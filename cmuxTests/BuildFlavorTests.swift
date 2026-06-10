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


// MARK: - Build flavor detection
final class BuildFlavorTests: XCTestCase {
    func testDetectsDevFromBundleName() {
        XCTAssertEqual(
            BuildFlavor.detect(bundleName: "cmux DEV noqdlg", bundleIdentifier: "com.cmuxterm.app"),
            .dev
        )
    }

    func testDetectsDevBeforeTagTextCanLookNightly() {
        XCTAssertEqual(
            BuildFlavor.detect(bundleName: "cmux DEV nightly", bundleIdentifier: "com.cmuxterm.app"),
            .dev
        )
    }

    func testDetectsNightlyFromBundleIdentifier() {
        XCTAssertEqual(
            BuildFlavor.detect(bundleName: "cmux", bundleIdentifier: "com.cmuxterm.app.nightly"),
            .nightly
        )
    }

    func testDetectsStableByDefault() {
        XCTAssertEqual(
            BuildFlavor.detect(bundleName: "cmux", bundleIdentifier: "com.cmuxterm.app"),
            .stable
        )
    }
}

