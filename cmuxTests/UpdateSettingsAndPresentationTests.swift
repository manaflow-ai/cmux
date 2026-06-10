import XCTest
import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WebKit
import ObjectiveC.runtime
import Bonsplit
import UserNotifications
import Sparkle
import CmuxUpdater

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif


// MARK: - Update channel, update settings, and update view model presentation
final class UpdateChannelSettingsTests: XCTestCase {
    func testResolvedFeedFallsBackWhenInfoFeedMissing() {
        let resolver = UpdateFeedResolver()
        let resolved = resolver.resolve(infoFeedURL: nil)
        XCTAssertEqual(resolved.url, resolver.fallbackFeedURL)
        XCTAssertFalse(resolved.isNightly)
        XCTAssertTrue(resolved.usedFallback)
    }

    func testResolvedFeedFallsBackWhenInfoFeedEmpty() {
        let resolver = UpdateFeedResolver()
        let resolved = resolver.resolve(infoFeedURL: "")
        XCTAssertEqual(resolved.url, resolver.fallbackFeedURL)
        XCTAssertFalse(resolved.isNightly)
        XCTAssertTrue(resolved.usedFallback)
    }

    func testResolvedFeedUsesInfoFeedForStableChannel() {
        let infoFeed = "https://example.com/custom/appcast.xml"
        let resolved = UpdateFeedResolver().resolve(infoFeedURL: infoFeed)
        XCTAssertEqual(resolved.url, infoFeed)
        XCTAssertFalse(resolved.isNightly)
        XCTAssertFalse(resolved.usedFallback)
    }

    func testResolvedFeedDetectsNightlyFromInfoFeedURL() {
        let resolved = UpdateFeedResolver().resolve(
            infoFeedURL: "https://example.com/nightly/appcast.xml"
        )
        XCTAssertEqual(resolved.url, "https://example.com/nightly/appcast.xml")
        XCTAssertTrue(resolved.isNightly)
        XCTAssertFalse(resolved.usedFallback)
    }
}


final class UpdateSettingsTests: XCTestCase {
    func testApplyEnablesAutomaticChecksAndDailySchedule() {
        let defaults = makeDefaults()
        UpdateSettings().apply(to: defaults)

        XCTAssertTrue(defaults.bool(forKey: UpdateSettings.automaticChecksKey))
        XCTAssertEqual(defaults.double(forKey: UpdateSettings.scheduledCheckIntervalKey), UpdateSettings().scheduledCheckInterval)
        XCTAssertFalse(defaults.bool(forKey: UpdateSettings.automaticallyUpdateKey))
        XCTAssertFalse(defaults.bool(forKey: UpdateSettings.sendProfileInfoKey))
        XCTAssertTrue(defaults.bool(forKey: UpdateSettings.migrationKey))
    }

    func testApplyRepairsLegacyDisabledAutomaticChecksOnce() {
        let defaults = makeDefaults()
        defaults.set(false, forKey: UpdateSettings.automaticChecksKey)
        defaults.set(0, forKey: UpdateSettings.scheduledCheckIntervalKey)
        defaults.set(true, forKey: UpdateSettings.automaticallyUpdateKey)

        UpdateSettings().apply(to: defaults)

        XCTAssertTrue(defaults.bool(forKey: UpdateSettings.automaticChecksKey))
        XCTAssertEqual(defaults.double(forKey: UpdateSettings.scheduledCheckIntervalKey), UpdateSettings().scheduledCheckInterval)
        XCTAssertTrue(defaults.bool(forKey: UpdateSettings.automaticallyUpdateKey))

        defaults.set(false, forKey: UpdateSettings.automaticChecksKey)
        UpdateSettings().apply(to: defaults)

        XCTAssertFalse(defaults.bool(forKey: UpdateSettings.automaticChecksKey))
    }

    private func makeDefaults() -> UserDefaults {
        let suiteName = "UpdateSettingsTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            fatalError("Failed to create isolated UserDefaults suite")
        }
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}

@MainActor
final class UpdateViewModelPresentationTests: XCTestCase {
    func testDetectedBackgroundUpdateShowsPillWhileIdle() {
        let viewModel = UpdateStateModel()

        viewModel.debugSetDetectedVersion("9.9.9")

        XCTAssertTrue(viewModel.showsPill)
        XCTAssertTrue(viewModel.showsDetectedBackgroundUpdate)
        XCTAssertEqual(viewModel.text, "Update Available: 9.9.9")
        XCTAssertEqual(viewModel.iconName, "shippingbox.fill")
    }

    func testActiveUpdateStateTakesPrecedenceOverDetectedBackgroundVersion() {
        let viewModel = UpdateStateModel()

        viewModel.debugSetDetectedVersion("9.9.9")
        viewModel.setState(.checking(.init(cancel: {})))

        XCTAssertTrue(viewModel.showsPill)
        XCTAssertFalse(viewModel.showsDetectedBackgroundUpdate)
        XCTAssertEqual(viewModel.text, "Checking for Updates…")
    }

    func testDismissDetectedAvailableUpdateRepliesAndClearsState() throws {
        let viewModel = UpdateStateModel()
        let item = try XCTUnwrap(makeAppcastItem(displayVersion: "9.9.9"))
        let recorder = UpdateChoiceRecorder()

        viewModel.recordDetectedUpdate(item)
        viewModel.setState(.updateAvailable(.init(
            appcastItem: item,
            reply: { recorder.record($0) }
        )))

        viewModel.dismissDetectedAvailableUpdate()

        XCTAssertEqual(recorder.snapshot(), [.dismiss])
        XCTAssertEqual(viewModel.state, .idle)
        XCTAssertNil(viewModel.detectedUpdateVersion)
        XCTAssertNil(viewModel.detectedUpdateItem)
        XCTAssertFalse(viewModel.showsPill)
    }

    func testCancelActiveStateForNewCheckDismissesAndClearsTransientState() throws {
        let viewModel = UpdateStateModel()
        let item = try XCTUnwrap(makeAppcastItem(displayVersion: "9.9.9"))
        let recorder = UpdateChoiceRecorder()

        viewModel.setState(.updateAvailable(.init(
            appcastItem: item,
            reply: { recorder.record($0) }
        )))
        viewModel.setOverrideState(.checking(.init(cancel: {})))

        viewModel.cancelActiveStateForNewCheck()

        XCTAssertEqual(recorder.snapshot(), [.dismiss])
        XCTAssertEqual(viewModel.state, .idle)
        XCTAssertNil(viewModel.overrideState)
    }

    func testApplyDriverStateRecordsDetectedUpdateMetadata() throws {
        let viewModel = UpdateStateModel()
        let item = try XCTUnwrap(makeAppcastItem(displayVersion: "9.9.9"))

        viewModel.applyDriverState(.updateAvailable(.init(
            appcastItem: item,
            reply: { _ in }
        )))
        viewModel.setState(.idle)

        XCTAssertEqual(viewModel.detectedUpdateVersion, "9.9.9")
        XCTAssertTrue(viewModel.hasCachedDetectedUpdateDetails)
        XCTAssertTrue(viewModel.showsDetectedBackgroundUpdate)
    }

    private func makeAppcastItem(displayVersion: String) -> SUAppcastItem? {
        let enclosure: [String: Any] = [
            "url": "https://example.com/cmux.zip",
            "length": "1024",
            "sparkle:version": displayVersion,
            "sparkle:shortVersionString": displayVersion,
        ]
        let dict: [String: Any] = [
            "title": "cmux \(displayVersion)",
            "pubDate": "Wed, 25 Mar 2026 12:00:00 +0000",
            "enclosure": enclosure,
        ]
        return SUAppcastItem(dictionary: dict)
    }
}

private final class UpdateChoiceRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var choices: [SPUUserUpdateChoice] = []

    func record(_ choice: SPUUserUpdateChoice) {
        lock.lock()
        choices.append(choice)
        lock.unlock()
    }

    func snapshot() -> [SPUUserUpdateChoice] {
        lock.lock()
        defer { lock.unlock() }
        return choices
    }
}

