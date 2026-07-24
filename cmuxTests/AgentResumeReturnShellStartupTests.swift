import Foundation
import Testing

#if canImport(cmux_DEV)
    @testable import cmux_DEV
#elseif canImport(cmux)
    @testable import cmux
#endif

@Suite("Agent resume return shell startup")
struct AgentResumeReturnShellStartupTests {
    @Test("auto-resume returns to an interactive login zsh with the session cwd and user rc")
    func autoResumeReturnsToInteractiveLoginZsh() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-8837-return-shell-\(UUID().uuidString)", isDirectory: true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        let workingDirectory = root.appendingPathComponent("project", isDirectory: true)
        try fileManager.createDirectory(at: home, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        try "export CMUX_8837_ZPROFILE=loaded\n"
            .write(to: home.appendingPathComponent(".zprofile"), atomically: true, encoding: .utf8)
        try "alias cmux_8837_alias='print alias-loaded'\n"
            .write(to: home.appendingPathComponent(".zshrc"), atomically: true, encoding: .utf8)

        let binding = SurfaceResumeBindingSnapshot(
            kind: "codex",
            command: ":",
            cwd: workingDirectory.path,
            source: "agent-hook",
            autoResume: true
        )
        let launchCommand = try #require(binding.startupCommandWithLauncherScript(
            fileManager: fileManager,
            temporaryDirectory: root
        ))

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["--noprofile", "--norc", "-c", "exec -l \(launchCommand)"]
        process.environment = [
            "HOME": home.path,
            "LOGNAME": NSUserName(),
            "PATH": "/usr/bin:/bin",
            "SHELL": "/bin/zsh",
            "TERM": "dumb",
            "USER": NSUserName(),
            "ZDOTDIR": home.path,
        ]

        let input = Pipe()
        let output = Pipe()
        let error = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = error

        try process.run()
        input.fileHandleForWriting.write(Data("""
        if [[ -o interactive ]]; then print -r -- interactive=yes; else print -r -- interactive=no; fi
        if [[ -o login ]]; then print -r -- login=yes; else print -r -- login=no; fi
        print -r -- "profile=${CMUX_8837_ZPROFILE:-missing}"
        print -r -- "cwd=$PWD"
        if (( $+aliases[cmux_8837_alias] )); then print -r -- alias=present; else print -r -- alias=missing; fi
        exit

        """.utf8))
        try input.fileHandleForWriting.close()
        process.waitUntilExit()

        let stdout = String(
            data: output.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
        let stderr = String(
            data: error.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
        let diagnostic = "stdout=\(stdout) stderr=\(stderr)"

        #expect(process.terminationStatus == 0, Comment(rawValue: diagnostic))
        #expect(stdout.contains("interactive=yes"), Comment(rawValue: diagnostic))
        #expect(stdout.contains("login=yes"), Comment(rawValue: diagnostic))
        #expect(stdout.contains("profile=loaded"), Comment(rawValue: diagnostic))
        #expect(stdout.contains("cwd=\(workingDirectory.path)"), Comment(rawValue: diagnostic))
        #expect(stdout.contains("alias=present"), Comment(rawValue: diagnostic))
    }
}
