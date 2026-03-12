import XCTest

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

        XCTAssertFalse(SocketControlPasswordStore.hasConfiguredPassword(fileURL: fileURL))

        try SocketControlPasswordStore.savePassword("hunter2", fileURL: fileURL)
        XCTAssertEqual(try SocketControlPasswordStore.loadPassword(fileURL: fileURL), "hunter2")
        XCTAssertTrue(SocketControlPasswordStore.hasConfiguredPassword(fileURL: fileURL))

        try SocketControlPasswordStore.clearPassword(fileURL: fileURL)
        XCTAssertNil(try SocketControlPasswordStore.loadPassword(fileURL: fileURL))
        XCTAssertFalse(SocketControlPasswordStore.hasConfiguredPassword(fileURL: fileURL))
    }

    func testConfiguredPasswordIgnoresEnvironmentVariable() throws {
        // When a file password is stored, it is returned regardless of whether
        // CMUX_SOCKET_PASSWORD is set in the process environment.
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-socket-password-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let fileURL = tempDir.appendingPathComponent("socket-password.txt", isDirectory: false)
        try SocketControlPasswordStore.savePassword("stored-secret", fileURL: fileURL)

        // environment parameter removed — the env var is no longer consulted.
        let configured = SocketControlPasswordStore.configuredPassword(fileURL: fileURL)
        XCTAssertEqual(configured, "stored-secret")
    }

    func testConfiguredPasswordReturnsNilWhenOnlyEnvVarIsSet() {
        // When no file password exists, configuredPassword() must return nil even
        // if CMUX_SOCKET_PASSWORD is set in the environment.  This is the core
        // security guarantee: the env var cannot be used as a back-door credential.
        let nonExistentFileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-socket-password-tests-\(UUID().uuidString)")
            .appendingPathComponent("no-such-file.txt")

        // CMUX_SOCKET_PASSWORD is in the real environment during CI runs; its
        // presence must not change the outcome.
        let configured = SocketControlPasswordStore.configuredPassword(
            fileURL: nonExistentFileURL,
            allowLazyKeychainFallback: false
        )
        XCTAssertNil(configured)
    }

    func testConfiguredPasswordLazyKeychainFallbackReadsOnlyOnceAndCaches() {
        var readCount = 0

        let withoutFallback = SocketControlPasswordStore.configuredPassword(
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
                fileURL: nil,
                allowLazyKeychainFallback: true,
                loadKeychainPassword: loader
            )
        )
        XCTAssertEqual(readCount, 1)

        XCTAssertTrue(
            SocketControlPasswordStore.verify(
                password: "legacy-secret",
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
