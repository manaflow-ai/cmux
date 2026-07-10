import AppKit
import CoreServices
import XCTest

/// Regression coverage for https://github.com/manaflow-ai/cmux/issues/7825.
///
/// cmux is a SwiftUI-lifecycle app whose only scene is a bootstrap
/// `WindowGroup`; every real window is AppKit-managed by `AppDelegate`.
/// Without `handlesExternalEvents(matching: [])` on that scene, macOS
/// delivering a `kAEGetURL` Apple Event (any `cmux://…` URL open, e.g.
/// Safari's `cmux://auth-callback` deep link after sign-in) makes SwiftUI
/// materialize a brand-new 900×450 WindowGroup window that the bootstrap view
/// then closes — a black zombie window that flashes for a moment and steals
/// focus from the real terminal window.
///
/// This suite runs app-hosted inside the real `cmux DEV.app`, so the live
/// SwiftUI scene machinery and the app's Apple Event handlers are exercised.
/// It sends the host process a self-addressed `kAEGetURL` event (self-sends
/// need no Automation/TCC consent) and asserts two invariants:
///
/// 1. `AppDelegate.application(_:open:)` still receives the URL (guards
///    against the fix accidentally swallowing URL delivery), observed through
///    the `AuthDebugLog` DEBUG sink at `/tmp/cmux-auth-debug.log`.
/// 2. No new `NSWindow` object appears at any point while the event is
///    processed. The zombie window lives only ~300ms, so the run loop is
///    pumped in small slices and every slice records windows that were not
///    part of the baseline — a transient window cannot slip through between
///    assertions.
@MainActor
final class ExternalURLOpenWindowRegressionTests: XCTestCase {
    private static let authDebugLogPath = "/tmp/cmux-auth-debug.log"

    func testExternalAuthCallbackURLOpenDoesNotCreateWindow() throws {
        // Unique per-run query key: `authURLDebugSummary` logs query keys (not
        // values), so the key doubles as a redaction-safe log marker.
        let marker = "zombiewindowprobe7825n\(UInt32.random(in: 0..<UInt32.max))"
        // Rejected by HostBrowserSignInFlow.handleCallbackURL with
        // reason=noActiveAttempt; it mutates no auth state. The zombie window
        // was created by the scene machinery before any auth code ran at all.
        let urlString = "cmux-dev://auth-callback?cmux_auth_state=probe&\(marker)=1"

        // Hold strong references so no baseline window can deallocate mid-test
        // and recycle its identity for a genuinely new window.
        let baselineWindows = NSApp.windows
        let baseline = Set(baselineWindows.map(ObjectIdentifier.init))
        let logOffset = currentAuthDebugLogSize()

        try sendSelfAddressedGetURLEvent(urlString)

        var newWindowDescriptions = [ObjectIdentifier: String]()
        var deliveryObserved = false
        var postDeliveryDeadline: Date?
        let hardDeadline = Date(timeIntervalSinceNow: 8)
        var slice = 0
        while Date() < hardDeadline {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02))
            for window in NSApp.windows where !baseline.contains(ObjectIdentifier(window)) {
                newWindowDescriptions[ObjectIdentifier(window)] =
                    "windowNumber=\(window.windowNumber) " +
                    "identifier=\(window.identifier?.rawValue ?? "nil") " +
                    "class=\(type(of: window)) title=\(window.title) " +
                    "frame=\(NSStringFromRect(window.frame)) visible=\(window.isVisible)"
            }
            // The log file is shared; only re-read it every ~200ms.
            slice += 1
            if !deliveryObserved, slice % 10 == 0,
               authDebugLogContainsDelivery(marker: marker, fromOffset: logOffset) {
                deliveryObserved = true
                // Grace period: keep watching for a late zombie window after
                // the delegate has already seen the URL.
                postDeliveryDeadline = Date(timeIntervalSinceNow: 2)
            }
            if let postDeliveryDeadline, Date() >= postDeliveryDeadline {
                break
            }
        }
        if !deliveryObserved {
            deliveryObserved = authDebugLogContainsDelivery(marker: marker, fromOffset: logOffset)
        }

        XCTAssertTrue(
            deliveryObserved,
            "kAEGetURL Apple Event was not delivered to application(_:open:) within 8s; " +
                "cannot evaluate the no-new-window invariant"
        )
        XCTAssertTrue(
            newWindowDescriptions.isEmpty,
            "External URL open must never materialize a window " +
                "(https://github.com/manaflow-ai/cmux/issues/7825); saw: " +
                newWindowDescriptions.values.sorted().joined(separator: "; ")
        )
        withExtendedLifetime(baselineWindows) {}
    }

    /// Sends this process a `kAEGetURL` Apple Event, the same event
    /// LaunchServices sends when another app (Safari) opens a `cmux://` URL.
    private func sendSelfAddressedGetURLEvent(_ urlString: String) throws {
        let target = NSAppleEventDescriptor(
            processIdentifier: ProcessInfo.processInfo.processIdentifier
        )
        let event = NSAppleEventDescriptor.appleEvent(
            withEventClass: AEEventClass(kInternetEventClass),
            eventID: AEEventID(kAEGetURL),
            targetDescriptor: target,
            returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID)
        )
        event.setParam(NSAppleEventDescriptor(string: urlString), forKeyword: keyDirectObject)
        _ = try event.sendEvent(options: [.noReply], timeout: 5)
    }

    private func currentAuthDebugLogSize() -> UInt64 {
        let attributes = try? FileManager.default.attributesOfItem(
            atPath: Self.authDebugLogPath
        )
        return (attributes?[.size] as? NSNumber)?.uint64Value ?? 0
    }

    /// Whether bytes appended past `offset` contain an
    /// `auth.openURLs.received` line mentioning the probe marker.
    private func authDebugLogContainsDelivery(marker: String, fromOffset offset: UInt64) -> Bool {
        guard let handle = FileHandle(forReadingAtPath: Self.authDebugLogPath) else {
            return false
        }
        defer { try? handle.close() }
        guard (try? handle.seek(toOffset: offset)) != nil,
              let data = try? handle.readToEnd(),
              !data.isEmpty else {
            return false
        }
        let appended = String(decoding: data, as: UTF8.self)
        return appended.split(separator: "\n").contains { line in
            line.contains("auth.openURLs.received") && line.contains(marker)
        }
    }
}
