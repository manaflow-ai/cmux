import CmuxFoundation
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

struct RepositoryTerminalScriptsTests {
    @Test func workspaceSetupCommandDecodesAndCannotConflictWithInlineSetup() throws {
        let definition = try JSONDecoder().decode(
            CmuxWorkspaceDefinition.self,
            from: Data(#"{"name":"Dev","setupCommand":"Bootstrap"}"#.utf8)
        )
        #expect(definition.setupCommand == "Bootstrap")

        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(
                CmuxWorkspaceDefinition.self,
                from: Data(#"{"setup":"make deps","setupCommand":"Bootstrap"}"#.utf8)
            )
        }
    }

    @Test func projectScriptsResolveWithPrivateSettingsPrecedenceAndTrustBoundary() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try makeNormalRepository(at: root)
        try writeConfig(
            #"{"scripts":{"setup":"pnpm install","archive":"pnpm clean"}}"#,
            at: root.appendingPathComponent(".cmux/cmux.json")
        )

        let resolver = RepositoryScriptResolver()
        let project = try #require(resolver.resolve(directory: root.path, preferences: []))
        #expect(project.setup == "pnpm install")
        #expect(project.archive == "pnpm clean")
        let canonicalConfigPath = root.resolvingSymlinksInPath()
            .appendingPathComponent(".cmux/cmux.json").path
        #expect(project.source == .projectFile(path: canonicalConfigPath))
        #expect(resolver.trustDescriptor(for: project) != nil)

        let preference = RepositoryScriptPreference(
            repositoryID: project.identity.id,
            repositoryRoot: project.identity.workTreeRoot,
            setup: "mise install",
            archive: "mise prune",
            overridesProjectScripts: true,
            promptDismissed: true
        )
        let overridden = try #require(resolver.resolve(directory: root.path, preferences: [preference]))
        #expect(overridden.setup == "mise install")
        #expect(overridden.archive == "mise prune")
        #expect(overridden.projectScripts.setup == "pnpm install")
        #expect(overridden.source == .userSettings)
        #expect(resolver.trustDescriptor(for: overridden) == nil)
    }

    @Test func oversizedProjectConfigIsIgnored() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try makeNormalRepository(at: root)
        let padding = String(repeating: "x", count: 1_048_576)
        let config = #"{"scripts":{"setup":"pnpm install"},"padding":"\#(padding)"}"#
        #expect(config.utf8.count > 1_048_576)
        try writeConfig(
            config,
            at: root.appendingPathComponent(".cmux/cmux.json")
        )

        let resolution = try #require(
            RepositoryScriptResolver().resolve(directory: root.path, preferences: [])
        )

        #expect(resolution.setup == nil)
        #expect(resolution.projectScripts.isEmpty)
        #expect(resolution.source == .none)
    }

    @Test func scopedConfigWinsOverLegacyRootConfig() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try makeNormalRepository(at: root)
        try writeConfig(#"{"scripts":{"setup":"legacy"}}"#, at: root.appendingPathComponent("cmux.json"))
        let scopedURL = root.appendingPathComponent(".cmux/cmux.json")
        try writeConfig(#"{"scripts":{"setup":"scoped"}}"#, at: scopedURL)

        let resolver = RepositoryScriptResolver()
        #expect(resolver.resolve(directory: root.path, preferences: [])?.setup == "scoped")

        try FileManager.default.removeItem(at: scopedURL)
        #expect(resolver.resolve(directory: root.path, preferences: [])?.setup == "legacy")
    }

    @Test func linkedWorktreesShareRepositoryIdentityAndTrustFingerprint() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let common = root.appendingPathComponent("shared.git")
        let first = root.appendingPathComponent("first")
        let second = root.appendingPathComponent("second")
        try makeLinkedWorktree(at: first, gitDirectory: common.appendingPathComponent("worktrees/first"))
        try makeLinkedWorktree(at: second, gitDirectory: common.appendingPathComponent("worktrees/second"))
        let config = #"{"scripts":{"setup":"pnpm install"}}"#
        try writeConfig(config, at: first.appendingPathComponent(".cmux/cmux.json"))
        try writeConfig(config, at: second.appendingPathComponent(".cmux/cmux.json"))

        let resolver = RepositoryScriptResolver()
        let firstResolution = try #require(resolver.resolve(directory: first.path, preferences: []))
        let secondResolution = try #require(resolver.resolve(directory: second.path, preferences: []))
        #expect(firstResolution.identity.id == secondResolution.identity.id)
        #expect(firstResolution.identity.commonDirectory == secondResolution.identity.commonDirectory)
        #expect(firstResolution.identity.workTreeRoot != secondResolution.identity.workTreeRoot)
        #expect(
            resolver.trustDescriptor(for: firstResolution)?.fingerprint
                == resolver.trustDescriptor(for: secondResolution)?.fingerprint
        )
    }

    @Test func changingAProjectScriptInvalidatesItsTrustFingerprint() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try makeNormalRepository(at: root)
        let configURL = root.appendingPathComponent(".cmux/cmux.json")
        try writeConfig(#"{"scripts":{"setup":"pnpm install"}}"#, at: configURL)

        let resolver = RepositoryScriptResolver()
        let original = try #require(resolver.resolve(directory: root.path, preferences: []))
        let originalFingerprint = try #require(resolver.trustDescriptor(for: original)?.fingerprint)

        try writeConfig(#"{"scripts":{"setup":"pnpm install --frozen-lockfile"}}"#, at: configURL)
        let changed = try #require(resolver.resolve(directory: root.path, preferences: []))
        let changedFingerprint = try #require(resolver.trustDescriptor(for: changed)?.fingerprint)

        #expect(changedFingerprint != originalFingerprint)
    }

    @Test func setupLaunchLocationMapsToTheExpectedBonsplitRoute() {
        #expect(RepositorySetupLaunchPlan(location: .backgroundTab) == .backgroundTab)
        #expect(RepositorySetupLaunchPlan(location: .verticalSplit) == .split(.horizontal))
        #expect(RepositorySetupLaunchPlan(location: .horizontalSplit) == .split(.vertical))
    }

    @Test func archiveScriptUsesBoundedDiscardingCommandInvocation() async throws {
        let commands = RecordingRepositoryArchiveCommandRunner()
        let script = "printf 'cleanup output'\nprintf 'cleanup error' >&2"

        _ = await RepositoryArchiveScriptRunner(commands: commands).run(script, in: "/repo")

        let recorded = await commands.lastInvocation()
        let invocation = try #require(recorded)
        #expect(invocation.directory == "/repo")
        #expect(invocation.executable == "/bin/zsh")
        #expect(invocation.arguments.prefix(2) == ["-l", "-c"])
        let shellPayload = try #require(invocation.arguments.last)
        #expect(shellPayload != script)
        #expect(shellPayload.contains("/dev/null"))
        #expect(shellPayload.contains("2>&1"))
        #expect(shellPayload.contains(script))
        #expect(invocation.timeout == 300)
    }

    @Test func archiveScriptDiscardsOutputWithTheProductionCommandRunner() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let script = "printf 'cleanup output'\nprintf 'cleanup error' >&2"

        let result = await RepositoryArchiveScriptRunner(commands: CommandRunner()).run(
            script,
            in: root.path
        )

        #expect(result.executionError == nil)
        #expect(!result.timedOut)
        #expect(result.exitStatus == 0)
        #expect(result.stdout == "")
        #expect(result.stderr == "")
    }

    @MainActor
    @Test func savedCommandsJoinTheCommandPaletteModelAsTrustedGlobalCommands() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let configURL = root.appendingPathComponent("cmux.json")
        try writeConfig(
            #"{"terminal":{"savedCommands":[{"id":"bootstrap","name":"Bootstrap","command":"pnpm install\npnpm build"}]}}"#,
            at: configURL
        )

        let store = CmuxConfigStore(globalConfigPath: configURL.path, startFileWatchers: false)
        store.loadAll()

        let command = try #require(store.loadedCommands.first { $0.name == "Bootstrap" })
        #expect(command.command == "pnpm install\npnpm build")
        #expect(store.commandSourcePaths[command.id] == configURL.path)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-repository-scripts-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeNormalRepository(at root: URL) throws {
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(".git"),
            withIntermediateDirectories: true
        )
    }

    private func makeLinkedWorktree(at root: URL, gitDirectory: URL) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: gitDirectory, withIntermediateDirectories: true)
        try Data("gitdir: \(gitDirectory.path)\n".utf8).write(to: root.appendingPathComponent(".git"))
        try Data("../..\n".utf8).write(to: gitDirectory.appendingPathComponent("commondir"))
    }

    private func writeConfig(_ contents: String, at url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(contents.utf8).write(to: url)
    }
}

private actor RecordingRepositoryArchiveCommandRunner: CommandRunning {
    struct Invocation: Sendable {
        let directory: String
        let executable: String
        let arguments: [String]
        let timeout: TimeInterval?
    }

    private var invocation: Invocation?

    func lastInvocation() -> Invocation? {
        invocation
    }

    func run(
        directory: String,
        executable: String,
        arguments: [String],
        timeout: TimeInterval?
    ) async -> CommandResult {
        invocation = Invocation(
            directory: directory,
            executable: executable,
            arguments: arguments,
            timeout: timeout
        )
        return CommandResult(
            stdout: "ignored stdout",
            stderr: "ignored stderr",
            exitStatus: 0,
            timedOut: false,
            executionError: nil
        )
    }
}
