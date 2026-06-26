import CmuxSettings
import Foundation
import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class WorkspaceAutoColorUnitTests: XCTestCase {
    private let settingsFileBackupsDefaultsKey = "cmux.settingsFile.backups.v1"

    func testSettingsFileStoreAppliesWorkspaceAutoColorFromCwd() throws {
        let defaults = UserDefaults.standard
        let autoColorKey = SettingCatalog().workspaceColors.autoColorFromCwd.userDefaultsKey
        let previousAutoColor = defaults.object(forKey: autoColorKey)
        let previousBackups = defaults.data(forKey: settingsFileBackupsDefaultsKey)
        defer {
            if let previousAutoColor {
                defaults.set(previousAutoColor, forKey: autoColorKey)
            } else {
                defaults.removeObject(forKey: autoColorKey)
            }
            if let previousBackups {
                defaults.set(previousBackups, forKey: settingsFileBackupsDefaultsKey)
            } else {
                defaults.removeObject(forKey: settingsFileBackupsDefaultsKey)
            }
        }

        defaults.removeObject(forKey: autoColorKey)
        defaults.removeObject(forKey: settingsFileBackupsDefaultsKey)

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
            startWatching: false
        )

        XCTAssertTrue(
            UserDefaultsSettingsClient(defaults: defaults)
                .value(for: SettingCatalog().workspaceColors.autoColorFromCwd)
        )

        let missingSettingsURL = directoryURL.appendingPathComponent("missing.json", isDirectory: false)
        _ = KeyboardShortcutSettingsFileStore(
            primaryPath: missingSettingsURL.path,
            fallbackPath: nil,
            startWatching: false
        )

        XCTAssertFalse(
            UserDefaultsSettingsClient(defaults: defaults)
                .value(for: SettingCatalog().workspaceColors.autoColorFromCwd)
        )
    }

    func testAutoColorUsesGithubRemoteSlugForStableRepoSeed() throws {
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

        XCTAssertEqual(
            WorkspaceTabColorSettings.autoColorSeed(forWorkingDirectory: firstNested.path),
            "github:manaflow-ai/cmux"
        )
        XCTAssertEqual(
            WorkspaceTabColorSettings.autoColorHex(forWorkingDirectory: firstNested.path),
            WorkspaceTabColorSettings.autoColorHex(forWorkingDirectory: secondNested.path)
        )
        XCTAssertNotNil(
            WorkspaceTabColorSettings.normalizedHex(
                try XCTUnwrap(WorkspaceTabColorSettings.autoColorHex(forWorkingDirectory: firstNested.path))
            )
        )
    }

    func testAutoColorUsesGitRootForNestedDirectoriesWithoutRemote() throws {
        let repository = try makeGitRepository(remoteURL: nil)
        defer { try? FileManager.default.removeItem(at: repository) }

        let nested = repository.appendingPathComponent("packages/app", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)

        XCTAssertEqual(
            WorkspaceTabColorSettings.autoColorHex(forWorkingDirectory: repository.path),
            WorkspaceTabColorSettings.autoColorHex(forWorkingDirectory: nested.path)
        )
        XCTAssertTrue(
            WorkspaceTabColorSettings.autoColorSeed(forWorkingDirectory: nested.path)?.hasPrefix("git:") == true
        )
    }

    @MainActor
    func testAutoColorFromCwdAppliesToInitialAndCreatedWorkspaces() throws {
        let defaultsFixture = try makeIsolatedDefaults()
        defer { defaultsFixture.defaults.removePersistentDomain(forName: defaultsFixture.suiteName) }
        let settings = UserDefaultsSettingsClient(defaults: defaultsFixture.defaults)
        settings.set(true, for: SettingCatalog().workspaceColors.autoColorFromCwd)

        let repository = try makeGitRepository(remoteURL: "https://github.com/manaflow-ai/cmux.git")
        defer { try? FileManager.default.removeItem(at: repository) }
        let nested = repository.appendingPathComponent("Sources", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let expected = try XCTUnwrap(WorkspaceTabColorSettings.autoColorHex(forWorkingDirectory: nested.path))

        let manager = TabManager(
            initialWorkingDirectory: nested.path,
            autoWelcomeIfNeeded: false,
            settings: settings
        )

        XCTAssertEqual(manager.tabs.first?.customColor, expected)
        let added = manager.addWorkspace(
            workingDirectory: nested.path,
            select: false,
            autoWelcomeIfNeeded: false
        )
        XCTAssertEqual(added.customColor, expected)
    }

    @MainActor
    func testAutoColorFromCwdIsOptInAndManualColorsStillWin() throws {
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
        XCTAssertNil(disabledManager.tabs.first?.customColor)

        settings.set(true, for: SettingCatalog().workspaceColors.autoColorFromCwd)
        let enabledManager = TabManager(
            initialWorkingDirectory: repository.path,
            autoWelcomeIfNeeded: false,
            settings: settings
        )
        let workspace = try XCTUnwrap(enabledManager.tabs.first)
        XCTAssertNotNil(workspace.customColor)

        workspace.setCustomColor("#C0392B")
        XCTAssertEqual(workspace.customColor, "#C0392B")
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
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return (suiteName, defaults)
    }
}
