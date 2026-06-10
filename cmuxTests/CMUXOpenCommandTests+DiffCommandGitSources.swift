import Darwin
import Foundation
import XCTest


// MARK: - Diff command git sources and empty states
extension CMUXOpenCommandTests {
    func testDiffCommandFallsBackToNonEmptyGitSourceForSelector() throws {
        let cliPath = try bundledCLIPath()
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let repoURL = rootURL.appendingPathComponent("repo", isDirectory: true)
        let fileURL = repoURL.appendingPathComponent("story.txt")
        try FileManager.default.createDirectory(at: repoURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        try runGit(["init"], in: repoURL)
        try runGit(["checkout", "-b", "main"], in: repoURL)
        try runGit(["config", "user.name", "cmux tests"], in: repoURL)
        try runGit(["config", "user.email", "cmux@example.invalid"], in: repoURL)
        try "one\n".write(to: fileURL, atomically: true, encoding: .utf8)
        try runGit(["add", "story.txt"], in: repoURL)
        try runGit(["commit", "-m", "initial"], in: repoURL)
        try "one\ntwo\n".write(to: fileURL, atomically: true, encoding: .utf8)
        try runGit(["add", "story.txt"], in: repoURL)

        let plainSiblingURL = rootURL.appendingPathComponent("plain-sibling", isDirectory: true)
        let binURL = rootURL.appendingPathComponent("bin", isDirectory: true)
        let gitWrapperURL = binURL.appendingPathComponent("git", isDirectory: false)
        let gitLogURL = rootURL.appendingPathComponent("git-log.txt", isDirectory: false)
        try FileManager.default.createDirectory(at: plainSiblingURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: binURL, withIntermediateDirectories: true)
        try """
        #!/bin/sh
        printf '%s\\n' "$*" >> "\(gitLogURL.path)"
        case "$*" in
          *"\(plainSiblingURL.path)"*) echo "unexpected plain sibling probe" >&2; exit 99 ;;
        esac
        exec /usr/bin/git "$@"
        """.write(to: gitWrapperURL, atomically: true, encoding: .utf8)
        chmod(gitWrapperURL.path, 0o755)

        let stagedFallback = try runDiffCLIAndReadHTML(
            cliPath: cliPath,
            arguments: ["diff", "--unstaged"],
            environmentOverrides: [
                "PATH": "\(binURL.path):/usr/bin:/bin:/usr/sbin:/sbin"
            ],
            currentDirectoryURL: repoURL
        )

        XCTAssertTrue(stagedFallback.html.contains("Staged changes"), stagedFallback.html)
        XCTAssertTrue(stagedFallback.html.contains("\"sourceLabel\":\"git staged\""), stagedFallback.html)
        XCTAssertTrue(stagedFallback.patch.contains("+two"), stagedFallback.patch)
        let payload = try diffViewerPayload(from: stagedFallback.html)
        let sourceOptions = try XCTUnwrap(payload["sourceOptions"] as? [[String: Any]])
        let stagedOption = try XCTUnwrap(sourceOptions.first { $0["value"] as? String == "staged" })
        let unstagedOption = try XCTUnwrap(sourceOptions.first { $0["value"] as? String == "unstaged" })
        XCTAssertEqual(stagedOption["selected"] as? Bool, true)
        XCTAssertEqual(unstagedOption["selected"] as? Bool, false)
        let unstagedURLString = try diffViewerOptionURL(value: "unstaged", in: sourceOptions)
        let unstagedFileURL = try diffViewerHTMLFileURL(for: unstagedURLString, from: stagedFallback.params)
        let unstagedHTML = try String(contentsOf: unstagedFileURL, encoding: .utf8)
        XCTAssertTrue(unstagedHTML.contains("No unstaged changes to diff."), unstagedHTML)
        XCTAssertFalse(unstagedHTML.contains("+two"), unstagedHTML)
        let gitLog = try String(contentsOf: gitLogURL, encoding: .utf8)
        XCTAssertFalse(gitLog.contains(plainSiblingURL.path), gitLog)
    }

    func testDiffCommandShowsFriendlyEmptyStateWhenEveryGitSourceIsEmpty() throws {
        let cliPath = try bundledCLIPath()
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let repoURL = rootURL.appendingPathComponent("repo", isDirectory: true)
        let fileURL = repoURL.appendingPathComponent("story.txt")
        try FileManager.default.createDirectory(at: repoURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        try runGit(["init"], in: repoURL)
        try runGit(["checkout", "-b", "main"], in: repoURL)
        try runGit(["config", "user.name", "cmux tests"], in: repoURL)
        try runGit(["config", "user.email", "cmux@example.invalid"], in: repoURL)
        try "one\n".write(to: fileURL, atomically: true, encoding: .utf8)
        try runGit(["add", "story.txt"], in: repoURL)
        try runGit(["commit", "-m", "initial"], in: repoURL)

        let socketPath = makeSocketPath("diff-empty")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
        }

        let serverHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
            guard let payload = Self.v2Payload(from: line),
                  let id = payload["id"] as? String,
                  let method = payload["method"] as? String,
                  method == "browser.open_split",
                  let params = payload["params"] as? [String: Any],
                  let rawURL = params["url"] as? String else {
                return Self.v2Response(id: "unknown", ok: false, error: ["code": "unexpected"])
            }
            return Self.v2Response(
                id: id,
                ok: true,
                result: ["surface_id": "surface-id", "pane_id": "pane-id", "url": rawURL]
            )
        }

        let result = runCLI(
            cliPath: cliPath,
            socketPath: socketPath,
            arguments: ["diff", "--unstaged"],
            currentDirectoryURL: repoURL
        )

        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stderr)
        // Empty diffs are a friendly state, not an error: the CLI exits 0 (so the
        // launcher never emits the "unable to click" beep) and prints nothing to
        // stderr. (issue #5246)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertFalse(result.stderr.contains("No unstaged changes to diff."), result.stderr)
        XCTAssertFalse(result.stderr.contains("EmptyDiffSourceError"), result.stderr)

        let commandPayload = try XCTUnwrap(
            state.commands.compactMap { Self.v2Payload(from: $0) }.first { payload in
                payload["method"] as? String == "browser.open_split"
            }
        )
        let params = try XCTUnwrap(commandPayload["params"] as? [String: Any])
        let rawURL = try XCTUnwrap(params["url"] as? String)
        let openedFileURL = try diffViewerHTMLFileURL(for: rawURL, from: params)
        let viewerFileURL = try resolvedDiffViewerHTMLFileURL(openedFileURL, from: params)
        let html = try String(contentsOf: viewerFileURL, encoding: .utf8)
        XCTAssertTrue(html.contains("No unstaged changes to diff."), html)
        XCTAssertFalse(html.contains("No last-turn diff baseline recorded"), html)
        let payload = try diffViewerPayload(from: html)
        XCTAssertEqual(payload["statusIsError"] as? Bool, false, html)
    }

    func testDiffCommandShowsFriendlyEmptyStateForLastTurnWithoutBaseline() throws {
        // Regression: a last-turn diff with no recorded baseline must render the
        // friendly empty diff state (with the source switcher) and exit 0, not
        // surface the raw "No last-turn diff baseline recorded" CLI error. The
        // non-zero exit is what triggered the launcher's "unable to click" beep,
        // so a clean exit fixes both the bad copy and the beep (issue #5246).
        let cliPath = try bundledCLIPath()
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let repoURL = rootURL.appendingPathComponent("repo", isDirectory: true)
        let fileURL = repoURL.appendingPathComponent("story.txt")
        try FileManager.default.createDirectory(at: repoURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        try runGit(["init"], in: repoURL)
        try runGit(["checkout", "-b", "main"], in: repoURL)
        try runGit(["config", "user.name", "cmux tests"], in: repoURL)
        try runGit(["config", "user.email", "cmux@example.invalid"], in: repoURL)
        try "one\n".write(to: fileURL, atomically: true, encoding: .utf8)
        try runGit(["add", "story.txt"], in: repoURL)
        try runGit(["commit", "-m", "initial"], in: repoURL)
        // Staged changes exist on another source; last turn must NOT silently fall
        // back to them — it stays on its own empty state.
        try "one\ntwo\n".write(to: fileURL, atomically: true, encoding: .utf8)
        try runGit(["add", "story.txt"], in: repoURL)

        let result = try runDiffCLIAndReadHTML(
            cliPath: cliPath,
            arguments: ["diff", "--last-turn"],
            environmentOverrides: [
                "CMUX_AGENT_HOOK_STATE_DIR": rootURL.appendingPathComponent("hook-state", isDirectory: true).path,
                "CMUX_WORKSPACE_ID": UUID().uuidString.lowercased(),
                "CMUX_SURFACE_ID": UUID().uuidString.lowercased()
            ],
            currentDirectoryURL: repoURL,
            readPatchSidecar: false
        )

        try assertFriendlyLastTurnEmptyState(html: result.html)
        // No silent fallback to the staged "+two" change.
        XCTAssertFalse(result.html.contains("+two"), result.html)
    }

    func testDiffCommandShowsFriendlyEmptyStateForEmptyLastTurnDiff() throws {
        let cliPath = try bundledCLIPath()
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let repoURL = rootURL.appendingPathComponent("repo", isDirectory: true)
        let stateURL = rootURL.appendingPathComponent("hook-state", isDirectory: true)
        let fileURL = repoURL.appendingPathComponent("story.txt")
        try FileManager.default.createDirectory(at: repoURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: stateURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        try runGit(["init"], in: repoURL)
        try runGit(["checkout", "-b", "main"], in: repoURL)
        try runGit(["config", "user.name", "cmux tests"], in: repoURL)
        try runGit(["config", "user.email", "cmux@example.invalid"], in: repoURL)
        try runGit(["remote", "add", "origin", rootURL.appendingPathComponent("origin.git").path], in: repoURL)
        try "one\n".write(to: fileURL, atomically: true, encoding: .utf8)
        try runGit(["add", "story.txt"], in: repoURL)
        try runGit(["commit", "-m", "initial"], in: repoURL)
        let initialCommit = try runGitStdout(["rev-parse", "HEAD"], in: repoURL)
        try runGit(["update-ref", "refs/remotes/origin/main", initialCommit], in: repoURL)
        try runGit(["symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/main"], in: repoURL)
        try runGit(["checkout", "-b", "feature/diff-source"], in: repoURL)
        try "one\ntwo\n".write(to: fileURL, atomically: true, encoding: .utf8)
        try runGit(["add", "story.txt"], in: repoURL)
        try runGit(["commit", "-m", "feature change"], in: repoURL)
        let featureCommit = try runGitStdout(["rev-parse", "HEAD"], in: repoURL)
        let workspaceId = UUID().uuidString.lowercased()
        let surfaceId = UUID().uuidString.lowercased()
        try writeDiffBaselineStore(
            stateDirectoryURL: stateURL,
            repoURL: repoURL,
            workspaceId: workspaceId,
            surfaceId: surfaceId,
            baseCommit: featureCommit
        )

        let result = try runDiffCLIAndReadHTML(
            cliPath: cliPath,
            arguments: ["diff", "--last-turn"],
            environmentOverrides: [
                "CMUX_AGENT_HOOK_STATE_DIR": stateURL.path,
                "CMUX_WORKSPACE_ID": workspaceId,
                "CMUX_SURFACE_ID": surfaceId
            ],
            currentDirectoryURL: repoURL,
            readPatchSidecar: false
        )

        try assertFriendlyLastTurnEmptyState(html: result.html)
    }

    func testDiffCommandSupportsGitSourcesAndSurfaceScopedLastTurn() throws {
        let cliPath = try bundledCLIPath()
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let repoURL = rootURL.appendingPathComponent("repo", isDirectory: true)
        let stateURL = rootURL.appendingPathComponent("hook-state", isDirectory: true)
        let fileURL = repoURL.appendingPathComponent("story.txt")
        try FileManager.default.createDirectory(at: repoURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: stateURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }
        func assertNoANSIEscape(_ html: String, file: StaticString = #filePath, line: UInt = #line) {
            XCTAssertFalse(html.contains("\u{1B}"), html, file: file, line: line)
            XCTAssertFalse(html.contains("\\u001B"), html, file: file, line: line)
            XCTAssertFalse(html.contains("\\u001b"), html, file: file, line: line)
        }

        try runGit(["init"], in: repoURL)
        try runGit(["checkout", "-b", "main"], in: repoURL)
        try runGit(["config", "user.name", "cmux tests"], in: repoURL)
        try runGit(["config", "user.email", "cmux@example.invalid"], in: repoURL)
        try runGit(["config", "color.ui", "always"], in: repoURL)
        try runGit(["config", "color.diff", "always"], in: repoURL)
        try runGit(["remote", "add", "origin", rootURL.appendingPathComponent("origin.git").path], in: repoURL)
        try "one\n".write(to: fileURL, atomically: true, encoding: .utf8)
        try runGit(["add", "story.txt"], in: repoURL)
        try runGit(["commit", "-m", "initial"], in: repoURL)
        let initialCommit = try runGitStdout(["rev-parse", "HEAD"], in: repoURL)
        try runGit(["update-ref", "refs/remotes/origin/main", initialCommit], in: repoURL)
        try runGit(["symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/main"], in: repoURL)

        let siblingRepoURL = rootURL.appendingPathComponent("other-repo", isDirectory: true)
        let siblingFileURL = siblingRepoURL.appendingPathComponent("other.txt")
        try FileManager.default.createDirectory(at: siblingRepoURL, withIntermediateDirectories: true)
        try runGit(["init"], in: siblingRepoURL)
        try runGit(["checkout", "-b", "main"], in: siblingRepoURL)
        try runGit(["config", "user.name", "cmux tests"], in: siblingRepoURL)
        try runGit(["config", "user.email", "cmux@example.invalid"], in: siblingRepoURL)
        try "base\n".write(to: siblingFileURL, atomically: true, encoding: .utf8)
        try runGit(["add", "other.txt"], in: siblingRepoURL)
        try runGit(["commit", "-m", "initial"], in: siblingRepoURL)
        let siblingInitialCommit = try runGitStdout(["rev-parse", "HEAD"], in: siblingRepoURL)
        try runGit(["update-ref", "refs/remotes/origin/main", siblingInitialCommit], in: siblingRepoURL)
        try runGit(["symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/main"], in: siblingRepoURL)
        try runGit(["checkout", "-b", "feature/other"], in: siblingRepoURL)
        try "base\nchanged\n".write(to: siblingFileURL, atomically: true, encoding: .utf8)

        try runGit(["checkout", "-b", "feature/diff-source"], in: repoURL)
        try "one\ntwo\n".write(to: fileURL, atomically: true, encoding: .utf8)
        try runGit(["add", "story.txt"], in: repoURL)
        try runGit(["commit", "-m", "add two"], in: repoURL)
        let featureCommit = try runGitStdout(["rev-parse", "HEAD"], in: repoURL)
        try runGit(["update-ref", "refs/remotes/origin/feature/diff-source", featureCommit], in: repoURL)
        try runGit(["branch", "--set-upstream-to=origin/feature/diff-source"], in: repoURL)
        try "one\ntwo\nthree\n".write(to: fileURL, atomically: true, encoding: .utf8)

        let branch = try runDiffCLIAndReadHTML(
            cliPath: cliPath,
            arguments: ["diff", "--branch", "--title", "Branch source"],
            currentDirectoryURL: repoURL
        )
        XCTAssertTrue(branch.html.contains("Branch source"), branch.html)
        XCTAssertTrue(branch.patch.contains("+two"), branch.patch)
        XCTAssertTrue(branch.patch.contains("+three"), branch.patch)
        XCTAssertTrue(branch.html.contains("\"sourceLabel\":\"git branch origin/main\""), branch.html)
        XCTAssertTrue(branch.html.contains("\"sourceOptions\""), branch.html)
        XCTAssertTrue(branch.html.contains("\"repoOptions\""), branch.html)
        XCTAssertTrue(branch.html.contains("\"baseOptions\""), branch.html)
        XCTAssertTrue(branch.html.contains("\"repoRoot\":\"\(repoURL.path)\""), branch.html)
        XCTAssertTrue(branch.html.contains("\"branchBaseRef\":\"origin/main\""), branch.html)
        XCTAssertTrue(branch.html.contains("other-repo"), branch.html)
        XCTAssertTrue(branch.html.contains("\"label\":\"Unstaged\""), branch.html)
        XCTAssertTrue(branch.html.contains("\"label\":\"Staged\""), branch.html)
        XCTAssertTrue(branch.html.contains("\"label\":\"Branch\""), branch.html)
        XCTAssertTrue(branch.html.contains("\"label\":\"Last turn\""), branch.html)
        assertNoANSIEscape(branch.html)

        let branchPayload = try diffViewerPayload(from: branch.html)
        let branchSourceOptions = try XCTUnwrap(branchPayload["sourceOptions"] as? [[String: Any]])
        let selectedRepoUnstagedURLString = try diffViewerOptionURL(value: "unstaged", in: branchSourceOptions)
        let selectedRepoUnstagedFileURL = try diffViewerHTMLFileURL(
            for: selectedRepoUnstagedURLString,
            from: branch.params
        )
        let selectedRepoUnstagedHTML = try String(contentsOf: selectedRepoUnstagedFileURL, encoding: .utf8)
        let selectedRepoUnstagedPayload = try diffViewerPayload(from: selectedRepoUnstagedHTML)
        let unstagedRepoOptions = try XCTUnwrap(selectedRepoUnstagedPayload["repoOptions"] as? [[String: Any]])
        let siblingRepoUnstagedURLString = try diffViewerOptionURL(value: siblingRepoURL.path, in: unstagedRepoOptions)
        XCTAssertTrue(siblingRepoUnstagedURLString.contains("-unstaged.html"), siblingRepoUnstagedURLString)
        let siblingRepoUnstagedFileURL = try diffViewerHTMLFileURL(
            for: siblingRepoUnstagedURLString,
            from: branch.params
        )
        let siblingRepoUnstagedHTML = try String(contentsOf: siblingRepoUnstagedFileURL, encoding: .utf8)
        let siblingRepoUnstagedPatch = try String(
            contentsOf: siblingRepoUnstagedFileURL.deletingPathExtension().appendingPathExtension("patch"),
            encoding: .utf8
        )
        XCTAssertTrue(siblingRepoUnstagedHTML.contains("\"sourceLabel\":\"git unstaged\""), siblingRepoUnstagedHTML)
        XCTAssertTrue(siblingRepoUnstagedHTML.contains("\"repoRoot\":\"\(siblingRepoURL.path)\""), siblingRepoUnstagedHTML)
        XCTAssertTrue(siblingRepoUnstagedPatch.contains("+changed"), siblingRepoUnstagedPatch)
        XCTAssertFalse(siblingRepoUnstagedHTML.contains("\"sourceLabel\":\"git branch"), siblingRepoUnstagedHTML)

        let branchWithBase = try runDiffCLIAndReadHTML(
            cliPath: cliPath,
            arguments: ["diff", "--branch", "--base", "main"],
            currentDirectoryURL: repoURL
        )
        XCTAssertTrue(branchWithBase.html.contains("\"sourceLabel\":\"git branch main\""), branchWithBase.html)
        XCTAssertTrue(branchWithBase.html.contains("\"branchBaseRef\":\"main\""), branchWithBase.html)
        XCTAssertTrue(branchWithBase.patch.contains("+two"), branchWithBase.patch)
        let branchWithBasePayload = try diffViewerPayload(from: branchWithBase.html)
        let branchWithBaseRepoOptions = try XCTUnwrap(branchWithBasePayload["repoOptions"] as? [[String: Any]])
        let siblingRepoBranchURLString = try diffViewerOptionURL(value: siblingRepoURL.path, in: branchWithBaseRepoOptions)
        let siblingRepoBranchFileURL = try diffViewerHTMLFileURL(
            for: siblingRepoBranchURLString,
            from: branchWithBase.params
        )
        let siblingRepoBranchHTML = try String(contentsOf: siblingRepoBranchFileURL, encoding: .utf8)
        let siblingRepoBranchPatch = try String(
            contentsOf: siblingRepoBranchFileURL.deletingPathExtension().appendingPathExtension("patch"),
            encoding: .utf8
        )
        XCTAssertTrue(siblingRepoBranchHTML.contains("\"sourceLabel\":\"git branch main\""), siblingRepoBranchHTML)
        XCTAssertTrue(siblingRepoBranchHTML.contains("\"branchBaseRef\":\"main\""), siblingRepoBranchHTML)
        XCTAssertTrue(siblingRepoBranchHTML.contains("\"repoRoot\":\"\(siblingRepoURL.path)\""), siblingRepoBranchHTML)
        XCTAssertTrue(siblingRepoBranchPatch.contains("+changed"), siblingRepoBranchPatch)

        let repoOverride = try runDiffCLIAndReadHTML(
            cliPath: cliPath,
            arguments: ["diff", "--unstaged", "--repo", repoURL.path],
            currentDirectoryURL: rootURL
        )
        XCTAssertTrue(repoOverride.html.contains("\"sourceLabel\":\"git unstaged\""), repoOverride.html)
        XCTAssertTrue(repoOverride.html.contains("\"repoRoot\":\"\(repoURL.path)\""), repoOverride.html)
        XCTAssertTrue(repoOverride.patch.contains("+three"), repoOverride.patch)

        let unstaged = try runDiffCLIAndReadHTML(
            cliPath: cliPath,
            arguments: ["diff", "--unstaged"],
            currentDirectoryURL: repoURL
        )
        XCTAssertTrue(unstaged.html.contains("Unstaged changes"), unstaged.html)
        XCTAssertTrue(unstaged.patch.contains("+three"), unstaged.patch)
        XCTAssertTrue(unstaged.html.contains("\"sourceLabel\":\"git unstaged\""), unstaged.html)
        assertNoANSIEscape(unstaged.patch)

        try runGit(["add", "story.txt"], in: repoURL)
        let staged = try runDiffCLIAndReadHTML(
            cliPath: cliPath,
            arguments: ["diff", "--source", "staged"],
            currentDirectoryURL: repoURL
        )
        XCTAssertTrue(staged.html.contains("Staged changes"), staged.html)
        XCTAssertTrue(staged.patch.contains("+three"), staged.patch)
        XCTAssertTrue(staged.html.contains("\"sourceLabel\":\"git staged\""), staged.html)
        assertNoANSIEscape(staged.patch)

        let workspaceId = UUID().uuidString.lowercased()
        let surfaceId = UUID().uuidString.lowercased()
        try "before\n".write(to: repoURL.appendingPathComponent("preexisting.txt"), atomically: true, encoding: .utf8)
        try "same\n".write(to: repoURL.appendingPathComponent("unchanged-untracked.txt"), atomically: true, encoding: .utf8)
        try "remove me\n".write(to: repoURL.appendingPathComponent("deleted-untracked.txt"), atomically: true, encoding: .utf8)
        let quotedUntrackedPath = "quoted\tuntracked.txt"
        try "quoted before\n".write(to: repoURL.appendingPathComponent(quotedUntrackedPath), atomically: true, encoding: .utf8)
        try "tracked later\n".write(to: repoURL.appendingPathComponent("tracked-later.txt"), atomically: true, encoding: .utf8)
        try Data([0xff, 0x00, 0x6f, 0x6c, 0x64])
            .write(to: repoURL.appendingPathComponent("binary.dat"), options: .atomic)
        try writeDiffBaselineStore(
            stateDirectoryURL: stateURL,
            repoURL: repoURL,
            workspaceId: workspaceId.uppercased(),
            surfaceId: surfaceId.uppercased(),
            baseCommit: initialCommit,
            untrackedPaths: [
                "preexisting.txt",
                "unchanged-untracked.txt",
                "deleted-untracked.txt",
                quotedUntrackedPath,
                "tracked-later.txt",
                "binary.dat"
            ]
        )
        try "after\n".write(to: repoURL.appendingPathComponent("preexisting.txt"), atomically: true, encoding: .utf8)
        try "quoted after\n".write(to: repoURL.appendingPathComponent(quotedUntrackedPath), atomically: true, encoding: .utf8)
        try Data([0xff, 0x00, 0x6e, 0x65, 0x77])
            .write(to: repoURL.appendingPathComponent("binary.dat"), options: .atomic)
        try runGit(["add", "tracked-later.txt"], in: repoURL)
        try "created\n".write(to: repoURL.appendingPathComponent("new-turn-file.txt"), atomically: true, encoding: .utf8)
        try FileManager.default.removeItem(at: repoURL.appendingPathComponent("deleted-untracked.txt"))
        let lastTurn = try runDiffCLIAndReadHTML(
            cliPath: cliPath,
            arguments: ["diff", "--last-turn"],
            environmentOverrides: [
                "CMUX_AGENT_HOOK_STATE_DIR": stateURL.path,
                "CMUX_WORKSPACE_ID": workspaceId,
                "CMUX_SURFACE_ID": surfaceId
            ],
            currentDirectoryURL: repoURL
        )
        XCTAssertEqual(lastTurn.params["workspace_id"] as? String, workspaceId)
        XCTAssertEqual(lastTurn.params["surface_id"] as? String, surfaceId)
        XCTAssertEqual(lastTurn.params["show_omnibar"] as? Bool, false)
        XCTAssertTrue(lastTurn.html.contains("Last turn diff"), lastTurn.html)
        XCTAssertTrue(lastTurn.patch.contains("+two"), lastTurn.patch)
        XCTAssertTrue(lastTurn.patch.contains("+three"), lastTurn.patch)
        XCTAssertTrue(lastTurn.patch.contains("new-turn-file.txt"), lastTurn.patch)
        XCTAssertTrue(lastTurn.patch.contains("+created"), lastTurn.patch)
        XCTAssertTrue(lastTurn.patch.contains("preexisting.txt"), lastTurn.patch)
        XCTAssertTrue(lastTurn.patch.contains("-before"), lastTurn.patch)
        XCTAssertTrue(lastTurn.patch.contains("+after"), lastTurn.patch)
        XCTAssertTrue(lastTurn.patch.contains("\"a/quoted\\tuntracked.txt\""), lastTurn.patch)
        XCTAssertTrue(lastTurn.patch.contains("\"b/quoted\\tuntracked.txt\""), lastTurn.patch)
        XCTAssertFalse(lastTurn.patch.contains("baseline/quoted"), lastTurn.patch)
        XCTAssertFalse(lastTurn.patch.contains("current/quoted"), lastTurn.patch)
        XCTAssertTrue(lastTurn.patch.contains("-quoted before"), lastTurn.patch)
        XCTAssertTrue(lastTurn.patch.contains("+quoted after"), lastTurn.patch)
        XCTAssertTrue(lastTurn.patch.contains("binary.dat"), lastTurn.patch)
        XCTAssertTrue(lastTurn.patch.contains("GIT binary patch"), lastTurn.patch)
        XCTAssertTrue(lastTurn.patch.contains("tracked-later.txt"), lastTurn.patch)
        XCTAssertTrue(lastTurn.patch.contains("+tracked later"), lastTurn.patch)
        XCTAssertFalse(lastTurn.patch.contains("-tracked later"), lastTurn.patch)
        XCTAssertTrue(lastTurn.patch.contains("deleted-untracked.txt"), lastTurn.patch)
        XCTAssertTrue(lastTurn.patch.contains("-remove me"), lastTurn.patch)
        XCTAssertFalse(lastTurn.patch.contains("unchanged-untracked.txt"), lastTurn.patch)
        assertNoANSIEscape(lastTurn.patch)

        let refLastTurn = try runDiffCLIAndReadHTML(
            cliPath: cliPath,
            arguments: ["diff", "--last-turn", "--workspace", "workspace:1", "--surface", "surface:1"],
            environmentOverrides: [
                "CMUX_AGENT_HOOK_STATE_DIR": stateURL.path
            ],
            currentDirectoryURL: repoURL
        ) { line in
            guard let payload = Self.v2Payload(from: line),
                  let id = payload["id"] as? String,
                  let method = payload["method"] as? String else {
                return nil
            }
            switch method {
            case "workspace.list":
                return Self.v2Response(
                    id: id,
                    ok: true,
                    result: [
                        "workspaces": [
                            [
                                "id": workspaceId,
                                "ref": "workspace:1",
                                "index": 1
                            ] as [String: Any]
                        ]
                    ]
                )
            case "surface.list":
                let params = payload["params"] as? [String: Any] ?? [:]
                XCTAssertEqual(params["workspace_id"] as? String, workspaceId)
                return Self.v2Response(
                    id: id,
                    ok: true,
                    result: [
                        "surfaces": [
                            [
                                "id": surfaceId,
                                "ref": "surface:1",
                                "index": 1,
                                "focused": true
                            ] as [String: Any]
                        ]
                    ]
                )
            default:
                return nil
            }
        }
        XCTAssertEqual(refLastTurn.params["workspace_id"] as? String, workspaceId)
        XCTAssertEqual(refLastTurn.params["surface_id"] as? String, surfaceId)
        XCTAssertTrue(refLastTurn.html.contains("Last turn diff"), refLastTurn.html)

        let homeURL = rootURL.appendingPathComponent("custom-home", isDirectory: true)
        let homeStateURL = homeURL.appendingPathComponent(".cmuxterm", isDirectory: true)
        try FileManager.default.createDirectory(at: homeStateURL, withIntermediateDirectories: true)
        try writeDiffBaselineStore(
            stateDirectoryURL: homeStateURL,
            repoURL: repoURL,
            workspaceId: workspaceId,
            surfaceId: surfaceId,
            baseCommit: initialCommit,
            untrackedPaths: ["preexisting.txt"]
        )
        let homeLastTurn = try runDiffCLIAndReadHTML(
            cliPath: cliPath,
            arguments: ["diff", "--last-turn"],
            environmentOverrides: [
                "HOME": homeURL.path,
                "CMUX_WORKSPACE_ID": workspaceId,
                "CMUX_SURFACE_ID": surfaceId
            ],
            currentDirectoryURL: repoURL
        )
        XCTAssertTrue(homeLastTurn.html.contains("Last turn diff"), homeLastTurn.html)
        XCTAssertTrue(homeLastTurn.patch.contains("new-turn-file.txt"), homeLastTurn.patch)

        let wrongSurfaceResult = try runDiffCLIAndReadHTML(
            cliPath: cliPath,
            arguments: ["diff", "--last-turn"],
            environmentOverrides: [
                "CMUX_AGENT_HOOK_STATE_DIR": stateURL.path,
                "CMUX_WORKSPACE_ID": workspaceId,
                "CMUX_SURFACE_ID": UUID().uuidString.lowercased()
            ],
            currentDirectoryURL: repoURL,
            readPatchSidecar: false
        )
        try assertFriendlyLastTurnEmptyState(html: wrongSurfaceResult.html)
    }

    /// Asserts the diff viewer HTML renders the friendly, non-error last-turn empty
    /// state: plain-language copy (never the raw baseline CLI error), `statusIsError`
    /// false, and the source switcher still present with last turn selected.
    private func assertFriendlyLastTurnEmptyState(html: String) throws {
        XCTAssertFalse(html.contains("No last-turn diff baseline recorded"), html)
        let payload = try diffViewerPayload(from: html)
        XCTAssertEqual(payload["statusMessage"] as? String, "No last-turn changes to diff.", html)
        XCTAssertEqual(payload["statusIsError"] as? Bool, false, html)
        let sourceOptions = try XCTUnwrap(payload["sourceOptions"] as? [[String: Any]], html)
        let lastTurnOption = try XCTUnwrap(
            sourceOptions.first { $0["value"] as? String == "last-turn" },
            html
        )
        XCTAssertEqual(lastTurnOption["selected"] as? Bool, true, html)
    }

    private func writeDiffBaselineStore(
        stateDirectoryURL: URL,
        repoURL: URL,
        workspaceId: String,
        surfaceId: String,
        baseCommit: String,
        untrackedPaths: [String]? = nil
    ) throws {
        var record: [String: Any] = [
            "workspaceId": workspaceId,
            "surfaceId": surfaceId,
            "sessionId": "session-1",
            "turnId": "turn-1",
            "agent": "codex",
            "repoRoot": repoURL.standardizedFileURL.path,
            "baseCommit": baseCommit,
            "capturedAt": Date().timeIntervalSince1970
        ]
        if let untrackedPaths {
            record["untrackedPaths"] = untrackedPaths
            var untrackedPathHashes: [String: String] = [:]
            let snapshotId = UUID().uuidString
            let snapshotRoot = stateDirectoryURL
                .appendingPathComponent("agent-turn-diff-baseline-snapshots", isDirectory: true)
                .appendingPathComponent(snapshotId, isDirectory: true)
                .appendingPathComponent("files", isDirectory: true)
            for path in untrackedPaths {
                let hash = try runGitStdout(["hash-object", "--no-filters", "--", path], in: repoURL)
                let snapshotURL = snapshotRoot.appendingPathComponent(path, isDirectory: false)
                try FileManager.default.createDirectory(
                    at: snapshotURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try FileManager.default.copyItem(
                    at: repoURL.appendingPathComponent(path, isDirectory: false),
                    to: snapshotURL
                )
                untrackedPathHashes[path] = hash
            }
            record["untrackedPathHashes"] = untrackedPathHashes
            record["untrackedSnapshotId"] = snapshotId
        }
        let payload: [String: Any] = [
            "version": 1,
            "records": [record]
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        try data.write(to: stateDirectoryURL.appendingPathComponent("agent-turn-diff-baselines.json"), options: .atomic)
    }

}
