import Security
import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

// MARK: - CodexValidators Tests

final class CodexValidatorTests: XCTestCase {

    // MARK: - isValidAccessToken

    func testValidJWTAccessTokenAccepted() {
        let token = ["eyJhbGciOiJSUzI1NiI", "eyJzdWIiOiIxMjM0NTY3ODkwIn0", "signature_part"].joined(separator: ".")
        XCTAssertTrue(CodexValidators.isValidAccessToken(token))
    }

    func testAccessTokenWithWhitespaceTrimmed() {
        let token = "  " + ["eyJhbGciOiJSUzI1NiI", "eyJzdWIiOiIxMjM0NTY3ODkwIn0", "signature_part"].joined(separator: ".") + "  \n"
        XCTAssertTrue(CodexValidators.isValidAccessToken(token))
    }

    func testAccessTokenMissingEyJPrefixRejected() {
        let token = "notajwt.second.third"
        XCTAssertFalse(CodexValidators.isValidAccessToken(token))
    }

    func testAccessTokenWithTwoSegmentsRejected() {
        let token = ["eyJhbGciOiJSUzI1NiI", "eyJzdWIiOiIxMjM0NTY3ODkwIn0"].joined(separator: ".")
        XCTAssertFalse(CodexValidators.isValidAccessToken(token))
    }

    func testAccessTokenWithFourSegmentsRejected() {
        let token = ["eyJhbGciOiJSUzI1NiI", "second", "third", "fourth"].joined(separator: ".")
        XCTAssertFalse(CodexValidators.isValidAccessToken(token))
    }

    func testEmptyAccessTokenRejected() {
        XCTAssertFalse(CodexValidators.isValidAccessToken(""))
    }

    func testWhitespaceOnlyAccessTokenRejected() {
        XCTAssertFalse(CodexValidators.isValidAccessToken("   "))
    }

    // MARK: - isValidAccountId

    func testEmptyAccountIdAccepted() {
        XCTAssertTrue(CodexValidators.isValidAccountId(""))
    }

    func testWhitespaceOnlyAccountIdAccepted() {
        // Trimmed to empty → valid
        XCTAssertTrue(CodexValidators.isValidAccountId("   "))
    }

    func testNormalAccountIdAccepted() {
        XCTAssertTrue(CodexValidators.isValidAccountId("user-u8MOwuoKUItNfaaPRCDeoJXU"))
    }

    func testAccountIdWithSpacesRejected() {
        XCTAssertFalse(CodexValidators.isValidAccountId("user id with spaces"))
    }

    func testAccountIdWithNewlineRejected() {
        XCTAssertFalse(CodexValidators.isValidAccountId("user-id\ninjection"))
    }
}

// MARK: - ProviderClaudeValidators Tests

final class ProviderClaudeValidatorTests: XCTestCase {

    func testValidOrgIdAccepted() {
        XCTAssertTrue(ProviderClaudeValidators.isValidOrgId("org-abc123"))
    }

    func testEmptyOrgIdRejected() {
        XCTAssertFalse(ProviderClaudeValidators.isValidOrgId(""))
    }

    func testOrgIdWithSlashRejected() {
        XCTAssertFalse(ProviderClaudeValidators.isValidOrgId("org/traversal"))
    }

    func testOrgIdWithDoubleDotRejected() {
        XCTAssertFalse(ProviderClaudeValidators.isValidOrgId("org..traversal"))
    }

    func testOrgIdWithColonRejected() {
        XCTAssertFalse(ProviderClaudeValidators.isValidOrgId("org:injection"))
    }

    func testOrgIdWithQuestionMarkRejected() {
        XCTAssertFalse(ProviderClaudeValidators.isValidOrgId("org?query=1"))
    }

    func testOrgIdWithHashRejected() {
        XCTAssertFalse(ProviderClaudeValidators.isValidOrgId("org#fragment"))
    }

    // MARK: sessionKey

    func testSessionKeyAcceptsTypicalValue() {
        XCTAssertTrue(ProviderClaudeValidators.isValidSessionKey("sk-ant-sid01-abc123"))
    }

    func testSessionKeyRejectsEmpty() {
        XCTAssertFalse(ProviderClaudeValidators.isValidSessionKey(""))
        XCTAssertFalse(ProviderClaudeValidators.isValidSessionKey("   "))
    }

    func testSessionKeyRejectsSemicolon() {
        XCTAssertFalse(ProviderClaudeValidators.isValidSessionKey("sk-ant;other=1"))
    }

    func testSessionKeyAcceptsEmbeddedEqualsButRejectsComma() {
        // Cookie values may legitimately contain `=` (base64 padding); keep
        // it. `;` and `,` stay rejected because they split cookie attributes.
        XCTAssertTrue(ProviderClaudeValidators.isValidSessionKey("sk-ant-abc=="))
        XCTAssertFalse(ProviderClaudeValidators.isValidSessionKey("sk,extra"))
    }

    func testSessionKeyAcceptsCookieAssignmentPrefix() {
        XCTAssertTrue(ProviderClaudeValidators.isValidSessionKey("sessionKey=sk-ant-sid01-abc"))
        XCTAssertTrue(ProviderClaudeValidators.isValidSessionKey("  sessionKey=sk-ant-sid01-abc  "))
        XCTAssertFalse(ProviderClaudeValidators.isValidSessionKey("sessionKey="))
    }

    func testStrippedSessionKeyRemovesPrefix() {
        XCTAssertEqual(ProviderClaudeValidators.strippedSessionKey("sessionKey=abc"), "abc")
        XCTAssertEqual(ProviderClaudeValidators.strippedSessionKey("  sessionKey=abc  "), "abc")
        XCTAssertEqual(ProviderClaudeValidators.strippedSessionKey("abc"), "abc")
    }

    func testSessionKeyRejectsControlCharacters() {
        XCTAssertFalse(ProviderClaudeValidators.isValidSessionKey("sk-ant\nextra"))
        XCTAssertFalse(ProviderClaudeValidators.isValidSessionKey("sk-ant\u{0007}"))
    }
}

// MARK: - ProviderISO8601DateParser Tests

final class ProviderISO8601DateParserTests: XCTestCase {

    func testParsesStandardISO8601() {
        let date = ProviderISO8601DateParser.parse("2026-04-10T12:30:00Z")
        XCTAssertNotNil(date)
    }

    func testParsesISO8601WithFractionalSeconds() {
        let date = ProviderISO8601DateParser.parse("2026-04-10T12:30:00.123Z")
        XCTAssertNotNil(date)
    }

    func testReturnsNilForNilInput() {
        XCTAssertNil(ProviderISO8601DateParser.parse(nil))
    }

    func testReturnsNilForEmptyString() {
        XCTAssertNil(ProviderISO8601DateParser.parse(""))
    }

    func testReturnsNilForGarbage() {
        XCTAssertNil(ProviderISO8601DateParser.parse("not-a-date"))
    }

    func testParsedDateHasCorrectComponents() throws {
        let date = try XCTUnwrap(ProviderISO8601DateParser.parse("2026-04-10T14:30:00Z"))
        let calendar = Calendar(identifier: .gregorian)
        var components = calendar.dateComponents(in: TimeZone(identifier: "UTC")!, from: date)
        XCTAssertEqual(components.year, 2026)
        XCTAssertEqual(components.month, 4)
        XCTAssertEqual(components.day, 10)
        XCTAssertEqual(components.hour, 14)
        XCTAssertEqual(components.minute, 30)
    }
}

// MARK: - ProviderSecret Redaction Tests

final class ProviderSecretRedactionTests: XCTestCase {
    func testDescriptionHidesFieldValues() {
        let secret = ProviderSecret(fields: [
            "sessionKey": "sk-ant-sid01-top-secret",
            "orgId": "00000000-0000-0000-0000-000000000001",
        ])
        let description = secret.description
        XCTAssertTrue(description.contains("<redacted>"))
        XCTAssertFalse(description.contains("sk-ant-sid01-top-secret"))
        XCTAssertFalse(description.contains("00000000-0000-0000-0000-000000000001"))
        XCTAssertTrue(description.contains("sessionKey"))
        XCTAssertTrue(description.contains("orgId"))
    }

    func testDebugDescriptionMatchesDescription() {
        let secret = ProviderSecret(fields: ["token": "s3cret"])
        XCTAssertEqual(secret.debugDescription, secret.description)
        XCTAssertFalse(secret.debugDescription.contains("s3cret"))
    }

    func testMirrorRedactsFieldValues() {
        let secret = ProviderSecret(fields: [
            "sessionKey": "sk-ant-sid01-top-secret",
            "orgId": "aaaa-bbbb",
        ])
        var dump = ""
        Swift.dump(secret, to: &dump)
        XCTAssertFalse(dump.contains("sk-ant-sid01-top-secret"))
        XCTAssertFalse(dump.contains("aaaa-bbbb"))
        XCTAssertTrue(dump.contains("<redacted>"))
    }

    func testStringInterpolationHidesFieldValues() {
        let secret = ProviderSecret(fields: ["sessionKey": "s3cret"])
        let interpolated = "captured: \(secret)"
        XCTAssertFalse(interpolated.contains("s3cret"))
        XCTAssertTrue(interpolated.contains("<redacted>"))
    }
}

// MARK: - ProviderUsageColorSettings Tests

@MainActor
final class ProviderUsageColorSettingsTests: XCTestCase {

    /// Each test spins up a fresh `ProviderUsageColorSettings` backed by an
    /// isolated `UserDefaults` suite so the tests never read from — or write
    /// to — the real `standard` domain used by the app.
    private var suiteName: String!
    private var userDefaults: UserDefaults!
    private var settings: ProviderUsageColorSettings!

    override func setUp() {
        super.setUp()
        suiteName = "cmux.tests.provider-colors.\(UUID().uuidString)"
        userDefaults = UserDefaults(suiteName: suiteName)!
        settings = ProviderUsageColorSettings(userDefaults: userDefaults)
    }

    override func tearDown() {
        userDefaults.removePersistentDomain(forName: suiteName)
        settings = nil
        userDefaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testColorForZeroPercentReturnsLowColor() {
        let color = settings.color(for: 0)
        XCTAssertNotNil(color)
    }

    func testColorFor100PercentReturnsHighColor() {
        let color = settings.color(for: 100)
        XCTAssertNotNil(color)
    }

    func testColorForNegativePercentClampedToZero() {
        XCTAssertEqual(settings.color(for: -10), settings.color(for: 0))
    }

    func testColorForOver100ClampedTo100() {
        XCTAssertEqual(settings.color(for: 110), settings.color(for: 100))
    }

    func testDefaultThresholds() {
        XCTAssertEqual(settings.lowMidThreshold, 85)
        XCTAssertEqual(settings.midHighThreshold, 95)
        XCTAssertTrue(settings.interpolate)
    }

    func testSetThresholdsEnforcesOrder() {
        settings.setThresholds(low: 40, high: 70)
        XCTAssertEqual(settings.lowMidThreshold, 40)
        XCTAssertEqual(settings.midHighThreshold, 70)

        // Invalid (low >= high) must be rejected outright.
        settings.setThresholds(low: 80, high: 70)
        XCTAssertEqual(settings.lowMidThreshold, 40)
        XCTAssertEqual(settings.midHighThreshold, 70)
    }

    func testResetRestoresDefaults() {
        settings.setThresholds(low: 30, high: 60)
        settings.interpolate = false
        settings.resetToDefaults()
        XCTAssertEqual(settings.lowMidThreshold, 85)
        XCTAssertEqual(settings.midHighThreshold, 95)
        XCTAssertTrue(settings.interpolate)
    }
}

// MARK: - ProviderRegistry Tests

final class ProviderRegistryTests: XCTestCase {

    func testRegistryContainsClaude() {
        let claude = ProviderRegistry.provider(id: "claude")
        XCTAssertNotNil(claude)
        XCTAssertEqual(claude?.id, "claude")
    }

    func testRegistryContainsCodex() {
        let codex = ProviderRegistry.provider(id: "codex")
        XCTAssertNotNil(codex)
        XCTAssertEqual(codex?.id, "codex")
    }

    func testRegistryReturnsNilForUnknownProvider() {
        XCTAssertNil(ProviderRegistry.provider(id: "nonexistent"))
    }

    func testUIProvidersHaveCredentialFields() {
        for provider in ProviderRegistry.ui {
            XCTAssertFalse(provider.credentialFields.isEmpty, "\(provider.id) should have credential fields")
        }
    }

    func testAllProvidersHaveUniqueIds() {
        let ids = ProviderRegistry.all.map(\.id)
        XCTAssertEqual(ids.count, Set(ids).count, "Provider IDs must be unique")
    }
}

// MARK: - ProviderHTTP Tests

final class ProviderHTTPTests: XCTestCase {

    func testMakeSessionAppliesTimeout() {
        let session = ProviderHTTP.makeSession(timeout: 7)
        XCTAssertEqual(session.configuration.timeoutIntervalForRequest, 7)
        XCTAssertEqual(session.configuration.timeoutIntervalForResource, 7)
    }

    /// The provider fetchers must never persist credentials to disk via a
    /// shared URL cache, HTTP cookie store, or URLCredential store. Those
    /// are all derived from `URLSessionConfiguration.ephemeral`, so the
    /// test asserts the marker of an ephemeral config: it has no HTTP
    /// cookie storage. If someone flips to `.default` by accident, this
    /// test catches it before a token ends up cached on disk.
    func testMakeSessionIsEphemeral() {
        let session = ProviderHTTP.makeSession(timeout: 5)
        XCTAssertNil(session.configuration.httpCookieStorage)
        XCTAssertNil(session.configuration.urlCache)
    }

    // MARK: - sanitizeHeaderValue

    /// A header value carrying `\r\n` could inject an additional header or
    /// body separator onto the wire. The sanitizer must strip those control
    /// bytes before the value ever reaches `URLRequest.setValue`.
    func testSanitizeHeaderValueStripsCRLF() {
        let input = "token\r\nX-Injected: evil"
        let sanitized = ProviderHTTP.sanitizeHeaderValue(input)
        XCTAssertFalse(sanitized.contains("\r"))
        XCTAssertFalse(sanitized.contains("\n"))
    }

    func testSanitizeHeaderValueStripsBareNewline() {
        let sanitized = ProviderHTTP.sanitizeHeaderValue("abc\ndef")
        XCTAssertFalse(sanitized.contains("\n"))
        XCTAssertEqual(sanitized, "abcdef")
    }

    func testSanitizeHeaderValueStripsBareCarriageReturn() {
        let sanitized = ProviderHTTP.sanitizeHeaderValue("abc\rdef")
        XCTAssertFalse(sanitized.contains("\r"))
        XCTAssertEqual(sanitized, "abcdef")
    }

    func testSanitizeHeaderValuePreservesSafeCharacters() {
        let safe = "Bearer sk-ant-sid01-abc.def-ghi_jkl=="
        XCTAssertEqual(ProviderHTTP.sanitizeHeaderValue(safe), safe)
    }

    func testSanitizeHeaderValueStripsCookieAttributeSeparators() {
        // `;` / `,` would let a malformed value splice in extra cookie
        // attributes. They must be stripped alongside the control chars.
        let sanitized = ProviderHTTP.sanitizeHeaderValue("a;b,c")
        XCTAssertEqual(sanitized, "abc")
    }
}

// MARK: - ProviderAccountStore round-trip

@MainActor
final class ProviderAccountStoreRoundTripTests: XCTestCase {

    private var store: ProviderAccountStore!
    private var userDefaults: UserDefaults!
    private var suiteName: String!
    private var testService: String!

    override func setUp() {
        super.setUp()
        // Each test runs against its own in-memory UserDefaults suite and
        // its own unique keychain service so runs can't collide with the
        // real app's stored accounts or with each other.
        suiteName = "cmux.tests.providerAccountStore.\(UUID().uuidString)"
        userDefaults = UserDefaults(suiteName: suiteName)
        userDefaults.removePersistentDomain(forName: suiteName)
        testService = "com.cmuxterm.tests.provider-accounts.\(UUID().uuidString)"

        store = ProviderAccountStore(
            userDefaults: userDefaults,
            indexKey: "cmux.tests.providers.accounts.index",
            keychainServiceResolver: { [testService] _ in testService! }
        )
    }

    override func tearDown() {
        // Wipe any keychain items still tied to the test service, regardless
        // of whether the test path hit `remove` or not.
        let wipeQuery: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: testService as Any,
        ]
        SecItemDelete(wipeQuery as CFDictionary)
        userDefaults.removePersistentDomain(forName: suiteName)
        store = nil
        userDefaults = nil
        suiteName = nil
        testService = nil
        super.tearDown()
    }

    @MainActor
    func testAddLoadUpdateRemoveRoundTrip() async throws {
        XCTAssertTrue(store.accounts.isEmpty)

        let originalSecret = ProviderSecret(fields: [
            "sessionKey": "sk-ant-sid01-test-token",
            "orgId": "00000000-0000-0000-0000-000000000001",
        ])

        // add()
        try await store.add(providerId: "claude", displayName: "Personal", secret: originalSecret)
        XCTAssertEqual(store.accounts.count, 1)
        let account = try XCTUnwrap(store.accounts.first)
        XCTAssertEqual(account.providerId, "claude")
        XCTAssertEqual(account.displayName, "Personal")

        // secret(for:) returns what we saved
        let loaded = try await store.secret(for: account.id)
        XCTAssertEqual(loaded.fields, originalSecret.fields)

        // update() rotates credentials and renames
        let rotatedSecret = ProviderSecret(fields: [
            "sessionKey": "sk-ant-sid01-rotated-token",
            "orgId": "00000000-0000-0000-0000-000000000002",
        ])
        try await store.update(id: account.id, displayName: "Personal (rotated)", secret: rotatedSecret)
        XCTAssertEqual(store.accounts.first?.displayName, "Personal (rotated)")
        let rotated = try await store.secret(for: account.id)
        XCTAssertEqual(rotated.fields, rotatedSecret.fields)

        // remove() deletes both the keychain item and the index entry
        let createdId = account.id
        try await store.remove(id: createdId)
        XCTAssertTrue(store.accounts.isEmpty)

        let probeStatus = ProviderAccountKeychain.probePresence(for: createdId, service: testService)
        XCTAssertEqual(probeStatus, errSecItemNotFound, "Keychain secret should be deleted after remove")

        do {
            _ = try await store.secret(for: createdId)
            XCTFail("Expected .notFound after remove")
        } catch ProviderAccountStoreError.notFound {
            // expected
        } catch {
            XCTFail("Expected .notFound after remove, got \(error)")
        }
    }

    @MainActor
    func testIndexPersistsAcrossInstances() async throws {
        try await store.add(
            providerId: "codex",
            displayName: "Work",
            secret: ProviderSecret(fields: ["accessToken": ["eyJhbGciOiJ", "eyJzdWIi", "sig"].joined(separator: ".")])
        )
        let createdId = try XCTUnwrap(store.accounts.first?.id)

        // Spin up a second store pointing at the same UserDefaults suite +
        // service resolver. It should see the account from the first one.
        let reloaded = ProviderAccountStore(
            userDefaults: userDefaults,
            indexKey: "cmux.tests.providers.accounts.index",
            keychainServiceResolver: { [testService] _ in testService! }
        )

        XCTAssertEqual(reloaded.accounts.count, 1)
        XCTAssertEqual(reloaded.accounts.first?.id, createdId)
        let secret = try await reloaded.secret(for: createdId)
        XCTAssertEqual(
            secret.fields["accessToken"],
            ["eyJhbGciOiJ", "eyJzdWIi", "sig"].joined(separator: ".")
        )
    }
}

// MARK: - ProviderUsageResetLabel Tests

final class ProviderUsageResetLabelTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeWindow(utilization: Int, resetsAt: Date?) -> ProviderUsageWindow {
        ProviderUsageWindow(
            utilization: utilization,
            resetsAt: resetsAt,
            windowSeconds: 18000
        )
    }

    // MARK: - No resetsAt (nil)

    func testSessionWithUtilizationButNoResetIsAwaitingRefresh() {
        let window = makeWindow(utilization: 50, resetsAt: nil)
        let result = providerUsageResetLabel(window: window, isSession: true, now: now)
        XCTAssertEqual(result, .awaitingRefresh)
    }

    func testSessionWithZeroUtilizationAndNoResetIsNotStarted() {
        let window = makeWindow(utilization: 0, resetsAt: nil)
        let result = providerUsageResetLabel(window: window, isSession: true, now: now)
        XCTAssertEqual(result, .sessionNotStarted)
    }

    func testWeekWithUtilizationButNoResetIsAwaitingRefresh() {
        let window = makeWindow(utilization: 50, resetsAt: nil)
        let result = providerUsageResetLabel(window: window, isSession: false, now: now)
        XCTAssertEqual(result, .awaitingRefresh)
    }

    func testWeekWithZeroUtilizationAndNoResetIsUnknown() {
        let window = makeWindow(utilization: 0, resetsAt: nil)
        let result = providerUsageResetLabel(window: window, isSession: false, now: now)
        XCTAssertEqual(result, .weekResetUnknown)
    }

    // MARK: - resetsAt relative to now

    func testFutureResetReturnsResetsAt() {
        let resetsAt = now.addingTimeInterval(3600)
        let window = makeWindow(utilization: 50, resetsAt: resetsAt)
        let result = providerUsageResetLabel(window: window, isSession: true, now: now)
        XCTAssertEqual(result, .resetsAt(resetsAt))
    }

    func testPastResetWithUtilizationIsStaleAwaitingRefresh() {
        let resetsAt = now.addingTimeInterval(-3600)
        let window = makeWindow(utilization: 50, resetsAt: resetsAt)
        let result = providerUsageResetLabel(window: window, isSession: true, now: now)
        XCTAssertEqual(result, .awaitingRefresh)
    }
}

// MARK: - ProviderStatusRanking Tests

final class ProviderStatusRankingTests: XCTestCase {

    private func makeIncident(id: String, impact: String) -> ProviderIncident {
        ProviderIncident(
            id: id,
            name: "Incident \(id)",
            status: "investigating",
            impact: impact,
            updatedAt: nil
        )
    }

    func testCriticalOutranksMaintenance() {
        let maintenance = makeIncident(id: "m", impact: "maintenance")
        let critical = makeIncident(id: "c", impact: "critical")

        XCTAssertEqual(
            ProviderStatusRanking.worstImpactSeverity(in: [maintenance, critical]),
            3
        )
        XCTAssertEqual(
            ProviderStatusRanking.worstIncident(in: [maintenance, critical])?.id,
            "c"
        )
        XCTAssertEqual(
            ProviderStatusRanking.statusText(for: [maintenance, critical]),
            String(localized: "provider.status.critical", defaultValue: "Critical")
        )
    }

    func testMaintenanceWinsOnlyWhenAlone() {
        let maintenance = makeIncident(id: "m", impact: "maintenance")
        XCTAssertEqual(ProviderStatusRanking.worstImpactSeverity(in: [maintenance]), 0)
        XCTAssertEqual(
            ProviderStatusRanking.statusText(for: [maintenance]),
            String(localized: "providers.accounts.status.maintenance", defaultValue: "Maintenance")
        )
    }

    func testMinorBeatsMaintenance() {
        let maintenance = makeIncident(id: "m", impact: "maintenance")
        let minor = makeIncident(id: "x", impact: "minor")
        XCTAssertEqual(ProviderStatusRanking.worstIncident(in: [maintenance, minor])?.id, "x")
    }
}
