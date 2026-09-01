import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite(.serialized)
struct CMUXCLIForkLegacyFallbackTests {
    private final class BundleToken {}

    @Test
    func structuredLaunchRunsBeforeLegacyForkCommand() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-fork-legacy-order-\(UUID().uuidString)", isDirectory: true)
        let executable = root.appendingPathComponent("fork-agent", isDirectory: false)
        let structuredMarker = root.appendingPathComponent("structured", isDirectory: false)
        let legacyMarker = root.appendingPathComponent("legacy", isDirectory: false)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }
        try """
        #!/bin/sh
        {
          printf 'arg=%s\\n' "$1"
          printf 'arg=%s\\n' "$2"
        } > "$FORK_TEST_MARKER"
        """.write(to: executable, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)

        let surfaceID = UUID().uuidString.lowercased()
        let checkpointID = "fork-legacy-order-checkpoint"
        let responseData = try JSONSerialization.data(withJSONObject: [
            "ok": true,
            "result": [
                "restore_record": [
                    "mode": "resumeAgent",
                    "kind": "pi",
                    "checkpoint_id": checkpointID,
                    "working_directory": root.path,
                    "launch_command": [
                        "arguments": [executable.path],
                        "executable_path": executable.path,
                        "working_directory": root.path,
                    ],
                    "fork_command": "printf legacy > \(legacyMarker.path)",
                ],
            ],
        ])
        let socketPath = "/tmp/cmux-fork-legacy-order-\(UUID().uuidString.prefix(8)).sock"
        let responder = try UnixSocketResponder(
            path: socketPath,
            response: String(decoding: responseData, as: UTF8.self)
        )
        defer { responder.stop() }

        var environment = ProcessInfo.processInfo.environment.filter {
            !$0.key.hasPrefix("CMUX_") && !$0.key.hasPrefix("CMUXD_")
        }
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["HOME"] = root.path
        environment["CFFIXED_USER_HOME"] = root.path
        environment["AppleLanguages"] = "(en)"
        environment["AppleLocale"] = "en_US_POSIX"
        environment["LANG"] = "en_US.UTF-8"
        environment["LC_ALL"] = "C"
        environment["FORK_TEST_MARKER"] = structuredMarker.path
        environment["PATH"] = "/usr/bin:/bin"

        let process = Process()
        process.executableURL = URL(
            fileURLWithPath: try BundledCLITestSupport.bundledCLIPath(for: BundleToken.self)
        )
        process.arguments = ["fork", "--surface", surfaceID, "pi", checkpointID]
        process.environment = environment
        let stderr = Pipe()
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()

        #expect(process.terminationStatus == 0)
        let output = try String(contentsOf: structuredMarker, encoding: .utf8)
        #expect(output.contains("arg=--fork"))
        #expect(output.contains("arg=\(checkpointID)"))
        #expect(!fileManager.fileExists(atPath: legacyMarker.path))
        _ = stderr.fileHandleForReading.readDataToEndOfFile()
    }
}
