import CmuxCore
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite @MainActor struct RemoteTerminalFilePreviewLoaderTests {
    @Test func nativeSSHPreviewRequiresTheProjectedConnection() throws {
        let workspace = Workspace()
        let panelID = try #require(workspace.focusedPanelId)
        let catalog = SurfaceCatalog.shared
        defer {
            catalog.endProjections(panelID: panelID, reason: .replaced)
            workspace.teardownAllPanels()
        }
        let configuration = WorkspaceRemoteConfiguration(
            destination: "fixture@remote.invalid", port: 2222, identityFile: "/tmp/fixture-key",
            sshOptions: ["ProxyJump=fixture-jump"], localProxyPort: nil, relayPort: nil,
            relayID: nil, relayToken: nil, localSocketPath: nil, terminalStartupCommand: nil,
            preserveAfterTerminalExit: true
        )
        workspace.remoteConfiguration = configuration
        #expect(workspace.remoteTerminalFilePreviewConfiguration(for: panelID) == nil)
        let resource = SurfaceResourceID(
            machine: SurfaceMachineID(rawValue: SSHTuiConnection(configuration: configuration).id),
            kind: .terminal, key: "term_" + UUID().uuidString
        )
        catalog.restore([SurfaceProjectionRecord(panelID: panelID, resource: resource)],
                        workspaceID: workspace.id, restoringWorkspace: workspace)
        #expect(workspace.activeRemoteTerminalSurfaceIds.isEmpty)
        #expect(workspace.terminalLinkIsRemoteTerminal(panelID))
        #expect(workspace.remoteTerminalFilePreviewConfiguration(for: panelID) == configuration)
        workspace.remoteConfiguration = WorkspaceRemoteConfiguration(
            destination: "fixture@different.invalid", port: 2222, identityFile: "/tmp/fixture-key",
            sshOptions: [], localProxyPort: nil, relayPort: nil, relayID: nil, relayToken: nil,
            localSocketPath: nil, terminalStartupCommand: nil, preserveAfterTerminalExit: true
        )
        // An old projection must neither download from the replacement host nor resolve locally.
        #expect(workspace.remoteTerminalFilePreviewConfiguration(for: panelID) == nil)
        #expect(workspace.terminalLinkIsRemoteTerminal(panelID))
    }

    @Test func downloadsRemoteBytesInsteadOfReadingLocalShadow() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let shadow = root.appendingPathComponent("same name.txt")
        try Data("local shadow".utf8).write(to: shadow)
        let transport = PreviewDownloadTransport(files: [shadow.path: Data("remote bytes".utf8)])
        let loader = makeLoader(transport: transport, cache: root.appendingPathComponent("cache"))
        let result = try await loader.load(tokens: [shadow.path], workingDirectory: nil)
        #expect(result != shadow)
        #expect(result.lastPathComponent == shadow.lastPathComponent)
        #expect(try String(contentsOf: result, encoding: .utf8) == "remote bytes")
        #expect(try String(contentsOf: shadow, encoding: .utf8) == "local shadow")
        #expect(await transport.requests.paths == [shadow.path])
    }

    @Test func retriesEscapedSpellingAgainstRemoteHome() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = PreviewDownloadTransport(files: ["/home/remote/file name.txt": Data("remote".utf8)])
        let result = try await makeLoader(transport: transport, cache: root).load(
            tokens: ["~/file\\ name.txt,"], workingDirectory: "/wrong"
        )
        #expect(result.lastPathComponent == "file name.txt")
        #expect(try String(contentsOf: result, encoding: .utf8) == "remote")
        let paths = await transport.requests.paths.filter { $0 != "HOME" }
        #expect(paths.last == "/home/remote/file name.txt")
        #expect(paths.allSatisfy { $0.hasPrefix("/home/remote/") })
    }

    @Test func cancellationDoesNotBeginAHomeLookupOrDownload() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = PreviewDownloadTransport(files: [:])
        let loader = makeLoader(transport: transport, cache: root)
        let task = Task { try await loader.load(tokens: ["~/file.txt"], workingDirectory: nil) }
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("Cancelled request completed")
        } catch is CancellationError {
        }
        #expect(await transport.requests.paths.isEmpty)
    }

    private func makeLoader(transport: PreviewDownloadTransport, cache: URL) -> RemoteTerminalFilePreviewLoader {
        RemoteTerminalFilePreviewLoader(
            provider: SSHFileExplorerProvider(
                destination: "fixture@host", port: 2200, identityFile: nil, sshOptions: [],
                homePath: "", isAvailable: true, transport: transport
            ),
            cacheDirectory: cache,
            fileManager: FileManager()
        )
    }
}

private actor PreviewDownloadRequests {
    var paths: [String] = []
    func record(_ path: String) { paths.append(path) }
}

private final class PreviewDownloadTransport: SSHFileExplorerTransport, Sendable {
    let files: [String: Data]
    let requests = PreviewDownloadRequests()
    init(files: [String: Data]) { self.files = files }
    nonisolated func resolveHomePath(connection: SSHFileExplorerConnection) async throws -> String {
        await requests.record("HOME")
        return "/home/remote"
    }
    nonisolated func listDirectory(
        path: String, connection: SSHFileExplorerConnection, showHidden: Bool
    ) async throws -> [FileExplorerEntry] { [] }
    nonisolated func downloadFile(
        path: String, connection: SSHFileExplorerConnection, to localURL: URL
    ) async throws {
        await requests.record(path)
        guard let data = files[path] else { throw FileExplorerError.providerUnavailable }
        try data.write(to: localURL)
    }
}
