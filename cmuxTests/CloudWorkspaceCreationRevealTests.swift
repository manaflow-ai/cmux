import AppKit
import CmuxCloud
import CmuxCloudMachines
import CmuxSurfaceCatalogModel
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Each creation entry point publishes a Cloud tree reveal only for a workspace
/// its window selected, and withdraws it when the create does not land.
@MainActor
@Suite("Cloud workspace creation reveals", .serialized)
struct CloudWorkspaceCreationRevealTests {
    @Test("A focused create reveals the receipt's workspace in its own window")
    func focusedCreateRevealsTheReceiptWorkspace() async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let fixture = try CloudWorkspaceCreationSidebarFixture()
            defer { fixture.close() }
            let key = KeyStatusTestWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
            fixture.manager.window = key
            defer { fixture.manager.window = fixture.window }
            fixture.provider.usesReceipt = true
            let reveals = fixture.catalog.cloudWorkspaceCreationCoordinator.reveals
            var inFlight: CloudWorkspaceCreationReveal?
            fixture.provider.beforeCreate = { inFlight = reveals.reveal(for: fixture.manager) }

            try await Self.create(fixture, focus: true).value
            let started = try #require(inFlight, "The reveal starts when the window selects the new pane")
            #expect(started.nodeID == nil, "The row is unknown until the daemon's receipt names it")
            #expect(!started.isWithdrawn)
            let reveal = try #require(reveals.reveal(for: fixture.manager))
            let workspace = try #require(fixture.provider.createdWorkspaces.first)
            #expect(reveal.token == started.token)
            #expect(reveal.nodeID == CloudTreeNodeBuilder.nodeID(workspace: workspace.id, machine: fixture.provider.machine))
            #expect(!reveal.isWithdrawn)
            #expect(fixture.workspaceRows().contains { $0.id == reveal.nodeID })
            #expect(reveals.reveal(for: nil) == nil)
        }
    }

    @Test("A create its window did not select publishes no reveal",
          arguments: [(false, true), (true, false)])
    func unselectedCreatePublishesNoReveal(focus: Bool, isKeyWindow: Bool) async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let fixture = try CloudWorkspaceCreationSidebarFixture()
            defer { fixture.close() }
            let key = KeyStatusTestWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
            if isKeyWindow { fixture.manager.window = key }
            defer { fixture.manager.window = fixture.window }
            fixture.provider.usesReceipt = true

            try await Self.create(fixture, focus: focus).value
            #expect(fixture.manager.selectedTabId == fixture.originalWorkspaceID)
            #expect(fixture.catalog.cloudWorkspaceCreationCoordinator.reveals.reveal(for: fixture.manager) == nil)
        }
    }

    @Test("Navigating away before the receipt withdraws the reveal")
    func navigationBeforeReceiptWithdraws() async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let fixture = try CloudWorkspaceCreationSidebarFixture()
            defer { fixture.close() }
            let key = KeyStatusTestWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
            fixture.manager.window = key
            defer { fixture.manager.window = fixture.window }
            fixture.provider.usesReceipt = true
            fixture.provider.beforeCreate = {
                let original = try #require(fixture.manager.workspacesById[fixture.originalWorkspaceID])
                fixture.manager.selectWorkspace(original)
            }

            try await Self.create(fixture, focus: true).value
            let reveal = try #require(fixture.catalog.cloudWorkspaceCreationCoordinator.reveals.reveal(for: fixture.manager))
            #expect(reveal.isWithdrawn)
        }
    }

    @Test("A failed, cancelled or rejected create withdraws its reveal",
          arguments: ["provider", "starter", "cancel", "daemon", "daemonAfterCompletion"])
    func failedCreateWithdrawsTheReveal(reason: String) async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let fixture = try CloudWorkspaceCreationSidebarFixture()
            defer { fixture.close() }
            let key = KeyStatusTestWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
            fixture.manager.window = key
            defer { fixture.manager.window = fixture.window }
            fixture.provider.usesReceipt = true
            switch reason {
            case "provider":
                fixture.provider.beforeCreate = { throw CloudDiagnosticFailure.conflict }
            case "starter":
                fixture.provider.includesStarter = false
                fixture.provider.terminalError = CloudDiagnosticFailure.conflict
            case "cancel":
                fixture.provider.beforeMaterialize = { _, _ in withUnsafeCurrentTask { $0?.cancel() } }
            case "daemon":
                fixture.provider.beforeMaterialize = { _, _ in try fixture.provider.publish(revision: 10, includesWorkspaces: false) }
            default:
                break
            }

            let result = await Self.create(fixture, focus: true).result
            switch reason {
            case "provider", "starter":
                #expect(throws: CloudDiagnosticFailure.conflict) { try result.get() }
            case "cancel", "daemon":
                #expect(throws: CancellationError.self) { try result.get() }
            default:
                try result.get()
                let revealed = try #require(fixture.catalog.cloudWorkspaceCreationCoordinator.reveals.reveal(for: fixture.manager))
                #expect(revealed.nodeID != nil && !revealed.isWithdrawn)
                try fixture.provider.publish(revision: 10, includesWorkspaces: false)
            }
            let reveal = try #require(fixture.catalog.cloudWorkspaceCreationCoordinator.reveals.reveal(for: fixture.manager))
            #expect(reveal.isWithdrawn)
            #expect((reveal.nodeID == nil) == (reason == "provider"))
        }
    }

    @Test("⌘N reveals the workspace it selects on completion, unless the user navigated first", arguments: [false, true])
    func newWorkspaceShortcutReveals(navigate: Bool) async throws {
        let fixture = CloudWorkspaceTargetingFixture()
        defer { fixture.close() }
        let manager = fixture.manager
        let other = try #require(manager.addWorkspaceIfActive(initialSurface: .cloudVMLoading, select: false))
        let window = KeyStatusTestWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 480), styleMask: [.titled], backing: .buffered, defer: false)
        window.identifier = NSUserInterfaceItemIdentifier("cmux.main.\(fixture.windowID.uuidString)")
        fixture.app.mainWindowContexts.values.first { $0.windowId == fixture.windowID }?.window = window
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil); withExtendedLifetime(window) {} }
        let reveals = SurfaceCatalog.shared.cloudWorkspaceCreationCoordinator.reveals
        let entered = AsyncStream<Void>.makeStream()
        let release = AsyncStream<Void>.makeStream()
        var machineID: String?
        fixture.onCreate = { request in
            entered.continuation.yield(())
            for await _ in release.stream { break }
            machineID = request.machineID
            let created = manager.addWorkspaceIfActive(initialSurface: .cloudVMLoading, select: false)
            created?.cloudVMBinding = WorkspaceCloudVMBinding(vmID: request.machineID, isBase: false, remoteWorkspaceID: "ws_7")
            return created?.id
        }

        #expect(fixture.app.performNewCloudWorkspaceOnResolvedMachineAction(tabManager: manager))
        for await _ in entered.stream { break }
        let started = try #require(reveals.reveal(for: manager), "The reveal starts with the shortcut")
        #expect(started.nodeID == nil && !started.isWithdrawn)
        if navigate { manager.selectWorkspace(other) }
        release.continuation.yield(())
        await fixture.app.cloudWorkspaceOperationController?.waitForPendingOperations()

        let reveal = try #require(reveals.reveal(for: manager))
        #expect(reveal.token == started.token)
        if navigate {
            #expect(reveal.isWithdrawn, "A newer selection wins over the finished create")
        } else {
            let machine = SurfaceMachineID(rawValue: try #require(machineID))
            #expect(reveal.nodeID == CloudTreeNodeBuilder.nodeID(workspace: "ws_7", machine: machine))
            #expect(!reveal.isWithdrawn)
        }
    }

    private static func create(_ fixture: CloudWorkspaceCreationSidebarFixture, focus: Bool) -> Task<Void, any Error> {
        let host = CloudWorkspaceCreationHost(manager: fixture.manager)
        return Task { @MainActor in
            _ = try await CloudTreeNodeActions.createWorkspaceAndOpenLocally(
                machine: fixture.provider.machine, provider: fixture.provider, catalog: fixture.catalog,
                name: nil, focus: focus, host: host
            )
        }
    }
}
