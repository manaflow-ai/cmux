import Foundation
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
final class CloudShortcutTestProvider: SurfaceProvider {
    let machine = SurfaceMachineID.cloud("shortcut-\(UUID().uuidString)")
    var info: SurfaceMachineInfo {
        SurfaceMachineInfo(id: machine, name: "Fixture", status: "running", image: nil,
            hasDesktop: false, memoryMb: nil, diskMb: nil, linkState: .connected,
            linkError: nil, cpuPercent: nil, memoryUsedMb: nil, diskUsedMb: nil)
    }
    func refresh() async {}
    func createTerminal(command: [String]?, cwd: String?, name: String?, remoteWorkspaceID: String?) async throws -> SurfaceResource {
        throw CloudDiagnosticFailure.network
    }
    func materialize(_ resource: SurfaceResource, at destination: SurfaceDestination, focus: Bool) async throws -> SurfaceProjection {
        throw CloudDiagnosticFailure.network
    }
    func projectionDidEnd(_ projection: SurfaceProjection) {}
}
