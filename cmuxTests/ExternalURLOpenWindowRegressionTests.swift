import AppKit
import CmuxAuthRuntime
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
///    `AuthDebugLog.recentDebugLines()` — an in-process DEBUG buffer, so the
///    signal cannot be lost to another process truncating a shared log file.
/// 2. No new `NSWindow` object appears at any point while the event is
///    processed. The zombie window lives only ~300ms, so the run loop is
///    pumped in small slices and every slice records windows that were not
///    part of the baseline — a transient window cannot slip through between
///    assertions.
@MainActor
final class ExternalURLOpenWindowRegressionTests: XCTestCase {
    func testExternalAuthCallbackURLOpenDoesNotCreateWindow() throws {
        // Unique per-run query key: `authURLDebugSummary` logs query keys (not
        // values), so the key doubles as a redaction-safe log marker.
        let marker = "zombiewindowprobe7825n\(UInt32.random(in: 0..<UInt32.max))"
        // Rejected by HostBrowserSignInFlow.handleCallbackURL with
        // reason=noActiveAttempt; it mutates no auth state. The zombie window
        // was created by the scene machinery before any auth code ran at all.
        let urlString = "cmux-dev://auth-callback?cmux_auth_state=probe&\(marker)=1"

        // Delayed app setup (config/onboarding panels) can open windows
        // seconds after launch, and tests in this target run serially in one
        // process — so wait for the window set to hold still before
        // baselining, ensuring startup windows are never misattributed to
        // the URL open. Hold strong references so no baseline window can
        // deallocate mid-test and recycle its identity for a new window.
        let baselineWindows = stableWindowBaseline()
        let baseline = Set(baselineWindows.map(ObjectIdentifier.init))

        try sendSelfAddressedGetURLEvent(urlString)

        var newWindowDescriptions = [ObjectIdentifier: String]()
        var deliveryObserved = false
        var postDeliveryDeadline: Date?
        let hardDeadline = Date(timeIntervalSinceNow: 8)
        var slice = 0
        while Date() < hardDeadline {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02))
            // Only windows actually shown on screen violate the invariant —
            // the regression is a visible flash. Offscreen helper windows
            // AppKit creates incidentally (popover hosts, input panels) are
            // not the bootstrap-scene window this test pins.
            for window in NSApp.windows
            where !baseline.contains(ObjectIdentifier(window)) && window.isVisible {
                newWindowDescriptions[ObjectIdentifier(window)] =
                    "windowNumber=\(window.windowNumber) " +
                    "identifier=\(window.identifier?.rawValue ?? "nil") " +
                    "class=\(type(of: window)) title=\(window.title) " +
                    "frame=\(NSStringFromRect(window.frame)) visible=\(window.isVisible)"
            }
            slice += 1
            if !deliveryObserved, slice % 10 == 0,
               Self.authDebugLinesContainDelivery(marker: marker) {
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
            deliveryObserved = Self.authDebugLinesContainDelivery(marker: marker)
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

    /// Returns `NSApp.windows` once the window set has been unchanged for a
    /// full second (capped at 10s), so windows opened by delayed app setup
    /// are captured in the baseline instead of failing the invariant.
    private func stableWindowBaseline() -> [NSWindow] {
        let deadline = Date(timeIntervalSinceNow: 10)
        var snapshot = NSApp.windows
        var stableSince = Date()
        while Date() < deadline {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
            let current = NSApp.windows
            if Set(current.map(ObjectIdentifier.init)) != Set(snapshot.map(ObjectIdentifier.init)) {
                snapshot = current
                stableSince = Date()
            } else if Date().timeIntervalSince(stableSince) >= 1 {
                return current
            }
        }
        return snapshot
    }

    /// Whether this process has logged an `auth.openURLs.received` line
    /// mentioning the probe marker. Reads `AuthDebugLog`'s in-process DEBUG
    /// buffer — the tests run app-hosted in the same process as
    /// `AppDelegate`, so delivery is observable without any shared file that
    /// another process could truncate or recreate mid-test.
    private static func authDebugLinesContainDelivery(marker: String) -> Bool {
        AuthDebugLog.recentDebugLines().contains { line in
            line.contains("auth.openURLs.received") && line.contains(marker)
        }
    }
}
