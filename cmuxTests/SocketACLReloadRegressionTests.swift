import Darwin
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
struct SocketACLReloadRegressionTests {
    @Test func reloadConfigAppliesSocketModeToRunningServer() throws {
        let controller = TerminalController.shared
        controller.stop()

        let originalDelegate = AppDelegate.shared
        let originalStore = KeyboardShortcutSettings.settingsFileStore
        let defaults = UserDefaults.standard
        let restoredDefaults = [
            SocketControlSettings.appStorageKey,
            "cmux.settingsFile.backups.v1",
            "cmux.settingsFile.importedManagedDefaults.v1",
        ].map { ($0, defaults.object(forKey: $0)) }
        let directory = shortTemporaryDirectory(prefix: "salr")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let configURL = directory.appendingPathComponent("cmux.json")
        let socketPath = directory.appendingPathComponent("cmux.sock").path
        let appDelegate = AppDelegate()

        defer {
            controller.stop()
            KeyboardShortcutSettings.settingsFileStore = originalStore
            for (key, value) in restoredDefaults {
                if let value {
                    defaults.set(value, forKey: key)
                } else {
                    defaults.removeObject(forKey: key)
                }
            }
            AppDelegate.shared = originalDelegate
            try? FileManager.default.removeItem(at: directory)
            _ = appDelegate
        }

        try writeConfig(mode: .cmuxOnly, to: configURL)
        KeyboardShortcutSettings.settingsFileStore = KeyboardShortcutSettingsFileStore(
            primaryPath: configURL.path,
            fallbackPath: nil,
            additionalFallbackPaths: [],
            startWatching: false
        )
        controller.start(
            tabManager: TabManager(),
            socketPath: socketPath,
            accessMode: .cmuxOnly
        )
        #expect(controller.socketServer.isRunning)
        #expect(controller.socketServer.accessMode == .cmuxOnly)

        try writeConfig(mode: .automation, to: configURL)
        controller.controlSidebarReloadConfig()

        #expect(controller.socketServer.isRunning)
        #expect(controller.socketServer.accessMode == .automation)
    }

    @Test func watchedConfigReloadAppliesSocketModeToRunningServer() async throws {
        let controller = TerminalController.shared
        controller.stop()

        let originalStore = KeyboardShortcutSettings.settingsFileStore
        let defaults = UserDefaults.standard
        let restoredDefaults = [
            SocketControlSettings.appStorageKey,
            "cmux.settingsFile.backups.v1",
            "cmux.settingsFile.importedManagedDefaults.v1",
        ].map { ($0, defaults.object(forKey: $0)) }
        let directory = shortTemporaryDirectory(prefix: "salw")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let configURL = directory.appendingPathComponent("cmux.json")
        let socketPath = directory.appendingPathComponent("cmux.sock").path
        let tabManager = TabManager()
        let (reloadSources, reloadContinuation) = AsyncStream<String>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )

        defer {
            reloadContinuation.finish()
            controller.stop()
            KeyboardShortcutSettings.settingsFileStore = originalStore
            for (key, value) in restoredDefaults {
                if let value {
                    defaults.set(value, forKey: key)
                } else {
                    defaults.removeObject(forKey: key)
                }
            }
            try? FileManager.default.removeItem(at: directory)
        }

        try writeConfig(mode: .allowAll, to: configURL)
        KeyboardShortcutSettings.settingsFileStore = KeyboardShortcutSettingsFileStore(
            primaryPath: configURL.path,
            fallbackPath: nil,
            additionalFallbackPaths: [],
            startWatching: true,
            onWatchedFileReload: { source in
                let rawMode = defaults.string(forKey: SocketControlSettings.appStorageKey)
                    ?? SocketControlSettings.defaultMode.rawValue
                controller.reconcileSocketConfiguration(
                    SocketControlServerConfiguration(
                        accessMode: SocketControlSettings.migrateMode(rawMode),
                        preferredSocketPath: socketPath
                    ),
                    routingFallbackTabManager: tabManager,
                    source: source
                )
                reloadContinuation.yield(source)
            }
        )
        controller.reconcileSocketConfiguration(
            SocketControlServerConfiguration(
                accessMode: .allowAll,
                preferredSocketPath: socketPath
            ),
            routingFallbackTabManager: tabManager,
            source: "test.watcher_baseline"
        )
        #expect(controller.socketServer.isRunning)

        try writeConfig(mode: .off, to: configURL)

        #expect(await firstValue(from: reloadSources, within: .seconds(5)) == "settings.file_watcher")
        #expect(!controller.socketServer.isRunning)
    }

    @Test func reconcilePathChangeRebindsRunningListener() throws {
        let controller = TerminalController.shared
        controller.stop()

        let directory = shortTemporaryDirectory(prefix: "salp")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let firstPath = directory.appendingPathComponent("first.sock").path
        let secondPath = directory.appendingPathComponent("second.sock").path
        defer {
            controller.stop()
            try? FileManager.default.removeItem(at: directory)
        }

        controller.reconcileSocketConfiguration(
            SocketControlServerConfiguration(
                accessMode: .cmuxOnly,
                preferredSocketPath: firstPath
            ),
            routingFallbackTabManager: TabManager(),
            source: "test.path_baseline"
        )
        #expect(controller.socketServer.currentSocketPath == firstPath)

        controller.reconcileSocketConfiguration(
            SocketControlServerConfiguration(
                accessMode: .automation,
                preferredSocketPath: secondPath
            ),
            routingFallbackTabManager: TabManager(),
            source: "test.path_change"
        )

        #expect(controller.socketServer.isRunning)
        #expect(controller.socketServer.currentSocketPath == secondPath)
        #expect(!FileManager.default.fileExists(atPath: firstPath))
        #expect(FileManager.default.fileExists(atPath: secondPath))
    }

    @Test func reconcilePathChangeSupersedesPendingRearm() throws {
        let controller = TerminalController.shared
        controller.stop()

        let directory = shortTemporaryDirectory(prefix: "salp")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let stalePath = directory.appendingPathComponent("stale.sock").path
        let configuredPath = directory.appendingPathComponent("configured.sock").path
        defer {
            controller.stop()
            try? FileManager.default.removeItem(at: directory)
        }

        _ = controller.socketServer.updateConfiguredPreferredSocketPath(stalePath)
        controller.socketServer.withListenerState { state in
            // Mirrors the retained state after accept recovery parks a rearm.
            state.socketPath = stalePath
            state.pendingAcceptLoopRearmGeneration = 42
        }

        controller.reconcileSocketConfiguration(
            SocketControlServerConfiguration(
                accessMode: .automation,
                preferredSocketPath: configuredPath
            ),
            routingFallbackTabManager: TabManager(),
            source: "test.pending_rearm_path_change"
        )

        #expect(controller.socketServer.isRunning)
        #expect(controller.socketServer.currentSocketPath == configuredPath)
        #expect(!FileManager.default.fileExists(atPath: stalePath))
        #expect(FileManager.default.fileExists(atPath: configuredPath))
        #expect(controller.socketServer.claimPendingRearm(
            generation: 42,
            errnoCode: EMFILE,
            consecutiveFailures: 1,
            delayMs: 100
        ) == nil)
    }

    @Test func reconcilePreservesIntentionalFallbackForSamePreferredPath() throws {
        let controller = TerminalController.shared
        controller.stop()

        let directory = shortTemporaryDirectory(prefix: "salf")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let preferredPath = directory.appendingPathComponent("preferred.sock").path
        let fallbackPath = directory.appendingPathComponent("fallback.sock").path
        defer {
            controller.stop()
            try? FileManager.default.removeItem(at: directory)
        }

        _ = controller.socketServer.updateConfiguredPreferredSocketPath(preferredPath)
        #expect(!controller.socketServer.updateConfiguredPreferredSocketPath(preferredPath))
        controller.start(tabManager: TabManager(), socketPath: fallbackPath, accessMode: .cmuxOnly)
        let originalIdentity = try #require(
            controller.socketServer.transport.pathIdentity(at: fallbackPath)
        )

        controller.reconcileSocketConfiguration(
            SocketControlServerConfiguration(
                accessMode: .automation,
                preferredSocketPath: preferredPath
            ),
            routingFallbackTabManager: TabManager(),
            source: "test.fallback_reconcile"
        )

        #expect(controller.socketServer.currentSocketPath == fallbackPath)
        #expect(controller.socketServer.transport.pathIdentity(at: fallbackPath) == originalIdentity)
        #expect(!FileManager.default.fileExists(atPath: preferredPath))
    }

    @Test func reconcileRestartsAfterLivePermissionUpdateLosesSocketPath() throws {
        let controller = TerminalController.shared
        controller.stop()

        let directory = shortTemporaryDirectory(prefix: "salm")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let socketPath = directory.appendingPathComponent("cmux.sock").path
        let tabManager = TabManager()
        defer {
            controller.stop()
            try? FileManager.default.removeItem(at: directory)
        }

        controller.reconcileSocketConfiguration(
            SocketControlServerConfiguration(
                accessMode: .cmuxOnly,
                preferredSocketPath: socketPath
            ),
            routingFallbackTabManager: tabManager,
            source: "test.missing_path_baseline"
        )
        #expect(controller.socketServer.isRunning)
        #expect(unlink(socketPath) == 0)

        controller.reconcileSocketConfiguration(
            SocketControlServerConfiguration(
                accessMode: .automation,
                preferredSocketPath: socketPath
            ),
            routingFallbackTabManager: tabManager,
            source: "test.missing_path_reconfigure"
        )

        #expect(controller.socketServer.isRunning)
        #expect(controller.socketServer.accessMode == .automation)
        #expect(FileManager.default.fileExists(atPath: socketPath))
    }

    @Test func deletedStalePathRecoversUsingLatestConfiguredPath() async throws {
        let controller = TerminalController.shared
        controller.stop()

        let originalDelegate = AppDelegate.shared
        let defaults = UserDefaults.standard
        let originalMode = defaults.object(forKey: SocketControlSettings.appStorageKey)
        let environmentKeys = [
            "CMUX_SOCKET_PATH",
            SocketControlSettings.allowSocketPathOverrideKey,
            "CMUX_SOCKET_ENABLE",
            "CMUX_SOCKET_MODE",
        ]
        let processEnvironment = ProcessInfo.processInfo.environment
        let originalEnvironment = environmentKeys.map { ($0, processEnvironment[$0]) }
        let directory = shortTemporaryDirectory(prefix: "salp")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let stalePath = directory.appendingPathComponent("stale.sock").path
        let configuredPath = directory.appendingPathComponent("configured.sock").path
        let appDelegate = AppDelegate()
        defer {
            controller.stop()
            if let originalMode {
                defaults.set(originalMode, forKey: SocketControlSettings.appStorageKey)
            } else {
                defaults.removeObject(forKey: SocketControlSettings.appStorageKey)
            }
            for (key, value) in originalEnvironment {
                if let value {
                    setenv(key, value, 1)
                } else {
                    unsetenv(key)
                }
            }
            AppDelegate.shared = originalDelegate
            try? FileManager.default.removeItem(at: directory)
            _ = appDelegate
        }

        defaults.set(SocketControlMode.automation.rawValue, forKey: SocketControlSettings.appStorageKey)
        setenv("CMUX_SOCKET_PATH", configuredPath, 1)
        setenv(SocketControlSettings.allowSocketPathOverrideKey, "1", 1)
        unsetenv("CMUX_SOCKET_ENABLE")
        setenv("CMUX_SOCKET_MODE", SocketControlMode.automation.rawValue, 1)

        controller.start(tabManager: TabManager(), socketPath: stalePath, accessMode: .automation)
        #expect(controller.socketServer.isRunning)
        #expect(controller.socketServer.currentSocketPath == stalePath)

        let (restartPaths, restartContinuation) = AsyncStream<String>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        let observer = NotificationCenter.default.addObserver(
            forName: .socketListenerDidStart,
            object: controller,
            queue: nil
        ) { notification in
            if let path = notification.userInfo?["path"] as? String {
                restartContinuation.yield(path)
            }
        }
        defer {
            NotificationCenter.default.removeObserver(observer)
            restartContinuation.finish()
        }

        #expect(unlink(stalePath) == 0)
        #expect(await firstValue(from: restartPaths, within: .seconds(5)) == configuredPath)
        #expect(controller.socketServer.currentSocketPath == configuredPath)
        #expect(FileManager.default.fileExists(atPath: configuredPath))
        #expect(!FileManager.default.fileExists(atPath: stalePath))
    }

    @Test func restartStopsListenerWhenModeIsOffWithoutTabManager() throws {
        let controller = TerminalController.shared
        controller.stop()

        let defaults = UserDefaults.standard
        let originalMode = defaults.object(forKey: SocketControlSettings.appStorageKey)
        let originalDelegate = AppDelegate.shared
        let directory = shortTemporaryDirectory(prefix: "salo")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let socketPath = directory.appendingPathComponent("cmux.sock").path
        let appDelegate = AppDelegate()
        defer {
            controller.stop()
            if let originalMode {
                defaults.set(originalMode, forKey: SocketControlSettings.appStorageKey)
            } else {
                defaults.removeObject(forKey: SocketControlSettings.appStorageKey)
            }
            AppDelegate.shared = originalDelegate
            try? FileManager.default.removeItem(at: directory)
            _ = appDelegate
        }

        controller.start(tabManager: TabManager(), socketPath: socketPath, accessMode: .automation)
        #expect(controller.socketServer.isRunning)
        defaults.set(SocketControlMode.off.rawValue, forKey: SocketControlSettings.appStorageKey)

        appDelegate.restartSocketListenerIfEnabled(source: "test.off_restart")

        #expect(!controller.socketServer.isRunning)
        #expect(!FileManager.default.fileExists(atPath: socketPath))
    }

    private func writeConfig(mode: SocketControlMode, to url: URL) throws {
        let contents = """
        {
          "automation": {
            "socketControlMode": "\(mode.rawValue)"
          }
        }
        """
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }

    func shortTemporaryDirectory(prefix: String) -> URL {
        let identifier = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8)
        return FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(identifier)", isDirectory: true)
    }

    private func firstValue<Element: Sendable>(
        from stream: AsyncStream<Element>,
        within timeout: Duration
    ) async -> Element? {
        await withTaskGroup(of: Element?.self) { group in
            group.addTask {
                var iterator = stream.makeAsyncIterator()
                return await iterator.next()
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return nil
            }
            let value = await group.next() ?? nil
            group.cancelAll()
            return value
        }
    }

}
