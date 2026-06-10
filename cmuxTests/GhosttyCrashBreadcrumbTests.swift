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


final class GhosttyCrashBreadcrumbTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!
    private var crashDirectoryURL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        suiteName = "GhosttyCrashBreadcrumbTests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        crashDirectoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ghostty-crash-breadcrumb-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: crashDirectoryURL, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let crashDirectoryURL {
            try? FileManager.default.removeItem(at: crashDirectoryURL)
        }
        if let suiteName {
            UserDefaults.standard.removePersistentDomain(forName: suiteName)
        }
        defaults = nil
        suiteName = nil
        crashDirectoryURL = nil
        try super.tearDownWithError()
    }

    func testPendingCrashDetectedWhenNewerThanCleanExit() throws {
        let cleanExit = Date(timeIntervalSince1970: 100)
        let crashDate = Date(timeIntervalSince1970: 200)
        defaults.set(cleanExit, forKey: GhosttyCrashBreadcrumb.lastCleanExitDefaultsKey)
        let crashURL = try writeCrashFile(named: "newer.ghosttycrash", modifiedAt: crashDate)

        let pending = GhosttyCrashBreadcrumb.pendingCrash(
            in: crashDirectoryURL,
            defaults: defaults
        )

        XCTAssertEqual(pending?.fileURL.resolvingSymlinksInPath(), crashURL.resolvingSymlinksInPath())
        XCTAssertEqual(pending?.modifiedAt, crashDate)
    }

    func testPendingCrashDetectedFromMatchingEnvelopeWhenNewerThanCleanExit() throws {
        let cleanExit = Date(timeIntervalSince1970: 100)
        let crashDate = Date(timeIntervalSince1970: 200)
        defaults.set(cleanExit, forKey: GhosttyCrashBreadcrumb.lastCleanExitDefaultsKey)
        let currentExecutablePath = try XCTUnwrap(Bundle.main.executableURL?.path)
        let crashURL = try writeCrashEnvelope(
            named: "matching-newer.ghosttycrash",
            executablePath: currentExecutablePath,
            modifiedAt: crashDate
        )

        let pending = GhosttyCrashBreadcrumb.pendingCrash(
            in: crashDirectoryURL,
            defaults: defaults
        )

        XCTAssertEqual(pending?.fileURL.resolvingSymlinksInPath(), crashURL.resolvingSymlinksInPath())
        XCTAssertEqual(pending?.modifiedAt, crashDate)
    }

    func testPendingCrashIgnoresNewerCrashFromDifferentExecutable() throws {
        let currentCrashDate = Date(timeIntervalSince1970: 200)
        let foreignCrashDate = Date(timeIntervalSince1970: 300)
        let currentExecutablePath = try XCTUnwrap(Bundle.main.executableURL?.path)
        let currentCrashURL = try writeCrashEnvelope(
            named: "current.ghosttycrash",
            executablePath: currentExecutablePath,
            modifiedAt: currentCrashDate
        )
        _ = try writeCrashEnvelope(
            named: "foreign.ghosttycrash",
            executablePath: "/private/tmp/cmux-tbinput-unit/Build/Products/Debug/cmux DEV.app/Contents/MacOS/cmux DEV",
            modifiedAt: foreignCrashDate
        )

        let pending = GhosttyCrashBreadcrumb.pendingCrash(
            in: crashDirectoryURL,
            defaults: defaults
        )

        XCTAssertEqual(pending?.fileURL.resolvingSymlinksInPath(), currentCrashURL.resolvingSymlinksInPath())
        XCTAssertEqual(pending?.modifiedAt, currentCrashDate)
    }

    func testPendingCrashIgnoresForeignCrashWhenEventIsNotFirstEnvelopeItem() throws {
        let currentCrashDate = Date(timeIntervalSince1970: 200)
        let foreignCrashDate = Date(timeIntervalSince1970: 300)
        let currentExecutablePath = try XCTUnwrap(Bundle.main.executableURL?.path)
        let currentCrashURL = try writeCrashEnvelope(
            named: "current-before-foreign-leading-item.ghosttycrash",
            executablePath: currentExecutablePath,
            modifiedAt: currentCrashDate
        )
        _ = try writeCrashEnvelope(
            named: "foreign-leading-item.ghosttycrash",
            executablePath: "/private/tmp/cmux-tbinput-unit/Build/Products/Debug/cmux DEV.app/Contents/MacOS/cmux DEV",
            modifiedAt: foreignCrashDate,
            leadingItems: [
                (type: "attachment", payload: Data(#"{"filename":"metadata.txt"}"#.utf8)),
            ]
        )

        let pending = GhosttyCrashBreadcrumb.pendingCrash(
            in: crashDirectoryURL,
            defaults: defaults
        )

        XCTAssertEqual(pending?.fileURL.resolvingSymlinksInPath(), currentCrashURL.resolvingSymlinksInPath())
        XCTAssertEqual(pending?.modifiedAt, currentCrashDate)
    }

    func testPendingCrashReturnsNilForOnlyDifferentExecutableCrash() throws {
        _ = try writeCrashEnvelope(
            named: "foreign-only.ghosttycrash",
            executablePath: "/private/tmp/cmux-tbinput-unit/Build/Products/Debug/cmux DEV.app/Contents/MacOS/cmux DEV",
            modifiedAt: Date(timeIntervalSince1970: 300)
        )

        XCTAssertNil(GhosttyCrashBreadcrumb.pendingCrash(
            in: crashDirectoryURL,
            defaults: defaults
        ))
    }

    func testDefaultCrashDirectoryUsesCmuxStatePath() throws {
        XCTAssertTrue(
            GhosttyCrashBreadcrumb.defaultCrashDirectoryURL.path.hasSuffix("/.local/state/cmux/crash"),
            GhosttyCrashBreadcrumb.defaultCrashDirectoryURL.path
        )
    }

    func testPendingCrashIsOneTimeAfterBeingShown() throws {
        let crashDate = Date(timeIntervalSince1970: 300)
        let crashURL = try writeCrashFile(named: "shown.ghosttycrash", modifiedAt: crashDate)
        let pending = try XCTUnwrap(GhosttyCrashBreadcrumb.pendingCrash(
            in: crashDirectoryURL,
            defaults: defaults
        ))
        XCTAssertEqual(pending.fileURL.resolvingSymlinksInPath(), crashURL.resolvingSymlinksInPath())

        GhosttyCrashBreadcrumb.markShown(pending, defaults: defaults)

        XCTAssertNil(GhosttyCrashBreadcrumb.pendingCrash(
            in: crashDirectoryURL,
            defaults: defaults
        ))
    }

    private func writeCrashFile(named name: String, modifiedAt: Date) throws -> URL {
        let url = crashDirectoryURL.appendingPathComponent(name)
        try Data("MDMP".utf8).write(to: url)
        try FileManager.default.setAttributes(
            [.modificationDate: modifiedAt],
            ofItemAtPath: url.path
        )
        return url
    }

    private func writeCrashEnvelope(
        named name: String,
        executablePath: String,
        modifiedAt: Date,
        leadingItems: [(type: String, payload: Data)] = []
    ) throws -> URL {
        let url = crashDirectoryURL.appendingPathComponent(name)
        let event = [
            "debug_meta": [
                "images": [
                    [
                        "code_file": executablePath,
                    ],
                ],
            ],
        ]
        let eventData = try JSONSerialization.data(withJSONObject: event)
        let eventHeader = #"{"type":"event","length":\#(eventData.count)}"#
        var envelope = Data(#"{"event_id":"00000000-0000-0000-0000-000000000000"}"#.utf8)
        envelope.append(0x0A)
        for item in leadingItems {
            let itemHeader = #"{"type":"\#(item.type)","length":\#(item.payload.count)}"#
            envelope.append(Data(itemHeader.utf8))
            envelope.append(0x0A)
            envelope.append(item.payload)
            envelope.append(0x0A)
        }
        envelope.append(Data(eventHeader.utf8))
        envelope.append(0x0A)
        envelope.append(eventData)
        envelope.append(0x0A)
        try envelope.write(to: url)
        try FileManager.default.setAttributes(
            [.modificationDate: modifiedAt],
            ofItemAtPath: url.path
        )
        return url
    }
}

