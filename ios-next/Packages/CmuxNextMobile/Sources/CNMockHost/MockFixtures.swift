// DEVELOPMENT FIXTURE DATA. Names, repos and stories are invented demo content.

import CNCore
import Foundation

struct MockToolStep: Sendable {
    var kind: ToolKind
    var title: String
    var input: JSONValue?
    var output: JSONValue?
    var locations: [ToolLocation] = []
    var diff: [FileDiff]?
    var durationMs: Double = 700
    var fails = false
    var needsPermission = false
}

struct MockTurnScript: Sendable {
    var thought: String
    var tools: [MockToolStep]
    var answer: String
}

struct MockFixtures: Sendable {
    let now: Date
    let conversations: [Conversation]
    let messages: [String: [Message]]
    let harnesses: [Harness]
    let agentSessions: [AgentSession]
    let transcripts: [String: [TranscriptItem]]
    let commands: [SlashCommand]

    static let me = MessageSender(id: "u_me", name: "You", isMe: true)
    static let chief = MessageSender(id: "chief", name: "Chief", isMe: false)
    static let maya = MessageSender(id: "u_maya", name: "Maya Chen", isMe: false)
    static let sam = MessageSender(id: "u_sam", name: "Sam Ortiz", isMe: false)
    static let claude = MessageSender(id: "agent_claude", name: "Claude", isMe: false)

    static let permissionOptions = [
        PermissionOption(id: "allow_once", name: "Allow once", kind: .allowOnce),
        PermissionOption(id: "allow_always", name: "Always allow", kind: .allowAlways),
        PermissionOption(id: "reject_once", name: "Reject", kind: .rejectOnce),
    ]

    init(now: Date) {
        self.now = now
        let cal = Calendar.current
        let today = cal.startOfDay(for: now)
        func at(_ dayOffset: Int, _ hour: Int, _ minute: Int) -> EpochMillis {
            var t = cal.date(byAdding: .day, value: dayOffset, to: today)!.addingTimeInterval(TimeInterval(hour * 3600 + minute * 60))
            if t > now { t = now.addingTimeInterval(-Double(abs(hour * 7 + minute)) * 60) }
            return t.epochMillis
        }
        func ago(_ minutes: Double) -> EpochMillis { now.addingTimeInterval(-minutes * 60).epochMillis }

        var counter = 0
        func msg(_ conv: String, _ sender: MessageSender, _ text: String, _ t: EpochMillis, _ status: MessageStatus = .read) -> Message {
            counter += 1
            return Message(id: "m_fx_\(counter)", conversationId: conv, sender: sender, text: text, sentAt: t, status: sender.isMe ? status : .delivered)
        }

        let chiefId = "c_chief", groupId = "c_release", agentConvId = "c_agent_auth"
        let chiefMessages = [
            msg(chiefId, Self.chief, "Good morning. Overnight: 3 agent sessions finished, 1 needs your approval, and CI on main is green.", at(-7, 8, 2)),
            msg(chiefId, Self.me, "Nice. What's blocking the auth refactor?", at(-7, 8, 15)),
            msg(chiefId, Self.chief, "It wants to delete the stale build caches in `dist/`. I paused it until you approve.", at(-7, 8, 15)),
            msg(chiefId, Self.me, "Let it run after standup.", at(-7, 8, 16)),
            msg(chiefId, Self.chief, "Weekly summary: 41 PRs merged, median review time 3h 12m. The flaky resize test failed 6 times; Codex is on it.", at(-3, 18, 30)),
            msg(chiefId, Self.me, "Can you get Sam to look at the browser memory growth too?", at(-1, 21, 4)),
            msg(chiefId, Self.chief, "Done. I opened a Gemini session on it and shared the heap snapshot with Sam.", at(-1, 21, 5)),
            msg(chiefId, Self.chief, "Heads up: the Codex session fixed the resize test. 200/200 runs green locally. Want me to open the PR?", ago(42)),
            msg(chiefId, Self.me, "Yes please, and tag Maya for review.", ago(38), .read),
            msg(chiefId, Self.chief, "PR #1421 is up and Maya is requested. I'll ping you when checks finish.", ago(37)),
            msg(chiefId, Self.chief, "Checks passed on #1421 ✅", ago(6)),
        ]
        let groupMessages = [
            msg(groupId, Self.maya, "Release train for 0.42 leaves Thursday. Anything still in flight?", at(-6, 10, 0)),
            msg(groupId, Self.sam, "Browser pane memory fix, maybe. Still profiling.", at(-6, 10, 4)),
            msg(groupId, Self.me, "Terminal resize fix should land today.", at(-6, 10, 7)),
            msg(groupId, Self.chief, "I'll track both and post a status here on Wednesday evening.", at(-6, 10, 7)),
            msg(groupId, Self.chief, "Status: resize fix merged, memory fix in review, changelog drafted.", at(-1, 19, 40)),
            msg(groupId, Self.maya, "🚢 let's cut the RC tomorrow morning", at(-1, 19, 52)),
            msg(groupId, Self.sam, "Memory fix is in. Peak RSS down from 1.9 GB to 620 MB on the 40-tab benchmark.", ago(95)),
            msg(groupId, Self.maya, "Huge. Approving now.", ago(80)),
        ]
        let agentMessages = [
            msg(agentConvId, Self.claude, "I finished reading the auth middleware. Plan: centralize JWT validation, rotate refresh tokens, add tests.", at(-1, 16, 20)),
            msg(agentConvId, Self.me, "Sounds good, go ahead.", at(-1, 16, 22)),
            msg(agentConvId, Self.claude, "Refactor done and 42 tests pass. I need permission to delete stale caches before the final build.", ago(14)),
        ]
        messages = [chiefId: chiefMessages, groupId: groupMessages, agentConvId: agentMessages]

        conversations = [
            Conversation(id: chiefId, kind: .chief, title: "Chief", subtitle: "Your cmux chief of staff",
                         avatar: Avatar(initials: "CH", tint: "#5E5CE6"), pinned: true, unread: 1,
                         lastMessage: chiefMessages.last, updatedAt: chiefMessages.last!.sentAt,
                         participants: [Participant(id: Self.chief.id, name: Self.chief.name)]),
            Conversation(id: groupId, kind: .group, title: "Release crew", subtitle: "Maya, Sam, Chief",
                         avatar: Avatar(initials: "RC", tint: "#30B0C7"), unread: 2,
                         lastMessage: groupMessages.last, updatedAt: groupMessages.last!.sentAt,
                         participants: [Self.maya, Self.sam, Self.chief].map { Participant(id: $0.id, name: $0.name) }),
            Conversation(id: agentConvId, kind: .agent, title: "Claude · auth refactor", subtitle: "~/src/cmux-backend",
                         avatar: Avatar(initials: "CC", tint: "#FF9F0A"), muted: false, unread: 1,
                         lastMessage: agentMessages.last, updatedAt: agentMessages.last!.sentAt,
                         participants: [Participant(id: Self.claude.id, name: Self.claude.name)]),
        ]

        harnesses = [
            Harness(id: "claude-code", name: "Claude Code", available: true,
                    models: [NamedOption(id: "opus", name: "Opus"), NamedOption(id: "sonnet", name: "Sonnet"), NamedOption(id: "haiku", name: "Haiku")],
                    modes: [NamedOption(id: "default", name: "Ask before edits"), NamedOption(id: "acceptEdits", name: "Accept edits"), NamedOption(id: "plan", name: "Plan only")]),
            Harness(id: "codex", name: "Codex", available: true,
                    models: [NamedOption(id: "codex-large", name: "Codex Large"), NamedOption(id: "codex-mini", name: "Codex Mini")],
                    modes: [NamedOption(id: "suggest", name: "Suggest"), NamedOption(id: "auto", name: "Auto edit"), NamedOption(id: "full", name: "Full auto")]),
            Harness(id: "gemini", name: "Gemini CLI", available: true,
                    models: [NamedOption(id: "gemini-pro", name: "Gemini Pro"), NamedOption(id: "gemini-flash", name: "Gemini Flash")],
                    modes: [NamedOption(id: "default", name: "Default")]),
            Harness(id: "opencode", name: "OpenCode", available: false, models: [], modes: []),
        ]

        commands = [
            SlashCommand(name: "/compact", description: "Summarize the conversation to free context"),
            SlashCommand(name: "/review", description: "Review the current diff"),
            SlashCommand(name: "/init", description: "Create an AGENTS.md for this repo"),
            SlashCommand(name: "/model", description: "Switch model"),
            SlashCommand(name: "/clear", description: "Start a fresh context"),
        ]

        agentSessions = [
            AgentSession(id: "s_auth", title: "Refactor auth middleware", harness: "claude-code", model: "opus", mode: "default",
                         cwd: "~/src/cmux-backend", status: .waiting, createdAt: at(-1, 16, 18), updatedAt: ago(14), unread: 1,
                         preview: "Waiting for permission: Delete stale build caches"),
            AgentSession(id: "s_resize", title: "Fix flaky terminal resize test", harness: "codex", model: "codex-large", mode: "auto",
                         cwd: "~/src/cmux", status: .idle, createdAt: at(-2, 11, 0), updatedAt: ago(44),
                         preview: "Fixed: resize events are now coalesced per run-loop turn. 200/200 green."),
            AgentSession(id: "s_memory", title: "Investigate browser memory growth", harness: "gemini", model: "gemini-pro", mode: "default",
                         cwd: "~/src/cmux", status: .error, createdAt: at(-6, 14, 0), updatedAt: at(-1, 21, 30),
                         preview: "Provider rate limit reached"),
        ]

        let authDiffOld = """
        export async function requireUser(req: Request, env: Env) {
          const header = req.headers.get("authorization") ?? ""
          const token = header.replace("Bearer ", "")
          const payload = await verify(token, env.JWT_SECRET)
          if (!payload) throw new HttpError(401, "unauthorized")
          return payload.sub
        }
        """
        let authDiffNew = """
        export async function requireUser(req: Request, env: Env): Promise<UserId> {
          const token = bearer(req)
          if (!token) throw new HttpError(401, "missing_token")
          const claims = await verifyAccessToken(token, env)
          if (claims.typ !== "user") throw new HttpError(401, "wrong_token_type")
          return claims.sub as UserId
        }
        """
        let resizeOld = """
        func terminalDidResize(_ size: TerminalSize) {
            surface.resize(cols: size.cols, rows: size.rows)
            delegate?.terminalSizeChanged(size)
        }
        """
        let resizeNew = """
        func terminalDidResize(_ size: TerminalSize) {
            pendingSize = size
            guard !resizeScheduled else { return }
            resizeScheduled = true
            RunLoop.main.perform { [weak self] in self?.flushResize() }
        }

        private func flushResize() {
            resizeScheduled = false
            guard let size = pendingSize, size != appliedSize else { return }
            appliedSize = size
            surface.resize(cols: size.cols, rows: size.rows)
            delegate?.terminalSizeChanged(size)
        }
        """

        transcripts = [
            "s_auth": [
                .user(UserTranscriptItem(id: "a1", text: "Refactor the auth middleware so JWT validation lives in one place, and rotate refresh tokens on use.")),
                .thought(ThoughtTranscriptItem(id: "a2", text: "The middleware is duplicated across `routes/me.ts`, `routes/hosts.ts` and `routes/ice.ts`. I should find every caller of `verify()` first, then introduce a single `requireUser` helper and make refresh rotation transactional.", durationMs: 4200)),
                .tool(ToolCallTranscriptItem(id: "a3", toolKind: .search, title: "Search for verify( callers", status: .completed,
                                             input: ["pattern": "verify\\(", "path": "src/"],
                                             output: "src/routes/me.ts:14\nsrc/routes/hosts.ts:22\nsrc/routes/ice.ts:9\nsrc/auth/jwt.ts:31",
                                             locations: [ToolLocation(path: "src/routes/me.ts", line: 14), ToolLocation(path: "src/routes/hosts.ts", line: 22)])),
                .tool(ToolCallTranscriptItem(id: "a4", toolKind: .read, title: "Read src/auth/middleware.ts", status: .completed,
                                             locations: [ToolLocation(path: "src/auth/middleware.ts")])),
                .plan(PlanTranscriptItem(id: "a5", entries: [
                    PlanEntry(content: "Add verifyAccessToken() with typ and expiry checks", status: .completed, priority: "high"),
                    PlanEntry(content: "Replace the three inline verify() calls with requireUser()", status: .completed, priority: "high"),
                    PlanEntry(content: "Rotate refresh tokens inside a transaction", status: .completed, priority: "medium"),
                    PlanEntry(content: "Add tests for expired and wrong-type tokens", status: .inProgress, priority: "medium"),
                    PlanEntry(content: "Clean stale build caches and run the full build", status: .pending, priority: "low"),
                ])),
                .assistant(AssistantTranscriptItem(id: "a6", text: """
                I'll centralize validation in `src/auth/middleware.ts`. The new helper rejects tokens with the wrong `typ` so host tokens can never authenticate as users:

                ```ts
                const claims = await verifyAccessToken(token, env)
                if (claims.typ !== "user") throw new HttpError(401, "wrong_token_type")
                ```

                Refresh rotation now runs in one transaction, so a replayed refresh token revokes the whole family.
                """)),
                .tool(ToolCallTranscriptItem(id: "a7", toolKind: .edit, title: "Edit src/auth/middleware.ts", status: .completed,
                                             locations: [ToolLocation(path: "src/auth/middleware.ts", line: 12)],
                                             diff: [FileDiff(path: "src/auth/middleware.ts", oldText: authDiffOld, newText: authDiffNew)])),
                .tool(ToolCallTranscriptItem(id: "a8", toolKind: .execute, title: "npm test", status: .completed,
                                             input: ["command": "npm test -- --reporter=dot"],
                                             output: "··········································\n42 passing (3.1s)")),
                .notice(NoticeTranscriptItem(id: "a9", level: .info, text: "Context compacted: 61% → 18%")),
                .tool(ToolCallTranscriptItem(id: "a10", toolKind: .delete, title: "Delete stale build caches", status: .pending,
                                             input: ["command": "rm -rf dist/ .wrangler/tmp node_modules/.cache"],
                                             locations: [ToolLocation(path: "dist/"), ToolLocation(path: ".wrangler/tmp")])),
                .permission(PermissionTranscriptItem(id: "a11", toolCallId: "a10", title: "Allow Claude to run rm -rf dist/ .wrangler/tmp node_modules/.cache?",
                                                     options: Self.permissionOptions)),
            ],
            "s_resize": [
                .user(UserTranscriptItem(id: "r1", text: "TerminalResizeTests.testRotationKeepsGrid is flaky on CI. Find out why and fix it.")),
                .thought(ThoughtTranscriptItem(id: "r2", text: "Flaky only on CI suggests timing. Rotation fires two resize callbacks in the same run-loop turn; if the second arrives before the first is applied we resize twice and the grid snapshot can catch the intermediate size.", durationMs: 6800)),
                .tool(ToolCallTranscriptItem(id: "r3", toolKind: .read, title: "Read Sources/Terminal/TerminalSurface.swift", status: .completed,
                                             locations: [ToolLocation(path: "Sources/Terminal/TerminalSurface.swift", line: 188)])),
                .tool(ToolCallTranscriptItem(id: "r4", toolKind: .execute, title: "Run the test 50 times", status: .failed,
                                             input: ["command": "swift test --filter testRotationKeepsGrid --repeat 50"],
                                             output: "Test Case 'testRotationKeepsGrid' failed (0.212 s)\nXCTAssertEqual failed: (\"80x24\") is not equal to (\"120x40\")\nExecuted 50 tests, with 3 failures")),
                .tool(ToolCallTranscriptItem(id: "r5", toolKind: .edit, title: "Coalesce resize events", status: .completed,
                                             locations: [ToolLocation(path: "Sources/Terminal/TerminalSurface.swift", line: 188)],
                                             diff: [FileDiff(path: "Sources/Terminal/TerminalSurface.swift", oldText: resizeOld, newText: resizeNew)])),
                .tool(ToolCallTranscriptItem(id: "r6", toolKind: .execute, title: "Run the test 200 times", status: .completed,
                                             input: ["command": "swift test --filter testRotationKeepsGrid --repeat 200"],
                                             output: "Executed 200 tests, with 0 failures (0 unexpected) in 41.8 seconds")),
                .assistant(AssistantTranscriptItem(id: "r7", text: """
                **Root cause:** rotation delivers two resize callbacks in one run-loop turn, and the test sampled the grid between them.

                **Fix:** resize requests are coalesced and applied once per turn (`flushResize()`), and identical sizes are skipped.

                | Runs | Before | After |
                | --- | --- | --- |
                | 50 | 3 failures | 0 failures |
                | 200 | – | 0 failures |
                """)),
                .turnEnd(TurnEndTranscriptItem(id: "r8", stopReason: "end_turn", durationMs: 184_000)),
            ],
            "s_memory": [
                .user(UserTranscriptItem(id: "g1", text: "Browser panes keep growing in memory with 40 tabs open. Profile it.",
                                         attachments: [PromptAttachment(name: "heap-snapshot.png", mimeType: "image/png")])),
                .thought(ThoughtTranscriptItem(id: "g2", text: "The screenshot shows retained `CALayer` backing stores. Likely the frame cache keeps every decoded image.", durationMs: 2900)),
                .tool(ToolCallTranscriptItem(id: "g3", toolKind: .fetch, title: "Fetch WebKit memory docs", status: .failed,
                                             input: ["url": "https://webkit.org/blog/memory"], output: "HTTP 429 Too Many Requests")),
                .notice(NoticeTranscriptItem(id: "g4", level: .warning, text: "Network access is limited in this sandbox")),
                .assistant(AssistantTranscriptItem(id: "g5", text: "The frame cache in `BrowserPane` never evicts. Capping it at 3 decoded frames should bound memory; I'll measure next.")),
                .notice(NoticeTranscriptItem(id: "g6", level: .error, text: "Provider rate limit reached. Retry in a few minutes.")),
                .turnEnd(TurnEndTranscriptItem(id: "g7", stopReason: "error", durationMs: 52_000)),
            ],
        ]
    }

    // MARK: Conversation replies

    func responder(for conversation: Conversation) -> MessageSender {
        switch conversation.kind {
        case .group: [Self.maya, Self.sam, Self.chief][conversation.id.unicodeScalars.reduce(0) { $0 + Int($1.value) } % 3]
        case .agent: Self.claude
        default: Self.chief
        }
    }

    func reply(to text: String, in conversation: Conversation) -> String {
        let t = text.lowercased()
        if conversation.kind == .agent { return "On it. I'll post an update here when the turn finishes." }
        if conversation.kind == .group { return ["Sounds good 👍", "I can take that.", "Let's sync after lunch?"].randomElement()! }
        if t.contains("status") || t.contains("update") {
            return "Right now: 1 agent is waiting on your approval (auth refactor), Codex is idle after fixing the resize test, and Gemini hit a rate limit."
        }
        if t.contains("pr") || t.contains("review") { return "PR #1421 has 12 passing checks and one approval from Maya. Want me to merge it?" }
        if t.contains("thank") { return "Anytime." }
        if t.hasSuffix("?") { return "Good question. Let me check with the agents and get back to you in a minute." }
        return "Got it. I'll take care of that and let you know when it's done."
    }

    // MARK: Agent turns

    func turnScript(for prompt: String, cwd: String) -> MockTurnScript {
        let p = prompt.lowercased()
        var tools = [
            MockToolStep(kind: .search, title: "Search the workspace", input: ["pattern": .string(String(prompt.prefix(24)))],
                         output: "Sources/App/AppModel.swift:42\nSources/Terminal/TerminalSurface.swift:188", durationMs: 600),
            MockToolStep(kind: .read, title: "Read Sources/App/AppModel.swift",
                         locations: [ToolLocation(path: "Sources/App/AppModel.swift", line: 42)], durationMs: 400),
        ]
        if p.contains("delete") || p.contains("permission") || p.contains("clean") {
            tools.append(MockToolStep(kind: .delete, title: "rm -rf .build/cache", input: ["command": "rm -rf .build/cache"],
                                      output: "Removed 1.2 GB", durationMs: 800, needsPermission: true))
        } else {
            tools.append(MockToolStep(kind: .edit, title: "Edit Sources/App/AppModel.swift",
                                      locations: [ToolLocation(path: "Sources/App/AppModel.swift", line: 42)],
                                      diff: [FileDiff(path: "Sources/App/AppModel.swift",
                                                      oldText: "    var isLoading = false\n",
                                                      newText: "    var isLoading = false\n    var lastRefresh: Date?\n")],
                                      durationMs: 500))
            tools.append(MockToolStep(kind: .execute, title: "swift build", input: ["command": "swift build"],
                                      output: "Build complete! (8.31s)", durationMs: 1400))
        }
        return MockTurnScript(
            thought: "The request is about \"\(prompt.prefix(60))\". I'll look at the relevant code in \(cwd) first, then make the smallest change that does it and verify with a build.",
            tools: tools,
            answer: """
            Done. Here's what changed:

            1. Added `lastRefresh` to `AppModel` so the UI can show when data was fetched.
            2. The build passes.

            ```swift
            model.lastRefresh = .now
            ```

            Let me know if you want tests for this too.
            """)
    }

    /// Splits text into token-sized pieces for streaming.
    static func tokenize(_ text: String) -> [String] {
        var out: [String] = []
        var current = ""
        for ch in text {
            current.append(ch)
            if ch == " " || ch == "\n" || current.count >= 6 {
                out.append(current)
                current = ""
            }
        }
        if !current.isEmpty { out.append(current) }
        return out
    }

    // MARK: Terminals

    func terminals() -> [MockTerminal] {
        let created = now.addingTimeInterval(-3 * 3600).epochMillis
        var shell = MockTerminal(info: Terminal(id: "term_main", title: "zsh — cmux", cwd: "~/src/cmux", cols: 80, rows: 24, running: true, createdAt: created),
                                 mode: .shell)
        let s = shell.shell
        var replay = "Last login: Thu Oct  8 09:12:44 on ttys002\r\n"
        replay += s.prompt + "ls --color\r\n" + s.lsOutput + "\r\n"
        if case .output(let status) = { var x = s; return x.run("git status") }() {
            replay += s.prompt + "git status\r\n" + status
        }
        if case .output(let log) = { var x = s; return x.run("git log") }() {
            replay += s.prompt + "git log --oneline -5\r\n" + log
        }
        replay += s.prompt
        shell.scrollback = Data(replay.utf8)

        var top = MockTerminal(info: Terminal(id: "term_top", title: "top", cwd: "~", cols: 80, rows: 24, running: true,
                                              createdAt: now.addingTimeInterval(-40 * 60).epochMillis), mode: .top)
        top.shell.directory = "~"
        top.scrollback = Data((top.shell.prompt + "top\r\n").utf8)
        return [shell, top]
    }

    // MARK: Browser

    func tabs() -> [MockTab] {
        let urls = ["https://cmux.dev", "https://github.com/manaflow-ai/cmux/pull/1421", "https://news.ycombinator.com"]
        return urls.enumerated().map { i, url in
            let page = page(for: url)
            return MockTab(tab: BrowserTab(id: "tab_\(i + 1)", url: page.url, title: page.title, faviconUrl: nil, active: i == 0), page: page)
        }
    }

    func page(for url: String) -> MockPage {
        let host = URL(string: url)?.host ?? url
        let path = URL(string: url)?.path ?? ""
        if host.hasSuffix("cmux.dev") {
            return MockPage(url: url, title: path.count > 1 ? "\(path.dropFirst().capitalized) — cmux" : "cmux — The terminal built for coding agents",
                            site: "cmux", accent: (0.37, 0.36, 0.90), dark: false,
                            headline: path.count > 1 ? String(path.dropFirst()).replacingOccurrences(of: "-", with: " ").capitalized : "The terminal built for coding agents",
                            subtitle: "Run Claude Code, Codex and friends side by side. Get notified the moment one needs you.",
                            sections: [
                                .init(title: "Vertical tabs", body: "Every workspace shows its branch, ports and the last agent message, so you always know which one needs attention."),
                                .init(title: "Notifications", body: "Agents ring a bell when they finish or ask for permission. Jump straight to the pane that called you."),
                                .init(title: "Built-in browser", body: "Preview your dev server next to the agent that is changing it. Scriptable from the CLI."),
                                .init(title: "On your phone", body: "Approve permissions, read transcripts and attach to terminals from anywhere, peer to peer."),
                            ],
                            code: "$ brew install --cask cmux\n$ cmux open ~/src/my-app\n✓ Workspace ready (3 panes)")
        }
        if host.hasSuffix("github.com") {
            return MockPage(url: url, title: "terminal: debounce resize during rotation · Pull Request #1421 · manaflow-ai/cmux",
                            site: "GitHub", accent: (0.14, 0.53, 0.25), dark: true,
                            headline: "terminal: debounce resize during rotation #1421",
                            subtitle: "Open · aziz wants to merge 3 commits into main from fix-resize-flake",
                            sections: [
                                .init(title: "Conversation (4)", body: "Maya approved these changes. “Nice catch on the double callback. Ship it.”"),
                                .init(title: "Checks: 12 successful", body: "macOS unit tests ✓  iOS build ✓  UI tests ✓  lint ✓  docs ✓"),
                                .init(title: "Files changed (2)", body: "Sources/Terminal/TerminalSurface.swift  +14 −2\nTests/TerminalResizeTests.swift  +38 −0"),
                            ],
                            code: "@@ -186,6 +186,18 @@\n-    surface.resize(cols: size.cols, rows: size.rows)\n+    pendingSize = size\n+    guard !resizeScheduled else { return }\n+    resizeScheduled = true")
        }
        if host.hasSuffix("ycombinator.com") {
            return MockPage(url: url, title: "Hacker News", site: "Hacker News", accent: (1.0, 0.40, 0.0), dark: false,
                            headline: "Top stories", subtitle: "Updated every few minutes",
                            sections: [
                                .init(title: "1. Show HN: A terminal designed for coding agents", body: "412 points · 188 comments · 3 hours ago"),
                                .init(title: "2. Peer-to-peer data channels without a media server", body: "233 points · 71 comments · 5 hours ago"),
                                .init(title: "3. The quiet return of the thin client", body: "198 points · 154 comments · 6 hours ago"),
                                .init(title: "4. Fragmentation done right: 16 KiB at a time", body: "121 points · 40 comments · 8 hours ago"),
                                .init(title: "5. What I learned writing a mock server for UI work", body: "96 points · 22 comments · 9 hours ago"),
                            ],
                            code: nil)
        }
        let title = path.count > 1 ? String(path.split(separator: "/").last ?? "").replacingOccurrences(of: "-", with: " ").capitalized : host
        return MockPage(url: url, title: "\(title) · \(host)", site: host, accent: (0.2, 0.45, 0.85), dark: false,
                        headline: title.isEmpty ? host : title, subtitle: "A page rendered by the cmux demo host.",
                        sections: [
                            .init(title: "Overview", body: "This content is generated so the browser view has something realistic to stream."),
                            .init(title: "Details", body: "Scroll, tap a card, type in the search field, or go back and forward."),
                            .init(title: "More", body: "Frames are JPEG, ack-paced with at most two unacknowledged frames in flight."),
                        ],
                        code: nil)
    }
}
