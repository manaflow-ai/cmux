import Darwin
import Foundation
import XCTest

// Regression coverage for the diff viewer fast-first-paint contract:
// `cmux diff` must open the loading page and render the selected diff
// before any smart branch-base resolution (`gh` lookups) runs.
extension CMUXOpenCommandTests {
    func testDiffCommandRedirectsBeforeSiblingRepoDiffsAndSmartBranchBase() throws {
        let cliPath = try bundledCLIPath()
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let repoURL = rootURL.appendingPathComponent("repo", isDirectory: true)
        let fakeBinURL = rootURL.appendingPathComponent("bin", isDirectory: true)
        let fakeGitURL = fakeBinURL.appendingPathComponent("git", isDirectory: false)
        let fakeGHURL = fakeBinURL.appendingPathComponent("gh", isDirectory: false)
        let diffStartedURL = rootURL.appendingPathComponent("diff-started", isDirectory: false)
        let releaseDiffURL = rootURL.appendingPathComponent("release-diff", isDirectory: false)
        let alternateStartedURL = rootURL.appendingPathComponent("alternate-started", isDirectory: false)
        let releaseAlternateURL = rootURL.appendingPathComponent("release-alternate", isDirectory: false)
        let ghLogURL = rootURL.appendingPathComponent("gh.log", isDirectory: false)
        try FileManager.default.createDirectory(at: repoURL.appendingPathComponent(".git", isDirectory: true), withIntermediateDirectories: true)
        for index in 0..<11 {
            let siblingURL = rootURL.appendingPathComponent("sibling-\(index)", isDirectory: true)
            try FileManager.default.createDirectory(at: siblingURL.appendingPathComponent(".git", isDirectory: true), withIntermediateDirectories: true)
        }
        try FileManager.default.createDirectory(at: fakeBinURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        try """
        #!/bin/sh
        cwd=""
        if [ "${1:-}" = "-C" ]; then
          cwd="$2"
          shift 2
        fi
        repo_root="${cwd:-$CMUX_FAKE_GIT_REPO_ROOT}"
        if [ "${1:-}" = "rev-parse" ] && [ "${2:-}" = "--show-toplevel" ]; then
          printf '%s\\n' "$repo_root"
          exit 0
        fi
        if [ "${1:-}" = "rev-parse" ] && [ "${2:-}" = "--abbrev-ref" ]; then
          printf 'feature/dvfast\\n'
          exit 0
        fi
        if [ "${1:-}" = "rev-parse" ] && [ "${2:-}" = "--verify" ]; then
          exit 0
        fi
        if [ "${1:-}" = "symbolic-ref" ]; then
          printf 'origin/main\\n'
          exit 0
        fi
        if [ "${1:-}" = "config" ]; then
          exit 1
        fi
        if [ "${1:-}" = "merge-base" ]; then
          printf 'mergebase\\n'
          exit 0
        fi
        if [ "${1:-}" = "diff" ]; then
          for arg in "$@"; do
            if [ "$arg" = "--cached" ]; then
              : > "$CMUX_FAKE_GIT_ALTERNATE_STARTED"
              while [ ! -f "$CMUX_FAKE_GIT_RELEASE_ALTERNATE" ]; do
                sleep 0.05
              done
              cat <<'PATCH'
        diff --git a/staged.txt b/staged.txt
        index 1111111..2222222 100644
        --- a/staged.txt
        +++ b/staged.txt
        @@ -1 +1 @@
        -old staged
        +new staged
        PATCH
              exit 0
            fi
          done
          : > "$CMUX_FAKE_GIT_STARTED"
          while [ ! -f "$CMUX_FAKE_GIT_RELEASE" ]; do
            sleep 0.05
          done
          cat <<'PATCH'
        diff --git a/worktree.txt b/worktree.txt
        index 1111111..2222222 100644
        --- a/worktree.txt
        +++ b/worktree.txt
        @@ -1 +1 @@
        -old line
        +new line
        PATCH
          exit 0
        fi
        if [ "${1:-}" = "for-each-ref" ]; then
          exit 0
        fi
        if [ "${1:-}" = "rev-list" ]; then
          printf '0\\t1\\n'
          exit 0
        fi
        exit 1
        """.write(to: fakeGitURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeGitURL.path)

        try """
        #!/bin/sh
        printf '%s\\n' "$*" >> "$CMUX_FAKE_GH_LOG"
        printf 'main\\n'
        exit 0
        """.write(to: fakeGHURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeGHURL.path)

        let socketPath = makeSocketPath("diff-siblings")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let openedURLBox = AsyncValueBox<String?>(nil)
        let openedHTMLURLBox = AsyncValueBox<URL?>(nil)
        let openHandled = expectation(description: "browser opened before sibling repo diffs")
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
            if let htmlURL = Self.diffViewerHTMLFileURLFromHTTPManifest(for: rawURL) {
                openedHTMLURLBox.set(htmlURL)
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
        environment["CMUX_FAKE_GH_LOG"] = ghLogURL.path
        process.executableURL = URL(fileURLWithPath: cliPath)
        process.arguments = ["diff", "--unstaged", "--cwd", repoURL.path, "--title", "Fast first paint", "--no-focus"]
        process.environment = environment
        process.currentDirectoryURL = repoURL
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        try process.run()
        defer { terminateProcess(process) }

        wait(for: [openHandled], timeout: 5)
        let openedURL = try XCTUnwrap(openedURLBox.get())
        XCTAssertFalse(FileManager.default.fileExists(atPath: ghLogURL.path))
        XCTAssertTrue(waitUntil(timeout: 5) {
            FileManager.default.fileExists(atPath: diffStartedURL.path)
        })
        try assertDiffViewerManifestReferencesExistingFiles(for: openedURL)
        FileManager.default.createFile(atPath: releaseDiffURL.path, contents: Data())

        let openingHTMLURL = try XCTUnwrap(openedHTMLURLBox.get())
        var selectedPageURL: String?
        XCTAssertTrue(waitUntil(timeout: 5) {
            let html = (try? String(contentsOf: openingHTMLURL, encoding: .utf8)) ?? ""
            selectedPageURL = Self.diffViewerRedirectURL(from: html)
            return selectedPageURL != nil && !FileManager.default.fileExists(atPath: alternateStartedURL.path)
        })
        try assertDiffViewerManifestReferencesExistingFiles(for: openedURL)
        let selectedResponse = try fetchDiffViewerHTTP(urlString: try XCTUnwrap(selectedPageURL))
        XCTAssertEqual(selectedResponse.statusCode, 200, selectedResponse.body)
        XCTAssertTrue(selectedResponse.body.contains("<div id=\"root\"></div>"), selectedResponse.body)
        let ghLogAtFirstPaint = (try? String(contentsOf: ghLogURL, encoding: .utf8)) ?? ""
        XCTAssertEqual(ghLogAtFirstPaint, "")
        XCTAssertTrue(FileManager.default.fileExists(atPath: diffStartedURL.path))

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
        // Deferred smart branch-base resolution must still RUN after first
        // paint; an empty gh log here would mean the branch page silently
        // skipped resolution rather than deferring it.
        let ghLogAfterExit = (try? String(contentsOf: ghLogURL, encoding: .utf8)) ?? ""
        XCTAssertFalse(
            ghLogAfterExit.isEmpty,
            "expected the deferred branch page completion to invoke gh after first paint"
        )
    }

    private func assertDiffViewerManifestReferencesExistingFiles(
        for rawURL: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let files = try diffViewerManifestFiles(for: rawURL)
        XCTAssertFalse(files.isEmpty, file: file, line: line)
        for entry in files {
            guard let filePath = entry["file_path"] as? String, !filePath.isEmpty else {
                continue
            }
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: filePath),
                "manifest references missing file: \(filePath)",
                file: file,
                line: line
            )
        }
    }

    private func diffViewerManifestFiles(for rawURL: String) throws -> [[String: Any]] {
        let viewerURL = try XCTUnwrap(URL(string: rawURL))
        let requestPath = URLComponents(url: viewerURL, resolvingAgainstBaseURL: false)?.percentEncodedPath ?? viewerURL.path
        let pathParts = requestPath.split(separator: "/", omittingEmptySubsequences: true)
        let token = try XCTUnwrap(pathParts.first.map(String.init))
        let manifestURL = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("cmux-diff-viewer-\(Darwin.getuid())", isDirectory: true)
            .appendingPathComponent(".manifest-\(token).json", isDirectory: false)
        let manifest = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any]
        )
        return try XCTUnwrap(manifest["files"] as? [[String: Any]])
    }

    private static func diffViewerRedirectURL(from html: String) -> String? {
        let marker = "data-cmux-diff-redirect=\""
        guard let start = html.range(of: marker)?.upperBound else { return nil }
        let tail = html[start...]
        guard let end = tail.firstIndex(of: "\"") else { return nil }
        return String(tail[..<end])
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
    }

    private func fetchDiffViewerHTTP(urlString: String) throws -> (statusCode: Int, body: String) {
        let url = try XCTUnwrap(URL(string: urlString))
        let finished = DispatchSemaphore(value: 0)
        let resultBox = AsyncValueBox<Result<(Int, String), Error>?>(nil)
        URLSession.shared.dataTask(with: url) { data, response, error in
            defer { finished.signal() }
            if let error {
                resultBox.set(.failure(error))
                return
            }
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            let body = String(data: data ?? Data(), encoding: .utf8) ?? ""
            resultBox.set(.success((statusCode, body)))
        }.resume()
        XCTAssertEqual(finished.wait(timeout: .now() + 5), .success)
        return try XCTUnwrap(resultBox.get()).get()
    }
}
