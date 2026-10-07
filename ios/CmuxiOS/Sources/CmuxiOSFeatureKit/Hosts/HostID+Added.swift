import Foundation

extension HostID {
    /// The id of a host this client adds with `key`. The client picks it, so
    /// a screen can bind device-local settings (how this device logs in)
    /// before the owner's snapshot returns, and replaying the add with the
    /// same key names the same host.
    public static func added(by key: IntentKey) -> HostID {
        HostID("host-" + key.rawValue)
    }
}
