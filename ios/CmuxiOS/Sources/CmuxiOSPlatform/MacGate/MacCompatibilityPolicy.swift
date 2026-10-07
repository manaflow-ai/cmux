import Foundation

/// Compares a Mac's capabilities with what this app supports
/// (c16-platform.md section 7). The remote config can raise the floor.
public struct MacCompatibilityPolicy: Sendable {
    /// `cmux.mobile` protocol versions this build speaks.
    public static let appProtocols: ClosedRange<Int> = 1...1
    /// Capabilities every Mac must announce (A0 names them; empty until A0
    /// lands its list).
    public static let requiredCapabilities: Set<String> = []

    public let supported: ClosedRange<Int>
    public let required: Set<String>
    public let remoteMinimum: Int?

    public init(supported: ClosedRange<Int> = MacCompatibilityPolicy.appProtocols,
                required: Set<String> = MacCompatibilityPolicy.requiredCapabilities,
                remoteMinimum: Int? = nil) {
        self.supported = supported
        self.required = required
        self.remoteMinimum = remoteMinimum
    }

    public func verdict(for mac: MacCapabilities) -> MacCompatibility {
        let floor = max(supported.lowerBound, remoteMinimum ?? supported.lowerBound)
        if mac.protocolVersion < floor { return .macUpdateRequired(minimumProtocol: floor) }
        if mac.protocolVersion > supported.upperBound { return .phoneUpdateRequired(macProtocol: mac.protocolVersion) }
        let missing = required.subtracting(mac.capabilities)
        if !missing.isEmpty { return .missingCapabilities(missing.sorted()) }
        return .compatible
    }
}
