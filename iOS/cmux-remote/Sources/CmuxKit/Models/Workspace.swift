public import Foundation

public struct CmuxWindow: Hashable, Codable, Sendable, Identifiable {
    public let id: WindowID
    public let title: String?
    public let isKey: Bool
    public let workspaceCount: Int
    public let selectedWorkspaceID: WorkspaceID?

    public init(
        id: WindowID,
        title: String?,
        isKey: Bool,
        workspaceCount: Int,
        selectedWorkspaceID: WorkspaceID?
    ) {
        self.id = id
        self.title = title
        self.isKey = isKey
        self.workspaceCount = workspaceCount
        self.selectedWorkspaceID = selectedWorkspaceID
    }
}

public struct CmuxWorkspace: Hashable, Codable, Sendable, Identifiable {
    public let id: WorkspaceID
    public let windowID: WindowID
    public let index: Int
    public let title: String?
    public let cwd: String?
    public let branch: String?
    public let isPinned: Bool
    public let isSelected: Bool
    public let unreadCount: Int
    public let isRemote: Bool
    public let remoteHost: String?
    public let remoteStatus: String?
    public let listeningPorts: [Int]

    public init(
        id: WorkspaceID,
        windowID: WindowID,
        index: Int,
        title: String?,
        cwd: String?,
        branch: String?,
        isPinned: Bool,
        isSelected: Bool,
        unreadCount: Int,
        isRemote: Bool,
        remoteHost: String?,
        remoteStatus: String?,
        listeningPorts: [Int]
    ) {
        self.id = id
        self.windowID = windowID
        self.index = index
        self.title = title
        self.cwd = cwd
        self.branch = branch
        self.isPinned = isPinned
        self.isSelected = isSelected
        self.unreadCount = unreadCount
        self.isRemote = isRemote
        self.remoteHost = remoteHost
        self.remoteStatus = remoteStatus
        self.listeningPorts = listeningPorts
    }
}

public struct CmuxPane: Hashable, Codable, Sendable, Identifiable {
    public let id: PaneID
    public let workspaceID: WorkspaceID
    public let isFocused: Bool
    public let selectedSurfaceID: SurfaceID?
    public let frame: Frame?

    public struct Frame: Hashable, Codable, Sendable {
        public let x: Double
        public let y: Double
        public let width: Double
        public let height: Double

        public init(x: Double, y: Double, width: Double, height: Double) {
            self.x = x
            self.y = y
            self.width = width
            self.height = height
        }
    }

    public init(
        id: PaneID,
        workspaceID: WorkspaceID,
        isFocused: Bool,
        selectedSurfaceID: SurfaceID?,
        frame: Frame?
    ) {
        self.id = id
        self.workspaceID = workspaceID
        self.isFocused = isFocused
        self.selectedSurfaceID = selectedSurfaceID
        self.frame = frame
    }
}

public struct CmuxSurface: Hashable, Codable, Sendable, Identifiable {
    public enum Kind: String, Hashable, Codable, Sendable {
        case terminal
        case browser
        case markdown
        case filePreview = "file_preview"
        case other
    }

    public let id: SurfaceID
    public let paneID: PaneID
    public let workspaceID: WorkspaceID
    public let kind: Kind
    public let title: String?
    public let isFocused: Bool
    public let isSelected: Bool
    public let unreadCount: Int

    public init(
        id: SurfaceID,
        paneID: PaneID,
        workspaceID: WorkspaceID,
        kind: Kind,
        title: String?,
        isFocused: Bool,
        isSelected: Bool,
        unreadCount: Int
    ) {
        self.id = id
        self.paneID = paneID
        self.workspaceID = workspaceID
        self.kind = kind
        self.title = title
        self.isFocused = isFocused
        self.isSelected = isSelected
        self.unreadCount = unreadCount
    }
}

public struct CmuxNotification: Hashable, Codable, Sendable, Identifiable {
    public let id: NotificationID
    public let workspaceID: WorkspaceID?
    public let surfaceID: SurfaceID?
    public let title: String?
    public let subtitle: String?
    public let body: String?
    public let tabTitle: String?
    public let createdAt: Date
    public let isRead: Bool

    public init(
        id: NotificationID,
        workspaceID: WorkspaceID?,
        surfaceID: SurfaceID?,
        title: String?,
        subtitle: String?,
        body: String?,
        tabTitle: String?,
        createdAt: Date,
        isRead: Bool
    ) {
        self.id = id
        self.workspaceID = workspaceID
        self.surfaceID = surfaceID
        self.title = title
        self.subtitle = subtitle
        self.body = body
        self.tabTitle = tabTitle
        self.createdAt = createdAt
        self.isRead = isRead
    }
}

public struct CmuxCapabilities: Hashable, Codable, Sendable {
    public let version: String
    public let bootID: String
    public let supportsV2: Bool
    public let supportsEventsStream: Bool
    public let supportedMethods: [String]
    public let supportedFeatures: [String]

    public init(
        version: String,
        bootID: String,
        supportsV2: Bool,
        supportsEventsStream: Bool,
        supportedMethods: [String],
        supportedFeatures: [String] = []
    ) {
        self.version = version
        self.bootID = bootID
        self.supportsV2 = supportsV2
        self.supportsEventsStream = supportsEventsStream
        self.supportedMethods = supportedMethods
        self.supportedFeatures = supportedFeatures
    }

    public var supportsRemoteDecisionResolution: Bool {
        supportedFeatures.contains("feed.reply.item_id_required")
            && supportedFeatures.contains("feed.question_selections")
    }
}
