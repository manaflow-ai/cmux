import AppKit

/// Exercises Retina conversion even when the fleet console has a 1x display.
@MainActor
final class TerminalPaneMetricsWindow: NSWindow {
    var testBackingScale: CGFloat = 1

    deinit {}

    override var backingScaleFactor: CGFloat { testBackingScale }
}
