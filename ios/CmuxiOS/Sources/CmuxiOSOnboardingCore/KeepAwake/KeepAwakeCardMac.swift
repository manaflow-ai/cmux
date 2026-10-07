public import CmuxiOSFeatureKit

/// One row of the keep-awake card: a trusted Mac and what it reports.
public struct KeepAwakeCardMac: Hashable, Sendable, Identifiable {
    public enum Availability: Hashable, Sendable {
        /// The Mac has not reported yet.
        case checking
        /// The Mac's cmux cannot hold the assertion (old build, policy).
        case unavailable
        case available(isOn: Bool)
    }

    public var id: HostID
    public var name: String
    public var availability: Availability

    public init(id: HostID, name: String, availability: Availability) {
        self.id = id
        self.name = name
        self.availability = availability
    }
}
