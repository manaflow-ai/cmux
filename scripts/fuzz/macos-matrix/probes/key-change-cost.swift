// OS probe (vm.sh --suite exec --probe key-change-cost): issue #24913. A 10 s main-thread stall inside one
// AppKit key-window change (`-[NSWindow makeKeyWindow]` > `_windowChangedKeyState`, about 20 view levels) on
// macOS 14 and 15. cmux NEXT keeps every workspace a window showed in the window as a hidden view tree
// (WindowRootView.show, perf I6). This probe measures what one key change costs against the size of such hidden
// trees: a "cmux" window with N hidden workspace-like trees (nested views, tab strip buttons, text fields) and a
// child "page" window (as Chromium's page window). It times the key moving to the page window and back, and the
// display pass after each, with the trees hidden in the window and with the same trees out of the window.
// The numbers are the data: it exits 0 once it measured, 2 when it cannot test (no active app, no window server).
// Self-contained, AppKit only.
import AppKit
import Foundation

let os = ProcessInfo.processInfo.operatingSystemVersion
let osName = "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"
let deadline = Date().addingTimeInterval(200)

final class PageWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// One workspace-like tree: a tab strip of buttons, panes of nested views about 20 levels deep, fields.
func workspace(size: NSSize) -> (view: NSView, views: Int, controls: Int) {
    var views = 0, controls = 0
    func add(_ child: NSView, to parent: NSView) {
        parent.addSubview(child)
        views += 1
        if child is NSControl { controls += 1 }
    }
    let root = NSView(frame: NSRect(origin: .zero, size: size))
    views += 1
    let strip = NSView(frame: NSRect(x: 0, y: size.height - 32, width: size.width, height: 32))
    add(strip, to: root)
    for index in 0..<12 {
        let tab = NSView(frame: NSRect(x: CGFloat(index) * 90, y: 0, width: 88, height: 32))
        add(tab, to: strip)
        let close = NSButton(title: "x", target: nil, action: nil)
        close.bezelStyle = .rounded
        close.frame = NSRect(x: 64, y: 4, width: 22, height: 22)
        add(close, to: tab)
        add(NSTextField(labelWithString: "Tab \(index)"), to: tab)
    }
    for pane in 0..<4 {
        var parent = NSView(frame: NSRect(x: CGFloat(pane) * size.width / 4, y: 0, width: size.width / 4, height: size.height - 32))
        add(parent, to: root)
        for level in 0..<18 {
            let child = NSView(frame: parent.bounds.insetBy(dx: 1, dy: 1))
            add(child, to: parent)
            if level % 3 == 0 {
                let button = NSButton(checkboxWithTitle: "b\(level)", target: nil, action: nil)
                add(button, to: parent)
                let push = NSButton(title: "p\(level)", target: nil, action: nil)
                push.bezelStyle = .rounded
                add(push, to: parent)
            }
            parent = child
        }
        add(NSTextField(string: "field"), to: parent)
    }
    return (root, views, controls)
}

func spin(_ seconds: TimeInterval) {
    RunLoop.current.run(until: Date().addingTimeInterval(seconds))
}

func ms(_ start: UInt64) -> Double { Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000 }

func stats(_ values: [Double]) -> String {
    guard !values.isEmpty else { return "n=0" }
    let sorted = values.sorted()
    let p50 = sorted[sorted.count / 2], maximum = sorted.last!
    return String(format: "p50=%.2f max=%.2f", p50, maximum)
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
app.activate(ignoringOtherApps: true)
let frame = NSRect(x: 100, y: 100, width: 1200, height: 800)
let cmux = NSWindow(contentRect: frame, styleMask: [.titled, .resizable, .closable], backing: .buffered, defer: false)
cmux.isReleasedWhenClosed = false
let content = NSView(frame: NSRect(origin: .zero, size: frame.size))
cmux.contentView = content
let shown = workspace(size: frame.size)
content.addSubview(shown.view)
let page = PageWindow(contentRect: NSRect(x: 400, y: 200, width: 600, height: 400), styleMask: [.borderless], backing: .buffered, defer: false)
page.isReleasedWhenClosed = false
page.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
cmux.makeKeyAndOrderFront(nil)
cmux.addChildWindow(page, ordered: .above)
page.orderFront(nil)
for _ in 0..<50 where !(app.isActive && cmux.isKeyWindow) { spin(0.1) }
guard app.isActive, cmux.isKeyWindow else {
    print("key-change-cost macOS \(osName): cannot test (active=\(app.isActive) cmuxKey=\(cmux.isKeyWindow))")
    exit(2)
}

func countViews(_ view: NSView) -> Int { view.subviews.reduce(1) { $0 + countViews($1) } }

/// Moves the key to the page window and back `rounds` times; each change and the display after it, in ms.
func measure(rounds: Int) -> (toPage: [Double], toCmux: [Double], display: [Double]) {
    var toPage: [Double] = [], toCmux: [Double] = [], display: [Double] = []
    for _ in 0..<rounds where Date() < deadline {
        var start = DispatchTime.now().uptimeNanoseconds
        page.makeKey()
        toPage.append(ms(start))
        start = DispatchTime.now().uptimeNanoseconds
        cmux.displayIfNeeded()
        page.displayIfNeeded()
        display.append(ms(start))
        start = DispatchTime.now().uptimeNanoseconds
        cmux.makeKey()
        toCmux.append(ms(start))
        start = DispatchTime.now().uptimeNanoseconds
        cmux.displayIfNeeded()
        page.displayIfNeeded()
        display.append(ms(start))
        spin(0.01)
    }
    return (toPage, toCmux, display)
}

print("key-change-cost macOS \(osName): ms per key change (to the page window, back to the cmux window) and per display pass after it")
var parked: [NSView] = []
var parkedViews = 0, parkedControls = 0
for target in [0, 10, 40, 120] {
    while parked.count < target {
        let tree = workspace(size: frame.size)
        tree.view.isHidden = true
        parked.append(tree.view)
        parkedViews += tree.views
        parkedControls += tree.controls
    }
    for mode in ["hidden-in-window", "out-of-window"] {
        if target == 0, mode == "out-of-window" { continue }
        for view in parked where (mode == "hidden-in-window") != (view.superview === content) {
            if mode == "hidden-in-window" { content.addSubview(view) } else { view.removeFromSuperview() }
        }
        spin(0.2)
        let result = measure(rounds: 15)
        print(String(format: "  parked=%3d %-16@ window_views=%6d (parked views %d, controls %d) to_page %@ to_cmux %@ display %@",
                     target, mode as NSString, countViews(content), mode == "hidden-in-window" ? parkedViews : 0,
                     mode == "hidden-in-window" ? parkedControls : 0, stats(result.toPage) as NSString,
                     stats(result.toCmux) as NSString, stats(result.display) as NSString))
        fflush(stdout)
        if Date() >= deadline { print("  stopped at the time limit"); exit(0) }
    }
}
exit(0)
