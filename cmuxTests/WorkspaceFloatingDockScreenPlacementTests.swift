import CmuxWindowing
import CoreGraphics
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite
struct WorkspaceFloatingDockScreenPlacementTests {
    private func display(
        id: UInt32,
        stableID: String,
        frame: CGRect
    ) -> SessionDisplayGeometry {
        SessionDisplayGeometry(
            displayID: id,
            stableID: stableID,
            frame: frame,
            visibleFrame: frame
        )
    }

    private func snapshot(
        id: UInt32,
        stableID: String,
        frame: CGRect
    ) -> SessionDisplaySnapshot {
        SessionDisplaySnapshot(
            displayID: id,
            stableID: stableID,
            frame: SessionRectSnapshot(frame),
            visibleFrame: SessionRectSnapshot(frame)
        )
    }

    @Test
    func screenResizePreservesRelativeCenterAndWindowSize() throws {
        let oldDisplayFrame = CGRect(x: 0, y: 0, width: 1_000, height: 800)
        let resizedDisplay = display(
            id: 8,
            stableID: "display-a",
            frame: CGRect(x: 0, y: 0, width: 2_000, height: 1_600)
        )
        let oldWindowFrame = CGRect(x: 500, y: 300, width: 400, height: 300)

        let resolved = try #require(WorkspaceFloatingDockScreenPlacement.resolvedFrame(
            currentSignature: "resized",
            configFrames: SessionConfigFrameRing(),
            fallbackFrame: oldWindowFrame,
            fallbackDisplay: snapshot(id: 8, stableID: "display-a", frame: oldDisplayFrame),
            availableDisplays: [resizedDisplay],
            fallbackDisplayGeometry: resizedDisplay
        ))

        #expect(resolved == CGRect(x: 1_200, y: 750, width: 400, height: 300))
    }

    @Test
    func returningDisplayConfigurationRestoresExactRememberedFrame() throws {
        let builtIn = display(
            id: 1,
            stableID: "built-in",
            frame: CGRect(x: 0, y: 0, width: 1_440, height: 900)
        )
        let external = display(
            id: 2,
            stableID: "external",
            frame: CGRect(x: 1_440, y: 0, width: 1_920, height: 1_080)
        )
        let rememberedFrame = CGRect(x: 2_100, y: 420, width: 520, height: 380)
        let rememberedEntry = SessionConfigFrameEntry(
            signature: "dual",
            frame: SessionRectSnapshot(rememberedFrame),
            display: snapshot(id: 2, stableID: "external", frame: external.frame),
            lastUsedAt: 1
        )

        let resolved = try #require(WorkspaceFloatingDockScreenPlacement.resolvedFrame(
            currentSignature: "dual",
            configFrames: SessionConfigFrameRing(entries: [rememberedEntry]),
            fallbackFrame: CGRect(x: 200, y: 200, width: 520, height: 380),
            fallbackDisplay: snapshot(id: 1, stableID: "built-in", frame: builtIn.frame),
            availableDisplays: [builtIn, external],
            fallbackDisplayGeometry: builtIn
        ))

        #expect(resolved == rememberedFrame)
    }

    @Test
    func removedDisplayMovesWindowRelativelyOntoFallbackDisplay() throws {
        let builtIn = display(
            id: 1,
            stableID: "built-in",
            frame: CGRect(x: 0, y: 0, width: 1_000, height: 800)
        )
        let externalFrame = CGRect(x: 1_000, y: 0, width: 1_000, height: 800)
        let externalWindowFrame = CGRect(x: 1_500, y: 300, width: 400, height: 300)

        let resolved = try #require(WorkspaceFloatingDockScreenPlacement.resolvedFrame(
            currentSignature: "single",
            configFrames: SessionConfigFrameRing(),
            fallbackFrame: externalWindowFrame,
            fallbackDisplay: snapshot(id: 2, stableID: "external", frame: externalFrame),
            availableDisplays: [builtIn],
            fallbackDisplayGeometry: builtIn
        ))

        #expect(resolved == CGRect(x: 500, y: 300, width: 400, height: 300))
    }
}
