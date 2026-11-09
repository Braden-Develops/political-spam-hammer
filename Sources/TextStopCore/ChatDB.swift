import Foundation

/// Read-only view of ~/Library/Messages/chat.db.
public final class ChatDB {
    private let db: Database
    private static let appleEpoch = 978_307_200.0

    public init(path: String = NSHomeDirectory() + "/Library/Messages/chat.db") throws {
        db = try Database(path: path, readOnly: true)
    }

    public func maxRowID() throws -> Int64 {
        try db.query("SELECT COALESCE(MAX(ROWID), 0) FROM message").first?[0].int ?? 0
    }

    /// Incoming, non-tapback messages after `rowID`. A chat that isn't 1:1 (style 45) reports 99
    /// participants and a message with no chat reports 0, so both fail the 1:1 check in `decide`.
    public func incoming(after rowID: Int64, limit: Int = 500) throws -> [Incoming] {
        try incoming(where: "m.ROWID > ?", [.int(rowID)], order: "m.ROWID ASC", limit: limit)
    }

    public func incoming(from handle: String, after rowID: Int64) throws -> [Incoming] {
        try incoming(where: "m.ROWID > ? AND h.id = ?", [.int(rowID), .text(handle)], order: "m.ROWID ASC", limit: 50)
    }

    /// Full text of one message, for forwarding spam to the carrier. Never stored.
    public func messageText(rowID: Int64) throws -> String? {
        guard let row = try db.query("SELECT text, attributedBody FROM message WHERE ROWID = ?", [.int(rowID)]).first
        else { return nil }
        return row[0].text ?? row[1].blob.flatMap(decodeAttributedBody)
    }

    public func incoming(since date: Date) throws -> [Incoming] {
        let raw = Int64((date.timeIntervalSince1970 - ChatDB.appleEpoch) * 1e9)
        return try incoming(where: "m.date >= ?", [.int(raw)], order: "m.ROWID ASC", limit: 100_000)
    }

    private func incoming(where clause: String, _ params: [SQLValue], order: String, limit: Int) throws -> [Incoming] {
        let rows = try db.query("""
            SELECT m.ROWID, h.id, m.service, m.text, m.attributedBody, m.date, m.is_spam, c.guid,
                   CASE WHEN c.ROWID IS NULL THEN 0
                        WHEN c.style != 45 THEN 99
                        ELSE (SELECT COUNT(*) FROM chat_handle_join j WHERE j.chat_id = c.ROWID) END
            FROM message m
            JOIN handle h ON h.ROWID = m.handle_id
            LEFT JOIN chat_message_join cm ON cm.message_id = m.ROWID
            LEFT JOIN chat c ON c.ROWID = cm.chat_id
            WHERE \(clause) AND m.is_from_me = 0 AND m.item_type = 0
              AND m.associated_message_type = 0 AND m.is_system_message = 0
            GROUP BY m.ROWID
            ORDER BY \(order)
            LIMIT ?
            """, params + [.int(Int64(limit))])

        return rows.map { row in
            Incoming(
                rowID: row[0].int ?? 0,
                handle: row[1].text ?? "",
                service: row[2].text ?? "",
                chatGUID: row[7].text,
                participantCount: Int(row[8].int ?? 0),
                text: row[3].text ?? row[4].blob.flatMap(decodeAttributedBody),
                date: ChatDB.date(fromRaw: row[5].int ?? 0),
                isSpamFiltered: (row[6].int ?? 0) != 0
            )
        }
    }

    /// True if I've ever sent this sender anything other than a bare STOP/HELP, in any chat with
    /// them. That usually means a real person or a service I use, whatever the message looks like.
    public func hasMessaged(handle: String) throws -> Bool {
        let rows = try db.query("""
            SELECT m.text, m.attributedBody FROM message m
            JOIN chat_message_join cm ON cm.message_id = m.ROWID
            JOIN chat_handle_join j ON j.chat_id = cm.chat_id
            JOIN handle h ON h.ROWID = j.handle_id
            WHERE h.id = ? AND m.is_from_me = 1
            """, [.text(handle)])
        // Sent messages often have only attributedBody. Anything undecodable counts as a conversation.
        return rows.contains { row in
            let text = row[0].text ?? row[1].blob.flatMap(decodeAttributedBody) ?? ""
            return !["STOP", "HELP"].contains(text.trimmingCharacters(in: .whitespacesAndNewlines).uppercased())
        }
    }

    /// The existing 1:1 chat with `handle`, which is the route real replies try first.
    public func chatGUID(handle: String) throws -> String? {
        try db.query("""
            SELECT c.guid FROM chat c
            JOIN chat_handle_join j ON j.chat_id = c.ROWID
            JOIN handle h ON h.ROWID = j.handle_id
            WHERE h.id = ? AND c.style = 45 AND c.service_name != 'iMessage'
            LIMIT 1
            """, [.text(handle)]).first?[0].text
    }

    /// The newest outgoing message to `handle` at or after `date`, for checking a send took effect.
    public func outgoingStatus(handle: String, since date: Date) throws -> (error: Int64, sent: Bool, delivered: Bool)? {
        let raw = Int64((date.timeIntervalSince1970 - ChatDB.appleEpoch) * 1e9)
        guard let row = try db.query("""
            SELECT m.error, m.is_sent, m.is_delivered FROM message m
            JOIN handle h ON h.ROWID = m.handle_id
            WHERE h.id = ? AND m.is_from_me = 1 AND m.date >= ?
            ORDER BY m.ROWID DESC LIMIT 1
            """, [.text(handle), .int(raw)]).first else { return nil }
        return (row[0].int ?? 0, (row[1].int ?? 0) != 0, (row[2].int ?? 0) != 0)
    }

    public struct Health {
        public let serviceCounts: [(service: String, count: Int64, newest: Date?)]
        public let decoderComparable: Int
        public let decoderMatches: Int
        public let bodyOnly: Int
        public let bodyOnlyDecoded: Int
    }

    /// Counts only; never returns message content.
    public func health() throws -> Health {
        let services = try db.query("SELECT COALESCE(service, '?'), COUNT(*), MAX(date) FROM message GROUP BY 1")
            .map { (service: $0[0].text ?? "?", count: $0[1].int ?? 0, newest: $0[2].int.map(ChatDB.date(fromRaw:))) }

        var comparable = 0, matches = 0, bodyOnly = 0, decoded = 0
        for row in try db.query("SELECT text, attributedBody FROM message WHERE attributedBody IS NOT NULL") {
            let result = row[1].blob.flatMap(decodeAttributedBody)
            if let text = row[0].text {
                comparable += 1
                if result == text { matches += 1 }
            } else {
                bodyOnly += 1
                if result != nil { decoded += 1 }
            }
        }
        return Health(serviceCounts: services, decoderComparable: comparable, decoderMatches: matches,
                      bodyOnly: bodyOnly, bodyOnlyDecoded: decoded)
    }

    private static func date(fromRaw raw: Int64) -> Date {
        // Very old rows store seconds rather than nanoseconds.
        let seconds = raw > 1_000_000_000_000 ? Double(raw) / 1e9 : Double(raw)
        return Date(timeIntervalSince1970: seconds + appleEpoch)
    }
}
