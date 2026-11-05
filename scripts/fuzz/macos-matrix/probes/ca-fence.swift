// OS probe (vm.sh --suite exec --probe ca-fence), SPIKE from scratch/frame-owner-s4-fence-spike-nomerge (never
// merged): which Core Animation fence SPI selectors this OS has, then, when the probe can open a window that draws,
// the fence spike of CoreAnimationFenceSpikeTests (VM, not comparable for timing). Prints FENCE-SPIKE {json} lines.
// Exit 0: the selectors were probed (the window part may report it could not run); 2: no NSApplication.
import AppKit
import CoreMedia
import CoreVideo
import Darwin
import Foundation
import IOSurface
import ObjectiveC
import QuartzCore
import ScreenCaptureKit

nonisolated final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func withLock<R>(_ body: (inout Value) throws -> R) rethrows -> R {
        lock.lock(); defer { lock.unlock() }
        return try body(&value)
    }
}

/// SPIKE (scratch/frame-owner-s4-fence-spike-nomerge, never merged): Core Animation's fence ports, the mechanism of
/// WebKit's resize sync, behind ONE adapter. Every selector is SPI, so each is resolved at run time
/// (`NSClassFromString`, `class_getInstanceMethod`, `class_getClassMethod`); nothing private is linked. When this OS
/// lacks a selector, the initializer returns nil and the caller runs with no fence.
///
/// The model (WebKit `TiledCoreAnimationDrawingAreaProxy::createFence`, `LayerHostingContext::setFencePort`):
/// `-[CAContext createFencePort]` puts a fence in the creating thread's current transaction on that context and returns
/// a send right to it. Every transaction that takes the port (`-[CAContext setFencePort:]`) joins the fence. The render
/// server holds the fenced transactions until every send right to the port is gone, then applies them together.
// crash-allow: immutable after init (a CAContext and three function pointers); CAContext is thread-safe under CA's own lock.
public nonisolated final class CoreAnimationFence: @unchecked Sendable {
    /// A fence port: a Mach send right.
    public typealias Port = mach_port_t

    private typealias CreateFunction = @convention(c) (AnyObject, Selector) -> UInt32
    private typealias SetFunction = @convention(c) (AnyObject, Selector, UInt32) -> Void
    private typealias VoidFunction = @convention(c) (AnyObject, Selector) -> Void

    /// The CAContext (an SPI class: held as an object).
    public let context: NSObject
    private let create: CreateFunction
    private let set: SetFunction
    private let invalidate: VoidFunction?

    /// The fence of the context that draws `layer` (`-[CALayer context]`); nil when this OS lacks a selector or the
    /// layer is not in a context yet.
    public convenience init?(contextOf layer: CALayer) {
        guard let context = Self.object(layer, "context") else { return nil }
        self.init(context: context)
    }

    /// The fence of `context`, a CAContext; nil when it lacks `createFencePort` or `setFencePort:`.
    public init?(context: NSObject) {
        guard let create = Self.instanceFunction(context, "createFencePort", as: CreateFunction.self),
              let set = Self.instanceFunction(context, "setFencePort:", as: SetFunction.self) else { return nil }
        self.context = context
        self.create = create
        self.set = set
        invalidate = Self.instanceFunction(context, "invalidateFences", as: VoidFunction.self)
    }

    /// Puts a fence in this thread's current transaction on the context and returns its port, or nil
    /// (`MACH_PORT_NULL`). The caller owns the send right: ``release(_:)`` it once every joined transaction committed.
    public func createFencePort() -> Port? {
        let port = create(context, CoreAnimationFence.selector("createFencePort"))
        return port == 0 ? nil : port
    }

    /// Joins this thread's current transaction on the context to the fence `port` (call between
    /// `CATransaction.begin()` and `commit()`).
    public func join(_ port: Port) {
        set(context, CoreAnimationFence.selector("setFencePort:"), port)
    }

    /// Lets every fenced transaction on the context go (`-[CAContext invalidateFences]`), when this OS has it.
    /// - Returns: Whether the OS had the selector.
    @discardableResult
    public func invalidateFences() -> Bool {
        guard let invalidate else { return false }
        invalidate(context, CoreAnimationFence.selector("invalidateFences"))
        return true
    }

    /// Gives up one send right to `port` (`mach_port_deallocate`, as WebKit's `MachSendRight` does after its commit).
    public static func release(_ port: Port) {
        mach_port_deallocate(mach_task_self_, port)
    }

    /// Which of the selectors and classes the fence and ``CoreAnimationHostedContext`` use this OS has, by name.
    public static func probe(layer: CALayer?) -> [String: Bool] {
        var found: [String: Bool] = [:]
        let contextClass: AnyClass? = NSClassFromString("CAContext")
        found["class CAContext"] = contextClass != nil
        for name in ["createFencePort", "setFencePort:", "setFencePort:commitHandler:", "invalidateFences", "contextId",
                     "setLayer:", "layer", "invalidate"] {
            found["-[CAContext \(name)]"] = contextClass.map { class_getInstanceMethod($0, CoreAnimationFence.selector(name)) != nil } ?? false
        }
        for name in ["remoteContextWithOptions:", "contextWithCGSConnection:options:", "localContext", "allContexts",
                     "currentContext"] {
            found["+[CAContext \(name)]"] = contextClass.map { class_getClassMethod($0, CoreAnimationFence.selector(name)) != nil } ?? false
        }
        for name in ["setFencePort:", "addCommitHandler:forPhase:", "activate", "synchronize"] {
            found["+[CATransaction \(name)]"] = class_getClassMethod(CATransaction.self, CoreAnimationFence.selector(name)) != nil
        }
        found["-[CALayer context]"] = class_getInstanceMethod(CALayer.self, CoreAnimationFence.selector("context")) != nil
        let host: AnyClass? = NSClassFromString("CALayerHost")
        found["class CALayerHost"] = host != nil
        found["-[CALayerHost setContextId:]"] = host.map { class_getInstanceMethod($0, CoreAnimationFence.selector("setContextId:")) != nil } ?? false
        found["symbol CGSMainConnectionID"] = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGSMainConnectionID") != nil
        if let window: AnyClass = NSClassFromString("NSWindow") {
            found["-[NSWindow _layerContext]"] = class_getInstanceMethod(window, CoreAnimationFence.selector("_layerContext")) != nil
        }
        if let layer {
            found["layer.context non-nil"] = object(layer, "context") != nil
        }
        return found
    }

    /// The selector named `name`, from the compile-time table of ``CoreAnimationSPI`` (no string lookup). Every caller
    /// checks it with `class_getInstanceMethod`, `class_getClassMethod` or `responds(to:)` before it calls it, so a
    /// selector this OS lacks is never sent.
    static func selector(_ name: String) -> Selector {
        selectors[name] ?? #selector(NSObject.description)
    }

    private static let selectors: [String: Selector] = {
        let list: [Selector] = [
            #selector(CoreAnimationSPI.createFencePort), #selector(CoreAnimationSPI.setFencePort(_:)),
            #selector(CoreAnimationSPI.setFencePort(_:commitHandler:)), #selector(CoreAnimationSPI.invalidateFences),
            #selector(CoreAnimationSPI.contextId), #selector(CoreAnimationSPI.setLayer(_:)), #selector(CoreAnimationSPI.layer),
            #selector(CoreAnimationSPI.invalidate), #selector(CoreAnimationSPI.remoteContextWithOptions(_:)),
            #selector(CoreAnimationSPI.contextWithCGSConnection(_:options:)), #selector(CoreAnimationSPI.localContext),
            #selector(CoreAnimationSPI.allContexts), #selector(CoreAnimationSPI.currentContext),
            #selector(CoreAnimationSPI.addCommitHandler(_:forPhase:)), #selector(CoreAnimationSPI.activate),
            #selector(CoreAnimationSPI.synchronize), #selector(CoreAnimationSPI.context),
            #selector(CoreAnimationSPI.setContextId(_:)), #selector(CoreAnimationSPI._layerContext),
        ]
        return Dictionary(list.map { (NSStringFromSelector($0), $0) }, uniquingKeysWith: { first, _ in first })
    }()

    static func object(_ target: NSObject, _ name: String) -> NSObject? {
        let selector = CoreAnimationFence.selector(name)
        guard target.responds(to: selector) else { return nil }
        return target.perform(selector)?.takeUnretainedValue() as? NSObject
    }

    static func instanceFunction<F>(_ target: NSObject, _ name: String, as _: F.Type) -> F? {
        let selector = CoreAnimationFence.selector(name)
        guard let method = class_getInstanceMethod(type(of: target), selector) else { return nil }
        return unsafeBitCast(method_getImplementation(method), to: F.self)
    }
}

/// SPIKE: a layer tree in its own CAContext, shown in a window's tree through a `CALayerHost`, as WebKit's and
/// Chromium's remote layers are, in one process. A fence made from ``fence`` holds only this context's commits.
/// nil when this OS lacks a selector or class.
// crash-allow: immutable after init; the layers and the CAContext are only read, and CA locks its own state.
public nonisolated final class CoreAnimationHostedContext: @unchecked Sendable {
    /// The layer to add to the window's tree: it shows the context's root layer.
    public let hostLayer: CALayer
    /// The fence of the hosted context.
    public let fence: CoreAnimationFence
    /// The hosted CAContext (retained for as long as it is shown).
    public let context: NSObject

    private typealias ContextIdFunction = @convention(c) (AnyObject, Selector) -> UInt32
    private typealias SetContextIdFunction = @convention(c) (AnyObject, Selector, UInt32) -> Void
    private typealias RemoteFunction = @convention(c) (AnyObject, Selector, NSDictionary) -> Unmanaged<NSObject>?
    private typealias CGSFunction = @convention(c) (AnyObject, Selector, UInt32, NSDictionary) -> Unmanaged<NSObject>?
    private typealias MainConnection = @convention(c) () -> UInt32

    /// Puts `root` in a new remote CAContext of this process and makes a host layer for it.
    public init?(root: CALayer) {
        guard let contextClass = NSClassFromString("CAContext"), let hostClass = NSClassFromString("CALayerHost") as? CALayer.Type
        else { return nil }
        var made: NSObject?
        let remote = CoreAnimationFence.selector("remoteContextWithOptions:")
        if let method = class_getClassMethod(contextClass, remote) {
            let function = unsafeBitCast(method_getImplementation(method), to: RemoteFunction.self)
            made = function(contextClass as AnyObject, remote, NSDictionary())?.takeUnretainedValue()
        }
        let cgs = CoreAnimationFence.selector("contextWithCGSConnection:options:")
        if made == nil, let method = class_getClassMethod(contextClass, cgs),
           let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGSMainConnectionID") {
            let connection = unsafeBitCast(symbol, to: MainConnection.self)()
            let function = unsafeBitCast(method_getImplementation(method), to: CGSFunction.self)
            made = function(contextClass as AnyObject, cgs, connection, NSDictionary())?.takeUnretainedValue()
        }
        guard let context = made,
              let fence = CoreAnimationFence(context: context),
              let contextId = CoreAnimationFence.instanceFunction(context, "contextId", as: ContextIdFunction.self)
        else { return nil }
        let setLayer = CoreAnimationFence.selector("setLayer:")
        guard context.responds(to: setLayer) else { return nil }
        context.perform(setLayer, with: root)
        let host = hostClass.init()
        let setContextId = CoreAnimationFence.selector("setContextId:")
        guard let setId = CoreAnimationFence.instanceFunction(host, "setContextId:", as: SetContextIdFunction.self) else { return nil }
        setId(host, setContextId, contextId(context, CoreAnimationFence.selector("contextId")))
        self.context = context
        self.fence = fence
        hostLayer = host
    }
}

/// The SPI selectors, declared once so `#selector` names them at compile time. Nothing conforms: it is only a table of
/// names (class methods are declared as instance methods: a selector is only a name); every call checks the receiver
/// has the method first (``CoreAnimationFence``).
@objc private protocol CoreAnimationSPI {
    func createFencePort() -> UInt32
    func setFencePort(_ port: UInt32)
    func setFencePort(_ port: UInt32, commitHandler: Any)
    func invalidateFences()
    func contextId() -> UInt32
    func setLayer(_ layer: CALayer?)
    func layer() -> CALayer?
    func invalidate()
    func remoteContextWithOptions(_ options: NSDictionary?) -> NSObject?
    func contextWithCGSConnection(_ connection: UInt32, options: NSDictionary?) -> NSObject?
    func localContext() -> NSObject?
    func allContexts() -> NSArray?
    func currentContext() -> NSObject?
    func addCommitHandler(_ handler: Any, forPhase phase: Int)
    func activate()
    func synchronize()
    func context() -> NSObject?
    func setContextId(_ contextId: UInt32)
    func _layerContext() -> NSObject?
}

// MARK: - The spike (CoreAnimationFenceSpikeTests)

@MainActor
struct Runner {
    func probe() throws {
        let scene = try Scene(ownContext: false)
        defer { scene.close() }
        var line = CoreAnimationFence.probe(layer: scene.content).reduce(into: [String: Any]()) { $0[$1.key] = $1.value }
        line["case"] = "probe"
        line["window_fence"] = scene.fence != nil
        line["own_context_fence"] = (try? Scene(ownContext: true)).map { other in
            defer { other.close() }
            return other.fence != nil
        } ?? false
        Self.report(line)
    }

    /// The main question: bad frames with and without the fence, the off-main commit at once, after half a refresh
    /// and after three refreshes; the unjoined layer's change (a typed key in a later main commit) and its delay.
    func windowContextFence() async throws {
        try await runCases(ownContext: false, iterations: 50)
    }

    /// The Lead's fix (a): the joined box in its own CAContext (a CALayerHost in the window's tree), the fence made
    /// from that context; the unjoined layer stays in the window's context.
    func ownContextFence() async throws {
        try await runCases(ownContext: true, iterations: 30)
    }

    /// The deadline: the off-main side never commits. The main side releases the port after one refresh, invalidates
    /// the fences after one refresh, or holds the port 2 s (does the system time the fence out?).
    func deadline() async throws {
        let scene = try Scene(ownContext: false)
        defer { scene.close() }
        let recorder = try await scene.startRecording()
        defer { recorder.stop() }
        let gaps = MainGapMeter()
        gaps.start()
        defer { gaps.stop() }
        for (name, iterations) in [("deadline_release_1_refresh", 10), ("deadline_invalidate_1_refresh", 10), ("deadline_hold_2s", 3)] {
            var visibleAfterCommit: [Double] = [], visibleAfterRelease: [Double] = [], unjoined: [Double] = []
            var commitMs: [Double] = []
            gaps.reset()
            for _ in 0..<iterations {
                await scene.reset()
                guard let fence = scene.fence else { break }
                let t0 = Ticks.now
                CATransaction.flush()
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                let port = fence.createFencePort()
                scene.box.bounds = Scene.newBounds
                scene.box.backgroundColor = Scene.red
                CATransaction.commit()
                commitMs.append(Ticks.ms(t0, Ticks.now))
                let released = Box<UInt64>(0)
                let wait = name == "deadline_hold_2s" ? 2.0 : scene.refresh
                DispatchQueue.main.asyncAfter(deadline: .now() + wait) {
                    if name == "deadline_invalidate_1_refresh" { fence.invalidateFences() } else if let port { CoreAnimationFence.release(port) }
                    released.value = Ticks.now
                }
                try await Task.sleep(for: .milliseconds(2))
                let tu = scene.typeUnjoined()
                try await Task.sleep(for: .milliseconds(Int(wait * 1000) + 250))
                if name == "deadline_invalidate_1_refresh", let port { CoreAnimationFence.release(port) }
                let frames = recorder.frames(after: t0)
                if let shown = frames.first(where: { $0.outside != .white }) {
                    visibleAfterCommit.append(Ticks.ms(t0, shown.time))
                    visibleAfterRelease.append(Ticks.ms(released.value, shown.time))
                }
                if let typed = frames.first(where: { $0.unjoined == .yellow }) { unjoined.append(Ticks.ms(tu, typed.time)) }
            }
            Self.report([
                "case": name, "iterations": iterations, "fence": scene.fence != nil, "refresh_ms": scene.refresh * 1000,
                "new_bounds_visible_after_commit_ms": Stats(visibleAfterCommit).json,
                "new_bounds_visible_after_release_ms": Stats(visibleAfterRelease).json,
                "unjoined_delay_ms": Stats(unjoined).json,
                "unjoined_delay_refreshes": Stats(unjoined.map { $0 / (scene.refresh * 1000) }).json,
                "main_commit_ms": Stats(commitMs).json, "max_main_gap_ms": gaps.maxGapMs,
                "capture": recorder.error ?? "screencapturekit",
            ])
        }
    }

    // MARK: - The cases

    private func runCases(ownContext: Bool, iterations: Int) async throws {
        let scene = try Scene(ownContext: ownContext)
        defer { scene.close() }
        guard scene.fence != nil else { throw SpikeError("no fence on this OS (ownContext \(ownContext)): see the probe line") }
        let recorder = try await scene.startRecording()
        defer { recorder.stop() }
        await scene.reset()
        let calibration = recorder.frames(after: 0).last
        let calibrated = calibration.map { $0.inside == .green && $0.outside == .white && $0.unjoined == .black } ?? false
        if !calibrated {
            Self.report(["case": ownContext ? "own_context_calibration" : "window_calibration", "ok": false,
                         "last_frame": calibration.map { "\($0.inside)/\($0.outside)/\($0.unjoined)" } ?? "none",
                         "capture": recorder.error ?? "screencapturekit"])
        }
        guard calibrated else { throw SpikeError("the first state did not reach the screen as expected") }
        let gaps = MainGapMeter()
        gaps.start()
        defer { gaps.stop() }
        let half = scene.refresh / 2
        for delay in [0, half, scene.refresh * 3] {
            for fenced in [false, true] {
                gaps.reset()
                var result = CaseResult()
                for _ in 0..<iterations {
                    await scene.reset()
                    result.add(try await scene.iteration(fenced: fenced, delay: delay, recorder: recorder))
                }
                var line = result.json(refresh: scene.refresh)
                line["case"] = "\(ownContext ? "own_context" : "window_context")_\(fenced ? "fence" : "control")_delay_\(Int((delay * 1000).rounded()))ms"
                line["own_context"] = ownContext
                line["fence"] = fenced
                line["off_main_delay_ms"] = delay * 1000
                line["iterations"] = iterations
                line["refresh_ms"] = scene.refresh * 1000
                line["max_main_gap_ms"] = gaps.maxGapMs
                line["capture"] = recorder.error ?? "screencapturekit"
                Self.report(line)
            }
        }
    }

    static func report(_ fields: [String: Any]) {
        var fields = fields
        fields["os"] = ProcessInfo.processInfo.operatingSystemVersionString
        fields["host"] = ProcessInfo.processInfo.hostName
        let data = (try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])) ?? Data()
        print("FENCE-SPIKE \(String(decoding: data, as: UTF8.self))")
    }
}

// MARK: - Scene

@MainActor
private final class Scene {
    static let oldBounds = CGRect(x: 0, y: 0, width: 160, height: 160)
    static let newBounds = CGRect(x: 0, y: 0, width: 260, height: 260)
    static let size = CGSize(width: 400, height: 400)
    /// Sample points in the window's content (bottom-left origin). With or without a flipped host they hold: the old box
    /// covers x 20...180 and y 20...180 (or 120...280 flipped), the new one 20...280 both ways.
    static let inside = CGPoint(x: 100, y: 150)
    static let outside = CGPoint(x: 230, y: 150)
    static let unjoinedPoint = CGPoint(x: 350, y: 350)
    static let red = CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)

    let window: NSWindow
    let content: CALayer
    let box: CALayer
    let unjoined: CALayer
    let hosted: CoreAnimationHostedContext?
    let fence: CoreAnimationFence?
    let refresh: Double
    let green: IOSurfaceRef
    let blue: IOSurfaceRef

    init(ownContext: Bool) throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(origin: CGPoint(x: 120, y: 120), size: Self.size), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let view = NSView(frame: NSRect(origin: .zero, size: Self.size))
        view.wantsLayer = true
        window.contentView = view
        let content = view.layer ?? CALayer()
        content.backgroundColor = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
        let scale = window.backingScaleFactor
        let green = Self.surface(Self.oldBounds.size, scale: scale, bgra: (0, 255, 0))
        let blue = Self.surface(Self.newBounds.size, scale: scale, bgra: (255, 0, 0))
        let box = CALayer()
        box.anchorPoint = .zero
        box.contentsGravity = .resize
        box.bounds = Self.oldBounds
        box.contents = green
        box.backgroundColor = Self.red
        let unjoined = CALayer()
        unjoined.anchorPoint = .zero
        unjoined.bounds = CGRect(x: 0, y: 0, width: 60, height: 60)
        unjoined.position = CGPoint(x: 320, y: 320)
        unjoined.backgroundColor = CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)
        content.addSublayer(unjoined)
        window.orderFrontRegardless()
        var hosted: CoreAnimationHostedContext?
        let fence: CoreAnimationFence?
        if ownContext {
            box.position = .zero
            hosted = CoreAnimationHostedContext(root: box)
            if let host = hosted?.hostLayer {
                host.anchorPoint = .zero
                host.frame = CGRect(x: 20, y: 20, width: 260, height: 260)
                content.addSublayer(host)
            }
            fence = hosted?.fence
        } else {
            box.position = CGPoint(x: 20, y: 20)
            content.addSublayer(box)
            CATransaction.flush()
            fence = CoreAnimationFence(contextOf: content)
        }
        CATransaction.flush()
        let fps = window.screen?.maximumFramesPerSecond ?? 60
        self.window = window
        self.content = content
        self.box = box
        self.unjoined = unjoined
        self.hosted = hosted
        self.fence = fence
        self.green = green
        self.blue = blue
        refresh = 1 / Double(fps > 0 ? fps : 60)
    }

    func close() {
        window.close()
    }

    func startRecording() async throws -> FrameRecorder {
        let points = [Self.inside, Self.outside, Self.unjoinedPoint].map { CGPoint(x: $0.x, y: Self.size.height - $0.y) }
        let recorder = FrameRecorder(points: points, size: Self.size)
        try await recorder.start(windowID: CGWindowID(window.windowNumber))
        return recorder
    }

    /// The old state, committed, then 120 ms for it to reach the screen.
    func reset() async {
        CATransaction.flush()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        box.bounds = Self.oldBounds
        box.contents = green
        unjoined.backgroundColor = CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)
        CATransaction.commit()
        try? await Task.sleep(for: .milliseconds(120))
    }

    /// The unjoined layer's change in its own main commit (a typed key); returns when it committed.
    func typeUnjoined() -> UInt64 {
        CATransaction.flush()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        unjoined.backgroundColor = CGColor(srgbRed: 1, green: 1, blue: 0, alpha: 1)
        CATransaction.commit()
        return Ticks.now
    }

    /// Main: the new bounds (and red) with the fence; off main (a plain thread) after `delay`: blue at the new size,
    /// joined to the fence, then the port released. 2 ms after the main commit, the unjoined change.
    func iteration(fenced: Bool, delay: Double, recorder: FrameRecorder) async throws -> Iteration {
        let t0 = Ticks.now
        CATransaction.flush()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let port = fenced ? fence?.createFencePort() : nil
        box.bounds = Self.newBounds
        box.backgroundColor = Self.red
        CATransaction.commit()
        let mainCommitMs = Ticks.ms(t0, Ticks.now)
        let released = Box<UInt64>(0)
        let offMain = Box<(box: CALayer, blue: IOSurfaceRef, fence: CoreAnimationFence?)>((box, blue, fence))
        let thread = Thread {
            if delay > 0 { usleep(UInt32(delay * 1_000_000)) }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            if let port { offMain.value.fence?.join(port) }
            offMain.value.box.contents = offMain.value.blue
            CATransaction.commit()
            if let port { CoreAnimationFence.release(port) }
            released.value = Ticks.now
        }
        thread.qos = .userInteractive
        thread.start()
        try await Task.sleep(for: .milliseconds(2))
        let typedAt = typeUnjoined()
        try await Task.sleep(for: .milliseconds(Int(delay * 1000) + 250))
        return Iteration(frames: recorder.frames(after: t0), t0: t0, typedAt: typedAt, releasedAt: released.value,
                         mainCommitMs: mainCommitMs, fenced: port != nil)
    }

    static func surface(_ size: CGSize, scale: CGFloat, bgra: (UInt8, UInt8, UInt8)) -> IOSurfaceRef {
        let width = Int(size.width * scale), height = Int(size.height * scale)
        let properties: [CFString: Any] = [kIOSurfaceWidth: width, kIOSurfaceHeight: height, kIOSurfaceBytesPerElement: 4,
                                           kIOSurfacePixelFormat: kCVPixelFormatType_32BGRA]
        let surface = IOSurfaceCreate(properties as CFDictionary)!
        IOSurfaceLock(surface, [], nil)
        let base = IOSurfaceGetBaseAddress(surface).assumingMemoryBound(to: UInt8.self)
        let row = IOSurfaceGetBytesPerRow(surface)
        for y in 0..<height {
            for x in 0..<width {
                let pixel = base + y * row + x * 4
                pixel[0] = bgra.0; pixel[1] = bgra.1; pixel[2] = bgra.2; pixel[3] = 255
            }
        }
        IOSurfaceUnlock(surface, [], nil)
        return surface
    }
}

// MARK: - Analysis

private nonisolated struct Iteration {
    let frames: [Frame]
    let t0: UInt64
    let typedAt: UInt64
    let releasedAt: UInt64
    let mainCommitMs: Double
    let fenced: Bool
}

private nonisolated struct CaseResult {
    var frames = 0
    var badFrames = 0
    var badIterations = 0
    var badKinds: [String: Int] = [:]
    var firstNewMs: [Double] = []
    var unjoinedMs: [Double] = []
    var unjoinedHeld = 0
    var unjoinedHeldMs: [Double] = []
    var mainCommitMs: [Double] = []
    var noNewFrame = 0

    mutating func add(_ it: Iteration) {
        mainCommitMs.append(it.mainCommitMs)
        var bad = 0
        for frame in it.frames {
            frames += 1
            switch (frame.inside, frame.outside) {
            case (.green, .white), (.blue, .blue): continue
            case (_, .green): badKinds["new_bounds_old_contents_stretched", default: 0] += 1
            case (_, .red): badKinds["new_bounds_no_contents", default: 0] += 1
            case (.blue, .white): badKinds["new_contents_old_bounds", default: 0] += 1
            default: badKinds["other_\(frame.inside)_\(frame.outside)", default: 0] += 1
            }
            bad += 1
        }
        badFrames += bad
        if bad > 0 { badIterations += 1 }
        let firstNew = it.frames.first { $0.inside == .blue && $0.outside == .blue }
        if let firstNew { firstNewMs.append(Ticks.ms(it.t0, firstNew.time)) } else { noNewFrame += 1 }
        if let typed = it.frames.first(where: { $0.unjoined == .yellow }) {
            let delay = Ticks.ms(it.typedAt, typed.time)
            unjoinedMs.append(delay)
            // Held: it showed only with or after the fenced frame, though the port went more than a refresh after it.
            if it.fenced, let firstNew, typed.time >= firstNew.time, it.releasedAt > it.typedAt {
                unjoinedHeld += 1
                unjoinedHeldMs.append(delay)
            }
        }
    }

    func json(refresh: Double) -> [String: Any] {
        [
            "frames": frames, "bad_frames": badFrames, "bad_iterations": badIterations, "bad_kinds": badKinds,
            "first_new_frame_after_main_commit_ms": Stats(firstNewMs).json, "iterations_without_new_frame": noNewFrame,
            "unjoined_delay_ms": Stats(unjoinedMs).json,
            "unjoined_delay_refreshes": Stats(unjoinedMs.map { $0 / (refresh * 1000) }).json,
            "unjoined_held": unjoinedHeld, "unjoined_held_delay_ms": Stats(unjoinedHeldMs).json,
            "main_commit_ms": Stats(mainCommitMs).json,
        ]
    }
}

private nonisolated struct Stats {
    let values: [Double]
    init(_ values: [Double]) { self.values = values.sorted() }
    var json: [String: Any] {
        guard !values.isEmpty else { return ["n": 0] }
        func at(_ q: Double) -> Double { (values[min(values.count - 1, Int(Double(values.count - 1) * q))] * 100).rounded() / 100 }
        return ["n": values.count, "min": at(0), "p50": at(0.5), "p95": at(0.95), "max": at(1)]
    }
}

private nonisolated final class Box<Value>: @unchecked Sendable {
    // concurrency-allow: spike; one writer thread, read by main after a 250 ms sleep that follows the write.
    var value: Value
    init(_ value: Value) { self.value = value }
}

private nonisolated enum Ticks {
    static let ticksPerMs: Double = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return 1e6 * Double(info.denom) / Double(info.numer)
    }()
    static var now: UInt64 { mach_absolute_time() }
    static func ms(_ from: UInt64, _ to: UInt64) -> Double { (Double(to) - Double(from)) / ticksPerMs }
}

/// Main-queue ticks every millisecond; the largest gap between two is how long the main thread was away.
@MainActor
private final class MainGapMeter {
    private var timer: (any DispatchSourceTimer)?
    private var last: UInt64 = 0
    private(set) var maxGap: UInt64 = 0
    var maxGapMs: Double { (Double(maxGap) / Ticks.ticksPerMs * 100).rounded() / 100 }

    func start() {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: .milliseconds(1), leeway: .nanoseconds(0))
        timer.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                let now = Ticks.now
                if self.last != 0 { self.maxGap = max(self.maxGap, now - self.last) }
                self.last = now
            }
        }
        timer.resume()
        self.timer = timer
    }

    func reset() {
        last = 0
        maxGap = 0
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }
}

// MARK: - Capture

private nonisolated enum Color: String, CustomStringConvertible {
    case white, red, green, blue, yellow, black
    var description: String { rawValue }

    static func nearest(r: Double, g: Double, b: Double) -> Color {
        let palette: [(Color, Double, Double, Double)] = [(.white, 255, 255, 255), (.red, 255, 0, 0), (.green, 0, 255, 0),
                                                         (.blue, 0, 0, 255), (.yellow, 255, 255, 0), (.black, 0, 0, 0)]
        return palette.min { lhs, rhs in
            func d(_ c: (Color, Double, Double, Double)) -> Double { pow(c.1 - r, 2) + pow(c.2 - g, 2) + pow(c.3 - b, 2) }
            return d(lhs) < d(rhs)
        }!.0
    }
}

private nonisolated struct Frame {
    let time: UInt64
    let inside: Color
    let outside: Color
    let unjoined: Color
}

/// A ScreenCaptureKit stream of the window alone; each complete frame sampled at three points on its own queue.
private nonisolated final class FrameRecorder: NSObject, SCStreamOutput, @unchecked Sendable {
    private let points: [CGPoint]
    private let size: CGSize
    private let queue = DispatchQueue(label: "fence-spike.capture", qos: .userInteractive)
    // concurrency-allow: spike; appended on the capture queue, copied out on main.
    private let collected = Locked<[Frame]>([])
    private var stream: SCStream?
    private(set) var error: String?

    init(points: [CGPoint], size: CGSize) {
        self.points = points
        self.size = size
    }

    func start(windowID: CGWindowID) async throws {
        guard #available(macOS 14.4, *) else { throw SpikeError("ScreenCaptureKit current-process content needs macOS 14.4") }
        var target: SCWindow?
        for _ in 0..<20 {
            let content = try await SCShareableContent.currentProcess
            target = content.windows.first { $0.windowID == windowID }
            if target != nil { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        guard let target else { throw SpikeError("ScreenCaptureKit lists no window \(windowID)") }
        let configuration = SCStreamConfiguration()
        configuration.width = Int(size.width)
        configuration.height = Int(size.height)
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 240)
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.colorSpaceName = CGColorSpace.sRGB
        configuration.showsCursor = false
        configuration.queueDepth = 8
        let stream = SCStream(filter: SCContentFilter(desktopIndependentWindow: target), configuration: configuration, delegate: nil)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await stream.startCapture()
        self.stream = stream
        try await Task.sleep(for: .milliseconds(300))
    }

    func stop() {
        let stream = self.stream
        Task { try? await stream?.stopCapture() }
    }

    func frames(after time: UInt64) -> [Frame] {
        collected.withLock { frames in
            frames.filter { $0.time > time }
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let info = attachments.first,
              let statusRaw = info[.status] as? Int, SCFrameStatus(rawValue: statusRaw) == .complete,
              let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let time = (info[.displayTime] as? NSNumber)?.uint64Value ?? Ticks.now
        CVPixelBufferLockBaseAddress(pixels, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixels)?.assumingMemoryBound(to: UInt8.self) else { return }
        let width = CVPixelBufferGetWidth(pixels), height = CVPixelBufferGetHeight(pixels)
        let row = CVPixelBufferGetBytesPerRow(pixels)
        let colors = points.map { point -> Color in
            let x = min(width - 1, Int(point.x * Double(width) / size.width))
            let y = min(height - 1, Int(point.y * Double(height) / size.height))
            let p = base + y * row + x * 4
            return Color.nearest(r: Double(p[2]), g: Double(p[1]), b: Double(p[0]))
        }
        collected.withLock { $0.append(Frame(time: time, inside: colors[0], outside: colors[1], unjoined: colors[2])) }
    }
}

private nonisolated struct SpikeError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}


@MainActor func runAll() async {
    let runner = Runner()
    do { try runner.probe() } catch { Runner.report(["case": "probe", "error": "\(error)"]) }
    for (name, body) in [("window_context", { try await runner.windowContextFence() }),
                         ("own_context", { try await runner.ownContextFence() }),
                         ("deadline", { try await runner.deadline() })] as [(String, @MainActor () async throws -> Void)] {
        do { try await body() } catch { Runner.report(["case": name, "error": "\(error)"]) }
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
Task { @MainActor in
    await runAll()
    exit(0)
}
app.run()
