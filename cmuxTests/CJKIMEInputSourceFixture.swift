import AppKit
import CmuxTerminal
import CmuxTerminalCore

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Gives each hosted terminal its own input-source values without changing TIS state.
@MainActor
struct CJKIMEInputSourceFixture: TerminalSurfaceViewProviding {
    let snapshot: KeyboardLayout.InputSourceSnapshot

    func makeSurfaceViews(
        initialFrame: NSRect
    ) -> (surfaceView: any TerminalSurfaceNativeViewing, paneHost: any TerminalSurfacePaneHosting) {
        let snapshot = snapshot
        let view = GhosttyNSView(frame: initialFrame, readInputSource: { snapshot })
        return (view, GhosttySurfaceScrollView(surfaceView: view))
    }

    func makeSurface() -> TerminalSurface {
        let live = GhosttyApp.terminalSurfaceRuntimeDependencies
        let dependencies = TerminalSurfaceRuntimeDependencies(
            registry: live.registry,
            engine: live.engine,
            viewProvider: self,
            spawnPolicy: live.spawnPolicy,
            byteTee: live.byteTee,
            rendererRealization: live.rendererRealization,
            hibernationRecorder: live.hibernationRecorder,
            runtimeTeardown: live.runtimeTeardown,
            restoreSpawnScheduler: live.restoreSpawnScheduler,
            runtimeFilesystem: live.runtimeFilesystem,
            agentCommandShimInstallDeadline: live.agentCommandShimInstallDeadline,
            agentCommandShimInstallDeadlineClock: live.agentCommandShimInstallDeadlineClock,
            sessionPortBase: live.sessionPortBase,
            sessionPortRangeSize: live.sessionPortRangeSize,
            scrollbackReplayEnvironmentKey: live.scrollbackReplayEnvironmentKey,
            globalFontMagnificationPercent: live.globalFontMagnificationPercent,
            terminalWork: live.terminalWork
        )
        return TerminalSurface(
            tabId: UUID(),
            context: GHOSTTY_SURFACE_CONTEXT_SPLIT,
            configTemplate: nil,
            dependencies: dependencies
        )
    }
}
