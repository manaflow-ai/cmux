import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite struct NotificationSoundSettingsTests {
    @Test func namedSystemSoundStagesDistinctSoundFile() throws {
        let fileManager = FileManager.default
        let stagedName = NotificationSoundSettings.stagedSystemSoundFileName(for: "Bottle")
        let stagingDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-notification-sound-\(UUID().uuidString)", isDirectory: true)
        let stagedURL = stagingDirectory.appendingPathComponent(stagedName, isDirectory: false)
        defer {
            try? fileManager.removeItem(at: stagingDirectory)
        }

        #expect(try #require(NotificationSoundSettings.stagedSystemSoundName(
            for: "Bottle",
            stagingDirectory: stagingDirectory
        )) == stagedName)
        #expect(fileManager.fileExists(atPath: stagedURL.path))

        let sourceURL = URL(fileURLWithPath: "/System/Library/Sounds/Bottle.aiff", isDirectory: false)
        let sourceData = try Data(contentsOf: sourceURL)
        let stagedData = try Data(contentsOf: stagedURL)
        #expect(stagedData == sourceData)
    }

    @Test func nonSoundSentinelsDoNotStageSystemSoundFiles() {
        #expect(NotificationSoundSettings.stagedSystemSoundName(for: "default") == nil)
        #expect(NotificationSoundSettings.stagedSystemSoundName(for: "none") == nil)
        #expect(NotificationSoundSettings.stagedSystemSoundName(for: NotificationSoundSettings.customFileValue) == nil)
    }

    @Test func activeFocusAssertionSuppressesFallbackSound() throws {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-dnd-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: directory) }
        let assertions = directory.appendingPathComponent("Assertions.json", isDirectory: false)

        // A Focus is active: storeAssertionRecords holds a live assertion.
        try Data(#"{"data":[{"storeAssertionRecords":[{"assertionDetails":{"x":1}}]}]}"#.utf8)
            .write(to: assertions)
        #expect(NotificationSoundSettings.isSuppressedByActiveFocus(assertionsFileURL: assertions))
    }

    @Test func endedFocusDoesNotSuppressSound() throws {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-dnd-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: directory) }
        let assertions = directory.appendingPathComponent("Assertions.json", isDirectory: false)

        // No Focus active: the assertion array is empty.
        try Data(#"{"data":[{"storeAssertionRecords":[]}]}"#.utf8).write(to: assertions)
        #expect(!NotificationSoundSettings.isSuppressedByActiveFocus(assertionsFileURL: assertions))
    }

    @Test func missingAssertionStoreFailsOpen() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-dnd-missing-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("Assertions.json", isDirectory: false)
        #expect(!NotificationSoundSettings.isSuppressedByActiveFocus(assertionsFileURL: missing))
    }

    // The canonical repro for the Focus bug is: the user enables a Focus, and
    // the next notification must already be silent. A cached Focus snapshot
    // that refreshes only after deciding lets exactly that first sound punch
    // through, so these tests drive the real playback entry point and assert
    // on the per-play decision, not on the pure predicate.

    @Test func firstPlayAfterFocusActivationIsSuppressed() async throws {
        let fixture = try ActiveFocusFixture()
        defer { fixture.cleanUp() }

        try fixture.writeAssertions(#"{"data":[{"storeAssertionRecords":[{"a":1}]}]}"#)
        #expect(await fixture.playOutcome() == false)
    }

    @Test func firstPlayAfterFocusEndsIsAudible() async throws {
        let fixture = try ActiveFocusFixture()
        defer { fixture.cleanUp() }

        try fixture.writeAssertions(#"{"data":[{"storeAssertionRecords":[{"a":1}]}]}"#)
        #expect(await fixture.playOutcome() == false)

        // The Focus ended: the very next play must be audible again.
        try fixture.writeAssertions(#"{"data":[{"storeAssertionRecords":[]}]}"#)
        #expect(await fixture.playOutcome() == true)
    }

    @Test func playbackFailsOpenWhenAssertionStoreIsMissing() async throws {
        let fixture = try ActiveFocusFixture(createAssertionsFile: false)
        defer { fixture.cleanUp() }

        #expect(await fixture.playOutcome() == true)
    }

    // The out-of-band fallback (direct NSSound) fires exactly when the OS
    // will not deliver the banner. A user who explicitly denied cmux
    // notifications asked for silence, so the fallback sound is stripped for
    // .denied - and only for .denied: fresh installs and granted states keep
    // the audible fallback, and non-sound effects are never touched.

    @Test func deniedAuthorizationStripsFallbackSound() {
        var effects = TerminalNotificationPolicyEffects()
        effects.sound = true
        let denied = TerminalNotificationStore.fallbackEffects(effects, authorizationState: .denied)
        #expect(!denied.sound)
    }

    @Test func deniedAuthorizationLeavesOtherEffectsIntact() {
        var effects = TerminalNotificationPolicyEffects()
        effects.sound = true
        let denied = TerminalNotificationStore.fallbackEffects(effects, authorizationState: .denied)
        #expect(denied.command == effects.command)
        #expect(denied.record == effects.record)
        #expect(denied.desktop == effects.desktop)
        #expect(denied.markUnread == effects.markUnread)
    }

    @Test func otherAuthorizationStatesKeepFallbackSound() {
        var effects = TerminalNotificationPolicyEffects()
        effects.sound = true
        let states: [NotificationAuthorizationState] = [
            .notDetermined, .unknown, .authorized, .provisional, .ephemeral,
        ]
        for state in states {
            #expect(TerminalNotificationStore.fallbackEffects(effects, authorizationState: state).sound)
        }
    }
}

/// Drives `playSelectedSound` against a scratch assertion store and scratch
/// defaults whose selected sound is "none", so the decision is observable
/// without audible output.
private struct ActiveFocusFixture {
    let directory: URL
    let assertionsFileURL: URL
    let defaults: UserDefaults
    private let suiteName: String

    init(createAssertionsFile: Bool = true) throws {
        let fileManager = FileManager.default
        directory = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-dnd-play-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        assertionsFileURL = directory.appendingPathComponent("Assertions.json", isDirectory: false)
        if createAssertionsFile {
            try Data(#"{"data":[]}"#.utf8).write(to: assertionsFileURL)
        }
        suiteName = "cmux-tests-notification-sound-\(UUID().uuidString)"
        defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.set("none", forKey: NotificationSoundSettings.key)
    }

    func writeAssertions(_ json: String) throws {
        try Data(json.utf8).write(to: assertionsFileURL)
    }

    func playOutcome() async -> Bool {
        await withCheckedContinuation { continuation in
            NotificationSoundSettings.playSelectedSound(
                defaults: defaults,
                assertionsFileURL: assertionsFileURL
            ) { didPlay in
                continuation.resume(returning: didPlay)
            }
        }
    }

    func cleanUp() {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: directory)
    }
}

@Suite struct TerminalNotificationDeliveryGateTests {
    private let workspaceId = UUID()
    private let surfaceId = UUID()

    // MARK: Sound window

    @Test func firstSoundForAKeyIsGranted() {
        let gate = TerminalNotificationDeliveryGate()
        #expect(gate.claimSound(forKey: "surface-a"))
    }

    @Test func secondSoundWithinTheWindowIsSilenced() {
        let gate = TerminalNotificationDeliveryGate(soundWindow: 2.0)
        let start = Date(timeIntervalSinceReferenceDate: 1_000)
        #expect(gate.claimSound(forKey: "surface-a", now: start))
        #expect(!gate.claimSound(forKey: "surface-a", now: start.addingTimeInterval(0.05)))
        #expect(!gate.claimSound(forKey: "surface-a", now: start.addingTimeInterval(1.95)))
    }

    @Test func soundIsGrantedAgainAfterTheWindowElapses() {
        let gate = TerminalNotificationDeliveryGate(soundWindow: 2.0)
        let start = Date(timeIntervalSinceReferenceDate: 1_000)
        #expect(gate.claimSound(forKey: "surface-a", now: start))
        #expect(gate.claimSound(forKey: "surface-a", now: start.addingTimeInterval(2.05)))
    }

    @Test func deniedAttemptsDoNotExtendTheWindow() {
        let gate = TerminalNotificationDeliveryGate(soundWindow: 2.0)
        let start = Date(timeIntervalSinceReferenceDate: 1_000)
        #expect(gate.claimSound(forKey: "surface-a", now: start))
        // A silenced banner at t+1.5 must not push the next grant to t+3.5.
        #expect(!gate.claimSound(forKey: "surface-a", now: start.addingTimeInterval(1.5)))
        #expect(gate.claimSound(forKey: "surface-a", now: start.addingTimeInterval(2.05)))
    }

    @Test func distinctKeysDoNotShareAWindow() {
        let gate = TerminalNotificationDeliveryGate(soundWindow: 2.0)
        let start = Date(timeIntervalSinceReferenceDate: 1_000)
        #expect(gate.claimSound(forKey: "surface-a", now: start))
        #expect(gate.claimSound(forKey: "surface-b", now: start.addingTimeInterval(0.1)))
    }

    @Test func missingKeysAreNeverSilenced() {
        let gate = TerminalNotificationDeliveryGate(soundWindow: 2.0)
        let start = Date(timeIntervalSinceReferenceDate: 1_000)
        #expect(gate.claimSound(forKey: nil, now: start))
        #expect(gate.claimSound(forKey: nil, now: start.addingTimeInterval(0.1)))
        #expect(gate.claimSound(forKey: "", now: start.addingTimeInterval(0.2)))
    }

    @Test func keyPrefersTheSurfaceAndFallsBackToTheWorkspace() {
        #expect(
            TerminalNotificationDeliveryGate.key(workspaceId: workspaceId, surfaceId: surfaceId)
                == surfaceId.uuidString
        )
        #expect(
            TerminalNotificationDeliveryGate.key(workspaceId: workspaceId, surfaceId: nil)
                == workspaceId.uuidString
        )
    }

    // MARK: Blocking-decision claims

    @Test func blockingDecisionClaimsTheSurfaceUntilConcluded() {
        let gate = TerminalNotificationDeliveryGate()
        let start = Date(timeIntervalSinceReferenceDate: 1_000)
        #expect(!gate.hasActiveBlockingDecision(forKey: "surface-a", now: start))
        gate.beginBlockingDecision(forKey: "surface-a", now: start)
        #expect(gate.hasActiveBlockingDecision(forKey: "surface-a", now: start.addingTimeInterval(0.5)))
        #expect(!gate.hasActiveBlockingDecision(forKey: "surface-b", now: start.addingTimeInterval(0.5)))
        gate.endBlockingDecision(forKey: "surface-a")
        #expect(!gate.hasActiveBlockingDecision(forKey: "surface-a", now: start.addingTimeInterval(1.0)))
    }

    @Test func blockingClaimIsTimeBoxedWhileStillPending() {
        // A decision the user answers in the terminal stays pending app-side
        // until the hook timeout. The claim must stop suppressing unrelated
        // alerts (e.g. the completion banner) long before that.
        let gate = TerminalNotificationDeliveryGate(blockingClaimWindow: 5.0)
        let start = Date(timeIntervalSinceReferenceDate: 1_000)
        gate.beginBlockingDecision(forKey: "surface-a", now: start)
        #expect(gate.hasActiveBlockingDecision(forKey: "surface-a", now: start.addingTimeInterval(4.9)))
        #expect(!gate.hasActiveBlockingDecision(forKey: "surface-a", now: start.addingTimeInterval(5.1)))
    }

    @Test func overlappingBlockingDecisionsAreRefcounted() {
        let gate = TerminalNotificationDeliveryGate(blockingClaimWindow: 5.0)
        let start = Date(timeIntervalSinceReferenceDate: 1_000)
        gate.beginBlockingDecision(forKey: "surface-a", now: start)
        gate.beginBlockingDecision(forKey: "surface-a", now: start.addingTimeInterval(1.0))
        gate.endBlockingDecision(forKey: "surface-a")
        #expect(gate.hasActiveBlockingDecision(forKey: "surface-a", now: start.addingTimeInterval(2.0)))
        gate.endBlockingDecision(forKey: "surface-a")
        #expect(!gate.hasActiveBlockingDecision(forKey: "surface-a", now: start.addingTimeInterval(2.0)))
    }

    @Test func aFreshOverlappingDecisionExtendsTheClaimWindow() {
        let gate = TerminalNotificationDeliveryGate(blockingClaimWindow: 5.0)
        let start = Date(timeIntervalSinceReferenceDate: 1_000)
        gate.beginBlockingDecision(forKey: "surface-a", now: start)
        gate.beginBlockingDecision(forKey: "surface-a", now: start.addingTimeInterval(4.0))
        #expect(gate.hasActiveBlockingDecision(forKey: "surface-a", now: start.addingTimeInterval(7.0)))
    }

    @Test func unbalancedEndAndNilKeysAreNoOps() {
        let gate = TerminalNotificationDeliveryGate()
        gate.endBlockingDecision(forKey: "surface-a")
        #expect(!gate.hasActiveBlockingDecision(forKey: "surface-a"))
        gate.beginBlockingDecision(forKey: nil)
        gate.beginBlockingDecision(forKey: "")
        #expect(!gate.hasActiveBlockingDecision(forKey: nil))
        #expect(!gate.hasActiveBlockingDecision(forKey: ""))
    }

    // MARK: Raced-banner withdrawal selection

    @Test func withdrawalSelectsOnlyRecentBannersForTheSurface() {
        let now = Date(timeIntervalSinceReferenceDate: 10_000)
        let recentMatch = makeNotification(surfaceId: surfaceId, createdAt: now.addingTimeInterval(-1))
        let staleMatch = makeNotification(surfaceId: surfaceId, createdAt: now.addingTimeInterval(-30))
        let otherSurface = makeNotification(surfaceId: UUID(), createdAt: now.addingTimeInterval(-1))

        let ids = TerminalNotificationStore.withdrawableNotificationIds(
            in: [recentMatch, staleMatch, otherSurface],
            gateKey: TerminalNotificationDeliveryGate.key(workspaceId: workspaceId, surfaceId: surfaceId),
            since: now.addingTimeInterval(-5)
        )
        #expect(ids == [recentMatch.id.uuidString])
    }

    @Test func withdrawalFallsBackToTheWorkspaceKeyForSurfacelessBanners() {
        let now = Date(timeIntervalSinceReferenceDate: 10_000)
        let surfaceless = makeNotification(surfaceId: nil, createdAt: now)

        let ids = TerminalNotificationStore.withdrawableNotificationIds(
            in: [surfaceless],
            gateKey: TerminalNotificationDeliveryGate.key(workspaceId: workspaceId, surfaceId: nil),
            since: now.addingTimeInterval(-5)
        )
        #expect(ids == [surfaceless.id.uuidString])
    }

    private func makeNotification(surfaceId: UUID?, createdAt: Date) -> TerminalNotification {
        TerminalNotification(
            id: UUID(),
            tabId: workspaceId,
            surfaceId: surfaceId,
            title: "Claude",
            subtitle: "Permission",
            body: "Bash needs approval",
            createdAt: createdAt,
            isRead: false
        )
    }
}
