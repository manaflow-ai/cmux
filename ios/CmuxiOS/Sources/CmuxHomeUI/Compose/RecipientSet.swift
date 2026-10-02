import CmuxHomeCore
import Foundation

/// One token in a To: field.
struct Recipient: Hashable, Sendable, Identifiable {
    enum State: Hashable, Sendable {
        /// Not an email address or phone number.
        case invalid
        case resolving
        /// Already on cmux; the DM opens directly.
        case member(Participant)
        /// No account yet; sending invites them.
        case invitable
        /// The lookup failed (for example offline); the owner decides on send.
        case unresolved
    }

    let id: Int
    /// What the person typed.
    let raw: String
    let address: ContactAddress?
    var state: State

    /// The chip's text: the member's name, else the address or raw text.
    var title: String {
        if case .member(let person) = state { return person.displayName }
        return address?.description ?? raw
    }
}

/// The pure state of a To: field: tokens in order, deduped by address.
/// The view model wraps it with lookups; tests drive it directly.
struct RecipientSet: Hashable, Sendable {
    private(set) var recipients: [Recipient] = []
    private var nextID = 1

    init() {}

    /// Splits text at commas, semicolons and newlines; adds valid addresses
    /// (as `resolving`) and invalid pieces (as `invalid`). Returns the new
    /// recipients that need a lookup.
    @discardableResult
    mutating func add(text: String, defaultCallingCode: String) -> [Recipient] {
        let parse = ContactFieldParse.parse(text, defaultCallingCode: defaultCallingCode)
        var added: [Recipient] = []
        for address in parse.addresses where !recipients.contains(where: { $0.address == address }) {
            let recipient = Recipient(id: mintID(), raw: address.description, address: address, state: .resolving)
            recipients.append(recipient)
            added.append(recipient)
        }
        for piece in parse.invalid {
            recipients.append(Recipient(id: mintID(), raw: piece, address: nil, state: .invalid))
        }
        return added
    }

    mutating func remove(id: Int) {
        recipients.removeAll { $0.id == id }
    }

    mutating func removeLast() {
        if !recipients.isEmpty { recipients.removeLast() }
    }

    mutating func resolve(id: Int, as resolution: ContactResolution?) {
        guard let index = recipients.firstIndex(where: { $0.id == id }) else { return }
        switch resolution {
        case .member(let person)?: recipients[index].state = .member(person)
        case .invitable?: recipients[index].state = .invitable
        case nil: recipients[index].state = .unresolved
        }
    }

    var addresses: [ContactAddress] { recipients.compactMap(\.address) }
    var isEmpty: Bool { recipients.isEmpty }
    var hasInvalid: Bool { recipients.contains { $0.state == .invalid } }
    var isResolving: Bool { recipients.contains { $0.state == .resolving } }
    var hasInvitable: Bool { recipients.contains { $0.state == .invitable } }

    /// Sendable once there is at least one address, nothing is invalid and
    /// every lookup has answered.
    var isReady: Bool { !addresses.isEmpty && !hasInvalid && !isResolving }

    private mutating func mintID() -> Int {
        defer { nextID += 1 }
        return nextID
    }

    /// The calling code for numbers typed without one, from the region.
    /// Unknown regions fall back to North America ("1").
    static func defaultCallingCode(region: String?) -> String {
        let codes: [String: String] = [
            "US": "1", "CA": "1", "GB": "44", "IE": "353", "DE": "49", "FR": "33", "ES": "34", "IT": "39",
            "NL": "31", "BE": "32", "CH": "41", "AT": "43", "SE": "46", "NO": "47", "DK": "45", "FI": "358",
            "PL": "48", "PT": "351", "BR": "55", "MX": "52", "JP": "81", "KR": "82", "CN": "86", "TW": "886",
            "HK": "852", "SG": "65", "IN": "91", "AU": "61", "NZ": "64", "TR": "90", "UA": "380", "RU": "7",
            "VN": "84", "TH": "66", "KH": "855", "BA": "387", "AE": "971", "SA": "966", "IL": "972",
        ]
        guard let region else { return "1" }
        return codes[region.uppercased()] ?? "1"
    }
}

/// The default first message for someone who is not on cmux yet, and the
/// invitation preview. Word of mouth: short, warm, concrete.
enum InviteCopy {
    static let link = "https://cmux.com"

    static var firstMessage: String { HomeText.inviteDefaultMessage(link: link) }

    static func invitationTitle(sender: String) -> String { HomeText.invitationTitle(sender: sender) }

    static func invitationBody(sender: String) -> String { HomeText.invitationBody(sender: sender) }

    /// The text for the share sheet.
    static var shareText: String { firstMessage }
}
