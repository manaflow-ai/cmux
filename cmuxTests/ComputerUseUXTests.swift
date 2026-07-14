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
}
