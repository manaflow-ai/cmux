import AppKit
@testable import CmuxUpdater
@preconcurrency import Sparkle
import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// One Install and Relaunch click relaunches cmux, even while a terminal command or an agent
/// is running (#15084). Sparkle asks the updater delegate
/// `updater(_:shouldPostponeRelaunchForUpdate:untilInvokingBlock:)` before every relaunching
/// install; a yes leaves the click without a relaunch until another prompt is answered.
@MainActor
final class UpdateInstallRelaunchTests: XCTestCase {
    private var createdWindowIds: [UUID] = []
    private let defaultsSuiteName = "cmux.tests.update-install-relaunch.\(UUID().uuidString)"

    override func tearDown() {
        for windowId in createdWindowIds {
            if let window = window(withId: windowId) {
                window.animationBehavior = .none
                window.orderOut(nil)
                window.close()
            }
        }
        createdWindowIds.removeAll()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        UserDefaults().removePersistentDomain(forName: defaultsSuiteName)
        super.tearDown()
    }

    func testInstallAndRelaunchIsNotPostponedWhileACommandRuns() throws {
        let appDelegate = try XCTUnwrap(AppDelegate.shared)
        let workspace = try makeWorkspace(appDelegate)
        for panelId in workspace.panels.keys {
            workspace.updatePanelShellActivityState(panelId: panelId, state: .commandRunning)
        }

        XCTAssertFalse(
            try sparkleWouldPostponeRelaunch(appDelegate),
            "A running command must not hold the relaunch Install and Relaunch asked for"
        )
    }

    func testInstallAndRelaunchIsNotPostponedWhileAnAgentIsMidTurn() throws {
        let appDelegate = try XCTUnwrap(AppDelegate.shared)
        let workspace = try makeWorkspace(appDelegate)
        let panelId = try XCTUnwrap(workspace.focusedPanelId)
        workspace.setAgentLifecycle(key: "claude_code", panelId: panelId, lifecycle: .running)

        XCTAssertFalse(
            try sparkleWouldPostponeRelaunch(appDelegate),
            "A mid-turn agent must not hold the relaunch Install and Relaunch asked for"
        )
    }

    /// Sparkle's ready-to-install prompt must be answered for the user, so the click that
    /// started the download is the only one needed to install.
    func testReadyToInstallIsAnsweredWithoutAnotherPromptWhileACommandRuns() throws {
        let appDelegate = try XCTUnwrap(AppDelegate.shared)
        let workspace = try makeWorkspace(appDelegate)
        for panelId in workspace.panels.keys {
            workspace.updatePanelShellActivityState(panelId: panelId, state: .commandRunning)
        }
        let controller = try makeController(appDelegate)
        let reply = ReadyReplyBox()

        controller.driver.showReady(toInstallAndRelaunch: { reply.choice = $0 })

        XCTAssertEqual(
            reply.choice,
            .install,
            "Install and Relaunch must not wait on another prompt while a command runs"
        )
    }

    /// Wires an updater to the app the way launch does, then asks the question Sparkle asks
    /// before relaunching. Like Sparkle, an unimplemented optional method means relaunch now.
    private func sparkleWouldPostponeRelaunch(_ appDelegate: AppDelegate) throws -> Bool {
        let controller = try makeController(appDelegate)
        let updater = try XCTUnwrap(controller.updater as? SPUUpdater)
        let delegate: any SPUUpdaterDelegate = controller.driver
        return delegate.updater?(
            updater,
            shouldPostponeRelaunchForUpdate: SUAppcastItem.empty(),
            untilInvokingBlock: {}
        ) ?? false
    }

    private func makeController(_ appDelegate: AppDelegate) throws -> UpdateController {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsSuiteName))
        let controller = UpdateController(log: DiscardingUpdateLog(), defaults: defaults)
        controller.actionDelegate = appDelegate
        return controller
    }

    private func makeWorkspace(_ appDelegate: AppDelegate) throws -> Workspace {
        let windowId = appDelegate.createMainWindow()
        createdWindowIds.append(windowId)
        let window = try XCTUnwrap(window(withId: windowId))
        window.makeKeyAndOrderFront(nil)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        let manager = try XCTUnwrap(appDelegate.tabManagerFor(windowId: windowId))
        return try XCTUnwrap(manager.selectedWorkspace)
    }

    private func window(withId windowId: UUID) -> NSWindow? {
        let identifier = "cmux.main.\(windowId.uuidString)"
        return NSApp.windows.first(where: { $0.identifier?.rawValue == identifier })
    }
}

/// Captures the reply sent to Sparkle's ready-to-install prompt.
private final class ReadyReplyBox: @unchecked Sendable {
    var choice: SPUUserUpdateChoice?
}

private struct DiscardingUpdateLog: UpdateLogging {
    func append(_ message: String) {}
    func logPath() -> String { "" }
}
