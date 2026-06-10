@preconcurrency import XCTest
import CmuxSettings
import CmuxSocketControl
import AppKit
import Combine
import CoreText
import WebKit
import Darwin
import SwiftUI
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif


// MARK: - Git/PR watch opt-outs
extension ZshShellIntegrationHandoffTests {
    func testBashNoGitWatchSkipsHeadTrackingAndPRClear() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-bash-no-git-watch-\(UUID().uuidString)")
        let repoA = root.appendingPathComponent("repo-a", isDirectory: true)
        let repoB = root.appendingPathComponent("repo-b", isDirectory: true)
        let logPath = root.appendingPathComponent("send.log", isDirectory: false)
        let socketPath = root.appendingPathComponent("cmux-test.sock", isDirectory: false)

        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        let socketFD = try bindUnixSocket(at: socketPath.path)
        defer {
            Darwin.close(socketFD)
            unlink(socketPath.path)
            try? fileManager.removeItem(at: root)
        }

        let result = try runInteractiveBash(
            cmuxLoadShellIntegration: true,
            command: """
            mkdir -p "\(repoA.path)/.git" "\(repoB.path)/.git"
            printf '%s\\n' 'ref: refs/heads/main' > "\(repoA.path)/.git/HEAD"
            printf '%s\\n' 'ref: refs/heads/feature' > "\(repoB.path)/.git/HEAD"
            : > "\(logPath.path)"
            _cmux_send() { printf '%s\\n' "$1" >> "\(logPath.path)"; }
            cd "\(repoA.path)"
            _CMUX_TTY_REPORTED=1
            _CMUX_PORTS_LAST_RUN=$(_cmux_now)
            _CMUX_PWD_LAST_PWD="$PWD"
            _CMUX_GIT_HEAD_LAST_PWD="$PWD"
            _CMUX_GIT_HEAD_PATH="$PWD/.git/HEAD"
            _CMUX_GIT_HEAD_SIGNATURE="$(_cmux_git_head_signature "$_CMUX_GIT_HEAD_PATH")"
            printf '%s\\n' 'ref: refs/heads/old-cleared' > "$_CMUX_GIT_HEAD_PATH"
            cd "\(repoB.path)"
            _CMUX_PWD_LAST_PWD="$PWD"
            _CMUX_LAST_PR_ACTION="checkout"
            _CMUX_LAST_PR_TARGET="feature"
            _cmux_prompt_command
            printf 'HEAD_PATH=%s\\n' "$_CMUX_GIT_HEAD_PATH"
            printf 'HEAD_LAST_PWD=%s\\n' "$_CMUX_GIT_HEAD_LAST_PWD"
            printf 'LAST_PR_ACTION=%s\\n' "$_CMUX_LAST_PR_ACTION"
            printf 'LOG<<EOF\\n'
            cat "\(logPath.path)"
            printf 'EOF\\n'
            """,
            extraEnvironment: [
                "CMUX_NO_GIT_WATCH": "1",
                "CMUX_SOCKET_PATH": socketPath.path,
                "CMUX_TAB_ID": "22222222-2222-2222-2222-222222222222",
                "CMUX_PANEL_ID": "22222222-2222-2222-2222-222222222222",
            ]
        )

        XCTAssertFalse(result.stdout.contains(repoA.appendingPathComponent(".git/HEAD").path), result.stdout)
        XCTAssertTrue(result.stdout.contains("HEAD_PATH=\n"), result.stdout)
        XCTAssertTrue(result.stdout.contains("HEAD_LAST_PWD=\n"), result.stdout)
        XCTAssertTrue(result.stdout.contains("LAST_PR_ACTION=\n"), result.stdout)
        XCTAssertFalse(result.stdout.contains("clear_pr"), result.stdout)
        XCTAssertFalse(result.stdout.contains("report_pr_action"), result.stdout)
    }

    func testZshNoGitWatchSkipsHeadTrackingAndPRClear() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-zsh-no-git-watch-\(UUID().uuidString)")
        let repoA = root.appendingPathComponent("repo-a", isDirectory: true)
        let repoB = root.appendingPathComponent("repo-b", isDirectory: true)
        let logPath = root.appendingPathComponent("send.log", isDirectory: false)
        let socketPath = root.appendingPathComponent("cmux-test.sock", isDirectory: false)

        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        let socketFD = try bindUnixSocket(at: socketPath.path)
        defer {
            Darwin.close(socketFD)
            unlink(socketPath.path)
            try? fileManager.removeItem(at: root)
        }

        let output = try runInteractiveZsh(
            cmuxLoadGhosttyIntegration: false,
            cmuxLoadShellIntegration: true,
            command: """
            mkdir -p "\(repoA.path)/.git" "\(repoB.path)/.git"
            printf '%s\\n' 'ref: refs/heads/main' > "\(repoA.path)/.git/HEAD"
            printf '%s\\n' 'ref: refs/heads/feature' > "\(repoB.path)/.git/HEAD"
            : > "\(logPath.path)"
            _cmux_send() { printf '%s\\n' "$1" >> "\(logPath.path)"; }
            cd "\(repoA.path)"
            _CMUX_TTY_REPORTED=1
            _CMUX_PORTS_LAST_RUN=$(_cmux_now)
            _CMUX_PWD_LAST_PWD="$PWD"
            _CMUX_GIT_HEAD_LAST_PWD="$PWD"
            _CMUX_GIT_HEAD_PATH="$PWD/.git/HEAD"
            _CMUX_GIT_HEAD_SIGNATURE="$(_cmux_git_head_signature "$_CMUX_GIT_HEAD_PATH")"
            printf '%s\\n' 'ref: refs/heads/old-cleared' > "$_CMUX_GIT_HEAD_PATH"
            cd "\(repoB.path)"
            _CMUX_PWD_LAST_PWD="$PWD"
            _CMUX_LAST_PR_ACTION="checkout"
            _CMUX_LAST_PR_TARGET="feature"
            _cmux_precmd
            printf 'HEAD_PATH=%s\\n' "$_CMUX_GIT_HEAD_PATH"
            printf 'HEAD_LAST_PWD=%s\\n' "$_CMUX_GIT_HEAD_LAST_PWD"
            printf 'LAST_PR_ACTION=%s\\n' "$_CMUX_LAST_PR_ACTION"
            printf 'LOG<<EOF\\n'
            cat "\(logPath.path)"
            printf 'EOF\\n'
            """,
            extraEnvironment: [
                "CMUX_NO_GIT_WATCH": "1",
                "CMUX_SOCKET_PATH": socketPath.path,
                "CMUX_TAB_ID": "22222222-2222-2222-2222-222222222222",
                "CMUX_PANEL_ID": "22222222-2222-2222-2222-222222222222",
            ]
        )

        XCTAssertFalse(output.contains(repoA.appendingPathComponent(".git/HEAD").path), output)
        XCTAssertTrue(output.contains("HEAD_PATH=\n"), output)
        XCTAssertTrue(output.contains("HEAD_LAST_PWD=\n"), output)
        XCTAssertTrue(output.contains("LAST_PR_ACTION=\n"), output)
        XCTAssertFalse(output.contains("clear_pr"), output)
        XCTAssertFalse(output.contains("report_pr_action"), output)
    }

    func testZshNoPullRequestWatchSkipsLegacyGhPRProbe() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-zsh-no-pr-watch-\(UUID().uuidString)")
        let repoURL = root.appendingPathComponent("repo", isDirectory: true)
        let fakeBinURL = root.appendingPathComponent("fake-bin", isDirectory: true)
        let markerURL = root.appendingPathComponent("gh-pr-invoked", isDirectory: false)
        let socketPath = root.appendingPathComponent("cmux-test.sock", isDirectory: false)

        try fileManager.createDirectory(at: repoURL.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: fakeBinURL, withIntermediateDirectories: true)
        try "ref: refs/heads/issue-2746-rate-limit\n".write(
            to: repoURL.appendingPathComponent(".git/HEAD"),
            atomically: true,
            encoding: .utf8
        )
        try writeExecutableScript(
            at: fakeBinURL.appendingPathComponent("gh"),
            contents: """
            #!/bin/sh
            printf invoked > "$CMUX_GH_MARKER"
            printf '2746\\tOPEN\\thttps://github.com/manaflow-ai/cmux/pull/2746\\n'
            """
        )
        let socketFD = try bindUnixSocket(at: socketPath.path)
        defer {
            Darwin.close(socketFD)
            unlink(socketPath.path)
            try? fileManager.removeItem(at: root)
        }

        let output = try runInteractiveZsh(
            cmuxLoadGhosttyIntegration: false,
            cmuxLoadShellIntegration: true,
            command: """
            _cmux_send() { :; }
            _cmux_send_bg() { :; }
            _cmux_report_pr_for_path "\(repoURL.path)" || true
            [[ -e "\(markerURL.path)" ]] && print MARKER=1 || print MARKER=0
            """,
            extraEnvironment: [
                "CMUX_NO_PR_WATCH": "1",
                "CMUX_GH_MARKER": markerURL.path,
                "CMUX_SOCKET_PATH": socketPath.path,
                "PATH": "\(fakeBinURL.path):/usr/bin:/bin",
            ]
        )

        XCTAssertTrue(output.contains("MARKER=0"), output)
    }

    func testBashNoPullRequestWatchSkipsLegacyGhPRProbe() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-bash-no-pr-watch-\(UUID().uuidString)")
        let repoURL = root.appendingPathComponent("repo", isDirectory: true)
        let fakeBinURL = root.appendingPathComponent("fake-bin", isDirectory: true)
        let markerURL = root.appendingPathComponent("gh-pr-invoked", isDirectory: false)
        let socketPath = root.appendingPathComponent("cmux-test.sock", isDirectory: false)

        try fileManager.createDirectory(at: repoURL.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: fakeBinURL, withIntermediateDirectories: true)
        try "ref: refs/heads/issue-2746-rate-limit\n".write(
            to: repoURL.appendingPathComponent(".git/HEAD"),
            atomically: true,
            encoding: .utf8
        )
        try writeExecutableScript(
            at: fakeBinURL.appendingPathComponent("gh"),
            contents: """
            #!/bin/sh
            printf invoked > "$CMUX_GH_MARKER"
            printf '2746\\tOPEN\\thttps://github.com/manaflow-ai/cmux/pull/2746\\n'
            """
        )
        let socketFD = try bindUnixSocket(at: socketPath.path)
        defer {
            Darwin.close(socketFD)
            unlink(socketPath.path)
            try? fileManager.removeItem(at: root)
        }

        let result = try runInteractiveBash(
            cmuxLoadShellIntegration: true,
            command: """
            _cmux_send() { :; }
            _cmux_report_pr_for_path "\(repoURL.path)" || true
            [[ -e "\(markerURL.path)" ]] && printf 'MARKER=1\\n' || printf 'MARKER=0\\n'
            """,
            extraEnvironment: [
                "CMUX_NO_PR_WATCH": "1",
                "CMUX_GH_MARKER": markerURL.path,
                "CMUX_SOCKET_PATH": socketPath.path,
                "PATH": "\(fakeBinURL.path):/usr/bin:/bin",
            ]
        )

        XCTAssertTrue(result.stdout.contains("MARKER=0"), result.stdout)
    }

    private func bindUnixSocket(at path: String) throws -> Int32 {
        unlink(path)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(errno),
                userInfo: [NSLocalizedDescriptionKey: "Failed to create Unix socket"]
            )
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let maxPathLength = MemoryLayout.size(ofValue: addr.sun_path)
        path.withCString { ptr in
            withUnsafeMutablePointer(to: &addr.sun_path) { pathPtr in
                let pathBuf = UnsafeMutableRawPointer(pathPtr).assumingMemoryBound(to: CChar.self)
                strncpy(pathBuf, ptr, maxPathLength - 1)
            }
        }

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                Darwin.bind(fd, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            let code = Int(errno)
            Darwin.close(fd)
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: code,
                userInfo: [NSLocalizedDescriptionKey: "Failed to bind Unix socket"]
            )
        }

        guard Darwin.listen(fd, 1) == 0 else {
            let code = Int(errno)
            Darwin.close(fd)
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: code,
                userInfo: [NSLocalizedDescriptionKey: "Failed to listen on Unix socket"]
            )
        }

        return fd
    }
}
