import Foundation

/// The merge of local and remote flag layers (c16-platform.md section 6):
/// launch environment, then the device's DEV override, then the remote
/// value, then the build default. A remote value that is not a bool is
/// ignored for a bool flag.
public struct FlagResolution: Hashable, Sendable {
    public let value: Bool
    public let layer: FlagLayer

    public init(environment: Bool?, deviceOverride: Bool?, remote: RemoteFlagValue?, buildDefault: Bool) {
        if let environment {
            (value, layer) = (environment, .environment)
        } else if let deviceOverride {
            (value, layer) = (deviceOverride, .deviceOverride)
        } else if let remote = remote?.boolValue {
            (value, layer) = (remote, .remote)
        } else {
            (value, layer) = (buildDefault, .buildDefault)
        }
    }
}
