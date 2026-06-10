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
