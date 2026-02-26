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
