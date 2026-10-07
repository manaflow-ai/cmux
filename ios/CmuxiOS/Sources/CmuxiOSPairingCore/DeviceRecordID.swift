/// The `DeviceRecord.id` grammar this registry uses, so intents can find
/// their owner entity again.
public enum DeviceRecordID: Hashable, Sendable {
    /// One of this account's installs.
    case install(String)
    /// Another account's host this account's device was accepted on.
    case remote(host: String, install: String)
    /// Another account's device accepted on one of this account's hosts.
    case guest(host: String, install: String)
    /// A pending cross-account request on one of this account's hosts.
    case request(offerID: String)

    public init?(rawValue: String) {
        let parts = rawValue.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        let pair = parts[1].split(separator: "/", maxSplits: 1).map(String.init)
        switch parts[0] {
        case "install": self = .install(parts[1])
        case "request": self = .request(offerID: parts[1])
        case "remote" where pair.count == 2: self = .remote(host: pair[0], install: pair[1])
        case "guest" where pair.count == 2: self = .guest(host: pair[0], install: pair[1])
        default: return nil
        }
    }

    public var rawValue: String {
        switch self {
        case .install(let id): "install:\(id)"
        case .remote(let host, let install): "remote:\(host)/\(install)"
        case .guest(let host, let install): "guest:\(host)/\(install)"
        case .request(let offerID): "request:\(offerID)"
        }
    }
}
