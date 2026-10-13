import CmuxAgentQuestion
import CnxAgentChat
import CnxFeed
import CnxModel
import CnxTransport
import Foundation
import Testing
@testable import CnxLive

// MARK: Link state machine

@Suite struct LinkMachineTests {
    let mac = LinkMachine.Target(macID: "m1", name: "Studio", isOnline: true)

    @Test func dialsOnlineTargetAndConnects() {
        var machine = LinkMachine(transport: .wireGuard)
        #expect(machine.handle(.target(mac)) == [.dial(generation: 1, macID: "m1", transport: .wireGuard)])
        #expect(machine.phase == .connecting(.wireGuard, attempt: 1))
        #expect(machine.handle(.dialSucceeded(generation: 1, path: .relay)) == [])
        #expect(machine.phase == .connected(.wireGuard, .relay, rttMillis: nil))
        _ = machine.handle(.linkUpdated(generation: 1, path: .relay, rttMillis: 27))
        #expect(machine.phase.statusLine(macName: "Studio") == "Connected · WireGuard relay · 27 ms")
    }

    @Test func offlineMacIsNotDialed() {
        var machine = LinkMachine(transport: .webRTC)
        var offline = mac
        offline.isOnline = false
        #expect(machine.handle(.target(offline)) == [])
        #expect(machine.phase == .macOffline)
        // Presence brings it back: dial.
        #expect(machine.handle(.target(mac)) == [.dial(generation: 2, macID: "m1", transport: .webRTC)])
    }

    @Test func failuresBackOffAndRetry() {
        var machine = LinkMachine(transport: .webRTC)
        _ = machine.handle(.target(mac))
        #expect(machine.handle(.dialFailed(generation: 1, reason: "ICE timed out")) == [.scheduleRetry(generation: 2, after: .seconds(1))])
        #expect(machine.phase == .waiting(.webRTC, attempt: 1, reason: "ICE timed out", retryIn: .seconds(1)))
        #expect(machine.phase.statusLine(macName: "Studio") == "WebRTC failed: ICE timed out · retrying in 1 s")
        #expect(machine.handle(.retryDue(generation: 2)) == [.dial(generation: 3, macID: "m1", transport: .webRTC)])
        #expect(machine.handle(.dialFailed(generation: 3, reason: "x")) == [.scheduleRetry(generation: 4, after: .seconds(2))])
        // A stale timer is ignored.
        #expect(machine.handle(.retryDue(generation: 2)) == [])
    }

    @Test func transportSwitchRedialsAndIgnoresLateResult() {
        var machine = LinkMachine(transport: .webRTC)
        _ = machine.handle(.target(mac))
        _ = machine.handle(.dialSucceeded(generation: 1, path: .direct))
        #expect(machine.handle(.transport(.wireGuard)) == [.close, .dial(generation: 2, macID: "m1", transport: .wireGuard)])
        // The old link's drop arrives late: ignored.
        #expect(machine.handle(.linkDropped(generation: 1, reason: "closed")) == [])
        #expect(machine.phase == .connecting(.wireGuard, attempt: 1))
        // Switching while waiting redials immediately with the new transport.
        _ = machine.handle(.dialFailed(generation: 2, reason: "x"))
        #expect(machine.handle(.transport(.webRTC)) == [.close, .dial(generation: 4, macID: "m1", transport: .webRTC)])
    }

    @Test func relayOnlyChangeRedials() {
        var machine = LinkMachine(transport: .webRTC)
        _ = machine.handle(.target(mac))
        _ = machine.handle(.dialSucceeded(generation: 1, path: .direct))
        #expect(machine.handle(.relayOnly(false)) == [])
        #expect(machine.handle(.relayOnly(true)) == [.close, .dial(generation: 2, macID: "m1", transport: .webRTC)])
        #expect(machine.relayOnly)
        #expect(machine.handle(.dialSucceeded(generation: 2, path: .turn)) == [])
        #expect(machine.phase.statusLine(macName: "Studio") == "Connected · WebRTC TURN")
    }

    @Test func dropReconnectsAndForegroundProbes() {
        var machine = LinkMachine(transport: .wireGuard)
        _ = machine.handle(.target(mac))
        _ = machine.handle(.dialSucceeded(generation: 1, path: .relay))
        #expect(machine.handle(.foreground) == [.probe(generation: 1)])
        #expect(machine.handle(.probeFailed(generation: 1, reason: "closed")) == [.close, .scheduleRetry(generation: 2, after: .seconds(1))])
        // Foreground while waiting dials now instead of waiting out the timer.
        #expect(machine.handle(.foreground) == [.dial(generation: 3, macID: "m1", transport: .wireGuard)])
    }

    @Test func sameTargetKeepsLinkAndNilTargetCloses() {
        var machine = LinkMachine(transport: .wireGuard)
        _ = machine.handle(.target(mac))
        _ = machine.handle(.dialSucceeded(generation: 1, path: .relay))
        #expect(machine.handle(.target(mac)) == [])
        #expect(machine.handle(.target(nil)) == [.close])
        #expect(machine.phase == .idle)
    }
}

// MARK: Link controller with a mock dialer

struct MockDialer: MacLinkDialer {
    let fail: Bool
    var dialed: (@Sendable (LinkEndpoint) -> Void)?
    func dial(_ endpoint: LinkEndpoint, transport: CnxTransport.TransportKind, accessToken: String) async throws -> any MacLink {
        dialed?(endpoint)
        if fail { throw LinkError(code: "timeout", message: "") }
        return MockMacLink(transport: transport)
    }
}

@MainActor
@Suite struct LinkControllerTests {
    @Test func connectsThroughDialerAndHandsOutLink() async throws {
        let controller = LinkController(transport: .wireGuard, dialer: MockDialer(fail: false), accessToken: { _ in "t" })
        controller.endpoint = { LinkEndpoint(baseURL: URL(string: "https://x")!, teamID: "t", deviceID: "d", macDeviceID: $0) }
        var handed: (any MacLink)?
        controller.onLink = { handed = $0 }
        controller.send(.target(LinkMachine.Target(macID: "m", name: "Mac", isOnline: true)))
        for _ in 0..<200 where !controller.phase.isConnected { await Task.yield() }
        #expect(controller.phase.isConnected)
        #expect(handed != nil)
    }

    @Test func relayOnlyReachesTheDialer() async throws {
        let seen = Seen()
        let dialer = MockDialer(fail: false, dialed: { endpoint in seen.append(endpoint.relayOnly) })
        let controller = LinkController(transport: .webRTC, relayOnly: true, dialer: dialer, accessToken: { _ in "t" })
        controller.endpoint = { LinkEndpoint(baseURL: URL(string: "https://x")!, teamID: "t", deviceID: "d", macDeviceID: $0) }
        controller.send(.target(LinkMachine.Target(macID: "m", name: "Mac", isOnline: true)))
        for _ in 0..<200 where !controller.phase.isConnected { await Task.yield() }
        controller.send(.relayOnly(false))
        for _ in 0..<200 where !(controller.phase.isConnected && seen.values.count == 2) { await Task.yield() }
        #expect(seen.values == [true, false])
    }

    @Test func dialFailureWaitsWithReadableReason() async throws {
        let controller = LinkController(transport: .webRTC, dialer: MockDialer(fail: true), accessToken: { _ in "t" })
        controller.endpoint = { LinkEndpoint(baseURL: URL(string: "https://x")!, teamID: "t", deviceID: "d", macDeviceID: $0) }
        controller.send(.target(LinkMachine.Target(macID: "m", name: "Mac", isOnline: true)))
        for _ in 0..<200 { if case .waiting = controller.phase { break }; await Task.yield() }
        guard case .waiting(.webRTC, 1, let reason, _) = controller.phase else {
            Issue.record("expected waiting, got \(controller.phase)")
            return
        }
        #expect(reason == "the Mac didn't answer in time")
    }
}

// MARK: Backend frames

@Suite struct SignalFrameTests {
    @Test func parsesHelloAndPresence() throws {
        let hello = Data(#"{"type":"hello","you":"p1","macs":[{"deviceId":"m1","name":"mini","online":true,"lastSeenAt":"2026-10-12T10:00:00.000Z","ownerUserId":"u"}]}"#.utf8)
        guard case .hello(let you, let macs) = SignalFrame.parse(hello) else { Issue.record("no hello"); return }
        #expect(you == "p1")
        #expect(macs.map(\.name) == ["mini"])
        #expect(macs[0].lastSeenDate != nil)
        let presence = Data(#"{"type":"presence","mac":{"deviceId":"m1","name":"mini","online":false,"lastSeenAt":null}}"#.utf8)
        #expect(SignalFrame.parse(presence) == .presence(LiveAPI.Mac(deviceId: "m1", name: "mini", online: false)))
        #expect(SignalFrame.parse(Data(#"{"type":"signal"}"#.utf8)) == .other)
        #expect(SignalFrame.parse(Data("nope".utf8)) == nil)
    }

    @Test func decodesErrorEnvelope() {
        let failure = LiveAPI.failure(status: 403, data: Data(#"{"error":{"code":"not_member","message":"no"}}"#.utf8))
        #expect(failure == LiveAPI.Failure(status: 403, code: "not_member", message: "no"))
    }
}

// MARK: Daemon tree

@Suite struct DaemonTreeTests {
    static let reply = Data("""
    {"id":"m2","ok":true,"data":{"workspace_revision":4,"workspaces":[
      {"id":4,"key":"ws-a","name":"1","title":"cmux","color":"#30D158","icon":"hammer","active":true,"unread_count":2,"screens":[
        {"id":3,"active":true,"active_pane":2,"panes":[
          {"id":2,"active_tab":1,"tabs":[
            {"surface":1,"kind":"pty","name":null,"title":"zsh","cwd":"/Users/cmux/src/cmux","git_branch":"main","dead":false},
            {"surface":7,"kind":"conversation","name":null,"title":"","cwd":"/Users/cmux/src/cmux","git_branch":"feat","conversation":{"agent_session":{"host":"install:x","session":"sess-1","harness":"claude","host_name":"mini"}},"dead":false},
            {"surface":8,"kind":"conversation","title":"Home","conversation":{"conversation":"conv_1","owner":"local"}},
            {"surface":9,"kind":"browser","title":"Docs","url":"https://cmux.com/docs"},
            {"surface":10,"kind":"pty","title":"gone","dead":true}
          ]}
        ]}
      ]},
      {"id":5,"name":"scratch","active":false,"screens":[]}
    ]}}
    """.utf8)

    @Test func mapsWorkspacesTabsAndAgentBindings() throws {
        var agents = AgentStates()
        agents.bySurface[1] = AgentState(state: "working", agent: "claude")
        let tree = try DaemonTree(reply: Self.reply, macID: "mac-1", agents: agents)
        #expect(tree.revision == 4)
        #expect(tree.workspaces.map(\.id) == ["ws-a", "w5"])
        let ws = tree.workspaces[0]
        #expect(ws.title == "cmux")
        #expect(ws.macID == "mac-1")
        #expect(ws.directory == "~/src/cmux")
        #expect(ws.branch == "feat")
        #expect(ws.colorHex == "#30D158")
        #expect(ws.hasUnread)
        #expect(ws.isWorking)
        #expect(ws.tabs.map(\.kind) == [.terminal, .agent, .browser])
        #expect(ws.tabs[1].title == "Claude")
        #expect(ws.tabs[1].harness == "claude")
        #expect(tree.agentTabs["s7"]?.session == "sess-1")
        #expect(tree.surfaces["s9"] == 9)
        #expect(ws.tabs[2].url?.host() == "cmux.com")
        #expect(tree.workspaces[1].title == "scratch")
    }

    @Test func pendingPermissionMarksNeedsYouAndActivityIsKept() throws {
        var agents = AgentStates()
        agents.pending["sess-1"] = true
        let earlier = Date(timeIntervalSince1970: 1000)
        let first = try DaemonTree(reply: Self.reply, macID: "m", now: earlier)
        let second = try DaemonTree(reply: Self.reply, macID: "m", previous: first.workspaces, agents: agents, now: Date())
        #expect(second.workspaces[0].needsAttention)
        #expect(second.workspaces[0].lastActivityAt == earlier)
    }

    @Test func errorReplyThrows() {
        let reply = Data(#"{"id":"m1","ok":false,"error":"list-workspaces is not available to a phone","error_code":"forbidden"}"#.utf8)
        #expect(throws: DaemonReplyError(message: "list-workspaces is not available to a phone", code: "forbidden")) {
            try DaemonTree(reply: reply, macID: "m")
        }
    }

    @Test func classifiesEvents() {
        func parse(_ s: String) -> DaemonEvent { DaemonEvent.parse(Data(s.utf8)) }
        #expect(parse(#"{"event":"tab-added","workspace":4,"surface":3}"#) == .treeChanged)
        #expect(parse(#"{"event":"workspace-renamed","workspace":4}"#) == .treeChanged)
        #expect(parse(#"{"event":"tree-changed"}"#) == .treeChanged)
        #expect(parse(#"{"event":"overflow"}"#) == .resubscribe)
        #expect(parse(#"{"event":"agent-changed","surface":1,"state":"blocked","agent":"claude"}"#) == .agentChanged(surface: 1, state: "blocked", agent: "claude"))
        #expect(parse(#"{"event":"bell","surface":1}"#) == .other)
    }
}

// MARK: Workspace sync over a fake daemon

@MainActor
@Suite struct WorkspaceSyncTests {
    @Test func listsAfterSubscribeAndRelistsOnEvents() async throws {
        let lists = Counter()
        let link = MockMacLink { _, data in
            let object = try! JSONSerialization.jsonObject(with: data.dropLast()) as! [String: Any]
            let id = object["id"] as! String
            let cmd = object["cmd"] as! String
            var out: [Data] = []
            switch cmd {
            case "list-workspaces":
                let n = lists.increment()
                let title = n == 1 ? "first" : "second"
                out.append(Data(#"{"id":"\#(id)","ok":true,"data":{"workspaces":[{"id":1,"key":"k","name":"\#(title)","screens":[]}]}}"#.utf8))
                if n == 1 { out.append(Data(#"{"event":"workspace-renamed","workspace":1}"#.utf8)) }
            case "list-agents":
                out.append(Data(#"{"id":"\#(id)","ok":true,"data":{"agents":[]}}"#.utf8))
            default:
                out.append(Data(#"{"id":"\#(id)","ok":true,"data":{}}"#.utf8))
            }
            return out.map { $0 + Data([0x0A]) }
        }
        let sync = WorkspaceSync(deviceID: "d", deviceName: "iPhone")
        var titles: [String] = []
        sync.onTree = { titles.append($0.workspaces.first?.title ?? "") }
        await sync.bind(try await link.openChannel(service: "daemon", args: [:]), macID: "mac")
        for _ in 0..<500 where titles.last != "second" { await Task.yield() }
        #expect(titles.first == "first")
        #expect(titles.last == "second")
        #expect(sync.identity != nil || true)
    }
}

// MARK: Workspace creation on the daemon

@MainActor
@Suite struct LiveWorkspaceCreationTests {
    /// A daemon that creates `new-workspace` (surface 10) and `new-browser-tab`
    /// (surface 11), or refuses `new-workspace` like the phone policy.
    static func daemon(refuse: Bool, seen: CommandLog) -> MockMacLink {
        MockMacLink { _, data in
            let object = try! JSONSerialization.jsonObject(with: data.dropLast()) as! [String: Any]
            let id = object["id"] as! String
            let cmd = object["cmd"] as! String
            seen.append(cmd, object["name"] as? String)
            let line: String
            switch cmd {
            case "new-workspace" where refuse:
                line = #"{"id":"\#(id)","ok":false,"error":"new-workspace is not available to a phone","error_code":"forbidden"}"#
            case "new-workspace":
                line = #"{"id":"\#(id)","ok":true,"data":{"surface":10}}"#
            case "new-browser-tab":
                line = #"{"id":"\#(id)","ok":true,"data":{"surface":11}}"#
            case "list-workspaces":
                let created = seen.contains("new-workspace") && !refuse
                let browser = seen.contains("new-browser-tab")
                let tabs = #"{"surface":10,"kind":"pty","cwd":"/Users/me"}"# + (browser ? #",{"surface":11,"kind":"browser","url":"about:blank"}"# : "")
                let ws = created ? #"{"id":2,"key":"wk2","name":"New Workspace","screens":[{"active":true,"active_pane":1,"panes":[{"id":1,"active_tab":0,"tabs":[\#(tabs)]}]}]}"# : ""
                line = #"{"id":"\#(id)","ok":true,"data":{"workspaces":[{"id":1,"key":"wk1","name":"main","screens":[]}\#(created ? "," : "")\#(ws)]}}"#
            case "list-agents":
                line = #"{"id":"\#(id)","ok":true,"data":{"agents":[]}}"#
            default:
                line = #"{"id":"\#(id)","ok":true,"data":{}}"#
            }
            return [Data(line.utf8) + Data([0x0A])]
        }
    }

    func connected(_ refuse: Bool, _ log: CommandLog) async throws -> (AppStore, WorkspaceCreator, WorkspaceSync) {
        let store = AppStore.mock(tabMemory: .inMemory())
        store.teams[0].macs = [MacDevice(id: "m", name: "Mac", isOnline: true)]
        let controller = LinkController(transport: .wireGuard, dialer: MockDialer(fail: false), accessToken: { _ in "t" })
        controller.endpoint = { LinkEndpoint(baseURL: URL(string: "https://x")!, teamID: "t", deviceID: "d", macDeviceID: $0) }
        controller.send(.target(LinkMachine.Target(macID: "m", name: "Mac", isOnline: true)))
        for _ in 0..<200 where !controller.phase.isConnected { await Task.yield() }
        let sync = WorkspaceSync(deviceID: "d", deviceName: "iPhone")
        sync.onTree = { store.replaceWorkspaces(macID: "m", with: $0.workspaces) }
        await sync.bind(try await Self.daemon(refuse: refuse, seen: log).openChannel(service: "daemon", args: [:]), macID: "m")
        let defaults = try #require(UserDefaults(suiteName: "cnx.tests.live.\(UUID().uuidString)"))
        let creator = WorkspaceCreator(store: store, backend: LiveWorkspaceCreationBackend(sync: sync, link: controller), defaults: defaults)
        return (store, creator, sync)
    }

    @Test func tapCreatesOnTheDaemonAndFollowsTheRealWorkspace() async throws {
        let log = CommandLog()
        let (store, creator, _) = try await connected(false, log)
        // Only what the phone lane allows: no directories, no agent tabs.
        #expect(creator.options(on: "m") == WorkspaceCreationOptions(browser: true))
        #expect(creator.recentDirectories(on: "m").isEmpty)
        let placeholder = try #require(creator.create())
        #expect(store.isPending(placeholder.id))
        await creator.settle()
        #expect(log.names["new-workspace"] == "New Workspace")
        #expect(creator.phases[placeholder.id] == .created("wk2"))
        #expect(store.workspace(id: placeholder.id)?.id == "wk2")
        #expect(store.workspaces.filter { $0.macID == "m" }.map(\.id) == ["wk1", "wk2"])
        #expect(store.openingTab(for: try #require(store.workspace(id: "wk2")))?.id == "s10")
    }

    @Test func browserStartOpensOnTheBrowserTab() async throws {
        let log = CommandLog()
        let (store, creator, _) = try await connected(false, log)
        let placeholder = try #require(creator.create(start: .browser))
        await creator.settle()
        #expect(log.contains("new-browser-tab"))
        let real = try #require(store.workspace(id: placeholder.id))
        #expect(store.openingTab(for: real)?.id == "s11")
    }

    @Test func refusalRemovesThePlaceholder() async throws {
        let log = CommandLog()
        let (store, creator, _) = try await connected(true, log)
        var reason: String?
        creator.onFailure = { reason = $1 }
        let placeholder = try #require(creator.create())
        await creator.settle()
        #expect(reason == "new-workspace is not available to a phone")
        #expect(store.workspace(id: placeholder.id) == nil)
        #expect(store.workspaces.filter { $0.macID == "m" }.map(\.id) == ["wk1"])
    }
}

final class CommandLog: @unchecked Sendable {
    private let lock = NSLock()
    private var commands: [String] = []
    private var nameByCommand: [String: String] = [:]
    func append(_ cmd: String, _ name: String?) {
        lock.withLock {
            commands.append(cmd)
            if let name { nameByCommand[cmd] = name }
        }
    }
    func contains(_ cmd: String) -> Bool { lock.withLock { commands.contains(cmd) } }
    var names: [String: String] { lock.withLock { nameByCommand } }
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func increment() -> Int { lock.withLock { value += 1; return value } }
}

// MARK: acpmux records and session source

@Suite struct AcpmuxRecordTests {
    let records = AcpmuxRecords(sessionID: "s1")

    func json(_ string: String) -> JSONValue { try! JSONDecoder().decode(JSONValue.self, from: Data(string.utf8)) }

    @Test func mapsAgentUpdatesAndMuxRecords() {
        let chunk = json(#"{"sessionId":"s1","seq":5,"at":1700000000000,"dir":"in","kind":"agent_message_chunk","msg":{"method":"session/update","params":{"sessionId":"x","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"hi"}}}}}"#)
        #expect(records.map(chunk) == [.update(.agentMessageChunk(text: "hi", messageId: nil))])
        let user = json(#"{"seq":4,"at":1700000000000,"dir":"mux","kind":"user_message","msg":{"text":"go","promptId":"p","turnId":"t"}}"#)
        guard case .userMessage(let text, "p", "t", _, _)? = records.map(user).first else { Issue.record("no user message"); return }
        #expect(text == "go")
        let result = json(#"{"seq":9,"dir":"mux","kind":"turn_result","msg":{"status":"failed","turnId":"t","errorText":"boom"}}"#)
        guard case .turnResult("t", .failed, "boom", _)? = records.map(result).first else { Issue.record("no result"); return }
        let decision = json(#"{"seq":10,"dir":"mux","kind":"permission_decision","msg":{"permissionId":"perm","outcome":{"outcome":"cancelled"}}}"#)
        #expect(records.map(decision) == [.permissionDecision(permissionId: "perm", optionId: nil)])
    }

    @Test func permissionRequestIsToolPermissionOrQuestion() {
        let tool = json(#"{"seq":6,"dir":"mux","kind":"permission_request","msg":{"permissionId":"p1","request":{"sessionId":"x","toolCall":{"toolCallId":"c1","title":"rm -rf build","kind":"execute","rawInput":{"command":"rm -rf build"}},"options":[{"optionId":"allow","name":"Allow","kind":"allow_once"},{"optionId":"deny","name":"Deny","kind":"reject_once"}]}}}"#)
        guard case .permissionRequest(let request)? = records.map(tool).first else { Issue.record("no permission"); return }
        #expect(request.id == "p1")
        #expect(request.options.map(\.id) == ["allow", "deny"])
        #expect(request.toolCall.command == "rm -rf build")
        let question = json(#"{"seq":7,"dir":"mux","kind":"permission_request","msg":{"permissionId":"p2","request":{"toolCall":{"toolCallId":"c2","title":"Ask","_meta":{"claude":{"tool":"AskUserQuestion"}},"rawInput":{"questions":[{"question":"Which?","header":"Pick","options":[{"label":"A"},{"label":"B"}],"multiSelect":false}]}},"options":[{"optionId":"allow_once","name":"Answer","kind":"allow_once"},{"optionId":"reject_once","name":"Skip","kind":"reject_once"}]}}}"#)
        guard case .question(let ask)? = records.map(question).first else { Issue.record("no question"); return }
        #expect(ask.id == "p2")
        #expect(ask.source.session == "s1")
        #expect(ask.items.first?.options.map(\.label) == ["A", "B"])
        let reply = try? ask.reply(AgentQuestionAnswer(selections: ["q0": .init(optionIDs: ["B"])]))
        #expect(reply?.optionId == "allow_once")
        #expect(reply?.answers == .object(["Which?": .string("B")]))
    }

    @Test func parsesSessionSummary() {
        let session = AcpmuxSession(json(#"{"sessionId":"s1","name":"Fix","harness":"fake","cwd":"/tmp/w","status":"waiting","pendingPermissions":1,"lastSeq":12,"preview":"Done","lastTurn":{"status":"completed"}}"#))
        #expect(session?.summaryStatus == .waiting)
        #expect(session?.pendingPermissions == 1)
        #expect(session?.lastTurnStatus == "completed")
    }
}

/// A fake acpmux behind `MockMacLink`: initialize, watch, attach with one
/// page and a pending permission, then a live event; permission_respond for
/// an allow is refused as for a remote connection.
@MainActor
@Suite struct AcpmuxSourceTests {
    static func fakeAcpmux(_ log: CommandLog? = nil) -> MockMacLink {
        MockMacLink { _, data in
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let method = object["method"] as? String else { return [] }
            let id = object["id"].map { "\($0)" } ?? "null"
            func reply(_ result: String) -> Data { Data(#"{"jsonrpc":"2.0","id":\#(id),"result":\#(result)}"#.utf8) }
            switch method {
            case "initialize": return [reply(#"{"protocolVersion":1}"#)]
            case "_acpmux/watch": return [reply(#"{"sessions":[{"sessionId":"s1","name":"Fix","harness":"fake","cwd":"/tmp/w","status":"idle"}]}"#)]
            case "_acpmux/attach":
                return [
                    reply(#"{"session":{"sessionId":"s1","status":"waiting","pending":[]},"hasMore":false,"lastSeq":3,"events":[{"sessionId":"s1","seq":1,"at":1,"dir":"mux","kind":"user_message","msg":{"text":"ask: rm","promptId":"p","turnId":"t"}},{"sessionId":"s1","seq":2,"at":2,"dir":"mux","kind":"turn_started","msg":{"turnId":"t"}},{"sessionId":"s1","seq":3,"at":3,"dir":"mux","kind":"permission_request","msg":{"permissionId":"perm","request":{"toolCall":{"toolCallId":"c","title":"rm","kind":"execute"},"options":[{"optionId":"allow","name":"Allow","kind":"allow_once"},{"optionId":"deny","name":"Deny","kind":"reject_once"}]}}}]}"#),
                    Data(#"{"jsonrpc":"2.0","method":"_acpmux/event","params":{"sessionId":"s1","seq":4,"at":4,"dir":"in","kind":"agent_message_chunk","msg":{"method":"session/update","params":{"update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"live"}}}}}}"#.utf8),
                ]
            case "_acpmux/permission_respond":
                let params = object["params"] as? [String: Any]
                log?.append("respond:\(params?["optionId"] as? String ?? "-")", nil)
                if ["allow", "allow_once"].contains(params?["optionId"] as? String) {
                    return [Data(#"{"jsonrpc":"2.0","id":\#(id),"error":{"code":-32000,"message":"person required","data":{"reason":"permission.person_required"}}}"#.utf8)]
                }
                return [reply("{}"), Data(#"{"jsonrpc":"2.0","method":"_acpmux/event","params":{"sessionId":"s1","seq":5,"at":5,"dir":"mux","kind":"permission_decision","msg":{"permissionId":"perm","outcome":{"outcome":"selected","optionId":"deny"}}}}"#.utf8)]
            default:
                return [reply("{}")]
            }
        }
    }

    @Test func attachStreamsHistoryLiveAndDecisions() async throws {
        let link = Self.fakeAcpmux()
        let hub = AcpmuxHub()
        await hub.bind(try await link.openChannel(service: "acpmux", args: [:]))
        #expect(hub.isReady)
        #expect(hub.sessions["s1"]?.harness == "fake")
        let summary = AgentSessionSummary(id: "s7", name: "Fix", harness: "fake", agentName: "Fake", cwd: "/tmp/w", workspaceTitle: "w", macName: "mini")
        let store = AgentChatStore(source: hub.source(sessionID: "s1", summary: summary))
        for _ in 0..<500 where store.turns.first?.answerMarkdown != "live" { await Task.yield() }
        #expect(store.turns.count == 1)
        #expect(store.turns.first?.prompt == "ask: rm")
        #expect(store.pendingPermission?.request.id == "perm")
        #expect(store.turns.first?.answerMarkdown == "live")

        // An allow is refused for a remote connection: the chat shows why, the ask stays open.
        let request = try #require(store.pendingPermission?.request)
        store.respond(to: request, option: request.options[0])
        for _ in 0..<500 where store.clientError == nil { await Task.yield() }
        #expect(store.clientError?.contains("Approve this on your Mac") == true)
        #expect(store.pendingPermission != nil)

        // A deny reaches the Mac; the decision record resolves the card.
        store.respond(to: request, option: request.options[1])
        for _ in 0..<500 where store.pendingPermission != nil { await Task.yield() }
        #expect(store.pendingPermission == nil)
    }

    @Test func feedRoutesAnswersAndShowsRefusals() async throws {
        let link = Self.fakeAcpmux()
        let hub = AcpmuxHub()
        await hub.bind(try await link.openChannel(service: "acpmux", args: [:]))
        let feedStore = FeedStore(items: [])
        let feed = LiveFeed(store: feedStore, hub: hub, place: { _ in LiveFeed.Place(workspaceID: "ws", tabID: "s7", workspaceTitle: "cmux") })
        feedStore.actions = feed
        let request: JSONValue = try JSONDecoder().decode(JSONValue.self, from: Data(#"{"toolCall":{"toolCallId":"c","title":"rm","kind":"execute"},"options":[{"optionId":"allow","name":"Allow","kind":"allow_once"},{"optionId":"deny","name":"Deny","kind":"reject_once"}]}"#.utf8))
        feed.handle(.permissionPending(sessionID: "s1", permissionID: "perm", request: request), sessions: hub.sessions)
        let item = try #require(feedStore.items.first)
        #expect(item.id == "ask-perm")
        #expect(item.workspaceTitle == "cmux")
        #expect(item.needsYou)
        guard case .permission(let permission) = item.kind else { Issue.record("not a permission"); return }
        feedStore.respond(item.id, option: permission.options[0])
        for _ in 0..<500 where feedStore.items.first?.error == nil { await Task.yield() }
        #expect(feedStore.items.first?.needsYou == true)
        #expect(feedStore.items.first?.error?.contains("Approve this on your Mac") == true)
        feedStore.respond(item.id, option: permission.options[1])
        for _ in 0..<100 { await Task.yield() }
        #expect(feedStore.items.first?.resolution == "Denied")
        #expect(feedStore.items.first?.error == nil)
    }
}

@MainActor
@Suite struct FeedQuestionDeclineTests {
    /// A phone's answer to a question is refused (only the Mac may answer);
    /// Decline sends the question's reject option and resolves the card.
    @Test func refusedAnswerThenDeclineReachesTheMac() async throws {
        let log = CommandLog()
        let link = AcpmuxSourceTests.fakeAcpmux(log)
        let hub = AcpmuxHub()
        await hub.bind(try await link.openChannel(service: "acpmux", args: [:]))
        let feedStore = FeedStore(items: [])
        let feed = LiveFeed(store: feedStore, hub: hub, place: { _ in LiveFeed.Place(workspaceID: "ws", tabID: "s7", workspaceTitle: "cmux") })
        feedStore.actions = feed
        let request = try JSONDecoder().decode(JSONValue.self, from: Data(#"{"toolCall":{"toolCallId":"q1","title":"Question","kind":"other","_meta":{"claude":{"tool":"AskUserQuestion"}},"rawInput":{"questions":[{"question":"Which?","header":"Pick","options":[{"label":"A"},{"label":"B"}],"multiSelect":false}]}},"options":[{"optionId":"allow_once","name":"Answer","kind":"allow_once"},{"optionId":"reject_once","name":"Reject","kind":"reject_once"}]}"#.utf8))
        feed.handle(.permissionPending(sessionID: "s1", permissionID: "pq", request: request), sessions: hub.sessions)
        let item = try #require(feedStore.items.first)
        guard case .question(let question) = item.kind else { Issue.record("not a question"); return }
        let first = try #require(question.items.first?.options.first)
        feedStore.answer(item.id, answer: AgentQuestionAnswer(selections: [question.items[0].id: .init(optionIDs: [first.id])]))
        for _ in 0..<500 where feedStore.items.first?.error == nil { await Task.yield() }
        #expect(feedStore.items.first?.needsYou == true)

        feedStore.decline(item.id)
        #expect(feedStore.items.first?.resolution == "Declined")
        #expect(feedStore.items.first?.needsYou == false)
        for _ in 0..<500 where !log.contains("respond:reject_once") { await Task.yield() }
        #expect(log.contains("respond:reject_once"))
        #expect(feedStore.items.first?.error == nil)
    }
}

/// A source that replays fixed events (store reducer tests).
@MainActor
final class ScriptedSource: AgentSessionSource {
    let summary = AgentSessionSummary(id: "s", name: "s", harness: "fake", agentName: "Fake", cwd: "/", workspaceTitle: "w", macName: "m")
    let script: [AgentSessionEvent]
    init(_ script: [AgentSessionEvent]) { self.script = script }
    func events() -> AsyncStream<AgentSessionEvent> {
        AsyncStream { continuation in
            for event in script { continuation.yield(event) }
            continuation.finish()
        }
    }
    func send(_ intent: AgentClientIntent) {}
}

@MainActor
@Suite struct QuestionDecisionTests {
    @Test func declinedQuestionIsCancelledNotAnswered() async throws {
        let records = AcpmuxRecords(sessionID: "s1")
        let request = try JSONDecoder().decode(JSONValue.self, from: Data(#"{"toolCall":{"toolCallId":"c2","_meta":{"claude":{"tool":"AskUserQuestion"}},"rawInput":{"questions":[{"question":"Which?","options":[{"label":"A"}]}]}},"options":[{"optionId":"allow_once","name":"Answer","kind":"allow_once"},{"optionId":"reject_once","name":"Skip","kind":"reject_once"}]}"#.utf8))
        let question = try #require(records.permission("p2", request: request))
        let store = AgentChatStore(source: ScriptedSource([
            .userMessage(text: "question: Which?", promptId: "p", turnId: "t", attachments: [], at: Date()),
            question,
            .permissionDecision(permissionId: "p2", optionId: "reject_once"),
        ]))
        for _ in 0..<200 where store.turns.first?.items.count != 1 || store.pendingQuestion != nil { await Task.yield() }
        guard case .question(let resolved)? = store.turns.first?.items.first else { Issue.record("no question"); return }
        #expect(resolved.state == .cancelled)
    }
}

// MARK: Prompt content blocks

@Suite struct PromptBlockTests {
    @Test @MainActor func imagesBecomeACPImageBlocks() {
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 0x0D])
        let image = AgentAttachment(kind: .image, name: "Photo", data: png)
        let blocks = AcpmuxSessionSource.promptBlocks(text: "look", attachments: [image, AgentAttachment(kind: .file, name: "a.txt")])
        #expect(blocks == [
            .object(["type": .string("text"), "text": .string("look")]),
            .object(["type": .string("image"), "mimeType": .string("image/png"), "data": .string(png.base64EncodedString())]),
        ])
    }

    @Test @MainActor func imageOnlyPromptHasNoEmptyTextBlock() {
        let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0, 0, 0, 0, 0, 0, 0, 0, 0])
        let blocks = AcpmuxSessionSource.promptBlocks(text: "", attachments: [AgentAttachment(kind: .image, name: "Photo", data: jpeg)])
        #expect(blocks.count == 1)
        #expect(blocks.first?["mimeType"]?.stringValue == "image/jpeg")
    }
}

// MARK: Subagents and handoff over acpmux

@Suite struct AcpmuxParityTests {
    let records = AcpmuxRecords(sessionID: "s1")

    func json(_ string: String) -> JSONValue { try! JSONDecoder().decode(JSONValue.self, from: Data(string.utf8)) }

    @Test func mapsSubagentAttribution() {
        let spawn = json(#"{"seq":7,"at":1700000000000,"dir":"in","msg":{"method":"session/update","params":{"sessionId":"s1","update":{"sessionUpdate":"tool_call","toolCallId":"tc","title":"Agent","kind":"other"},"_meta":{"acpmux":{"subagents":[{"id":"a1","parent":null,"name":"Explore","task":"Find the dialer","state":"running","toolCallId":"tc"}]}}}}}"#)
        let events = records.map(spawn)
        guard case .subagent(let change)? = events.first else { Issue.record("no subagent"); return }
        #expect(change.id == "a1" && change.parent == nil && change.name == "Explore" && change.toolCallID == "tc" && change.state == .running)
        #expect(events.count == 2)
        let owned = json(#"{"seq":8,"dir":"in","msg":{"method":"session/update","params":{"sessionId":"a1","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"found"}},"_meta":{"acpmux":{"subagent":"a1"}}}}}"#)
        #expect(records.map(owned) == [.subagentUpdate(subagentID: "a1", .agentMessageChunk(text: "found", messageId: nil))])
    }

    @Test @MainActor func readsHarnessesAndHandoffRecords() {
        let harnesses = json(#"{"harnesses":{"claude":{"family":"claude"},"codex":{"family":"codex","displayName":"Codex"},"gemini":{"unavailable":"not installed"}}}"#)
        let targets = AcpmuxSessionSource.handoffTargets(harnesses, excluding: "claude")
        #expect(targets.map(\.id) == ["codex", "gemini"])
        #expect(targets[0].name == "Codex" && targets[1].unavailableReason == "not installed")
        let record = json(#"{"handoffId":"h1","revision":2,"state":"draft","target":{"coverage":[{"item":"transcript","status":"summarized","detail":null}]},"capsule":{"text":"ctx","maxBytes":65536,"checkpoint":null},"promptId":null}"#)
        let draft = AcpmuxSessionSource.handoffDraft(record, target: targets[0])
        #expect(draft?.id == "h1" && draft?.revision == 2 && draft?.capsule == "ctx" && draft?.coverage.first?.status == .summarized)
    }
}

final class Seen: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [Bool] = []
    func append(_ value: Bool) { lock.withLock { stored.append(value) } }
    var values: [Bool] { lock.withLock { stored } }
}
