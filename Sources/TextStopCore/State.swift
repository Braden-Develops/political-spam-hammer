import Foundation

/// The tool's own state, the only database it writes to.
public final class State {
    private let db: Database

    public struct DecisionRow {
        public let at: Date
        public let handle: String
        public let service: String
        public let action: String
        public let category: String
        public let reason: String
        public let preview: String
    }

    public static var defaultDirectory: String {
        NSHomeDirectory() + "/Library/Application Support/textstop"
    }

    public init(directory: String = State.defaultDirectory) throws {
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        db = try Database(path: directory + "/state.db", readOnly: false)
        try db.query("CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT NOT NULL)")
        try db.query("""
            CREATE TABLE IF NOT EXISTS decisions (
                message_rowid INTEGER PRIMARY KEY, at REAL NOT NULL, handle TEXT NOT NULL, service TEXT NOT NULL,
                action TEXT NOT NULL, category TEXT NOT NULL, reason TEXT NOT NULL, preview TEXT NOT NULL,
                dry_run INTEGER NOT NULL)
            """)
        try db.query("""
            CREATE TABLE IF NOT EXISTS sends (
                id INTEGER PRIMARY KEY, at REAL NOT NULL, handle TEXT NOT NULL, message_rowid INTEGER,
                status TEXT NOT NULL)
            """)
        try db.query("""
            CREATE TABLE IF NOT EXISTS spam_reports (
                id INTEGER PRIMARY KEY, handle TEXT NOT NULL, message_rowid INTEGER NOT NULL UNIQUE,
                status TEXT NOT NULL, queued_at REAL NOT NULL, forwarded_at REAL, watermark INTEGER, done_at REAL)
            """)
    }

    public func meta(_ key: String) throws -> String? {
        try db.query("SELECT value FROM meta WHERE key = ?", [.text(key)]).first?[0].text
    }

    public func setMeta(_ key: String, _ value: String) throws {
        try db.query("INSERT OR REPLACE INTO meta (key, value) VALUES (?, ?)", [.text(key), .text(value)])
    }

    public func deleteMeta(_ key: String) throws {
        try db.query("DELETE FROM meta WHERE key = ?", [.text(key)])
    }

    public var isLive: Bool { (try? meta("mode")) == "live" }
    public var cloudEnabled: Bool { (try? meta("cloud")) == "on" }
    public var allowWithoutOptOut: Bool { (try? meta("no_optout")) == "on" }
    public var spamReporting: Bool { (try? meta("spam_report")) == "on" }

    public struct SpamReport {
        public let id: Int64
        public let handle: String
        public let messageRowID: Int64
        public let forwardedAt: Date
        public let watermark: Int64
    }

    /// Queues a message for 7726. Returns false if it was already queued.
    @discardableResult
    public func queueSpamReport(handle: String, rowID: Int64, now: Date = Date()) throws -> Bool {
        let before = try db.query("SELECT COUNT(*) FROM spam_reports").first?[0].int ?? 0
        try db.query("INSERT OR IGNORE INTO spam_reports (handle, message_rowid, status, queued_at) VALUES (?, ?, 'queued', ?)",
                     [.text(handle), .int(rowID), .real(now.timeIntervalSince1970)])
        return (try db.query("SELECT COUNT(*) FROM spam_reports").first?[0].int ?? 0) > before
    }

    private func spamReport(_ row: [SQLValue]) -> SpamReport {
        SpamReport(id: row[0].int ?? 0, handle: row[1].text ?? "", messageRowID: row[2].int ?? 0,
                   forwardedAt: Date(timeIntervalSince1970: row[3].asDouble), watermark: row[4].int ?? 0)
    }

    public func activeSpamReport() throws -> SpamReport? {
        try db.query("SELECT id, handle, message_rowid, forwarded_at, watermark FROM spam_reports WHERE status = 'forwarded' ORDER BY id LIMIT 1")
            .first.map(spamReport)
    }

    public func nextQueuedSpamReport() throws -> SpamReport? {
        try db.query("SELECT id, handle, message_rowid, 0, 0 FROM spam_reports WHERE status = 'queued' ORDER BY id LIMIT 1")
            .first.map(spamReport)
    }

    public func markSpamReportForwarded(id: Int64, watermark: Int64, now: Date = Date()) throws {
        try db.query("UPDATE spam_reports SET status = 'forwarded', forwarded_at = ?, watermark = ? WHERE id = ?",
                     [.real(now.timeIntervalSince1970), .int(watermark), .int(id)])
    }

    public func updateSpamReport(id: Int64, status: String, now: Date = Date()) throws {
        try db.query("UPDATE spam_reports SET status = ?, done_at = ? WHERE id = ?",
                     [.text(status), .real(now.timeIntervalSince1970), .int(id)])
    }

    public func spamReportCounts() throws -> [(status: String, count: Int64)] {
        try db.query("SELECT status, COUNT(*) FROM spam_reports GROUP BY 1 ORDER BY 1").map { ($0[0].text ?? "", $0[1].int ?? 0) }
    }

    /// STOPs that went out recently, for queueing reports after turning reporting on.
    public func recentStoppedMessages(since: Date) throws -> [(handle: String, rowID: Int64)] {
        try db.query("SELECT handle, message_rowid FROM sends WHERE at >= ? AND message_rowid IS NOT NULL AND status NOT LIKE 'script_failed%' AND status NOT LIKE 'failed%' ORDER BY id",
                     [.real(since.timeIntervalSince1970)]).map { ($0[0].text ?? "", $0[1].int ?? 0) }
    }

    public var firstRun: Date? {
        (try? meta("first_run")).flatMap { $0 }.flatMap(Double.init).map(Date.init(timeIntervalSince1970:))
    }

    public func record(_ message: Incoming, _ decision: Decision, dryRun: Bool, storeText: Bool = true, now: Date = Date()) throws {
        try db.query("INSERT OR REPLACE INTO decisions VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)", [
            .int(message.rowID), .real(now.timeIntervalSince1970), .text(message.handle), .text(message.service),
            .text(decision.action.rawValue), .text(decision.category?.rawValue ?? "-"), .text(decision.reason),
            .text(storeText ? redactedPreview(message.text, category: decision.category) : "[not stored]"), .int(dryRun ? 1 : 0),
        ])
    }

    public func decisions(limit: Int, action: Action? = nil) throws -> [DecisionRow] {
        let filter = action == nil ? "" : "WHERE action = ?"
        let params: [SQLValue] = (action.map { [.text($0.rawValue)] } ?? []) + [.int(Int64(limit))]
        return try db.query("""
            SELECT at, handle, service, action, category, reason, preview FROM decisions \(filter)
            ORDER BY message_rowid DESC LIMIT ?
            """, params).map { row in
            DecisionRow(at: Date(timeIntervalSince1970: row[0].asDouble),
                        handle: row[1].text ?? "", service: row[2].text ?? "", action: row[3].text ?? "",
                        category: row[4].text ?? "", reason: row[5].text ?? "", preview: row[6].text ?? "")
        }
    }

    public func actionCounts() throws -> [(String, Int64)] {
        try db.query("SELECT action, COUNT(*) FROM decisions GROUP BY action ORDER BY 2 DESC")
            .map { ($0[0].text ?? "", $0[1].int ?? 0) }
    }

    public func decisionCounts() throws -> [(action: String, category: String, dryRun: Bool, count: Int64)] {
        try db.query("SELECT action, category, dry_run, COUNT(*) FROM decisions GROUP BY 1, 2, 3 ORDER BY 1, 2, 3").map {
            ($0[0].text ?? "", $0[1].text ?? "", ($0[2].int ?? 0) != 0, $0[3].int ?? 0)
        }
    }

    /// Statuses are free text from the send path; fold them into a few stable label values.
    public func sendCounts() throws -> [(result: String, count: Int64)] {
        var counts: [String: Int64] = [:]
        for row in try db.query("SELECT status FROM sends") {
            counts[sendResult(row[0].text ?? ""), default: 0] += 1
        }
        return counts.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
    }

    /// Written before the send is attempted, so a crash mid-send can't cause a second STOP.
    @discardableResult
    public func beginSend(handle: String, rowID: Int64?, now: Date = Date()) throws -> Int64 {
        let rows = try db.query("INSERT INTO sends (at, handle, message_rowid, status) VALUES (?, ?, ?, 'attempted') RETURNING id",
                                [.real(now.timeIntervalSince1970), .text(handle), rowID.map { .int($0) } ?? .null])
        return rows.first?[0].int ?? 0
    }

    public func finishSend(id: Int64, status: String) throws {
        try db.query("UPDATE sends SET status = ? WHERE id = ?", [.text(status), .int(id)])
    }

    public func lastSend(handle: String) throws -> Date? {
        try db.query("SELECT MAX(at) FROM sends WHERE handle = ?", [.text(handle)])
            .first?[0].asOptionalDouble.map(Date.init(timeIntervalSince1970:))
    }

    public func sendsToday(now: Date = Date()) throws -> Int {
        let cutoff = now.timeIntervalSince1970 - 86_400
        return Int(try db.query("SELECT COUNT(*) FROM sends WHERE at >= ?", [.real(cutoff)])
            .first?[0].int ?? 0)
    }

    public func recentSends(limit: Int) throws -> [(at: Date, handle: String, status: String)] {
        try db.query("SELECT at, handle, status FROM sends ORDER BY id DESC LIMIT ?", [.int(Int64(limit))]).map {
            (Date(timeIntervalSince1970: $0[0].asDouble), $0[1].text ?? "", $0[2].text ?? "")
        }
    }
}

func sendResult(_ status: String) -> String {
    let s = status.lowercased()
    if s.hasPrefix("script_failed") { return "script_failed" }
    if s.contains("failed") || s.contains("error=") && !s.contains("error=0") { return "failed" }
    if s.contains("delivered=1") || s.hasPrefix("delivered") { return "delivered" }
    if s.contains("sent") { return "sent" }
    if s == "attempted" { return "attempted" }
    return "unconfirmed"
}

extension SQLValue {
    var asOptionalDouble: Double? {
        switch self {
        case .int(let v): return Double(v)
        case .text(let v): return Double(v)
        case .real(let v): return v
        default: return nil
        }
    }
    var asDouble: Double { asOptionalDouble ?? 0 }
}
