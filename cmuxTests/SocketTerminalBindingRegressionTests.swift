import AppKit
import CmuxTerminal
import Foundation
import GhosttyKit
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Regression coverage for https://github.com/manaflow-ai/cmux/issues/9330.
///
/// A replacement terminal can be live in the process registry before the
/// workspace's panel wrapper catches up. Socket reads must resolve the live
/// registry owner instead of staying bound to the stale wrapper.
@MainActor
@Suite("Socket terminal binding", .serialized)
struct SocketTerminalBindingRegressionTests {
    private struct TextWaitTimeout: Error {
        let expected: String
    }

    private static let socketWorker = DispatchQueue(
        label: "SocketTerminalBindingRegressionTests.socketWorker"
    )

    @Test func liveReplacementRebindsReadsAndReportsHealth() async throws {
        try await withAppContext { workspace in
            let originalPanel = try #require(
                workspace.focusedPanelId.flatMap { workspace.panels[$0] as? TerminalPanel }
            )
            let marker = "socket-registry-rebound-\(UUID().uuidString)"
            let replacement = TerminalSurface(
                id: originalPanel.id,
                tabId: workspace.id,
                context: GHOSTTY_SURFACE_CONTEXT_SPLIT,
                configTemplate: nil,
                initialCommand: "/bin/cat"
            )
            defer {
                replacement.teardownSurface()
                GhosttyApp.terminalSurfaceRegistry.unregister(replacement)
            }

            await waitForLiveSurface(replacement)
            #expect(
                GhosttyApp.terminalSurfaceRegistry.surface(id: originalPanel.id) === replacement,
                "The live replacement must be the canonical registry owner"
            )

            let sendEnvelope = try socketEnvelope(
                method: "surface.send_text",
                params: [
                    "workspace_id": workspace.id.uuidString,
                    "surface_id": originalPanel.id.uuidString,
                    "text": "\(marker)\r",
                ]
            )
            try #require(sendEnvelope["ok"] as? Bool == true, "\(sendEnvelope)")
            try await waitForText(marker, in: replacement)

            let readEnvelope = try await socketEnvelopeOnWorker(
                method: "surface.read_text",
                params: [
                    "workspace_id": workspace.id.uuidString,
                    "surface_id": originalPanel.id.uuidString,
                ]
            )
            try #require(readEnvelope["ok"] as? Bool == true, "\(readEnvelope)")
            let readResult = try #require(readEnvelope["result"] as? [String: Any])
            #expect((readResult["text"] as? String)?.contains(marker) == true)

            let healthEnvelope = try socketEnvelope(
                method: "surface.health",
                params: ["workspace_id": workspace.id.uuidString]
            )
            try #require(healthEnvelope["ok"] as? Bool == true, "\(healthEnvelope)")
            let healthResult = try #require(healthEnvelope["result"] as? [String: Any])
            let surfaces = try #require(healthResult["surfaces"] as? [[String: Any]])
            let row = try #require(surfaces.first { $0["id"] as? String == originalPanel.id.uuidString })
            #expect(row["socket_binding"] as? String == "registry_rebound")
        }
    }

    @Test func unavailableBindingPreservesPanelWindowHealth() async throws {
        try await withAppContext { workspace in
            let panel = try #require(
                workspace.focusedPanelId.flatMap {
                    workspace.panels[$0] as? TerminalPanel
                }
            )
            let entry = TerminalController.shared.controlSurfaceHealthEntry(
                for: panel,
                terminalTarget: nil
            )

            #expect(entry.inWindow != nil)
            #expect(entry.inWindow == panel.surface.isViewInWindow)
            #expect(entry.socketBindingRawValue == "unavailable")
        }
    }

    private func waitForLiveSurface(_ surface: TerminalSurface) async {
        guard !surface.hasLiveSurface else { return }
        let previousOnRuntimeReady = surface.onRuntimeReady
        defer { surface.onRuntimeReady = previousOnRuntimeReady }
        let readiness = AsyncStream<Void> { continuation in
            surface.onRuntimeReady = {
                previousOnRuntimeReady?()
                continuation.yield()
                continuation.finish()
            }
        }
        if surface.hasLiveSurface { return }
        for await _ in readiness { break }
    }

    private func waitForText(_ expected: String, in surface: TerminalSurface) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(10))
        while clock.now < deadline {
            if surface.visibleText()?.contains(expected) == true { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw TextWaitTimeout(expected: expected)
    }

    private func socketEnvelope(
        method: String,
        params: [String: Any]
    ) throws -> [String: Any] {
        let request: [String: Any] = ["id": method, "method": method, "params": params]
        let data = try JSONSerialization.data(withJSONObject: request)
        let line = try #require(String(data: data, encoding: .utf8))
        return try decodeEnvelope(TerminalController.shared.handleSocketLine(line))
    }

    private func socketEnvelopeOnWorker(
        method: String,
        params: [String: Any]
    ) async throws -> [String: Any] {
        let request: [String: Any] = ["id": method, "method": method, "params": params]
        let data = try JSONSerialization.data(withJSONObject: request)
        let line = try #require(String(data: data, encoding: .utf8))
        let controller = TerminalController.shared
        let raw = await withCheckedContinuation { continuation in
            Self.socketWorker.async {
                continuation.resume(returning: controller.handleSocketLine(line))
            }
        }
        return try decodeEnvelope(raw)
    }

    private func decodeEnvelope(_ raw: String) throws -> [String: Any] {
        let responseData = try #require(raw.data(using: .utf8))
        return try #require(JSONSerialization.jsonObject(with: responseData) as? [String: Any])
    }

    private func withAppContext(
        _ body: @MainActor (Workspace) async throws -> Void
    ) async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let previousAppDelegate = AppDelegate.shared
            let previousManager = TerminalController.shared.activeTabManagerForCallerNotification()
            let appDelegate = AppDelegate()
            let manager = TabManager(autoWelcomeIfNeeded: false)
            AppDelegate.shared = appDelegate
            appDelegate.tabManager = manager
            TerminalController.shared.setActiveTabManager(manager)
            defer {
                TerminalController.shared.setActiveTabManager(previousManager)
                manager.tabs.forEach { $0.teardownAllPanels() }
                AppDelegate.shared = previousAppDelegate
            }

            let workspace = try #require(manager.tabs.first)
            try await body(workspace)
        }
    }
}
