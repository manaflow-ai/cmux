import CmuxSurfaceCatalogModel
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Cloud first-workspace naming")
struct CloudInitialWorkspaceNameTests {
    private func decision(
        remoteName: String? = "workspace-1",
        ids: [String]? = ["ws_a"],
        directory: String? = "~",
        label: String? = "brave-otter"
    ) -> CloudInitialWorkspaceName {
        CloudInitialWorkspaceName(
            remoteWorkspaceID: "ws_a", remoteName: remoteName, machineWorkspaceIDs: ids,
            workingDirectory: directory, machineLabel: label,
            machineRawIDs: ["vm-123", "cloud:vm-123"]
        )
    }

    @Test("A new machine's sole counter-named workspace takes the machine label")
    func soleCounterWorkspaceTakesLabel() {
        #expect(decision().replacement == "brave-otter")
    }

    @Test("A project working directory names the workspace before the label")
    func projectDirectoryWins() {
        #expect(decision(directory: "~/work/todo-app").replacement == "todo-app")
        #expect(decision(directory: "/home/cmux/todo-app/").replacement == "todo-app")
    }

    @Test("Home, root and container folders never name a workspace",
          arguments: ["~", "/", "/root", "/home/cmux", "/Users/me", "~/work", "/workspace", "relative/x"])
    func homeLikeDirectoriesFallBackToLabel(directory: String) {
        #expect(CloudInitialWorkspaceName.projectName(fromWorkingDirectory: directory) == nil)
        #expect(decision(directory: directory).replacement == "brave-otter")
    }

    @Test("Names a person or a repository chose are never replaced",
          arguments: ["todo-app", "workspace", "workspace-", "workspace-1a", "my workspace-1", "Cloud VM"])
    func chosenNamesStand(name: String) {
        #expect(decision(remoteName: name).replacement == nil)
    }

    @Test("Only the machine's sole workspace is renamed")
    func secondWorkspaceKeepsCounterName() {
        #expect(decision(ids: ["ws_a", "ws_b"]).replacement == nil)
        #expect(decision(ids: nil).replacement == nil, "an unreported workspace list is not proof of a sole workspace")
        #expect(decision(ids: []).replacement == "brave-otter", "a receipt can precede the machine's list")
    }

    @Test("A raw machine id is never shown as a name")
    func rawIDIsNotALabel() {
        #expect(decision(label: "vm-123").replacement == nil)
        #expect(decision(label: "cloud:vm-123").replacement == nil)
        #expect(decision(label: "  ").replacement == nil)
        #expect(decision(label: nil).replacement == nil)
        #expect(decision(label: "workspace-3").replacement == nil)
    }

    @Test("Counter names match the daemon's shape only")
    func counterShape() {
        #expect(CloudInitialWorkspaceName.isDaemonCounterName("workspace-1"))
        #expect(CloudInitialWorkspaceName.isDaemonCounterName(" workspace-42 "))
        #expect(!CloudInitialWorkspaceName.isDaemonCounterName("workspace-١"))
        #expect(!CloudInitialWorkspaceName.isDaemonCounterName("workspace-"))
    }

    @Test("A brand-new machine's sole counter workspace is the one a named workspace takes over")
    func adoptableInitialWorkspace() {
        #expect(CloudInitialWorkspaceName.adoptableInitialWorkspaceID([(id: "ws_1", name: "workspace-1")]) == "ws_1")
        // A chosen name, a second workspace, or nothing reported: create beside it as before.
        #expect(CloudInitialWorkspaceName.adoptableInitialWorkspaceID([(id: "ws_1", name: "brave-otter")]) == nil)
        #expect(CloudInitialWorkspaceName.adoptableInitialWorkspaceID([
            (id: "ws_1", name: "workspace-1"), (id: "ws_2", name: "api"),
        ]) == nil)
        #expect(CloudInitialWorkspaceName.adoptableInitialWorkspaceID([]) == nil)
        #expect(CloudInitialWorkspaceName.adoptableInitialWorkspaceID([(id: "", name: "workspace-1")]) == nil)
    }
}

@Suite("Sidebar Cloud button presentation")
struct SidebarCloudButtonPresentationTests {
    private func machine(_ id: String, status: String, cloud: Bool = true) -> SurfaceMachineInfo {
        SurfaceMachineInfo(
            id: cloud ? .cloud(id) : .local, name: id, status: status,
            hasDesktop: false, linkState: .connected
        )
    }

    @Test("Running machines are counted; paused, standby and starting ones are not")
    func countsRunningOnly() {
        let presentation = SidebarCloudButtonPresentation.resolve(machines: [
            machine("a", status: "running"), machine("b", status: "Ready"),
            machine("c", status: "paused"), machine("d", status: "standby"),
            machine("e", status: "starting"), machine("mac", status: "running", cloud: false),
        ], hasOpenedCloud: true)
        #expect(presentation.runningCount == 2)
        #expect(presentation.countText == 2.formatted(.number))
        #expect(presentation.mark == .quiet)
    }

    @Test("A machine that needs attention marks the button over the introduction")
    func attentionWins() {
        let presentation = SidebarCloudButtonPresentation.resolve(machines: [
            machine("a", status: "running"), machine("b", status: "failed"),
        ], hasOpenedCloud: false)
        #expect(presentation.mark == .attention)
        #expect(presentation.runningCount == 1)
        #expect(!presentation.accessibilityValue.isEmpty)
    }

    @Test("The introduction dot shows only before Cloud is first opened and while no machine exists")
    func introductionNeverNags() {
        #expect(SidebarCloudButtonPresentation.resolve(machines: [], hasOpenedCloud: false).mark == .introduction)
        #expect(SidebarCloudButtonPresentation.resolve(machines: [], hasOpenedCloud: true).mark == .quiet)
        #expect(SidebarCloudButtonPresentation.resolve(
            machines: [machine("a", status: "paused")], hasOpenedCloud: false
        ).mark == .quiet, "someone with a machine already found Cloud")
    }

    @Test("No count is shown when nothing runs")
    func noCountWhenIdle() {
        let presentation = SidebarCloudButtonPresentation.resolve(machines: [], hasOpenedCloud: true)
        #expect(presentation.countText == nil)
        #expect(presentation.accessibilityValue.isEmpty)
    }
}
