import CmuxCloud
import AppKit
import CmuxSurfaceCatalogModel
import Foundation
import Testing
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

extension SurfaceSocketCommandTests {
    // MARK: - surface.new_display

    /// Both adapters create through the real cloud provider and publish the guest receipt.
    @Test(arguments: [false, true])
    func newDisplayCreatesWithoutProjection(asyncAdapter: Bool) async throws {
        try await Self.withFixture { fixture in
            var creates = 0
            let coordinator = CloudDisplayCoordinator { _, _ in
                creates += 1
                return .init(exitCode: 0, stdout: Self.createdDisplaySnapshot, stderr: "")
            }
            let provider = Self.installDisplayProvider(fixture, coordinator: coordinator)
            defer { provider.suspendForFeatureFlag() }

            let result = try Self.ok(try await Self.callDisplay([
                "machine": fixture.machineID, "open": false,
                "workspace_id": "workspace:999999",
            ], asyncAdapter: asyncAdapter))
            let resource = SurfaceResourceID(machine: fixture.machine, kind: .display, key: "display:2")
            #expect(result["resource"] as? String == resource.rawValue)
            #expect(result["open"] as? Bool == false)
            #expect(result["surface_id"] == nil)
            #expect(result["projection_failed"] == nil)
            #expect(SurfaceCatalog.shared.resources[resource] != nil)
            #expect(creates == 1)
        }
    }

    /// Invalid input must fail before the guest allocates a display, on either adapter.
    @Test(arguments: [false, true])
    func newDisplayValidatesBeforeCreating(asyncAdapter: Bool) async throws {
        try await Self.withFixture { fixture in
            var creates = 0
            let coordinator = CloudDisplayCoordinator { _, _ in
                creates += 1
                return .init(exitCode: 0, stdout: Self.createdDisplaySnapshot, stderr: "")
            }
            let provider = Self.installDisplayProvider(fixture, coordinator: coordinator)
            defer { provider.suspendForFeatureFlag() }
            let invalidRequests: [[String: Any]] = [
                [:],
                ["machine": "local", "open": false],
                ["machine": fixture.machineID, "workspace_id": "workspace:999999"],
                ["machine": fixture.machineID, "surface_id": UUID().uuidString],
            ]
            for params in invalidRequests {
                let error = try Self.error(try await Self.callDisplay(params, asyncAdapter: asyncAdapter))
                #expect(error["code"] as? String == "invalid_params")
            }
            #expect(creates == 0)
        }
    }

    /// A workspace can disappear while guest creation is in flight; keep the new resource.
    @Test(arguments: [false, true])
    func newDisplayPreservesTheResourceWhenProjectionFails(asyncAdapter: Bool) async throws {
        try await Self.withFixture { fixture in
            let destination = try #require(fixture.manager.selectedWorkspace)
            _ = try #require(fixture.manager.addWorkspaceIfActive(select: false, autoWelcomeIfNeeded: false))
            var creates = 0
            let coordinator = CloudDisplayCoordinator { _, _ in
                creates += 1
                fixture.manager.closeWorkspace(destination, recordHistory: false)
                return .init(exitCode: 0, stdout: Self.createdDisplaySnapshot, stderr: "")
            }
            let provider = Self.installDisplayProvider(fixture, coordinator: coordinator)
            defer { provider.suspendForFeatureFlag() }

            // Omitting `open` uses the default projection into the selected workspace.
            let result = try Self.ok(try await Self.callDisplay([
                "machine": fixture.machineID,
            ], asyncAdapter: asyncAdapter))
            let resource = SurfaceResourceID(machine: fixture.machine, kind: .display, key: "display:2")
            #expect(result["resource"] as? String == resource.rawValue)
            #expect(result["open"] as? Bool == false)
            #expect(result["projection_failed"] as? Bool == true)
            #expect((result["projection_error"] as? String)?.contains("cmux surface open") == true)
            #expect(SurfaceCatalog.shared.resources[resource] != nil)
            #expect(creates == 1)
        }
    }

    /// A second socket request reports busy while the first creation is still running.
    @Test(arguments: [false, true])
    func newDisplayConcurrentCreationReportsBusy(asyncAdapter: Bool) async throws {
        try await Self.withFixture { fixture in
            let started = CloudLinkFirstValue<Bool>()
            let release = CloudLinkFirstValue<Bool>()
            var creates = 0
            let coordinator = CloudDisplayCoordinator { _, _ in
                creates += 1
                started.resolve(true)
                _ = await release.result
                return .init(exitCode: 0, stdout: Self.createdDisplaySnapshot, stderr: "")
            }
            let provider = Self.installDisplayProvider(fixture, coordinator: coordinator)
            defer {
                release.resolve(true)
                provider.suspendForFeatureFlag()
            }
            let line = try Self.displayRequestLine(["machine": fixture.machineID, "open": false])
            let first = Task {
                await TerminalController.shared.processCommandUsingSocketExecutionPolicyAsync(line)
            }
            Task {
                _ = await first.value
                started.resolve(false)
            }
            try #require(await started.result)
            let busy = try Self.error(try await Self.callDisplay([
                "machine": fixture.machineID, "open": false,
            ], asyncAdapter: asyncAdapter))
            #expect(busy["code"] as? String == "busy")
            #expect(creates == 1)
            release.resolve(true)
            let response = try #require(await first.value)
            _ = try Self.ok(try #require(JSONSerialization.jsonObject(with: Data(response.utf8)) as? [String: Any]))
        }
    }

    // A guest creation receipt carries the primary display and the newly allocated display.
    private static let createdDisplaySnapshot = #"{"version":1,"canCreate":true,"displays":[{"id":"display:1","number":1,"port":6901,"state":"running"},{"id":"display:2","number":2,"port":6902,"state":"running"}],"created":"display:2"}"#

    /// Uses a real display provider with an isolated guest executor, never a live Cloud VM.
    private static func installDisplayProvider(_ fixture: Fixture, coordinator: CloudDisplayCoordinator) -> CmuxTuiSurfaceProvider {
        var summary = VMSummary(id: fixture.machineID, provider: "freestyle", status: "running", image: "cmux-devbox", createdAt: 0, base: nil)
        summary.kind = .desktop
        summary.addressIPv4 = "10.0.0.7"
        let provider = CmuxTuiSurfaceProvider(
            summary: summary,
            links: CloudMachineLinkManager(clientURL: nil, hub: nil, hostThemeColors: { nil }),
            catalog: .shared,
            displayCoordinator: coordinator
        )
        SurfaceCatalog.shared.register(provider)
        return provider
    }

    private nonisolated static func displayRequestLine(_ params: [String: Any]) throws -> String {
        let request: [String: Any] = ["id": UUID().uuidString, "method": "surface.new_display", "params": params]
        return String(decoding: try JSONSerialization.data(withJSONObject: request), as: UTF8.self)
    }

    /// Exercises the production async dispatcher as well as the in-process compatibility adapter.
    private nonisolated static func callDisplay(_ params: [String: Any], asyncAdapter: Bool) async throws -> [String: Any] {
        if !asyncAdapter { return try await call("surface.new_display", params) }
        let line = try displayRequestLine(params)
        let response = try #require(await TerminalController.shared.processCommandUsingSocketExecutionPolicyAsync(line))
        return try #require(JSONSerialization.jsonObject(with: Data(response.utf8)) as? [String: Any])
    }

}
