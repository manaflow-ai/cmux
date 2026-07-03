import CmuxSettings
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite(.serialized)
struct WorkspaceAutoColorUnitTests {
    private static let settingsFileBackupsDefaultsKey = "cmux.settingsFile.backups.v1"

    @Test
    func settingsFileStoreAppliesWorkspaceAutoColorFromCwd() throws {
        let defaultsFixture = try makeIsolatedDefaults()
        defer { defaultsFixture.defaults.removePersistentDomain(forName: defaultsFixture.suiteName) }
        let defaults = defaultsFixture.defaults
        let autoColorKey = SettingCatalog().workspaceColors.autoColorFromCwd.userDefaultsKey

        defaults.removeObject(forKey: autoColorKey)
        defaults.removeObject(forKey: Self.settingsFileBackupsDefaultsKey)

        let directoryURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let settingsFileURL = directoryURL.appendingPathComponent("cmux.json", isDirectory: false)
        try writeSettingsFile(
            """
            {
              "workspaceColors": {
                "autoColorFromCwd": true
              }
            }
            """,
            to: settingsFileURL
        )

        _ = KeyboardShortcutSettingsFileStore(
            primaryPath: settingsFileURL.path,
            fallbackPath: nil,
            userDefaults: defaults,
            startWatching: false
        )

        #expect(
            UserDefaultsSettingsClient(defaults: defaults)
                .value(for: SettingCatalog().workspaceColors.autoColorFromCwd)
        )

        let missingSettingsURL = directoryURL.appendingPathComponent("missing.json", isDirectory: false)
        _ = KeyboardShortcutSettingsFileStore(
            primaryPath: missingSettingsURL.path,
            fallbackPath: nil,
            userDefaults: defaults,
            startWatching: false
        )

        #expect(
            !UserDefaultsSettingsClient(defaults: defaults)
                .value(for: SettingCatalog().workspaceColors.autoColorFromCwd)
        )
    }

    @Test
    func autoColorUsesGithubRemoteSlugForStableRepoSeed() throws {
        let firstRepository = try makeGitRepository(remoteURL: "https://github.com/manaflow-ai/cmux.git")
        let secondRepository = try makeGitRepository(remoteURL: "git@github.com:manaflow-ai/cmux.git")
        defer {
            try? FileManager.default.removeItem(at: firstRepository)
            try? FileManager.default.removeItem(at: secondRepository)
        }

        let firstNested = firstRepository.appendingPathComponent("Sources/App", isDirectory: true)
        let secondNested = secondRepository.appendingPathComponent("subdir", isDirectory: true)
        try FileManager.default.createDirectory(at: firstNested, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secondNested, withIntermediateDirectories: true)

        #expect(
            WorkspaceTabColorSettings.autoColorSeed(forWorkingDirectory: firstNested.path)
                == "github:manaflow-ai/cmux"
        )
        #expect(
            WorkspaceTabColorSettings.autoColorHex(forWorkingDirectory: firstNested.path)
                == WorkspaceTabColorSettings.autoColorHex(forWorkingDirectory: secondNested.path)
        )
        let hex = try #require(WorkspaceTabColorSettings.autoColorHex(forWorkingDirectory: firstNested.path))
        #expect(WorkspaceTabColorSettings.normalizedHex(hex) != nil)
    }

    @Test
    func autoColorUsesGitRootForNestedDirectoriesWithoutRemote() throws {
        let repository = try makeGitRepository(remoteURL: nil)
        defer { try? FileManager.default.removeItem(at: repository) }

        let nested = repository.appendingPathComponent("packages/app", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)

        #expect(
            WorkspaceTabColorSettings.autoColorHex(forWorkingDirectory: repository.path)
                == WorkspaceTabColorSettings.autoColorHex(forWorkingDirectory: nested.path)
        )
        #expect(
            WorkspaceTabColorSettings.autoColorSeed(forWorkingDirectory: nested.path)?.hasPrefix("git:") == true
        )
    }

    @Test @MainActor
    func autoColorFromCwdAppliesToInitialAndCreatedWorkspaces() async throws {
        let defaultsFixture = try makeIsolatedDefaults()
        defer { defaultsFixture.defaults.removePersistentDomain(forName: defaultsFixture.suiteName) }
        let settings = UserDefaultsSettingsClient(defaults: defaultsFixture.defaults)
        settings.set(true, for: SettingCatalog().workspaceColors.autoColorFromCwd)

        let repository = try makeGitRepository(remoteURL: "https://github.com/manaflow-ai/cmux.git")
        defer { try? FileManager.default.removeItem(at: repository) }
        let nested = repository.appendingPathComponent("Sources", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let expected = try #require(WorkspaceTabColorSettings.autoColorHex(forWorkingDirectory: nested.path))

        let manager = TabManager(
            initialWorkingDirectory: nested.path,
            autoWelcomeIfNeeded: false,
            settings: settings
        )

        let initial = try #require(manager.tabs.first)
        await waitForAutoColor(expected, on: initial)
        let added = manager.addWorkspace(
            workingDirectory: nested.path,
            select: false,
            autoWelcomeIfNeeded: false
        )
        await waitForAutoColor(expected, on: added)
    }

    @Test @MainActor
    func autoColorFromCwdIsOptInAndManualColorsStillWin() async throws {
        let defaultsFixture = try makeIsolatedDefaults()
        defer { defaultsFixture.defaults.removePersistentDomain(forName: defaultsFixture.suiteName) }
        let settings = UserDefaultsSettingsClient(defaults: defaultsFixture.defaults)

        let repository = try makeGitRepository(remoteURL: "https://github.com/manaflow-ai/cmux.git")
        defer { try? FileManager.default.removeItem(at: repository) }

        let disabledManager = TabManager(
            initialWorkingDirectory: repository.path,
            autoWelcomeIfNeeded: false,
            settings: settings
        )
        #expect(disabledManager.tabs.first?.customColor == nil)

        settings.set(true, for: SettingCatalog().workspaceColors.autoColorFromCwd)
        let enabledManager = TabManager(
            initialWorkingDirectory: repository.path,
            autoWelcomeIfNeeded: false,
            settings: settings
        )
        let workspace = try #require(enabledManager.tabs.first)
        let expected = try #require(WorkspaceTabColorSettings.autoColorHex(forWorkingDirectory: repository.path))
        await waitForAutoColor(expected, on: workspace)

        workspace.setCustomColor("#C0392B")
        #expect(workspace.customColor == "#C0392B")
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func writeSettingsFile(_ content: String, to url: URL) throws {
        try content.write(to: url, atomically: true, encoding: .utf8)
    }

    private func makeGitRepository(remoteURL: String?) throws -> URL {
        let repository = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let gitDirectory = repository.appendingPathComponent(".git", isDirectory: true)
        try FileManager.default.createDirectory(at: gitDirectory, withIntermediateDirectories: true)
        if let remoteURL {
            try """
            [remote "origin"]
                url = \(remoteURL)
            """.write(
                to: gitDirectory.appendingPathComponent("config", isDirectory: false),
                atomically: true,
                encoding: .utf8
            )
        }
        return repository
    }

    private func makeIsolatedDefaults() throws -> (suiteName: String, defaults: UserDefaults) {
        let suiteName = "WorkspaceAutoColorUnitTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return (suiteName, defaults)
    }

    @MainActor
    private func waitForAutoColor(
        _ expected: String,
        on workspace: Workspace,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async {
        // The color is applied asynchronously after an off-main probe, so poll
        // the published value (up to ~2s) instead of using XCTest expectations.
        for _ in 0..<200 {
            if workspace.customColor == expected { break }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(workspace.customColor == expected, sourceLocation: sourceLocation)
    }
}
