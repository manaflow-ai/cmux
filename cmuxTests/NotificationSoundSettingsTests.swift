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
}
