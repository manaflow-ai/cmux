import Foundation
import Testing
@testable import CmuxControlSocket
import CmuxSettings
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

extension SocketACLReloadRegressionTests {
    @Test(arguments: [
        "{",
        #"{"automation":{"socketControlMode":"invalid-mode"}}"#,
    ])
    func invalidColdLaunchPreservesPasswordMode(contents: String) throws {
        let defaults = UserDefaults.standard
        let originalDefaults = capturedSocketDefaults(defaults)
        let directory = lifecycleTemporaryDirectory(prefix: "scfp")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let configURL = directory.appendingPathComponent("cmux.json")
        defer {
            restoreSocketDefaults(originalDefaults, in: defaults)
            try? FileManager.default.removeItem(at: directory)
        }

        resetSocketDefaults(defaults, unmanagedMode: .password)
        try contents.write(to: configURL, atomically: true, encoding: .utf8)
        _ = CmuxSettingsFileStore(
            primaryPath: configURL.path,
            fallbackPath: nil,
            additionalFallbackPaths: [],
            startWatching: false
        )

        #expect(defaults.string(forKey: SocketControlSettings.appStorageKey) == SocketControlMode.password.rawValue)
    }

    @Test(arguments: ["null", "[]"])
    func malformedAutomationSectionPreservesManagedPassword(section: String) throws {
        let defaults = UserDefaults.standard
        let originalDefaults = capturedSocketDefaults(defaults)
        let originalAppearance = defaults.object(forKey: AppearanceSettings.appearanceModeKey)
        let directory = lifecycleTemporaryDirectory(prefix: "scfa")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let configURL = directory.appendingPathComponent("cmux.json")
        defer {
            restoreSocketDefaults(originalDefaults, in: defaults)
            if let originalAppearance {
                defaults.set(originalAppearance, forKey: AppearanceSettings.appearanceModeKey)
            } else {
                defaults.removeObject(forKey: AppearanceSettings.appearanceModeKey)
            }
            try? FileManager.default.removeItem(at: directory)
        }

        resetSocketDefaults(defaults, unmanagedMode: .allowAll)
        try writeConfig(mode: SocketControlMode.password.rawValue, to: configURL)
        let store = CmuxSettingsFileStore(
            primaryPath: configURL.path,
            fallbackPath: nil,
            additionalFallbackPaths: [],
            startWatching: false
        )
        #expect(defaults.string(forKey: SocketControlSettings.appStorageKey) == SocketControlMode.password.rawValue)

        defaults.set("system", forKey: AppearanceSettings.appearanceModeKey)
        try "{\"app\":{\"appearance\":\"dark\"},\"automation\":\(section)}"
            .write(to: configURL, atomically: true, encoding: .utf8)
        store.reload()

        #expect(defaults.string(forKey: SocketControlSettings.appStorageKey) == SocketControlMode.password.rawValue)
        #expect(defaults.string(forKey: AppearanceSettings.appearanceModeKey) == "dark")
    }

    @Test(arguments: [SocketControlMode.cmuxOnly, .off])
    func missingPrimaryColdStartPreservesImportedRestrictiveMode(mode: SocketControlMode) throws {
        let defaults = UserDefaults.standard
        let originalDefaults = capturedSocketDefaults(defaults)
        let directory = lifecycleTemporaryDirectory(prefix: "scfc")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let configURL = directory.appendingPathComponent("cmux.json")
        defer {
            restoreSocketDefaults(originalDefaults, in: defaults)
            try? FileManager.default.removeItem(at: directory)
        }

        resetSocketDefaults(defaults, unmanagedMode: .allowAll)
        try writeConfig(mode: mode.rawValue, to: configURL)
        _ = CmuxSettingsFileStore(
            primaryPath: configURL.path,
            fallbackPath: nil,
            additionalFallbackPaths: [],
            startWatching: false
        )
        #expect(defaults.string(forKey: SocketControlSettings.appStorageKey) == mode.rawValue)

        try FileManager.default.removeItem(at: configURL)
        _ = CmuxSettingsFileStore(
            primaryPath: configURL.path,
            fallbackPath: nil,
            additionalFallbackPaths: [],
            startWatching: false
        )

        #expect(defaults.string(forKey: SocketControlSettings.appStorageKey) == mode.rawValue)

        _ = CmuxSettingsFileStore(
            primaryPath: configURL.path,
            fallbackPath: nil,
            additionalFallbackPaths: [],
            startWatching: false
        )

        #expect(defaults.string(forKey: SocketControlSettings.appStorageKey) == mode.rawValue)
    }

    @Test func missingPrimaryColdStartPreservesPasswordCredentialAcrossRelaunches() throws {
        let defaults = UserDefaults.standard
        let originalDefaults = capturedSocketDefaults(defaults)
        let directory = lifecycleTemporaryDirectory(prefix: "scfpw")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let configURL = directory.appendingPathComponent("cmux.json")
        let passwordStore = SocketControlPasswordStore(
            environment: [:],
            fileURL: directory.appendingPathComponent("socket-password")
        )
        defer {
            restoreSocketDefaults(originalDefaults, in: defaults)
            try? FileManager.default.removeItem(at: directory)
        }

        resetSocketDefaults(defaults, unmanagedMode: .allowAll)
        try passwordStore.savePassword("preserved-secret")
        try writeConfig(mode: SocketControlMode.password.rawValue, to: configURL)
        _ = CmuxSettingsFileStore(
            primaryPath: configURL.path,
            fallbackPath: nil,
            additionalFallbackPaths: [],
            passwordStore: passwordStore,
            startWatching: false
        )

        try FileManager.default.removeItem(at: configURL)
        for _ in 0..<2 {
            _ = CmuxSettingsFileStore(
                primaryPath: configURL.path,
                fallbackPath: nil,
                additionalFallbackPaths: [],
                passwordStore: passwordStore,
                startWatching: false
            )
            #expect(defaults.string(forKey: SocketControlSettings.appStorageKey) == SocketControlMode.password.rawValue)
            #expect(try passwordStore.loadPassword() == "preserved-secret")
        }
    }

    @Test func bootstrapPreservesUTF16FallbackSettingsWhileRestrictingSocketMode() throws {
        let source = """
        {
          "app": { "appearance": "dark" },
          "automation": { "socketControlMode": "allowAll" }
        }
        """
        let fallback = try #require(source.data(using: .utf16LittleEndian))

        let materialized = CmuxSettingsFileStore.materializeBootstrapSocketPolicy(
            in: fallback,
            imported: .string(SocketControlMode.cmuxOnly.rawValue)
        )
        let sanitized = try JSONCParser.preprocess(data: materialized)
        let root = try #require(
            JSONSerialization.jsonObject(with: sanitized) as? [String: Any]
        )
        let app = try #require(root["app"] as? [String: Any])
        let automation = try #require(root["automation"] as? [String: Any])

        #expect(app["appearance"] as? String == "dark")
        #expect(automation["socketControlMode"] as? String == SocketControlMode.cmuxOnly.rawValue)
    }

    @Test func malformedReloadPreservesLastValidRestrictiveMode() throws {
        let defaults = UserDefaults.standard
        let originalDefaults = capturedSocketDefaults(defaults)
        let directory = lifecycleTemporaryDirectory(prefix: "scfm")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let configURL = directory.appendingPathComponent("cmux.json")
        defer {
            restoreSocketDefaults(originalDefaults, in: defaults)
            try? FileManager.default.removeItem(at: directory)
        }

        resetSocketDefaults(defaults, unmanagedMode: .allowAll)
        try writeConfig(mode: SocketControlMode.cmuxOnly.rawValue, to: configURL)
        let store = CmuxSettingsFileStore(
            primaryPath: configURL.path,
            fallbackPath: nil,
            additionalFallbackPaths: [],
            startWatching: false
        )
        #expect(defaults.string(forKey: SocketControlSettings.appStorageKey) == SocketControlMode.cmuxOnly.rawValue)

        try "{".write(to: configURL, atomically: true, encoding: .utf8)
        store.reload()

        #expect(defaults.string(forKey: SocketControlSettings.appStorageKey) == SocketControlMode.cmuxOnly.rawValue)
    }

    @Test func invalidExplicitModeFailsClosed() throws {
        let defaults = UserDefaults.standard
        let originalDefaults = capturedSocketDefaults(defaults)
        let directory = lifecycleTemporaryDirectory(prefix: "scfi")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let configURL = directory.appendingPathComponent("cmux.json")
        defer {
            restoreSocketDefaults(originalDefaults, in: defaults)
            try? FileManager.default.removeItem(at: directory)
        }

        resetSocketDefaults(defaults, unmanagedMode: .allowAll)
        try writeConfig(mode: "unrestricted-invalid-mode", to: configURL)
        _ = CmuxSettingsFileStore(
            primaryPath: configURL.path,
            fallbackPath: nil,
            additionalFallbackPaths: [],
            startWatching: false
        )

        #expect(defaults.string(forKey: SocketControlSettings.appStorageKey) == SocketControlMode.cmuxOnly.rawValue)
    }

    @Test func malformedReloadPreservesExplicitOffWhenFileDoesNotManageMode() throws {
        let defaults = UserDefaults.standard
        let originalDefaults = capturedSocketDefaults(defaults)
        let directory = lifecycleTemporaryDirectory(prefix: "scfo")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let configURL = directory.appendingPathComponent("cmux.json")
        defer {
            restoreSocketDefaults(originalDefaults, in: defaults)
            try? FileManager.default.removeItem(at: directory)
        }

        resetSocketDefaults(defaults, unmanagedMode: .off)
        try "{}".write(to: configURL, atomically: true, encoding: .utf8)
        let store = CmuxSettingsFileStore(
            primaryPath: configURL.path,
            fallbackPath: nil,
            additionalFallbackPaths: [],
            startWatching: false
        )
        #expect(defaults.string(forKey: SocketControlSettings.appStorageKey) == SocketControlMode.off.rawValue)

        try "{".write(to: configURL, atomically: true, encoding: .utf8)
        store.reload()

        #expect(defaults.string(forKey: SocketControlSettings.appStorageKey) == SocketControlMode.off.rawValue)
    }

    @Test func transientMissingPrimaryDoesNotImportBroaderFallbackMode() throws {
        let defaults = UserDefaults.standard
        let originalDefaults = capturedSocketDefaults(defaults)
        let directory = lifecycleTemporaryDirectory(prefix: "scff")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let primaryURL = directory.appendingPathComponent("cmux.json")
        let fallbackURL = directory.appendingPathComponent("settings.json")
        defer {
            restoreSocketDefaults(originalDefaults, in: defaults)
            try? FileManager.default.removeItem(at: directory)
        }

        resetSocketDefaults(defaults, unmanagedMode: .allowAll)
        try writeConfig(mode: SocketControlMode.cmuxOnly.rawValue, to: primaryURL)
        try writeConfig(mode: SocketControlMode.allowAll.rawValue, to: fallbackURL)
        let store = CmuxSettingsFileStore(
            primaryPath: primaryURL.path,
            fallbackPath: fallbackURL.path,
            additionalFallbackPaths: [],
            startWatching: false
        )
        #expect(defaults.string(forKey: SocketControlSettings.appStorageKey) == SocketControlMode.cmuxOnly.rawValue)

        try FileManager.default.removeItem(at: primaryURL)
        store.reload()

        #expect(defaults.string(forKey: SocketControlSettings.appStorageKey) == SocketControlMode.cmuxOnly.rawValue)
    }

    @Test func missingPrimaryAcceptsFallbackThatDisablesSocket() throws {
        let defaults = UserDefaults.standard
        let originalDefaults = capturedSocketDefaults(defaults)
        let directory = lifecycleTemporaryDirectory(prefix: "scft")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let primaryURL = directory.appendingPathComponent("cmux.json")
        let fallbackURL = directory.appendingPathComponent("settings.json")
        defer {
            restoreSocketDefaults(originalDefaults, in: defaults)
            try? FileManager.default.removeItem(at: directory)
        }

        resetSocketDefaults(defaults, unmanagedMode: .allowAll)
        try writeConfig(mode: SocketControlMode.allowAll.rawValue, to: primaryURL)
        try writeConfig(mode: SocketControlMode.off.rawValue, to: fallbackURL)
        let store = CmuxSettingsFileStore(
            primaryPath: primaryURL.path,
            fallbackPath: fallbackURL.path,
            additionalFallbackPaths: [],
            startWatching: false
        )
        #expect(defaults.string(forKey: SocketControlSettings.appStorageKey) == SocketControlMode.allowAll.rawValue)

        try FileManager.default.removeItem(at: primaryURL)
        store.reload()

        #expect(defaults.string(forKey: SocketControlSettings.appStorageKey) == SocketControlMode.off.rawValue)
    }

    @Test func enabledReconciliationStartsListenerWithoutTabManager() throws {
        let controller = TerminalController.shared
        let originalTabManager = controller.tabManager
        controller.stop()
        controller.setActiveTabManager(nil)

        let directory = lifecycleTemporaryDirectory(prefix: "scfh")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let socketPath = directory.appendingPathComponent("cmux.sock").path
        defer {
            controller.stop()
            controller.setActiveTabManager(originalTabManager)
            try? FileManager.default.removeItem(at: directory)
        }

        controller.reconcileSocketConfiguration(
            SocketControlServerConfiguration(
                accessMode: .cmuxOnly,
                preferredSocketPath: socketPath
            ),
            source: "test.headless_start"
        )

        #expect(controller.socketServer.isRunning)
        #expect(controller.socketServer.currentSocketPath == socketPath)
        #expect(FileManager.default.fileExists(atPath: socketPath))
        #expect(controller.tabManager == nil)

        let listenerIdentity = try #require(controller.socketServer.transport.pathIdentity(at: socketPath))
        let tabManager = TabManager()
        controller.reconcileSocketConfiguration(
            SocketControlServerConfiguration(
                accessMode: .cmuxOnly,
                preferredSocketPath: socketPath
            ),
            routingFallbackTabManager: tabManager,
            source: "test.headless_attach"
        )

        #expect(controller.tabManager === tabManager)
        #expect(controller.socketServer.transport.pathIdentity(at: socketPath) == listenerIdentity)
    }

    private func capturedSocketDefaults(_ defaults: UserDefaults) -> [(String, Any?)] {
        socketDefaultsKeys.map { ($0, defaults.object(forKey: $0)) }
    }

    private func restoreSocketDefaults(_ values: [(String, Any?)], in defaults: UserDefaults) {
        for (key, value) in values {
            if let value {
                defaults.set(value, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }
    }

    private func resetSocketDefaults(_ defaults: UserDefaults, unmanagedMode: SocketControlMode) {
        socketDefaultsKeys.forEach(defaults.removeObject(forKey:))
        defaults.set(unmanagedMode.rawValue, forKey: SocketControlSettings.appStorageKey)
    }

    private var socketDefaultsKeys: [String] {
        [
            SocketControlSettings.appStorageKey,
            "cmux.settingsFile.backups.v1",
            "cmux.settingsFile.importedManagedDefaults.v1",
        ]
    }

    private func writeConfig(mode: String, to url: URL) throws {
        let contents = """
        {
          "automation": {
            "socketControlMode": "\(mode)"
          }
        }
        """
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }

    private func lifecycleTemporaryDirectory(prefix: String) -> URL {
        let identifier = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8)
        return FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(identifier)", isDirectory: true)
    }
}
