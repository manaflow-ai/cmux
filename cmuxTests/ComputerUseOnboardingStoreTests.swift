import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Computer Use verified completion")
@MainActor
struct ComputerUseOnboardingStoreTests {
    @Test(.timeLimit(.minutes(1))) func completionNotifiesSettingsWithoutAnAppActivation() async throws {
        let fixture = try ComputerUseOnboardingFixture()
        defer { fixture.remove() }
        let store = fixture.store()
        store.apply(.setEnabled(true))
        store.restore(for: "synthetic-signed-helper-a")
        var updates = store.updates().makeAsyncIterator()
        #expect(await updates.next() != nil)
        _ = store.finishVerification(.ready, attempt: try #require(store.beginVerification()))
        #expect(await updates.next() != nil)
        #expect(store.phase.isReady)
        store.statusChanged() // The runtime received the final daemon acknowledgement.
        #expect(await updates.next() != nil)
    }

    @Test func grantsWithoutCompletionRequireCaptureConfirmation() throws {
        let fixture = try ComputerUseOnboardingFixture()
        defer { fixture.remove() }
        let store = fixture.store()
        store.apply(.setEnabled(true))
        store.restore(for: "synthetic-signed-helper-a")
        #expect(store.phase == .onboardingRequired)
        let attempt = try #require(store.beginVerification())
        #expect(store.finishVerification(.notCapturable, attempt: attempt) == .notCapturable)
        #expect(!store.phase.isReady)
        #expect(store.finishVerification(.unavailable, attempt: attempt) == .unavailable)
        #expect(!store.phase.isReady)
        #expect(store.finishVerification(.ready, attempt: attempt) == .ready)
        #expect(store.phase == .ready)
    }

    @Test func completionSurvivesRestartAndAnEmptyActivityDirectory() throws {
        let fixture = try ComputerUseOnboardingFixture()
        defer { fixture.remove() }
        let store = fixture.store()
        store.apply(.setEnabled(true))
        store.restore(for: "synthetic-signed-helper-a")
        let attempt = try #require(store.beginVerification())
        #expect(store.finishVerification(.ready, attempt: attempt) == .ready)
        // Activity snapshots are unrelated to admission and may be absent or empty.
        try FileManager.default.createDirectory(at: fixture.paths.stateDirectoryURL, withIntermediateDirectories: true)
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.paths.stateDirectoryURL.path).isEmpty)
        let restarted = fixture.store()
        restarted.restore(for: "synthetic-signed-helper-a")
        #expect(restarted.phase == .disabled(onboardingComplete: true))
        restarted.apply(.setEnabled(true))
        #expect(restarted.phase == .ready)
        restarted.restore(for: "synthetic-signed-helper-a")
        #expect(restarted.phase == .ready)
        try FileManager.default.removeItem(at: fixture.paths.stateDirectoryURL)
        #expect(fixture.defaults.data(forKey: fixture.completionKey) != nil)
    }

    @Test func completionDoesNotTransferAcrossTagsOrHelperBuilds() throws {
        let fixture = try ComputerUseOnboardingFixture()
        defer { fixture.remove() }
        let original = fixture.store()
        original.apply(.setEnabled(true))
        original.restore(for: "synthetic-signed-helper-a")
        _ = original.finishVerification(.ready, attempt: try #require(original.beginVerification()))

        let differentTag = fixture.store(scope: "other-synthetic-tag")
        differentTag.apply(.setEnabled(true))
        differentTag.restore(for: "synthetic-signed-helper-a")
        #expect(!differentTag.phase.isReady)
        let differentBuild = fixture.store()
        differentBuild.apply(.setEnabled(true))
        differentBuild.restore(for: "synthetic-signed-helper-b")
        #expect(!differentBuild.phase.isReady)
    }

    @Test func disableAndReplacementRejectInFlightVerification() throws {
        let fixture = try ComputerUseOnboardingFixture()
        defer { fixture.remove() }
        let store = fixture.store()
        store.apply(.setEnabled(true))
        store.restore(for: "synthetic-signed-helper-a")
        let disabledAttempt = try #require(store.beginVerification())
        store.apply(.setEnabled(false))
        store.apply(.setEnabled(true))
        #expect(store.finishVerification(.ready, attempt: disabledAttempt) == .unavailable)
        let replacedAttempt = try #require(store.beginVerification())
        store.invalidateHelper()
        store.restore(for: "synthetic-signed-helper-b")
        #expect(store.finishVerification(.ready, attempt: replacedAttempt) == .unavailable)
        #expect(fixture.defaults.data(forKey: fixture.completionKey) == nil)
    }

    @Test func reinstallInvalidationSurvivesRestartBeforeProvisioningFinishes() throws {
        let fixture = try ComputerUseOnboardingFixture()
        defer { fixture.remove() }
        let store = fixture.store()
        store.apply(.setEnabled(true))
        store.restore(for: "synthetic-signed-helper-a")
        _ = store.finishVerification(.ready, attempt: try #require(store.beginVerification()))
        store.invalidateHelper()
        store.invalidateHelper()
        let restarted = fixture.store()
        restarted.restore(for: "synthetic-signed-helper-a")
        restarted.apply(.setEnabled(true))
        #expect(restarted.phase == .onboardingRequired)
    }

    @Test func legacyCompletionMigratesOnlyForAnUnchangedInstalledHelper() throws {
        let fixture = try ComputerUseOnboardingFixture()
        defer { fixture.remove() }
        fixture.defaults.set(true, forKey: ComputerUseOnboardingStore.legacyCompletionKey)
        let store = fixture.store()
        store.restore(for: "synthetic-signed-helper-a")
        #expect(store.phase.isReady)
        #expect(fixture.defaults.object(forKey: ComputerUseOnboardingStore.legacyCompletionKey) == nil)
        #expect(fixture.defaults.data(forKey: fixture.completionKey) != nil)

        fixture.defaults.set(true, forKey: ComputerUseOnboardingStore.legacyCompletionKey)
        let missingHelper = fixture.store()
        missingHelper.invalidateHelper()
        missingHelper.restore(for: "synthetic-signed-helper-a")
        #expect(!missingHelper.phase.isReady)
    }

    @Test(arguments: ["not-json", "{}", #"{"version":2,"scope":"fixture","helperIdentity":"synthetic-signed-helper-a"}"#])
    func malformedOrFutureRecordsNeverFallBackToTheLegacyBoolean(record: String) throws {
        let fixture = try ComputerUseOnboardingFixture()
        defer { fixture.remove() }
        fixture.defaults.set(Data(record.utf8), forKey: fixture.completionKey)
        fixture.defaults.set(true, forKey: ComputerUseOnboardingStore.legacyCompletionKey)
        let store = fixture.store()
        store.restore(for: "synthetic-signed-helper-a")
        #expect(!store.phase.isReady)
    }

    @Test func confirmedRevocationInvalidatesCompletion() throws {
        let fixture = try ComputerUseOnboardingFixture()
        defer { fixture.remove() }
        let store = fixture.store()
        store.apply(.setEnabled(true))
        store.restore(for: "synthetic-signed-helper-a")
        _ = store.finishVerification(.ready, attempt: try #require(store.beginVerification()))
        store.permissionsRevoked()
        #expect(store.phase == .onboardingRequired)
        #expect(fixture.defaults.data(forKey: fixture.completionKey) == nil)
        #expect(store.beginVerification() != nil)
    }
}
