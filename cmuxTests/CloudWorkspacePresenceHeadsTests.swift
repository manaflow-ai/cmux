import AppKit
import CMUXMobileCore
import CmuxSurfaceCatalogModel
import CmuxWorkspacePresence
import SwiftUI
import Testing
#if canImport(cmux_DEV)
@testable import cmux_DEV
#else
@testable import cmux
#endif

@Suite("Cloud workspace profile heads") @MainActor
struct CloudWorkspacePresenceHeadsTests {
    private final class Participants {
        var byWorkspace: [String: [WorkspacePresenceParticipant]] = [:]
    }

    @Test("native row hover and accessibility follow its workspace through join, leave and reuse")
    func namesFollowWorkspace() throws {
        let fixture = CloudSidebarOrderingFixture()
        defer { fixture.close() }
        let participants = Participants()
        participants.byWorkspace["a"] = [.init(id: "ada", displayName: "Ada Lovelace")]
        participants.byWorkspace["b"] = [.init(id: "grace", displayName: "Grace Hopper")]
        let cell = CloudTreeCellView(frame: NSRect(x: 0, y: 0, width: 240, height: 24), collaborators: { machine, workspace in
            machine == fixture.machine ? participants.byWorkspace[workspace, default: []] : []
        })
        fixture.window.contentView = cell
        func configure(_ id: String) {
            cell.configure(node: CloudTreeNode(id: id, kind: .workspace(
                machine: fixture.machine, .init(id: id, name: "Workspace \(id)", index: 0, focused: false),
                terminalCount: 0, hiddenTabCount: 0, openIn: nil
            )), machineActions: fixture.coordinator.machineActions, nodeActions: fixture.coordinator.nodeActions)
        }
        configure("a")
        #expect(cell.toolTip?.contains("Ada Lovelace") == true)
        #expect(cell.accessibilityLabel()?.contains("Ada Lovelace") == true)
        #expect(cell.toolTip?.contains("Grace Hopper") == false)
        cell.prepareForReuse()
        configure("b")
        #expect(cell.toolTip?.contains("Grace Hopper") == true)
        #expect(cell.accessibilityLabel()?.contains("Ada Lovelace") == false)
        participants.byWorkspace["b"] = []
        NotificationCenter.default.post(name: .workspacePresenceDidChange, object: nil)
        #expect(cell.toolTip == nil)
        #expect(cell.accessibilityLabel() == "Workspace b")
        participants.byWorkspace["b"] = [.init(id: "grace", displayName: "Grace Hopper")]
        NotificationCenter.default.post(name: .workspacePresenceDidChange, object: nil)
        #expect(cell.toolTip?.contains("Grace Hopper") == true)
    }

    @Test("many viewers use four heads plus overflow and keep all names accessible")
    func compactOverflow() {
        let participants = (1...12).map { WorkspacePresenceParticipant(id: "u\($0)", displayName: "Person \($0)") }
        let layout = WorkspacePresencePolicy.layout(participants: participants)
        #expect(layout.visible.map(\.id) == ["u1", "u2", "u3", "u4"])
        #expect(layout.overflow == 8)
        let host = NSHostingView(rootView: SidebarWorkspacePresenceHeadsView(participants: participants))
        #expect(host.fittingSize.width < 100)
        #expect(host.fittingSize.height == 20)
        #expect(WorkspacePresencePolicy.accessibilityLabel(participants).contains("Person 12"))
        #expect(WorkspacePresencePolicy.names([.init(id: "missing-name")]).isEmpty == false)
    }
}
