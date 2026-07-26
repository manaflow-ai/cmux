import Foundation
import XCTest

final class WorkspaceWorkingDirectorySpawnUITests: BrowserFixtureSocketTestCase {
    private var temporaryDirectories: [URL] = []

    override func tearDown() {
        super.tearDown()
        for directory in temporaryDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        temporaryDirectories = []
    }

    func testDisabledInheritanceDoesNotReachSpawnedShell() throws {
        let sourceDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-issue-8741-source-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        temporaryDirectories.append(sourceDirectory)

        let app = try launchApp(additionalLaunchArguments: [
            "-workspaceInheritWorkingDirectory", "false",
        ])
        app.activate()

        let source = try socketResult(
            method: "workspace.create",
            params: [
                "title": "Issue 8741 source",
                "working_directory": sourceDirectory.path,
                "initial_command": #"printf 'SOURCE_CWD=%s\n' "$PWD"; sleep 60"#,
                "focus": true,
            ],
            responseTimeout: 12.0
        )
        let sourceSurfaceID = try XCTUnwrap(source["surface_id"] as? String)
        let sourceOutput = try XCTUnwrap(
            waitForScreenLine(prefix: "SOURCE_CWD=/", surfaceID: sourceSurfaceID, timeout: 12.0),
            "Expected source shell to report its cwd"
        )
        XCTAssertEqual(sourceOutput, "SOURCE_CWD=\(sourceDirectory.path)")

        _ = try socketResult(
            method: "surface.focus",
            params: ["surface_id": sourceSurfaceID]
        )
        app.activate()
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))

        let target = try socketResult(
            method: "workspace.create",
            params: [
                "title": "Issue 8741 probe",
                "initial_command": #"printf 'SPAWN_CWD=%s\n' "$PWD"; sleep 60"#,
                "focus": false,
            ],
            responseTimeout: 12.0
        )
        let targetSurfaceID = try XCTUnwrap(target["surface_id"] as? String)
        let targetOutput = try XCTUnwrap(
            waitForScreenLine(prefix: "SPAWN_CWD=/", surfaceID: targetSurfaceID, timeout: 12.0),
            "Expected new workspace shell to report its spawn cwd"
        )
        let spawnedDirectory = String(targetOutput.dropFirst("SPAWN_CWD=".count))

        XCTAssertNotEqual(
            spawnedDirectory,
            sourceDirectory.path,
            "Disabled workspace cwd inheritance must reach the spawned shell"
        )
    }

    private func waitForScreenLine(
        prefix: String,
        surfaceID: String,
        timeout: TimeInterval
    ) -> String? {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let line = screenLine(prefix: prefix, surfaceID: surfaceID) {
                return line
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        } while Date() < deadline
        return screenLine(prefix: prefix, surfaceID: surfaceID)
    }

    private func screenLine(prefix: String, surfaceID: String) -> String? {
        guard let envelope = socketEnvelope(
            method: "surface.read_text",
            params: ["surface_id": surfaceID],
            responseTimeout: 2.0
        ), envelope["ok"] as? Bool == true,
           let result = envelope["result"] as? [String: Any],
           let text = result["text"] as? String else {
            return nil
        }
        return text
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { $0.hasPrefix(prefix) }
    }
}
