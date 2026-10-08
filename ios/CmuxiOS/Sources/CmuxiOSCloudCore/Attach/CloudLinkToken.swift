import CmuxiOSFeatureKit
import Foundation

/// The one-shot credential returned by `cloud.machine.link_token`.
///
/// A grant is deliberately separate from `CloudConnectInfo`: connect-info may
/// be cached for its short lifetime, while this token is valid for one hello
/// only. Callers must hand it to the link session immediately and never put it
/// in a machine mirror, intent log, or persistence layer.
public struct CloudLinkTokenGrant: Equatable, Sendable {
    public let token: String
    public let expiresAt: Date
    public let hostID: HostID
    public let epoch: Int
    public let services: [CloudConnectInfo.Service]

    public init(token: String, expiresAt: Date, hostID: HostID, epoch: Int,
                services: [CloudConnectInfo.Service]) {
        self.token = token
        self.expiresAt = expiresAt
        self.hostID = hostID
        self.epoch = epoch
        self.services = services
    }

    /// A safe summary for diagnostics. The token itself is never rendered.
    public var redactedSummary: String {
        "host=\(hostID.rawValue), epoch=\(epoch), services=\(services.map(\.rawValue).joined(separator: ","))"
    }
}
