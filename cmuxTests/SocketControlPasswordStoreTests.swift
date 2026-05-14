import XCTest
import CMUXAuthCore

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

@MainActor
final class AuthManagerSignOutTests: XCTestCase {
    func testAuthLogRedactionRemovesTokensAndEmails() {
        let message = """
        auth.webauth callback failed: cmux://auth-callback?stack_access=access-token&stack_refresh=refresh-token&state=opaque-state user=alice@example.com Authorization: Bearer header.payload.signature
        """

        let redacted = AuthManager.redactedAuthLogMessageForTesting(message)

        XCTAssertFalse(redacted.contains("access-token"))
        XCTAssertFalse(redacted.contains("refresh-token"))
        XCTAssertFalse(redacted.contains("opaque-state"))
        XCTAssertFalse(redacted.contains("alice@example.com"))
        XCTAssertFalse(redacted.contains("header.payload.signature"))
        XCTAssertTrue(redacted.contains("stack_access=<redacted>"))
        XCTAssertTrue(redacted.contains("stack_refresh=<redacted>"))
        XCTAssertTrue(redacted.contains("state=<redacted>"))
        XCTAssertTrue(redacted.contains("<email>"))
        XCTAssertTrue(redacted.contains("Authorization=<redacted>"))
    }

    func testSignOutClearsInFlightBrowserSignInLoadingState() async {
        let suiteName = "cmux-auth-manager-sign-out-tests-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Could not create isolated defaults suite")
            return
        }
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let manager = AuthManager(
            client: AuthManagerSignOutTestClient(),
            tokenStore: AuthManagerSignOutTestTokenStore(),
            settingsStore: AuthSettingsStore(userDefaults: defaults)
        )
        await manager.awaitBootstrapped()

        manager.markBrowserSignInLoadingForTesting()
        XCTAssertTrue(manager.isLoading)

        await manager.signOut()

        XCTAssertFalse(manager.isLoading)
    }

    func testSignOutDuringBrowserCallbackDoesNotLeaveStaleAccessToken() async throws {
        let suiteName = "cmux-auth-manager-sign-out-race-tests-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Could not create isolated defaults suite")
            return
        }
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let tokenStore = AuthManagerSignOutTestTokenStore()
        let manager = AuthManager(
            client: AuthManagerSignOutTestClient(),
            tokenStore: tokenStore,
            settingsStore: AuthSettingsStore(userDefaults: defaults)
        )
        await manager.awaitBootstrapped()

        await tokenStore.suspendNextSetTokens()
        let callbackURL = try XCTUnwrap(URL(string: "cmux://auth-callback?stack_refresh=refresh-after-signout&stack_access=access-after-signout"))
        let callbackTask = Task { @MainActor in
            try await manager.handleCallbackURL(callbackURL)
        }

        await tokenStore.waitForSuspendedSetTokens()
        await manager.signOut()
        await tokenStore.resumeSuspendedSetTokens()
        try await callbackTask.value

        XCTAssertFalse(manager.isAuthenticated)
        let storedAccessToken = await tokenStore.getStoredAccessToken()
        XCTAssertNil(storedAccessToken)
        do {
            _ = try await manager.getAccessToken()
            XCTFail("Expected getAccessToken to reject the stale post-sign-out token")
        } catch AuthManagerError.missingAccessToken {
        } catch {
            XCTFail("Expected missingAccessToken, got \(error)")
        }
    }

    func testNewSignInDuringInFlightSignOutSurvivesSignOutCompletion() async throws {
        let suiteName = "cmux-auth-manager-sign-out-new-sign-in-tests-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Could not create isolated defaults suite")
            return
        }
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let client = AuthManagerSuspendingSignOutTestClient()
        let tokenStore = AuthManagerSignOutTestTokenStore()
        await tokenStore.setTokens(accessToken: "old-access", refreshToken: "old-refresh")
        let manager = AuthManager(
            client: client,
            tokenStore: tokenStore,
            settingsStore: AuthSettingsStore(userDefaults: defaults)
        )
        await manager.awaitBootstrapped()

        let signOutTask = Task { @MainActor in
            await manager.signOut()
        }
        await client.waitForSignOutStarted()

        let callbackURL = try XCTUnwrap(URL(string: "cmux://auth-callback?stack_refresh=new-refresh&stack_access=new-access"))
        try await manager.handleCallbackURL(callbackURL)
        await client.resumeSignOut()
        await signOutTask.value

        XCTAssertTrue(manager.isAuthenticated)
        let storedAccessToken = await tokenStore.getStoredAccessToken()
        let storedRefreshToken = await tokenStore.getStoredRefreshToken()
        XCTAssertEqual(storedAccessToken, "new-access")
        XCTAssertEqual(storedRefreshToken, "new-refresh")
    }
}

private struct AuthManagerSignOutTestClient: AuthClientProtocol {
    func currentUser() async throws -> CMUXAuthUser? {
        nil
    }

    func listTeams() async throws -> [AuthTeamSummary] {
        []
    }

    func signOut() async throws {}
}

private actor AuthManagerSuspendingSignOutTestClient: AuthClientProtocol {
    private var signOutContinuation: CheckedContinuation<Void, Never>?
    private var signOutStartedContinuation: CheckedContinuation<Void, Never>?

    func currentUser() async throws -> CMUXAuthUser? {
        nil
    }

    func listTeams() async throws -> [AuthTeamSummary] {
        []
    }

    func signOut() async throws {
        await withCheckedContinuation { continuation in
            signOutContinuation = continuation
            signOutStartedContinuation?.resume()
            signOutStartedContinuation = nil
        }
    }

    func waitForSignOutStarted() async {
        if signOutContinuation != nil {
            return
        }
        await withCheckedContinuation { continuation in
            signOutStartedContinuation = continuation
        }
    }

    func resumeSignOut() {
        let continuation = signOutContinuation
        signOutContinuation = nil
        continuation?.resume()
    }
}

private actor AuthManagerSignOutTestTokenStore: StackAuthTokenStoreProtocol {
    private var accessToken: String?
    private var refreshToken: String?
    private var shouldSuspendNextSetTokens = false
    private var suspendedSetTokensContinuation: CheckedContinuation<Void, Never>?
    private var suspendedSetTokensWaiter: CheckedContinuation<Void, Never>?

    func suspendNextSetTokens() {
        shouldSuspendNextSetTokens = true
    }

    func waitForSuspendedSetTokens() async {
        if suspendedSetTokensContinuation != nil {
            return
        }
        await withCheckedContinuation { continuation in
            suspendedSetTokensWaiter = continuation
        }
    }

    func resumeSuspendedSetTokens() {
        shouldSuspendNextSetTokens = false
        let continuation = suspendedSetTokensContinuation
        suspendedSetTokensContinuation = nil
        continuation?.resume()
    }

    func getStoredAccessToken() async -> String? {
        accessToken
    }

    func getStoredRefreshToken() async -> String? {
        refreshToken
    }

    func setTokens(accessToken: String?, refreshToken: String?) async {
        if shouldSuspendNextSetTokens {
            await withCheckedContinuation { continuation in
                suspendedSetTokensContinuation = continuation
                suspendedSetTokensWaiter?.resume()
                suspendedSetTokensWaiter = nil
            }
        }
        self.accessToken = accessToken
        self.refreshToken = refreshToken
    }

    func clearTokens() async {
        accessToken = nil
        refreshToken = nil
    }

    func compareAndSet(
        compareRefreshToken: String,
        newRefreshToken: String?,
        newAccessToken: String?
    ) async {
        guard refreshToken == compareRefreshToken else { return }
        refreshToken = newRefreshToken
        accessToken = newAccessToken
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
