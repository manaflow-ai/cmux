import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif


// MARK: - Shell bootstrap, locale, and PATH setup
extension WorkspaceRemoteConnectionTests {
    private func writeShellFile(at url: URL, lines: [String]) throws {
        try lines.joined(separator: "\n")
            .appending("\n")
            .write(to: url, atomically: true, encoding: .utf8)
    }

    private func runRelayZshHistfile(
        configureUserHome: (URL) throws -> URL
    ) throws -> String {
        let fileManager = FileManager.default
        let home = fileManager.temporaryDirectory.appendingPathComponent("cmux-relay-zsh-\(UUID().uuidString)")
        let relayDir = home.appendingPathComponent(".cmux/relay/64011.shell")

        try fileManager.createDirectory(at: relayDir, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: home) }

        let effectiveUserZdotdir = try configureUserHome(home)
        let bootstrap = RemoteRelayZshBootstrap(shellStateDir: relayDir.path)

        try writeShellFile(at: relayDir.appendingPathComponent(".zshenv"), lines: bootstrap.zshEnvLines)
        try writeShellFile(at: relayDir.appendingPathComponent(".zprofile"), lines: bootstrap.zshProfileLines)
        try writeShellFile(at: relayDir.appendingPathComponent(".zshrc"), lines: bootstrap.zshRCLines(commonShellLines: []))
        try writeShellFile(at: relayDir.appendingPathComponent(".zlogin"), lines: bootstrap.zshLoginLines)

        let result = runProcess(
            executablePath: "/usr/bin/env",
            arguments: [
                "HOME=\(home.path)",
                "TERM=xterm-256color",
                "SHELL=/bin/zsh",
                "USER=\(NSUserName())",
                "CMUX_REAL_ZDOTDIR=\(home.path)",
                "ZDOTDIR=\(relayDir.path)",
                "/bin/zsh",
                "-ilc",
                "print -r -- \"$HISTFILE\"",
            ],
            timeout: 5
        )

        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)

        let histfile = result.stdout
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .last(where: { !$0.isEmpty })
        XCTAssertEqual(histfile, effectiveUserZdotdir.appendingPathComponent(".zsh_history").path)
        return histfile ?? ""
    }

    private func runGeneratedBashBootstrapMarkers(startupFiles: [String: String]) throws -> [String] {
        let fileManager = FileManager.default
        let home = fileManager.temporaryDirectory.appendingPathComponent("cmux-relay-bash-\(UUID().uuidString)")
        let bin = home.appendingPathComponent("bin")
        let markerFile = home.appendingPathComponent("markers.txt")
        try fileManager.createDirectory(at: bin, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: home) }

        for (fileName, marker) in startupFiles {
            let startupScript = """
            printf '%s\\n' '\(marker)' >> "$CMUX_BASH_MARKERS"
            """
            try startupScript.write(to: home.appendingPathComponent(fileName), atomically: true, encoding: .utf8)
        }
        try writeExecutableShellFile(
            at: bin.appendingPathComponent("bash"),
            body: """
            #!/bin/sh
            rcfile=
            while [ "$#" -gt 0 ]; do
              case "$1" in
                --rcfile)
                  shift
                  rcfile="${1:-}"
                  ;;
              esac
              shift || true
            done
            if [ -n "$rcfile" ]; then
              . "$rcfile"
            fi
            """
        )

        let script = RemoteInteractiveShellBootstrapBuilder.script(
            remoteRelayPort: 0,
            shellFeatures: ""
        )
        let result = runProcess(
            executablePath: "/usr/bin/env",
            arguments: [
                "HOME=\(home.path)",
                "SHELL=\(bin.appendingPathComponent("bash").path)",
                "PATH=\(bin.path):/usr/bin:/bin",
                "TERM=xterm-256color",
                "USER=\(NSUserName())",
                "CMUX_BASH_MARKERS=\(markerFile.path)",
                "/bin/sh",
                "-c",
                script,
            ],
            timeout: 5
        )

        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)

        let contents = (try? String(contentsOf: markerFile, encoding: .utf8)) ?? ""
        return contents
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    func testGeneratedBashBootstrapSourcesLoginFilesInBashPrecedenceOrder() throws {
        XCTAssertEqual(
            try runGeneratedBashBootstrapMarkers(startupFiles: [
                ".bash_profile": "bash_profile",
                ".bash_login": "bash_login",
                ".profile": "profile",
                ".bashrc": "bashrc",
            ]),
            ["bash_profile", "bashrc"]
        )
        XCTAssertEqual(
            try runGeneratedBashBootstrapMarkers(startupFiles: [
                ".bash_login": "bash_login",
                ".profile": "profile",
                ".bashrc": "bashrc",
            ]),
            ["bash_login", "bashrc"]
        )
        XCTAssertEqual(
            try runGeneratedBashBootstrapMarkers(startupFiles: [
                ".profile": "profile",
                ".bashrc": "bashrc",
            ]),
            ["profile", "bashrc"]
        )
    }

    func testGeneratedFallbackShellBootstrapPrependsCmuxBinOnce() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-fallback-shell-bootstrap-\(UUID().uuidString)")
        let home = root.appendingPathComponent("home")
        let bin = root.appendingPathComponent("bin")
        let capturedPath = root.appendingPathComponent("path.txt")
        try fileManager.createDirectory(at: home, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: bin, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        try writeExecutableShellFile(
            at: bin.appendingPathComponent("fish"),
            body: """
            #!/bin/sh
            printf '%s\\n' "$PATH" > "$CMUX_CAPTURE_PATH"
            """
        )

        let script = RemoteInteractiveShellBootstrapBuilder.script(
            remoteRelayPort: 0,
            shellFeatures: ""
        )
        let result = runProcess(
            executablePath: "/usr/bin/env",
            arguments: [
                "HOME=\(home.path)",
                "SHELL=\(bin.appendingPathComponent("fish").path)",
                "PATH=/usr/bin:/bin",
                "TERM=xterm-256color",
                "USER=\(NSUserName())",
                "CMUX_CAPTURE_PATH=\(capturedPath.path)",
                "/bin/sh",
                "-c",
                script,
            ],
            timeout: 5
        )

        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)

        let path = try String(contentsOf: capturedPath, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let cmuxBinEntries = path.split(separator: ":")
            .filter { $0 == "\(home.path)/.cmux/bin" }
        XCTAssertEqual(cmuxBinEntries.count, 1, path)
    }

    func testRelayZshBootstrapUsesRealHomeHistoryByDefault() throws {
        let histfile = try runRelayZshHistfile { home in
            try ":\n".write(to: home.appendingPathComponent(".zshenv"), atomically: true, encoding: .utf8)
            try ":\n".write(to: home.appendingPathComponent(".zshrc"), atomically: true, encoding: .utf8)
            return home
        }

        XCTAssertTrue(histfile.hasSuffix("/.zsh_history"))
    }

    func testRelayZshBootstrapUsesUserUpdatedZdotdirHistory() throws {
        let histfile = try runRelayZshHistfile { home in
            let altZdotdir = home.appendingPathComponent("dotfiles")
            try FileManager.default.createDirectory(at: altZdotdir, withIntermediateDirectories: true)
            try "export ZDOTDIR=\"$HOME/dotfiles\"\n".write(
                to: home.appendingPathComponent(".zshenv"),
                atomically: true,
                encoding: .utf8
            )
            try ":\n".write(to: altZdotdir.appendingPathComponent(".zshrc"), atomically: true, encoding: .utf8)
            return altZdotdir
        }

        XCTAssertTrue(histfile.contains("/dotfiles/.zsh_history"))
    }

    func testRemoteUTF8LocaleSetupLinesSeedUTF8LocaleWhenMissing() {
        let script = (RemoteShellEnvironment.utf8LocaleSetupLines() + [
            #"printf '%s' "${LANG}|${LC_CTYPE}|${LC_ALL}""#,
        ])
            .joined(separator: "\n")

        let result = runProcess(
            executablePath: "/usr/bin/env",
            arguments: [
                "LANG=",
                "LC_CTYPE=",
                "LC_ALL=",
                "/bin/sh",
                "-c",
                script,
            ],
            timeout: 5
        )

        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines), "C.UTF-8|C.UTF-8|C.UTF-8")
    }

    func testRemoteUTF8LocaleSetupLinesPreserveExistingUTF8Locale() {
        let script = (RemoteShellEnvironment.utf8LocaleSetupLines() + [
            #"printf '%s' "${LANG}|${LC_CTYPE}|${LC_ALL}""#,
        ])
            .joined(separator: "\n")

        let result = runProcess(
            executablePath: "/usr/bin/env",
            arguments: [
                "LANG=ja_JP.UTF-8",
                "LC_CTYPE=",
                "LC_ALL=",
                "/bin/sh",
                "-c",
                script,
            ],
            timeout: 5
        )

        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines), "ja_JP.UTF-8||")
    }

    func testExecutableSearchPathsIncludesHomebrewAndHomeFallbacks() {
        let paths = WorkspaceRemoteSessionController.executableSearchPaths(
            environment: [
                "HOME": "/Users/tester",
                "PATH": "/usr/bin:/bin",
            ],
            pathHelperOutput: "PATH=\"/opt/homebrew/bin:/usr/local/bin:/usr/bin\"; export PATH;\n"
        )

        XCTAssertEqual(
            paths,
            [
                "/usr/bin",
                "/bin",
                "/Users/tester/.local/bin",
                "/Users/tester/go/bin",
                "/Users/tester/bin",
                "/opt/homebrew/bin",
                "/usr/local/bin",
                "/opt/homebrew/sbin",
                "/usr/local/sbin",
                "/usr/sbin",
                "/sbin",
            ]
        )
    }

    func testParsePathHelperPathsExtractsPathEntries() {
        XCTAssertEqual(
            WorkspaceRemoteSessionController.parsePathHelperPaths(
                "PATH=\"/opt/homebrew/bin:/usr/local/bin:/usr/bin\"; export PATH;\n"
            ),
            [
                "/opt/homebrew/bin",
                "/usr/local/bin",
                "/usr/bin",
            ]
        )
    }

    func testParsePathHelperPathsIgnoresMANPATHAssignments() {
        XCTAssertEqual(
            WorkspaceRemoteSessionController.parsePathHelperPaths(
                """
                MANPATH="/opt/homebrew/share/man:/usr/share/man"; export MANPATH;
                PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin"; export PATH;
                """
            ),
            [
                "/opt/homebrew/bin",
                "/usr/local/bin",
                "/usr/bin",
            ]
        )
    }

}
