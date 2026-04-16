import Foundation
import Security
import os

private let logger = Logger(subsystem: "app.agentglance", category: "PairingManager")

/// Manages pairing codes and persistent session tokens for the web remote interface.
@Observable
@MainActor
final class PairingManager {

    struct StoredToken: Codable {
        let token: String
        let createdAt: Date
        var lastUsed: Date
        var deviceName: String
    }

    private(set) var currentCode: String?
    private(set) var codeSecondsRemaining: Int = 0

    static let codeLifetime: TimeInterval = 60

    private var codeExpiry: Date?
    private var codeTimer: Timer?

    private var tokens: [StoredToken] = []
    private var failedAttempts: [(ip: String, time: Date)] = []

    private let tokensPath: String = {
        let dir = (NSHomeDirectory() as NSString).appendingPathComponent(".agentglance")
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return (dir as NSString).appendingPathComponent("web-tokens.json")
    }()

    var pairedDeviceCount: Int { tokens.count }

    init() {
        loadTokens()
        pruneExpiredTokens()
    }

    // MARK: - Pair Code

    /// Generate a new 6-digit code that expires after 60 seconds.
    /// Automatically regenerates when the timer reaches 0.
    @discardableResult
    func generatePairCode() -> String {
        codeTimer?.invalidate()

        var bytes = [UInt8](repeating: 0, count: 4)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let num = (UInt32(bytes[0]) << 24 | UInt32(bytes[1]) << 16 | UInt32(bytes[2]) << 8 | UInt32(bytes[3])) % 1_000_000
        let code = String(format: "%06d", num)
        currentCode = code
        codeExpiry = Date().addingTimeInterval(Self.codeLifetime)
        codeSecondsRemaining = Int(Self.codeLifetime)
        logger.info("Generated new pair code (expires in \(Int(Self.codeLifetime))s)")

        codeTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] timer in
            Task { @MainActor [weak self] in
                guard let self else { timer.invalidate(); return }
                self.tickCodeTimer()
            }
        }

        return code
    }

    /// Stop the pair code timer (e.g. when disabling remote access)
    func stopCodeTimer() {
        codeTimer?.invalidate()
        codeTimer = nil
        currentCode = nil
        codeSecondsRemaining = 0
    }

    private func tickCodeTimer() {
        guard let codeExpiry else { return }
        let remaining = Int(codeExpiry.timeIntervalSinceNow)
        if remaining <= 0 {
            // Auto-regenerate
            generatePairCode()
        } else {
            codeSecondsRemaining = remaining
        }
    }

    /// Validate a pair code and return a session token on success, nil on failure.
    func validateCode(_ code: String, ip: String = "unknown", deviceName: String = "Phone") -> String? {
        // Rate limiting: max 5 failed attempts per minute per IP
        let oneMinuteAgo = Date().addingTimeInterval(-60)
        failedAttempts.removeAll { $0.time < oneMinuteAgo.addingTimeInterval(-600) }
        let recentFails = failedAttempts.filter { $0.ip == ip && $0.time > oneMinuteAgo }
        if recentFails.count >= 5 {
            logger.warning("Rate limited pairing from \(ip)")
            return nil
        }

        guard let currentCode, let codeExpiry, Date() < codeExpiry, code == currentCode else {
            failedAttempts.append((ip: ip, time: Date()))
            logger.info("Pair code validation failed from \(ip)")
            return nil
        }

        // Code used: generate a fresh one immediately
        generatePairCode()

        // Generate token
        var tokenBytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, tokenBytes.count, &tokenBytes)
        let token = tokenBytes.map { String(format: "%02x", $0) }.joined()

        let stored = StoredToken(token: token, createdAt: Date(), lastUsed: Date(), deviceName: deviceName)
        tokens.append(stored)
        saveTokens()

        logger.info("Paired new device '\(deviceName)' from \(ip)")
        return token
    }

    // MARK: - Token Validation

    func isValidToken(_ token: String) -> Bool {
        guard let index = tokens.firstIndex(where: { $0.token == token }) else { return false }
        tokens[index].lastUsed = Date()
        return true
    }

    // MARK: - Device Management

    /// Called when tokens are revoked — WebRemoteServer uses this to disconnect clients
    var onRevokeAll: (() -> Void)?

    /// Paired devices for display in the UI
    struct PairedDevice: Identifiable {
        let id: String // token prefix, enough to identify
        let deviceName: String
        let createdAt: Date
        let lastUsed: Date
        fileprivate let token: String
    }

    var pairedDevices: [PairedDevice] {
        tokens.map { t in
            PairedDevice(
                id: String(t.token.prefix(12)),
                deviceName: t.deviceName,
                createdAt: t.createdAt,
                lastUsed: t.lastUsed,
                token: t.token
            )
        }
    }

    func revokeDevice(_ device: PairedDevice) {
        tokens.removeAll(where: { $0.token == device.token })
        saveTokens()
        logger.info("Revoked device '\(device.deviceName)'")
    }

    func revokeToken(_ token: String) {
        tokens.removeAll(where: { $0.token == token })
        saveTokens()
        logger.info("Device unpaired via web remote")
    }

    func revokeAll() {
        tokens.removeAll()
        saveTokens()
        logger.info("Revoked all web remote tokens")
        onRevokeAll?()
    }

    // MARK: - Persistence

    private func loadTokens() {
        guard let data = FileManager.default.contents(atPath: tokensPath) else {
            logger.info("No tokens file at \(self.tokensPath)")
            return
        }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            tokens = try decoder.decode([StoredToken].self, from: data)
            logger.info("Loaded \(self.tokens.count) token(s) from disk")
        } catch {
            logger.warning("Resetting corrupt tokens file: \(error.localizedDescription)")
            try? FileManager.default.removeItem(atPath: tokensPath)
        }
    }

    private func saveTokens() {
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = .prettyPrinted
            let data = try encoder.encode(tokens)
            try data.write(to: URL(fileURLWithPath: tokensPath), options: .atomic)
            logger.info("Saved \(self.tokens.count) token(s) to disk")
        } catch {
            logger.error("Failed to save tokens: \(error.localizedDescription)")
        }
    }

    private func pruneExpiredTokens() {
        let cutoff = Date().addingTimeInterval(-30 * 24 * 3600) // 30 days
        let before = tokens.count
        self.tokens.removeAll(where: { $0.lastUsed < cutoff })
        if tokens.count < before {
            saveTokens()
            logger.info("Pruned \(before - self.tokens.count) expired token(s)")
        }
    }
}
