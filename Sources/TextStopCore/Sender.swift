import Foundation

public struct ProcessResult {
    public let status: Int32
    public let stderr: String
    public let stdout: String
}

/// Runs a process with a deadline: a pending permission dialog must not wedge the agent forever.
public func runProcess(_ path: String, _ arguments: [String], timeout: TimeInterval = 60) throws -> ProcessResult {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = arguments
    let out = Pipe(), err = Pipe()
    process.standardOutput = out
    process.standardError = err
    try process.run()

    let deadline = DispatchWorkItem { process.terminate() }
    DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: deadline)
    let output = out.fileHandleForReading.readDataToEndOfFile()
    let errors = err.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    deadline.cancel()
    return ProcessResult(status: process.terminationStatus,
                         stderr: String(decoding: errors, as: UTF8.self),
                         stdout: String(decoding: output, as: UTF8.self))
}

public enum Sender {
    // Values travel as argv, never spliced into the script, so nothing in a handle can become AppleScript.
    private static let sendToChat = """
        on run argv
            tell application "Messages" to send (item 1 of argv) to chat id (item 2 of argv)
        end run
        """
    private static let sendToParticipant = """
        on run argv
            tell application "Messages"
                set smsAccount to 1st account whose service type = SMS
                send (item 1 of argv) to participant (item 2 of argv) of smsAccount
            end tell
        end run
        """
    private static let probe = """
        tell application "Messages" to get count of accounts
        """

    /// Prefers the existing chat, which is the reliable route to short codes. A failed script hasn't
    /// sent anything, so falling through to the participant form can't double-send.
    public static func send(_ text: String, handle: String, chatGUID: String?) -> Result<String, SendError> {
        var errors: [String] = []
        if let chatGUID = chatGUID {
            switch osascript(sendToChat, [text, chatGUID]) {
            case .success: return .success("chat")
            case .failure(let error): errors.append("chat: \(error.message)")
            }
        }
        switch osascript(sendToParticipant, [text, handle]) {
        case .success: return .success("participant")
        case .failure(let error): errors.append("participant: \(error.message)")
        }
        return .failure(SendError(message: errors.joined(separator: "; ")))
    }

    /// Harmless scripting call. Run under the agent, it triggers the Automation prompt for the
    /// tool's own identity during dry-run rather than on the first real send.
    public static func probeAutomation() -> Result<String, SendError> {
        osascript(probe, [])
    }

    private static func osascript(_ script: String, _ args: [String]) -> Result<String, SendError> {
        do {
            let result = try runProcess("/usr/bin/osascript", ["-e", script] + args)
            guard result.status == 0 else {
                return .failure(SendError(message: result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)))
            }
            return .success(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
        } catch {
            return .failure(SendError(message: "\(error)"))
        }
    }
}

public struct SendError: Error {
    public let message: String
}
