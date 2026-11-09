import Foundation

public enum TextCategory: String, Codable {
    case verification, transactional, scam, political, marketing, unclear
}

public struct Classification: Equatable {
    public let category: TextCategory
    public let hasOptOut: Bool
    public let reason: String
}

/// Keyword classifier. Order matters: anything that must never get a reply is checked first, so a
/// message that looks like both a pharmacy alert and a promotion is treated as the alert.
public func classify(_ text: String) -> Classification {
    // ICU's \b doesn't break inside "trump's", so drop possessives before matching.
    let t = text.lowercased()
        .replacingOccurrences(of: "\u{2019}", with: "'")
        .replacingOccurrences(of: #"(?<=[a-z])'s(?![a-z])"#, with: "", options: .regularExpression)
    let optOut = matches(t, optOutPatterns) != nil

    if let hit = matches(t, verificationPatterns) {
        return Classification(category: .verification, hasOptOut: optOut, reason: hit)
    }
    if let hit = matches(t, scamPatterns) {
        return Classification(category: .scam, hasOptOut: optOut, reason: hit)
    }
    if let hit = matches(t, transactionalPatterns) {
        return Classification(category: .transactional, hasOptOut: optOut, reason: hit)
    }
    if let hit = matches(t, politicalPatterns) {
        return Classification(category: .political, hasOptOut: optOut, reason: hit)
    }
    if let hit = matches(t, marketingPatterns) {
        return Classification(category: .marketing, hasOptOut: optOut, reason: hit)
    }
    return Classification(category: .unclear, hasOptOut: optOut, reason: "no keyword match")
}

private func matches(_ text: String, _ patterns: [String]) -> String? {
    patterns.first { text.range(of: $0, options: .regularExpression) != nil }
}

let optOutPatterns = [
    #"\b(reply|text|txt|send|respond)\b[^.!?\n]{0,20}\b(stop|quit|end|cancel|unsubscribe)\b"#,
    #"\bstop\s*(2|to|=|-)\s*(end|quit|opt|unsub|cancel|stop)"#,
    #"\b(stop|end)\s+to\s+(end|quit|opt|unsubscribe|cancel)"#,
    #"\bopt[- ]?out\b"#,
    #"\bunsubscribe\b"#,
]

let verificationPatterns = [
    #"\b(verification|security|login|log-in|sign-in|access|authentication|confirmation|one[- ]time|2fa|otp)\b[^.\n]{0,30}\b(code|pin|passcode|password)\b"#,
    #"\b(code|pin|passcode)\b[^.\n]{0,15}\b(is|:)\s*[a-z]?-?\d{4,8}\b"#,
    #"\b\d{4,8}\b[^.\n]{0,20}\b(is your|verification|security code|login code)\b"#,
    #"\b(do not|don't|never) share (this|your|the) (code|pin)\b"#,
    #"^\s*<#>"#,
]

/// A reply confirms the number is live, so these are never answered. Checked before opt-out
/// language counts for anything, because scams often include a fake "reply STOP" footer.
let scamPatterns = [
    #"\b(usps|fedex|ups|dhl)\b[^\n]{0,60}\b(failed|unable|held|hold|redeliver|address|suspended|incomplete)\b"#,
    #"\b(package|parcel|delivery)\b[^\n]{0,60}\b(failed|unable to deliver|redeliver|update your address|held)\b"#,
    #"\b(unpaid|outstanding|overdue)\b[^\n]{0,30}\b(toll|tolls|ticket|citation|fine)\b"#,
    #"\b(toll|e-?z ?pass|fastrak|sunpass|dmv)\b[^\n]{0,60}\b(unpaid|outstanding|overdue|pay|penalt|suspen)"#,
    #"\b(account|card|access|profile|apple id|icloud)\b[^\n]{0,40}\b(suspended|locked|compromised|restricted|disabled|deactivated)\b"#,
    #"\b(suspicious|unauthorized|unusual)\b[^\n]{0,20}\b(activity|login|charge|transaction|purchase|sign-?in)\b"#,
    #"\b(you('ve| have)? won|you are (a |the )?winner|claim your (prize|reward|gift)|congratulations[^\n]{0,30}(selected|winner|won))\b"#,
    #"\bgift ?cards?\b[^\n]{0,30}\b(buy|purchase|send|code)\b"#,
    #"\b(crypto|bitcoin|usdt|forex)\b[^\n]{0,60}\b(invest|profit|returns?|earn|trading|mentor)\b"#,
    #"\b(work from home|remote job|part[- ]time job)\b[^\n]{0,60}\$\s?\d"#,
    #"\b(whatsapp|telegram)\b[^\n]{0,40}\b(contact|message|add|join|chat)\b"#,
    #"\b(student loan|debt relief|tax refund|irs|forgiveness)\b[^\n]{0,60}\b(eligible|approved|claim|final notice|act now)\b"#,
    #"\b(final notice|last warning|act immediately|legal action)\b"#,
    #"https?://\d{1,3}(\.\d{1,3}){3}"#,
    #"\b[a-z0-9-]+\.(top|xyz|icu|click|cfd|sbs|buzz|rest|vip|live)\b(/|\s|$)"#,
    #"^\s*(hi|hello|hey)\b[^\n]{0,30}\b(is this|are you|long time|how have you been)\b"#,
    #"\b(wrong number|sorry to bother)\b"#,
]

/// Real notifications from services the user relies on; STOP here could silence something useful.
let transactionalPatterns = [
    #"\b(appointment|appt)\b[^\n]{0,60}\b(confirm|remind|scheduled|tomorrow|today|at \d)"#,
    #"\b(prescription|refill|rx|pharmacy|lab results?|patient portal)\b"#,
    #"\b(your )?(order|package|shipment|delivery)\b[^\n]{0,40}\b(shipped|out for delivery|delivered|arriving|on its way|tracking)\b"#,
    #"\b(fraud alert|balance|low balance|deposit|withdrawal|payment (due|received|posted|confirmation)|autopay|statement)\b"#,
    #"\b(flight|boarding|gate|check-?in|reservation|booking)\b[^\n]{0,40}\b(confirm|delayed|cancel|change|ready|now open|reminder)"#,
    #"\b(outage|school closure|emergency alert|weather alert|amber alert)\b"#,
    #"\b(your (ride|driver|table|food)|is arriving|ready for pickup)\b"#,
    #"\b(track (your )?order|scheduled for delivery|headed to the store|your shopper)\b"#,
]

let politicalPatterns = [
    #"\b(donate|chip in|contribute|rush)\b[^\n]{0,60}\b(campaign|election|senate|congress|maga|democrats?|republicans?|gop|dnc|rnc|trump|biden|harris|vance|fight)\b"#,
    #"\b(paid for by|authorized by)\b[^\n]{0,60}\b(committee|campaign|pac|for (senate|congress|president|governor|america)|party|action fund)\b"#,
    #"\b(election day|early voting|polling (place|location)|vote (for|by|early|yes|no)|ballots?|voters?|your vote|every vote|get out the vote)\b"#,
    #"\b(democrats?|republicans?|gop|dnc|rnc|nrsc|dscc|dccc|nrcc|maga|super pac|actblue|winred)\b"#,
    #"\b(senator|congressman|congresswoman|candidate|midterms?|presidential)\b"#,
    #"\b(trump|biden|harris|vance|obama|pelosi|schumer|mcconnell|newsom|desantis|hegseth|aoc)\b"#,
    #"maga\b"#,
    // Peer-to-peer texting platforms used for political and advocacy outreach sign off this way.
    #"\bstop2end\b"#,
    #"(?<!reply )(?<!text )(?<!txt )(?<!send )\bstop to end\s*$"#,
    #"\b(add your name|sign (the|our|this) petition|force (his|her|their) resignation)\b"#,
]

let marketingPatterns = [
    #"\b\d{1,2}\s?% off\b"#,
    #"\b(sale|promo|promotion|discount|coupon|deal|deals|clearance|bogo|free shipping|limited time|flash sale|shop now|exclusive offer|new arrivals|members? only|rewards? points?|use code|save \$?\d)\b"#,
    #"\bmsg ?(&|and) ?data rates\b"#,
    #"\bmsg ?frq\b|\bmessage frequency\b"#,
]
