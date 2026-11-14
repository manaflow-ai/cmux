import AppKit
import CmuxTerminal
import Darwin
import GhosttyKit
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Owns only the window, process, and portal created by one geometry test.
@MainActor
final class TerminalPortalGeometryFixture {
    private let workspace = TerminalPortalTestWorkspace()
    let window: NSWindow
    let anchor: NSView
    let portal: WindowTerminalPortal
    let surface: TerminalSurface
    private var dividerResizeActive = false
    var hosted: GhosttySurfaceScrollView { surface.hostedView }
    var hostedID: ObjectIdentifier { ObjectIdentifier(hosted) }
    /// The longest this surface's first runtime may wait for its command-shim install.
    private let shimInstallDeadline: Duration

    /// - Parameter stalledShimInstallDeadline: When set, the surface's agent
    ///   command-shim install never finishes, so only this install deadline
    ///   (#9769) can release its first runtime.
    init(anchorView: NSView? = nil, stalledShimInstallDeadline: Duration? = nil) {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 420),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false
        )
        window.animationBehavior = .none
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        window.displayIfNeeded()
        window.contentView?.layoutSubtreeIfNeeded()
        anchor = anchorView ?? NSView(frame: NSRect(x: 8, y: 8, width: 520, height: 280))
        window.contentView?.addSubview(anchor)
        portal = WindowTerminalPortal(window: window)
        let live = GhosttyApp.terminalSurfaceRuntimeDependencies
        shimInstallDeadline = stalledShimInstallDeadline ?? live.agentCommandShimInstallDeadline
        surface = TerminalSurface(
            tabId: workspace.id, context: GHOSTTY_SURFACE_CONTEXT_SPLIT,
            configTemplate: nil, workingDirectory: nil,
            dependencies: stalledShimInstallDeadline.map {
                Self.dependencies(live, stallingShimInstallUntil: $0)
            } ?? live
        )
    }

    /// The live runtime collaborators with a command-shim install that does
    /// not finish within the test.
    private static func dependencies(
        _ live: TerminalSurfaceRuntimeDependencies,
        stallingShimInstallUntil deadline: Duration
    ) -> TerminalSurfaceRuntimeDependencies {
        TerminalSurfaceRuntimeDependencies(
            registry: live.registry,
            engine: live.engine,
            viewProvider: live.viewProvider,
            spawnPolicy: live.spawnPolicy,
            byteTee: live.byteTee,
            rendererRealization: live.rendererRealization,
            hibernationRecorder: live.hibernationRecorder,
            runtimeTeardown: live.runtimeTeardown,
            restoreSpawnScheduler: live.restoreSpawnScheduler,
            runtimeFilesystem: TerminalSurfaceRuntimeFilesystem(
                agentCommandShimRootDirectory: live.runtimeFilesystem.agentCommandShimRootDirectory,
                installAgentCommandShims: { _, _, _ in
                    try? await Task.sleep(for: .seconds(60))
                    return nil
                },
                isExecutableFile: live.runtimeFilesystem.isExecutableFile
            ),
            agentCommandShimInstallDeadline: deadline,
            agentCommandShimInstallDeadlineClock: live.agentCommandShimInstallDeadlineClock,
            sessionPortBase: live.sessionPortBase,
            sessionPortRangeSize: live.sessionPortRangeSize,
            scrollbackReplayEnvironmentKey: live.scrollbackReplayEnvironmentKey,
            globalFontMagnificationPercent: live.globalFontMagnificationPercent,
            terminalWork: live.terminalWork
        )
    }

    func bind(visible: Bool = true) {
        // Match the host's visibility-before-attachment order so a visible
        // runtime must wait for its first committed portal geometry.
        hosted.setVisibleInUI(visible)
        portal.bind(hostedView: hosted, to: anchor, visibleInUI: visible)
    }

    func beginResize(native: Bool) {
        if native {
            portal.isWindowLiveResizeActiveOverrideForTesting = true
        } else {
            dividerResizeActive = true
            TerminalWindowPortalRegistry.beginInteractiveGeometryResize(in: window)
        }
    }

    func endResize() {
        portal.isWindowLiveResizeActiveOverrideForTesting = false
        if dividerResizeActive {
            dividerResizeActive = false
            TerminalWindowPortalRegistry.endInteractiveGeometryResize(in: window)
        }
        // A fixture owns a direct portal, outside the process-wide registry.
        NotificationCenter.default.post(name: NSWindow.didEndLiveResizeNotification, object: window)
    }

    func flushLayout() async {
        window.contentView?.layoutSubtreeIfNeeded()
        // Suspend the test behind the portal's queued callbacks. A nested
        // RunLoop from a synchronous MainActor test does not drain that work.
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    /// How long a published geometry may take to reach Ghostty's grid and the
    /// PTY. A visible exec surface creates its runtime only after its agent
    /// command shims install or the install deadline passes (#9769). That
    /// install is utility-priority file I/O, so a busy host can hold the first
    /// runtime for up to the deadline after the geometry has already settled
    /// (main run 36748094366, app-host shard 4: settled, pending=false, no runtime).
    private var commitWaitBound: Duration { shimInstallDeadline + .seconds(2) }

    func requireCommit(
        width: CGFloat? = nil,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
        let deadline = ContinuousClock.now.advanced(by: commitWaitBound)
        repeat {
            if let geometry = surface.committedPaneGeometry,
               geometry.phase == .settled, gridMatchesPTY(),
               portal.entriesByHostedId[hostedID]?.needsSettledCommit == false,
               geometry.size == hosted.surfaceView.frame.size,
               width.map({ abs($0 - geometry.size.width) < 0.5 }) ?? true {
                return
            }
            await flushLayout()
        } while ContinuousClock.now < deadline && !Task.isCancelled
        let didCommit = false
        try #require(
            didCommit,
            Comment(rawValue: "Expected a settled geometry with matching Ghostty grid and PTY; " +
                "geometry=\(String(describing: surface.committedPaneGeometry)), " +
                "viewport=\(hosted.surfaceView.frame.size), runtime=\(surface.surface != nil), " +
                "tty=\(surface.controllingTTYName() ?? "nil"), " +
                "pending=\(String(describing: portal.entriesByHostedId[hostedID]?.needsSettledCommit))"),
            sourceLocation: sourceLocation
        )
    }

    func requireScrollback(sourceLocation: SourceLocation = #_sourceLocation) async throws {
        // Real shell output keeps the scroller present after the runtime's
        // first scrollbar packet; a style toggle on an empty shell is a no-op.
        let command = #"/bin/sh -c 'i=0; while [ "$i" -lt 80 ]; do printf "cmux-geometry-scroll\n"; i=$((i + 1)); done'"#
        try #require(surface.sendInput(command + "\r"), sourceLocation: sourceLocation)
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        repeat {
            if let scrollbar = hosted.surfaceView.scrollbar, scrollbar.total > scrollbar.len { return }
            await flushLayout()
        } while ContinuousClock.now < deadline && !Task.isCancelled
        let hasScrollback = false
        try #require(
            hasScrollback,
            Comment(rawValue: "Expected shell output to create real scrollback; " + scrollbackDiagnostics()),
            sourceLocation: sourceLocation
        )
    }

    /// Separates the two ways the scrollback wait can fail: the command never
    /// produced output (the terminal holds no scrollback), or it did and the
    /// view never received the runtime's scrollbar packet.
    private func scrollbackDiagnostics() -> String {
        var runtime = ghostty_surface_scrollbar_s()
        let runtimeScrollbar = hosted.surfaceView.readAuthoritativeScrollbar(&runtime)
            ? "total=\(runtime.total) offset=\(runtime.offset) len=\(runtime.len)"
            : "unavailable"
        let text = surface.visibleText().map { String($0.suffix(600)) } ?? "nil"
        return "viewScrollbar=\(String(describing: hosted.surfaceView.scrollbar)), " +
            "runtimeScrollbar=\(runtimeScrollbar), tty=\(surface.controllingTTYName() ?? "nil"), " +
            "visibleText=\(text.debugDescription)"
    }

    /// Read the actual terminal screen and kernel TTY, not just Ghostty's
    /// main-thread size cache, which can lead its asynchronous IO resize.
    private func gridMatchesPTY() -> Bool {
        guard let runtime = surface.surface,
              let name = surface.controllingTTYName() else { return false }
        let path = name.hasPrefix("/dev/") ? name : "/dev/\(name)"
        let descriptor = Darwin.open(path, O_RDONLY | O_NONBLOCK | O_NOCTTY)
        guard descriptor >= 0 else { return false }
        defer { Darwin.close(descriptor) }
        var size = winsize()
        var grid = ghostty_surface_grid_metrics_s()
        guard ioctl(descriptor, TIOCGWINSZ, &size) == 0,
              ghostty_surface_grid_metrics(runtime, &grid) else { return false }
        let requested = ghostty_surface_size(runtime)
        return grid.columns > 1 && grid.rows > 1 &&
            grid.columns == size.ws_col && grid.rows == size.ws_row &&
            grid.columns == requested.columns && grid.rows == requested.rows
    }

    func close() {
        endResize()
        surface.releaseHostedSurfaceForTesting()
        portal.tearDown()
        window.close()
        workspace.tearDown()
    }
}
