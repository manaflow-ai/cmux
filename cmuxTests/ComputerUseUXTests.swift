import AppKit
import CmuxTerminal
import Foundation
import Testing
@testable import CmuxSettingsUI

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Computer Use UX")
struct ComputerUseUXTests {
    @Test func missingStateDirectoryProducesEmptyScan() {
        let missingDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let result = ComputerUseStateRepository().scan(
            directoryURL: missingDirectory,
            sessions: [],
            now: Date(timeIntervalSince1970: 2_000_000_000)
        )

        #expect(result == .empty)
    }

    @Test func malformedStateFileIsIgnored() throws {
        try withStateDirectory { directory in
            try Data("not-json".utf8).write(to: directory.appendingPathComponent("broken.json"))
            let result = ComputerUseStateRepository().scan(
                directoryURL: directory,
                sessions: [ComputerUseSessionProcessScope(id: "row", sessionID: "session-1", processIDs: [42])],
                now: Date(timeIntervalSince1970: 2_000_000_000)
            )

            #expect(result == .empty)
        }
    }

    @Test func staleStateFileIsIgnored() throws {
        try withStateDirectory { directory in
            let now = Date(timeIntervalSince1970: 2_000_000_000)
            try writeState(
                to: directory.appendingPathComponent("stale.json"),
                pid: 42,
                session: "session-1",
                targetPID: 84,
                lastActionAt: now.addingTimeInterval(-3_601)
            )
            let result = ComputerUseStateRepository(recentActivityInterval: 3_600).scan(
                directoryURL: directory,
                sessions: [ComputerUseSessionProcessScope(id: "row", sessionID: "session-1", processIDs: [42])],
                now: now
            )

            #expect(result == .empty)
        }
    }

    @Test func newestRecentStateMustMatchSessionProcessTree() throws {
        try withStateDirectory { directory in
            let now = Date(timeIntervalSince1970: 2_000_000_000)
            try writeState(
                to: directory.appendingPathComponent("older.json"),
                pid: 42,
                session: "session-1",
                targetPID: 84,
                lastActionAt: now.addingTimeInterval(-20)
            )
            // The driver's session field never matches the cmux hook session id
            // (and is null for cursor-less runs); pid-tree containment alone
            // must resolve the state.
            try writeState(
                to: directory.appendingPathComponent("newer.json"),
                pid: 43,
                session: nil,
                targetPID: 86,
                lastActionAt: now.addingTimeInterval(-10)
            )
            try writeState(
                to: directory.appendingPathComponent("foreign.json"),
                pid: 99,
                session: "session-1",
                targetPID: 198,
                lastActionAt: now.addingTimeInterval(-1)
            )
            let result = ComputerUseStateRepository().scan(
                directoryURL: directory,
                sessions: [ComputerUseSessionProcessScope(id: "row", sessionID: "session-1", processIDs: [42, 43])],
                now: now
            )

            #expect(result.hasRecentStateFiles)
            #expect(result.newestStateByScopeID["row"]?.targetPID == 86)
        }
    }

    @Test func onboardingSurfacesWhenPermissionsMissingEvenAfterSeen() {
        // Missing permission must surface regardless of `seen` — a dev rebuild
        // drops the TCC grant, and gating on `seen` left the user with no prompt.
        #expect(ComputerUseOnboardingWindowController.shouldPresentAutomatically(
            seen: true, featureEnabled: true, accessibilityGranted: false, screenRecordingGranted: true))
        #expect(ComputerUseOnboardingWindowController.shouldPresentAutomatically(
            seen: true, featureEnabled: true, accessibilityGranted: true, screenRecordingGranted: false))
        // Both granted -> never surfaced (no nag for a set-up user).
        #expect(!ComputerUseOnboardingWindowController.shouldPresentAutomatically(
            seen: false, featureEnabled: true, accessibilityGranted: true, screenRecordingGranted: true))
        // Feature off -> never surfaced.
        #expect(!ComputerUseOnboardingWindowController.shouldPresentAutomatically(
            seen: false, featureEnabled: false, accessibilityGranted: false, screenRecordingGranted: false))
    }

    @Test func parsesRealDriverStateFileShape() throws {
        // Byte shape captured from a live cua-driver 0.7.1 state file: driver_pid
        // (not pid), null session, RFC3339 last_action_at with 6-digit fraction.
        let json = """
        {"driver_pid":71790,"session":null,"target_app":"Calculator","target_pid":71241,\
        "target_window_id":87692,"last_action_at":"2026-07-14T01:09:37.745752Z","schema":1}
        """
        let state = try #require(ComputerUseDriverState(data: Data(json.utf8)))
        #expect(state.pid == 71790)
        #expect(state.session == nil)
        #expect(state.targetApp == "Calculator")
        #expect(state.targetPID == 71241)
        #expect(state.targetWindowID == 87692)
        #expect(abs(state.lastActionAt.timeIntervalSince1970 - 1_783_991_377.745) < 0.01)
    }

    @Test func computerUseSettingsNavigationRawValuesStayInSync() {
        #expect(SettingsSectionID.computerUse.rawValue == SettingsNavigationTarget.computerUse.rawValue)
    }

    @Test func targetIdentityFailsClosedWhenPIDIdentityChanges() {
        let launchDate = Date(timeIntervalSince1970: 1_900_000_000)
        let identity = ComputerUseTargetIdentity(
            processIdentifier: 42,
            bundleIdentifier: "com.example.Target",
            launchDate: launchDate
        )

        #expect(identity.matches(
            processIdentifier: 42,
            bundleIdentifier: "com.example.Target",
            launchDate: launchDate
        ))
        #expect(!identity.matches(
            processIdentifier: 42,
            bundleIdentifier: "com.example.Recycled",
            launchDate: launchDate
        ))
        #expect(!identity.matches(
            processIdentifier: 42,
            bundleIdentifier: "com.example.Target",
            launchDate: launchDate.addingTimeInterval(1)
        ))
        #expect(!identity.matches(
            processIdentifier: 43,
            bundleIdentifier: "com.example.Target",
            launchDate: launchDate
        ))
    }

    @Test @MainActor func onboardingCreatesFreshWindowAndRootForEveryRun() {
        let controller = ComputerUseOnboardingWindowController(
            permissionService: ComputerUsePermissionService()
        )
        let first = controller.makeWindow()
        let second = controller.makeWindow()
        defer {
            first.close()
            second.close()
        }

        #expect(first !== second)
        #expect(first.contentViewController !== second.contentViewController)
    }

    @Test func menuRefreshPolicyDebouncesAndSkipsFullyInactiveFeature() throws {
        let policy = ComputerUseMenuBarRefreshPolicy(minimumEventReloadInterval: 0.2)
        let firstEvent = Date(timeIntervalSince1970: 1_900_000_000)
        let secondEvent = firstEvent.addingTimeInterval(0.05)

        #expect(policy.reloadDeadline(
            forEventAt: firstEvent,
            featureEnabled: false,
            showInMenuBar: false
        ) == nil)
        let firstDeadline = try #require(policy.reloadDeadline(
            forEventAt: firstEvent,
            featureEnabled: true,
            showInMenuBar: false
        ))
        let secondDeadline = try #require(policy.reloadDeadline(
            forEventAt: secondEvent,
            featureEnabled: true,
            showInMenuBar: false
        ))
        #expect(firstDeadline == firstEvent.addingTimeInterval(0.2))
        #expect(secondDeadline > firstDeadline)
    }

    @Test func computerUseSchemaDeclaresPersistedKeys() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let schemaURL = repositoryRoot.appendingPathComponent("web/data/cmux.schema.json")
        let object = try #require(
            try JSONSerialization.jsonObject(with: Data(contentsOf: schemaURL)) as? [String: Any]
        )
        let properties = try #require(object["properties"] as? [String: Any])
        let computerUse = try #require(properties["computerUse"] as? [String: Any])
        #expect(computerUse["additionalProperties"] as? Bool == false)
        let computerUseProperties = try #require(computerUse["properties"] as? [String: Any])
        #expect((computerUseProperties["enabled"] as? [String: Any])?["type"] as? String == "boolean")
        #expect((computerUseProperties["showInMenuBar"] as? [String: Any])?["type"] as? String == "boolean")
    }

    @Test func generatedAgentShimReadsComputerUseAuthorityOnEveryLaunch() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-computer-use-live-setting-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let binDirectory = root.appendingPathComponent("bin", isDirectory: true)
        let shimRoot = root.appendingPathComponent("shims", isDirectory: true)
        let settingURL = root.appendingPathComponent("enabled")
        let logURL = root.appendingPathComponent("disabled-value")
        try FileManager.default.createDirectory(at: binDirectory, withIntermediateDirectories: true)
        let wrapperURL = binDirectory.appendingPathComponent("cmux-claude-wrapper")
        try """
        #!/usr/bin/env bash
        printf '%s' "${CMUX_COMPUTER_USE_MCP_DISABLED:-missing}" > "$CMUX_TEST_LOG"
        """.write(to: wrapperURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: wrapperURL.path)
        let shim = try #require(TerminalSurface.installClaudeCommandShimIfPossible(
            wrapperURL: wrapperURL,
            surfaceId: UUID(),
            temporaryDirectory: shimRoot,
            computerUseSettingFileURL: settingURL
        ))

        // Setting disabled -> shim forces the disable regardless of inherited env.
        try "0\n".write(to: settingURL, atomically: true, encoding: .utf8)
        try runShim(at: shim.executablePath, logURL: logURL, inheritedDisabled: "0")
        #expect(try String(contentsOf: logURL, encoding: .utf8) == "1")

        // Setting enabled + no inherited kill switch -> attachment stays enabled.
        try "1\n".write(to: settingURL, atomically: true, encoding: .utf8)
        try runShim(at: shim.executablePath, logURL: logURL, inheritedDisabled: "0")
        #expect(try String(contentsOf: logURL, encoding: .utf8) == "0")

        // Setting enabled but the user exported the documented kill switch
        // (CMUX_COMPUTER_USE_MCP_DISABLED=1): the shim must NOT clobber it.
        try "1\n".write(to: settingURL, atomically: true, encoding: .utf8)
        try runShim(at: shim.executablePath, logURL: logURL, inheritedDisabled: "1")
        #expect(try String(contentsOf: logURL, encoding: .utf8) == "1")
    }

    private func withStateDirectory(_ body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-computer-use-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory)
    }

    private func writeState(
        to url: URL,
        pid: Int,
        session: String?,
        targetPID: Int,
        lastActionAt: Date
    ) throws {
        // Mirrors the driver's schema-1 shape (driver_pid + RFC3339 timestamp).
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let object: [String: Any] = [
            "driver_pid": pid,
            "session": session as Any? ?? NSNull(),
            "target_app": "Example App",
            "target_pid": targetPID,
            "target_window_id": 7,
            "last_action_at": formatter.string(from: lastActionAt),
            "schema": 1,
        ]
        let data = try JSONSerialization.data(withJSONObject: object)
        try data.write(to: url, options: .atomic)
    }

    private func runShim(at path: String, logURL: URL, inheritedDisabled: String = "0") throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_TEST_LOG"] = logURL.path
        environment["CMUX_COMPUTER_USE_MCP_DISABLED"] = inheritedDisabled
        process.environment = environment
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
    }
}
