import CmuxCore
import Dispatch
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

private struct FakeDockConfigFileSystem: DockConfigFileSystem {
    let directories: Set<String>
    let files: [String: Data]
    var enforcesDeadline = false

    func metadata(at path: String, deadline: DispatchTime) async throws -> DockConfigFileMetadata {
        try checkDeadline(deadline)
        if directories.contains(path) {
            return DockConfigFileMetadata(exists: true, kind: .directory, size: nil)
        }
        if let data = files[path] {
            return DockConfigFileMetadata(
                exists: true,
                kind: .file,
                size: Int64(data.count)
            )
        }
        return DockConfigFileMetadata(exists: false, kind: nil, size: nil)
    }

    func readFile(at path: String, deadline: DispatchTime) async throws -> Data {
        try checkDeadline(deadline)
        guard let data = files[path] else {
            throw CocoaError(.fileNoSuchFile)
        }
        return data
    }

    private func checkDeadline(_ deadline: DispatchTime) throws {
        guard enforcesDeadline,
              deadline.uptimeNanoseconds <= DispatchTime.now().uptimeNanoseconds else {
            return
        }
        throw NSError(domain: "test.dock.config", code: 1)
    }
}

@Suite("Dock config source resolution")
struct DockConfigSourceResolutionTests {
    private func context(
        root: String,
        origin: DockConfigOrigin,
        files: [String: Data],
        executionContext: DockExecutionContext = .local
    ) -> DockConfigurationContext {
        let executionWorkspaceID: UUID?
        if case .remote(let remoteContext) = executionContext {
            executionWorkspaceID = remoteContext.workspaceID
        } else {
            executionWorkspaceID = nil
        }
        let source = DockProjectConfigSource(
            origin: origin,
            fileSystem: FakeDockConfigFileSystem(directories: [root], files: files),
            rootDirectory: DockConfigPath(root)!,
            boundaryDirectory: DockConfigPath("/")!,
            executionContext: executionContext
        )
        return DockConfigurationContext(
            identity: DockConfigurationContext.Identity(
                projectOrigin: origin,
                rootDirectory: root,
                availabilityRevision: "test",
                executionWorkspaceID: executionWorkspaceID,
                includesGlobalFallback: false
            ),
            projectSource: source,
            includesGlobalFallback: false,
            emptyBaseDirectory: root
        )
    }

    @Test("remote paths resolve through the source filesystem, not local FileManager")
    func resolvesRemoteProjectConfig() async throws {
        let workspaceID = UUID()
        let path = "/home/me/project/.cmux/dock.json"
        let data = Data(#"{"controls":[{"id":"logs","command":"tail -f logs/app.log"}]}"#.utf8)
        let resolution = try await DockConfigResolver().resolve(context: context(
            root: "/home/me/project/packages/app",
            origin: .remote(identity: "ssh|me@example.com|22", displayTarget: "me@example.com"),
            files: [path: data],
            executionContext: .remote(DockRemoteExecutionContext(
                workspaceID: workspaceID,
                foregroundAuth: nil
            ))
        ))

        #expect(resolution.sourcePath == path)
        #expect(resolution.baseDirectory == "/home/me/project")
        #expect(resolution.controls.map(\.id) == ["logs"])
        #expect(resolution.executionContext == .remote(DockRemoteExecutionContext(
            workspaceID: workspaceID,
            foregroundAuth: nil
        )))
    }

    @Test("the nearest project config wins during upward traversal")
    func nearestProjectConfigWins() async throws {
        let parent = "/srv/repo/.cmux/dock.json"
        let nested = "/srv/repo/apps/web/.cmux/dock.json"
        let resolution = try await DockConfigResolver().resolve(context: context(
            root: "/srv/repo/apps/web/src",
            origin: .local,
            files: [
                parent: Data(#"{"controls":[{"id":"parent","command":"true"}]}"#.utf8),
                nested: Data(#"{"controls":[{"id":"nested","command":"true"}]}"#.utf8),
            ]
        ))

        #expect(resolution.sourcePath == nested)
        #expect(resolution.controls.map(\.id) == ["nested"])
    }

    @Test("config resolution applies one bounded operation deadline")
    func configResolutionHonorsOperationDeadline() async {
        let root = "/srv/repo/apps/web/src"
        let source = DockProjectConfigSource(
            origin: .remote(identity: "ssh|host|22", displayTarget: "host"),
            fileSystem: FakeDockConfigFileSystem(
                directories: [root],
                files: [:],
                enforcesDeadline: true
            ),
            rootDirectory: DockConfigPath(root)!,
            boundaryDirectory: DockConfigPath("/")!,
            executionContext: .local
        )
        let context = DockConfigurationContext(
            identity: DockConfigurationContext.Identity(
                projectOrigin: source.origin,
                rootDirectory: root,
                availabilityRevision: "test",
                executionWorkspaceID: nil,
                includesGlobalFallback: false
            ),
            projectSource: source,
            includesGlobalFallback: false,
            emptyBaseDirectory: root
        )

        await #expect(throws: (any Error).self) {
            _ = try await DockConfigResolver(operationTimeout: 0).resolve(context: context)
        }
    }

    @Test("remote trust identities distinguish hosts with the same path and config")
    func remoteTrustIdentityIncludesHost() async throws {
        let path = "/home/me/project/.cmux/dock.json"
        let data = Data(#"{"controls":[{"id":"logs","command":"tail -f app.log"}]}"#.utf8)
        let first = try await DockConfigResolver().resolve(context: context(
            root: "/home/me/project",
            origin: .remote(identity: "ssh|host-a|22", displayTarget: "host-a"),
            files: [path: data]
        ))
        let second = try await DockConfigResolver().resolve(context: context(
            root: "/home/me/project",
            origin: .remote(identity: "ssh|host-b|22", displayTarget: "host-b"),
            files: [path: data]
        ))

        #expect(DockSplitStore.configIdentity(for: first) != DockSplitStore.configIdentity(for: second))
        #expect(DockSplitStore.trustDescriptor(for: first) != DockSplitStore.trustDescriptor(for: second))
    }

    @Test("remote trust identity follows the complete daemon transport identity")
    func remoteTrustIdentityIncludesSSHRoute() {
        func configuration(identityFile: String, proxyJump: String) -> WorkspaceRemoteConfiguration {
            WorkspaceRemoteConfiguration(
                destination: "me@example.com",
                port: 22,
                identityFile: identityFile,
                sshOptions: ["ProxyJump=\(proxyJump)"],
                localProxyPort: nil,
                relayPort: nil,
                relayID: nil,
                relayToken: nil,
                localSocketPath: nil,
                terminalStartupCommand: nil
            )
        }
        let first = configuration(identityFile: "/keys/first", proxyJump: "bastion-a")
        let second = configuration(identityFile: "/keys/second", proxyJump: "bastion-b")

        #expect(Workspace.remoteDockTrustIdentity(first) == first.durableTransportTrustKey)
        #expect(Workspace.remoteDockTrustIdentity(first) != Workspace.remoteDockTrustIdentity(second))
    }

    @Test("remote execution identity distinguishes workspaces on the same host and path")
    func remoteExecutionIdentityIncludesWorkspace() {
        let firstWorkspaceID = UUID()
        let secondWorkspaceID = UUID()
        let first = context(
            root: "/home/me/project",
            origin: .remote(identity: "ssh|host-a|22", displayTarget: "host-a"),
            files: [:],
            executionContext: .remote(DockRemoteExecutionContext(
                workspaceID: firstWorkspaceID,
                foregroundAuth: nil
            ))
        )
        let second = context(
            root: "/home/me/project",
            origin: .remote(identity: "ssh|host-a|22", displayTarget: "host-a"),
            files: [:],
            executionContext: .remote(DockRemoteExecutionContext(
                workspaceID: secondWorkspaceID,
                foregroundAuth: nil
            ))
        )

        #expect(first.identity != second.identity)

        let location = DockConfigLocation(
            origin: .remote(identity: "ssh|host-a|22", displayTarget: "host-a"),
            path: "/home/me/project/.cmux/dock.json"
        )
        let firstResolution = DockConfigResolution(
            controls: [],
            sourceLocation: location,
            baseDirectory: "/home/me/project",
            isProjectSource: true,
            executionContext: .remote(DockRemoteExecutionContext(
                workspaceID: firstWorkspaceID,
                foregroundAuth: nil
            ))
        )
        let secondResolution = DockConfigResolution(
            controls: [],
            sourceLocation: location,
            baseDirectory: "/home/me/project",
            isProjectSource: true,
            executionContext: .remote(DockRemoteExecutionContext(
                workspaceID: secondWorkspaceID,
                foregroundAuth: nil
            ))
        )

        let firstLoadedIdentity = DockSplitStore.configIdentity(for: firstResolution)
        let secondLoadedIdentity = DockSplitStore.configIdentity(for: secondResolution)
        #expect(secondLoadedIdentity.requiresPanelReload(comparedTo: firstLoadedIdentity))
    }

    @Test("POSIX traversal never escapes the filesystem root")
    func pathTraversalStopsAtRoot() {
        #expect(DockConfigPath("/../../home/me")?.value == "/home/me")
        #expect(DockConfigPath("/")?.parent == nil)
        #expect(DockConfigPath("/home")?.parent?.value == "/")
    }

    @Test("remote PTY startup targets the selected workspace explicitly")
    func remotePTYStartupUsesExplicitWorkspace() {
        let workspaceID = UUID()
        let foregroundAuth = SSHPTYAttachStartupCommandBuilder.ForegroundAuth(
            destination: "me@example.com",
            port: 22,
            identityFile: nil,
            sshOptions: [],
            token: "test-token"
        )
        let command = SSHPTYAttachStartupCommandBuilder.command(
            foregroundAuth: foregroundAuth,
            remoteCommand: "printf ready",
            requireExisting: false,
            workspaceID: workspaceID
        )

        #expect(command.contains("--workspace \(workspaceID.uuidString.lowercased())"))
        #expect(!command.contains("required workspace context missing"))
        #expect(!command.contains("$CMUX_WORKSPACE_ID"))
        #expect(command.contains(
            #"{\"workspace_id\":\"\#(workspaceID.uuidString.lowercased())\",\"foreground_auth_token\":\"$cmux_ssh_auth_token\"}"#
        ))
        #expect(command.contains(Data("printf ready".utf8).base64EncodedString()))
    }

    @Test("remote control startup carries cwd, command, and Dock environment")
    func remoteControlStartupCarriesContext() {
        let script = DockSplitStore.remoteShellStartupScript(
            command: "tail -f logs/app.log",
            workingDirectory: "/home/me/project",
            environment: ["CMUX_DOCK_CONTROL_ID": "logs"]
        )

        #expect(script.contains(Data("tail -f logs/app.log".utf8).base64EncodedString()))
        #expect(script.contains(Data("/home/me/project".utf8).base64EncodedString()))
        #expect(script.contains("export CMUX_DOCK_CONTROL_ID=logs"))
        #expect(script.contains(#"cd "$cmux_dock_working_directory""#))
    }

    @Test("remote control startup without a command still carries cwd and Dock environment")
    func remoteControlStartupWithoutCommandCarriesContext() {
        let script = DockSplitStore.remoteControlStartupCommand(
            command: nil,
            workingDirectory: "/home/me/project",
            environment: ["CMUX_DOCK_CONTROL_ID": "shell"]
        )

        #expect(script.contains(Data("/home/me/project".utf8).base64EncodedString()))
        #expect(script.contains("export CMUX_DOCK_CONTROL_ID=shell"))
        #expect(script.contains(#"cd "$cmux_dock_working_directory""#))
    }

    @Test("remote control startup does not run when its working directory is unavailable")
    func remoteControlStartupFailsClosedForMissingWorkingDirectory() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "cmux-remote-dock-cwd-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let marker = root.appendingPathComponent("command-ran")
        let script = DockSplitStore.remoteShellStartupScript(
            command: "printf ran > \(marker.path)",
            workingDirectory: root.appendingPathComponent("missing").path,
            environment: [:]
        )
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script]
        process.standardError = Pipe()

        try process.run()
        process.waitUntilExit()

        #expect(process.terminationStatus != 0)
        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }

    @Test("remote config environment is not inherited by the local attach shell")
    func remoteConfigEnvironmentStaysRemote() {
        let environment = ["REMOTE_ONLY": "value"]
        let remoteContext = DockExecutionContext.remote(DockRemoteExecutionContext(
            workspaceID: UUID(),
            foregroundAuth: nil
        ))

        #expect(DockSplitStore.localAttachEnvironment(
            resolvedEnvironment: environment,
            executionContext: remoteContext
        ).isEmpty)
        #expect(DockSplitStore.localAttachEnvironment(
            resolvedEnvironment: environment,
            executionContext: .local
        ) == environment)
    }
}
