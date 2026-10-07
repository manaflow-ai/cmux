import Foundation

/// Every feature seam the shell wires, with the lane that implements it
/// (plans/cmux-next/ios-next/PLAN.md section 2).
public enum FeatureSeam: String, CaseIterable, Hashable, Sendable {
    case feed
    case workspaces
    case composer
    case hosts
    case devices
    case files
    case browser

    /// The implementing lane id.
    public var lane: String {
        switch self {
        case .feed: "C6"
        case .workspaces: "C5"
        case .composer: "C8"
        case .hosts: "B4/C9"
        case .devices: "B6/C11"
        case .files: "C4"
        case .browser: "C2"
        }
    }

    /// The protocol name, for DEV screens and logs.
    public var protocolName: String {
        switch self {
        case .feed: "FeedSource"
        case .workspaces: "WorkspaceSource"
        case .composer: "TaskComposerSink"
        case .hosts: "HostsStore"
        case .devices: "DeviceRegistry"
        case .files: "FileTransfer"
        case .browser: "BrowserStreamSource"
        }
    }
}
