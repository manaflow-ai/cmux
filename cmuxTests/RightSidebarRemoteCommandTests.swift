import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

extension TerminalControllerSocketSecurityTests {
    @Test func v1CommandsDriveExistingState() throws {
        let previousAppDelegate = AppDelegate.shared
        let appDelegate = AppDelegate()
        defer { AppDelegate.shared = previousAppDelegate }

        let windowId = UUID()
        let tabManager = TabManager()
        let fileExplorerState = FileExplorerState()
        fileExplorerState.setVisible(false)
        fileExplorerState.mode = .files

        appDelegate.fileExplorerState = fileExplorerState
        appDelegate.registerMainWindowContextForTesting(
            windowId: windowId,
            tabManager: tabManager,
            fileExplorerState: fileExplorerState
        )
        defer { appDelegate.unregisterMainWindowContextForTesting(windowId: windowId) }

        fileExplorerState.setVisible(false)
        fileExplorerState.mode = .files

        #expect(TerminalController.shared.handleSocketLine("right_sidebar show") == "OK")
        #expect(fileExplorerState.isVisible)

        #expect(TerminalController.shared.handleSocketLine("right_sidebar set find") == "OK")
        #expect(fileExplorerState.mode == .find)
        #expect(fileExplorerState.isVisible)

        #expect(TerminalController.shared.handleSocketLine("right_sidebar set vault --no-focus") == "OK")
        #expect(fileExplorerState.mode == .sessions)

        #expect(TerminalController.shared.handleSocketLine("right_sidebar set sessions --no-focus") == "OK")
        #expect(fileExplorerState.mode == .sessions)

        #expect(TerminalController.shared.handleSocketLine("right_sidebar hide") == "OK")
        #expect(!fileExplorerState.isVisible)

        #expect(TerminalController.shared.handleSocketLine("right_sidebar toggle") == "OK")
        #expect(fileExplorerState.isVisible)

        #expect(TerminalController.shared.handleSocketLine("right_sidebar focus") == "OK")
        #expect(fileExplorerState.isVisible)

        let modeResponse = TerminalController.shared.handleSocketLine("right_sidebar mode")
        let modeData = try #require(modeResponse.data(using: .utf8))
        let modePayload = try #require(JSONSerialization.jsonObject(with: modeData) as? [String: Any])
        #expect(modePayload["visible"] as? Bool == true)
        #expect(modePayload["mode"] as? String == "sessions")

        #expect(TerminalController.shared.handleSocketLine("right_sidebar set unknown").hasPrefix("ERROR:"))
    }

    @Test func v1CommandsRejectCustomSidebarNames() throws {
        let name = "__cmux_test_sidebar_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
        try withTemporaryCustomSidebarsDirectory { directory in
            let fileURL = directory.appendingPathComponent("\(name).swift")
            try #"Text("Custom")"#.write(to: fileURL, atomically: true, encoding: .utf8)

            let customSidebarsDefaultsKey = "customSidebars.beta.enabled"
            let previousCustomSidebars = UserDefaults.standard.object(forKey: customSidebarsDefaultsKey)
            UserDefaults.standard.set(true, forKey: customSidebarsDefaultsKey)
            defer {
                if let previousCustomSidebars {
                    UserDefaults.standard.set(previousCustomSidebars, forKey: customSidebarsDefaultsKey)
                } else {
                    UserDefaults.standard.removeObject(forKey: customSidebarsDefaultsKey)
                }
            }

            let previousAppDelegate = AppDelegate.shared
            let appDelegate = AppDelegate()
            defer { AppDelegate.shared = previousAppDelegate }

            let windowId = UUID()
            let tabManager = TabManager()
            let fileExplorerState = FileExplorerState()
            fileExplorerState.setVisible(false)
            fileExplorerState.mode = .files

            appDelegate.fileExplorerState = fileExplorerState
            appDelegate.registerMainWindowContextForTesting(
                windowId: windowId,
                tabManager: tabManager,
                fileExplorerState: fileExplorerState
            )
            defer { appDelegate.unregisterMainWindowContextForTesting(windowId: windowId) }

            #expect(TerminalController.shared.handleSocketLine("right_sidebar set \(name) --no-focus").hasPrefix("ERROR:"))
            #expect(!fileExplorerState.isVisible)
            #expect(fileExplorerState.mode == .files)
            #expect(fileExplorerState.customSidebarName != name)

            let modeResponse = TerminalController.shared.handleSocketLine("right_sidebar mode")
            let modeData = try #require(modeResponse.data(using: .utf8))
            let modePayload = try #require(JSONSerialization.jsonObject(with: modeData) as? [String: Any])
            #expect(modePayload["visible"] as? Bool == false)
            #expect(modePayload["mode"] as? String == "files")
        }
    }

    @Test func v1ParserProducesRemoteCommands() throws {
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
            #expect(try result.get() == expected, Comment(rawValue: line))
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
                Issue.record("Expected parser failure for \(line), got \(request)")
            case .failure(let error):
                #expect(
                    error.message.contains(expectedMessage),
                    "Expected \(line) to contain \(expectedMessage), got \(error.message)"
                )
            }
        }
#endif
    }

    @Test func v1FocusPolicyIsCommandSpecific() throws {
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
            #expect(
                TerminalController.shared.rightSidebarCommandAllowsInAppFocusMutationsForTesting(line) == expected,
                Comment(rawValue: line)
            )
        }
#endif
    }

    @Test func remoteCommandsCanTargetRegisteredWindowOrWorkspaceWithoutFocus() throws {
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

        #expect(appDelegate.applyRightSidebarRemoteCommand(
            .setMode(.find, focus: false),
            target: RightSidebarRemoteTarget(windowId: windowAId, workspaceId: nil)
        ) == .ok)
        #expect(stateA.isVisible)
        #expect(stateA.mode == .find)
        #expect(!stateB.isVisible)
        #expect(stateB.mode == .files)

        #expect(appDelegate.applyRightSidebarRemoteCommand(
            .setMode(.sessions, focus: false),
            target: RightSidebarRemoteTarget(windowId: nil, workspaceId: workspaceB.id)
        ) == .ok)
        #expect(stateB.isVisible)
        #expect(stateB.mode == .sessions)
        #expect(stateA.mode == .find)

        #expect(appDelegate.applyRightSidebarRemoteCommand(
            .hide,
            target: RightSidebarRemoteTarget(windowId: nil, workspaceId: workspaceB.id)
        ) == .ok)
        #expect(!stateB.isVisible)
        #expect(stateA.isVisible)

        switch appDelegate.applyRightSidebarRemoteCommand(
            .toggle,
            target: RightSidebarRemoteTarget(windowId: nil, workspaceId: workspaceB.id)
        ) {
        case .failure(let message):
            #expect(message.contains("target not found"), Comment(rawValue: message))
        case .ok, .state:
            Issue.record("Expected targeted toggle without a window to fail")
        }
        #expect(!stateB.isVisible)

        #expect(appDelegate.applyRightSidebarRemoteCommand(
            .getState,
            target: RightSidebarRemoteTarget(windowId: nil, workspaceId: workspaceB.id)
        ) == .state(.init(visible: false, modeRawValue: "sessions")))

        switch appDelegate.applyRightSidebarRemoteCommand(
            .getState,
            target: RightSidebarRemoteTarget(windowId: nil, workspaceId: workspaceC.id)
        ) {
        case .failure(let message):
            #expect(message.contains("state not available"), Comment(rawValue: message))
        case .ok, .state:
            Issue.record("Expected explicit target without right-sidebar state to fail")
        }

        switch appDelegate.applyRightSidebarRemoteCommand(
            .hide,
            target: RightSidebarRemoteTarget(windowId: nil, workspaceId: UUID())
        ) {
        case .failure(let message):
            #expect(message.contains("target not found"), Comment(rawValue: message))
        case .ok, .state:
            Issue.record("Expected missing workspace target to fail")
        }
    }

    private func withTemporaryCustomSidebarsDirectory<T>(_ body: (URL) throws -> T) throws -> T {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "cmux-sidebars-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        return try CmuxExtensionSidebarSelection.withCustomSidebarsDirectoryForTesting(directory) {
            try body(directory)
        }
    }
}
