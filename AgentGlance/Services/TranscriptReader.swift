import Foundation
import os

/// Reads Claude Code JSONL transcript files to extract model name and token usage.
enum TranscriptReader {
    private static let logger = Logger(subsystem: "AgentGlance", category: "TranscriptReader")

    /// Construct the path to a session's JSONL transcript file.
    static func transcriptPath(sessionId: String, cwd: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let projectsDir = (home as NSString).appendingPathComponent(".claude/projects")
        // Encode CWD: replace "/" with "-"
        let encodedCwd = cwd.replacingOccurrences(of: "/", with: "-")
        let dir = (projectsDir as NSString).appendingPathComponent(encodedCwd)
        return (dir as NSString).appendingPathComponent("\(sessionId).jsonl")
    }

    /// Read the transcript and extract model name + cumulative token usage.
    /// Only reads assistant-type lines. Reads from the end for efficiency.
    static func readUsage(sessionId: String, cwd: String) -> TranscriptUsage? {
        let path = transcriptPath(sessionId: sessionId, cwd: cwd)
        guard FileManager.default.fileExists(atPath: path) else {
            return nil
        }

        guard let data = FileManager.default.contents(atPath: path),
              let content = String(data: data, encoding: .utf8) else {
            return nil
        }

        var modelName: String?
        var totalInput = 0
        var totalOutput = 0

        for line in content.components(separatedBy: .newlines) where !line.isEmpty {
            guard let lineData = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let type = json["type"] as? String,
                  type == "assistant",
                  let message = json["message"] as? [String: Any] else {
                continue
            }

            // Extract model name (use the latest one)
            if let model = message["model"] as? String {
                modelName = model
            }

            // Accumulate token usage
            if let usage = message["usage"] as? [String: Any] {
                if let input = usage["input_tokens"] as? Int {
                    totalInput += input
                }
                if let output = usage["output_tokens"] as? Int {
                    totalOutput += output
                }
                // Include cache tokens in input count
                if let cacheCreation = usage["cache_creation_input_tokens"] as? Int {
                    totalInput += cacheCreation
                }
                if let cacheRead = usage["cache_read_input_tokens"] as? Int {
                    totalInput += cacheRead
                }
            }
        }

        guard modelName != nil || totalInput > 0 || totalOutput > 0 else {
            return nil
        }

        return TranscriptUsage(
            modelName: modelName,
            inputTokens: totalInput,
            outputTokens: totalOutput
        )
    }
}

struct TranscriptUsage {
    let modelName: String?
    let inputTokens: Int
    let outputTokens: Int
    var totalTokens: Int { inputTokens + outputTokens }
}
