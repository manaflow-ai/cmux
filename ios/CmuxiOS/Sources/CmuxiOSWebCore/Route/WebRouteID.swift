public import CmuxiOSFeatureKit

/// The machine whose localhost a browser route reaches.
public enum WebRouteID: Hashable, Sendable {
    case mac(HostID)
    case ssh(HostID)
}
