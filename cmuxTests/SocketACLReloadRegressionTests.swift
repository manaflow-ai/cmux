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

    @Test func deniedConnectionReceivesAccessDeniedResponse() throws {
        let controller = TerminalController.shared
        controller.stop()

        let directory = shortTemporaryDirectory(prefix: "sald")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let socketPath = directory.appendingPathComponent("cmux.sock").path
        defer {
            controller.stop()
            try? FileManager.default.removeItem(at: directory)
        }

        controller.start(
            tabManager: TabManager(),
            socketPath: socketPath,
            accessMode: .cmuxOnly
        )
        #expect(controller.socketServer.isRunning)

        let sockets = try makeSocketPair()
        defer { close(sockets.client) }
        try configureReadTimeout(sockets.client)
        try writeLine("ping", to: sockets.client)

        let yieldResult = controller.socketServer.connectionsContinuation.yield(
            ControlConnection(
                socket: sockets.server,
                peerProcessID: 1,
                authorizationGeneration: controller.socketServer.connectionAuthorizationGeneration
            )
        )
        if case .enqueued = yieldResult {
            // Ownership transferred to TerminalController's connection consumer.
        } else {
            close(sockets.server)
            Issue.record("Failed to enqueue the synthetic denied connection")
        }

        let response = try readLine(from: sockets.client)
        #expect(response == TerminalController.socketClientAccessDeniedResponse)
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
            preferredTabManager: TabManager(),
            source: "test.path_baseline"
        )
        #expect(controller.socketServer.currentSocketPath == firstPath)

        controller.reconcileSocketConfiguration(
            SocketControlServerConfiguration(
                accessMode: .automation,
                preferredSocketPath: secondPath
            ),
            preferredTabManager: TabManager(),
            source: "test.path_change"
        )

        #expect(controller.socketServer.isRunning)
        #expect(controller.socketServer.currentSocketPath == secondPath)
        #expect(!FileManager.default.fileExists(atPath: firstPath))
        #expect(FileManager.default.fileExists(atPath: secondPath))
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
            preferredTabManager: TabManager(),
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
            preferredTabManager: tabManager,
            source: "test.missing_path_baseline"
        )
        #expect(controller.socketServer.isRunning)
        #expect(unlink(socketPath) == 0)

        controller.reconcileSocketConfiguration(
            SocketControlServerConfiguration(
                accessMode: .automation,
                preferredSocketPath: socketPath
            ),
            preferredTabManager: tabManager,
            source: "test.missing_path_reconfigure"
        )

        #expect(controller.socketServer.isRunning)
        #expect(controller.socketServer.accessMode == .automation)
        #expect(FileManager.default.fileExists(atPath: socketPath))
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

    @Test func activeEventStreamClosesWhenPolicyGenerationChanges() throws {
        let controller = TerminalController.shared
        controller.stop()
        CmuxEventBus.shared.resetForTesting()

        let directory = shortTemporaryDirectory(prefix: "sals")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let socketPath = directory.appendingPathComponent("cmux.sock").path
        defer {
            controller.stop()
            CmuxEventBus.shared.resetForTesting()
            try? FileManager.default.removeItem(at: directory)
        }

        controller.start(tabManager: TabManager(), socketPath: socketPath, accessMode: .allowAll)
        let sockets = try makeSocketPair()
        defer { close(sockets.client) }
        try configureReadTimeout(sockets.client)
        try writeLine(
            #"{"id":"stream","method":"events.stream","params":{"include_heartbeats":false}}"#,
            to: sockets.client
        )

        let yieldResult = controller.socketServer.connectionsContinuation.yield(
            ControlConnection(
                socket: sockets.server,
                peerProcessID: getpid(),
                authorizationGeneration: controller.socketServer.connectionAuthorizationGeneration
            )
        )
        if case .enqueued = yieldResult {
            // Ownership transferred to TerminalController's connection consumer.
        } else {
            close(sockets.server)
            Issue.record("Failed to enqueue the synthetic event-stream connection")
        }

        let acknowledgement = try readLine(from: sockets.client)
        let acknowledgementData = try #require(acknowledgement.data(using: .utf8))
        let acknowledgementObject = try #require(
            JSONSerialization.jsonObject(with: acknowledgementData) as? [String: Any]
        )
        #expect(acknowledgementObject["type"] as? String == "ack")

        #expect(controller.socketServer.reconfigure(accessMode: .automation))
        CmuxEventBus.shared.publish(
            name: "test.revoked",
            category: "test",
            source: "test"
        )

        var byte: UInt8 = 0
        #expect(Darwin.read(sockets.client, &byte, 1) == 0)
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

    private func shortTemporaryDirectory(prefix: String) -> URL {
        let identifier = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8)
        return FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(identifier)", isDirectory: true)
    }

    private func makeSocketPair() throws -> (client: Int32, server: Int32) {
        var descriptors: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0 else {
            throw posixError("socketpair")
        }
        return (client: descriptors[0], server: descriptors[1])
    }

    private func configureReadTimeout(_ socket: Int32) throws {
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        let result = withUnsafePointer(to: &timeout) { pointer in
            setsockopt(
                socket,
                SOL_SOCKET,
                SO_RCVTIMEO,
                pointer,
                socklen_t(MemoryLayout<timeval>.size)
            )
        }
        guard result == 0 else { throw posixError("setsockopt(SO_RCVTIMEO)") }
    }

    private func writeLine(_ line: String, to socket: Int32) throws {
        let data = Data((line + "\n").utf8)
        try data.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let written = Darwin.write(
                    socket,
                    baseAddress.advanced(by: offset),
                    bytes.count - offset
                )
                if written < 0, errno == EINTR { continue }
                guard written > 0 else { throw posixError("write") }
                offset += written
            }
        }
    }

    private func readLine(from socket: Int32) throws -> String {
        var data = Data()
        var byte: UInt8 = 0
        while true {
            let count = Darwin.read(socket, &byte, 1)
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else { throw posixError("read") }
            guard count > 0 else { break }
            if byte == 0x0A { break }
            data.append(byte)
        }
        guard !data.isEmpty else {
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(ECONNRESET),
                userInfo: [NSLocalizedDescriptionKey: "Socket closed without an access-denied response"]
            )
        }
        guard let response = String(data: data, encoding: .utf8) else {
            throw NSError(
                domain: NSCocoaErrorDomain,
                code: NSFileReadInapplicableStringEncodingError
            )
        }
        return response
    }

    private func posixError(_ operation: String) -> NSError {
        let code = errno
        return NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(code),
            userInfo: [
                NSLocalizedDescriptionKey: "\(operation) failed: \(String(cString: strerror(code)))"
            ]
        )
    }
}
