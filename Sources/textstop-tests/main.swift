import Foundation
import TextStopCore

extension Result {
    var isFailure: Bool { if case .failure = self { return true }; return false }
}

var failures = 0
func check(_ condition: Bool, _ name: String) {
    if !condition {
        failures += 1
        print("FAIL: \(name)")
    }
}

// MARK: classifier

let classifierCases: [(String, TextCategory, Bool)] = [
    ("Your verification code is 482913. Do not share it.", .verification, false),
    ("G-482913 is your Google verification code.", .verification, false),
    ("Chase: your one-time passcode is 12345. Reply STOP to opt out", .verification, true),
    ("Paid for by Smith for Senate. Chip in $5 to the campaign before midnight! Reply STOP to end", .political, true),
    ("Early voting starts today! Find your polling place at vote.example. Stop2End", .political, true),
    ("TRUMP needs you: RUSH a gift to fight back. Txt STOP to quit", .political, true),
    ("Old Navy: 40% off everything today! Shop now. Reply STOP to unsubscribe", .marketing, true),
    ("FLASH SALE at Bob's Pizza: use code PIE. Msg&data rates may apply. Text STOP to cancel", .marketing, true),
    ("USPS: your package could not be delivered, update your address at usps-track.top. Reply STOP to opt out", .scam, true),
    ("You have an unpaid toll balance of $6.99. Pay now to avoid penalty.", .scam, false),
    ("Your Apple ID has been locked. Sign in here", .scam, false),
    ("Congratulations, you've won a $500 gift card! Claim your prize. Reply STOP to end", .scam, true),
    ("Hi, is this Jenny? Long time no see", .scam, false),
    ("CVS: your prescription is ready for pickup. Reply STOP to opt out", .transactional, true),
    ("Reminder: dental appointment tomorrow at 3pm. Reply C to confirm", .transactional, false),
    ("Your order has shipped! Track it here. Reply STOP to end alerts", .transactional, true),
    ("How would you grade Secretary Hegseth? Be honest to force his resignation. Respond: s.example.io/abc\n\nST\nStop2End", .political, true),
    ("Staff threaten to quit over pro-Trump censorship. Add your name >>> t.crushmaga.io/abc\n\nCMA\nStop2End", .political, true),
    ("EVERYONE is signing to CANCEL construction of Trump\u{2019}s arch. Have you signed?? >> t.example.io/abc  RAA Stop2End", .political, true),
    ("Obama's pick for the court? Y/N", .political, false),
    ("Mary Peltola here. Ballots are still arriving. Help make sure every vote is counted: https://example.com Stop to End", .political, true),
    ("Hi, you never confirmed your Costco Membership, and it's due today: i.example.org/x  AMPF Stop2End", .political, true),
    ("Shipt: Your Target order is scheduled for delivery Today: 1 pm to 2 pm. Track your order: https://example.com", .transactional, false),
    ("Thanks for joining. Text STOP to end", .unclear, true),
    ("Hey are we still on for dinner?", .unclear, false),
    ("Thanks for joining. Reply STOP to end", .unclear, true),
]
for (text, category, optOut) in classifierCases {
    let result = classify(text)
    check(result.category == category, "category \(category) for: \(text) (got \(result.category): \(result.reason))")
    check(result.hasOptOut == optOut, "optOut \(optOut) for: \(text)")
}

// MARK: policy

let now = Date()
func sms(_ text: String?, handle: String = "55123", service: String = "SMS", participants: Int = 1,
         age: TimeInterval = 60, spam: Bool = false) -> Incoming {
    Incoming(rowID: 1, handle: handle, service: service, chatGUID: "SMS;-;\(handle)", participantCount: participants,
             text: text, date: now.addingTimeInterval(-age), isSpamFiltered: spam)
}
func context(contact: Bool = false, messaged: Bool = false, last: Date? = nil, allow: Bool = false) -> PolicyContext {
    PolicyContext(isContact: contact, hasMessagedSender: messaged, lastStopSent: last, allowWithoutOptOut: allow, now: now)
}
let promo = "Old Navy: 40% off today! Reply STOP to unsubscribe"
let policyCases: [(String, Incoming, PolicyContext, Action)] = [
    ("marketing with opt-out", sms(promo), context(), .replyStop),
    ("long-code sender", sms(promo, handle: "+15551234567"), context(), .replyStop),
    ("contact never", sms(promo), context(contact: true), .ignore),
    ("previously messaged never", sms(promo), context(messaged: true), .ignore),
    ("group chat never", sms(promo, participants: 3), context(), .ignore),
    ("unknown chat never", sms(promo, participants: 0), context(), .ignore),
    ("verification never", sms("Your code is 123456. Reply STOP to opt out"), context(), .ignore),
    ("transactional never", sms("CVS: prescription ready. Reply STOP to end"), context(), .ignore),
    ("scam reported", sms("USPS: delivery failed, update address. Reply STOP to end"), context(), .report),
    ("iMessage bulk reported", sms(promo, handle: "+15551234567", service: "iMessage"), context(), .report),
    ("iMessage plain ignored", sms("hello there", handle: "+15551234567", service: "iMessage"), context(), .ignore),
    ("spam-filtered reported", sms(promo, spam: true), context(), .report),
    ("alphanumeric sender", sms(promo, handle: "OLDNAVY"), context(), .ignore),
    ("too old", sms(promo, age: 2 * 86_400), context(), .ignore),
    ("recent STOP", sms(promo), context(last: now.addingTimeInterval(-3600)), .ignore),
    ("old STOP resend", sms(promo), context(last: now.addingTimeInterval(-40 * 86_400)), .replyStop),
    ("no opt-out", sms("Old Navy: 40% off today!"), context(), .ignore),
    ("no opt-out allowed", sms("Old Navy: 40% off today!"), context(allow: true), .replyStop),
    ("opt-out but unclear", sms("Thanks for joining. Reply STOP to end"), context(), .askCloud),
    ("no text", sms(nil), context(), .ignore),
]
for (name, message, ctx, expected) in policyCases {
    let got = decide(message, ctx)
    check(got.action == expected, "policy \(name): expected \(expected), got \(got.action) (\(got.reason))")
}

check(decisionAfterCloud(.marketing).action == .replyStop, "cloud marketing")
check(decisionAfterCloud(.political).action == .replyStop, "cloud political")
check(decisionAfterCloud(.scam).action == .report, "cloud scam")
for label in [TextCategory.transactional, .verification, .unclear] {
    check(decisionAfterCloud(label).action == .ignore, "cloud \(label)")
}
check(decisionAfterCloud(nil).action == .ignore, "cloud unavailable")

// MARK: contacts

let book = ContactBook(phones: ["(555) 123-4567", "+44 7700 900123"], emails: ["Friend@Example.com"])
check(book.contains(handle: "+15551234567"), "contact: country code added")
check(book.contains(handle: "5551234567"), "contact: bare number")
check(book.contains(handle: "+447700900123"), "contact: international")
check(book.contains(handle: "friend@example.com"), "contact: email case")
check(!book.contains(handle: "+15559999999"), "contact: stranger")
check(!book.contains(handle: "55123"), "contact: short code")

// MARK: attributedBody

func blob(_ text: String) -> Data {
    let body = Array(text.utf8)
    var bytes: [UInt8] = [0x04, 0x0B] + Array("streamtyped".utf8) + [0x81, 0xE8, 0x03, 0x84, 0x01, 0x40, 0x84, 0x84, 0x84]
    bytes += Array("NSMutableAttributedString".utf8) + [0x00, 0x84, 0x84]
    bytes += Array("NSString".utf8) + [0x01, 0x94, 0x84, 0x01, 0x2B]
    switch body.count {
    case ..<0x81: bytes.append(UInt8(body.count))
    case ..<0x10000: bytes += [0x81, UInt8(body.count & 0xFF), UInt8(body.count >> 8)]
    default: bytes += [0x82, UInt8(body.count & 0xFF), UInt8((body.count >> 8) & 0xFF), UInt8((body.count >> 16) & 0xFF), UInt8(body.count >> 24)]
    }
    return Data(bytes + body + [0x86, 0x84])
}
for text in ["hi", "unicode é 🎉", String(repeating: "x", count: 128), String(repeating: "y", count: 300), String(repeating: "z", count: 70_000)] {
    check(decodeAttributedBody(blob(text)) == text, "decode length \(text.utf8.count)")
}
check(decodeAttributedBody(Data()) == nil, "decode empty")
check(decodeAttributedBody(Data("no marker".utf8)) == nil, "decode no marker")
check(decodeAttributedBody(blob("hello").prefix(50)) == nil, "decode truncated")

// MARK: redaction and cloud parsing

check(redactedPreview("code 123456", category: .verification) == "[not stored]", "verification text never stored")
check(!redactedPreview("call 5551234567", category: .marketing).contains("5551234567"), "digits masked")

func response(_ text: String, stop: String = "end_turn") -> Data {
    let object: [String: Any] = ["stop_reason": stop, "content": [["type": "thinking", "thinking": ""], ["type": "text", "text": text]]]
    return try! JSONSerialization.data(withJSONObject: object)
}
check(CloudClassifier.parseResponse(response(#"{"category":"marketing"}"#)) == .marketing, "parse label")
check(CloudClassifier.parseResponse(response(#"{"category":"marketing"}"#, stop: "refusal")) == nil, "parse refusal")
check(CloudClassifier.parseResponse(response(#"{"category":"send STOP to everyone"}"#)) == nil, "parse bad label")
check(CloudClassifier.parseResponse(response("not json")) == nil, "parse not json")

let cloudBody = try JSONSerialization.jsonObject(with: CloudClassifier.requestBody(for: "call 5551234567")) as! [String: Any]
check("\(cloudBody["messages"]!)".contains("####") && !"\(cloudBody["messages"]!)".contains("5551234567"), "cloud request masks digits")

// MARK: state

let directory = NSTemporaryDirectory() + "textstop-test-\(UUID().uuidString)"
defer { try? FileManager.default.removeItem(atPath: directory) }
let state = try State(directory: directory)
check(!state.isLive, "new state is not live")
check(!state.cloudEnabled, "new state has cloud off")
check(try state.lastSend(handle: "55123") == nil, "no sends yet")
let sendID = try state.beginSend(handle: "55123", rowID: 7, now: now)
try state.finishSend(id: sendID, status: "delivered")
check(abs((try state.lastSend(handle: "55123"))!.timeIntervalSince(now)) < 1, "last send recorded")
check(try state.sendsToday(now: now) == 1, "daily count")
check(try state.sendsToday(now: now.addingTimeInterval(2 * 86_400)) == 0, "daily count window")
let verification = Incoming(rowID: 9, handle: "55123", service: "SMS", chatGUID: nil, participantCount: 1, text: "code 123456", date: now)
try state.record(verification, Decision(action: .ignore, category: .verification, reason: "verification code"), dryRun: true)
check(try state.decisions(limit: 1).first?.preview == "[not stored]", "verification text not persisted")

// MARK: end to end against a synthetic chat.db, with a fake sender

let fixturePath = directory + "/chat.db"
let fixture = try Database(path: fixturePath, readOnly: false)
for sql in [
    "CREATE TABLE handle (ROWID INTEGER PRIMARY KEY, id TEXT)",
    "CREATE TABLE chat (ROWID INTEGER PRIMARY KEY, guid TEXT, style INTEGER, service_name TEXT DEFAULT 'SMS')",
    "CREATE TABLE chat_handle_join (chat_id INTEGER, handle_id INTEGER)",
    "CREATE TABLE chat_message_join (chat_id INTEGER, message_id INTEGER)",
    """
    CREATE TABLE message (ROWID INTEGER PRIMARY KEY, handle_id INTEGER, service TEXT, text TEXT, attributedBody BLOB,
        date INTEGER, is_spam INTEGER DEFAULT 0, is_from_me INTEGER DEFAULT 0, item_type INTEGER DEFAULT 0,
        associated_message_type INTEGER DEFAULT 0, is_system_message INTEGER DEFAULT 0, error INTEGER DEFAULT 0,
        is_sent INTEGER DEFAULT 0, is_delivered INTEGER DEFAULT 0)
    """,
] { try fixture.query(sql) }

var nextRow: Int64 = 0
func addChat(_ id: Int64, handle: String, style: Int64 = 45) throws {
    try fixture.query("INSERT OR IGNORE INTO handle VALUES (?, ?)", [.int(id), .text(handle)])
    try fixture.query("INSERT OR IGNORE INTO chat (ROWID, guid, style) VALUES (?, ?, ?)", [.int(id), .text("SMS;-;\(handle)"), .int(style)])
    try fixture.query("INSERT INTO chat_handle_join VALUES (?, ?)", [.int(id), .int(id)])
}
func addMessage(chat id: Int64, text: String?, body: Data? = nil, fromMe: Bool = false, tapback: Bool = false, service: String = "SMS") throws {
    nextRow += 1
    let raw = Int64((Date().timeIntervalSince1970 - 978_307_200) * 1e9)
    try fixture.query(
        "INSERT INTO message (ROWID, handle_id, service, text, attributedBody, date, is_from_me, associated_message_type) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
        [.int(nextRow), .int(id), .text(service), text.map { .text($0) } ?? .null, body.map { .blob($0) } ?? .null,
         .int(raw), .int(fromMe ? 1 : 0), .int(tapback ? 2000 : 0)])
    try fixture.query("INSERT INTO chat_message_join VALUES (?, ?)", [.int(id), .int(nextRow)])
}

try addChat(1, handle: "55001")          // marketing short code
try addChat(2, handle: "+15550000002")   // a contact
try addChat(3, handle: "+15550000003")   // stranger I've talked to
try addChat(4, handle: "55004")          // scam
try addChat(5, handle: "55005")          // verification
try addChat(6, handle: "55006", style: 43) // group
try addChat(7, handle: "55007")          // political, body-only text
try addMessage(chat: 1, text: "ancient promo from before install. 20% off! Reply STOP to end")

let e2eState = try State(directory: directory + "/e2e")
let e2eChat = try ChatDB(path: fixturePath)
let e2eContacts = ContactBook(phones: ["+15550000002"], emails: [])
var sentTo: [String] = []
let fakeSend: (Incoming) -> String = { sentTo.append($0.handle); return "delivered via fake" }
func pass() throws -> RunSummary {
    try runOnce(chat: e2eChat, state: e2eState, contacts: e2eContacts, send: fakeSend, log: { _ in })
}

check(try pass().processed == 0, "first run only sets the watermark")
check(!e2eState.isLive, "first run is dry-run")

let bulk = "Old Navy: 40% off today! Reply STOP to unsubscribe"
try addMessage(chat: 1, text: bulk)
try addMessage(chat: 2, text: bulk)
try addMessage(chat: 3, text: "see you then", fromMe: true)
try addMessage(chat: 3, text: bulk)
try addMessage(chat: 4, text: "USPS: delivery failed, update your address. Reply STOP to end")
try addMessage(chat: 5, text: "Your code is 123456. Reply STOP to opt out")
try addMessage(chat: 6, text: bulk)
try addMessage(chat: 7, text: nil, body: blob("Paid for by Smith for Senate. Early voting starts now. Reply STOP to end"))
try addMessage(chat: 1, text: bulk, tapback: true)

let dry = try pass()
check(dry.processed == 7, "dry-run processed 7 (got \(dry.processed))")
check(dry.wouldSend == 2 && dry.sent == 0, "dry-run would send 2, sent 0 (got \(dry.wouldSend), \(dry.sent))")
check(dry.reported == 1, "dry-run reported the scam")
check(sentTo.isEmpty, "dry-run never calls the sender")
let logged = try e2eState.decisions(limit: 50)
check(logged.first { $0.handle == "+15550000002" }?.preview == "[not stored]", "contact text not persisted")
check(logged.first { $0.handle == "+15550000003" }?.preview == "[not stored]", "known sender text not persisted")
check(logged.first { $0.handle == "55001" }?.preview != "[not stored]", "bulk sender text kept for review")
check(try pass().processed == 0, "watermark prevents reprocessing")
check(try e2eState.lastSend(handle: "55001") == nil, "dry-run doesn't count as a send")

try e2eState.setMeta("mode", "live")
try addMessage(chat: 1, text: bulk)
try addMessage(chat: 1, text: bulk) // same sender again in the same pass
try addMessage(chat: 2, text: bulk)
try addMessage(chat: 4, text: "USPS: delivery failed, update your address. Reply STOP to end")
try addMessage(chat: 7, text: nil, body: blob("Paid for by Smith for Senate. Early voting starts now. Reply STOP to end"))
let live = try pass()
check(sentTo == ["55001", "55007"], "live sends once per eligible sender (got \(sentTo))")
check(live.sent == 2, "live sent 2")

// My own STOP doesn't make the sender look like someone I talk to; a cooldown handles repeats.
try addMessage(chat: 1, text: "STOP", fromMe: true)
check(!(try e2eChat.hasMessaged(handle: "55001")), "bare STOP isn't a conversation")
check(try e2eChat.hasMessaged(handle: "+15550000003"), "real conversation is detected")
try addChat(9, handle: "55009")
try addMessage(chat: 9, text: nil, body: blob("STOP"), fromMe: true)
check(!(try e2eChat.hasMessaged(handle: "55009")), "body-only STOP isn't a conversation")
try addMessage(chat: 9, text: nil, body: blob("thanks, see you then"), fromMe: true)
check(try e2eChat.hasMessaged(handle: "55009"), "body-only real message is a conversation")

check(try e2eChat.chatGUID(handle: "55001") == "SMS;-;55001", "finds the existing chat")
check(try e2eChat.chatGUID(handle: "55006") == nil, "skips group chats")

// Daily cap: 20 prior sends, then a new eligible sender gets nothing.
for _ in 0..<dailySendCap { try e2eState.beginSend(handle: "cap-filler", rowID: nil) }
try addChat(8, handle: "55008")
try addMessage(chat: 8, text: bulk)
sentTo = []
let capped = try pass()
check(sentTo.isEmpty && capped.capped == 1, "daily cap blocks sending")

// Empty Contacts must stop the run rather than treating everyone as unknown.
do {
    _ = try runOnce(chat: e2eChat, state: e2eState, contacts: ContactBook(phones: [], emails: []), send: fakeSend, log: { _ in })
    check(false, "empty contacts should throw")
} catch is RunError {}

// MARK: spam reports

check(reportableNumber("+12025550143") == "2025550143", "report number: US number as 10 digits")
check(reportableNumber("55001") == "55001", "report number: short code unchanged")
let carrierAsk = Incoming(rowID: 1, handle: spamReportHandle, service: "SMS", chatGUID: nil, participantCount: 1,
                          text: "Reply with the phone number the spam came from. Reply STOP to end", date: Date())
check(decide(carrierAsk, PolicyContext(isContact: false, hasMessagedSender: false, lastStopSent: nil)).action == .ignore,
      "carrier spam line is never a STOP target")

var reported: [String] = []
let fakeReport: (String) -> String = { reported.append($0); return "delivered via fake" }
let spamRow = try e2eChat.incoming(from: "55001", after: 0).last!.rowID
check(try e2eState.queueSpamReport(handle: "55001", rowID: spamRow), "queues a report")
check(!(try e2eState.queueSpamReport(handle: "55001", rowID: spamRow)), "doesn't queue the same message twice")
let t0 = Date()
_ = try processSpamReports(chat: e2eChat, state: e2eState, now: t0, sendReport: fakeReport, log: { _ in })
check(reported == [bulk], "forwards the full spam text first (got \(reported))")
_ = try processSpamReports(chat: e2eChat, state: e2eState, now: t0.addingTimeInterval(60), sendReport: fakeReport, log: { _ in })
check(reported.count == 1, "waits for the carrier before sending the number")
try addChat(10, handle: spamReportHandle)
try addMessage(chat: 10, text: "Thanks. Now reply with the phone number the spam came from.")
_ = try processSpamReports(chat: e2eChat, state: e2eState, now: t0.addingTimeInterval(120), sendReport: fakeReport, log: { _ in })
check(reported.last == "55001", "sends the number after the carrier asks (got \(reported))")
check(!carrierWantsNumber("Thank you for reporting spam, we appreciate your assistance. Messages sent to 7726 are shared with security providers to help prevent further spam."),
      "a thank-you isn't a request for the number")
check(carrierWantsNumber("Please reply with the phone number or email address the spam came from."), "recognises the number request")
check(try e2eState.spamReportCounts().contains { $0.status == "done" && $0.count == 1 }, "report marked done")

let secondRow = try e2eChat.incoming(from: "55007", after: 0).last!.rowID
try e2eState.queueSpamReport(handle: "55007", rowID: secondRow)
_ = try processSpamReports(chat: e2eChat, state: e2eState, now: t0, sendReport: fakeReport, log: { _ in })
check(reported.count == 3, "forwards the next queued report")
_ = try processSpamReports(chat: e2eChat, state: e2eState, now: t0.addingTimeInterval(spamReportReplyWindow + 60),
                           sendReport: fakeReport, log: { _ in })
check(reported.count == 3, "the old carrier message doesn't count as a reply to a new report")
check(try e2eState.spamReportCounts().contains { $0.status == "no_reply" }, "gives up after the reply window")
try e2eState.queueSpamReport(handle: "55007", rowID: try e2eChat.incoming(from: "55007", after: 0).first!.rowID)
_ = try processSpamReports(chat: e2eChat, state: e2eState, now: t0, sendReport: fakeReport, log: { _ in })
try addMessage(chat: 10, text: "Thank you for reporting spam, we appreciate your assistance.")
_ = try processSpamReports(chat: e2eChat, state: e2eState, now: t0.addingTimeInterval(60), sendReport: fakeReport, log: { _ in })
check(reported.count == 4 && reported.last != "55007", "a thank-you finishes the report without sending the number (got \(reported))")
check(try e2eState.spamReportCounts().contains { $0.status == "done" && $0.count == 2 }, "thanked report marked done")

// A live STOP queues a report and the same run forwards it.
let liveState = try State(directory: directory + "/e2e-live")
try liveState.setMeta("watermark", String(try e2eChat.maxRowID()))
try liveState.setMeta("mode", "live")
try liveState.setMeta("spam_report", "on")
try addChat(11, handle: "55011")
try addMessage(chat: 11, text: bulk)
sentTo = []; reported = []
_ = try runOnce(chat: e2eChat, state: liveState, contacts: e2eContacts, send: fakeSend, sendReport: fakeReport, log: { _ in })
check(sentTo == ["55011"] && reported == [bulk], "live STOP is followed by a 7726 report (got \(sentTo), \(reported))")
let liveMetrics = try metricsText(state: liveState, report: nil)
check(liveMetrics.contains(#"textstop_spam_reports_total{status="forwarded"} 1"#), "metrics: spam report status")

// MARK: campaign log

check(extractCampaign(from: ["Trump is at it again! Chip in: secure.actblue.com/x Stop2End",
                             "You have been unsubscribed from AmeriPAC Future. No more messages will be sent."])
      == Campaign(name: "AmeriPAC Future", source: "unsubscribe confirmation"), "campaign: unsubscribe confirmation wins")
check(extractCampaign(from: ["Early voting starts now! Paid for by Smith for Senate. Reply STOP to end"])?.name == "Smith for Senate",
      "campaign: paid for by")
check(extractCampaign(from: ["Paid for by Friends of Jane Doe and not authorized by any candidate"])?.name == "Friends of Jane Doe",
      "campaign: paid for by with authorization clause")
check(extractCampaign(from: ["Hi it's Jen with Arizona Victory Fund. Will you chip in?"])?.name == "Arizona Victory Fund",
      "campaign: sign-off")
check(extractCampaign(from: ["Vote!"]) == nil, "campaign: none found")
check(extractCampaign(from: ["TRUMP'S IRS ANNOUNCED: $1.8B!\nSign: r.turnoutpac.org/Y\n\nPTP26\nStop2End"])
      == Campaign(name: "PTP26", source: "sign-off"), "campaign: sign-off above Stop2End, not the headline")
check(extractCampaign(from: ["It's Mary Peltola. We spent down to $0. Help: https://peltola-text.com/x"])?.name == "Mary Peltola",
      "campaign: candidate names themself")
check(extractCampaign(from: ["Mary Peltola here. Ballots are still arriving."])?.name == "Mary Peltola", "campaign: 'X here'")
check(isUnsubscribeConfirmation("You have been unsubscribed from Stop GOP Fund") && !isUnsubscribeConfirmation("Stop GOP Fund\nStop2End"),
      "unsubscribe confirmations are recognised")
check(extractCampaign(from: ["Rush $30 >> i.demsenate.org/k\n\nDSCC\n\nStop2End"])?.name == "DSCC", "campaign: blank line before Stop2End")
check(rootDomain("t.stopgopfund.org/abc") == "stopgopfund.org", "root domain")
check(linkHosts("Chip in: https://secure.actblue.com/donate/smith-sms and winred.com/abc") ==
      ["secure.actblue.com/donate/smith-sms", "winred.com/abc"], "links: hosts and paths (got \(linkHosts("Chip in: https://secure.actblue.com/donate/smith-sms and winred.com/abc")))")
check(csvField("=HYPERLINK(\"x\")") == "\"'=HYPERLINK(\"\"x\"\")\"", "csv: quotes and formula guard")

// MARK: metrics

let metrics = try metricsText(state: e2eState, report: RunReport(success: true, processed: 3, contacts: 2))
check(metrics.contains("textstop_last_run_success 1"), "metrics: success")
check(metrics.contains("textstop_live 1"), "metrics: live flag")
check(metrics.contains(#"textstop_decisions_total{action="reply_stop",category="political",mode="dry_run"} 1"#), "metrics: decision labels")
check(metrics.contains(#"textstop_sends_total{result="delivered"}"#), "metrics: send results folded")
check(!metrics.contains("55001") && !metrics.contains("+1555") && !metrics.contains("Navy"), "metrics: no handles or text")
let failed = try metricsText(state: e2eState, report: RunReport(success: false))
let lastBefore = try e2eState.meta("last_success")
let preview = try metricsText(state: e2eState, report: nil)
check(!preview.contains("textstop_last_run_success"), "test push has no run fields")
check(try e2eState.meta("last_success") == lastBefore, "test push leaves last_success alone")
check(failed.contains("textstop_last_run_success 0") && !failed.contains("textstop_last_run_processed"), "metrics: failed run")
check(failed.contains("textstop_last_success_timestamp_seconds"), "metrics: last success survives a failure")
for line in metrics.split(separator: "\n") where !line.hasPrefix("#") {
    check(line.range(of: #"^[a-z_0-9]+(\{[a-z_]+="[a-z_0-9]*"(,[a-z_]+="[a-z_0-9]*")*\})? -?[0-9.e+]+$"#, options: .regularExpression) != nil,
          "metrics: valid line \(line)")
}
check(Pushgateway.push("x 1\n", to: "ftp://example", instance: "m").isFailure, "push rejects non-http URL")

print(failures == 0 ? "all tests passed" : "\(failures) failures")
exit(failures == 0 ? 0 : 1)
