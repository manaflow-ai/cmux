#if canImport(UIKit)
import CMUXMobileCore
import Foundation
import Testing
import UIKit

@testable import CmuxMobileTerminal

/// Regression coverage for optimistic bottom-follow on user input.
///
/// The iOS Ghostty surface is a display-only mirror: typed bytes go to the Mac
/// and the echo comes back in the output stream. If the user has scrolled up
/// into local scrollback and then types, the Mac updates at the prompt but the
/// phone keeps showing old scrollback, so the terminal reads as frozen. The
/// fix snaps the local viewport to the bottom on every user-produced input
/// (typing, backspace, escape sequences, paste) via the serial surface queue,
/// while passive output never forces that jump.
///
/// These tests mount a real `GhosttySurfaceView` + libghostty surface in the
/// scene-less xctest host (bare `UIWindow`, render dispatch skipped because a
/// Metal present can never complete there) and observe the viewport through
/// `renderedTextForTesting()`, which reads terminal state without the renderer.
@MainActor
@Suite("Terminal input scroll-to-bottom", .serialized)
struct TerminalInputScrollToBottomTests {
    private final class InputCollectingDelegate: NSObject, GhosttySurfaceViewDelegate {
        private(set) var produced: [Data] = []
        func ghosttySurfaceView(_ surfaceView: GhosttySurfaceView, didProduceInput data: Data) {
            produced.append(data)
        }
        func ghosttySurfaceView(_ surfaceView: GhosttySurfaceView, didResize size: TerminalGridSize) {}
    }

    private struct Harness {
        let window: UIWindow
        let view: GhosttySurfaceView
        let delegate: InputCollectingDelegate
    }

    private func makeHarness() throws -> Harness {
        let runtime = try GhosttyRuntime.shared()
        let delegate = InputCollectingDelegate()
        let view = GhosttySurfaceView(runtime: runtime, delegate: delegate, fontSize: 10)
        view.debugSkipRenderDispatchForTesting = true
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 700))
        window.addSubview(view)
        view.frame = window.bounds
        window.isHidden = false
        return Harness(window: window, view: view, delegate: delegate)
    }

    /// Awaiting (not run-loop pumping) lets the main queue drain so the
    /// output-queue → main completions under test can land.
    private func waitUntil(
        timeout: Duration = .seconds(10),
        _ predicate: @MainActor () -> Bool
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while clock.now < deadline {
            if predicate() { return true }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return predicate()
    }

    private func viewportText(_ view: GhosttySurfaceView) -> String {
        view.renderedTextForTesting() ?? ""
    }

    /// Seeds numbered scrollback and scrolls up until the last line leaves the
    /// viewport, returning the marker text of the last (bottom) line.
    private func seedAndScrollUp(_ view: GhosttySurfaceView) async throws -> String {
        let lastLineMarker = "seed-line 300"
        var text = ""
        for i in 1...300 {
            text += String(format: "seed-line %03d\r\n", i)
        }
        _ = await view.processOutputAndWait(Data(text.utf8))
        #expect(await waitUntil { viewportText(view).contains(lastLineMarker) },
                "seeded output should land with the viewport at the bottom")

        view.applyLocalScrollbackScroll(lines: 120, col: 2, row: 2)
        #expect(await waitUntil { !viewportText(view).contains(lastLineMarker) },
                "scrolling up should move the last line out of the viewport")
        return lastLineMarker
    }

    @Test("typing while scrolled up snaps the viewport back to the bottom")
    func typedInputSnapsToBottom() async throws {
        let harness = try makeHarness()
        defer { harness.view.prepareForDismantle() }
        let marker = try await seedAndScrollUp(harness.view)

        harness.view.simulateInputProxyTextChangeForTesting("l", isComposing: false)

        #expect(await waitUntil { viewportText(harness.view).contains(marker) },
                "user input while scrolled up must optimistically scroll the mirror to the bottom")
        #expect(!harness.delegate.produced.isEmpty,
                "the typed byte must still reach the transport delegate")
    }

    @Test("passive output while scrolled up does not force the viewport down")
    func passiveOutputDoesNotFollow() async throws {
        let harness = try makeHarness()
        defer { harness.view.prepareForDismantle() }
        let marker = try await seedAndScrollUp(harness.view)

        _ = await harness.view.processOutputAndWait(Data("passive-tail 1\r\npassive-tail 2\r\n".utf8))

        // Bounded settle: the viewport must STAY scrolled up after the passive
        // chunk is applied; reaching the bottom within the window is a failure.
        let jumped = await waitUntil(timeout: .seconds(1)) {
            viewportText(harness.view).contains(marker)
                || viewportText(harness.view).contains("passive-tail")
        }
        #expect(!jumped, "passive output must not auto-follow while the user reads scrollback")
    }
}
#endif
