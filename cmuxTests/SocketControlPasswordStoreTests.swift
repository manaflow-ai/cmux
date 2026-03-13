import XCTest
import Darwin

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class SocketControlPasswordStoreTests: XCTestCase {
    override func setUp() {
        super.setUp()
        SocketControlPasswordStore.resetLazyKeychainFallbackCacheForTests()
    }

    override func tearDown() {
        SocketControlPasswordStore.resetLazyKeychainFallbackCacheForTests()
        super.tearDown()
    }

    func testSaveLoadAndClearRoundTripUsesFileStorage() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-socket-password-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let fileURL = tempDir.appendingPathComponent("socket-password.txt", isDirectory: false)

        XCTAssertFalse(SocketControlPasswordStore.hasConfiguredPassword(environment: [:], fileURL: fileURL))

        try SocketControlPasswordStore.savePassword("hunter2", fileURL: fileURL)
        XCTAssertEqual(try SocketControlPasswordStore.loadPassword(fileURL: fileURL), "hunter2")
        XCTAssertTrue(SocketControlPasswordStore.hasConfiguredPassword(environment: [:], fileURL: fileURL))

        try SocketControlPasswordStore.clearPassword(fileURL: fileURL)
        XCTAssertNil(try SocketControlPasswordStore.loadPassword(fileURL: fileURL))
        XCTAssertFalse(SocketControlPasswordStore.hasConfiguredPassword(environment: [:], fileURL: fileURL))
    }

    func testConfiguredPasswordPrefersEnvironmentOverStoredFile() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-socket-password-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let fileURL = tempDir.appendingPathComponent("socket-password.txt", isDirectory: false)
        try SocketControlPasswordStore.savePassword("stored-secret", fileURL: fileURL)

        let environment = [SocketControlSettings.socketPasswordEnvKey: "env-secret"]
        let configured = SocketControlPasswordStore.configuredPassword(
            environment: environment,
            fileURL: fileURL
        )
        XCTAssertEqual(configured, "env-secret")
    }

    func testConfiguredPasswordLazyKeychainFallbackReadsOnlyOnceAndCaches() {
        var readCount = 0

        let withoutFallback = SocketControlPasswordStore.configuredPassword(
            environment: [:],
            fileURL: nil,
            allowLazyKeychainFallback: false,
            loadKeychainPassword: {
                readCount += 1
                return "legacy-secret"
            }
        )
        XCTAssertNil(withoutFallback)
        XCTAssertEqual(readCount, 0)

        let firstWithFallback = SocketControlPasswordStore.configuredPassword(
            environment: [:],
            fileURL: nil,
            allowLazyKeychainFallback: true,
            loadKeychainPassword: {
                readCount += 1
                return "legacy-secret"
            }
        )
        XCTAssertEqual(firstWithFallback, "legacy-secret")
        XCTAssertEqual(readCount, 1)

        let secondWithFallback = SocketControlPasswordStore.configuredPassword(
            environment: [:],
            fileURL: nil,
            allowLazyKeychainFallback: true,
            loadKeychainPassword: {
                readCount += 1
                return "new-secret"
            }
        )
        XCTAssertEqual(secondWithFallback, "legacy-secret")
        XCTAssertEqual(readCount, 1)
    }

    func testConfiguredPasswordLazyKeychainFallbackCachesMissingValue() {
        var readCount = 0

        let first = SocketControlPasswordStore.configuredPassword(
            environment: [:],
            fileURL: nil,
            allowLazyKeychainFallback: true,
            loadKeychainPassword: {
                readCount += 1
                return nil
            }
        )
        XCTAssertNil(first)
        XCTAssertEqual(readCount, 1)

        let second = SocketControlPasswordStore.configuredPassword(
            environment: [:],
            fileURL: nil,
            allowLazyKeychainFallback: true,
            loadKeychainPassword: {
                readCount += 1
                return "should-not-be-read"
            }
        )
        XCTAssertNil(second)
        XCTAssertEqual(readCount, 1)
    }

    func testConfiguredPasswordPrefersStoredFileOverLazyKeychainFallback() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-socket-password-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let fileURL = tempDir.appendingPathComponent("socket-password.txt", isDirectory: false)
        try SocketControlPasswordStore.savePassword("stored-secret", fileURL: fileURL)

        var readCount = 0
        let configured = SocketControlPasswordStore.configuredPassword(
            environment: [:],
            fileURL: fileURL,
            allowLazyKeychainFallback: true,
            loadKeychainPassword: {
                readCount += 1
                return "legacy-secret"
            }
        )

        XCTAssertEqual(configured, "stored-secret")
        XCTAssertEqual(readCount, 0)
    }

    func testHasConfiguredAndVerifyReuseSingleLazyKeychainRead() {
        var readCount = 0
        let loader = {
            readCount += 1
            return "legacy-secret"
        }

        XCTAssertTrue(
            SocketControlPasswordStore.hasConfiguredPassword(
                environment: [:],
                fileURL: nil,
                allowLazyKeychainFallback: true,
                loadKeychainPassword: loader
            )
        )
        XCTAssertEqual(readCount, 1)

        XCTAssertTrue(
            SocketControlPasswordStore.verify(
                password: "legacy-secret",
                environment: [:],
                fileURL: nil,
                allowLazyKeychainFallback: true,
                loadKeychainPassword: loader
            )
        )
        XCTAssertEqual(readCount, 1)
    }

    func testDefaultPasswordFileURLUsesCmuxAppSupportPath() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-socket-password-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let resolved = SocketControlPasswordStore.defaultPasswordFileURL(appSupportDirectory: tempDir)
        XCTAssertEqual(
            resolved?.path,
            tempDir.appendingPathComponent("cmux", isDirectory: true)
                .appendingPathComponent("socket-control-password", isDirectory: false).path
        )
    }

    func testLegacyKeychainMigrationCopiesPasswordDeletesLegacyAndRunsOnlyOnce() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-socket-password-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let fileURL = tempDir.appendingPathComponent("socket-password.txt", isDirectory: false)
        let defaultsSuiteName = "cmux-socket-password-migration-tests-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: defaultsSuiteName) else {
            XCTFail("Expected isolated UserDefaults suite for migration test")
            return
        }
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName) }

        var lookupCount = 0
        var deleteCount = 0

        SocketControlPasswordStore.migrateLegacyKeychainPasswordIfNeeded(
            defaults: defaults,
            fileURL: fileURL,
            loadLegacyPassword: {
                lookupCount += 1
                return "legacy-secret"
            },
            deleteLegacyPassword: {
                deleteCount += 1
                return true
            }
        )

        XCTAssertEqual(try SocketControlPasswordStore.loadPassword(fileURL: fileURL), "legacy-secret")
        XCTAssertEqual(lookupCount, 1)
        XCTAssertEqual(deleteCount, 1)

        SocketControlPasswordStore.migrateLegacyKeychainPasswordIfNeeded(
            defaults: defaults,
            fileURL: fileURL,
            loadLegacyPassword: {
                lookupCount += 1
                return "new-value"
            },
            deleteLegacyPassword: {
                deleteCount += 1
                return true
            }
        )

        XCTAssertEqual(lookupCount, 1)
        XCTAssertEqual(deleteCount, 1)
        XCTAssertEqual(try SocketControlPasswordStore.loadPassword(fileURL: fileURL), "legacy-secret")
    }
}

final class CmuxCLIPathInstallerTests: XCTestCase {
    func testInstallAndUninstallRoundTripWithoutAdministratorPrivileges() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-cli-installer-tests-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let bundledCLIURL = root
            .appendingPathComponent("cmux.app/Contents/Resources/bin/cmux", isDirectory: false)
        try fileManager.createDirectory(
            at: bundledCLIURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "#!/bin/sh\necho cmux\n".write(to: bundledCLIURL, atomically: true, encoding: .utf8)

        let destinationURL = root.appendingPathComponent("usr/local/bin/cmux", isDirectory: false)

        var privilegedInstallCallCount = 0
        var privilegedUninstallCallCount = 0
        let installer = CmuxCLIPathInstaller(
            fileManager: fileManager,
            destinationURL: destinationURL,
            bundledCLIURLProvider: { bundledCLIURL },
            expectedBundledCLIPath: bundledCLIURL.path,
            privilegedInstaller: { _, _ in privilegedInstallCallCount += 1 },
            privilegedUninstaller: { _ in privilegedUninstallCallCount += 1 }
        )

        let installOutcome = try installer.install()
        XCTAssertFalse(installOutcome.usedAdministratorPrivileges)
        XCTAssertEqual(privilegedInstallCallCount, 0)
        XCTAssertTrue(installer.isInstalled())
        XCTAssertEqual(
            try fileManager.destinationOfSymbolicLink(atPath: destinationURL.path),
            bundledCLIURL.path
        )

        let uninstallOutcome = try installer.uninstall()
        XCTAssertFalse(uninstallOutcome.usedAdministratorPrivileges)
        XCTAssertTrue(uninstallOutcome.removedExistingEntry)
        XCTAssertEqual(privilegedUninstallCallCount, 0)
        XCTAssertFalse(fileManager.fileExists(atPath: destinationURL.path))
        XCTAssertFalse(installer.isInstalled())
    }

    func testInstallFallsBackToAdministratorFlowWhenDestinationIsNotWritable() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-cli-installer-tests-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let bundledCLIURL = root
            .appendingPathComponent("cmux.app/Contents/Resources/bin/cmux", isDirectory: false)
        try fileManager.createDirectory(
            at: bundledCLIURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "#!/bin/sh\necho cmux\n".write(to: bundledCLIURL, atomically: true, encoding: .utf8)

        let destinationURL = root.appendingPathComponent("usr/local/bin/cmux", isDirectory: false)
        let destinationDir = destinationURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: destinationDir, withIntermediateDirectories: true)
        try fileManager.setAttributes([.posixPermissions: 0o555], ofItemAtPath: destinationDir.path)
        defer {
            try? fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destinationDir.path)
        }

        var privilegedInstallCallCount = 0
        let installer = CmuxCLIPathInstaller(
            fileManager: fileManager,
            destinationURL: destinationURL,
            bundledCLIURLProvider: { bundledCLIURL },
            expectedBundledCLIPath: bundledCLIURL.path,
            privilegedInstaller: { sourceURL, privilegedDestinationURL in
                privilegedInstallCallCount += 1
                XCTAssertEqual(sourceURL.standardizedFileURL, bundledCLIURL.standardizedFileURL)
                XCTAssertEqual(privilegedDestinationURL.standardizedFileURL, destinationURL.standardizedFileURL)
                try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destinationDir.path)
                try fileManager.createSymbolicLink(at: privilegedDestinationURL, withDestinationURL: sourceURL)
            }
        )

        let installOutcome = try installer.install()
        XCTAssertTrue(installOutcome.usedAdministratorPrivileges)
        XCTAssertEqual(privilegedInstallCallCount, 1)
        XCTAssertTrue(installer.isInstalled())
    }
}

private struct CLIVersionInvocationResult {
    let exitCode: Int32
    let stdout: String
    let stderr: String
    let elapsed: TimeInterval
    let timedOut: Bool
}

private enum FakeVersionSocketServerMode {
    case responsive(appInfo: [String: String])
    case unresponsive
}

private struct FakeVersionSocketServerError: Error, CustomStringConvertible {
    let message: String

    var description: String { message }
}

private final class FakeVersionSocketServer {
    let socketPath: String

    private let mode: FakeVersionSocketServerMode
    private let ready = DispatchSemaphore(value: 0)
    private let stateLock = NSLock()
    private var readBuffer = Data()
    private var stopRequested = false
    private var thread: Thread?
    private var listenerFD: Int32 = -1

    private(set) var error: Error?

    init(socketPath: String, mode: FakeVersionSocketServerMode) {
        self.socketPath = socketPath
        self.mode = mode
    }

    func start() throws {
        let thread = Thread { [weak self] in
            self?.run()
        }
        self.thread = thread
        thread.start()

        guard ready.wait(timeout: .now() + 2.0) == .success else {
            throw FakeVersionSocketServerError(message: "Timed out waiting for socket server readiness")
        }

        if let error {
            throw error
        }
    }

    func stop() {
        stateLock.lock()
        stopRequested = true
        let listenerFD = self.listenerFD
        stateLock.unlock()

        if listenerFD >= 0 {
            Darwin.shutdown(listenerFD, SHUT_RDWR)
            Darwin.close(listenerFD)
        }

        thread?.cancel()
        while let thread, !thread.isFinished {
            Thread.sleep(forTimeInterval: 0.01)
        }

        unlink(socketPath)
    }

    private func run() {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: socketPath) {
            unlink(socketPath)
        }

        let listenerFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listenerFD >= 0 else {
            fail(FakeVersionSocketServerError(message: "Failed to create fake version socket"))
            return
        }

        stateLock.lock()
        self.listenerFD = listenerFD
        stateLock.unlock()

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let maxLength = MemoryLayout.size(ofValue: addr.sun_path)
        socketPath.withCString { ptr in
            withUnsafeMutablePointer(to: &addr.sun_path) { pathPtr in
                let buf = UnsafeMutableRawPointer(pathPtr).assumingMemoryBound(to: CChar.self)
                strncpy(buf, ptr, maxLength - 1)
            }
        }

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                Darwin.bind(listenerFD, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            let err = errno
            Darwin.close(listenerFD)
            fail(FakeVersionSocketServerError(message: "Failed to bind fake version socket (errno \(err))"))
            return
        }

        guard listen(listenerFD, 8) == 0 else {
            let err = errno
            Darwin.close(listenerFD)
            fail(FakeVersionSocketServerError(message: "Failed to listen on fake version socket (errno \(err))"))
            return
        }

        ready.signal()

        while !isStopRequested {
            var pollFD = pollfd(fd: listenerFD, events: Int16(POLLIN), revents: 0)
            let ready = poll(&pollFD, 1, 100)
            if ready < 0 {
                if errno == EINTR || isStopRequested {
                    continue
                }
                fail(FakeVersionSocketServerError(message: "poll() failed while waiting for fake socket connections"))
                return
            }
            if ready == 0 {
                continue
            }

            let clientFD = accept(listenerFD, nil, nil)
            if clientFD < 0 {
                if errno == EINTR || isStopRequested {
                    continue
                }
                fail(FakeVersionSocketServerError(message: "accept() failed for fake socket server"))
                return
            }

            handleConnection(clientFD)
            Darwin.close(clientFD)
        }
    }

    private var isStopRequested: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return stopRequested
    }

    private func handleConnection(_ clientFD: Int32) {
        readBuffer.removeAll(keepingCapacity: true)
        defer { readBuffer.removeAll(keepingCapacity: true) }

        while !isStopRequested {
            guard let requestLine = readLine(from: clientFD, timeoutMilliseconds: 200) else {
                return
            }

            if requestLine.isEmpty {
                return
            }

            if requestLine.hasPrefix("auth ") {
                _ = writeLine("OK", to: clientFD)
                continue
            }

            if requestLine == "ping" {
                _ = writeLine("PONG", to: clientFD)
                continue
            }

            switch mode {
            case .responsive(let appInfo):
                guard
                    let requestData = requestLine.data(using: .utf8),
                    let request = try? JSONSerialization.jsonObject(with: requestData, options: []) as? [String: Any]
                else {
                    _ = writeLine("ERROR: invalid request", to: clientFD)
                    continue
                }
                let requestId = request["id"] ?? UUID().uuidString
                let response: [String: Any] = [
                    "ok": true,
                    "id": requestId,
                    "result": [
                        "socket_path": socketPath,
                        "focused": NSNull(),
                        "caller": NSNull(),
                        "app_info": appInfo
                    ]
                ]
                guard
                    let data = try? JSONSerialization.data(withJSONObject: response, options: []),
                    let line = String(data: data, encoding: .utf8)
                else {
                    _ = writeLine("ERROR: failed to encode response", to: clientFD)
                    continue
                }
                _ = writeLine(line, to: clientFD)

            case .unresponsive:
                while !isStopRequested {
                    var pollFD = pollfd(fd: clientFD, events: Int16(POLLHUP | POLLERR), revents: 0)
                    let pollResult = poll(&pollFD, 1, 50)
                    if pollResult < 0 {
                        if errno == EINTR {
                            continue
                        }
                        return
                    }
                    if pollResult > 0, (pollFD.revents & Int16(POLLHUP | POLLERR)) != 0 {
                        return
                    }
                }
                return
            }
        }
    }

    private func readLine(from fd: Int32, timeoutMilliseconds: Int32) -> String? {
        while !isStopRequested {
            if let newlineIndex = readBuffer.firstIndex(of: UInt8(ascii: "\n")) {
                let lineData = readBuffer.prefix(upTo: newlineIndex)
                readBuffer.removeSubrange(readBuffer.startIndex...newlineIndex)
                return String(data: lineData, encoding: .utf8)
            }

            var pollFD = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&pollFD, 1, timeoutMilliseconds)
            if ready < 0 {
                if errno == EINTR {
                    continue
                }
                return nil
            }
            if ready == 0 {
                if readBuffer.isEmpty {
                    return nil
                }
                continue
            }

            var buffer = [UInt8](repeating: 0, count: 4096)
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count <= 0 {
                guard !readBuffer.isEmpty else { return nil }
                let line = String(data: readBuffer, encoding: .utf8)
                readBuffer.removeAll(keepingCapacity: true)
                return line
            }
            readBuffer.append(buffer, count: count)
        }

        return nil
    }

    private func writeLine(_ line: String, to fd: Int32) -> Bool {
        let payload = line + "\n"
        return payload.withCString { ptr in
            Darwin.write(fd, ptr, strlen(ptr)) >= 0
        }
    }

    private func fail(_ error: Error) {
        self.error = error
        ready.signal()
    }
}

final class CLIVersionSocketFallbackTests: XCTestCase {
    func testVersionCommandsPreferSocketReportedVersion() throws {
        let fileManager = FileManager.default
        let tempRoot = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-cli-version-tests-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: tempRoot) }

        let socketPath = "/tmp/cmux-version-\(UUID().uuidString).sock"
        let server = FakeVersionSocketServer(
            socketPath: socketPath,
            mode: .responsive(
                appInfo: [
                    "CFBundleShortVersionString": "98.7.6",
                    "CFBundleVersion": "123",
                    "CMUXCommit": "abcdef1234567890"
                ]
            )
        )
        try server.start()
        defer { server.stop() }

        let expected = "cmux 98.7.6 (123) [abcdef123456]"
        let cliPath = try resolveCmuxCLIExecutable()

        for args in [["--socket", socketPath, "--version"], ["--socket", socketPath, "version"]] {
            let result = try runCLI(
                executablePath: cliPath,
                arguments: args,
                environment: isolatedCLIEnvironment(homeRoot: tempRoot)
            )

            XCTAssertFalse(result.timedOut, "CLI timed out for arguments: \(args)")
            XCTAssertEqual(result.exitCode, 0, "stderr=\(result.stderr)")
            XCTAssertEqual(result.stdout, expected, "stderr=\(result.stderr)")
        }
    }

    func testVersionCommandsAutoDiscoverTaggedSocketAndUseRunningAppVersion() throws {
        let fileManager = FileManager.default
        let tempRoot = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-cli-version-tests-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: tempRoot) }

        let tag = "version-auto-\(UUID().uuidString.lowercased())"
            .replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
        let socketPath = "/tmp/cmux-debug-\(tag).sock"
        let server = FakeVersionSocketServer(
            socketPath: socketPath,
            mode: .responsive(
                appInfo: [
                    "CFBundleShortVersionString": "77.7.7",
                    "CFBundleVersion": "707",
                    "CMUXCommit": "1234567890abcdef"
                ]
            )
        )
        try server.start()
        defer { server.stop() }

        let cliPath = try resolveCmuxCLIExecutable()
        let expected = "cmux 77.7.7 (707) [1234567890ab]"
        let environment = isolatedCLIEnvironment(
            homeRoot: tempRoot,
            overrides: [
                "CMUX_TAG": tag,
                "CMUX_SOCKET_PATH": "/tmp/cmux.sock"
            ]
        )

        for args in [["--version"], ["version"]] {
            let result = try runCLI(
                executablePath: cliPath,
                arguments: args,
                environment: environment
            )

            XCTAssertFalse(result.timedOut, "CLI timed out for arguments: \(args)")
            XCTAssertEqual(result.exitCode, 0, "stderr=\(result.stderr)")
            XCTAssertEqual(result.stdout, expected, "stderr=\(result.stderr)")
        }
    }

    func testVersionFallbackRemovesStaleSocketFile() throws {
        let fileManager = FileManager.default
        let tempRoot = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-cli-version-tests-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: tempRoot) }

        let cliPath = try resolveCmuxCLIExecutable()
        let baseEnvironment = isolatedCLIEnvironment(homeRoot: tempRoot)
        let baseline = try runCLI(
            executablePath: cliPath,
            arguments: ["--version"],
            environment: baseEnvironment
        )
        XCTAssertFalse(baseline.timedOut)
        XCTAssertEqual(baseline.exitCode, 0, "stderr=\(baseline.stderr)")

        let socketPath = "/tmp/cmux-stale-\(UUID().uuidString).sock"
        try createStaleUnixSocket(at: socketPath)
        try fileManager.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -60)], ofItemAtPath: socketPath)
        XCTAssertTrue(fileManager.fileExists(atPath: socketPath))
        defer { unlink(socketPath) }

        let result = try runCLI(
            executablePath: cliPath,
            arguments: ["--socket", socketPath, "--version"],
            environment: baseEnvironment
        )

        XCTAssertFalse(result.timedOut)
        XCTAssertEqual(result.exitCode, 0, "stderr=\(result.stderr)")
        XCTAssertEqual(result.stdout, baseline.stdout, "stderr=\(result.stderr)")
        XCTAssertFalse(fileManager.fileExists(atPath: socketPath), "Expected stale socket file to be removed")
    }

    func testVersionFallsBackQuicklyWhenSocketStopsResponding() throws {
        let fileManager = FileManager.default
        let tempRoot = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-cli-version-tests-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: tempRoot) }

        let socketPath = "/tmp/cmux-version-timeout-\(UUID().uuidString).sock"
        let server = FakeVersionSocketServer(socketPath: socketPath, mode: .unresponsive)
        try server.start()
        defer { server.stop() }

        let cliPath = try resolveCmuxCLIExecutable()
        let baseline = try runCLI(
            executablePath: cliPath,
            arguments: ["--version"],
            environment: isolatedCLIEnvironment(homeRoot: tempRoot)
        )
        XCTAssertFalse(baseline.timedOut)
        XCTAssertEqual(baseline.exitCode, 0, "stderr=\(baseline.stderr)")

        let result = try runCLI(
            executablePath: cliPath,
            arguments: ["--socket", socketPath, "version"],
            environment: isolatedCLIEnvironment(
                homeRoot: tempRoot,
                overrides: ["CMUXTERM_CLI_VERSION_TIMEOUT_SEC": "0.35"]
            ),
            timeout: 2.0
        )

        XCTAssertFalse(result.timedOut, "CLI should fall back instead of hanging")
        XCTAssertEqual(result.exitCode, 0, "stderr=\(result.stderr)")
        XCTAssertEqual(result.stdout, baseline.stdout, "stderr=\(result.stderr)")
        XCTAssertLessThan(result.elapsed, 1.5, "Expected fallback within a short timeout window")
    }

    private func resolveCmuxCLIExecutable() throws -> String {
        let fileManager = FileManager.default
        let env = ProcessInfo.processInfo.environment
        var candidates: [String] = []

        if let builtProductsDir = env["BUILT_PRODUCTS_DIR"], !builtProductsDir.isEmpty {
            candidates.append(contentsOf: cliCandidates(productsDirectory: builtProductsDir))
        }

        if let hostPath = env["TEST_HOST"], !hostPath.isEmpty {
            let productsDirectory = URL(fileURLWithPath: hostPath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .path
            candidates.append(contentsOf: cliCandidates(productsDirectory: productsDirectory))
        }

        for candidate in uniquePaths(candidates) where fileManager.isExecutableFile(atPath: candidate) {
            return URL(fileURLWithPath: candidate).resolvingSymlinksInPath().path
        }

        throw FakeVersionSocketServerError(message: "Unable to resolve built cmux CLI executable")
    }

    private func cliCandidates(productsDirectory: String) -> [String] {
        [
            "\(productsDirectory)/cmux DEV.app/Contents/Resources/bin/cmux",
            "\(productsDirectory)/cmux.app/Contents/Resources/bin/cmux",
            "\(productsDirectory)/cmux"
        ]
    }

    private func uniquePaths(_ paths: [String]) -> [String] {
        var seen = Set<String>()
        return paths.filter { seen.insert($0).inserted }
    }

    private func isolatedCLIEnvironment(
        homeRoot: URL,
        overrides: [String: String] = [:]
    ) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        for key in [
            "CMUX_SOCKET_PATH",
            "CMUX_SOCKET",
            "CMUX_TAG",
            "CMUX_SOCKET_PASSWORD",
            "CMUX_COMMIT",
            "CMUXTERM_CLI_VERSION_TIMEOUT_SEC"
        ] {
            environment.removeValue(forKey: key)
        }

        environment["HOME"] = homeRoot.path
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CMUX_CLAUDE_HOOK_SENTRY_DISABLED"] = "1"
        for (key, value) in overrides {
            environment[key] = value
        }
        return environment
    }

    private func runCLI(
        executablePath: String,
        arguments: [String],
        environment: [String: String],
        timeout: TimeInterval = 3.0
    ) throws -> CLIVersionInvocationResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        process.environment = environment

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let started = Date()
        try process.run()

        while process.isRunning && Date().timeIntervalSince(started) < timeout {
            Thread.sleep(forTimeInterval: 0.01)
        }

        let timedOut = process.isRunning
        if timedOut {
            process.interrupt()
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning {
            process.terminate()
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
        }

        process.waitUntilExit()

        let stdout = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        return CLIVersionInvocationResult(
            exitCode: process.terminationStatus,
            stdout: stdout,
            stderr: stderr,
            elapsed: Date().timeIntervalSince(started),
            timedOut: timedOut
        )
    }

    private func createStaleUnixSocket(at path: String) throws {
        unlink(path)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw FakeVersionSocketServerError(message: "Failed to create stale Unix socket")
        }
        defer { Darwin.close(fd) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let maxLength = MemoryLayout.size(ofValue: addr.sun_path)
        path.withCString { ptr in
            withUnsafeMutablePointer(to: &addr.sun_path) { pathPtr in
                let buf = UnsafeMutableRawPointer(pathPtr).assumingMemoryBound(to: CChar.self)
                strncpy(buf, ptr, maxLength - 1)
            }
        }

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                Darwin.bind(fd, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            throw FakeVersionSocketServerError(message: "Failed to bind stale Unix socket at \(path)")
        }
        guard listen(fd, 1) == 0 else {
            throw FakeVersionSocketServerError(message: "Failed to listen on stale Unix socket at \(path)")
        }
    }
}
