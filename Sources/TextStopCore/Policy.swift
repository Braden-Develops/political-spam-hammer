import Foundation

public struct Incoming {
    public let rowID: Int64
    public let handle: String
    public let service: String
    public let chatGUID: String?
    public let participantCount: Int
    public let text: String?
    public let date: Date
    public let isSpamFiltered: Bool

    public init(rowID: Int64, handle: String, service: String, chatGUID: String?, participantCount: Int,
                text: String?, date: Date, isSpamFiltered: Bool = false) {
        self.rowID = rowID
        self.handle = handle
        self.service = service
        self.chatGUID = chatGUID
        self.participantCount = participantCount
        self.text = text
        self.date = date
        self.isSpamFiltered = isSpamFiltered
    }
}

public enum Action: String {
    case replyStop = "reply_stop"
    case askCloud = "ask_cloud"
    case report = "report"
    case ignore = "ignore"
}

public struct Decision: Equatable {
    public let action: Action
    public let category: TextCategory?
    public let reason: String

    public init(action: Action, category: TextCategory?, reason: String) {
        self.action = action
        self.category = category
        self.reason = reason
    }
}

public struct PolicyContext {
    public let isContact: Bool
    public let hasMessagedSender: Bool
    public let lastStopSent: Date?
    public let allowWithoutOptOut: Bool
    public let now: Date

    public init(isContact: Bool, hasMessagedSender: Bool, lastStopSent: Date?,
                allowWithoutOptOut: Bool = false, now: Date = Date()) {
        self.isContact = isContact
        self.hasMessagedSender = hasMessagedSender
        self.lastStopSent = lastStopSent
        self.allowWithoutOptOut = allowWithoutOptOut
        self.now = now
    }
}

public let maxMessageAge: TimeInterval = 24 * 3600
public let stopCooldown: TimeInterval = 30 * 24 * 3600

/// Every path to a reply runs through here. Pure, so all the safeguards are testable without
/// touching Messages.
public func decide(_ message: Incoming, _ context: PolicyContext) -> Decision {
    func ignore(_ reason: String, _ category: TextCategory? = nil) -> Decision {
        Decision(action: .ignore, category: category, reason: reason)
    }

    if message.handle == spamReportHandle { return ignore("carrier spam reporting") }
    if context.isContact { return ignore("sender is in Contacts") }
    if context.hasMessagedSender { return ignore("I have messaged this sender before") }
    if message.participantCount != 1 { return ignore("group chat") }
    guard let text = message.text, !text.isEmpty else { return ignore("no decodable text") }

    let result = classify(text)
    if result.category == .verification { return ignore("verification code", .verification) }
    if result.category == .transactional { return ignore("transactional: \(result.reason)", .transactional) }
    if result.category == .scam { return Decision(action: .report, category: .scam, reason: result.reason) }

    // Legitimate bulk senders use SMS. Unsolicited iMessage or email-address senders are almost
    // always scams, and a reply there also proves the Apple ID is live.
    if !["SMS", "RCS"].contains(message.service) {
        let suspicious = result.hasOptOut || result.category != .unclear
        return suspicious
            ? Decision(action: .report, category: .scam, reason: "bulk-looking \(message.service) from unknown sender")
            : ignore("\(message.service) from unknown sender", result.category)
    }
    if message.isSpamFiltered {
        return Decision(action: .report, category: .scam, reason: "filtered as spam by Messages")
    }
    guard isReplyableSender(message.handle) else { return ignore("sender can't receive replies", result.category) }
    if context.now.timeIntervalSince(message.date) > maxMessageAge { return ignore("older than 24h", result.category) }
    if let last = context.lastStopSent, context.now.timeIntervalSince(last) < stopCooldown {
        return ignore("STOP already sent in last 30 days", result.category)
    }

    if !result.hasOptOut && !context.allowWithoutOptOut {
        return ignore("no opt-out language", result.category)
    }
    switch result.category {
    case .political, .marketing:
        return Decision(action: .replyStop, category: result.category, reason: result.reason)
    default:
        return Decision(action: .askCloud, category: .unclear, reason: result.reason)
    }
}

/// Phone numbers and 5-6 digit short codes. Alphanumeric sender IDs and emails can't take a reply.
public func isReplyableSender(_ handle: String) -> Bool {
    handle.range(of: #"^\+?\d{5,15}$"#, options: .regularExpression) != nil
}

/// Applies a cloud label to a message the keyword pass couldn't place. The label can only choose
/// whether the fixed STOP reply goes out; the model never influences the text or the recipient.
public func decisionAfterCloud(_ label: TextCategory?) -> Decision {
    switch label {
    case .political?, .marketing?:
        return Decision(action: .replyStop, category: label, reason: "cloud classifier")
    case .scam?:
        return Decision(action: .report, category: .scam, reason: "cloud classifier")
    case let other?:
        return Decision(action: .ignore, category: other, reason: "cloud classifier")
    case nil:
        return Decision(action: .ignore, category: .unclear, reason: "unclear; cloud classifier unavailable")
    }
}

/// Never persists verification codes, and masks long digit runs everywhere else.
public func redactedPreview(_ text: String?, category: TextCategory?) -> String {
    guard let text = text, category != .verification else { return "[not stored]" }
    let masked = text.replacingOccurrences(of: #"\d{4,}"#, with: "####", options: .regularExpression)
    return String(masked.prefix(160))
}
