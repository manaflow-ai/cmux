import Darwin
import Foundation
import XCTest


// MARK: - Diff command streaming
extension CMUXOpenCommandTests {
    func testDiffCommandGitSourcesDrainLargeDiffOutput() throws {
        let cliPath = try bundledCLIPath()
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let repoURL = rootURL.appendingPathComponent("repo", isDirectory: true)
        let fileURL = repoURL.appendingPathComponent("large.txt")
        try FileManager.default.createDirectory(at: repoURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        try runGit(["init"], in: repoURL)
        try runGit(["config", "user.name", "cmux tests"], in: repoURL)
        try runGit(["config", "user.email", "cmux@example.invalid"], in: repoURL)
        try (0..<5_000)
            .map { "old line \($0)" }
            .joined(separator: "\n")
            .appending("\n")
            .write(to: fileURL, atomically: true, encoding: .utf8)
        try runGit(["add", "large.txt"], in: repoURL)
        try runGit(["commit", "-m", "initial"], in: repoURL)
        try (0..<5_000)
            .map { "new line \($0)" }
            .joined(separator: "\n")
            .appending("\n")
            .write(to: fileURL, atomically: true, encoding: .utf8)

        let large = try runDiffCLIAndReadHTML(
            cliPath: cliPath,
            arguments: ["diff", "--unstaged", "--title", "Large git source"],
            currentDirectoryURL: repoURL
        )
        XCTAssertTrue(large.html.contains("Large git source"), large.html)
        XCTAssertTrue(large.patch.contains("large.txt"), large.patch)
        XCTAssertTrue(large.patch.contains("+new line 4999"), large.patch)
    }

    func testDiffCommandOpensPendingViewerBeforeGitDiffCompletes() throws {
        let cliPath = try bundledCLIPath()
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let repoURL = rootURL.appendingPathComponent("repo", isDirectory: true)
        let fakeBinURL = rootURL.appendingPathComponent("bin", isDirectory: true)
        let fakeGitURL = fakeBinURL.appendingPathComponent("git", isDirectory: false)
        let diffStartedURL = rootURL.appendingPathComponent("diff-started", isDirectory: false)
        let releaseDiffURL = rootURL.appendingPathComponent("release-diff", isDirectory: false)
        let alternateStartedURL = rootURL.appendingPathComponent("alternate-started", isDirectory: false)
        let releaseAlternateURL = rootURL.appendingPathComponent("release-alternate", isDirectory: false)
        try FileManager.default.createDirectory(at: repoURL.appendingPathComponent(".git", isDirectory: true), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: fakeBinURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        try """
        #!/bin/sh
        if [ "${1:-}" = "-C" ]; then
          shift 2
        fi
        if [ "${1:-}" = "rev-parse" ] && [ "${2:-}" = "--show-toplevel" ]; then
          printf '%s\\n' "$CMUX_FAKE_GIT_REPO_ROOT"
          exit 0
        fi
        if [ "${1:-}" = "rev-parse" ] && [ "${2:-}" = "--verify" ]; then
          : > "$CMUX_FAKE_GIT_STARTED"
          while [ ! -f "$CMUX_FAKE_GIT_RELEASE" ]; do
            sleep 0.05
          done
          exit 1
        fi
        if [ "${1:-}" = "diff" ] && [ "${2:-}" = "--cached" ]; then
          : > "$CMUX_FAKE_GIT_ALTERNATE_STARTED"
          while [ ! -f "$CMUX_FAKE_GIT_RELEASE_ALTERNATE" ]; do
            sleep 0.05
          done
          exit 0
        fi
        if [ "${1:-}" = "diff" ]; then
          : > "$CMUX_FAKE_GIT_STARTED"
          while [ ! -f "$CMUX_FAKE_GIT_RELEASE" ]; do
            sleep 0.05
          done
          cat <<'PATCH'
        diff --git a/large.txt b/large.txt
        index 1111111..2222222 100644
        --- a/large.txt
        +++ b/large.txt
        @@ -1 +1 @@
        -old line
        +new line
        PATCH
          exit 0
        fi
        if [ "${1:-}" = "for-each-ref" ]; then
          exit 0
        fi
        exit 1
        """.write(to: fakeGitURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeGitURL.path)

        let socketPath = makeSocketPath("diff-pending")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let openedURLBox = AsyncValueBox<String?>(nil)
        let openedHTMLURLBox = AsyncValueBox<URL?>(nil)
        let pendingHTMLBox = AsyncValueBox<String?>(nil)
        let diffHadStartedWhenOpenedBox = AsyncValueBox<Bool?>(nil)
        let openHandled = expectation(description: "browser opened before fake git diff completed")
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
        }

        let serverClosed = startMockServer(listenerFD: listenerFD, state: state) { line in
            guard let payload = Self.v2Payload(from: line),
                  let id = payload["id"] as? String,
                  let method = payload["method"] as? String,
                  method == "browser.open_split",
                  let params = payload["params"] as? [String: Any],
                  let rawURL = params["url"] as? String else {
                return Self.v2Response(id: "unknown", ok: false, error: ["code": "unexpected"])
            }
            openedURLBox.set(rawURL)
            diffHadStartedWhenOpenedBox.set(FileManager.default.fileExists(atPath: diffStartedURL.path))
            if let htmlURL = Self.diffViewerHTMLFileURLFromHTTPManifest(for: rawURL) {
                openedHTMLURLBox.set(htmlURL)
                pendingHTMLBox.set(try? String(contentsOf: htmlURL, encoding: .utf8))
            }
            openHandled.fulfill()
            return Self.v2Response(
                id: id,
                ok: true,
                result: ["surface_id": "surface-id", "pane_id": "pane-id", "url": rawURL]
            )
        }

        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "\(fakeBinURL.path):\(environment["PATH"] ?? "")"
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CMUX_CLAUDE_HOOK_SENTRY_DISABLED"] = "1"
        environment["CMUX_FAKE_GIT_REPO_ROOT"] = repoURL.path
        environment["CMUX_FAKE_GIT_STARTED"] = diffStartedURL.path
        environment["CMUX_FAKE_GIT_RELEASE"] = releaseDiffURL.path
        environment["CMUX_FAKE_GIT_ALTERNATE_STARTED"] = alternateStartedURL.path
        environment["CMUX_FAKE_GIT_RELEASE_ALTERNATE"] = releaseAlternateURL.path
        process.executableURL = URL(fileURLWithPath: cliPath)
        process.arguments = ["diff", "--unstaged", "--cwd", repoURL.path, "--title", "Slow diff", "--no-focus"]
        process.environment = environment
        process.currentDirectoryURL = repoURL
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        try process.run()
        defer { terminateProcess(process) }

        wait(for: [openHandled], timeout: 5)
        XCTAssertNotNil(openedURLBox.get())
        XCTAssertEqual(diffHadStartedWhenOpenedBox.get() ?? true, false)
        let pendingHTML = try XCTUnwrap(pendingHTMLBox.get())
        let pendingPayload = try diffViewerPayload(from: pendingHTML)
        XCTAssertTrue(pendingHTML.contains("data-cmux-diff-pending=\"true\""), pendingHTML)
        XCTAssertFalse(pendingHTML.contains("data-status-only=\"true\""), pendingHTML)
        XCTAssertTrue(pendingHTML.contains("<div id=\"root\"></div>"), pendingHTML)
        XCTAssertEqual(pendingPayload["pendingReplacement"] as? Bool, true)
        XCTAssertEqual(pendingPayload["title"] as? String, "Slow diff")
        XCTAssertEqual(pendingPayload["statusIsError"] as? Bool, false)
        XCTAssertFalse(FileManager.default.fileExists(atPath: releaseDiffURL.path))
        FileManager.default.createFile(atPath: releaseDiffURL.path, contents: Data())
        let openingHTMLURL = try XCTUnwrap(openedHTMLURLBox.get())
        XCTAssertTrue(waitUntil(timeout: 5) {
            let html = (try? String(contentsOf: openingHTMLURL, encoding: .utf8)) ?? ""
            return html.contains("data-cmux-diff-redirect=")
                && FileManager.default.fileExists(atPath: alternateStartedURL.path)
        })
        XCTAssertFalse(FileManager.default.fileExists(atPath: releaseAlternateURL.path))
        XCTAssertTrue(process.isRunning)
        FileManager.default.createFile(atPath: releaseAlternateURL.path, contents: Data())

        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            process.waitUntilExit()
            finished.signal()
        }
        XCTAssertEqual(finished.wait(timeout: .now() + 5), .success)
        wait(for: [serverClosed], timeout: 5)

        let stdout = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        XCTAssertEqual(process.terminationStatus, 0, stderr)
        XCTAssertTrue(stdout.contains("OK surface=surface-id pane=pane-id"), stdout)
        XCTAssertTrue(FileManager.default.fileExists(atPath: diffStartedURL.path))

        let openingURL = try XCTUnwrap(openedURLBox.get())
        let htmlURL = try resolvedDiffViewerHTMLFileURL(openingHTMLURL, from: ["url": openingURL])
        let html = try String(contentsOf: htmlURL, encoding: .utf8)
        let patch = try String(contentsOf: htmlURL.deletingPathExtension().appendingPathExtension("patch"), encoding: .utf8)
        XCTAssertFalse(html.contains("data-cmux-diff-pending=\"true\""), html)
        XCTAssertTrue(html.contains("Slow diff"), html)
        XCTAssertTrue(patch.contains("+new line"), patch)
    }

}
