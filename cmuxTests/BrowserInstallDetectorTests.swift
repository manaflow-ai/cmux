@preconcurrency import XCTest
import CmuxSettings
import CmuxSocketControl
import AppKit
import Combine
import CoreText
import WebKit
import Darwin
import SwiftUI
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif


final class BrowserInstallDetectorTests: XCTestCase {
    func testDetectInstalledBrowsersUsesBundleIdAndProfileData() throws {
        let home = makeTemporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }

        try createFile(
            at: home
                .appendingPathComponent("Library/Application Support/Google/Chrome/Default/History"),
            contents: Data()
        )
        try createFile(
            at: home
                .appendingPathComponent("Library/Application Support/Firefox/Profiles/dev.default-release/cookies.sqlite"),
            contents: Data()
        )

        let detected = InstalledBrowserDetector.detectInstalledBrowsers(
            homeDirectoryURL: home,
            bundleLookup: { bundleIdentifier in
                if bundleIdentifier == "com.google.Chrome" {
                    return URL(fileURLWithPath: "/Applications/Google Chrome.app", isDirectory: true)
                }
                return nil
            },
            applicationSearchDirectories: []
        )

        guard let chrome = detected.first(where: { $0.descriptor.id == "google-chrome" }) else {
            XCTFail("Expected Chrome to be detected")
            return
        }
        guard let firefox = detected.first(where: { $0.descriptor.id == "firefox" }) else {
            XCTFail("Expected Firefox to be detected from profile data")
            return
        }

        XCTAssertNotNil(chrome.appURL)
        XCTAssertEqual(firefox.profileURLs.count, 1)
        XCTAssertNil(firefox.appURL)
    }

    func testDetectInstalledBrowsersReturnsEmptyWhenNoSignalsExist() throws {
        let home = makeTemporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let detected = InstalledBrowserDetector.detectInstalledBrowsers(
            homeDirectoryURL: home,
            bundleLookup: { _ in nil },
            applicationSearchDirectories: []
        )

        XCTAssertTrue(detected.isEmpty)
    }

    func testUngoogledChromiumRequiresAppSignal() throws {
        let home = makeTemporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }

        try createFile(
            at: home
                .appendingPathComponent("Library/Application Support/Chromium/Default/History"),
            contents: Data()
        )

        let detected = InstalledBrowserDetector.detectInstalledBrowsers(
            homeDirectoryURL: home,
            bundleLookup: { _ in nil },
            applicationSearchDirectories: []
        )

        XCTAssertTrue(detected.contains(where: { $0.descriptor.id == "chromium" }))
        XCTAssertFalse(detected.contains(where: { $0.descriptor.id == "ungoogled-chromium" }))
    }

    func testDetectInstalledBrowsersDiscoversHeliumProfilesFromChromiumLayout() throws {
        let home = makeTemporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let heliumRoot = home.appendingPathComponent("Library/Application Support/net.imput.helium", isDirectory: true)
        try createFile(
            at: heliumRoot.appendingPathComponent("Default/History"),
            contents: Data()
        )
        try createFile(
            at: heliumRoot.appendingPathComponent("Profile 1/Cookies"),
            contents: Data()
        )
        try createFile(
            at: heliumRoot.appendingPathComponent("Local State"),
            contents: Data(
                """
                {
                  "profile": {
                    "info_cache": {
                      "Default": {
                        "name": "Personal"
                      },
                      "Profile 1": {
                        "name": "Work"
                      }
                    }
                  }
                }
                """.utf8
            )
        )

        let detected = InstalledBrowserDetector.detectInstalledBrowsers(
            homeDirectoryURL: home,
            bundleLookup: { _ in nil },
            applicationSearchDirectories: []
        )

        guard let helium = detected.first(where: { $0.descriptor.id == "helium" }) else {
            XCTFail("Expected Helium to be detected")
            return
        }

        XCTAssertEqual(helium.family, .chromium)
        XCTAssertEqual(helium.profiles.map(\.displayName), ["Personal", "Work"])
        XCTAssertEqual(
            helium.profiles.map(\.rootURL.lastPathComponent),
            ["Default", "Profile 1"]
        )
    }

    func testDetectInstalledBrowsersDiscoversSafariProfiles() throws {
        let home = makeTemporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }

        try createFile(
            at: home.appendingPathComponent("Library/Safari/History.db"),
            contents: Data()
        )
        try createFile(
            at: home.appendingPathComponent(
                "Library/Safari/Profiles/Work/History.db"
            ),
            contents: Data()
        )
        try createFile(
            at: home.appendingPathComponent(
                "Library/Containers/com.apple.Safari/Data/Library/Safari/Profiles/Travel/History.db"
            ),
            contents: Data()
        )

        let detected = InstalledBrowserDetector.detectInstalledBrowsers(
            homeDirectoryURL: home,
            bundleLookup: { _ in nil },
            applicationSearchDirectories: []
        )

        guard let safari = detected.first(where: { $0.descriptor.id == "safari" }) else {
            XCTFail("Expected Safari to be detected")
            return
        }

        XCTAssertEqual(Set(safari.profiles.map(\.displayName)), Set(["Default", "Work", "Travel"]))
        XCTAssertEqual(
            safari.profiles
                .map { $0.rootURL.standardizedFileURL.resolvingSymlinksInPath().path(percentEncoded: false) }
                .sorted(),
            [
                home.appendingPathComponent("Library/Safari", isDirectory: true)
                    .standardizedFileURL.resolvingSymlinksInPath().path(percentEncoded: false),
                home.appendingPathComponent("Library/Safari/Profiles/Work", isDirectory: true)
                    .standardizedFileURL.resolvingSymlinksInPath().path(percentEncoded: false),
                home.appendingPathComponent(
                    "Library/Containers/com.apple.Safari/Data/Library/Safari/Profiles/Travel",
                    isDirectory: true
                ).standardizedFileURL.resolvingSymlinksInPath().path(percentEncoded: false),
            ].sorted()
        )
    }

    private func makeTemporaryHome() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("cmux-browser-detect-\(UUID().uuidString)")
    }

    private func createFile(at url: URL, contents: Data) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard FileManager.default.createFile(atPath: url.path, contents: contents) else {
            throw CocoaError(
                .fileWriteUnknown,
                userInfo: [NSFilePathErrorKey: url.path]
            )
        }
    }
}

