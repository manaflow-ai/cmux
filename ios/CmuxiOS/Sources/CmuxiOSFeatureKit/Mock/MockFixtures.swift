public import Foundation

/// Sample data the mocks share, so the Feed, Workspaces, Compose and Hosts
/// placeholders describe the same two Macs. Fixture text is sample owner
/// data, not app chrome, so it is not localized.
public enum MockFixtures {
    public static let studio = HostID("mac-studio")
    public static let mini = HostID("mac-mini")

    public static func hostWorkspaces(now: Date = Date()) -> [HostWorkspaces] {
        [
            HostWorkspaces(hostID: studio, hostName: "Mac Studio", isReachable: true, workspaces: [
                WorkspaceSummary(id: "ws_studio1", hostID: studio, title: "cmux", status: .running,
                                 paneCount: 3, unreadCount: 2, lastActivity: now.addingTimeInterval(-40)),
                WorkspaceSummary(id: "ws_studio2", hostID: studio, title: "backend", status: .waitingForInput,
                                 paneCount: 2, unreadCount: 1, lastActivity: now.addingTimeInterval(-300)),
                WorkspaceSummary(id: "ws_studio3", hostID: studio, title: "docs", status: .idle,
                                 paneCount: 1, lastActivity: now.addingTimeInterval(-7200)),
            ]),
            HostWorkspaces(hostID: mini, hostName: "Mac mini", isReachable: false, workspaces: [
                WorkspaceSummary(id: "ws_mini1", hostID: mini, title: "release", status: .failed,
                                 paneCount: 2, lastActivity: now.addingTimeInterval(-86_400)),
            ]),
        ]
    }

    public static func feedItems(now: Date = Date()) -> [FeedItem] {
        [
            FeedItem(id: "feed1", kind: .permission, hostID: studio, workspaceID: "ws_studio1",
                     source: "Claude Code · cmux", title: "Run tests?",
                     body: "swift test --filter CmuxiOSFeatureKitTests", createdAt: now.addingTimeInterval(-60)),
            FeedItem(id: "feed2", kind: .question(options: ["Keep", "Replace"]), hostID: studio,
                     workspaceID: "ws_studio2", source: "Codex · backend", title: "Existing migration found",
                     body: "Keep the current migration or replace it?", createdAt: now.addingTimeInterval(-320)),
            FeedItem(id: "feed3", kind: .planApproval, hostID: studio, workspaceID: "ws_studio2",
                     source: "Codex · backend", title: "Plan ready", body: "3 steps: schema, handler, tests.",
                     createdAt: now.addingTimeInterval(-900)),
            FeedItem(id: "feed4", kind: .done, hostID: mini, workspaceID: "ws_mini1",
                     source: "Claude Code · release", title: "Build failed",
                     body: "Archive step exited with 65.", createdAt: now.addingTimeInterval(-86_000), isRead: true),
        ]
    }

    public static let agents: [ComposerAgent] = [
        ComposerAgent(id: "claude", name: "Claude Code", models: ["opus", "sonnet"], efforts: ["low", "medium", "high"]),
        ComposerAgent(id: "codex", name: "Codex", models: ["gpt-5.6"], efforts: ["low", "medium", "high", "xhigh"]),
    ]

    public static func hosts() -> [HostRecord] {
        [
            HostRecord(id: studio, name: "Mac Studio", kind: .pairedMac, reachability: .reachable(path: "direct")),
            HostRecord(id: mini, name: "Mac mini", kind: .pairedMac, reachability: .unreachable(reason: "Asleep")),
            HostRecord(id: HostID("ssh-devbox"), name: "devbox",
                       kind: .ssh(endpoint: HostEndpoint(address: "devbox.tail0.ts.net", port: 22, user: "dev"), jumpHost: nil),
                       reachability: .unknown),
        ]
    }

    public static func devices(now: Date = Date()) -> [DeviceRecord] {
        [
            DeviceRecord(id: "dev-phone", name: "iPhone", platform: .iPhone, trust: .trusted, isThisDevice: true, lastSeen: now),
            DeviceRecord(id: studio.rawValue, name: "Mac Studio", platform: .mac, trust: .trusted, lastSeen: now.addingTimeInterval(-30)),
            DeviceRecord(id: mini.rawValue, name: "Mac mini", platform: .mac, trust: .trusted, lastSeen: now.addingTimeInterval(-86_400)),
            DeviceRecord(id: "dev-laptop", name: "MacBook Pro", platform: .mac, trust: .discovered),
        ]
    }

    public static func browserTabs(on hostID: HostID) -> [BrowserTabInfo] {
        guard hostID == studio else { return [] }
        return [
            BrowserTabInfo(id: "tab_web1", workspaceID: "ws_studio1", title: "localhost:3000", url: URL(string: "http://localhost:3000")),
            BrowserTabInfo(id: "tab_web2", workspaceID: "ws_studio2", title: "API docs", url: URL(string: "https://example.com/docs")),
        ]
    }
}
