import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite(.serialized)
struct WorkspaceRemotePlatformProbeTests {
    private struct ProcessResult {
        let status: Int32
        let stdout: String
        let stderr: String
    }

    @Test
    func probeScriptWorksWhenTrLacksCharacterClasses() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(
            "cmux-remote-platform-probe-\(UUID().uuidString)",
            isDirectory: true
        )
        let home = root.appendingPathComponent("home", isDirectory: true)
        let bin = root.appendingPathComponent("bin", isDirectory: true)
        let daemonURL = home
            .appendingPathComponent(".cmux/bin/cmuxd-remote/test-version/linux-amd64", isDirectory: true)
            .appendingPathComponent("cmuxd-remote", isDirectory: false)
        try fileManager.createDirectory(at: daemonURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: bin, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        try Self.writeExecutableShellFile(
            at: daemonURL,
            body: """
            #!/bin/sh
            exit 0
            """
        )
        try Self.writeExecutableShellFile(
            at: bin.appendingPathComponent("uname"),
            body: """
            #!/bin/sh
            case "${1:-}" in
              -s) printf '%s\\n' Linux ;;
              -m) printf '%s\\n' x86_64 ;;
              *) exit 1 ;;
            esac
            """
        )
        try Self.writeExecutableShellFile(
            at: bin.appendingPathComponent("tr"),
            body: """
            #!/bin/sh
            if [ "$#" -eq 2 ] && [ "$1" = '[:upper:]' ] && [ "$2" = '[:lower:]' ]; then
              awk -v from="$1" -v to="$2" '
                BEGIN {
                  for (i = 1; i <= length(from); i++) {
                    map[substr(from, i, 1)] = substr(to, i, 1)
                  }
                }
                {
                  if (NR > 1) {
                    printf "\\n"
                  }
                  output = ""
                  for (i = 1; i <= length($0); i++) {
                    ch = substr($0, i, 1)
                    output = output ((ch in map) ? map[ch] : ch)
                  }
                  printf "%s", output
                }
              '
              exit 0
            fi
            exec /usr/bin/tr "$@"
            """
        )

        let result = try Self.runProcess(
            executablePath: "/usr/bin/env",
            arguments: [
                "HOME=\(home.path)",
                "PATH=\(bin.path):/usr/bin:/bin",
                "/bin/sh",
                "-c",
                WorkspaceRemoteSessionController.remotePlatformProbeScript(version: "test-version"),
            ]
        )

        let outputComment = Comment(rawValue: result.stdout + result.stderr)
        let stdoutComment = Comment(rawValue: result.stdout)
        #expect(result.status == 0, outputComment)
        #expect(
            result.stdout.contains("\(WorkspaceRemoteSessionController.remotePlatformProbeOSMarker)Linux"),
            stdoutComment
        )
        #expect(
            result.stdout.contains("\(WorkspaceRemoteSessionController.remotePlatformProbeArchMarker)x86_64"),
            stdoutComment
        )
        #expect(
            result.stdout.contains("\(WorkspaceRemoteSessionController.remotePlatformProbeExistsMarker)yes"),
            stdoutComment
        )
    }

    private static func writeExecutableShellFile(at url: URL, body: String) throws {
        try body.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    private static func runProcess(executablePath: String, arguments: [String]) throws -> ProcessResult {
        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()
        process.waitUntilExit()

        let stdout = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return ProcessResult(status: process.terminationStatus, stdout: stdout, stderr: stderr)
    }
}
