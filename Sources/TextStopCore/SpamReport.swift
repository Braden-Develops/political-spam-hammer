import Foundation

/// US carriers' shared spam-reporting short code. Forward the spam text, the carrier asks for the
/// sender's number, reply with it.
public let spamReportHandle = "7726"
/// How long to wait for the carrier to ask for the number before giving up on one report.
public let spamReportReplyWindow: TimeInterval = 30 * 60

/// The form carriers ask for: ten digits for US numbers, short codes as they are.
public func reportableNumber(_ handle: String) -> String {
    let digits = handle.filter(\.isNumber)
    if handle.hasPrefix("+1") && digits.count == 11 { return String(digits.dropFirst()) }
    return handle.hasPrefix("+") ? digits : handle
}

/// True when the carrier's reply asks who sent the spam, rather than just thanking.
public func carrierWantsNumber(_ text: String) -> Bool {
    let t = text.lowercased()
    return t.range(of: #"(reply|respond|send|provide|enter)\b.{0,60}\b(number|address|sender)|what (phone )?number"#,
                   options: .regularExpression) != nil
}

/// Advances the report queue by at most one step per call, so carrier replies pair with the right
/// report: forward the oldest queued text, then wait for the carrier's question before sending its number.
/// `sendReport` delivers a text to 7726 and returns a status like `deliver` does.
public func processSpamReports(chat: ChatDB, state: State, now: Date = Date(),
                               sendReport: ((String) -> String)? = nil, log: (String) -> Void) throws -> Int {
    func send(_ text: String) -> String {
        sendReport?(text) ?? deliver(text, to: spamReportHandle,
                                     chatGUID: try? chat.chatGUID(handle: spamReportHandle), chat: chat)
    }
    func ok(_ status: String) -> Bool { !["script_failed", "failed"].contains(sendResult(status)) }

    if let active = try state.activeSpamReport() {
        let replies = try chat.incoming(from: spamReportHandle, after: active.watermark)
        if !replies.isEmpty && !replies.contains(where: { carrierWantsNumber($0.text ?? "") }) {
            // Some carriers take the forward alone and just say thanks.
            try state.updateSpamReport(id: active.id, status: "done", now: now)
            log("spam report for \(active.handle): \(spamReportHandle) accepted it")
            return 1
        }
        if !replies.isEmpty {
            let status = send(reportableNumber(active.handle))
            try state.updateSpamReport(id: active.id, status: ok(status) ? "done" : "number_failed", now: now)
            log("spam report for \(active.handle): sent number to \(spamReportHandle) (\(status))")
            return 1
        }
        if now.timeIntervalSince(active.forwardedAt) > spamReportReplyWindow {
            try state.updateSpamReport(id: active.id, status: "no_reply", now: now)
            log("spam report for \(active.handle): \(spamReportHandle) never asked for the number")
        } else {
            return 0
        }
    }

    guard let next = try state.nextQueuedSpamReport() else { return 0 }
    guard let text = try chat.messageText(rowID: next.messageRowID), !text.isEmpty else {
        try state.updateSpamReport(id: next.id, status: "no_text", now: now)
        return 0
    }
    let watermark = try chat.maxRowID()
    let status = send(text)
    if ok(status) {
        try state.markSpamReportForwarded(id: next.id, watermark: watermark, now: now)
        log("spam report for \(next.handle): forwarded text to \(spamReportHandle) (\(status))")
    } else {
        try state.updateSpamReport(id: next.id, status: "forward_failed", now: now)
        log("spam report for \(next.handle): forward failed (\(status))")
    }
    return 1
}
