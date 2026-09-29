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
    private(set) var requests: [String] = []
    private var workspaceGeneration = 0

    func setMode(_ mode: Mode) { self.mode = mode }
    func setFile(_ path: String, _ data: Data) { files[path] = data }
    func setDirectory(_ path: String, _ entries: [(name: String, kind: String)]) { directories[path] = entries }
    func setSymlink(_ path: String, kind: String) { symlinkTargets[path] = kind }
    /// Simulates a replaced channel: previously leased workspace ids become unknown.
    func forgetWorkspaces() { workspaceGeneration += 1 }

    nonisolated func request(vmID: String, _ requestJSON: Data) async throws -> Data {
        try await handle(requestJSON)
    }

    private func handle(_ requestJSON: Data) throws -> Data {
        guard mode == .daemon else { throw CloudWorkspaceFileRPCUnavailable() }
        let request = try JSONSerialization.jsonObject(with: requestJSON) as! [String: Any]
        let type = request["type"] as! String
        requests.append(type)
        let current = "ws-\(workspaceGeneration)"
        if type == "open-workspace" {
            #expect(request["root"] as? String == "/")
            return try JSONSerialization.data(withJSONObject: ["type": "workspace", "id": current, "root": "/"])
        }
        guard request["workspace"] as? String == current else {
            throw CloudWorkspaceRPCProcess.RemoteError(code: "unknown-workspace", message: "unknown workspace")
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
            let kind = symlinkTargets[path] ?? "file"
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
}
