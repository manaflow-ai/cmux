import Foundation
import Testing
@testable import CmuxControlSocket
import CmuxSettings
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite(.serialized)
struct SocketConfigurationLifecycleTests {
    @Test func malformedReloadPreservesLastValidRestrictiveMode() throws {
        let defaults = UserDefaults.standard
        let originalDefaults = capturedSocketDefaults(defaults)
        let directory = shortTemporaryDirectory(prefix: "scfm")
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
        let directory = shortTemporaryDirectory(prefix: "scfi")
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

    @Test func enabledReconciliationStartsListenerWithoutTabManager() throws {
        let controller = TerminalController.shared
        let originalTabManager = controller.tabManager
        controller.stop()
        controller.setActiveTabManager(nil)

        let directory = shortTemporaryDirectory(prefix: "scfh")
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

    private func shortTemporaryDirectory(prefix: String) -> URL {
        let identifier = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8)
        return FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(identifier)", isDirectory: true)
    }
}
