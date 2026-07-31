import Darwin
import Foundation
import Testing

#if canImport(cmux_DEV)
    @testable import cmux_DEV
#elseif canImport(cmux)
    @testable import cmux
#endif

@Suite("Agent resume return shell startup")
struct AgentResumeReturnShellStartupTests {
    @Test("local resume input is one history-hidden wrapper invocation")
    func localResumeInputUsesOneWrapperInvocation() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-9200-input-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let bindings = [
            SurfaceResumeBindingSnapshot(
                kind: "codex",
                command: ":",
                source: "agent-hook",
                autoResume: true
            ),
            SurfaceResumeBindingSnapshot(
                name: "Short CLI binding",
                command: ":",
                source: "cli",
                autoResume: true
            ),
            SurfaceResumeBindingSnapshot(
                name: "Long CLI binding",
                command: "printf done >/dev/null # \(String(repeating: "x", count: 1_200))",
                source: "cli",
                autoResume: true
            ),
        ]

        for binding in bindings {
            let input = try #require(binding.startupInputWithLauncherScript(
                fileManager: fileManager,
                temporaryDirectory: root
            ))
            try expectLauncherInvocation(input)
        }

        for extraArgument in ["short", String(repeating: "nested-path-", count: 120)] {
            let snapshot = SessionRestorableAgentSnapshot(
                kind: .codex,
                sessionId: "019dad34-d218-7943-b81a-eddac5c87951",
                workingDirectory: root.path,
                launchCommand: AgentLaunchCommandSnapshot(
                    launcher: "codex",
                    executablePath: "/Users/example/.bun/bin/codex",
                    arguments: [
                        "/Users/example/.bun/bin/codex",
                        "--add-dir",
                        extraArgument,
                    ],
                    workingDirectory: root.path,
                    environment: nil,
                    capturedAt: 123,
                    source: "environment"
                )
            )
            let input = try #require(snapshot.resumeStartupInput(
                fileManager: fileManager,
                temporaryDirectory: root
            ))
            try expectLauncherInvocation(input)
        }
    }

    @Test("one-shot launcher is private, self-deleting, and TTL-pruned")
    func oneShotLauncherStoragePolicy() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-9200-store-\(UUID().uuidString)", isDirectory: true)
        let launcherDirectory = root.appendingPathComponent("cmux-r", isDirectory: true)
        let staleLauncher = launcherDirectory.appendingPathComponent("stale.zsh", isDirectory: false)
        let currentLauncher = launcherDirectory.appendingPathComponent("current.zsh", isDirectory: false)
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        try fileManager.createDirectory(at: launcherDirectory, withIntermediateDirectories: true)
        try "#!/bin/zsh\n:\n".write(to: staleLauncher, atomically: true, encoding: .utf8)
        try "#!/bin/zsh\n:\n".write(to: currentLauncher, atomically: true, encoding: .utf8)
        try fileManager.setAttributes(
            [.modificationDate: now.addingTimeInterval(-(25 * 60 * 60))],
            ofItemAtPath: staleLauncher.path
        )
        try fileManager.setAttributes(
            [.modificationDate: now.addingTimeInterval(-(23 * 60 * 60))],
            ofItemAtPath: currentLauncher.path
        )
        defer { try? fileManager.removeItem(at: root) }

        let launcher = try #require(OneShotTerminalLauncherStore(
            fileManager: fileManager,
            temporaryDirectory: root,
            currentDate: now
        ).writeLauncherScript(
            command: ":",
            workingDirectory: nil
        ))

        #expect(!fileManager.fileExists(atPath: staleLauncher.path))
        #expect(fileManager.fileExists(atPath: currentLauncher.path))
        let directoryMode = try #require(
            fileManager.attributesOfItem(atPath: launcherDirectory.path)[.posixPermissions] as? NSNumber
        ).intValue & 0o777
        let launcherMode = try #require(
            fileManager.attributesOfItem(atPath: launcher.path)[.posixPermissions] as? NSNumber
        ).intValue & 0o777
        #expect(directoryMode == 0o700)
        #expect(launcherMode == 0o600)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = [launcher.path]
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        #expect(!fileManager.fileExists(atPath: launcher.path))
    }

    @Test("launcher cwd guard preserves present, missing, and inaccessible outcomes")
    func launcherWorkingDirectoryOutcomes() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-9200-cwd-\(UUID().uuidString)", isDirectory: true)
        let presentDirectory = root.appendingPathComponent("present", isDirectory: true)
        let missingDirectory = root.appendingPathComponent("missing", isDirectory: true)
        let inaccessibleDirectory = root.appendingPathComponent("inaccessible", isDirectory: true)
        let nestedInaccessibleDirectory = inaccessibleDirectory.appendingPathComponent("child", isDirectory: true)
        try fileManager.createDirectory(at: presentDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: nestedInaccessibleDirectory, withIntermediateDirectories: true)
        try fileManager.setAttributes([.posixPermissions: 0o000], ofItemAtPath: inaccessibleDirectory.path)
        defer {
            try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: inaccessibleDirectory.path)
            try? fileManager.removeItem(at: root)
        }

        let presentOutput = root.appendingPathComponent("present.txt", isDirectory: false)
        let presentInput = try launcherInput(
            command: "pwd > \(TerminalStartupShellQuoting.singleQuoted(presentOutput.path))",
            workingDirectory: presentDirectory.path,
            root: root
        )
        try expectLauncherInvocation(presentInput)
        let presentResult = try runShellInput(presentInput, currentDirectory: root)
        #expect(presentResult.status == 0, Comment(rawValue: presentResult.stderr))
        let presentCwd = try #require(
            String(bytes: Data(contentsOf: presentOutput), encoding: .utf8)
        )
        #expect(
            presentCwd.trimmingCharacters(in: .whitespacesAndNewlines) == presentDirectory.path
        )

        let missingOutput = root.appendingPathComponent("missing.txt", isDirectory: false)
        let missingInput = try launcherInput(
            command: "pwd > \(TerminalStartupShellQuoting.singleQuoted(missingOutput.path))",
            workingDirectory: missingDirectory.path,
            root: root
        )
        try expectLauncherInvocation(missingInput)
        let missingResult = try runShellInput(missingInput, currentDirectory: root)
        #expect(missingResult.status == 0, Comment(rawValue: missingResult.stderr))
        let missingCwd = try #require(
            String(bytes: Data(contentsOf: missingOutput), encoding: .utf8)
        )
        #expect(
            missingCwd.trimmingCharacters(in: .whitespacesAndNewlines) ==
                root.resolvingSymlinksInPath().path
        )

        if getuid() != 0 {
            let inaccessibleOutput = root.appendingPathComponent("inaccessible.txt", isDirectory: false)
            let inaccessibleInput = try launcherInput(
                command: "print ran > \(TerminalStartupShellQuoting.singleQuoted(inaccessibleOutput.path))",
                workingDirectory: inaccessibleDirectory.path,
                root: root
            )
            try expectLauncherInvocation(inaccessibleInput)
            let inaccessibleResult = try runShellInput(inaccessibleInput, currentDirectory: root)
            #expect(inaccessibleResult.status != 0)
            #expect(!fileManager.fileExists(atPath: inaccessibleOutput.path))

            let nestedInaccessibleOutput = root.appendingPathComponent("nested-inaccessible.txt", isDirectory: false)
            let nestedInaccessibleInput = try launcherInput(
                command: "print ran > \(TerminalStartupShellQuoting.singleQuoted(nestedInaccessibleOutput.path))",
                workingDirectory: nestedInaccessibleDirectory.path,
                root: root
            )
            try expectLauncherInvocation(nestedInaccessibleInput)
            let nestedInaccessibleResult = try runShellInput(nestedInaccessibleInput, currentDirectory: root)
            #expect(nestedInaccessibleResult.status != 0)
            #expect(!fileManager.fileExists(atPath: nestedInaccessibleOutput.path))
        }
    }

    @Test("pre-change hook and CLI bindings with an outside cwd prefix still resume")
    func legacyOutsideScriptWorkingDirectoryPrefixStillResumes() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-9200-legacy-\(UUID().uuidString)", isDirectory: true)
        let workingDirectory = root.appendingPathComponent("legacy project", isDirectory: true)
        try fileManager.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let quotedDirectory = TerminalStartupShellQuoting.singleQuoted(workingDirectory.path)
        for source in ["agent-hook", "cli"] {
            let output = root.appendingPathComponent("\(source).txt", isDirectory: false)
            let quotedOutput = TerminalStartupShellQuoting.singleQuoted(output.path)
            let encoded = try JSONSerialization.data(withJSONObject: [
                "kind": "codex",
                "command": "cd -- \(quotedDirectory) 2>/dev/null || [ ! -d \(quotedDirectory) ] && pwd > \(quotedOutput)",
                "cwd": workingDirectory.path,
                "source": source,
                "autoResume": true,
            ])
            let binding = try JSONDecoder().decode(SurfaceResumeBindingSnapshot.self, from: encoded)
            let input = try #require(binding.startupInputWithLauncherScript(
                fileManager: fileManager,
                temporaryDirectory: root
            ))

            try expectLauncherInvocation(input)
            let result = try runShellInput(input, currentDirectory: root)
            #expect(result.status == 0, Comment(rawValue: "\(source): \(result.stderr)"))
            let restoredCwd = try #require(
                String(bytes: Data(contentsOf: output), encoding: .utf8)
            )
            #expect(
                restoredCwd.trimmingCharacters(in: .whitespacesAndNewlines) == workingDirectory.path
            )
        }
    }

    @Test("auto-resume returns to the normally initialized login shell")
    func autoResumeReturnsToNormallyInitializedLoginShell() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-8837-return-shell-\(UUID().uuidString)", isDirectory: true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        let workingDirectory = root.appendingPathComponent("project", isDirectory: true)
        let historyURL = home.appendingPathComponent(".zsh_history", isDirectory: false)
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
        HISTFILE=\(TerminalStartupShellQuoting.singleQuoted(historyURL.path))
        HISTSIZE=100
        SAVEHIST=100
        setopt HIST_IGNORE_SPACE

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
        process.arguments = ["-li"]
        process.currentDirectoryURL = workingDirectory
        let startupInput = launch.initialInput
        try expectLauncherInvocation(startupInput)
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
        print -r -- history-control >/dev/null
        fc -W "$HISTFILE"
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
        #expect(
            stdout.contains("cwd=\(workingDirectory.resolvingSymlinksInPath().path)"),
            Comment(rawValue: diagnostic)
        )
        #expect(stdout.contains("alias=present"), Comment(rawValue: diagnostic))
        let history = try #require(
            String(bytes: Data(contentsOf: historyURL), encoding: .utf8)
        )
        #expect(history.contains("history-control"), Comment(rawValue: history))
        #expect(!history.contains(root.path), Comment(rawValue: history))
    }

    private func launcherInput(command: String, workingDirectory: String, root: URL) throws -> String {
        let binding = SurfaceResumeBindingSnapshot(
            kind: "codex",
            command: command,
            cwd: workingDirectory,
            source: "agent-hook",
            autoResume: true
        )
        return try #require(binding.startupInputWithLauncherScript(
            fileManager: .default,
            temporaryDirectory: root
        ))
    }

    private func expectLauncherInvocation(
        _ input: String,
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws {
        #expect(input.first == " ", "Injected resume input must opt into HIST_IGNORE_SPACE", sourceLocation: sourceLocation)
        let commandLine = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let words = TerminalStartupWorkingDirectoryPrefix.shellWordRanges(commandLine).map(\.value)
        #expect(words.count == 2, "Expected one interpreter + launcher invocation, saw: \(input)", sourceLocation: sourceLocation)
        #expect(words.first == "/bin/zsh", "Expected the established zsh wrapper, saw: \(input)", sourceLocation: sourceLocation)
        let path = try #require(words.dropFirst().first, sourceLocation: sourceLocation)
        #expect(path.hasPrefix("/"), "Expected an absolute launcher path, saw: \(input)", sourceLocation: sourceLocation)
        for shellOperator in ["cd ", "&&", "||", "{", "}", ";"] {
            #expect(
                !commandLine.contains(shellOperator),
                "Launcher input contains shell syntax '\(shellOperator)': \(input)",
                sourceLocation: sourceLocation
            )
        }
    }

    private func runShellInput(
        _ input: String,
        currentDirectory: URL
    ) throws -> (status: Int32, stderr: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-fc", input]
        process.currentDirectoryURL = currentDirectory
        let error = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = error

        try process.run()
        process.waitUntilExit()
        return (
            process.terminationStatus,
            String(
                data: error.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            ) ?? ""
        )
    }
}
