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

@Suite struct TerminalNotificationSoundGateTests {
    private let workspaceId = UUID()
    private let surfaceId = UUID()

    @Test func firstSoundForAKeyIsGranted() {
        let gate = TerminalNotificationSoundGate()
        #expect(gate.shouldPlaySound(forKey: "surface-a"))
    }

    @Test func secondSoundWithinTheWindowIsSilenced() {
        let gate = TerminalNotificationSoundGate(suppressionWindow: 2.0)
        let start = Date(timeIntervalSinceReferenceDate: 1_000)
        #expect(gate.shouldPlaySound(forKey: "surface-a", now: start))
        #expect(!gate.shouldPlaySound(forKey: "surface-a", now: start.addingTimeInterval(0.05)))
        #expect(!gate.shouldPlaySound(forKey: "surface-a", now: start.addingTimeInterval(1.95)))
    }

    @Test func soundIsGrantedAgainAfterTheWindowElapses() {
        let gate = TerminalNotificationSoundGate(suppressionWindow: 2.0)
        let start = Date(timeIntervalSinceReferenceDate: 1_000)
        #expect(gate.shouldPlaySound(forKey: "surface-a", now: start))
        #expect(gate.shouldPlaySound(forKey: "surface-a", now: start.addingTimeInterval(2.05)))
    }

    @Test func deniedAttemptsDoNotExtendTheWindow() {
        let gate = TerminalNotificationSoundGate(suppressionWindow: 2.0)
        let start = Date(timeIntervalSinceReferenceDate: 1_000)
        #expect(gate.shouldPlaySound(forKey: "surface-a", now: start))
        // A silenced banner at t+1.5 must not push the next grant to t+3.5.
        #expect(!gate.shouldPlaySound(forKey: "surface-a", now: start.addingTimeInterval(1.5)))
        #expect(gate.shouldPlaySound(forKey: "surface-a", now: start.addingTimeInterval(2.05)))
    }

    @Test func distinctKeysDoNotShareAWindow() {
        let gate = TerminalNotificationSoundGate(suppressionWindow: 2.0)
        let start = Date(timeIntervalSinceReferenceDate: 1_000)
        #expect(gate.shouldPlaySound(forKey: "surface-a", now: start))
        #expect(gate.shouldPlaySound(forKey: "surface-b", now: start.addingTimeInterval(0.1)))
    }

    @Test func missingKeysAreNeverSilenced() {
        let gate = TerminalNotificationSoundGate(suppressionWindow: 2.0)
        let start = Date(timeIntervalSinceReferenceDate: 1_000)
        #expect(gate.shouldPlaySound(forKey: nil, now: start))
        #expect(gate.shouldPlaySound(forKey: nil, now: start.addingTimeInterval(0.1)))
        #expect(gate.shouldPlaySound(forKey: "", now: start.addingTimeInterval(0.2)))
    }

    @Test func keyPrefersTheSurfaceAndFallsBackToTheWorkspace() {
        #expect(
            TerminalNotificationSoundGate.key(workspaceId: workspaceId, surfaceId: surfaceId)
                == surfaceId.uuidString
        )
        #expect(
            TerminalNotificationSoundGate.key(workspaceId: workspaceId, surfaceId: nil)
                == workspaceId.uuidString
        )
    }

    @Test func bothBannerPathsForOnePromptShareTheWindow() {
        // The agent-hook banner (TerminalNotificationStore) and the feed
        // decision banner (FeedCoordinator) compute the same key for one
        // surface, so whichever posts first wins the sound and the other is
        // silenced — regardless of arrival order.
        let gate = TerminalNotificationSoundGate(suppressionWindow: 2.0)
        let key = TerminalNotificationSoundGate.key(workspaceId: workspaceId, surfaceId: surfaceId)
        let start = Date(timeIntervalSinceReferenceDate: 1_000)
        #expect(gate.shouldPlaySound(forKey: key, now: start))
        #expect(!gate.shouldPlaySound(forKey: key, now: start.addingTimeInterval(0.3)))
    }
}
