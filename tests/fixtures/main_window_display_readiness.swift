import AppKit

@MainActor final class ProbeState {
    var draws = 0
    var completions = 0
    var deliveries = 0
    var afterFirstDraw: (() -> Void)?
}
final class ProbeView: NSView {
    let state: ProbeState
    init(state: ProbeState) {
        self.state = state
        super.init(frame: NSRect(x: 0, y: 0, width: 120, height: 80))
    }
    required init?(coder: NSCoder) { fatalError("unused") }
    override func draw(_ dirtyRect: NSRect) {
        state.draws += 1
        let completion = state.afterFirstDraw
        state.afterFirstDraw = nil
        completion?()
    }
}
final class ProbeWindow: NSWindow {
    // WINDOW LIFECYCLE
}
@main struct Probe {
    @MainActor static func require(_ condition: Bool, _ message: String) {
        if !condition { print("FAIL: " + message); exit(1) }
    }
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let state = ProbeState()
        let window = ProbeWindow(contentRect: NSRect(x: 40, y: 40, width: 120, height: 80),
                                 styleMask: [.titled], backing: .buffered, defer: false)
        window.isRestorable = false
        window.alphaValue = 0.01
        window.contentView = ProbeView(state: state)
        let mode = CommandLine.arguments[1]
        let finish = {
            require(state.draws > 0 && state.completions == 1 && state.deliveries == 1,
                    "completion Task did not follow a real draw exactly once")
            window.displayIfNeeded()
            require(state.completions == 1, "later display delivered twice")
            window.orderOut(nil)
            print("PASS \(mode): draw=\(state.draws), completion=\(state.completions), Task=\(state.deliveries)")
            exit(0)
        }
        let subscribe = {
            window.whenInitialDisplayCompletes {
                state.completions += 1
                Task { @MainActor in
                    state.deliveries += 1
                    finish()
                }
            }
        }
        if mode == "before" {
            subscribe()
            require(state.completions == 0 && state.deliveries == 0, "registration inferred a display")
        } else if mode == "hidden" {
            window.display()
            subscribe()
            window.displayIfNeeded()
            require(!window.isVisible && state.completions == 0 && state.deliveries == 0,
                    "hidden display opened readiness")
            print("PASS hidden: completion=0")
            exit(0)
        } else {
            state.afterFirstDraw = { [weak window] in
                DispatchQueue.main.async { [weak window] in
                    guard let window else { require(false, "window released before registration"); return }
                    require(state.draws > 0, "initial display never drew the real content view")
                    // Automatic AppKit display has finished; optionally exercise each public entrypoint.
                    if mode == "late-display" { window.display() }
                    if mode == "late-if-needed" { window.displayIfNeeded() }
                    let drawsBeforeSubscription = state.draws
                    window.contentView?.needsDisplay = false
                    // No event-loop turn or display call follows registration before this oracle.
                    subscribe()
                    require(state.completions == 1, "completed paint was lost before late registration")
                    require(state.draws == drawsBeforeSubscription, "late registration required a redraw")
                    require(state.deliveries == 0, "Task delivered inside the registration call stack")
                    window.whenInitialDisplayCompletes { state.completions += 10 }
                    require(state.completions == 1, "repeated registration delivered twice")
                }
            }
        }
        window.orderFrontRegardless()
        window.contentView?.needsDisplay = true
        // This deadline only fails a missing draw/completion; it never signals readiness.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { require(false, "no real draw/completion before probe timeout") }
        app.run()
    }
}
