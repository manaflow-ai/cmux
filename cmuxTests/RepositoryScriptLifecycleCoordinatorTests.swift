import CmuxFoundation
import CmuxSettings
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
struct RepositoryScriptLifecycleCoordinatorTests {
    @Test func closeBeforeResolutionRunsAnAlreadyTrustedArchiveScript() async throws {
        let root = try makeRepository(archive: "echo cleanup")
        defer { try? FileManager.default.removeItem(at: root) }
        let authorizer = RepositoryScriptTestAuthorizer(trusted: true)
        let fixture = makeCoordinator(root: root, authorizer: authorizer)
        let workspace = Workspace()

        fixture.coordinator.workspaceCreated(workspace, directory: root.path)
        fixture.coordinator.workspaceWillClose(workspace)

        let invocation = await fixture.commands.waitForInvocation()
        #expect(invocation?.directory == root.resolvingSymlinksInPath().path)
        #expect(invocation?.arguments.last?.contains("echo cleanup") == true)
    }

    @Test func authorizationCompletingAfterCloseRunsTheArchiveScript() async throws {
        let root = try makeRepository(archive: "echo cleanup")
        defer { try? FileManager.default.removeItem(at: root) }
        let authorizer = RepositoryScriptTestAuthorizer(trusted: false)
        let fixture = makeCoordinator(root: root, authorizer: authorizer)
        let workspace = Workspace()

        fixture.coordinator.workspaceCreated(workspace, directory: root.path)
        #expect(await authorizer.waitForRequest())
        fixture.coordinator.workspaceWillClose(workspace)
        authorizer.authorizePendingRequest()

        let invocation = await fixture.commands.waitForInvocation()
        #expect(invocation?.directory == root.resolvingSymlinksInPath().path)
        #expect(invocation?.arguments.last?.contains("echo cleanup") == true)
    }

    @Test func closeBeforeResolutionRejectsAnUntrustedProjectArchiveScript() async throws {
        let root = try makeRepository(archive: "echo untrusted")
        defer { try? FileManager.default.removeItem(at: root) }
        let authorizer = RepositoryScriptTestAuthorizer(trusted: false)
        let fixture = makeCoordinator(root: root, authorizer: authorizer)
        let workspace = Workspace()

        fixture.coordinator.workspaceCreated(workspace, directory: root.path)
        fixture.coordinator.workspaceWillClose(workspace)

        #expect(await authorizer.waitForTrustCheck())
        #expect(await fixture.commands.lastInvocation() == nil)
    }

    private func makeCoordinator(
        root: URL,
        authorizer: RepositoryScriptTestAuthorizer
    ) -> (
        coordinator: RepositoryScriptLifecycleCoordinator,
        commands: RecordingRepositoryArchiveCommandRunner
    ) {
        let catalog = SettingCatalog()
        let configStore = JSONConfigStore(fileURL: root.appendingPathComponent("global.json"))
        let commands = RecordingRepositoryArchiveCommandRunner()
        return (
            RepositoryScriptLifecycleCoordinator(
                configStore: configStore,
                catalog: catalog,
                promptStore: RepositorySetupPromptStore(
                    configStore: configStore,
                    catalog: catalog
                ),
                commandRunner: commands,
                authorizer: authorizer
            ),
            commands
        )
    }

    private func makeRepository(archive: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-repository-lifecycle-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(".git"),
            withIntermediateDirectories: true
        )
        let configURL = root.appendingPathComponent(".cmux/cmux.json")
        try FileManager.default.createDirectory(
            at: configURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let config = CmuxConfigFile(
            scripts: CmuxRepositoryScriptsDefinition(archive: archive)
        )
        try JSONEncoder().encode(config).write(to: configURL)
        return root
    }
}
