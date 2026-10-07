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
                                 paneCount: 2, unreadCount: 2, lastActivity: now.addingTimeInterval(-40),
                                 panes: [
                                    WorkspacePane(id: "pane_s1a", surfaces: [
                                        WorkspaceSurface(id: "tab_s1a", kind: .agent, title: "Claude Code", terminalID: "term_s1a",
                                                         status: .running, unreadCount: 2, preview: "Running swift test (41/120)"),
                                        WorkspaceSurface(id: "tab_s1b", kind: .terminal, title: "zsh", terminalID: "term_s1b",
                                                         preview: "~/src/cmux main"),
                                    ]),
                                    WorkspacePane(id: "pane_s1b", surfaces: [
                                        WorkspaceSurface(id: "tab_s1c", kind: .browser, title: "localhost:3000",
                                                         url: URL(string: "http://localhost:3000")),
                                    ]),
                                 ],
                                 preview: "Running swift test (41/120)", isPinned: true, order: 0),
                WorkspaceSummary(id: "ws_studio2", hostID: studio, title: "backend", status: .waitingForInput,
                                 paneCount: 1, unreadCount: 1, lastActivity: now.addingTimeInterval(-300),
                                 panes: [
                                    WorkspacePane(id: "pane_s2a", surfaces: [
                                        WorkspaceSurface(id: "tab_s2a", kind: .agent, title: "Codex", terminalID: "term_s2a",
                                                         status: .waitingForInput, unreadCount: 1,
                                                         preview: "Keep the current migration or replace it?"),
                                    ]),
                                 ],
                                 preview: "Keep the current migration or replace it?",
                                 group: WorkspaceGroup(id: "grp_api", name: "API"), order: 1),
                WorkspaceSummary(id: "ws_studio3", hostID: studio, title: "docs", status: .idle,
                                 paneCount: 1, lastActivity: now.addingTimeInterval(-7200),
                                 panes: [
                                    WorkspacePane(id: "pane_s3a", surfaces: [
                                        WorkspaceSurface(id: "tab_s3a", kind: .terminal, title: "zsh", terminalID: "term_s3a",
                                                         preview: "Done in 2.1s"),
                                    ]),
                                 ],
                                 preview: "Done in 2.1s", group: WorkspaceGroup(id: "grp_api", name: "API"), order: 2),
            ]),
            HostWorkspaces(hostID: mini, hostName: "Mac mini", isReachable: false, workspaces: [
                WorkspaceSummary(id: "ws_mini1", hostID: mini, title: "release", status: .failed,
                                 paneCount: 1, lastActivity: now.addingTimeInterval(-86_400),
                                 panes: [
                                    WorkspacePane(id: "pane_m1a", surfaces: [
                                        WorkspaceSurface(id: "tab_m1a", kind: .terminal, title: "archive", terminalID: "term_m1a",
                                                         status: .failed, preview: "Archive step exited with 65"),
                                    ]),
                                 ],
                                 preview: "Archive step exited with 65", order: 0),
            ], offlineReason: "Asleep"),
        ]
    }

    public static func feedItems(now: Date = Date()) -> [FeedItem] {
        [
            FeedItem(id: "feed1", kind: .permission(FeedPermission(
                        actionType: .command, summary: "Run the FeatureKit tests",
                        command: "swift test --filter CmuxiOSFeatureKitTests", cwd: "~/cmux/ios/CmuxiOS",
                        scopes: [.once, .session, .always])),
                     priority: .high, hostID: studio, workspaceID: "ws_studio1", source: "Claude Code · cmux",
                     agent: "claude", title: "Run tests?", createdAt: now.addingTimeInterval(-60)),
            FeedItem(id: "feed2", kind: .choice(FeedChoice(questions: [
                        FeedChoiceQuestion(id: "q1", question: "Keep the current migration or replace it?",
                                           header: "Migration", options: [
                                               FeedChoiceOption(id: "keep", label: "Keep", detail: "Add a follow-up migration"),
                                               FeedChoiceOption(id: "replace", label: "Replace", detail: "Rewrite 0042"),
                                           ], allowOther: true),
                     ])),
                     priority: .high, hostID: studio, workspaceID: "ws_studio2", source: "Codex · backend",
                     agent: "codex", title: "Existing migration found", createdAt: now.addingTimeInterval(-320)),
            FeedItem(id: "feed3", kind: .planApproval(FeedPlan(ref: "plan.md", checklist: ["Schema", "Handler", "Tests"])),
                     hostID: studio, workspaceID: "ws_studio2", source: "Codex · backend", agent: "codex",
                     title: "Plan ready", body: "1. Add the `team_invites` table.\n2. Add the invite handler.\n3. Cover both with tests.",
                     createdAt: now.addingTimeInterval(-900)),
            FeedItem(id: "feed5", kind: .question(FeedQuestion(question: "Which branch should I base the fix on?",
                                                               suggestions: ["main", "release"])),
                     priority: .high, hostID: studio, workspaceID: "ws_studio1", source: "Claude Code · cmux",
                     agent: "claude", title: "Base branch?", createdAt: now.addingTimeInterval(-1_200)),
            FeedItem(id: "feed4", kind: .done, hostID: mini, workspaceID: "ws_mini1",
                     source: "Claude Code · release", agent: "claude", title: "Build failed",
                     body: "Archive step exited with 65.", createdAt: now.addingTimeInterval(-86_000),
                     readAt: now.addingTimeInterval(-80_000)),
        ]
    }

    public static let agents: [ComposerAgent] = [
        ComposerAgent(id: "claude", name: "Claude Code", modelOptions: [
            ComposerModel(id: "opus", label: "Claude Opus", efforts: ["low", "medium", "high"], defaultEffort: "medium"),
            ComposerModel(id: "sonnet", label: "Claude Sonnet", efforts: ["low", "medium", "high"], defaultEffort: "medium"),
        ], defaultModel: "opus"),
        ComposerAgent(id: "codex", name: "Codex", modelOptions: [
            ComposerModel(id: "gpt-5.6", label: "GPT-5.6", efforts: ["low", "medium", "high", "xhigh"], defaultEffort: "high"),
        ], defaultModel: "gpt-5.6"),
        ComposerAgent(id: "opencode", name: "OpenCode", modelOptions: [ComposerModel(id: "default", label: "Default")],
                      defaultModel: "default", unavailableReason: "Not installed"),
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
