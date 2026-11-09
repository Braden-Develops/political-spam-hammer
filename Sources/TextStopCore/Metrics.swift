import Foundation

/// Prometheus exposition text for one run. Counts and states only: never a handle or message text.
public struct RunReport {
    public var success: Bool
    public var processed: Int?
    public var contacts: Int?
    public var duration: TimeInterval
    public var now: Date

    public init(success: Bool, processed: Int? = nil, contacts: Int? = nil, duration: TimeInterval = 0, now: Date = Date()) {
        self.success = success
        self.processed = processed
        self.contacts = contacts
        self.duration = duration
        self.now = now
    }
}

/// `report` is nil for a test push or a preview: no run fields, and `last_success` is left alone.
public func metricsText(state: State?, report: RunReport?) throws -> String {
    var lines: [String] = []
    func metric(_ name: String, _ type: String, _ help: String, _ samples: [(labels: String, value: Double)]) {
        lines.append("# HELP \(name) \(help)")
        lines.append("# TYPE \(name) \(type)")
        for sample in samples {
            let value = sample.value == sample.value.rounded() && abs(sample.value) < 1e15
                ? String(Int64(sample.value)) : String(sample.value)
            lines.append("\(name)\(sample.labels.isEmpty ? "" : "{\(sample.labels)}") \(value)")
        }
    }

    if let report = report {
        metric("textstop_last_run_timestamp_seconds", "gauge", "When the last run finished.", [("", report.now.timeIntervalSince1970)])
        metric("textstop_last_run_success", "gauge", "1 if the last run completed, 0 if it failed (for example lost Full Disk Access).",
               [("", report.success ? 1 : 0)])
        metric("textstop_last_run_duration_seconds", "gauge", "How long the last run took.", [("", report.duration)])
    }

    if let state = state {
        if let report = report, report.success { try state.setMeta("last_success", String(report.now.timeIntervalSince1970)) }
        if let last = try state.meta("last_success").flatMap(Double.init) {
            metric("textstop_last_success_timestamp_seconds", "gauge", "When a run last completed.", [("", last)])
        }
        metric("textstop_live", "gauge", "1 if real STOP replies are on, 0 in dry-run.", [("", state.isLive ? 1 : 0)])
        metric("textstop_cloud_enabled", "gauge", "1 if unclear messages may go to the Claude API.", [("", state.cloudEnabled ? 1 : 0)])
        metric("textstop_decisions_total", "counter", "Messages evaluated, by outcome.",
               try state.decisionCounts().map { ("action=\"\($0.action)\",category=\"\($0.category == "-" ? "none" : $0.category)\",mode=\"\($0.dryRun ? "dry_run" : "live")\"", Double($0.count)) })
        metric("textstop_sends_total", "counter", "STOP and test messages sent, by result.",
               try state.sendCounts().map { ("result=\"\($0.result)\"", Double($0.count)) })
        metric("textstop_sends_last_24h", "gauge", "Sends in the last 24 hours, against the daily cap.", [("", Double(try state.sendsToday()))])
        metric("textstop_spam_reporting_enabled", "gauge", "1 if STOPped texts are reported to 7726.", [("", state.spamReporting ? 1 : 0)])
        metric("textstop_spam_reports_total", "counter", "Reports to the carrier spam line (7726), by status.",
               try state.spamReportCounts().map { ("status=\"\($0.status)\"", Double($0.count)) })
        metric("textstop_daily_send_cap", "gauge", "Maximum sends per 24 hours.", [("", Double(dailySendCap))])
    }
    if let processed = report?.processed {
        metric("textstop_last_run_processed", "gauge", "Messages processed by the last run.", [("", Double(processed))])
    }
    if let contacts = report?.contacts {
        metric("textstop_contacts", "gauge", "Phone numbers and addresses loaded from Contacts.", [("", Double(contacts))])
    }
    return lines.joined(separator: "\n") + "\n"
}

/// Short hostname (e.g. "My-Mac-mini"), a stable Prometheus instance label.
public var metricsInstance: String {
    ProcessInfo.processInfo.hostName.components(separatedBy: ".").first.flatMap { $0.isEmpty ? nil : $0 } ?? "mac"
}

public enum Pushgateway {
    /// Replaces this Mac's group on each push, so stale series don't linger.
    public static func push(_ body: String, to base: String, instance: String, timeout: TimeInterval = 5) -> Result<Void, SendError> {
        let safeInstance = instance.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "mac"
        let trimmed = base.hasSuffix("/") ? String(base.dropLast()) : base
        guard let url = URL(string: "\(trimmed)/metrics/job/textstop/instance/\(safeInstance)"),
              ["http", "https"].contains(url.scheme ?? "") else {
            return .failure(SendError(message: "bad Pushgateway URL: \(base)"))
        }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "PUT"
        request.setValue("text/plain; version=0.0.4", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(body.utf8)

        let done = DispatchSemaphore(value: 0)
        var result: Result<Void, SendError> = .failure(SendError(message: "no response"))
        URLSession.shared.dataTask(with: request) { _, response, error in
            if let error = error {
                result = .failure(SendError(message: error.localizedDescription))
            } else if let code = (response as? HTTPURLResponse)?.statusCode, !(200..<300).contains(code) {
                result = .failure(SendError(message: "HTTP \(code)"))
            } else {
                result = .success(())
            }
            done.signal()
        }.resume()
        done.wait()
        return result
    }
}
