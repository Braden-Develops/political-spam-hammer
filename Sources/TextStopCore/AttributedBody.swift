import Foundation

/// Extracts the plain string from a `message.attributedBody` typedstream blob.
///
/// Deliberately a small byte parser rather than `NSUnarchiver`: the blob's contents derive from
/// messages sent by strangers, and NSUnarchiver instantiates arbitrary classes while decoding.
///
/// Layout after the first "NSString" class name: 5 bytes of class/object tags ending in `+`
/// (0x2B, the typedstream C-string type), then a length, then UTF-8 bytes. The length is one byte
/// below 0x81, 0x81 followed by a little-endian UInt16, or 0x82 followed by a little-endian UInt32.
public func decodeAttributedBody(_ blob: Data) -> String? {
    let bytes = [UInt8](blob)
    let marker = Array("NSString".utf8)
    guard let markerStart = firstIndex(of: marker, in: bytes) else { return nil }

    // Scan a short window for the `+` tag rather than assuming exactly 5 bytes.
    var i = markerStart + marker.count
    let windowEnd = min(i + 12, bytes.count)
    while i < windowEnd, bytes[i] != 0x2B { i += 1 }
    guard i < windowEnd else { return nil }
    i += 1

    guard i < bytes.count else { return nil }
    let length: Int
    switch bytes[i] {
    case 0x81:
        guard i + 2 < bytes.count else { return nil }
        length = Int(bytes[i + 1]) | Int(bytes[i + 2]) << 8
        i += 3
    case 0x82:
        guard i + 4 < bytes.count else { return nil }
        length = Int(bytes[i + 1]) | Int(bytes[i + 2]) << 8 | Int(bytes[i + 3]) << 16 | Int(bytes[i + 4]) << 24
        i += 5
    default:
        length = Int(bytes[i])
        i += 1
    }
    guard length > 0, i + length <= bytes.count else { return nil }
    return String(bytes: bytes[i..<(i + length)], encoding: .utf8)
}

private func firstIndex(of needle: [UInt8], in haystack: [UInt8]) -> Int? {
    guard haystack.count >= needle.count else { return nil }
    for start in 0...(haystack.count - needle.count) where haystack[start] == needle[0] {
        if Array(haystack[start..<(start + needle.count)]) == needle { return start }
    }
    return nil
}
