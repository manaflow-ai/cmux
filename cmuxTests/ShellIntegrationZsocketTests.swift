import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

struct ShellIntegrationZsocketTests {
    /// The integration's fast path sends socket messages with the `zsocket`
    /// builtin. When it fails to load, every send falls back to
    /// ncat/socat/nc, and on machines whose PATH `nc` lacks unix-socket
    /// support (`-U`) the whole hook channel (report_tty, ports_kick,
    /// report_shell_state) drops silently: no sidebar ports, no shell-state
    /// reporting.
    @Test func zshIntegrationEnablesZsocketFastPath() throws {
        let script = try #require(
            RemoteInteractiveShellBootstrapBuilder.bundledShellIntegrationScript(
                named: "cmux-zsh-integration.zsh"
            ),
            "cmux-zsh-integration.zsh must ship in the app bundle"
        )
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-zsh-zsocket-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("integration.zsh")
        try script.write(to: file, atomically: true, encoding: .utf8)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = [
            "-f", "-c",
            "source '\(file.path)' >/dev/null 2>&1; print -rn -- ${_CMUX_HAS_ZSOCKET:-unset}",
        ]
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        let value = String(
            data: stdout.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""

        #expect(
            value == "1",
            "Sourcing the zsh integration must enable the zsocket fast path (got \(value))."
        )
    }
}
