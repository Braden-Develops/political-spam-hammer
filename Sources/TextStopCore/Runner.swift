import Foundation

public let stopText = "STOP"
public let dailySendCap = 20
public let dryRunDays = 7

public struct RunSummary {
    public var processed = 0
    public var wouldSend = 0
    public var sent = 0
    public var reported = 0
    public var capped = 0
    public var contacts = 0
    public var spamReportSteps = 0
}

public enum RunError: Error, CustomStringConvertible {
    case noContacts
    public var description: String {
        "Contacts came back empty. Refusing to run, since every sender would look unknown."
    }
}

/// One pass over new messages. The launch agent runs this on an interval.
public func runOnce(chat: ChatDB, state: State, contacts: ContactBook? = nil,
                    send: ((Incoming) -> String)? = nil, sendReport: ((String) -> String)? = nil,
                    log: (String) -> Void) throws -> RunSummary {
    let contacts = try contacts ?? ContactBook.loadFromDisk()
    guard contacts.count > 0 else { throw RunError.noContacts }
    var summary = RunSummary()
    summary.contacts = contacts.count

    // First run starts from "now": history never gets a reply.
    guard let watermarkText = try state.meta("watermark"), let watermark = Int64(watermarkText) else {
        let current = try chat.maxRowID()
        try state.setMeta("watermark", String(current))
        try state.setMeta("first_run", String(Date().timeIntervalSince1970))
        if try state.meta("mode") == nil { try state.setMeta("mode", "dry-run") }
        log("initialized at message \(current) in dry-run mode")
        return summary
    }

    let dryRun = !state.isLive
    for message in try chat.incoming(after: watermark) {
        let context = PolicyContext(
            isContact: contacts.contains(handle: message.handle),
            hasMessagedSender: try chat.hasMessaged(handle: message.handle),
            lastStopSent: try state.lastSend(handle: message.handle),
            allowWithoutOptOut: state.allowWithoutOptOut
        )
        var decision = decide(message, context)
        if decision.action == .askCloud {
            let label = state.cloudEnabled ? CloudClassifier.classify(message.text ?? "") : nil
            decision = decisionAfterCloud(label)
        }

        if decision.action == .replyStop && !dryRun {
            if try state.sendsToday() >= dailySendCap {
                decision = Decision(action: .ignore, category: decision.category, reason: "daily send cap reached")
                summary.capped += 1
            } else {
                let id = try state.beginSend(handle: message.handle, rowID: message.rowID)
                let status = send?(message) ?? deliver(stopText, to: message.handle, chatGUID: message.chatGUID, chat: chat)
                try state.finishSend(id: id, status: status)
                log("sent \(stopText) to \(message.handle): \(status)")
                summary.sent += 1
                if state.spamReporting && !["script_failed", "failed"].contains(sendResult(status)) {
                    try state.queueSpamReport(handle: message.handle, rowID: message.rowID)
                }
            }
        } else if decision.action == .replyStop {
            log("[dry-run] would send \(stopText) to \(message.handle) (\(decision.category?.rawValue ?? "-"): \(decision.reason))")
            summary.wouldSend += 1
        }
        if decision.action == .report { summary.reported += 1 }

        // Conversations with people are none of the log's business; keep text only for bulk-looking senders.
        let known = context.isContact || context.hasMessagedSender
        let storeText = !known && (["SMS", "RCS"].contains(message.service) || decision.action == .report)
        try state.record(message, decision, dryRun: dryRun, storeText: storeText)
        try state.setMeta("watermark", String(message.rowID))
        summary.processed += 1
    }
    if !dryRun {
        summary.spamReportSteps = try processSpamReports(chat: chat, state: state, sendReport: sendReport, log: log)
    }
    return summary
}

/// AppleScript reporting success only means Messages accepted the request, so check chat.db too.
public func deliver(_ text: String, to handle: String, chatGUID: String?, chat: ChatDB, wait: TimeInterval = 20) -> String {
    let start = Date().addingTimeInterval(-2)
    switch Sender.send(text, handle: handle, chatGUID: chatGUID) {
    case .failure(let error):
        return "script_failed: \(error.message)"
    case .success(let route):
        let deadline = Date().addingTimeInterval(wait)
        var last = "not_seen_in_chat_db"
        while Date() < deadline {
            if let status = try? chat.outgoingStatus(handle: handle, since: start) {
                if status.error != 0 { return "failed via \(route): error \(status.error)" }
                if status.delivered { return "delivered via \(route)" }
                last = status.sent ? "sent" : "pending"
            }
            Thread.sleep(forTimeInterval: 2)
        }
        return "\(last) via \(route)"
    }
}
