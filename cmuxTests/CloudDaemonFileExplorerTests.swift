import CmuxCloud
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Scripted guest daemon: answers WorkspaceRequest JSON like the cmux-tui workspace service.
private actor CloudWorkspaceFileRPCFixture: CloudWorkspaceFileRPC {
    enum Mode { case daemon, unavailable }
    var mode: Mode = .daemon
    var files: [String: Data] = [:]
    var directories: [String: [(name: String, kind: String)]] = [:]
    var symlinkTargets: [String: String] = [:]
    var gitChanges: [[String: Any]] = []
    var diffPages: [String] = []
    var capabilities: [String] = []
    var watchEvents: [[String]] = []
    private(set) var roots: [String] = []
    private(set) var requests: [String] = []
    private var workspaceGeneration = 0

    func setMode(_ mode: Mode) { self.mode = mode }
    func setFile(_ path: String, _ data: Data) { files[path] = data }
    func setDirectory(_ path: String, _ entries: [(name: String, kind: String)]) { directories[path] = entries }
    func setSymlink(_ path: String, kind: String) { symlinkTargets[path] = kind }
    func setGitChanges(_ changes: [[String: Any]]) { gitChanges = changes }
    func setDiffPages(_ pages: [String]) { diffPages = pages }
    func setCapabilities(_ values: [String]) { capabilities = values }
    func setWatchEvents(_ events: [[String]]) { watchEvents = events }
    /// Simulates a replaced channel: previously leased workspace ids become unknown.
    func forgetWorkspaces() { workspaceGeneration += 1 }

    nonisolated func request(vmID: String, _ requestJSON: Data) async throws -> Data {
        try await handle(requestJSON)
    }

    private func handle(_ requestJSON: Data) async throws -> Data {
        guard mode == .daemon else { throw CloudWorkspaceFileRPCUnavailable() }
        let request = try JSONSerialization.jsonObject(with: requestJSON) as! [String: Any]
        let type = request["type"] as! String
        requests.append(type)
        if type == "capabilities" {
            return try JSONSerialization.data(withJSONObject: ["type": "capabilities", "capabilities": capabilities])
        }
        if type == "watch-poll" {
            let after = (request["after"] as! NSNumber).uint64Value
            guard Int(after) < watchEvents.count else {
                try await Task.sleep(for: .seconds(60))
                throw CancellationError()
            }
            return try JSONSerialization.data(withJSONObject: [
                "type": "watch-changes", "sequence": after + 1, "paths": watchEvents[Int(after)], "overflow": false,
            ])
        }
        if type == "unwatch" { return try JSONSerialization.data(withJSONObject: ["type": "unwatched"]) }
        if type == "open-workspace" {
            let root = request["root"] as! String
            roots.append(root)
            return try JSONSerialization.data(withJSONObject: ["type": "workspace", "id": "ws-\(workspaceGeneration)-\(root)", "root": root])
        }
        guard let workspace = request["workspace"] as? String, workspace.hasPrefix("ws-\(workspaceGeneration)-") else {
            throw CloudWorkspaceRPCProcess.RemoteError(code: "unknown-workspace", message: "unknown workspace")
        }
        if type == "git-status" {
            return try JSONSerialization.data(withJSONObject: [
                "type": "git-status", "status": ["branch": "main", "changes": gitChanges],
            ])
        }
        if type == "diff" {
            let index = (request["cursor"] as? String).flatMap(Int.init) ?? 0
            var response: [String: Any] = [
                "type": "diff", "format": "unified", "data": Data(diffPages[index].utf8).base64EncodedString(),
            ]
            if index + 1 < diffPages.count { response["next_cursor"] = String(index + 1) }
            return try JSONSerialization.data(withJSONObject: response)
        }
        if type == "watch-directories" {
            return try JSONSerialization.data(withJSONObject: ["type": "watch-started", "watch": "w1"])
        }
        let path = request["path"] as! String
        #expect(!path.hasPrefix("/"), "workspace paths are relative to the / root")
        switch type {
        case "list-directory":
            guard let entries = directories[path] else {
                throw CloudWorkspaceRPCProcess.RemoteError(code: "not-found", message: "missing")
            }
            let hidden = request["include_hidden"] as? Bool ?? false
            let visible = entries.filter { hidden || !$0.name.hasPrefix(".") }
            return try JSONSerialization.data(withJSONObject: [
                "type": "directory", "truncated": false,
                "entries": visible.map { ["name": $0.name, "path": $0.name, "kind": $0.kind, "size": 0] },
            ])
        case "stat":
            let exists = symlinkTargets[path] != nil || files[path] != nil || directories[path] != nil
            guard exists else { throw CloudWorkspaceRPCProcess.RemoteError(code: "not-found", message: "missing") }
            let kind = symlinkTargets[path] ?? (directories[path] != nil ? "directory" : "file")
            return try JSONSerialization.data(withJSONObject: ["type": "stat", "stat": ["path": path, "kind": kind, "size": 0]])
        case "read-file":
            guard let data = files[path] else {
                throw CloudWorkspaceRPCProcess.RemoteError(code: "not-found", message: "missing")
            }
            let limit = request["limit"] as! Int
            let slice = data.prefix(limit)
            return try JSONSerialization.data(withJSONObject: [
                "type": "file", "data": slice.base64EncodedString(), "offset": 0,
                "eof": slice.count == data.count, "content_hash": "h",
            ])
        default:
            throw CloudWorkspaceRPCProcess.RemoteError(code: "unsupported", message: type)
        }
    }
}

private final class ExecCallRecorder: CloudFileExplorerCommandRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var calls: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
    let stdout: String

    init(stdout: String) { self.stdout = stdout }

    func run(vmID: String, command: String, timeoutMs: Int) async throws -> VMExecResult {
        lock.lock()
        count += 1
        lock.unlock()
        return VMExecResult(exitCode: 0, stdout: stdout, stderr: "")
    }
}

@Suite struct CloudDaemonFileExplorerTests {
    private func provider(rpc: CloudWorkspaceFileRPCFixture, exec: ExecCallRecorder) -> CloudVMFileExplorerProvider {
        CloudVMFileExplorerProvider(
            vmID: "vivid-newt", displayTarget: "vivid-newt", isAvailable: true,
            commandRunner: exec, fileRPC: rpc
        )
    }

    @Test("listing goes to the daemon, expands directory symlinks, and never uses exec")
    func listingUsesDaemon() async throws {
        let rpc = CloudWorkspaceFileRPCFixture()
        await rpc.setDirectory("home/cmux", [
            (".env", "file"), ("src", "directory"), ("notes.md", "file"), ("repo", "symlink"), ("latest.log", "symlink"),
        ])
        await rpc.setSymlink("home/cmux/repo", kind: "directory")
        let exec = ExecCallRecorder(stdout: "[]")
        let entries = try await provider(rpc: rpc, exec: exec).listDirectory(path: "/home/cmux/", showHidden: false)
        #expect(entries.map(\.name) == ["src", "notes.md", "repo", "latest.log"])
        #expect(entries.map(\.path) == ["/home/cmux/src", "/home/cmux/notes.md", "/home/cmux/repo", "/home/cmux/latest.log"])
        #expect(entries.map(\.isDirectory) == [true, false, true, false])
        #expect(exec.calls == 0)
        #expect(await rpc.requests.filter { $0 == "open-workspace" }.count == 1)
    }

    @Test("a preview reads the file through the daemon in one request")
    func previewUsesDaemon() async throws {
        let rpc = CloudWorkspaceFileRPCFixture()
        await rpc.setFile("home/cmux/a.txt", Data("hello".utf8))
        let exec = ExecCallRecorder(stdout: "")
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-daemon-preview-\(UUID().uuidString)/a.txt")
        defer { try? FileManager.default.removeItem(at: destination.deletingLastPathComponent()) }
        try await provider(rpc: rpc, exec: exec).downloadFile(path: "/home/cmux/a.txt", to: destination)
        #expect(try Data(contentsOf: destination) == Data("hello".utf8))
        #expect(await rpc.requests == ["open-workspace", "read-file"])
        #expect(exec.calls == 0)
    }

    @Test("a file above the preview limit is refused")
    func oversizedPreviewIsRefused() async throws {
        let rpc = CloudWorkspaceFileRPCFixture()
        await rpc.setFile("big.bin", Data(count: 1_048_577))
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent("cmux-big-\(UUID().uuidString)")
        await #expect {
            try await provider(rpc: rpc, exec: ExecCallRecorder(stdout: "")).downloadFile(path: "/big.bin", to: destination)
        } throws: { error in
            if case FileExplorerError.remoteFileTooLarge = error { return true }
            return false
        }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }

    @Test("a daemon error is final and does not retry through exec")
    func daemonErrorDoesNotFallBack() async throws {
        let rpc = CloudWorkspaceFileRPCFixture()
        let exec = ExecCallRecorder(stdout: "[]")
        await #expect(throws: FileExplorerError.self) {
            try await provider(rpc: rpc, exec: exec).listDirectory(path: "/missing", showHidden: false)
        }
        #expect(exec.calls == 0)
    }

    @Test("an unavailable daemon channel falls back to exec")
    func unavailableChannelFallsBackToExec() async throws {
        let rpc = CloudWorkspaceFileRPCFixture()
        await rpc.setMode(.unavailable)
        let exec = ExecCallRecorder(stdout: #"[{"name":"a","path":"/a","directory":false}]"#)
        let entries = try await provider(rpc: rpc, exec: exec).listDirectory(path: "/", showHidden: false)
        #expect(entries.map(\.path) == ["/a"])
        #expect(exec.calls == 1)
    }

    @Test("a replaced channel reopens the root workspace once")
    func staleWorkspaceIsReopened() async throws {
        let rpc = CloudWorkspaceFileRPCFixture()
        await rpc.setDirectory("", [("etc", "directory")])
        let exec = ExecCallRecorder(stdout: "[]")
        let explorer = provider(rpc: rpc, exec: exec)
        _ = try await explorer.listDirectory(path: "/", showHidden: false)
        await rpc.forgetWorkspaces()
        let entries = try await explorer.listDirectory(path: "/", showHidden: false)
        #expect(entries.map(\.path) == ["/etc"])
        #expect(await rpc.requests.filter { $0 == "open-workspace" }.count == 2)
        #expect(exec.calls == 0)
    }

    @Test("git status finds the repository above the explorer root and keys paths absolutely")
    func gitStatusUsesRepositoryRoot() async throws {
        let rpc = CloudWorkspaceFileRPCFixture()
        await rpc.setDirectory("home/cmux/proj/.git", [])
        await rpc.setGitChanges([
            ["path": "src/a.swift", "index_status": " ", "worktree_status": "M"],
            ["path": "new.txt", "index_status": "?", "worktree_status": "?"],
            ["path": "b.txt", "original_path": "old.txt", "index_status": "R", "worktree_status": " "],
        ])
        let provider = provider(rpc: rpc, exec: ExecCallRecorder(stdout: ""))
        let status = try #require(try await provider.gitStatus(directory: "/home/cmux/proj/src"))
        #expect(status.repositoryRoot == "/home/cmux/proj")
        let map = GitStatusProvider().statusFromRemotePorcelain(
            status.porcelain, repoRoot: status.repositoryRoot, directory: "/home/cmux/proj"
        )
        #expect(map["/home/cmux/proj/src/a.swift"] == .modified)
        #expect(map["/home/cmux/proj/src"] == .modified)
        #expect(map["/home/cmux/proj/new.txt"] == .untracked)
        #expect(map["/home/cmux/proj/b.txt"] == .renamed)
        #expect(await rpc.roots.contains("/home/cmux/proj"))
    }

    @Test("outside a repository there is no git status")
    func gitStatusOutsideRepository() async throws {
        let rpc = CloudWorkspaceFileRPCFixture()
        let status = try await provider(rpc: rpc, exec: ExecCallRecorder(stdout: "")).gitStatus(directory: "/tmp")
        #expect(status == nil)
    }

    @Test("a diff concatenates every page the daemon returns")
    func diffConcatenatesPages() async throws {
        let rpc = CloudWorkspaceFileRPCFixture()
        await rpc.setDirectory("repo/.git", [])
        await rpc.setDiffPages(["diff --git a/x b/x\n", "diff --git a/y b/y\n"])
        let result = try #require(try await provider(rpc: rpc, exec: ExecCallRecorder(stdout: "")).diff(directory: "/repo", staged: false))
        #expect(String(decoding: result.patch, as: UTF8.self) == "diff --git a/x b/x\ndiff --git a/y b/y\n")
    }

    @Test("directory changes stream the daemon's changed directories as absolute paths")
    func watchStreamsChanges() async throws {
        let rpc = CloudWorkspaceFileRPCFixture()
        await rpc.setCapabilities(["workspace-watch-v1"])
        await rpc.setWatchEvents([["home/cmux"], ["home/cmux/src"]])
        var iterator = provider(rpc: rpc, exec: ExecCallRecorder(stdout: ""))
            .directoryChanges(["/home/cmux", "/home/cmux/src"]).makeAsyncIterator()
        #expect(try await iterator.next() == ["/home/cmux"])
        #expect(try await iterator.next() == ["/home/cmux/src"])
    }

    @Test("an old daemon without the watch capability ends the stream at once")
    func watchWithoutCapabilityFinishes() async throws {
        let rpc = CloudWorkspaceFileRPCFixture()
        var iterator = provider(rpc: rpc, exec: ExecCallRecorder(stdout: ""))
            .directoryChanges(["/home/cmux"]).makeAsyncIterator()
        #expect(try await iterator.next() == nil)
        #expect(await !rpc.requests.contains("watch-directories"))
    }
}
