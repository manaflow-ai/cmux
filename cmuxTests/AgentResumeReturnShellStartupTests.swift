import Foundation
import Testing

#if canImport(cmux_DEV)
    @testable import cmux_DEV
#elseif canImport(cmux)
    @testable import cmux
#endif

@Suite("Agent resume return shell startup")
struct AgentResumeReturnShellStartupTests {
    @Test("auto-resume returns to the normally initialized login shell")
    func autoResumeReturnsToNormallyInitializedLoginShell() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-8837-return-shell-\(UUID().uuidString)", isDirectory: true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        let workingDirectory = root.appendingPathComponent("project", isDirectory: true)
        try fileManager.createDirectory(at: home, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        try """
        export CMUX_8837_ZPROFILE_COUNT=$(( ${CMUX_8837_ZPROFILE_COUNT:-0} + 1 ))
        export CMUX_8837_ZPROFILE=loaded

        """
            .write(to: home.appendingPathComponent(".zprofile"), atomically: true, encoding: .utf8)
        try """
        export CMUX_8837_ZSHRC_COUNT=$(( ${CMUX_8837_ZSHRC_COUNT:-0} + 1 ))
        alias cmux_8837_alias='print alias-loaded'

        """
            .write(to: home.appendingPathComponent(".zshrc"), atomically: true, encoding: .utf8)
        try """
        export CMUX_8837_ZLOGIN_COUNT=$(( ${CMUX_8837_ZLOGIN_COUNT:-0} + 1 ))

        """
            .write(to: home.appendingPathComponent(".zlogin"), atomically: true, encoding: .utf8)

        let binding = SurfaceResumeBindingSnapshot(
            kind: "codex",
            command: ":",
            cwd: workingDirectory.path,
            source: "agent-hook",
            autoResume: true
        )
        let launch = try #require(Workspace.surfaceResumeStartupLaunch(
            binding,
            autoResumeAgentSessions: true,
            approvalStoreURL: root.appendingPathComponent("approvals.json"),
            fileManager: fileManager,
            temporaryDirectory: root
        ))

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        let startupInput: String
        switch launch {
        case .command(let command):
            // Ghostty's startup-command path has already entered a login shell
            // before dispatching cmux's command.
            process.arguments = ["-lc", "exec \(command)"]
            startupInput = ""
        case .input(let input):
            process.arguments = ["-li"]
            startupInput = input
        }
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
        input.fileHandleForWriting.write(Data((startupInput + """
        if [[ -o interactive ]]; then print -r -- interactive=yes; else print -r -- interactive=no; fi
        if [[ -o login ]]; then print -r -- login=yes; else print -r -- login=no; fi
        print -r -- "profile=${CMUX_8837_ZPROFILE:-missing}"
        print -r -- "zprofile_count=${CMUX_8837_ZPROFILE_COUNT:-0}"
        print -r -- "zshrc_count=${CMUX_8837_ZSHRC_COUNT:-0}"
        print -r -- "zlogin_count=${CMUX_8837_ZLOGIN_COUNT:-0}"
        print -r -- "cwd=$PWD"
        if (( $+aliases[cmux_8837_alias] )); then print -r -- alias=present; else print -r -- alias=missing; fi
        exit

        """).utf8))
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
        #expect(stdout.contains("zprofile_count=1"), Comment(rawValue: diagnostic))
        #expect(stdout.contains("zshrc_count=1"), Comment(rawValue: diagnostic))
        #expect(stdout.contains("zlogin_count=1"), Comment(rawValue: diagnostic))
        #expect(stdout.contains("cwd=\(workingDirectory.path)"), Comment(rawValue: diagnostic))
        #expect(stdout.contains("alias=present"), Comment(rawValue: diagnostic))
    }
}
