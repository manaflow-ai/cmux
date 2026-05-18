import XCTest
import Foundation

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class GhosttyConfigPathResolverTests: XCTestCase {
    func testCmuxAppSupportConfigURLsUseReleaseConfigForDebugBundleWithoutCurrentConfig() throws {
        try withTemporaryAppSupportDirectory { appSupportDirectory in
            let releaseConfigURL = try writeAppSupportConfig(
                appSupportDirectory: appSupportDirectory,
                bundleIdentifier: "com.cmuxterm.app",
                filename: "config",
                contents: "font-size = 13\n"
            )

            XCTAssertEqual(
                GhosttyApp.cmuxAppSupportConfigURLs(
                    currentBundleIdentifier: "com.cmuxterm.app.debug",
                    appSupportDirectory: appSupportDirectory
                ),
                [releaseConfigURL]
            )
        }
    }

    func testCmuxAppSupportConfigURLsPreferConfigGhosttyOverLegacyConfigWhenBothExist() throws {
        try withTemporaryAppSupportDirectory { appSupportDirectory in
            _ = try writeAppSupportConfig(
                appSupportDirectory: appSupportDirectory,
                bundleIdentifier: "com.cmuxterm.app",
                filename: "config",
                contents: "background = #000000\n"
            )
            let preferredConfigURL = try writeAppSupportConfig(
                appSupportDirectory: appSupportDirectory,
                bundleIdentifier: "com.cmuxterm.app",
                filename: "config.ghostty",
                contents: "theme = light:3024 Day,dark:3024 Night\n"
            )

            XCTAssertEqual(
                GhosttyApp.cmuxAppSupportConfigURLs(
                    currentBundleIdentifier: "com.cmuxterm.app.debug.issue-3478",
                    appSupportDirectory: appSupportDirectory
                ),
                [preferredConfigURL]
            )
        }
    }

    func testCmuxAppSupportConfigURLsPreferCurrentBundleConfigWhenPresent() throws {
        try withTemporaryAppSupportDirectory { appSupportDirectory in
            _ = try writeAppSupportConfig(
                appSupportDirectory: appSupportDirectory,
                bundleIdentifier: "com.cmuxterm.app",
                filename: "config",
                contents: "font-size = 13\n"
            )
            let currentConfigURL = try writeAppSupportConfig(
                appSupportDirectory: appSupportDirectory,
                bundleIdentifier: "com.cmuxterm.app.debug.issue-829",
                filename: "config.ghostty",
                contents: "font-size = 14\n"
            )

            XCTAssertEqual(
                GhosttyApp.cmuxAppSupportConfigURLs(
                    currentBundleIdentifier: "com.cmuxterm.app.debug.issue-829",
                    appSupportDirectory: appSupportDirectory
                ),
                [currentConfigURL]
            )
        }
    }

    func testCmuxAppSupportConfigURLsPreserveSymlinkedConfigURL() throws {
        try withTemporaryAppSupportDirectory { appSupportDirectory in
            let fileManager = FileManager.default
            let bundleDirectory = appSupportDirectory
                .appendingPathComponent("com.cmuxterm.app.debug.issue-3518", isDirectory: true)
            try fileManager.createDirectory(at: bundleDirectory, withIntermediateDirectories: true)

            let dotfilesDirectory = appSupportDirectory
                .appendingPathComponent("dotfiles", isDirectory: true)
                .appendingPathComponent("ghostty", isDirectory: true)
            try fileManager.createDirectory(at: dotfilesDirectory, withIntermediateDirectories: true)
            let targetConfigURL = dotfilesDirectory.appendingPathComponent("config.ghostty", isDirectory: false)
            try "font-size = 16\n".write(to: targetConfigURL, atomically: true, encoding: .utf8)

            let symlinkedConfigURL = bundleDirectory.appendingPathComponent("config.ghostty", isDirectory: false)
            try fileManager.createSymbolicLink(
                atPath: symlinkedConfigURL.path,
                withDestinationPath: targetConfigURL.path
            )

            XCTAssertEqual(
                GhosttyApp.cmuxAppSupportConfigURLs(
                    currentBundleIdentifier: "com.cmuxterm.app.debug.issue-3518",
                    appSupportDirectory: appSupportDirectory
                ),
                [symlinkedConfigURL]
            )
        }
    }

    func testConfigSourceEnvironmentSaveWritesThroughSymlinkedCmuxConfig() throws {
        try withTemporaryHomeDirectory { homeDirectory in
            let fileManager = FileManager.default
            let appSupportDirectory = homeDirectory
                .appendingPathComponent("Library", isDirectory: true)
                .appendingPathComponent("Application Support", isDirectory: true)
            let bundleDirectory = appSupportDirectory
                .appendingPathComponent("com.cmuxterm.app.debug.issue-3518", isDirectory: true)
            try fileManager.createDirectory(at: bundleDirectory, withIntermediateDirectories: true)

            let dotfilesDirectory = homeDirectory
                .appendingPathComponent("dotfiles", isDirectory: true)
                .appendingPathComponent("ghostty", isDirectory: true)
            try fileManager.createDirectory(at: dotfilesDirectory, withIntermediateDirectories: true)
            let targetConfigURL = dotfilesDirectory.appendingPathComponent("config.ghostty", isDirectory: false)
            try "font-size = 16\n".write(to: targetConfigURL, atomically: true, encoding: .utf8)

            let symlinkedConfigURL = bundleDirectory.appendingPathComponent("config.ghostty", isDirectory: false)
            try fileManager.createSymbolicLink(
                atPath: symlinkedConfigURL.path,
                withDestinationPath: targetConfigURL.path
            )

            let environment = ConfigSourceEnvironment(
                homeDirectoryURL: homeDirectory,
                currentBundleIdentifier: "com.cmuxterm.app.debug.issue-3518"
            )
            try environment.writeCmuxConfigContents("theme = light:Andromeda,dark:3024 Day\n")

            XCTAssertEqual(
                try String(contentsOf: targetConfigURL, encoding: .utf8),
                "theme = light:Andromeda,dark:3024 Day\n"
            )
            XCTAssertEqual(
                try symlinkedConfigURL.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink,
                true
            )
            XCTAssertEqual(environment.cmuxConfigURL, symlinkedConfigURL)
        }
    }

    func testMaterializeWritesSelectedEditableConfigWhenLegacyConfigAppearsDuringCheck() throws {
        try withTemporaryHomeDirectory { homeDirectory in
            let fileManager = RaceCreatingFileManager()
            let appSupportDirectory = homeDirectory
                .appendingPathComponent("Library", isDirectory: true)
                .appendingPathComponent("Application Support", isDirectory: true)
            let bundleDirectory = appSupportDirectory
                .appendingPathComponent("com.cmuxterm.app.debug.issue-3518", isDirectory: true)
            let configGhosttyURL = bundleDirectory.appendingPathComponent("config.ghostty", isDirectory: false)
            let legacyConfigURL = bundleDirectory.appendingPathComponent("config", isDirectory: false)

            fileManager.onFirstMissingPlainExistenceCheck = { path in
                guard path == configGhosttyURL.path else { return }
                try FileManager.default.createDirectory(at: bundleDirectory, withIntermediateDirectories: true)
                try "background = #000000\n".write(to: legacyConfigURL, atomically: true, encoding: .utf8)
            }

            let environment = ConfigSourceEnvironment(
                homeDirectoryURL: homeDirectory,
                currentBundleIdentifier: "com.cmuxterm.app.debug.issue-3518",
                fileManager: fileManager
            )

            let materializedURL = try environment.materializeCmuxConfigFileIfNeeded()

            XCTAssertEqual(materializedURL, configGhosttyURL)
            XCTAssertTrue(FileManager.default.fileExists(atPath: configGhosttyURL.path))
            XCTAssertEqual(try String(contentsOf: configGhosttyURL, encoding: .utf8), "")
            XCTAssertEqual(try String(contentsOf: legacyConfigURL, encoding: .utf8), "background = #000000\n")
            XCTAssertNil(fileManager.creationError)
        }
    }

    func testSyncedConfigPreviewIncludesSymlinkedStandaloneGhosttyConfig() throws {
        try withTemporaryHomeDirectory { homeDirectory in
            let fileManager = FileManager.default
            let ghosttyConfigDirectory = homeDirectory
                .appendingPathComponent(".config", isDirectory: true)
                .appendingPathComponent("ghostty", isDirectory: true)
            try fileManager.createDirectory(at: ghosttyConfigDirectory, withIntermediateDirectories: true)

            let dotfilesDirectory = homeDirectory
                .appendingPathComponent("dotfiles", isDirectory: true)
                .appendingPathComponent("ghostty", isDirectory: true)
            try fileManager.createDirectory(at: dotfilesDirectory, withIntermediateDirectories: true)
            let targetConfigURL = dotfilesDirectory.appendingPathComponent("config", isDirectory: false)
            try "font-size = 17\n".write(to: targetConfigURL, atomically: true, encoding: .utf8)

            let symlinkedConfigURL = ghosttyConfigDirectory.appendingPathComponent("config", isDirectory: false)
            try fileManager.createSymbolicLink(
                atPath: symlinkedConfigURL.path,
                withDestinationPath: targetConfigURL.path
            )

            let snapshot = ConfigSource.synced.snapshot(
                environment: ConfigSourceEnvironment(
                    homeDirectoryURL: homeDirectory,
                    currentBundleIdentifier: "com.cmuxterm.app"
                )
            )

            XCTAssertTrue(snapshot.hasStandaloneGhosttyConfig)
            XCTAssertTrue(snapshot.contents.contains("font-size = 17"))
            XCTAssertEqual(snapshot.displayPaths, [
                homeDirectory
                    .appendingPathComponent("Library", isDirectory: true)
                    .appendingPathComponent("Application Support", isDirectory: true)
                    .appendingPathComponent("com.cmuxterm.app", isDirectory: true)
                    .appendingPathComponent("config.synced-preview", isDirectory: false)
                    .path,
            ])
        }
    }

    func testCmuxAppSupportConfigURLsUseNightlyConfigWhenPresent() throws {
        try withTemporaryAppSupportDirectory { appSupportDirectory in
            _ = try writeAppSupportConfig(
                appSupportDirectory: appSupportDirectory,
                bundleIdentifier: "com.cmuxterm.app",
                filename: "config.ghostty",
                contents: "font-size = 13\n"
            )
            let nightlyConfigURL = try writeAppSupportConfig(
                appSupportDirectory: appSupportDirectory,
                bundleIdentifier: "com.cmuxterm.app.nightly",
                filename: "config.ghostty",
                contents: "font-size = 15\n"
            )

            XCTAssertEqual(
                GhosttyApp.cmuxAppSupportConfigURLs(
                    currentBundleIdentifier: "com.cmuxterm.app.nightly",
                    appSupportDirectory: appSupportDirectory
                ),
                [nightlyConfigURL]
            )
        }
    }

    func testCmuxAppSupportConfigURLsUseReleaseConfigForNightlyWithoutCurrentConfig() throws {
        try withTemporaryAppSupportDirectory { appSupportDirectory in
            let releaseConfigURL = try writeAppSupportConfig(
                appSupportDirectory: appSupportDirectory,
                bundleIdentifier: "com.cmuxterm.app",
                filename: "config.ghostty",
                contents: "font-size = 13\n"
            )

            XCTAssertEqual(
                GhosttyApp.cmuxAppSupportConfigURLs(
                    currentBundleIdentifier: "com.cmuxterm.app.nightly",
                    appSupportDirectory: appSupportDirectory
                ),
                [releaseConfigURL]
            )
        }
    }

    func testCmuxAppSupportConfigURLsUseStagingConfigWhenPresent() throws {
        try withTemporaryAppSupportDirectory { appSupportDirectory in
            _ = try writeAppSupportConfig(
                appSupportDirectory: appSupportDirectory,
                bundleIdentifier: "com.cmuxterm.app",
                filename: "config.ghostty",
                contents: "font-size = 13\n"
            )
            let stagingConfigURL = try writeAppSupportConfig(
                appSupportDirectory: appSupportDirectory,
                bundleIdentifier: "com.cmuxterm.app.staging",
                filename: "config.ghostty",
                contents: "font-size = 15\n"
            )

            XCTAssertEqual(
                GhosttyApp.cmuxAppSupportConfigURLs(
                    currentBundleIdentifier: "com.cmuxterm.app.staging",
                    appSupportDirectory: appSupportDirectory
                ),
                [stagingConfigURL]
            )
        }
    }

    func testCmuxAppSupportConfigURLsUseReleaseConfigForStagingWithoutCurrentConfig() throws {
        try withTemporaryAppSupportDirectory { appSupportDirectory in
            let releaseConfigURL = try writeAppSupportConfig(
                appSupportDirectory: appSupportDirectory,
                bundleIdentifier: "com.cmuxterm.app",
                filename: "config.ghostty",
                contents: "font-size = 13\n"
            )

            XCTAssertEqual(
                GhosttyApp.cmuxAppSupportConfigURLs(
                    currentBundleIdentifier: "com.cmuxterm.app.staging",
                    appSupportDirectory: appSupportDirectory
                ),
                [releaseConfigURL]
            )
        }
    }

    func testLoadedGhosttyConfigScanPathsOmitsReleaseLegacyConfigWhenPreferredConfigGhosttyExists() throws {
        try withTemporaryAppSupportDirectory { appSupportDirectory in
            let legacyConfigURL = try writeAppSupportConfig(
                appSupportDirectory: appSupportDirectory,
                bundleIdentifier: "com.cmuxterm.app",
                filename: "config",
                contents: "background = #000000\n"
            )
            let preferredConfigURL = try writeAppSupportConfig(
                appSupportDirectory: appSupportDirectory,
                bundleIdentifier: "com.cmuxterm.app",
                filename: "config.ghostty",
                contents: "theme = light:3024 Day,dark:3024 Night\n"
            )

            let paths = GhosttyApp.loadedGhosttyConfigScanPaths(
                currentBundleIdentifier: "com.cmuxterm.app.debug.issue-3478",
                appSupportDirectory: appSupportDirectory
            )

            XCTAssertTrue(paths.contains(preferredConfigURL.path))
            XCTAssertFalse(paths.contains(legacyConfigURL.path))
        }
    }

    func testCmuxAppSupportConfigURLsSkipReleaseFallbackForNonDebugBundle() throws {
        try withTemporaryAppSupportDirectory { appSupportDirectory in
            _ = try writeAppSupportConfig(
                appSupportDirectory: appSupportDirectory,
                bundleIdentifier: "com.cmuxterm.app",
                filename: "config",
                contents: "font-size = 13\n"
            )

            XCTAssertTrue(
                GhosttyApp.cmuxAppSupportConfigURLs(
                    currentBundleIdentifier: "com.example.other-app",
                    appSupportDirectory: appSupportDirectory
                ).isEmpty
            )
        }
    }

    func testCmuxConfigPathResolverOpensLegacyConfigWhenConfigGhosttyIsEmpty() throws {
        try withTemporaryAppSupportDirectory { appSupportDirectory in
            let legacyConfigURL = try writeAppSupportConfig(
                appSupportDirectory: appSupportDirectory,
                bundleIdentifier: "com.cmuxterm.app",
                filename: "config",
                contents: "background = #000000\n"
            )
            _ = try writeAppSupportConfig(
                appSupportDirectory: appSupportDirectory,
                bundleIdentifier: "com.cmuxterm.app",
                filename: "config.ghostty",
                contents: ""
            )

            XCTAssertEqual(
                CmuxGhosttyConfigPathResolver.activeOrEditableConfigURL(
                    currentBundleIdentifier: "com.cmuxterm.app",
                    appSupportDirectory: appSupportDirectory
                ),
                legacyConfigURL
            )
        }
    }

    func testCmuxConfigPathResolverTargetsCurrentConfigGhosttyWhenNoActiveConfigExists() throws {
        try withTemporaryAppSupportDirectory { appSupportDirectory in
            let expectedURL = appSupportDirectory
                .appendingPathComponent("com.cmuxterm.app.debug.issue-3518", isDirectory: true)
                .appendingPathComponent("config.ghostty", isDirectory: false)

            XCTAssertEqual(
                CmuxGhosttyConfigPathResolver.activeOrEditableConfigURL(
                    currentBundleIdentifier: "com.cmuxterm.app.debug.issue-3518",
                    appSupportDirectory: appSupportDirectory
                ),
                expectedURL
            )
        }
    }

    func testCmuxAppSupportConfigURLsIgnoreMissingOrEmptyFiles() throws {
        try withTemporaryAppSupportDirectory { appSupportDirectory in
            _ = try writeAppSupportConfig(
                appSupportDirectory: appSupportDirectory,
                bundleIdentifier: "com.cmuxterm.app",
                filename: "config.ghostty",
                contents: ""
            )

            XCTAssertTrue(
                GhosttyApp.cmuxAppSupportConfigURLs(
                    currentBundleIdentifier: "com.cmuxterm.app.debug",
                    appSupportDirectory: appSupportDirectory
                ).isEmpty
            )
        }
    }

    private func withTemporaryAppSupportDirectory(
        _ body: (URL) throws -> Void
    ) throws {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-app-support-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: directory) }
        try body(directory)
    }

    private func withTemporaryHomeDirectory(
        _ body: (URL) throws -> Void
    ) throws {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-home-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: directory) }
        try body(directory)
    }

    private func writeAppSupportConfig(
        appSupportDirectory: URL,
        bundleIdentifier: String,
        filename: String,
        contents: String
    ) throws -> URL {
        let fileManager = FileManager.default
        let bundleDirectory = appSupportDirectory
            .appendingPathComponent(bundleIdentifier, isDirectory: true)
        try fileManager.createDirectory(at: bundleDirectory, withIntermediateDirectories: true)

        let configURL = bundleDirectory.appendingPathComponent(filename, isDirectory: false)
        try contents.write(to: configURL, atomically: true, encoding: .utf8)
        return configURL
    }

    private final class RaceCreatingFileManager: FileManager {
        var onFirstMissingPlainExistenceCheck: ((String) throws -> Void)?
        var creationError: Error?
        private var hasRunPlainExistenceHook = false

        override func fileExists(atPath path: String) -> Bool {
            let exists = super.fileExists(atPath: path)
            guard !exists, !hasRunPlainExistenceHook else {
                return exists
            }
            hasRunPlainExistenceHook = true
            do {
                try onFirstMissingPlainExistenceCheck?(path)
            } catch {
                creationError = error
            }
            return exists
        }
    }
}
