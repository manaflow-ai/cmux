import XCTest
import AppKit
import Darwin
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

// MARK: - Right sidebar v1 commands, parser, and focus policy
extension TerminalControllerSocketSecurityTests {
    func testRightSidebarV1CommandsDriveExistingState() throws {
        let previousAppDelegate = AppDelegate.shared
        let appDelegate = AppDelegate()
        defer { AppDelegate.shared = previousAppDelegate }

        let windowId = UUID()
        let tabManager = TabManager()
        let sidebarState = SidebarState()
        let sidebarSelectionState = SidebarSelectionState()
        let fileExplorerState = FileExplorerState()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 320),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.identifier = NSUserInterfaceItemIdentifier("cmux.main.\(windowId.uuidString)")

        appDelegate.fileExplorerState = fileExplorerState
        appDelegate.registerMainWindow(
            window,
            windowId: windowId,
            tabManager: tabManager,
            sidebarState: sidebarState,
            sidebarSelectionState: sidebarSelectionState,
            fileExplorerState: fileExplorerState
        )
        defer {
            appDelegate.unregisterMainWindowContextForTesting(windowId: windowId)
            window.close()
        }

        fileExplorerState.setVisible(false)
        fileExplorerState.mode = .files

        XCTAssertEqual(TerminalController.shared.handleSocketLine("right_sidebar show"), "OK")
        XCTAssertTrue(fileExplorerState.isVisible)

        XCTAssertEqual(TerminalController.shared.handleSocketLine("right_sidebar set find"), "OK")
        XCTAssertEqual(fileExplorerState.mode, .find)
        XCTAssertTrue(fileExplorerState.isVisible)

        XCTAssertEqual(TerminalController.shared.handleSocketLine("right_sidebar set vault --no-focus"), "OK")
        XCTAssertEqual(fileExplorerState.mode, .sessions)

        XCTAssertEqual(TerminalController.shared.handleSocketLine("right_sidebar set sessions --no-focus"), "OK")
        XCTAssertEqual(fileExplorerState.mode, .sessions)

        XCTAssertEqual(TerminalController.shared.handleSocketLine("right_sidebar hide"), "OK")
        XCTAssertFalse(fileExplorerState.isVisible)

        XCTAssertEqual(TerminalController.shared.handleSocketLine("right_sidebar toggle"), "OK")
        XCTAssertTrue(fileExplorerState.isVisible)

        XCTAssertEqual(TerminalController.shared.handleSocketLine("right_sidebar focus"), "OK")
        XCTAssertTrue(fileExplorerState.isVisible)

        let modeResponse = TerminalController.shared.handleSocketLine("right_sidebar mode")
        let modeData = try XCTUnwrap(modeResponse.data(using: .utf8))
        let modePayload = try XCTUnwrap(JSONSerialization.jsonObject(with: modeData) as? [String: Any])
        XCTAssertEqual(modePayload["visible"] as? Bool, true)
        XCTAssertEqual(modePayload["mode"] as? String, "sessions")

        XCTAssertTrue(TerminalController.shared.handleSocketLine("right_sidebar set unknown").hasPrefix("ERROR:"))
    }

    func testRightSidebarV1ParserProducesRemoteCommands() throws {
#if DEBUG
        let workspaceId = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let windowId = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        let cases: [(String, RightSidebarRemoteRequest)] = [
            (
                "right_sidebar toggle",
                RightSidebarRemoteRequest(command: .toggle, target: RightSidebarRemoteTarget())
            ),
            (
                "right_sidebar show --window=\(windowId.uuidString)",
                RightSidebarRemoteRequest(command: .show, target: RightSidebarRemoteTarget(windowId: windowId, workspaceId: nil))
            ),
            (
                "right_sidebar hide --tab=\(workspaceId.uuidString)",
                RightSidebarRemoteRequest(command: .hide, target: RightSidebarRemoteTarget(windowId: nil, workspaceId: workspaceId))
            ),
            (
                "right_sidebar focus",
                RightSidebarRemoteRequest(command: .focus, target: RightSidebarRemoteTarget())
            ),
            (
                "right_sidebar set find",
                RightSidebarRemoteRequest(command: .setMode(.find, focus: true), target: RightSidebarRemoteTarget())
            ),
            (
                "right_sidebar set vault --no-focus",
                RightSidebarRemoteRequest(command: .setMode(.sessions, focus: false), target: RightSidebarRemoteTarget())
            ),
            (
                "right_sidebar sessions",
                RightSidebarRemoteRequest(command: .setMode(.sessions, focus: true), target: RightSidebarRemoteTarget())
            ),
            (
                "right_sidebar mode",
                RightSidebarRemoteRequest(command: .getState, target: RightSidebarRemoteTarget())
            ),
            (
                "right_sidebar state --workspace \(workspaceId.uuidString) --window \(windowId.uuidString)",
                RightSidebarRemoteRequest(command: .getState, target: RightSidebarRemoteTarget(windowId: windowId, workspaceId: workspaceId))
            ),
        ]

        for (line, expected) in cases {
            let result = TerminalController.shared.parseRightSidebarRemoteRequestForTesting(line)
            XCTAssertEqual(try result.get(), expected, line)
        }

        let invalidCases: [(String, String)] = [
            ("right_sidebar", "Usage: right_sidebar"),
            ("right_sidebar set", "Usage: right_sidebar set"),
            ("right_sidebar set unknown", "Unknown right sidebar mode"),
            ("right_sidebar show --no-focus", "Usage: right_sidebar show"),
            ("right_sidebar files --no-focus", "--no-focus is only valid"),
            ("right_sidebar --bad", "Unknown right sidebar option"),
            ("right_sidebar show --tab not-a-uuid", "Invalid right sidebar --tab id"),
            ("right_sidebar show --window", "--window requires an id"),
        ]

        for (line, expectedMessage) in invalidCases {
            switch TerminalController.shared.parseRightSidebarRemoteRequestForTesting(line) {
            case .success(let request):
                XCTFail("Expected parser failure for \(line), got \(request)")
            case .failure(let error):
                XCTAssertTrue(
                    error.message.contains(expectedMessage),
                    "Expected \(line) to contain \(expectedMessage), got \(error.message)"
                )
            }
        }
#else
        throw XCTSkip("Right sidebar parser helper is debug-only.")
#endif
    }

    func testRightSidebarV1FocusPolicyIsCommandSpecific() throws {
#if DEBUG
        let cases: [(String, Bool)] = [
            ("right_sidebar toggle", true),
            ("right_sidebar show", true),
            ("right_sidebar focus", true),
            ("right_sidebar set find", true),
            ("right_sidebar sessions", true),
            ("right_sidebar set vault --no-focus", false),
            ("right_sidebar hide", false),
            ("right_sidebar mode", false),
            ("right_sidebar state", false),
            ("right_sidebar set unknown", false),
        ]

        for (line, expected) in cases {
            XCTAssertEqual(
                TerminalController.shared.rightSidebarCommandAllowsInAppFocusMutationsForTesting(line),
                expected,
                line
            )
        }
#else
        throw XCTSkip("Right sidebar focus policy helper is debug-only.")
#endif
    }

    func testRightSidebarRemoteCommandsCanTargetRegisteredWindowOrWorkspaceWithoutFocus() throws {
        let previousAppDelegate = AppDelegate.shared
        let appDelegate = AppDelegate()
        defer { AppDelegate.shared = previousAppDelegate }
        let windowAId = UUID()
        let windowBId = UUID()
        let managerA = TabManager()
        let managerB = TabManager()
        let managerC = TabManager()
        _ = managerA.addWorkspace(select: false, eagerLoadTerminal: false)
        let workspaceB = managerB.addWorkspace(select: false, eagerLoadTerminal: false)
        let workspaceC = managerC.addWorkspace(select: false, eagerLoadTerminal: false)
        let stateA = FileExplorerState()
        let stateB = FileExplorerState()
        let fallbackState = FileExplorerState()

        stateA.setVisible(false)
        stateA.mode = .files
        stateB.setVisible(false)
        stateB.mode = .files
        fallbackState.setVisible(true)
        fallbackState.mode = .dock
        appDelegate.fileExplorerState = fallbackState

        appDelegate.registerMainWindowContextForTesting(
            windowId: windowAId,
            tabManager: managerA,
            fileExplorerState: stateA
        )
        appDelegate.registerMainWindowContextForTesting(
            windowId: windowBId,
            tabManager: managerB,
            fileExplorerState: stateB
        )
        let windowCId = appDelegate.registerMainWindowContextForTesting(
            tabManager: managerC
        )
        defer {
            appDelegate.unregisterMainWindowContextForTesting(windowId: windowAId)
            appDelegate.unregisterMainWindowContextForTesting(windowId: windowBId)
            appDelegate.unregisterMainWindowContextForTesting(windowId: windowCId)
        }

        XCTAssertEqual(
            appDelegate.applyRightSidebarRemoteCommand(
                .setMode(.find, focus: false),
                target: RightSidebarRemoteTarget(windowId: windowAId, workspaceId: nil)
            ),
            .ok
        )
        XCTAssertTrue(stateA.isVisible)
        XCTAssertEqual(stateA.mode, .find)
        XCTAssertFalse(stateB.isVisible)
        XCTAssertEqual(stateB.mode, .files)

        XCTAssertEqual(
            appDelegate.applyRightSidebarRemoteCommand(
                .setMode(.sessions, focus: false),
                target: RightSidebarRemoteTarget(windowId: nil, workspaceId: workspaceB.id)
            ),
            .ok
        )
        XCTAssertTrue(stateB.isVisible)
        XCTAssertEqual(stateB.mode, .sessions)
        XCTAssertEqual(stateA.mode, .find)

        XCTAssertEqual(
            appDelegate.applyRightSidebarRemoteCommand(
                .hide,
                target: RightSidebarRemoteTarget(windowId: nil, workspaceId: workspaceB.id)
            ),
            .ok
        )
        XCTAssertFalse(stateB.isVisible)
        XCTAssertTrue(stateA.isVisible)

        switch appDelegate.applyRightSidebarRemoteCommand(
            .toggle,
            target: RightSidebarRemoteTarget(windowId: nil, workspaceId: workspaceB.id)
        ) {
        case .failure(let message):
            XCTAssertTrue(message.contains("target not found"), message)
        case .ok, .state:
            XCTFail("Expected targeted toggle without a window to fail")
        }
        XCTAssertFalse(stateB.isVisible)

        XCTAssertEqual(
            appDelegate.applyRightSidebarRemoteCommand(
                .getState,
                target: RightSidebarRemoteTarget(windowId: nil, workspaceId: workspaceB.id)
            ),
            .state(.init(visible: false, mode: .sessions))
        )

        switch appDelegate.applyRightSidebarRemoteCommand(
            .getState,
            target: RightSidebarRemoteTarget(windowId: nil, workspaceId: workspaceC.id)
        ) {
        case .failure(let message):
            XCTAssertTrue(message.contains("state not available"), message)
        case .ok, .state:
            XCTFail("Expected explicit target without right-sidebar state to fail")
        }

        switch appDelegate.applyRightSidebarRemoteCommand(
            .hide,
            target: RightSidebarRemoteTarget(windowId: nil, workspaceId: UUID())
        ) {
        case .failure(let message):
            XCTAssertTrue(message.contains("target not found"), message)
        case .ok, .state:
            XCTFail("Expected missing workspace target to fail")
        }
    }

}
