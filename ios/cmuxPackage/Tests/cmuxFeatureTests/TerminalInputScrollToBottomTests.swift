#if canImport(UIKit)
import CMUXMobileCore
import Foundation
import Testing
import UIKit

@testable import CmuxMobileShell
@testable import CmuxMobileTerminal

/// Regression coverage for optimistic bottom-follow on user input.
///
/// The iOS Ghostty surface is a display-only mirror: typed bytes go to the Mac
/// and the echo comes back in the output stream. If the user has scrolled up
/// into local scrollback and then types, the Mac updates at the prompt but the
/// phone keeps showing old scrollback, so the terminal reads as frozen. The
/// The shell admits one bottom mutation for each scroll episode and the mounted
/// surface consumes that mutation through the same serial stream as output.
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
        private let onInput: @MainActor (Data) -> Void

        init(onInput: @escaping @MainActor (Data) -> Void) {
            self.onInput = onInput
        }

        func ghosttySurfaceView(_ surfaceView: GhosttySurfaceView, didProduceInput data: Data) {
            produced.append(data)
            onInput(data)
        }
        func ghosttySurfaceView(_ surfaceView: GhosttySurfaceView, didResize size: TerminalGridSize, reportID: UInt64) {}
    }

    private struct Harness {
        let window: UIWindow
        let view: GhosttySurfaceView
        let delegate: InputCollectingDelegate
        let store: MobileShellComposite
        let scrollSessionToken: UUID
        let outputTask: Task<Void, Never>
    }

    private func makeHarness() throws -> Harness {
        let runtime = try GhosttyRuntime.shared()
        let store = MobileShellComposite.preview()
        let surfaceID = "input-scroll-to-bottom"
        let delegate = InputCollectingDelegate { [weak store] _ in
            _ = store?.terminalScrollSessionsBySurfaceID[surfaceID]?.submitInput(.fence)
        }
        let view = GhosttySurfaceView(runtime: runtime, delegate: delegate, fontSize: 10)
        // The xctest host has no window scene, so a Metal present can never
        // complete here; suppress render dispatch so the render-stall recovery
        // never resets the surface (and its seeded scrollback) under test.
        view.isRenderDispatchSuppressed = true
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 700))
        window.addSubview(view)
        view.frame = window.bounds
        window.isHidden = false
        let mount = store.mountTerminalSurfaceOutput(
            surfaceID: surfaceID,
            cancelLocal: { [weak view] in view?.cancelScrollMomentum() }
        )
        let outputTask = Task { @MainActor [weak view, weak store] in
            guard let view, let store else { return }
            for await chunk in mount.output {
                guard store.terminalOutputWillProcess(
                    surfaceID: surfaceID,
                    streamToken: chunk.streamToken,
                    deliveryID: chunk.deliveryID
                ) else { continue }
                let applied: Bool
                switch chunk.mutation {
                case .output(let operation):
                    if operation.data.isEmpty {
                        applied = true
                    } else {
                        applied = await view.processOutputAndWait(operation.data)
                    }
                case .localScroll(let runs):
                    applied = await view.applyLocalScrollbackScrollAndWait(runs)
                case .scrollToBottom:
                    applied = await view.scrollToBottomAndWait()
                case .barrier:
                    applied = true
                }
                if applied {
                    store.terminalOutputDidProcess(surfaceID: surfaceID, streamToken: chunk.streamToken)
                } else {
                    store.terminalOutputDidReset(surfaceID: surfaceID, streamToken: chunk.streamToken)
                }
            }
        }
        return Harness(
            window: window,
            view: view,
            delegate: delegate,
            store: store,
            scrollSessionToken: mount.scrollSessionToken,
            outputTask: outputTask
        )
    }

    private func dismantle(_ harness: Harness) {
        harness.outputTask.cancel()
        harness.store.unmountTerminalScrollSession(
            surfaceID: "input-scroll-to-bottom",
            token: harness.scrollSessionToken
        )
        harness.view.prepareForDismantle()
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

        _ = await view.applyLocalScrollbackScrollAndWait(lines: 120, col: 2, row: 2)
        #expect(await waitUntil { !viewportText(view).contains(lastLineMarker) },
                "scrolling up should move the last line out of the viewport")
        return lastLineMarker
    }

    @Test("typing while scrolled up snaps the viewport back to the bottom")
    func typedInputSnapsToBottom() async throws {
        let harness = try makeHarness()
        defer { dismantle(harness) }
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
        defer { dismantle(harness) }
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
