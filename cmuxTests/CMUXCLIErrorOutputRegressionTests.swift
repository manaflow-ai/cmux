import XCTest

final class CMUXCLIErrorOutputRegressionTests: XCTestCase {
    private struct ProcessRunResult {
        let status: Int32
        let stdout: String
        let timedOut: Bool
    }

    func testCLIErrorPathDoesNotCrashWhenStderrIsClosed() throws {
        let cliPath = try bundledCLIPath()
        let result = runShell(
            "CMUX_CLI_SENTRY_DISABLED=1 \(shellSingleQuote(cliPath)) definitely-not-a-command 2>&-",
            timeout: 5
        )

        XCTAssertFalse(result.timedOut, result.stdout)
        XCTAssertEqual(result.status, 1, result.stdout)
        XCTAssertTrue(result.stdout.contains("Usage:"), result.stdout)
    }

    func testUseCommandRejectsNoRunWithCommandOverrideBeforeRepositoryResolution() throws {
        let cliPath = try bundledCLIPath()
        let result = runShell(
            "CMUX_CLI_SENTRY_DISABLED=1 \(shellSingleQuote(cliPath)) use not-a-github-repo --command \"./start.sh\" --no-run 2>&1",
            timeout: 5
        )

        XCTAssertFalse(result.timedOut, result.stdout)
        XCTAssertEqual(result.status, 1, result.stdout)
        XCTAssertTrue(result.stdout.contains("cannot be used with --no-run"), result.stdout)
    }

    func testUseCommandHidesRawGitErrorOutput() throws {
        let cliPath = try bundledCLIPath()
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let fakeBinURL = directory.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: fakeBinURL, withIntermediateDirectories: true)
        let fakeGitURL = fakeBinURL.appendingPathComponent("git", isDirectory: false)
        try """
        #!/bin/sh
        echo "fatal: internal-host.example token secret --ff-only remote get-url origin" >&2
        exit 42
        """.write(to: fakeGitURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fakeGitURL.path)

        let homeURL = directory.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: homeURL, withIntermediateDirectories: true)

        let result = runShell(
            "HOME=\(shellSingleQuote(homeURL.path)) PATH=\(shellSingleQuote(fakeBinURL.path)):/usr/bin:/bin CMUX_CLI_SENTRY_DISABLED=1 \(shellSingleQuote(cliPath)) use owner/repo --no-run 2>&1",
            timeout: 5
        )

        XCTAssertFalse(result.timedOut, result.stdout)
        XCTAssertEqual(result.status, 1, result.stdout)
        XCTAssertTrue(result.stdout.contains("Failed to download extension repository (exit 42)"), result.stdout)
        XCTAssertFalse(result.stdout.contains("fatal:"), result.stdout)
        XCTAssertFalse(result.stdout.contains("internal-host.example"), result.stdout)
        XCTAssertFalse(result.stdout.contains("token secret"), result.stdout)
        XCTAssertFalse(result.stdout.contains("--ff-only"), result.stdout)
        XCTAssertFalse(result.stdout.contains("remote get-url"), result.stdout)
    }

    func testUseCommandRejectsOptionLikeCommandValueBeforeCheckout() throws {
        let cliPath = try bundledCLIPath()
        let result = runShell(
            "CMUX_CLI_SENTRY_DISABLED=1 \(shellSingleQuote(cliPath)) use owner/repo --command --no-run 2>&1",
            timeout: 5
        )

        XCTAssertFalse(result.timedOut, result.stdout)
        XCTAssertEqual(result.status, 1, result.stdout)
        XCTAssertTrue(result.stdout.contains("--command requires a command, not another flag"), result.stdout)
    }

    func testUseCommandInvalidRepositoryDoesNotEchoRawInput() throws {
        let cliPath = try bundledCLIPath()
        let result = runShell(
            "CMUX_CLI_SENTRY_DISABLED=1 \(shellSingleQuote(cliPath)) use \(shellSingleQuote("https://credential-secret@github.com/bad*/repo")) --no-run 2>&1",
            timeout: 5
        )

        XCTAssertFalse(result.timedOut, result.stdout)
        XCTAssertEqual(result.status, 1, result.stdout)
        XCTAssertTrue(result.stdout.contains("Invalid GitHub repository"), result.stdout)
        XCTAssertFalse(result.stdout.contains("credential-secret"), result.stdout)
        XCTAssertFalse(result.stdout.contains("bad*/repo"), result.stdout)
    }

    func testUseCommandRejectsSymlinkedSensitiveInstallPath() throws {
        let cliPath = try bundledCLIPath()
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let homeURL = directory.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(
            at: homeURL.appendingPathComponent(".ssh", isDirectory: true),
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(
            atPath: homeURL.appendingPathComponent("safe-link", isDirectory: true).path,
            withDestinationPath: ".ssh"
        )

        let fakeBinURL = directory.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: fakeBinURL, withIntermediateDirectories: true)
        let fakeGitURL = fakeBinURL.appendingPathComponent("git", isDirectory: false)
        try """
        #!/bin/sh
        if [ "$1" = "clone" ]; then
          mkdir -p "$3/.git"
          cat > "$3/cmux.extension.json" <<'JSON'
        {"id":"owner.repo","name":"Repo","publisher":"owner","version":"0.0.1","install":{"path":"~/safe-link"}}
        JSON
          exit 0
        fi
        exit 1
        """.write(to: fakeGitURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fakeGitURL.path)

        let result = runShell(
            "HOME=\(shellSingleQuote(homeURL.path)) PATH=\(shellSingleQuote(fakeBinURL.path)):/usr/bin:/bin CMUX_CLI_SENTRY_DISABLED=1 \(shellSingleQuote(cliPath)) use owner/repo --no-run 2>&1",
            timeout: 5
        )

        XCTAssertFalse(result.timedOut, result.stdout)
        XCTAssertEqual(result.status, 1, result.stdout)
        XCTAssertTrue(result.stdout.contains("install.path must not target sensitive home directory ~/.ssh"), result.stdout)
        XCTAssertFalse(result.stdout.contains("OK "), result.stdout)
    }

    private func bundledCLIPath() throws -> String {
        let fileManager = FileManager.default
        let appBundleURL = Bundle(for: Self.self)
            .bundleURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let enumerator = fileManager.enumerator(at: appBundleURL, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])

        while let item = enumerator?.nextObject() as? URL {
            guard item.lastPathComponent == "cmux",
                  item.path.contains(".app/Contents/Resources/bin/cmux") else {
                continue
            }
            return item.path
        }

        throw XCTSkip("Bundled cmux CLI not found in \(appBundleURL.path)")
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("CMUXCLIErrorOutputRegressionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func shellSingleQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\"'\"'"))'"
    }

    private func runShell(_ command: String, timeout: TimeInterval) -> ProcessRunResult {
        let process = Process()
        let stdoutPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdoutPipe

        do {
            try process.run()
        } catch {
            return ProcessRunResult(status: -1, stdout: String(describing: error), timedOut: false)
        }

        let exitSignal = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            process.waitUntilExit()
            exitSignal.signal()
        }

        let timedOut = exitSignal.wait(timeout: .now() + timeout) == .timedOut
        if timedOut {
            process.terminate()
            _ = exitSignal.wait(timeout: .now() + 1)
        }

        return ProcessRunResult(
            status: process.terminationStatus,
            stdout: String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "",
            timedOut: timedOut
        )
    }
}
