import Darwin
import Foundation
import Testing

@Suite struct AutoNamingSubprocessRunnerTests {
    @Test func returnsOutputWhenTermIgnoringDescendantKeepsStdoutOpenAndCleansProcessGroup() throws {
        let root = try temporaryDirectory(named: "autoname-runner-stdout")
        defer { try? FileManager.default.removeItem(at: root) }
        let marker = root.appendingPathComponent("descendant-survived", isDirectory: false)
        let script = try executableScript(in: root, named: "summarizer", body: """
        ( trap '' TERM; sleep 1; printf survived > "$MARKER" ) &
        printf 'Good title\\n'
        exit 0
        """)

        let output = AutoNamingSubprocessRunner().run(
            executable: script,
            arguments: [],
            prompt: "",
            environment: processEnvironment(marker: marker),
            timeout: 2
        )

        #expect(output == "Good title\n")
        waitBriefly(for: 1.5)
        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }

    @Test func oversizedStdoutFailsWithoutReturningPartialOutput() throws {
        let root = try temporaryDirectory(named: "autoname-runner-output-cap")
        defer { try? FileManager.default.removeItem(at: root) }
        let chunk = String(repeating: "x", count: 16)
        let script = try executableScript(in: root, named: "summarizer", body: """
        printf '\(chunk)'
        """)

        let output = AutoNamingSubprocessRunner(maxOutputBytes: 8).run(
            executable: script,
            arguments: [],
            prompt: "",
            environment: processEnvironment(),
            timeout: 2
        )

        #expect(output == nil)
    }

    @Test func blockedStdinIsBoundedByRunnerDeadline() throws {
        let root = try temporaryDirectory(named: "autoname-runner-stdin")
        defer { try? FileManager.default.removeItem(at: root) }
        let marker = root.appendingPathComponent("child-finished", isDirectory: false)
        let script = try executableScript(in: root, named: "summarizer", body: """
        sleep 1
        printf late > "$MARKER"
        """)

        let output = AutoNamingSubprocessRunner().run(
            executable: script,
            arguments: [],
            prompt: String(repeating: "x", count: 1024 * 1024),
            environment: processEnvironment(marker: marker),
            timeout: 0.2
        )

        #expect(output == nil)
        waitBriefly(for: 1.5)
        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }

    @Test func timeoutTerminatesDescendantsInProcessGroup() throws {
        let root = try temporaryDirectory(named: "autoname-runner-group")
        defer { try? FileManager.default.removeItem(at: root) }
        let marker = root.appendingPathComponent("descendant-survived", isDirectory: false)
        let script = try executableScript(in: root, named: "summarizer", body: """
        ( trap '' TERM; sleep 1; printf survived > "$MARKER" ) &
        while :; do sleep 1; done
        """)

        let output = AutoNamingSubprocessRunner().run(
            executable: script,
            arguments: [],
            prompt: "",
            environment: processEnvironment(marker: marker),
            timeout: 0.2
        )

        #expect(output == nil)
        waitBriefly(for: 1.5)
        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }

    private func temporaryDirectory(named name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func executableScript(in root: URL, named name: String, body: String) throws -> String {
        let url = root.appendingPathComponent(name, isDirectory: false)
        try "#!/bin/sh\n\(body)\n".write(to: url, atomically: true, encoding: .utf8)
        #expect(chmod(url.path, 0o700) == 0)
        return url.path
    }

    private func processEnvironment(marker: URL? = nil) -> [String: String] {
        var environment = [
            "HOME": FileManager.default.temporaryDirectory.path,
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "TMPDIR": FileManager.default.temporaryDirectory.path,
        ]
        if let marker {
            environment["MARKER"] = marker.path
        }
        return environment
    }

    private func waitBriefly(for seconds: TimeInterval) {
        _ = DispatchSemaphore(value: 0).wait(timeout: .now() + seconds)
    }
}
