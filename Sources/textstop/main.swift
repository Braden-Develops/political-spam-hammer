import Foundation
import TextStopCore

setvbuf(stdout, nil, _IOLBF, 0)

let usage = """
    textstop: reply STOP to political and marketing texts. Dry-run until you say otherwise.

      run                    process new messages once (what the launch agent calls)
      status                 mode, counts, recent sends
      log [n] [--stop]       recent decisions (--stop: only would-send/sent ones)
      report [n]             likely scams, for reporting by hand
      doctor                 check permissions, contacts, SMS arrival, decoder
      backtest [days] [--show]
                             classify past messages. Sends nothing, stores nothing
      test-send <handle> [text]
                             send one manual text (default HELP), with confirmation
      go-live [--force]      start sending real replies (after \(dryRunDays) days of dry-run)
      dry-run                stop sending real replies
      cloud on|off           allow unclear messages to go to the Claude API
      metrics <url>|off      push metrics to a Prometheus Pushgateway each run
      no-optout on|off       also reply when a message has no "reply STOP" wording (default off)
      spam-report on|off|backfill [hours]
                             after each real STOP, report the text to the carrier spam line 7726
    """

func stamp(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd HH:mm"
    return formatter.string(from: date)
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func log(_ message: String) { print("\(stamp(Date())) \(message)") }

let args = Array(CommandLine.arguments.dropFirst())
let flags = Set(args.filter { $0.hasPrefix("--") })
let positional = args.filter { !$0.hasPrefix("--") }

do {
    switch positional.first {
    case "run":
        let started = Date()
        let state = try State()
        var report = RunReport(success: false)
        // Metrics go out even when the run fails, so a lost permission shows up as an alert.
        defer {
            if let url = (try? state.meta("pushgateway")) ?? nil {
                report.duration = Date().timeIntervalSince(started)
                report.now = Date()
                if let body = try? metricsText(state: state, report: report),
                   case .failure(let error) = Pushgateway.push(body, to: url, instance: metricsInstance) {
                    log("metrics push failed: \(error.message)")
                }
            }
        }
        let chat = try ChatDB()
        // Set by the launch agent plist: probing from a terminal would grant the terminal instead.
        if ProcessInfo.processInfo.environment["TEXTSTOP_AGENT"] == "1", try state.meta("automation_ok") == nil {
            switch Sender.probeAutomation() {
            case .success:
                try state.setMeta("automation_ok", "1")
                log("Automation permission for Messages: ok")
            case .failure(let error):
                log("Automation permission for Messages: NOT granted (\(error.message))")
            }
        }
        let summary = try runOnce(chat: chat, state: state, log: log)
        report = RunReport(success: true, processed: summary.processed, contacts: summary.contacts)
        if summary.processed > 0 || summary.spamReportSteps > 0 {
            log("processed \(summary.processed): would_send=\(summary.wouldSend) sent=\(summary.sent) report=\(summary.reported) capped=\(summary.capped)")
        }

    case "status":
        let state = try State()
        print("mode:      \(state.isLive ? "LIVE" : "dry-run")")
        print("cloud:     \(state.cloudEnabled ? "on" : "off")")
        print("no-optout: \(state.allowWithoutOptOut ? "on" : "off")")
        print("first run: \(state.firstRun.map(stamp) ?? "not yet")")
        for (action, count) in try state.actionCounts() { print("  \(action): \(count)") }
        print("sends in last 24h: \(try state.sendsToday()) of \(dailySendCap)")
        for send in try state.recentSends(limit: 10) { print("  \(stamp(send.at)) \(send.handle) \(send.status)") }

    case "log":
        let state = try State()
        let limit = positional.dropFirst().first.flatMap(Int.init) ?? 30
        for row in try state.decisions(limit: limit, action: flags.contains("--stop") ? .replyStop : nil) {
            print("\(stamp(row.at)) \(row.action) [\(row.category)] \(row.handle) (\(row.service)): \(row.reason)\n    \(row.preview)")
        }

    case "report":
        let state = try State()
        let limit = positional.dropFirst().first.flatMap(Int.init) ?? 30
        print("Likely scams. To report: use Report Junk in Messages, or forward to 7726 (SPAM) from your iPhone.\n")
        for row in try state.decisions(limit: limit, action: .report) {
            print("\(stamp(row.at)) \(row.handle) (\(row.service)): \(row.reason)\n    \(row.preview)")
        }

    case "doctor":
        let chat = try ChatDB()
        print("chat.db: readable")
        let contacts = try ContactBook.loadFromDisk()
        print("contacts: \(contacts.count) numbers/addresses\(contacts.count == 0 ? "  <- PROBLEM: tool refuses to run" : "")")
        let health = try chat.health()
        for service in health.serviceCounts.sorted(by: { $0.count > $1.count }) {
            print("service \(service.service): \(service.count) messages, newest \(service.newest.map(stamp) ?? "-")")
        }
        let sms = health.serviceCounts.first { $0.service == "SMS" || $0.service == "RCS" }
        if let newest = sms?.newest {
            print("forwarding: SMS has reached this Mac (newest \(stamp(newest)))")
        } else {
            print("forwarding: NO SMS rows. Turn on iPhone > Settings > Apps > Messages > Text Message Forwarding")
        }
        print("decoder: \(health.decoderMatches)/\(health.decoderComparable) match the text column; \(health.bodyOnlyDecoded)/\(health.bodyOnly) body-only rows decoded")
        print("api key in Keychain: \(CloudClassifier.apiKey() == nil ? "no" : "yes")")

    case "backtest":
        let days = positional.dropFirst().first.flatMap(Double.init) ?? 90
        let chat = try ChatDB()
        let contacts = try ContactBook.loadFromDisk()
        guard contacts.count > 0 else { throw RunError.noContacts }
        var counts: [String: Int] = [:]
        // Age is judged against each message's own time so old messages evaluate as if they just arrived.
        for message in try chat.incoming(since: Date().addingTimeInterval(-days * 86_400)) {
            let context = PolicyContext(
                isContact: contacts.contains(handle: message.handle),
                hasMessagedSender: try chat.hasMessaged(handle: message.handle),
                lastStopSent: nil,
                now: message.date
            )
            let decision = decide(message, context)
            let key = "\(decision.action.rawValue) [\(decision.category?.rawValue ?? "-")]"
            counts[key, default: 0] += 1
            if flags.contains("--show"), decision.action != .ignore {
                print("\(stamp(message.date)) \(key) \(message.handle) (\(message.service)): \(decision.reason)\n    \(redactedPreview(message.text, category: decision.category))")
            }
        }
        print("last \(Int(days)) days:")
        for (key, count) in counts.sorted(by: { $0.value > $1.value }) { print("  \(key): \(count)") }

    case "test-send":
        guard positional.count >= 2 else { fail(usage) }
        let handle = positional[1]
        let text = positional.count > 2 ? positional[2...].joined(separator: " ") : "HELP"
        guard isReplyableSender(handle) else { fail("\(handle) isn't a phone number or short code") }
        guard isatty(STDIN_FILENO) == 1 else { fail("test-send needs an interactive terminal") }
        print("This sends a real text: \"\(text)\" to \(handle). Standard message rates may apply.\nType SEND to continue: ", terminator: "")
        guard readLine() == "SEND" else { fail("cancelled") }
        let chat = try ChatDB()
        print(deliver(text, to: handle, chatGUID: try chat.chatGUID(handle: handle), chat: chat, wait: 30))

    case "go-live":
        let state = try State()
        guard let first = state.firstRun else { fail("No dry-run yet. Install the agent first.") }
        let elapsed = Date().timeIntervalSince(first) / 86_400
        if elapsed < Double(dryRunDays) && !flags.contains("--force") {
            fail(String(format: "Only %.1f of %d dry-run days so far. Review `textstop log --stop`, or pass --force.", elapsed, dryRunDays))
        }
        try state.setMeta("mode", "live")
        print("LIVE: real STOP replies are on. Undo with `textstop dry-run`.")

    case "dry-run":
        try State().setMeta("mode", "dry-run")
        print("dry-run: no real replies will be sent.")

    case "cloud":
        let state = try State()
        switch positional.dropFirst().first {
        case "on":
            guard CloudClassifier.apiKey() != nil else {
                fail("No API key. Add one: security add-generic-password -s \(CloudClassifier.keychainService) -a textstop -T /usr/bin/security -w")
            }
            try state.setMeta("cloud", "on")
        case "off":
            try state.setMeta("cloud", "off")
        default:
            fail(usage)
        }
        print("cloud: \(state.cloudEnabled ? "on" : "off")")

    case "metrics":
        let state = try State()
        switch positional.dropFirst().first {
        case "off"?:
            try state.deleteMeta("pushgateway")
            print("metrics: off")
        case let url?:
            let body = try metricsText(state: state, report: nil)
            switch Pushgateway.push(body, to: url, instance: metricsInstance) {
            case .success:
                try state.setMeta("pushgateway", url)
                print("metrics: pushing to \(url) each run (test push ok)")
            case .failure(let error):
                fail("test push to \(url) failed: \(error.message). Not saved.")
            }
        case nil:
            print(try state.meta("pushgateway").map { "metrics: \($0)" } ?? "metrics: off")
            print(try metricsText(state: state, report: nil), terminator: "")
        }

    case "spam-report":
        let state = try State()
        switch positional.dropFirst().first {
        case "on"?: try state.setMeta("spam_report", "on")
        case "off"?: try state.setMeta("spam_report", "off")
        case "backfill"?:
            let hours = positional.dropFirst(2).first.flatMap(Double.init) ?? 24
            var queued = 0
            for item in try state.recentStoppedMessages(since: Date().addingTimeInterval(-hours * 3600)) {
                if try state.queueSpamReport(handle: item.handle, rowID: item.rowID) { queued += 1 }
            }
            print("queued \(queued) for \(spamReportHandle); the agent sends them one at a time")
        case nil: break
        default: fail(usage)
        }
        print("spam-report: \(state.spamReporting ? "on" : "off")")
        for (status, count) in try state.spamReportCounts() { print("  \(status): \(count)") }

    case "no-optout":
        guard let value = positional.dropFirst().first, ["on", "off"].contains(value) else { fail(usage) }
        try State().setMeta("no_optout", value)
        print("no-optout: \(value)")

    default:
        print(usage)
    }
} catch {
    fail("error: \(error)")
}
