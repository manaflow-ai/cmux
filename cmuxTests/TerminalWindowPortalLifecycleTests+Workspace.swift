import AppKit
import CmuxTerminal
import GhosttyKit

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

extension TerminalWindowPortalLifecycleTests {
    func waitForPortalPresentation(
        _ surface: TerminalSurface,
        after baseline: GhosttySurfaceScrollView.DebugRenderStats
    ) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !Task.isCancelled {
            let stats = surface.hostedView.debugRenderStats()
            // Embedded Ghostty can present through IOSurfaceLayer instead of
            // CAMetalLayer; its contents seed is the observable frame change.
            if stats.metalDrawableCount > baseline.metalDrawableCount ||
                (stats.layerContentsKey != "nil" && stats.presentCount > baseline.presentCount) { return true }
            guard ContinuousClock.now < deadline else { return false }
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async { continuation.resume() }
            }
        }
        return false
    }

    /// Wait for the queued portal commit and runtime creation without holding
    /// the main actor in a nested run loop.
    func waitForSettledPortalGeometry(_ surface: TerminalSurface, anchor: NSView) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !Task.isCancelled {
            let hosted = surface.hostedView
            let view = hosted.surfaceView
            let pixels = surface.debugCurrentPixelSize()
            let expected = view.expectedPixelSize(for: view.bounds.size)
            if surface.surface != nil, surface.committedPaneGeometry?.phase == .settled,
               surface.committedPaneGeometry?.size == view.bounds.size,
               hosted.frame.size == anchor.bounds.size, view.bounds.width > 1,
               pixels.width == UInt32(expected.width.rounded(.down)),
               pixels.height == UInt32(expected.height.rounded(.down)) { return true }
            guard ContinuousClock.now < deadline else { return false }
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async { continuation.resume() }
            }
        }
        return false
    }

    func layoutResizeTestWindow(_ window: NSWindow) {
        window.makeKeyAndOrderFront(nil)
        window.displayIfNeeded()
        window.contentView?.layoutSubtreeIfNeeded()
    }

    func waitForResizeTestGeometry(_ surface: TerminalSurface, anchor: NSView) -> Bool {
        waitUntil(timeout: 2) {
            let hosted = surface.hostedView
            let view = hosted.surfaceView
            let pixels = surface.debugCurrentPixelSize()
            let expected = view.expectedPixelSize(for: view.bounds.size)
            return hosted.isVisibleInUI && !hosted.isHidden &&
                hosted.frame.size == anchor.bounds.size &&
                view.bounds.width > 1 && view.bounds.height > 1 &&
                view.bounds.width <= hosted.bounds.width &&
                pixels.width == UInt32(expected.width.rounded(.down)) &&
                pixels.height == UInt32(expected.height.rounded(.down))
        }
    }

    /// Tests free their surfaces milliseconds after Ghostty spawns them, while
    /// login(1) still ignores SIGHUP during its startup. Closing then waits out
    /// Ghostty's whole 12 s SIGHUP grace, which is sized for agent exit hooks,
    /// before it escalates to SIGKILL: every test in this suite took 12 s. A
    /// test shell needs no graceful exit, so kill every process on the
    /// surface's terminal first and the close finds nothing left to wait for.
    func killShellProcesses(of surface: TerminalSurface) {
        // Ghostty opens the PTY on its IO thread, so right after spawn the
        // device may not be known yet. Only a live runtime has a process.
        guard surface.surface != nil else { return }
        _ = waitUntil(timeout: 1) { surface.controllingTTYDeviceIdentifier != nil }
        guard let device = surface.controllingTTYDeviceIdentifier else { return }
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_TTY, Int32(truncatingIfNeeded: device)]
        var size = 0
        guard sysctl(&mib, 4, nil, &size, nil, 0) == 0, size > 0 else { return }
        let stride = MemoryLayout<kinfo_proc>.stride
        var processes = [kinfo_proc](repeating: kinfo_proc(), count: size / stride + 8)
        size = processes.count * stride
        guard sysctl(&mib, 4, &processes, &size, nil, 0) == 0 else { return }
        let ownGroup = getpgrp()
        for process in processes.prefix(size / stride) {
            let pid = process.kp_proc.p_pid
            guard pid > 1, pid != getpid(), process.kp_eproc.e_pgid != ownGroup else { continue }
            kill(pid, SIGKILL)
        }
    }

    func makeTrackedTerminalSurface() -> TerminalSurface {
        let workspace = testWorkspace ?? TerminalPortalTestWorkspace()
        testWorkspace = workspace
        let surface = TerminalSurface(
            tabId: workspace.id,
            context: GHOSTTY_SURFACE_CONTEXT_SPLIT,
            configTemplate: nil,
            workingDirectory: nil
        )
        trackedSurfaces.append(surface)
        return surface
    }
}
