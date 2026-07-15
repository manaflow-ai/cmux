import AppKit
import CmuxFoundation
import CmuxSettings
import CmuxSettingsUI
import CryptoKit
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

    @Test func projectScriptsResolveWithPrivateSettingsPrecedenceAndTrustBoundary() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try makeNormalRepository(at: root)
        try writeConfig(
            #"{"scripts":{"setup":"pnpm install","archive":"pnpm clean"}}"#,
            at: root.appendingPathComponent(".cmux/cmux.json")
        )

        let resolver = RepositoryScriptResolver()
        let project = try #require(await resolver.resolve(directory: root.path, preferences: []))
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
        let overridden = try #require(await resolver.resolve(directory: root.path, preferences: [preference]))
        #expect(overridden.setup == "mise install")
        #expect(overridden.archive == "mise prune")
        #expect(overridden.projectScripts.setup == "pnpm install")
        #expect(overridden.source == .userSettings)
        #expect(resolver.trustDescriptor(for: overridden) == nil)
    }

    @Test func scopedConfigWinsOverLegacyRootConfig() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try makeNormalRepository(at: root)
        try writeConfig(#"{"scripts":{"setup":"legacy"}}"#, at: root.appendingPathComponent("cmux.json"))
        let scopedURL = root.appendingPathComponent(".cmux/cmux.json")
        try writeConfig(#"{"scripts":{"setup":"scoped"}}"#, at: scopedURL)

        let resolver = RepositoryScriptResolver()
        #expect(await resolver.resolve(directory: root.path, preferences: [])?.setup == "scoped")

        try FileManager.default.removeItem(at: scopedURL)
        #expect(await resolver.resolve(directory: root.path, preferences: [])?.setup == "legacy")
    }

    @Test func linkedWorktreesShareRepositoryIdentityButRequireSeparateTrust() async throws {
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
        let firstResolution = try #require(await resolver.resolve(directory: first.path, preferences: []))
        let secondResolution = try #require(await resolver.resolve(directory: second.path, preferences: []))
        #expect(firstResolution.identity.id == secondResolution.identity.id)
        #expect(firstResolution.identity.commonDirectory == secondResolution.identity.commonDirectory)
        #expect(firstResolution.identity.workTreeRoot != secondResolution.identity.workTreeRoot)
        #expect(
            resolver.trustDescriptor(for: firstResolution)?.fingerprint
                != resolver.trustDescriptor(for: secondResolution)?.fingerprint
        )
    }

    @MainActor
    @Test func settingsSaveStaysBoundToTheDisplayedRepository() async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let root = try makeTemporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let first = root.appendingPathComponent("first")
            let second = root.appendingPathComponent("second")
            try makeNormalRepository(at: first)
            try makeNormalRepository(at: second)

            let suiteName = "cmux.repository-script-settings.\(UUID().uuidString)"
            let defaults = try #require(UserDefaults(suiteName: suiteName))
            defer { defaults.removePersistentDomain(forName: suiteName) }
            let catalog = SettingCatalog()
            let configURL = root.appendingPathComponent("cmux.json")
            let jsonStore = JSONConfigStore(fileURL: configURL)
            let hostActions = HostSettingsActions(configFileURL: configURL)
            let runtime = SettingsRuntime(
                catalog: catalog,
                userDefaultsStore: UserDefaultsSettingsStore(defaults: defaults),
                jsonStore: jsonStore,
                secretStore: SecretFileStore(baseDirectory: root.appendingPathComponent("secrets")),
                errorLog: SettingsErrorLog(),
                hostActions: hostActions
            )

            let previousAppDelegate = AppDelegate.shared
            let appDelegate = AppDelegate()
            defer { AppDelegate.shared = previousAppDelegate }
            appDelegate.settingsRuntime = runtime
            let manager = TabManager(
                initialWorkingDirectory: first.path,
                autoWelcomeIfNeeded: false
            )
            appDelegate.tabManager = manager
            let windowID = appDelegate.registerMainWindowContextForTesting(tabManager: manager)
            let window = NSWindow()
            let registeredContext = try #require(
                appDelegate.mainWindowContexts.values.first { $0.windowId == windowID }
            )
            registeredContext.window = window
            manager.window = window
            defer { appDelegate.unregisterMainWindowContextForTesting(windowId: windowID) }

            let resolver = RepositoryScriptResolver()
            let firstResolution = try #require(
                await resolver.resolve(directory: first.path, preferences: [])
            )
            let secondID = try #require(
                await resolver.resolve(directory: second.path, preferences: [])?.identity.id
            )
            try await jsonStore.set([
                RepositoryScriptPreference(
                    repositoryID: firstResolution.identity.id,
                    repositoryRoot: firstResolution.identity.workTreeRoot,
                    archive: "echo old",
                    overridesProjectScripts: true,
                    promptDismissed: true
                ),
            ], for: catalog.terminal.repositoryScripts)

            let displayed = try #require(await hostActions.repositoryScriptSettingsContext())
            #expect(displayed.repositoryRoot == first.resolvingSymlinksInPath().path)

            _ = manager.addWorkspace(
                workingDirectory: second.path,
                inheritWorkingDirectory: false,
                select: true,
                autoWelcomeIfNeeded: false,
                autoRefreshMetadata: false,
                runRepositoryScripts: false
            )
            #expect(manager.selectedWorkspace?.currentDirectory == second.path)
            let updated = await hostActions.saveRepositoryScripts(
                context: displayed,
                setup: "",
                archive: "echo first"
            )
            #expect(updated?.repositoryID == displayed.repositoryID)

            let preferences = await jsonStore.value(for: catalog.terminal.repositoryScripts)
            let firstPreference = try #require(
                preferences.first { $0.repositoryID == firstResolution.identity.id }
            )
            #expect(firstPreference.archive == "echo first")
            #expect(firstPreference.promptDismissed)
            #expect(!preferences.contains { $0.repositoryID == secondID })
        }
    }

    @Test func repositoryIdentityUsesStableLowercaseSHA256Encoding() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try makeNormalRepository(at: root)

        let resolution = try #require(
            await RepositoryScriptResolver().resolve(directory: root.path, preferences: [])
        )
        let digits = Array("0123456789abcdef".utf8)
        var expectedBytes: [UInt8] = []
        expectedBytes.reserveCapacity(64)
        for byte in SHA256.hash(data: Data(resolution.identity.commonDirectory.utf8)) {
            expectedBytes.append(digits[Int(byte >> 4)])
            expectedBytes.append(digits[Int(byte & 0x0f)])
        }

        #expect(resolution.identity.id == String(decoding: expectedBytes, as: UTF8.self))
    }

    @Test func changingAProjectScriptInvalidatesItsTrustFingerprint() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try makeNormalRepository(at: root)
        let configURL = root.appendingPathComponent(".cmux/cmux.json")
        try writeConfig(#"{"scripts":{"setup":"pnpm install"}}"#, at: configURL)

        let resolver = RepositoryScriptResolver()
        let original = try #require(await resolver.resolve(directory: root.path, preferences: []))
        let originalFingerprint = try #require(resolver.trustDescriptor(for: original)?.fingerprint)

        try writeConfig(#"{"scripts":{"setup":"pnpm install --frozen-lockfile"}}"#, at: configURL)
        let changed = try #require(await resolver.resolve(directory: root.path, preferences: []))
        let changedFingerprint = try #require(resolver.trustDescriptor(for: changed)?.fingerprint)

        #expect(changedFingerprint != originalFingerprint)
    }

    @Test func setupLaunchLocationMapsToTheExpectedBonsplitRoute() {
        #expect(RepositorySetupLaunchPlan(location: .backgroundTab) == .backgroundTab)
        #expect(RepositorySetupLaunchPlan(location: .verticalSplit) == .split(.horizontal))
        #expect(RepositorySetupLaunchPlan(location: .horizontalSplit) == .split(.vertical))
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

    @MainActor
    @Test func savedCommandSettingsChangesReloadTheCurrentCommandPalette() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let configURL = root.appendingPathComponent("cmux.json")
        try writeConfig("{}", at: configURL)
        let settingsStore = JSONConfigStore(fileURL: configURL)
        let catalog = SettingCatalog()
        let store = CmuxConfigStore(
            globalConfigPath: configURL.path,
            startFileWatchers: false,
            terminalScriptSettingsStore: settingsStore,
            settingCatalog: catalog
        )
        store.loadAll()
        #expect(store.loadedCommands.isEmpty)

        try await settingsStore.set(
            SavedTerminalCommandLibrary(commands: [
                SavedTerminalCommand(id: "bootstrap", name: "Bootstrap", command: "pnpm install"),
            ]),
            for: catalog.terminal.savedCommands
        )
        #expect(await waitForLoadedCommandNames(["Bootstrap"], in: store))

        try await settingsStore.set(
            SavedTerminalCommandLibrary(),
            for: catalog.terminal.savedCommands
        )
        #expect(await waitForLoadedCommandNames([], in: store))
    }

    @MainActor
    private func waitForLoadedCommandNames(
        _ expected: [String],
        in store: CmuxConfigStore
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while clock.now < deadline {
            if store.loadedCommands.map(\.name) == expected { return true }
            try? await clock.sleep(for: .milliseconds(10))
        }
        return store.loadedCommands.map(\.name) == expected
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

struct RepositoryScriptSafetyTests {
    @Test func oversizedProjectConfigIsIgnored() async throws {
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
            await RepositoryScriptResolver().resolve(directory: root.path, preferences: [])
        )

        #expect(resolution.setup == nil)
        #expect(resolution.projectScripts.isEmpty)
        #expect(resolution.source == .none)
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

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-repository-script-safety-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeNormalRepository(at root: URL) throws {
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(".git"),
            withIntermediateDirectories: true
        )
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
