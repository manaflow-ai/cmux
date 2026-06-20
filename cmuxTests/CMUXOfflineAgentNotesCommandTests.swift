import Darwin
import Foundation
import XCTest

extension CLINotifyProcessIntegrationRegressionTests {
    func testOfflineNotesAddAndListWorkWithoutSocket() throws {
        let cliPath = try bundledCLIPath()
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let notesURL = rootURL.appendingPathComponent("offline-agent-notes.json", isDirectory: false)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = makeSocketPath("notes-add")
        environment["CMUX_OFFLINE_AGENT_NOTES_PATH"] = notesURL.path
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"

        let add = runProcess(
            executablePath: cliPath,
            arguments: ["notes", "add", "--agent", "codex", "--", "Check the release notes when online"],
            environment: environment,
            timeout: 5
        )
        XCTAssertFalse(add.timedOut, add.stderr)
        XCTAssertEqual(add.status, 0, add.stderr)
        XCTAssertTrue(add.stdout.hasPrefix("OK note="), add.stdout)

        let list = runProcess(
            executablePath: cliPath,
            arguments: ["notes", "list", "--json"],
            environment: environment,
            timeout: 5
        )
        XCTAssertFalse(list.timedOut, list.stderr)
        XCTAssertEqual(list.status, 0, list.stderr)
        let payload = try XCTUnwrap(jsonObject(list.stdout))
        let notes = try XCTUnwrap(payload["notes"] as? [[String: Any]])
        XCTAssertEqual(notes.count, 1)
        XCTAssertEqual(notes.first?["agent"] as? String, "codex")
        XCTAssertEqual(notes.first?["text"] as? String, "Check the release notes when online")
        XCTAssertNil(notes.first?["flushed_at"] as? Double)
    }

    func testOfflineNotesFlushSubmitsPendingNotesAndMarksThemFlushed() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("notes-flush")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let notesURL = rootURL.appendingPathComponent("offline-agent-notes.json", isDirectory: false)
        let workspaceId = UUID().uuidString.lowercased()
        let surfaceId = UUID().uuidString.lowercased()
        let state = MockSocketServerState()

        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
            try? FileManager.default.removeItem(at: rootURL)
        }

        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_OFFLINE_AGENT_NOTES_PATH"] = notesURL.path
        environment["CMUX_WORKSPACE_ID"] = workspaceId
        environment["CMUX_SURFACE_ID"] = surfaceId
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"

        for text in ["Audit the auth retry path", "Hand this to an agent after online"] {
            let add = runProcess(
                executablePath: cliPath,
                arguments: ["notes", "add", "--agent", "codex", "--", text],
                environment: environment,
                timeout: 5
            )
            XCTAssertEqual(add.status, 0, add.stderr)
        }

        let serverHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
            guard let payload = self.jsonObject(line),
                  let id = payload["id"] as? String,
                  payload["method"] as? String == "surface.send_text",
                  let params = payload["params"] as? [String: Any],
                  params["workspace_id"] as? String == workspaceId,
                  params["surface_id"] as? String == surfaceId,
                  let text = params["text"] as? String,
                  text.contains("Offline cmux notes queued while you were away:"),
                  text.contains("Audit the auth retry path"),
                  text.contains("Hand this to an agent after online"),
                  text.hasSuffix("\r") else {
                return self.malformedRequestResponse(raw: line)
            }
            return self.v2Response(id: id, ok: true, result: ["surface_id": surfaceId, "workspace_id": workspaceId])
        }

        let flush = runProcess(
            executablePath: cliPath,
            arguments: ["notes", "flush", "--agent", "codex"],
            environment: environment,
            timeout: 5
        )

        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(flush.timedOut, flush.stderr)
        XCTAssertEqual(flush.status, 0, flush.stderr)
        XCTAssertEqual(flush.stdout, "OK flushed=2\n")
        XCTAssertEqual(state.snapshot().compactMap { jsonObject($0)?["method"] as? String }, ["surface.send_text"])

        let pending = runProcess(
            executablePath: cliPath,
            arguments: ["notes", "list", "--json"],
            environment: environment,
            timeout: 5
        )
        let pendingPayload = try XCTUnwrap(jsonObject(pending.stdout))
        XCTAssertEqual((pendingPayload["notes"] as? [[String: Any]])?.count, 0)

        let all = runProcess(
            executablePath: cliPath,
            arguments: ["notes", "list", "--all", "--json"],
            environment: environment,
            timeout: 5
        )
        let allPayload = try XCTUnwrap(jsonObject(all.stdout))
        let allNotes = try XCTUnwrap(allPayload["notes"] as? [[String: Any]])
        XCTAssertEqual(allNotes.count, 2)
        XCTAssertNotNil(allNotes.first?["flushed_at"] as? Double)
    }
}
