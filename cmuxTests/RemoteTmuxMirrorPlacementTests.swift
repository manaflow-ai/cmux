import AppKit
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite(.serialized) struct RemoteTmuxMirrorPlacementTests {
    @Test func explicitWindowRoutingFailsClosedButExistingMirrorAffinityWins() {
        let existing = UUID()
        let explicit = UUID()
        let active = UUID()

        #expect(RemoteTmuxAttachWindowTarget.unresolvedExplicitWindow.resolve(
            existingMirrorWindowID: nil,
            activeWindowID: active,
            isLive: { $0 == active }
        ) == nil)
        #expect(RemoteTmuxAttachWindowTarget.explicitWindow(explicit).resolve(
            existingMirrorWindowID: nil,
            activeWindowID: active,
            isLive: { $0 == active }
        ) == nil)
        #expect(RemoteTmuxAttachWindowTarget.unresolvedExplicitWindow.resolve(
            existingMirrorWindowID: existing,
            activeWindowID: active,
            isLive: { $0 == existing || $0 == active }
        ) == existing)
    }

    @Test func contextualRoutingRecoversFromAClosedPreferredWindow() {
        let preferred = UUID()
        let active = UUID()

        #expect(RemoteTmuxAttachWindowTarget.contextualWindow(preferred).resolve(
            existingMirrorWindowID: nil,
            activeWindowID: active,
            isLive: { $0 == active }
        ) == active)
        #expect(RemoteTmuxAttachWindowTarget.contextualWindow(preferred).resolve(
            existingMirrorWindowID: nil,
            activeWindowID: active,
            isLive: { $0 == preferred || $0 == active }
        ) == preferred)
    }

    @Test func mirrorDiscoveredSessionsLandInRequestedManagerWithoutFocusOrWindowCreation() throws {
        let harness = try Harness()
        defer { harness.tearDown() }

        let beforeWindowCount = harness.appDelegate.mainWindowContexts.count
        let selectedBefore = harness.manager.selectedTabId
        let host = RemoteTmuxHost(destination: "user@placement-a.test")
        harness.cacheConnection(host: host, session: "one")

        let workspaceIds = harness.controller.mirrorDiscoveredSessions(
            host: host,
            sessions: [RemoteTmuxSession(id: "$1", name: "one", windowCount: 1, attached: false, createdUnix: nil)],
            into: harness.manager
        )

        #expect(workspaceIds.count == 1)
        #expect(harness.appDelegate.mainWindowContexts.count == beforeWindowCount)
        #expect(harness.manager.selectedTabId == selectedBefore)
        let workspace = try #require(harness.manager.tabs.first { $0.id == workspaceIds[0] })
        #expect(workspace.isRemoteTmuxMirror)
    }

    @Test func existingMirrorLocationWinsOverSecondRequestedManager() throws {
        let harness = try Harness()
        let secondWindowId = harness.appDelegate.createMainWindow()
        guard let secondManager = harness.appDelegate.tabManagerFor(windowId: secondWindowId) else {
            Issue.record("missing second manager")
            harness.tearDown()
            return
        }
        defer {
            harness.closeWindow(secondWindowId)
            harness.tearDown()
        }

        let host = RemoteTmuxHost(destination: "user@placement-b.test")
        harness.cacheConnection(host: host, session: "one")
        _ = harness.controller.mirrorDiscoveredSessions(
            host: host,
            sessions: [RemoteTmuxSession(id: "$1", name: "one", windowCount: 1, attached: false, createdUnix: nil)],
            into: harness.manager
        )
        harness.cacheConnection(host: host, session: "two")
        let target = try #require(harness.controller.existingMirrorManager(for: host))

        let workspaceIds = harness.controller.mirrorDiscoveredSessions(
            host: host,
            sessions: [RemoteTmuxSession(id: "$2", name: "two", windowCount: 1, attached: false, createdUnix: nil)],
            into: target
        )

        #expect(target === harness.manager)
        #expect(!workspaceIds.isEmpty)
        #expect(secondManager.tabs.allSatisfy { !$0.isRemoteTmuxMirror })
    }

    @MainActor
    private struct Harness {
        let appDelegate: AppDelegate
        let controller: RemoteTmuxController
        let windowId: UUID
        let manager: TabManager

        init() throws {
            appDelegate = try #require(AppDelegate.shared)
            controller = appDelegate.remoteTmuxController
            windowId = appDelegate.createMainWindow()
            manager = try #require(appDelegate.tabManagerFor(windowId: windowId))
        }

        func cacheConnection(host: RemoteTmuxHost, session: String) {
            let connection = RemoteTmuxControlConnection(host: host, sessionName: session)
            controller.cacheConnection(connection)
        }

        func tearDown() {
            controller.detachAll()
            closeWindow(windowId)
        }

        func closeWindow(_ id: UUID) {
            let identifier = "cmux.main.\(id.uuidString)"
            if let window = NSApp.windows.first(where: { $0.identifier?.rawValue == identifier }) {
                window.performClose(nil)
                RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
            }
        }
    }
}
