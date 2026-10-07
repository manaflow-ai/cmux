public import CmuxiOSFeatureKit
public import Foundation

/// What a `PairingTicket` carries (B6 owns the encoding; the shell only
/// carries it): a scanned or opened `pair` link, or a discovered device id
/// (same-account Connect).
public enum PairingTicketPayload: Hashable, Sendable {
    case link(URL)
    case device(DeviceRecordID)

    public init?(ticket: PairingTicket) {
        let text = String(decoding: ticket.payload, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if let id = DeviceRecordID(rawValue: text) {
            self = .device(id)
        } else if let url = URL(string: text), url.scheme != nil {
            self = .link(url)
        } else {
            return nil
        }
    }

    public var ticket: PairingTicket {
        switch self {
        case .link(let url): PairingTicket(payload: Data(url.absoluteString.utf8))
        case .device(let id): PairingTicket(payload: Data(id.rawValue.utf8))
        }
    }
}
