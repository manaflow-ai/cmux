public import Foundation
public import ActivityKit

/// Live Activity payload shared between the iOS app process and the widget
/// extension that renders the activity UI on the Lock Screen / Dynamic
/// Island.
///
/// `ContentState` is the part that changes during the activity's lifetime
/// from foreground snapshots or background refreshes.
/// `Attributes` is immutable once the activity is started.
public struct CMUXActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable, Sendable {
        public var workspaceTitle: String
        public var workspaceBranch: String?
        public var pendingCount: Int
        public var lastSurfaceTitle: String?
        public var lastNotificationBody: String?
        public var phaseLabel: String
        public var isLive: Bool

        public init(
            workspaceTitle: String,
            workspaceBranch: String?,
            pendingCount: Int,
            lastSurfaceTitle: String?,
            lastNotificationBody: String?,
            phaseLabel: String,
            isLive: Bool
        ) {
            self.workspaceTitle = workspaceTitle
            self.workspaceBranch = workspaceBranch
            self.pendingCount = pendingCount
            self.lastSurfaceTitle = lastSurfaceTitle
            self.lastNotificationBody = lastNotificationBody
            self.phaseLabel = phaseLabel
            self.isLive = isLive
        }
    }

    public let hostLabel: String
    public let hostID: UUID

    public init(hostLabel: String, hostID: UUID) {
        self.hostLabel = hostLabel
        self.hostID = hostID
    }
}
