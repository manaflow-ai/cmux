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


final class UITestLaunchManifestTests: XCTestCase {
    func testManifestPathReadsArgumentValue() {
        XCTAssertEqual(
            UITestLaunchManifest.manifestPath(
                from: ["cmux", "-cmuxUITestLaunchManifest", "/tmp/cmux-ui-test-launch.json"]
            ),
            "/tmp/cmux-ui-test-launch.json"
        )
    }

    func testManifestPathReturnsNilWithoutValue() {
        XCTAssertNil(
            UITestLaunchManifest.manifestPath(
                from: ["cmux", "-cmuxUITestLaunchManifest"]
            )
        )
    }

    func testApplyIfPresentDecodesEnvironmentPayload() {
        let payload = """
        {"environment":{"CMUX_TAG":"ui-tests-display","CMUX_SOCKET_PATH":"/tmp/cmux-ui-tests.sock"}}
        """.data(using: .utf8)!
        var applied: [String: String] = [:]

        UITestLaunchManifest.applyIfPresent(
            arguments: ["cmux", UITestLaunchManifest.argumentName, "/tmp/cmux-ui-test-launch.json"],
            loadData: { _ in payload },
            applyEnvironment: { key, value in
                applied[key] = value
            }
        )

        XCTAssertEqual(applied["CMUX_TAG"], "ui-tests-display")
        XCTAssertEqual(applied["CMUX_SOCKET_PATH"], "/tmp/cmux-ui-tests.sock")
    }
}

