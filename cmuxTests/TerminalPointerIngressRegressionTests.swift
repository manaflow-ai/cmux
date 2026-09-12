import AppKit
import CmuxTerminal
import GhosttyKit
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite("Pointer ingress semantic preservation")
struct TerminalPointerIngressRegressionTests {
    @Test("callback ingress uses the explicit surface identity")
    func callbackIngressUsesExplicitSurfaceIdentity() {
        let runtimeID = UUID()
        let surfaceID = UUID()
        let view = GhosttyNSView(frame: .zero)
        let generation = view.prepareForRuntimeSurfaceCreation(
            runtimeLifetimeId: runtimeID,
            surfaceId: surfaceID
        )
        let ingress = view.pointerStyleIngress!

        #expect(ingress.mailbox.snapshot.surfaceId == surfaceID)
        #expect(ingress.submit(
            .init(
                event: .shape(GHOSTTY_MOUSE_SHAPE_COPY),
                surfaceId: surfaceID,
                runtimeLifetimeId: runtimeID,
                runtimeGeneration: generation
            )
        ))
        #expect(!ingress.submit(
            .init(
                event: .shape(GHOSTTY_MOUSE_SHAPE_WAIT),
                surfaceId: UUID(),
                runtimeLifetimeId: runtimeID,
                runtimeGeneration: generation
            )
        ))
    }

    @Test("coalescing preserves the last supported shape before an unsupported shape")
    func supportedIntermediateShapeSurvivesCoalescing() {
        let runtimeID = UUID()
        let surfaceID = UUID()
        let view = GhosttyNSView(frame: .zero)
        let generation = view.prepareForRuntimeSurfaceCreation(
            runtimeLifetimeId: runtimeID,
            surfaceId: surfaceID
        )
        view.applyTerminalPointerStyle(.focusChanged(true))
        let ingress = view.pointerStyleIngress!
        for shape in [GHOSTTY_MOUSE_SHAPE_CROSSHAIR, GHOSTTY_MOUSE_SHAPE_COPY, GHOSTTY_MOUSE_SHAPE_WAIT] {
            ingress.submit(.init(event: .shape(shape), surfaceId: surfaceID,
                runtimeLifetimeId: runtimeID, runtimeGeneration: generation))
        }
        // Deliver only the final snapshot; no intermediate UI delivery is necessary.
        view.applyTerminalPointerStyleSnapshot(ingress.mailbox.snapshot)
        #expect(view.effectiveTerminalPointerCursor == NSCursor.dragCopy)
    }

    @Test("a snapshot captured before focus loss cannot resurrect the old cursor")
    func oldSnapshotCannotCrossFocusTransition() {
        let view = GhosttyNSView(frame: .zero)
        let runtimeID = UUID()
        let surfaceID = UUID()
        view.prepareForRuntimeSurfaceCreation(
            runtimeLifetimeId: runtimeID,
            surfaceId: surfaceID
        )
        view.applyTerminalPointerStyle(.focusChanged(true))
        view.applyTerminalPointerStyle(.ghosttyShape(GHOSTTY_MOUSE_SHAPE_COPY, runtimeLifetimeId: runtimeID))
        let oldSnapshot = view.pointerStyleIngress!.mailbox.snapshot
        view.applyTerminalPointerStyle(.focusChanged(false))
        #expect(!view.applyTerminalPointerStyleSnapshot(oldSnapshot))
        #expect(view.effectiveTerminalPointerCursor == NSCursor.iBeam)
    }
}
