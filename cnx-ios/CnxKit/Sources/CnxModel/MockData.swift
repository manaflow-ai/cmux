import Foundation

extension AppStore {
    /// Sample data for previews, UI verification and first-run demos.
    public static func mock(now: Date = Date()) -> AppStore {
        let teams = [
            Team(id: "team-manaflow", name: "Manaflow", macs: [
                MacDevice(id: "mac-studio", name: "Aziz's Mac Studio", isOnline: true),
                MacDevice(id: "mac-mini-2", name: "cmux mini 2", isOnline: true),
                MacDevice(id: "mbp", name: "MacBook Pro", isOnline: false),
            ]),
            Team(id: "team-personal", name: "Personal", appearance: TeamAppearance(colorHex: "#30D158", emoji: "🌵"), macs: [
                MacDevice(id: "mbp-home", name: "Home MacBook", isOnline: false),
            ]),
            Team(id: "team-fleet", name: "Build Fleet", macs: (1...8).map {
                MacDevice(id: "mini-\($0)", name: "mini \($0)", isOnline: $0 % 3 != 0)
            }),
        ]
        let workspaces = [
            Workspace(
                id: "ws-cmux", macID: "mac-studio", title: "cmux", directory: "~/Development/cmux", branch: "feat-cnx-ios",
                tabs: [
                    WorkspaceTab(id: "t-claude", kind: .agent, title: "Claude", subtitle: "Refactor transport layer", harness: "claude"),
                    WorkspaceTab(id: "t-zsh", kind: .terminal, title: "zsh", subtitle: "~/Development/cmux"),
                    WorkspaceTab(id: "t-docs", kind: .browser, title: "Swift docs", subtitle: "developer.apple.com"),
                ],
                lastActivityAt: now.addingTimeInterval(-60), needsAttention: true
            ),
            Workspace(
                id: "ws-web", macID: "mac-studio", title: "cmux.com", directory: "~/Development/web", branch: "main",
                tabs: [
                    WorkspaceTab(id: "t-codex", kind: .agent, title: "Codex", subtitle: "Fix pricing page", harness: "codex"),
                    WorkspaceTab(id: "t-dev", kind: .terminal, title: "bun dev", subtitle: "localhost:3000"),
                ],
                lastActivityAt: now.addingTimeInterval(-900)
            ),
            Workspace(
                id: "ws-infra", macID: "mac-mini-2", title: "fleet", directory: "~/fleet", branch: nil,
                tabs: [WorkspaceTab(id: "t-htop", kind: .terminal, title: "htop", subtitle: "TUI")],
                lastActivityAt: now.addingTimeInterval(-7200)
            ),
        ]
        let feed = [
            FeedEvent(
                id: "e1",
                kind: .question(QuestionPrompt(items: [
                    QuestionPrompt.Item(header: "Transport", question: "Which transport should be the default on cellular?", options: [
                        QuestionPrompt.Option(label: "WebRTC", detail: "Uses TURN when no direct path exists."),
                        QuestionPrompt.Option(label: "WireGuard", detail: "Falls back to the relay."),
                    ]),
                ])),
                workspaceID: "ws-cmux", tabID: "t-claude", agentName: "Claude", harness: "claude",
                markdown: "I finished the **link framing**. Before wiring the dialers I need one decision:\n\n- WebRTC is faster to connect\n- WireGuard keeps one tunnel for every service",
                quotedPrompt: "Make the transport layer switchable between WebRTC and WireGuard",
                createdAt: now.addingTimeInterval(-45)
            ),
            FeedEvent(
                id: "e2", kind: .agentResponse, workspaceID: "ws-web", tabID: "t-codex", agentName: "Codex", harness: "codex",
                markdown: "Fixed the pricing table overflow on small screens.\n\n```diff\n- grid-template-columns: repeat(3, 1fr);\n+ grid-template-columns: repeat(auto-fit, minmax(220px, 1fr));\n```\n\nAll 14 tests pass.",
                quotedPrompt: "the pricing page breaks on iPhone SE",
                createdAt: now.addingTimeInterval(-600)
            ),
            FeedEvent(
                id: "e3", kind: .permission(options: ["Allow once", "Always allow", "Deny"]), workspaceID: "ws-cmux", tabID: "t-claude",
                agentName: "Claude", harness: "claude",
                markdown: "Run `cargo test -p cnx-link`?",
                quotedPrompt: "run the tests", createdAt: now.addingTimeInterval(-1200)
            ),
        ]
        return AppStore(teams: teams, activeTeamID: "team-manaflow", workspaces: workspaces, feed: feed)
    }
}
