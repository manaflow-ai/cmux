import AppKit
import CmuxSwiftRender
import CmuxSwiftRenderUI
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// https://github.com/manaflow-ai/cmux/issues/34356: a custom sidebar's close
/// button on a workspace with a running process was refused by the socket
/// with `confirmation_required` and nothing told the user. The built-in
/// sidebar asks "Close workspace?" for the same click.
@Suite(.serialized)
@MainActor
struct CustomSidebarCloseConfirmationTests {
    /// A registered window context with two workspaces; the second one has a
    /// terminal that reports a running process.
    private struct Fixture {
        let manager: TabManager
        let busy: Workspace
        let tearDown: @MainActor () -> Void
    }

    private func makeFixture() throws -> Fixture {
        let appDelegate = try #require(AppDelegate.shared)
        let suiteName = "CustomSidebarCloseConfirmationTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        let manager = TabManager(autoWelcomeIfNeeded: false, closeTabWarningDefaults: defaults)
        let busy = manager.addWorkspace()
        let panel = try #require(busy.focusedTerminalPanel)
        panel.surface.setNeedsConfirmCloseOverrideForTesting(true)
        let windowId = appDelegate.registerMainWindowContextForTesting(tabManager: manager)
        return Fixture(manager: manager, busy: busy, tearDown: {
            panel.surface.setNeedsConfirmCloseOverrideForTesting(nil)
            appDelegate.unregisterMainWindowContextForTesting(windowId: windowId)
            appDelegate.forgetRecoverableMainWindowRoute(windowId: windowId)
            manager.closeWorkspacesForTesting()
            defaults.removePersistentDomain(forName: suiteName)
        })
    }

    private enum Trigger {
        /// The close runs from a button's click handler.
        case click
        /// The close runs while the sidebar program loads, with no click.
        case load
    }

    /// Runs a JS sidebar against the real action dispatch. The program sends
    /// what the Workspaces template's close button sends, then renames the
    /// first workspace: both go down the serial sidebar worker in order, so
    /// the rename landing means the close has been fully handled.
    private func sidebarClose(
        _ workspace: Workspace,
        in manager: TabManager,
        trigger: Trigger = .click,
        force: Bool = false
    ) async throws -> Bool {
        let markerTitle = "sidebar-close-done-\(UUID().uuidString)"
        let markerTarget = manager.tabs[0]
        let closeParams = force
            ? #"{ workspace_id: "\#(workspace.id.uuidString)", force: "true" }"#
            : #"{ workspace_id: "\#(workspace.id.uuidString)" }"#
        let commands = """
        cmux("workspace.close", \(closeParams));
        cmux("workspace.rename", { workspace_id: "\(markerTarget.id.uuidString)", title: "\(markerTitle)" });
        """
        let runtime = SidebarJSRuntime()
        runtime.dispatch = makeCmuxSidebarActionDispatch()
        switch trigger {
        case .click:
            runtime.start(source: "sidebar(() => Button(\"Close\", () => { \(commands) }))")
            #expect(runtime.errorMessage == nil)
            runtime.dispatchEvent(nodeId: try #require(runtime.store.rootId), event: "tap")
        case .load:
            runtime.start(source: "\(commands)\nsidebar(() => Text(\"row\"))")
            #expect(runtime.errorMessage == nil)
        }
        return await AppKitTestEventPump().waitUntil(timeout: .seconds(10)) {
            markerTarget.title == markerTitle
        }
    }

    @Test func refusedCloseAsksAndClosesWhenAccepted() async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let fixture = try makeFixture()
            defer { fixture.tearDown() }
            var prompts = 0
            fixture.manager.confirmCloseHandler = { _, _, _ in
                prompts += 1
                return true
            }

            #expect(try await sidebarClose(fixture.busy, in: fixture.manager))

            #expect(prompts == 1)
            #expect(!fixture.manager.tabs.contains { $0.id == fixture.busy.id })
        }
    }

    @Test func refusedCloseAsksAndKeepsTheWorkspaceWhenCancelled() async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let fixture = try makeFixture()
            defer { fixture.tearDown() }
            var prompts = 0
            fixture.manager.confirmCloseHandler = { _, _, _ in
                prompts += 1
                return false
            }

            #expect(try await sidebarClose(fixture.busy, in: fixture.manager))

            #expect(prompts == 1)
            #expect(fixture.manager.tabs.contains { $0.id == fixture.busy.id })
        }
    }

    /// A sidebar program can call `cmux(...)` at any time, not only from a
    /// click. A close it sends on its own must not put a dialog in front of
    /// the user; it stays the refusal it was.
    @Test func closeSentWithoutAClickDoesNotAsk() async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let fixture = try makeFixture()
            defer { fixture.tearDown() }
            var prompts = 0
            fixture.manager.confirmCloseHandler = { _, _, _ in
                prompts += 1
                return true
            }

            #expect(try await sidebarClose(fixture.busy, in: fixture.manager, trigger: .load))

            #expect(prompts == 0)
            #expect(fixture.manager.tabs.contains { $0.id == fixture.busy.id })
        }
    }

    @Test func idleWorkspaceClosesWithoutAsking() async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let fixture = try makeFixture()
            defer { fixture.tearDown() }
            let idle = fixture.manager.addWorkspace()
            let idlePanel = try #require(idle.focusedTerminalPanel)
            idlePanel.surface.setNeedsConfirmCloseOverrideForTesting(false)
            var prompts = 0
            fixture.manager.confirmCloseHandler = { _, _, _ in
                prompts += 1
                return false
            }

            #expect(try await sidebarClose(idle, in: fixture.manager))

            #expect(prompts == 0)
            #expect(!fixture.manager.tabs.contains { $0.id == idle.id })
        }
    }

    @Test func forcedCloseStillSkipsThePrompt() async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let fixture = try makeFixture()
            defer { fixture.tearDown() }
            var prompts = 0
            fixture.manager.confirmCloseHandler = { _, _, _ in
                prompts += 1
                return false
            }

            #expect(try await sidebarClose(fixture.busy, in: fixture.manager, force: true))

            #expect(prompts == 0)
            #expect(!fixture.manager.tabs.contains { $0.id == fixture.busy.id })
        }
    }

    /// The prompt belongs to the sidebar click only: a socket or CLI caller
    /// keeps getting the error it can act on.
    @Test func socketCallersStillGetConfirmationRequired() async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let fixture = try makeFixture()
            defer { fixture.tearDown() }
            var prompts = 0
            fixture.manager.confirmCloseHandler = { _, _, _ in
                prompts += 1
                return true
            }
            let line = #"{"id":"1","method":"workspace.close","params":{"workspace_id":"\#(fixture.busy.id.uuidString)"}}"#

            let reply = TerminalController.shared.handleSocketLine(line)

            let object = try #require(try JSONSerialization.jsonObject(with: Data(reply.utf8)) as? [String: Any])
            let error = try #require(object["error"] as? [String: Any])
            #expect(error["code"] as? String == "confirmation_required")
            #expect(prompts == 0)
            #expect(fixture.manager.tabs.contains { $0.id == fixture.busy.id })
        }
    }
}
