import Foundation
import UserNotifications
import AppKit
import os

private let logger = Logger(subsystem: "app.agentglance", category: "NotificationManager")

@MainActor
final class NotificationManager: NSObject {
    private let center = UNUserNotificationCenter.current()

    override init() {
        super.init()
        center.delegate = self
        requestPermission()
    }

    private func requestPermission() {
        center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            if granted {
                logger.info("Notification permission granted")
            } else if let error {
                logger.error("Notification permission error: \(error.localizedDescription)")
            }
        }
    }

    func notifyAwaitingApproval(session: Session) {
        let content = UNMutableNotificationContent()
        content.title = "Claude Code — \(session.projectName)"

        var body = "Wants to run \(session.currentTool ?? "a tool")"
        if let summary = session.pendingToolSummary {
            body += "\n\(summary)"
        }
        content.body = body
        content.sound = .default
        content.categoryIdentifier = "APPROVAL"

        let request = UNNotificationRequest(
            identifier: "approval-\(session.id)-\(Date().timeIntervalSince1970)",
            content: content,
            trigger: nil
        )

        center.add(request)
    }

    func notifyReady(session: Session) {
        let content = UNMutableNotificationContent()
        content.title = "Claude Code"
        content.body = "'\(session.projectName)' finished — ready for next prompt"
        content.sound = .default
        content.categoryIdentifier = "READY"

        let request = UNNotificationRequest(
            identifier: "ready-\(session.id)",
            content: content,
            trigger: nil
        )

        center.add(request)
    }

    func notifyComplete(session: Session) {
        let content = UNMutableNotificationContent()
        content.title = "Claude Code"
        content.body = "Task complete in '\(session.projectName)' — \(session.toolCount) tool calls"
        content.sound = .default
        content.categoryIdentifier = "COMPLETE"

        let request = UNNotificationRequest(
            identifier: "complete-\(session.id)",
            content: content,
            trigger: nil
        )

        center.add(request)
    }

    func setupCategories() {
        let openAction = UNNotificationAction(
            identifier: "OPEN_CLAUDE",
            title: "Open Claude",
            options: [.foreground]
        )
        let dismissAction = UNNotificationAction(
            identifier: "DISMISS",
            title: "Dismiss",
            options: [.destructive]
        )

        let approvalCategory = UNNotificationCategory(
            identifier: "APPROVAL",
            actions: [openAction, dismissAction],
            intentIdentifiers: []
        )
        let readyCategory = UNNotificationCategory(
            identifier: "READY",
            actions: [openAction, dismissAction],
            intentIdentifiers: []
        )
        let completeCategory = UNNotificationCategory(
            identifier: "COMPLETE",
            actions: [openAction, dismissAction],
            intentIdentifiers: []
        )

        center.setNotificationCategories([approvalCategory, readyCategory, completeCategory])
    }
}

extension NotificationManager: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        if response.actionIdentifier == "OPEN_CLAUDE" {
            Task { @MainActor in
                if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.anthropic.claudecode") {
                    NSWorkspace.shared.openApplication(at: url, configuration: .init())
                }
            }
        }
        completionHandler()
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}
