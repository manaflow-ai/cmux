import XCTest
import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WebKit
import ObjectiveC.runtime
import Bonsplit
import UserNotifications

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif


// MARK: - Notification sounds and custom sound staging
extension NotificationDockBadgeTests {
    func testNotificationSoundUsesSystemSoundForDefaultAndNamedSounds() {
        let suiteName = "NotificationDockBadgeTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create isolated UserDefaults suite")
            return
        }
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        XCTAssertTrue(NotificationSoundSettings.usesSystemSound(defaults: defaults))

        defaults.set("Ping", forKey: NotificationSoundSettings.key)
        XCTAssertTrue(NotificationSoundSettings.usesSystemSound(defaults: defaults))
        let stagingDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-notification-sound-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: stagingDirectory)
        }
        XCTAssertNotNil(NotificationSoundSettings.sound(
            defaults: defaults,
            systemSoundStagingDirectory: stagingDirectory
        ))
        let stagedSoundURL = stagingDirectory.appendingPathComponent(
            NotificationSoundSettings.stagedSystemSoundFileName(for: "Ping"),
            isDirectory: false
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: stagedSoundURL.path))
    }

    func testNotificationSoundDisablesSystemSoundForNoneAndCustomFile() {
        let suiteName = "NotificationDockBadgeTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create isolated UserDefaults suite")
            return
        }
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        defaults.set("none", forKey: NotificationSoundSettings.key)
        XCTAssertFalse(NotificationSoundSettings.usesSystemSound(defaults: defaults))
        XCTAssertNil(NotificationSoundSettings.sound(defaults: defaults))

        defaults.set(NotificationSoundSettings.customFileValue, forKey: NotificationSoundSettings.key)
        XCTAssertFalse(NotificationSoundSettings.usesSystemSound(defaults: defaults))
        XCTAssertNil(NotificationSoundSettings.sound(defaults: defaults))
    }

    func testNotificationCustomFileURLExpandsTildePath() {
        let suiteName = "NotificationDockBadgeTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create isolated UserDefaults suite")
            return
        }
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let rawPath = "~/Library/Sounds/my-custom.wav"
        defaults.set(rawPath, forKey: NotificationSoundSettings.customFilePathKey)
        let expectedPath = (rawPath as NSString).expandingTildeInPath
        XCTAssertEqual(NotificationSoundSettings.customFileURL(defaults: defaults)?.path, expectedPath)
    }

    func testNotificationCustomFileSelectionMustBeExplicit() {
        let suiteName = "NotificationDockBadgeTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create isolated UserDefaults suite")
            return
        }
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        defaults.set("~/Library/Sounds/my-custom.wav", forKey: NotificationSoundSettings.customFilePathKey)

        defaults.set("none", forKey: NotificationSoundSettings.key)
        XCTAssertFalse(NotificationSoundSettings.isCustomFileSelected(defaults: defaults))

        defaults.set("Ping", forKey: NotificationSoundSettings.key)
        XCTAssertFalse(NotificationSoundSettings.isCustomFileSelected(defaults: defaults))

        defaults.set(NotificationSoundSettings.customFileValue, forKey: NotificationSoundSettings.key)
        XCTAssertTrue(NotificationSoundSettings.isCustomFileSelected(defaults: defaults))
    }

    func testNotificationCustomStagingPreservesSourceFileWithCmuxPrefix() {
        let suiteName = "NotificationDockBadgeTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create isolated UserDefaults suite")
            return
        }
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let fileManager = FileManager.default
        let soundsDirectory = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Sounds", isDirectory: true)
        do {
            try fileManager.createDirectory(at: soundsDirectory, withIntermediateDirectories: true)
        } catch {
            XCTFail("Failed to create sounds directory: \(error)")
            return
        }

        let sourceURL = soundsDirectory.appendingPathComponent(
            "cmux-custom-notification-sound.source-\(UUID().uuidString).wav",
            isDirectory: false
        )
        defer {
            try? fileManager.removeItem(at: sourceURL)
        }

        do {
            try Data("test".utf8).write(to: sourceURL, options: .atomic)
        } catch {
            XCTFail("Failed to write source custom sound file: \(error)")
            return
        }

        defaults.set(NotificationSoundSettings.customFileValue, forKey: NotificationSoundSettings.key)
        defaults.set(sourceURL.path, forKey: NotificationSoundSettings.customFilePathKey)

        _ = NotificationSoundSettings.sound(defaults: defaults)

        guard let stagedName = NotificationSoundSettings.stagedCustomSoundName(defaults: defaults) else {
            XCTFail("Expected staged custom sound name")
            return
        }
        let stagedURL = soundsDirectory.appendingPathComponent(stagedName, isDirectory: false)
        defer {
            try? fileManager.removeItem(at: stagedURL)
        }

        XCTAssertTrue(fileManager.fileExists(atPath: sourceURL.path))
        XCTAssertTrue(fileManager.fileExists(atPath: stagedURL.path))
        XCTAssertTrue(stagedName.hasPrefix("cmux-custom-notification-sound-"))
        XCTAssertTrue(stagedName.hasSuffix(".wav"))
    }

    func testNotificationCustomUnsupportedExtensionsStageAsCaf() {
        XCTAssertEqual(
            NotificationSoundSettings.stagedCustomSoundFileExtension(forSourceExtension: "mp3"),
            "caf"
        )
        XCTAssertEqual(
            NotificationSoundSettings.stagedCustomSoundFileExtension(forSourceExtension: "M4A"),
            "caf"
        )
        XCTAssertEqual(
            NotificationSoundSettings.stagedCustomSoundFileExtension(forSourceExtension: "wav"),
            "wav"
        )
        XCTAssertEqual(
            NotificationSoundSettings.stagedCustomSoundFileExtension(forSourceExtension: "AIFF"),
            "aiff"
        )

        let sourceA = URL(fileURLWithPath: "/tmp/custom-a.mp3")
        let sourceB = URL(fileURLWithPath: "/tmp/custom-b.mp3")
        let stagedA = NotificationSoundSettings.stagedCustomSoundFileName(
            forSourceURL: sourceA,
            destinationExtension: "caf"
        )
        let stagedB = NotificationSoundSettings.stagedCustomSoundFileName(
            forSourceURL: sourceB,
            destinationExtension: "caf"
        )
        XCTAssertNotEqual(stagedA, stagedB)
        XCTAssertTrue(stagedA.hasPrefix("cmux-custom-notification-sound-"))
        XCTAssertTrue(stagedA.hasSuffix(".caf"))
    }

    func testNotificationCustomPreparationKeepsActiveSourceMetadataSidecar() {
        let suiteName = "NotificationDockBadgeTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create isolated UserDefaults suite")
            return
        }
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let fileManager = FileManager.default
        let soundsDirectory = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Sounds", isDirectory: true)
        do {
            try fileManager.createDirectory(at: soundsDirectory, withIntermediateDirectories: true)
        } catch {
            XCTFail("Failed to create sounds directory: \(error)")
            return
        }

        let sourceURL = soundsDirectory.appendingPathComponent(
            "cmux-custom-notification-sound.metadata-\(UUID().uuidString).wav",
            isDirectory: false
        )
        do {
            try Data("test".utf8).write(to: sourceURL, options: .atomic)
        } catch {
            XCTFail("Failed to write source custom sound file: \(error)")
            return
        }
        defer {
            try? fileManager.removeItem(at: sourceURL)
        }

        defaults.set(NotificationSoundSettings.customFileValue, forKey: NotificationSoundSettings.key)
        defaults.set(sourceURL.path, forKey: NotificationSoundSettings.customFilePathKey)

        let prepareResult = NotificationSoundSettings.prepareCustomFileForNotifications(path: sourceURL.path)
        let stagedName: String
        switch prepareResult {
        case .success(let name):
            stagedName = name
        case .failure(let issue):
            XCTFail("Expected custom sound preparation success, got \(issue)")
            return
        }

        let stagedURL = soundsDirectory.appendingPathComponent(stagedName, isDirectory: false)
        let metadataURL = stagedURL.appendingPathExtension("source-metadata")
        defer {
            try? fileManager.removeItem(at: stagedURL)
            try? fileManager.removeItem(at: metadataURL)
        }

        XCTAssertTrue(fileManager.fileExists(atPath: stagedURL.path))
        XCTAssertTrue(fileManager.fileExists(atPath: metadataURL.path))
    }

    func testNotificationCustomSoundReturnsNilWhenPreparationFails() {
        let suiteName = "NotificationDockBadgeTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create isolated UserDefaults suite")
            return
        }
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let invalidSourceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-invalid-sound-\(UUID().uuidString).mp3", isDirectory: false)
        defer {
            try? FileManager.default.removeItem(at: invalidSourceURL)
            let stagedURL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
                .appendingPathComponent("Library", isDirectory: true)
                .appendingPathComponent("Sounds", isDirectory: true)
                .appendingPathComponent("cmux-custom-notification-sound.caf", isDirectory: false)
            try? FileManager.default.removeItem(at: stagedURL)
        }

        do {
            try Data("not-audio".utf8).write(to: invalidSourceURL, options: .atomic)
        } catch {
            XCTFail("Failed to write invalid custom sound source: \(error)")
            return
        }

        defaults.set(NotificationSoundSettings.customFileValue, forKey: NotificationSoundSettings.key)
        defaults.set(invalidSourceURL.path, forKey: NotificationSoundSettings.customFilePathKey)

        XCTAssertNil(NotificationSoundSettings.sound(defaults: defaults))
    }

    func testNotificationCustomPreparationReportsMissingFile() {
        let missingPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-missing-\(UUID().uuidString).wav", isDirectory: false)
            .path

        let result = NotificationSoundSettings.prepareCustomFileForNotifications(path: missingPath)
        switch result {
        case .success:
            XCTFail("Expected missing file failure")
        case .failure(let issue):
            guard case .missingFile = issue else {
                XCTFail("Expected missingFile issue, got \(issue)")
                return
            }
        }
    }

}
