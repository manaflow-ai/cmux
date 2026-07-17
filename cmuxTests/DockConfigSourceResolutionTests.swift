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

    func metadata(at path: String) async throws -> DockConfigFileMetadata {
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

    func readFile(at path: String) async throws -> Data {
        guard let data = files[path] else {
            throw CocoaError(.fileNoSuchFile)
        }
        return data
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
}
