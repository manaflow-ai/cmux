// VB spike HOST. Throwaway demo binary (localization-exempt).
//
// Fetches the service child's anonymous endpoint from the broker, then asks
// ViewBridge to marshal a remote view controller across it via the private
//   +[NSRemoteViewController requestViewController:fromServiceListenerEndpoint:connectionHandler:]
// and embeds the returned NSRemoteView in a window. Then it programmatically
// delivers NSEvents into its own window to exercise click/typing/hover.

import AppKit
import ObjectiveC.runtime

final class HostController: NSObject {
    let window: NSWindow
    var remoteVC: NSViewController?

    override init() {
        window = NSWindow(
            contentRect: NSRect(x: 200, y: 200, width: 320, height: 420),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered, defer: false)
        window.title = "VB spike host"
        super.init()
        window.makeKeyAndOrderFront(nil)
        // Global watchdog: terminate after a bounded deadline no matter what, so a
        // failure to obtain the endpoint never leaves the host hanging.
        // Throwaway test scaffolding; deterministic shutdown.
        let watchdog = Timer(timeInterval: 9.0, repeats: false) { _ in
            SpikeLog.err("HOST", "watchdog auto-exit")
            NSApp.terminate(nil)
        }
        RunLoop.main.add(watchdog, forMode: .common)
    }

    func fetchEndpointAndRequest() {
        let conn = NSXPCConnection(machServiceName: kBrokerMachName, options: [])
        conn.remoteObjectInterface = NSXPCInterface(with: VBBrokerProtocol.self)
        conn.resume()
        guard let proxy = conn.remoteObjectProxyWithErrorHandler({ err in
            SpikeLog.err("HOST", "broker connect error \(err)")
        }) as? VBBrokerProtocol else {
            SpikeLog.err("HOST", "broker proxy nil"); return
        }
        proxy.getServiceEndpoint { [weak self] ep in
            guard let self = self else { return }
            guard let ep = ep else {
                self.endpointRetries += 1
                if self.endpointRetries <= 12 {
                    SpikeLog.err("HOST", "no endpoint yet (retry \(self.endpointRetries))")
                    // Bounded retry; throwaway scaffolding, deterministic shutdown via watchdog.
                    DispatchQueue.main.async {
                        let t = Timer(timeInterval: 0.4, repeats: false) { _ in self.fetchEndpointAndRequest() }
                        RunLoop.main.add(t, forMode: .common)
                    }
                } else {
                    SpikeLog.err("HOST", "no endpoint from broker after retries")
                }
                return
            }
            DispatchQueue.main.async { self.requestViewController(ep) }
        }
    }

    private var endpointRetries = 0

    private func requestViewController(_ endpoint: NSXPCListenerEndpoint) {
        guard let cls = NSClassFromString("NSRemoteViewController") else {
            SpikeLog.err("HOST", "NSRemoteViewController missing"); return
        }
        let sel = NSSelectorFromString("requestViewController:fromServiceListenerEndpoint:connectionHandler:")
        guard let m = class_getClassMethod(cls, sel) else {
            SpikeLog.err("HOST", "selector missing: \(sel)"); return
        }
        typealias Fn = @convention(c) (
            AnyObject, Selector, NSString, NSXPCListenerEndpoint,
            @convention(block) (AnyObject?, NSError?) -> Void) -> Void
        let imp = method_getImplementation(m)
        let fn = unsafeBitCast(imp, to: Fn.self)
        let handler: @convention(block) (AnyObject?, NSError?) -> Void = { [weak self] vc, err in
            if let err = err {
                SpikeLog.err("HOST", "requestViewController error: \(err)")
                return
            }
            guard let vc = vc as? NSViewController else {
                SpikeLog.err("HOST", "handler vc not an NSViewController: \(String(describing: vc))")
                return
            }
            SpikeLog.err("HOST", "got remote VC \(vc); view = \(String(describing: vc.view))")
            DispatchQueue.main.async { self?.embed(vc) }
        }
        SpikeLog.err("HOST", "calling requestViewController:fromServiceListenerEndpoint: with VBServiceVC")
        fn(cls, sel, "VBServiceVC" as NSString, endpoint, handler)
    }

    private func embed(_ vc: NSViewController) {
        remoteVC = vc
        let remoteView = vc.view
        remoteView.frame = window.contentView!.bounds
        remoteView.autoresizingMask = [.width, .height]
        window.contentView?.addSubview(remoteView)
        SpikeLog.err("HOST", "embedded remote view; valid=\(remoteView.responds(to: NSSelectorFromString("isValid")) ? String(describing: remoteView.value(forKey: "isValid")) : "n/a") frame=\(remoteView.frame)")
        window.makeKey()
        verify(remoteView)
    }

    private func snapshot(_ view: NSView, _ name: String) {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            SpikeLog.err("HOST", "snapshot \(name): no rep"); return
        }
        view.cacheDisplay(in: view.bounds, to: rep)
        // count non-transparent / non-uniform pixels as a crude content signal
        var distinct = Set<UInt32>()
        if let data = rep.bitmapData {
            let n = rep.bytesPerRow * rep.pixelsHigh
            var i = 0
            while i < n - 4 {
                let px = UInt32(data[i]) << 24 | UInt32(data[i+1]) << 16 | UInt32(data[i+2]) << 8 | UInt32(data[i+3])
                distinct.insert(px); i += 64
            }
        }
        if let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: "/tmp/vbridge-\(name).png"))
        }
        SpikeLog.err("HOST", "snapshot \(name): \(rep.pixelsWide)x\(rep.pixelsHigh), distinctColors~=\(distinct.count) (saved /tmp/vbridge-\(name).png)")
    }

    private func post(_ event: NSEvent?) {
        guard let event = event else { return }
        window.sendEvent(event)
    }

    private func verify(_ remoteView: NSView) {
        // t+1s: first snapshot (should show rendered SwiftUI if marshal works)
        runAfter(1.0) { self.snapshot(remoteView, "before") }
        // t+2s: hover near the counter, then click the Increment button area
        runAfter(2.0) {
            let p = NSPoint(x: 160, y: 250)
            self.post(NSEvent.mouseEvent(with: .mouseMoved, location: p, modifierFlags: [], timestamp: 0,
                windowNumber: self.window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0))
        }
        runAfter(3.0) {
            let btn = NSPoint(x: 160, y: 230)
            self.post(NSEvent.mouseEvent(with: .leftMouseDown, location: btn, modifierFlags: [], timestamp: 0,
                windowNumber: self.window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
            self.post(NSEvent.mouseEvent(with: .leftMouseUp, location: btn, modifierFlags: [], timestamp: 0,
                windowNumber: self.window.windowNumber, context: nil, eventNumber: 2, clickCount: 1, pressure: 0))
        }
        // t+4s: focus the text field and type
        runAfter(4.0) {
            let tf = NSPoint(x: 160, y: 150)
            self.post(NSEvent.mouseEvent(with: .leftMouseDown, location: tf, modifierFlags: [], timestamp: 0,
                windowNumber: self.window.windowNumber, context: nil, eventNumber: 3, clickCount: 1, pressure: 1))
            self.post(NSEvent.mouseEvent(with: .leftMouseUp, location: tf, modifierFlags: [], timestamp: 0,
                windowNumber: self.window.windowNumber, context: nil, eventNumber: 4, clickCount: 1, pressure: 0))
            for ch in "hi" {
                let s = String(ch)
                self.post(NSEvent.keyEvent(with: .keyDown, location: tf, modifierFlags: [], timestamp: 0,
                    windowNumber: self.window.windowNumber, context: nil, characters: s,
                    charactersIgnoringModifiers: s, isARepeat: false, keyCode: 4))
                self.post(NSEvent.keyEvent(with: .keyUp, location: tf, modifierFlags: [], timestamp: 0,
                    windowNumber: self.window.windowNumber, context: nil, characters: s,
                    charactersIgnoringModifiers: s, isARepeat: false, keyCode: 4))
            }
        }
        // t+5s: second snapshot (counter/textfield should have changed if input bridged)
        runAfter(5.0) { self.snapshot(remoteView, "after") }
        // t+7s: bounded auto-exit (throwaway scaffolding; deterministic shutdown)
        runAfter(7.0) {
            SpikeLog.err("HOST", "auto-exit")
            NSApp.terminate(nil)
        }
    }

    private func runAfter(_ s: Double, _ block: @escaping () -> Void) {
        let t = Timer(timeInterval: s, repeats: false) { _ in block() }
        RunLoop.main.add(t, forMode: .common)
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let host = HostController()
app.activate(ignoringOtherApps: true)
DispatchQueue.main.async { host.fetchEndpointAndRequest() }
app.run()
