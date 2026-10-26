// OS probe (vm.sh --suite exec --probe render-motion-survival): spike p03-rendering-016 on macOS 14 and 15, where
// no package test runs (the Tart images have no Xcode). Same question as RenderMotionSpikeTests: does a pane's
// additive render-server spring survive AppKit events, on the pane host's backing layer and on a motion container
// that keeps its springs and adds them to a new backing layer? It is a real app (NSApplication running, launched
// through LaunchServices), so it also enters full screen, which a `swift test` process cannot.
// Each case springs a view from one frame to another (mass 1, critically damped, initial velocity 0, additive),
// applies one event, then reads presentation() at 25, 50 and 75 % of the way. Error: the largest miss of
// position and size, past one frame of travel either side of the read. Limit 0.5 pt.
// Exit 0 when every motion container case holds its spring, 1 when one loses it, 2 when it cannot test. The
// backing layer's numbers are data. Self-contained: AppKit and QuartzCore only (the host stands in for
// PaneHostView: a layer-backed view with masksToBounds that the screen view's layout writes).
import AppKit
import Foundation
import QuartzCore

let os = ProcessInfo.processInfo.operatingSystemVersion
let osName = "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"
let deadline = Date().addingTimeInterval(200)
let tolerance: CGFloat = 0.5

func spin(_ seconds: TimeInterval) {
    RunLoop.current.run(until: Date().addingTimeInterval(seconds))
}

func spin(untilMediaTime time: CFTimeInterval) {
    while CACurrentMediaTime() < time { RunLoop.current.run(until: Date().addingTimeInterval(min(0.004, time - CACurrentMediaTime()))) }
}

/// See key-change-cost.swift: the SSH run cannot be an active app, so it starts a copy in the GUI session.
func relaunchInGUISession() -> Never {
    let fm = FileManager.default
    let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("render-motion-survival-\(getpid())")
    let bundle = dir.appendingPathComponent("RenderMotionSurvival.app")
    let macos = bundle.appendingPathComponent("Contents/MacOS")
    let out = dir.appendingPathComponent("out.txt"), status = dir.appendingPathComponent("status.txt")
    do {
        try fm.createDirectory(at: macos, withIntermediateDirectories: true)
        let me = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        try fm.copyItem(at: me, to: macos.appendingPathComponent("RenderMotionSurvival"))
        let plist: [String: Any] = ["CFBundleExecutable": "RenderMotionSurvival", "CFBundleIdentifier": "com.cmux.matrix.render-motion-survival",
                                    "CFBundleName": "RenderMotionSurvival", "CFBundlePackageType": "APPL", "NSPrincipalClass": "NSApplication"]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: bundle.appendingPathComponent("Contents/Info.plist"))
    } catch {
        print("render-motion-survival macOS \(osName): cannot test (bundle: \(error))")
        exit(2)
    }
    let sign = Process()
    sign.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
    sign.arguments = ["--force", "--sign", "-", bundle.path]
    try? sign.run()
    sign.waitUntilExit()
    let open = Process()
    open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    open.arguments = ["-W", "-n", "--env", "RENDER_MOTION_SURVIVAL_OUT=\(out.path)", "--env", "RENDER_MOTION_SURVIVAL_STATUS=\(status.path)", bundle.path]
    do { try open.run() } catch {
        print("render-motion-survival macOS \(osName): cannot test (open: \(error))")
        exit(2)
    }
    open.waitUntilExit()
    print((try? String(contentsOf: out, encoding: .utf8)) ?? "render-motion-survival macOS \(osName): cannot test (no output from the GUI run; open exited \(open.terminationStatus))", terminator: "")
    let code = Int32((try? String(contentsOf: status, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "") ?? 2
    exit(code)
}

let env = ProcessInfo.processInfo.environment
let outPath = env["RENDER_MOTION_SURVIVAL_OUT"] ?? "", statusPath = env["RENDER_MOTION_SURVIVAL_STATUS"] ?? ""
if outPath.isEmpty || statusPath.isEmpty { relaunchInGUISession() }
freopen(outPath, "w", stdout)
func finish(_ code: Int32) -> Never {
    fflush(stdout)
    try? "\(code)".write(toFile: statusPath, atomically: true, encoding: .utf8)
    exit(code)
}

struct Spring {
    let omega: Double
    func remaining(at time: Double) -> Double { time > 0 ? (1 + omega * time) * exp(-omega * time) : 1 }
    func time(atProgress progress: Double) -> Double {
        var low = 0.0, high = 60 / omega
        for _ in 0..<64 {
            let middle = (low + high) / 2
            if 1 - remaining(at: middle) < progress { low = middle } else { high = middle }
        }
        return high
    }
    func animation(_ keyPath: String, from delta: NSValue, zero: NSValue, beginTime: CFTimeInterval) -> CASpringAnimation {
        let animation = CASpringAnimation(keyPath: keyPath)
        animation.mass = 1
        animation.stiffness = omega * omega
        animation.damping = 2 * omega
        animation.initialVelocity = 0
        animation.duration = time(atProgress: 0.999)
        animation.fromValue = delta
        animation.toValue = zero
        animation.isAdditive = true
        animation.beginTime = beginTime
        return animation
    }
}

/// The motion container: keeps its springs and adds them to any backing layer AppKit makes again.
final class MotionContainer: NSView {
    private var springs: [String: CAAnimation] = [:]
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
    }
    required init?(coder: NSCoder) { nil }
    override func makeBackingLayer() -> CALayer {
        let layer = super.makeBackingLayer()
        layer.masksToBounds = true
        let now = layer.convertTime(CACurrentMediaTime(), from: nil)
        springs = springs.filter { $0.value.beginTime + $0.value.duration > now }
        for (key, spring) in springs { layer.add(spring, forKey: key) }
        return layer
    }
    func addSpring(_ spring: CAAnimation, forKey key: String) {
        springs[key] = spring
        layer?.add(spring, forKey: key)
    }
}

/// The screen view: its layout writes each pane's frame from its rest, scaled to its bounds (ScreenContentView).
final class Screen: NSView {
    var rests: [(view: NSView, rest: NSRect)] = []
    let reference: NSSize
    override init(frame: NSRect) {
        reference = frame.size
        super.init(frame: frame)
        wantsLayer = true
        autoresizingMask = [.width, .height]
        autoresizesSubviews = false
    }
    required init?(coder: NSCoder) { nil }
    func place(_ view: NSView, rest: NSRect) {
        rests.removeAll { $0.view === view }
        rests.append((view: view, rest: rest))
        view.frame = placed(rest)
    }
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }
    override func layout() {
        super.layout()
        for entry in rests where entry.view.frame != placed(entry.rest) { entry.view.frame = placed(entry.rest) }
    }
    func placed(_ rest: NSRect) -> NSRect {
        let sx = bounds.width / reference.width, sy = bounds.height / reference.height
        return NSRect(x: rest.minX * sx, y: rest.minY * sy, width: rest.width * sx, height: rest.height * sy)
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
app.activate(ignoringOtherApps: true)
guard NSScreen.main != nil else {
    print("render-motion-survival macOS \(osName): cannot test (no screen)")
    finish(2)
}

enum Event: String, CaseIterable {
    case control, appKitLayout, ancestorSetFrame, wantsLayer, ancestorWantsLayer, layerReassigned, windowStyleChange, fullScreen
}

/// Runs one case; nil errors when the event could not be applied (not covered).
func run(container useContainer: Bool, event: Event) -> (errors: [CGFloat]?, note: String) {
    let size = NSSize(width: 900, height: 620)
    let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: 120, y: 120), size: size), styleMask: [.titled, .resizable],
                          backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.collectionBehavior = [.fullScreenPrimary]
    let root = NSView(frame: NSRect(origin: .zero, size: size))
    root.wantsLayer = true
    window.contentView = root
    let screen = Screen(frame: root.bounds)
    root.addSubview(screen)
    let host = NSView(frame: .zero)
    host.wantsLayer = true
    host.layer?.masksToBounds = true
    let container = useContainer ? MotionContainer(frame: .zero) : nil
    let animated: NSView = container ?? host
    if let container {
        host.autoresizingMask = [.width, .height]
        container.addSubview(host)
    }
    screen.addSubview(animated)
    screen.place(animated, rest: NSRect(x: 40, y: 40, width: 240, height: 180))
    host.frame = container?.bounds ?? host.frame
    window.makeKeyAndOrderFront(nil)
    spin(0.3)
    defer {
        if window.styleMask.contains(.fullScreen) {
            window.toggleFullScreen(nil)
            let leave = Date().addingTimeInterval(5)
            while window.styleMask.contains(.fullScreen), Date() < leave { spin(0.05) }
        }
        window.orderOut(nil)
        window.close()
    }
    guard let first = animated.layer else { return (nil, "no layer") }
    let spring = Spring(omega: event == .fullScreen ? 0.35 : 2)
    let oldPosition = first.position, oldSize = first.bounds.size
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    screen.place(animated, rest: NSRect(x: 240, y: 160, width: 400, height: 280))
    CATransaction.commit()
    let positionDelta = CGPoint(x: oldPosition.x - first.position.x, y: oldPosition.y - first.position.y)
    let sizeDelta = CGSize(width: oldSize.width - first.bounds.width, height: oldSize.height - first.bounds.height)
    let begin = CACurrentMediaTime()
    let local = first.convertTime(begin, from: nil)
    let animations = [("spike.position", spring.animation("position", from: NSValue(point: positionDelta), zero: NSValue(point: .zero), beginTime: local)),
                      ("spike.size", spring.animation("bounds.size", from: NSValue(size: sizeDelta), zero: NSValue(size: .zero), beginTime: local))]
    for (key, animation) in animations {
        if let container { container.addSpring(animation, forKey: key) } else { first.add(animation, forKey: key) }
    }
    let frameBefore = first.frame
    switch event {
    case .control:
        break
    case .appKitLayout:
        // The layout, not this case, writes the new frame: the rest moves 2 pt and the screen lays out.
        screen.rests = screen.rests.map { (view: $0.view, rest: $0.rest.offsetBy(dx: 2, dy: 2)) }
        screen.needsLayout = true
        root.layoutSubtreeIfNeeded()
    case .ancestorSetFrame:
        screen.setFrameSize(NSSize(width: screen.frame.width + 80, height: screen.frame.height + 40))
        root.layoutSubtreeIfNeeded()
        window.setFrame(window.frame.insetBy(dx: -40, dy: -30), display: true)
        root.layoutSubtreeIfNeeded()
    case .wantsLayer:
        animated.wantsLayer = false
        window.displayIfNeeded()
        animated.wantsLayer = true
        window.displayIfNeeded()
    case .ancestorWantsLayer:
        screen.wantsLayer = false
        window.displayIfNeeded()
        screen.wantsLayer = true
        window.displayIfNeeded()
    case .layerReassigned:
        animated.layer = animated.makeBackingLayer()
        window.displayIfNeeded()
    case .windowStyleChange:
        window.styleMask.insert(.fullSizeContentView)
        window.titlebarAppearsTransparent = true
        if let visible = window.screen?.visibleFrame { window.setFrame(visible, display: true) }
        root.layoutSubtreeIfNeeded()
    case .fullScreen:
        window.toggleFullScreen(nil)
        let enterBy = begin + spring.time(atProgress: 0.25) - 0.5
        while !window.styleMask.contains(.fullScreen) || window.frame.size != window.screen?.frame.size, CACurrentMediaTime() < enterBy {
            spin(0.02)
        }
        guard window.styleMask.contains(.fullScreen) else { return (nil, "full screen not entered before the 25 % mark") }
        root.layoutSubtreeIfNeeded()
    }
    guard let layer = animated.layer else { return (nil, "no layer after the event") }
    let replaced = layer !== first, written = layer.frame != frameBefore
    let note = "layerReplaced=\(replaced) frameWritten=\(written)"
    switch event {
    case .appKitLayout, .ancestorSetFrame, .windowStyleChange, .fullScreen:
        if !written { return (nil, "\(note): the event wrote no frame") }
    case .layerReassigned:
        if !replaced { return (nil, "\(note): the layer was not replaced") }
    case .wantsLayer, .ancestorWantsLayer:
        if !replaced { return (nil, "\(note): AppKit kept the layer, not a replacement") }
    case .control:
        break
    }
    var errors: [CGFloat] = []
    for mark in [0.25, 0.5, 0.75] {
        let at = begin + spring.time(atProgress: mark)
        guard CACurrentMediaTime() < at else { return (nil, "\(note): the \(Int(mark * 100)) % mark passed before it was read") }
        spin(untilMediaTime: at)
        let before = CACurrentMediaTime() - begin
        guard let shown = layer.presentation() else { errors.append(.infinity); continue }
        let after = CACurrentMediaTime() - begin
        let early = CGFloat(spring.remaining(at: before - 1.0 / 60)), late = CGFloat(spring.remaining(at: after + 1.0 / 60))
        func miss(_ measured: CGFloat, _ delta: CGFloat) -> CGFloat {
            let low = min(delta * early, delta * late), high = max(delta * early, delta * late)
            return measured < low ? low - measured : measured > high ? measured - high : 0
        }
        errors.append(max(miss(shown.position.x - layer.position.x, positionDelta.x),
                          miss(shown.position.y - layer.position.y, positionDelta.y),
                          miss(shown.bounds.width - layer.bounds.width, sizeDelta.width),
                          miss(shown.bounds.height - layer.bounds.height, sizeDelta.height)))
    }
    return (errors, note)
}

func format(_ value: CGFloat) -> String { value.isFinite ? String(format: "%.2f", Double(value)) : "lost" }

print("render-motion-survival macOS \(osName): error in pt at 25/50/75 % of the way (limit \(tolerance))")
var containerFailed = false
for event in Event.allCases {
    for useContainer in [false, true] {
        guard Date() < deadline else {
            print("  stopped at the time limit")
            finish(2)
        }
        let layer = useContainer ? "motionContainer" : "backingLayer"
        let result = run(container: useContainer, event: event)
        guard let errors = result.errors else {
            print("  render-motion-spike layer=\(layer) event=\(event.rawValue) notCovered (\(result.note))")
            continue
        }
        let held = errors.allSatisfy { $0 <= tolerance }
        if useContainer, !held { containerFailed = true }
        print("  render-motion-spike layer=\(layer) event=\(event.rawValue) p25=\(format(errors[0])) p50=\(format(errors[1])) " +
              "p75=\(format(errors[2])) \(result.note)\(held ? "" : " LOST")")
        fflush(stdout)
    }
}
finish(containerFailed ? 1 : 0)
