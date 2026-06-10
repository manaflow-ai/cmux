import XCTest
import AppKit
import Carbon.HIToolbox
import Darwin
import PDFKit
import Testing
import SwiftUI
import UniformTypeIdentifiers
import WebKit
import ObjectiveC.runtime
@testable import Bonsplit
import UserNotifications

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif


@MainActor
final class AppDelegateLaunchServicesRegistrationTests: XCTestCase {
    func testDefaultTerminalRegistrationKeepsAllAdvertisedTargets() {
        XCTAssertEqual(
            DefaultTerminalRegistration.targetCount,
            DefaultTerminalRegistration.urlSchemes.count + DefaultTerminalRegistration.contentTypeIdentifiers.count
        )
        XCTAssertEqual(
            DefaultTerminalRegistration.contentType(forIdentifier: "com.apple.terminal.shell-script").identifier,
            "com.apple.terminal.shell-script"
        )
    }

    func testScheduleLaunchServicesRegistrationDefersRegisterWork() {
        _ = NSApplication.shared
        let app = AppDelegate()

        var scheduledWork: (@Sendable () -> Void)?
        var registerCallCount = 0

        app.scheduleLaunchServicesBundleRegistrationForTesting(
            bundleURL: URL(fileURLWithPath: "/tmp/../tmp/cmux-launch-services-test.app"),
            scheduler: { work in
                scheduledWork = work
            },
            register: { _ in
                registerCallCount += 1
                return noErr
            }
        )

        XCTAssertEqual(registerCallCount, 0, "Registration should not run inline on the startup call path")
        XCTAssertNotNil(scheduledWork, "Registration work should be handed to the scheduler")

        scheduledWork?()

        XCTAssertEqual(registerCallCount, 1)
    }
}

