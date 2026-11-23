import CmuxCloud
import CmuxCore
import CmuxSurfaceCatalogModel
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

    @Test func managedSSHTerminalReadsItsLiveDirectoryFromTheDaemon() async throws {
        let workspace = Workspace()
        let panelID = try #require(workspace.focusedPanelId)
        let catalog = SurfaceCatalog.shared
        let configuration = WorkspaceRemoteConfiguration(
            destination: "fixture@remote.invalid", port: 2222, identityFile: nil,
            sshOptions: [], localProxyPort: nil, relayPort: nil, relayID: nil, relayToken: nil,
            localSocketPath: nil, terminalStartupCommand: nil, preserveAfterTerminalExit: true
        )
        workspace.remoteConfiguration = configuration
        let provider = CloudTerminalPlacementTestProvider(
            machine: SurfaceMachineID(rawValue: SSHTuiConnection(configuration: configuration).id)
        )
        catalog.register(provider)
        defer {
            catalog.endProjections(panelID: panelID, reason: .replaced)
            catalog.unregister(machine: provider.machine)
            workspace.teardownAllPanels()
        }
        #expect(workspace.remoteTerminalLiveWorkingDirectoryLookup(for: panelID) == nil)
        let resource = provider.resource(key: "term_" + UUID().uuidString)
        catalog.upsert(resource, from: provider)
        catalog.record(SurfaceProjection(resource: resource.id, workspaceID: workspace.id, panelID: panelID,
            remoteWorkspaceID: provider.remote.id, remoteTabID: "tab-live"))
        let lookup = try #require(workspace.remoteTerminalLiveWorkingDirectoryLookup(for: panelID))
        #expect(await lookup() == "/remote/project")
        // A projection from another machine must never answer for this connection.
        let other = CloudTerminalPlacementTestProvider()
        catalog.register(other)
        defer { catalog.unregister(machine: other.machine) }
        let foreign = other.resource(key: "term_" + UUID().uuidString)
        catalog.upsert(foreign, from: other)
        catalog.endProjections(panelID: panelID, reason: .replaced)
        catalog.record(SurfaceProjection(resource: foreign.id, workspaceID: workspace.id, panelID: panelID,
            remoteWorkspaceID: other.remote.id, remoteTabID: "tab-foreign"))
        #expect(workspace.remoteTerminalLiveWorkingDirectoryLookup(for: panelID) == nil)
    }

    @Test func relativeTokensResolveAgainstTheLiveDirectoryNotTheSpawnDirectory() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = PreviewDownloadTransport(files: ["/home/remote/repo/subdir/README.md": Data("live".utf8)])
        let queries = LiveDirectoryQueries()
        let result = try await makeLoader(transport: transport, cache: root).load(
            tokens: ["subdir/README.md"], workingDirectory: "/home/remote",
            liveWorkingDirectory: { await queries.answer("/home/remote/repo") }
        )
        #expect(try String(contentsOf: result, encoding: .utf8) == "live")
        #expect(await transport.requests.paths == ["/home/remote/repo/subdir/README.md"])
        #expect(await queries.count == 1)
    }

    @Test func liveDirectoryIsNotQueriedWithoutARelativeToken() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = PreviewDownloadTransport(files: [
            "/srv/notes.md": Data("absolute".utf8), "/home/remote/notes.md": Data("home".utf8),
        ])
        let queries = LiveDirectoryQueries()
        let loader = makeLoader(transport: transport, cache: root)
        for token in ["/srv/notes.md", "~/notes.md", "file:///srv/notes.md"] {
            _ = try await loader.load(
                tokens: [token], workingDirectory: nil,
                liveWorkingDirectory: { await queries.answer("/elsewhere") }
            )
        }
        #expect(await queries.count == 0)
    }

    @Test func absoluteCandidateOpensBeforeQueryingALaterRelativeCandidate() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = PreviewDownloadTransport(files: ["/srv/notes.md": Data("absolute".utf8)])
        let queries = LiveDirectoryQueries()
        let result = try await makeLoader(transport: transport, cache: root).load(
            tokens: ["/srv/notes.md", "notes.md"], workingDirectory: "/reported",
            liveWorkingDirectory: { await queries.answer("/live") }
        )
        #expect(try String(contentsOf: result, encoding: .utf8) == "absolute")
        #expect(await transport.requests.paths == ["/srv/notes.md"])
        #expect(await queries.count == 0)
    }

    @Test func missingAbsoluteCandidateQueriesTheDirectoryBeforeTryingARelativeCandidate() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = PreviewDownloadTransport(files: ["/live/notes.md": Data("relative".utf8)])
        let queries = LiveDirectoryQueries()
        let result = try await makeLoader(transport: transport, cache: root).load(
            tokens: ["/missing.md", "notes.md"], workingDirectory: "/reported",
            liveWorkingDirectory: { await queries.answer("/live") }
        )
        #expect(try String(contentsOf: result, encoding: .utf8) == "relative")
        #expect(await transport.requests.paths == ["/missing.md", "/live/notes.md"])
        #expect(await queries.count == 1)
    }

    @Test func liveDirectoryResolvesRelativeTokensWithoutAReportedDirectory() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = PreviewDownloadTransport(files: ["/remote/repo/notes.md": Data("live".utf8)])
        let result = try await makeLoader(transport: transport, cache: root).load(
            tokens: ["notes.md"], workingDirectory: nil,
            liveWorkingDirectory: { "/remote/repo" }
        )
        #expect(try String(contentsOf: result, encoding: .utf8) == "live")
        #expect(await transport.requests.paths == ["/remote/repo/notes.md"])
    }

    @Test func unavailableLiveDirectoryFallsBackToTheReportedDirectory() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = PreviewDownloadTransport(files: ["/reported/notes.md": Data("reported".utf8)])
        let loader = makeLoader(transport: transport, cache: root)
        for live in [nil, "", "relative/dir"] as [String?] {
            let result = try await loader.load(
                tokens: ["notes.md"], workingDirectory: "/reported",
                liveWorkingDirectory: { live }
            )
            #expect(try String(contentsOf: result, encoding: .utf8) == "reported")
        }
    }

    @Test func relativeTokenFallsBackToTheReportedDirectoryWhenTheLiveDirectoryMisses() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        // The shell reported /reported, but the foreground process runs in /live and the
        // printed path is relative to the shell's directory.
        let transport = PreviewDownloadTransport(files: ["/reported/notes.md": Data("reported".utf8)])
        let result = try await makeLoader(transport: transport, cache: root).load(
            tokens: ["notes.md"], workingDirectory: "/reported",
            liveWorkingDirectory: { "/live" }
        )
        #expect(try String(contentsOf: result, encoding: .utf8) == "reported")
        #expect(await transport.requests.paths == ["/live/notes.md", "/reported/notes.md"])
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

    @Test func missingRemoteCandidatesProduceAnActionablePreviewError() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = PreviewDownloadTransport(files: [:])
        do {
            _ = try await makeLoader(transport: transport, cache: root).load(
                tokens: ["/missing.md", "notes.md"], workingDirectory: "/reported",
                liveWorkingDirectory: { "/live" }
            )
            Issue.record("Missing remote files unexpectedly opened")
        } catch {
            #expect(error as? FileExplorerError == .remoteFileUnavailable)
        }
        #expect(await transport.requests.paths == ["/missing.md", "/live/notes.md", "/reported/notes.md"])
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

private actor LiveDirectoryQueries {
    var count = 0
    func answer(_ directory: String?) -> String? {
        count += 1
        return directory
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
