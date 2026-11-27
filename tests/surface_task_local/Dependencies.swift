import Foundation

// Standalone collaborators for the real Cloud pane reservations. They replace
// the workspace model and surface catalog, never task-local binding. Like the
// app's own values, the reservation keeps Foundation UUIDs, whose layout the
// Xcode 26 SDK hides from client code.

enum SurfaceResourceKind: Sendable { case terminal, display }

struct SurfaceMachine: Hashable, Sendable {
    let cloudMachineID: String?
}

struct SurfaceResourceID: Hashable, Sendable {
    let kind: SurfaceResourceKind
    let machine: SurfaceMachine
    let name: String
}

struct SurfaceResource: Sendable {
    let id: SurfaceResourceID
}

struct SurfaceDestination: Sendable {
    let workspaceID: UUID
}

struct SurfaceRemoteWorkspace: Sendable {
    let id: String
}

struct SurfaceRemoteView: Sendable {
    let workspace: SurfaceRemoteWorkspace
    let tabID: String?
}

struct SurfaceRemotePlacement: Sendable {
    let workspaceID: String?
    let tabID: String?
}

enum CloudDiagnosticFailure: Error, Sendable { case placement }

@MainActor
final class CloudVMLoadingPanel {
    let id = UUID()
}

struct CloudVMBinding: Sendable {
    let vmID: String
}

@MainActor
final class Workspace {
    private static var live: [UUID: Workspace] = [:]

    let id = UUID()
    let loading = CloudVMLoadingPanel()
    let cloudVMBinding: CloudVMBinding?
    var isRetiredFromOwningTabManager = false
    var panels: [UUID: AnyObject] { [loading.id: loading] }

    init(machineID: String) {
        cloudVMBinding = CloudVMBinding(vmID: machineID)
        Self.live[id] = self
    }

    static func liveWorkspace(id: UUID) -> Workspace? { live[id] }

    func cloudMachineLoadingPanel(at destination: SurfaceDestination, machineID: String) -> CloudVMLoadingPanel? {
        destination.workspaceID == id && cloudVMBinding?.vmID == machineID ? loading : nil
    }
}

@MainActor
enum SurfacePaneFactory {
    static var browserPanels: Set<UUID> = []

    static func browserPanel(panelID: UUID, in workspaceID: UUID) -> UUID? {
        browserPanels.contains(panelID) ? panelID : nil
    }
}
