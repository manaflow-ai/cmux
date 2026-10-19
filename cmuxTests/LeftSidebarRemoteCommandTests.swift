import AppKit
import CmuxSidebar
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

extension TerminalControllerSocketSecurityTests {
    @Test func leftSidebarV1CommandsDriveTargetedSidebarState() throws {
        let previousAppDelegate = AppDelegate.shared
        let appDelegate = AppDelegate()
        defer { AppDelegate.shared = previousAppDelegate }

        let windowId = UUID()
        let sidebarState = SidebarState(isVisible: true)
        appDelegate.registerMainWindowContextForTesting(
            windowId: windowId,
            tabManager: TabManager(),
            sidebarState: sidebarState
        )
        defer { appDelegate.unregisterMainWindowContextForTesting(windowId: windowId) }
        let target = "--window=\(windowId.uuidString)"

        #expect(TerminalController.shared.handleSocketLine("left_sidebar hide \(target)") == "OK")
        #expect(!sidebarState.isVisible)

        #expect(TerminalController.shared.handleSocketLine("left_sidebar mode \(target)") == #"{"visible":false}"#)

        #expect(TerminalController.shared.handleSocketLine("left_sidebar show \(target)") == "OK")
        #expect(sidebarState.isVisible)
        #expect(TerminalController.shared.handleSocketLine("left_sidebar show \(target)") == "OK")
        #expect(sidebarState.isVisible)

        #expect(TerminalController.shared.handleSocketLine("left_sidebar toggle \(target)") == "OK")
        #expect(!sidebarState.isVisible)
        #expect(TerminalController.shared.handleSocketLine("left_sidebar toggle \(target)") == "OK")
        #expect(sidebarState.isVisible)

        let modeResponse = TerminalController.shared.handleSocketLine("left_sidebar mode \(target)")
        let modePayload = try #require(
            JSONSerialization.jsonObject(with: Data(modeResponse.utf8)) as? [String: Any]
        )
        #expect(modePayload.count == 1)
        #expect(modePayload["visible"] as? Bool == true)

        #expect(TerminalController.shared.handleSocketLine("left_sidebar set files \(target)").hasPrefix("ERROR:"))
        #expect(sidebarState.isVisible)
    }

    /// A sidebar the window collapsed for lack of room reads as hidden and
    /// comes back with `show`; `hide` keeps it from returning when the window
    /// widens again.
    @Test func leftSidebarHideClearsAutoCollapse() {
        let previousAppDelegate = AppDelegate.shared
        let appDelegate = AppDelegate()
        defer { AppDelegate.shared = previousAppDelegate }

        let windowId = UUID()
        let sidebarState = SidebarState(isVisible: false)
        sidebarState.isAutoCollapsed = true
        appDelegate.registerMainWindowContextForTesting(
            windowId: windowId,
            tabManager: TabManager(),
            sidebarState: sidebarState
        )
        defer { appDelegate.unregisterMainWindowContextForTesting(windowId: windowId) }
        let target = SidebarRemoteTarget(windowId: windowId, workspaceId: nil)

        #expect(appDelegate.applyLeftSidebarRemoteCommand(.getState, target: target) == .state(visible: false))

        #expect(appDelegate.applyLeftSidebarRemoteCommand(.hide, target: target) == .ok)
        #expect(!sidebarState.isVisible)
        #expect(!sidebarState.isAutoCollapsed)
        #expect(SidePanelWidthFit(
            isLeftVisible: sidebarState.isVisible,
            isRightVisible: false,
            isLeftAutoCollapsed: sidebarState.isAutoCollapsed
        ).fitting(windowWidth: 2000, leftWidth: 240, rightWidth: 295).isLeftVisible == false)

        sidebarState.isAutoCollapsed = true
        #expect(appDelegate.applyLeftSidebarRemoteCommand(.show, target: target) == .ok)
        #expect(sidebarState.isVisible)
    }

    @Test func leftSidebarV1ParserProducesRemoteCommands() throws {
        let workspaceId = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let windowId = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        let cases: [([String], LeftSidebarRemoteRequest)] = [
            (["toggle"], .init(command: .toggle, target: SidebarRemoteTarget())),
            (
                ["show", "--window=\(windowId.uuidString)"],
                .init(command: .show, target: SidebarRemoteTarget(windowId: windowId, workspaceId: nil))
            ),
            (
                ["hide", "--tab=\(workspaceId.uuidString)"],
                .init(command: .hide, target: SidebarRemoteTarget(windowId: nil, workspaceId: workspaceId))
            ),
            (["FOCUS"], .init(command: .focus, target: SidebarRemoteTarget())),
            (
                ["mode", "--workspace", workspaceId.uuidString, "--window", windowId.uuidString],
                .init(command: .getState, target: SidebarRemoteTarget(windowId: windowId, workspaceId: workspaceId))
            ),
        ]

        for (tokens, expected) in cases {
            let result = LeftSidebarRemoteRequest.parse(tokens: tokens)
            #expect(try result.get() == expected, Comment(rawValue: tokens.joined(separator: " ")))
        }

        let invalidCases: [([String], String)] = [
            ([], "Usage: left_sidebar <toggle"),
            (["state"], "Unknown left sidebar command 'state'"),
            (["set", "files"], "Unknown left sidebar command 'set'"),
            (["files"], "Unknown left sidebar command 'files'"),
            (["toggle", "extra"], "Usage: left_sidebar toggle"),
            (["show", "--no-focus"], "Unknown left sidebar option '--no-focus'"),
            (["--bad"], "Unknown left sidebar option '--bad'"),
            (["show", "--window"], "--window requires an id"),
            (["show", "--tab", "not-a-uuid"], "Invalid left sidebar --tab id 'not-a-uuid'"),
        ]

        for (tokens, expectedMessage) in invalidCases {
            switch LeftSidebarRemoteRequest.parse(tokens: tokens) {
            case .success(let request):
                Issue.record("Expected parser failure for \(tokens), got \(request)")
            case .failure(let error):
                #expect(
                    error.message.contains(expectedMessage),
                    "Expected \(tokens) to contain \(expectedMessage), got \(error.message)"
                )
            }
        }
    }

    /// Unlike `right_sidebar`, only `focus` may move in-app focus.
    @Test func leftSidebarV1FocusPolicyAllowsOnlyFocus() throws {
        let cases: [(String, Bool)] = [
            ("focus", true),
            ("focus --window=22222222-2222-2222-2222-222222222222", true),
            ("toggle", false),
            ("show", false),
            ("hide", false),
            ("mode", false),
            ("set files", false),
            ("focus extra", false),
        ]

        for (args, expected) in cases {
            #expect(
                TerminalController.leftSidebarCommandAllowsInAppFocusMutations(args: args) == expected,
                Comment(rawValue: args)
            )
        }
    }

    @Test func leftSidebarCommandsTargetRegisteredWindowOrWorkspace() {
        let previousAppDelegate = AppDelegate.shared
        let appDelegate = AppDelegate()
        defer { AppDelegate.shared = previousAppDelegate }

        let windowAId = UUID()
        let windowBId = UUID()
        let managerA = TabManager()
        let managerB = TabManager()
        _ = managerA.addWorkspace(select: false, eagerLoadTerminal: false)
        let workspaceB = managerB.addWorkspace(select: false, eagerLoadTerminal: false)
        let stateA = SidebarState(isVisible: true)
        let stateB = SidebarState(isVisible: true)
        appDelegate.registerMainWindowContextForTesting(windowId: windowAId, tabManager: managerA, sidebarState: stateA)
        appDelegate.registerMainWindowContextForTesting(windowId: windowBId, tabManager: managerB, sidebarState: stateB)
        defer {
            appDelegate.unregisterMainWindowContextForTesting(windowId: windowAId)
            appDelegate.unregisterMainWindowContextForTesting(windowId: windowBId)
        }

        #expect(appDelegate.applyLeftSidebarRemoteCommand(
            .hide,
            target: SidebarRemoteTarget(windowId: windowAId, workspaceId: nil)
        ) == .ok)
        #expect(!stateA.isVisible)
        #expect(stateB.isVisible)

        #expect(appDelegate.applyLeftSidebarRemoteCommand(
            .toggle,
            target: SidebarRemoteTarget(windowId: nil, workspaceId: workspaceB.id)
        ) == .ok)
        #expect(!stateB.isVisible)
        #expect(!stateA.isVisible)

        #expect(appDelegate.applyLeftSidebarRemoteCommand(
            .getState,
            target: SidebarRemoteTarget(windowId: nil, workspaceId: workspaceB.id)
        ) == .state(visible: false))

        // Neither registered context has a window, so there is nothing to focus.
        switch appDelegate.applyLeftSidebarRemoteCommand(
            .focus,
            target: SidebarRemoteTarget(windowId: windowAId, workspaceId: nil)
        ) {
        case .failure(let message):
            #expect(message.contains("Failed to focus left sidebar"), Comment(rawValue: message))
        case .ok, .state:
            Issue.record("Expected focus without a window to fail")
        }
        #expect(!stateA.isVisible)

        for missing in [
            SidebarRemoteTarget(windowId: UUID(), workspaceId: nil),
            SidebarRemoteTarget(windowId: nil, workspaceId: UUID()),
        ] {
            switch appDelegate.applyLeftSidebarRemoteCommand(.show, target: missing) {
            case .failure(let message):
                #expect(message.contains("target not found"), Comment(rawValue: message))
            case .ok, .state:
                Issue.record("Expected missing target to fail")
            }
        }
        #expect(!stateA.isVisible)
        #expect(!stateB.isVisible)
    }

    /// With no target, the command acts on the window ⌘B toggles: a context
    /// with a live window, never a windowless one.
    @Test func leftSidebarDefaultTargetMatchesToggleSidebarShortcut() {
        let previousAppDelegate = AppDelegate.shared
        let appDelegate = AppDelegate()
        defer { AppDelegate.shared = previousAppDelegate }

        let windowedId = UUID()
        let windowlessId = UUID()
        let windowedState = SidebarState(isVisible: true)
        let windowlessState = SidebarState(isVisible: true)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        appDelegate.registerMainWindowContextForTesting(
            windowId: windowlessId,
            tabManager: TabManager(),
            sidebarState: windowlessState
        )
        appDelegate.registerMainWindowContextForTesting(
            windowId: windowedId,
            tabManager: TabManager(),
            sidebarState: windowedState,
            window: window
        )
        defer {
            appDelegate.unregisterMainWindowContextForTesting(windowId: windowedId)
            appDelegate.unregisterMainWindowContextForTesting(windowId: windowlessId)
        }

        #expect(appDelegate.sidebarToggleTarget()?.context.windowId == windowedId)

        #expect(appDelegate.applyLeftSidebarRemoteCommand(.hide) == .ok)
        #expect(!windowedState.isVisible)
        #expect(windowlessState.isVisible)

        // ⌘B's path flips the same sidebar back.
        #expect(appDelegate.toggleSidebarInActiveMainWindow())
        #expect(windowedState.isVisible)
        #expect(windowlessState.isVisible)
    }

    @Test func leftSidebarWithoutAnyWindowFails() {
        let previousAppDelegate = AppDelegate.shared
        let appDelegate = AppDelegate()
        defer { AppDelegate.shared = previousAppDelegate }

        switch appDelegate.applyLeftSidebarRemoteCommand(.show) {
        case .failure(let message):
            #expect(message.contains("Left sidebar not available"), Comment(rawValue: message))
        case .ok, .state:
            Issue.record("Expected show without any main window to fail")
        }
    }
}
