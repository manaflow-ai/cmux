import CMUXMobileCore
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Another Mac's synced workspace records must land in the surface catalog in
/// exactly the shape a cloud machine's do, so the shared tree renders them
/// without a device-specific branch: a remote workspace per record, a terminal
/// resource per terminal with one exact remote view, browsers alongside.
@Suite("Devices: workspace projection")
struct DeviceWorkspaceProjectionTests {
    private let machine = SurfaceMachineID.device(
        SurfaceDeviceInstanceID(deviceID: "3f2504e0-4f89-11d3-9a0c-0305e82c3301", tag: "default")
    )

    private func record(
        _ id: String,
        title: String,
        index: Int,
        selected: Bool = false,
        pinned: Bool = false,
        hasUnread: Bool = false,
        unreadCount: Int? = nil,
        cwd: String? = "/Users/me/src",
        terminals: [WorkspaceSyncRecord.Terminal],
        surfaces: [WorkspaceSyncRecord.Surface]? = nil
    ) -> WorkspaceSyncRecord {
        WorkspaceSyncRecord(
            id: id, windowID: "win", title: title, currentDirectory: cwd, isSelected: selected, isPinned: pinned,
            groupID: nil, preview: nil, previewAt: nil, lastActivityAt: 0, hasUnread: hasUnread, unreadCount: unreadCount,
            sortIndex: index, terminals: terminals, surfaces: surfaces
        )
    }

    private func terminal(
        _ id: String,
        title: String,
        ready: Bool = true,
        focused: Bool = false,
        agentSource: String? = nil,
        agentState: String? = nil
    ) -> WorkspaceSyncRecord.Terminal {
        WorkspaceSyncRecord.Terminal(
            id: id, title: title, currentDirectory: "/Users/me/src", isReady: ready, isFocused: focused,
            agentSource: agentSource, agentState: agentState
        )
    }

    @Test("A synced workspace becomes a remote workspace with cwd, unread count, and pin")
    func remoteWorkspaceFields() {
        let workspace = DeviceWorkspaceProjection.remoteWorkspace(
            record("w1", title: "api", index: 3, selected: true, pinned: true, hasUnread: true, unreadCount: 4, terminals: [])
        )
        #expect(workspace == SurfaceRemoteWorkspace(
            id: "w1", name: "api", index: 3, focused: true, detail: "/Users/me/src", unreadCount: 4, isPinned: true
        ))
        let legacy = DeviceWorkspaceProjection.remoteWorkspace(record("w2", title: "old", index: 0, hasUnread: true, terminals: []))
        #expect(legacy.unreadCount == 1, "a Mac too old to count unread still shows the dot as one")
        let quiet = DeviceWorkspaceProjection.remoteWorkspace(record("w3", title: "quiet", index: 1, cwd: nil, terminals: []))
        #expect(quiet.unreadCount == 0)
        #expect(quiet.detail == nil)
        #expect(quiet.isPinned == false)
    }

    @Test("Terminals project to terminal resources under their workspace, in layout order, with agent badges")
    func terminalResources() throws {
        let projection = DeviceWorkspaceProjection(machine: machine, isLive: true)
        let resources = projection.resources([
            record("w1", title: "api", index: 0, terminals: [
                terminal("t1", title: "zsh", focused: true, agentSource: "claude_code", agentState: "Working"),
                terminal("t2", title: "tail", ready: false),
            ]),
            record("w2", title: "web", index: 1, terminals: [terminal("t3", title: "vite")]),
        ])
        #expect(resources.map(\.id.key) == ["t1", "t2", "t3"])
        #expect(resources.allSatisfy { $0.kind == .terminal && $0.machine == machine })
        let first = try #require(resources.first)
        #expect(first.title == "zsh")
        #expect(first.detail == "/Users/me/src")
        #expect(first.lifecycle == .running)
        #expect(first.agent == SurfaceAgentBadge(state: "Working", source: "claude_code"))
        #expect(first.remoteWorkspace?.id == "w1")
        #expect(first.remoteViews?.count == 1)
        #expect(first.remoteViews?.first?.tabID == "t1")
        #expect(first.remoteViews?.first?.workspace.id == "w1")
        #expect(first.remoteViews?.first?.index == 0)
        #expect(first.remoteViews?.first?.focused == true)
        #expect(resources[1].lifecycle == .launching)
        #expect(resources[1].agent == nil)
        #expect(resources[1].remoteViews?.first?.index == 1)
        #expect(resources[1].remoteViews?.first?.focused == false)
        #expect(resources[2].remoteWorkspace?.name == "web")
        #expect(projection.remoteWorkspaces([record("w9", title: "x", index: 9, terminals: [])]).map(\.index) == [9])
    }

    @Test("Browsers project as browser resources; other surface kinds and duplicate ids are skipped")
    func browserResourcesAndDuplicates() {
        let projection = DeviceWorkspaceProjection(machine: machine, isLive: true)
        let resources = projection.resources([
            record("w1", title: "api", index: 0, terminals: [terminal("t1", title: "zsh"), terminal("t1", title: "dup")], surfaces: [
                WorkspaceSyncRecord.Surface(surfaceID: "t1", kind: "terminal", title: "zsh", filePath: nil),
                WorkspaceSyncRecord.Surface(surfaceID: "b1", kind: "browser", title: "localhost:3000", filePath: nil, isFocused: true),
                WorkspaceSyncRecord.Surface(surfaceID: "e1", kind: "editor", title: "main.swift", filePath: "/x/main.swift"),
            ]),
        ])
        #expect(resources.map { "\($0.kind.rawValue):\($0.id.key)" } == ["terminal:t1", "browser:b1"])
        #expect(resources[0].title == "zsh")
        #expect(resources[1].title == "localhost:3000")
        #expect(resources[1].remoteViews?.first?.focused == true)
        #expect(resources[1].remoteWorkspace?.id == "w1")
    }

    @Test("An offline link keeps every row but marks it unavailable")
    func offlineRowsAreUnavailable() {
        let projection = DeviceWorkspaceProjection(machine: machine, isLive: false)
        let records = [record("w1", title: "api", index: 0, terminals: [terminal("t1", title: "zsh"), terminal("t2", title: "x", ready: false)])]
        #expect(projection.remoteWorkspaces(records).map(\.id) == ["w1"])
        #expect(projection.resources(records).map(\.lifecycle) == [.unavailable, .unavailable])
    }

    @Test("Agent badges trim and drop empty states")
    func agentBadges() {
        #expect(DeviceWorkspaceProjection.agentBadge(source: nil, state: nil) == nil)
        #expect(DeviceWorkspaceProjection.agentBadge(source: " ", state: "\n") == nil)
        #expect(DeviceWorkspaceProjection.agentBadge(source: "codex", state: " Idle ") == SurfaceAgentBadge(state: "Idle", source: "codex"))
        #expect(DeviceWorkspaceProjection.agentBadge(source: "", state: "Idle") == SurfaceAgentBadge(state: "Idle", source: nil))
        #expect(DeviceWorkspaceProjection.agentBadge(source: "codex", state: nil) == SurfaceAgentBadge(state: "", source: "codex"))
    }

    @Test("Terminal rows decode the agent fields when present and default them when absent")
    func terminalRecordWire() throws {
        let withAgent = try JSONDecoder().decode(WorkspaceSyncRecord.Terminal.self, from: Data("""
        {"id":"t1","title":"zsh","current_directory":"/x","is_ready":true,"is_focused":false,"agent_source":"codex","agent_state":"Idle"}
        """.utf8))
        #expect(withAgent.agentSource == "codex")
        #expect(withAgent.agentState == "Idle")
        let legacy = try JSONDecoder().decode(WorkspaceSyncRecord.Terminal.self, from: Data("""
        {"id":"t1","title":"zsh","current_directory":null,"is_ready":true,"is_focused":false}
        """.utf8))
        #expect(legacy.agentSource == nil)
        #expect(legacy.agentState == nil)
        let encoded = try JSONEncoder().encode(withAgent)
        let object = try #require(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(object["agent_source"] as? String == "codex")
    }
}
