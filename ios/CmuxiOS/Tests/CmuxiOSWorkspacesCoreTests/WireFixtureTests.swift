import CmuxiOSFeatureKit
import CmuxMobileWire
@testable import CmuxiOSWorkspacesCore
import Foundation
import Testing

/// Replays the A0 golden fixture (schemas/mobile-rpc/fixtures/workspace.json)
/// through the mirror, so a wire change that the phone cannot read fails here.
@Suite struct WireFixtureTests {
    static var fixtureURL: URL {
        var dir = URL(fileURLWithPath: #filePath).resolvingSymlinksInPath().deletingLastPathComponent()
        while dir.path != "/" {
            let candidate = dir.appendingPathComponent("schemas/mobile-rpc/fixtures/workspace.json")
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            dir.deleteLastPathComponent()
        }
        return dir
    }

    @Test func goldenStreamReplays() throws {
        let root = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: Self.fixtureURL))
        guard case .array(let cases)? = root["cases"] else { Issue.record("no cases"); return }
        var mirror = HostWorkspaceMirror()
        for entry in cases {
            guard let frame = entry["frame"], let type = frame["t"]?.stringValue else { continue }
            switch type {
            case "snapshot": try mirror.apply(frame.decode(as: SnapshotFrame.self))
            case "event": #expect(mirror.apply(try frame.decode(as: EventFrame.self)) == .applied)
            default: continue
            }
        }
        #expect(mirror.epoch == "ep_1791331200000_a1b2c3d4")
        let host = HostID("h_mac1A2b")
        let rows = mirror.summaries(hostID: host)
        let main = try #require(rows.first { $0.id == "ws_main01" })
        #expect(main.isPinned)
        #expect(main.group == WorkspaceGroup(id: "grp_app", name: "App", order: 0))
        #expect(main.icon == "hammer.fill")
        #expect(mirror.confirmedGroups.map(\.id) == ["grp_app", "grp_ops"])
        #expect(main.color == "#7a7a7a")
        let terminal = try #require(main.panes.first?.surfaces.first { $0.id == "tab_t01" })
        #expect(terminal.unreadCount == 3)
        #expect(terminal.preview == "Compiling (12/40)")
        #expect(main.panes.first?.surfaces.contains { $0.id == "tab_b01" } == false)
        #expect(main.status == .waitingForInput)
        #expect(!rows.contains { $0.id == "ws_new02" })
    }

    @Test func opsEncodeLikeTheFixture() throws {
        let encoder = WorkspaceOpEncoder(hostID: HostID("h_mac1A2b"))
        let close = try encoder.frame(for: .close(workspaceID: "ws_main01"), key: IntentKey(rawValue: "01JB7Q2W8M0000WSCLS001"))
        #expect(close.op == "workspace.close")
        #expect(close.params == .object(["workspace": .string("ws_main01")]))
        #expect(close.stream == "workspace:h_mac1A2b")
        #expect(close.origin == .user)
        let read = try encoder.frame(for: .markRead(workspaceID: "ws_main01"), key: IntentKey())
        #expect(read.op == "workspace.read")
        let create = try encoder.frame(for: .create(hostID: HostID("h_mac1A2b"), title: nil), key: IntentKey())
        #expect(create.params == .object(["host": .string("h_mac1A2b")]))
        #expect(MobileCatalog.v1.message(named: "workspace.close")?.kind == .op)
        #expect(MobileCatalog.v1.message(named: "workspace.preview.set")?.kind == .owner)
    }
}
