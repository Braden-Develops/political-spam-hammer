import Foundation

/// Reads the AddressBook databases directly, read-only, so the tool doesn't need the separate
/// Contacts permission on top of Full Disk Access.
public struct ContactBook {
    private let phoneKeys: Set<String>
    private let emails: Set<String>

    public var count: Int { phoneKeys.count + emails.count }

    public init(phones: [String], emails: [String]) {
        phoneKeys = Set(phones.compactMap(ContactBook.phoneKey))
        self.emails = Set(emails.map { $0.lowercased() })
    }

    public static func loadFromDisk() throws -> ContactBook {
        let root = NSHomeDirectory() + "/Library/Application Support/AddressBook"
        var paths = [root + "/AddressBook-v22.abcddb"]
        let sources = root + "/Sources"
        for source in (try? FileManager.default.contentsOfDirectory(atPath: sources)) ?? [] {
            paths.append("\(sources)/\(source)/AddressBook-v22.abcddb")
        }

        var phones: [String] = []
        var emails: [String] = []
        for path in paths where FileManager.default.fileExists(atPath: path) {
            let db = try Database(path: path, readOnly: true)
            phones += try db.query("SELECT ZFULLNUMBER FROM ZABCDPHONENUMBER WHERE ZFULLNUMBER IS NOT NULL")
                .compactMap { $0[0].text }
            emails += try db.query("SELECT ZADDRESSNORMALIZED FROM ZABCDEMAILADDRESS WHERE ZADDRESSNORMALIZED IS NOT NULL")
                .compactMap { $0[0].text }
        }
        return ContactBook(phones: phones, emails: emails)
    }

    public func contains(handle: String) -> Bool {
        if handle.contains("@") { return emails.contains(handle.lowercased()) }
        guard let key = ContactBook.phoneKey(handle) else { return false }
        return phoneKeys.contains(key)
    }

    /// Last 9 digits, so "+44 7700 900123" and "07700 900123" collide. The occasional false match
    /// only means the tool skips a sender, which is the safe direction.
    static func phoneKey(_ raw: String) -> String? {
        let digits = raw.filter(\.isNumber)
        guard !digits.isEmpty else { return nil }
        return String(digits.suffix(9))
    }
}
