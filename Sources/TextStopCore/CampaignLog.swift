import Foundation

/// Who is behind a run of political texts, and how we know.
public struct Campaign: Equatable {
    public let name: String
    /// "unsubscribe confirmation", "paid for by" or "sign-off": most to least reliable.
    public let source: String

    public init(name: String, source: String) {
        self.name = name
        self.source = source
    }
}

private func firstMatch(_ pattern: String, in text: String, caseSensitive: Bool = false) -> String? {
    guard let regex = try? NSRegularExpression(pattern: pattern, options: caseSensitive ? [] : [.caseInsensitive]),
          let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
          match.numberOfRanges > 1, let range = Range(match.range(at: 1), in: text) else { return nil }
    let name = text[range].trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ".,!:;-\"'")))
    return name.count >= 3 && name.count <= 80 ? name : nil
}

private let unsubscribePatterns = [
    #"unsubscribed from ([^.!\n]+?)(?:\s+(?:texts|messages|alerts|sms))?(?:[.!\n]|$)"#,
    #"no longer receive (?:texts|messages|text messages|alerts) from ([^.!\n]+)"#,
    #"opted out of ([^.!\n]+?)(?:\s+(?:texts|messages|alerts))?(?:[.!\n]|$)"#,
]

/// The sender's own "you've been unsubscribed" reply: evidence of who they are, not a political text.
public func isUnsubscribeConfirmation(_ text: String) -> Bool {
    unsubscribePatterns.contains { firstMatch($0, in: text) != nil }
}

/// Looks through everything one sender sent, most reliable evidence first: the committee's own name in
/// its unsubscribe confirmation, then the legal disclaimer, then who the text says it's from, then the
/// short sign-off P2P texts put above "Stop2End" (often an abbreviation like "DSCC" or "RAA").
public func extractCampaign(from texts: [String]) -> Campaign? {
    let tiers: [(source: String, caseSensitive: Bool, patterns: [String])] = [
        ("unsubscribe confirmation", false, unsubscribePatterns),
        ("paid for by", false, [
            #"(?:paid|pd\.?) (?:for )?by:? ([^.\n(]+?)(?:\s*[.(\n]|\s+and not authorized|,\s*not authorized|$)"#,
        ]),
        ("named in text", true, [
            #"\b(?:[Tt]his is|[Ii]t'?s) [A-Z][a-z]+ (?:with|from|at) ((?:the )?[A-Z][^.,!?\n]{2,60})"#,
            #"^(?:[Hh]i,? )?(?:[Ii]t'?s|[Tt]his is) ([A-Z][a-z]+ (?:[A-Z]\. )?[A-Z][a-z]+)\b"#,
            #"^([A-Z][a-z]+ [A-Z][a-z]+) here\b"#,
        ]),
        ("sign-off", false, [
            #"\n[ \t]*([^\n]{2,40}?)[ \t]*\n(?:[ \t]*\n)*[ \t]*(?:stop2end|stop to end|txt stop to end|reply stop to (?:end|quit|opt out))\b[^\n]*\s*$"#,
        ]),
    ]
    for tier in tiers {
        for pattern in tier.patterns {
            for text in texts {
                if let name = firstMatch(pattern, in: text, caseSensitive: tier.caseSensitive), !name.contains("://"),
                   name.range(of: #"\.[a-z]{2,}/"#, options: .regularExpression) == nil {
                    return Campaign(name: name, source: tier.source)
                }
            }
        }
    }
    return nil
}

/// "t.stopgopfund.org/abc" -> "stopgopfund.org": tracking subdomains vary, the domain doesn't.
public func rootDomain(_ hostAndPath: String) -> String {
    let host = hostAndPath.split(separator: "/").first.map(String.init) ?? hostAndPath
    return host.split(separator: ".").suffix(2).joined(separator: ".")
}

/// Hostnames of links in a text: donation pages (ActBlue, WinRed, Anedot) often name the committee.
public func linkHosts(_ text: String) -> [String] {
    guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return [] }
    let urls = detector.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap(\.url)
    var seen = Set<String>()
    return urls.compactMap { url in
        let shown = (url.host ?? "") + (url.path.isEmpty || url.path == "/" ? "" : url.path)
        return shown.isEmpty || !seen.insert(shown).inserted ? nil : shown
    }
}

public func csvField(_ value: String) -> String {
    // A leading = + - @ would run as a formula in a spreadsheet.
    var v = value
    if let first = v.first, "=+-@".contains(first) { v = "'" + v }
    return "\"" + v.replacingOccurrences(of: "\"", with: "\"\"") + "\""
}
