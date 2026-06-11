// VB spike SERVICE child. Throwaway demo binary (localization-exempt).
//
// Attempts to stand up the ViewBridge *service* side from an ordinary CLI process:
//   1. bring up AppKit (NSViewServiceApplication as NSApp if possible),
//   2. bootstrap the private shared service listener,
//   3. attach our own NSXPCListener.anonymous() so the ViewBridge service protocol
//      is vended over an endpoint we own (no launchd check-in needed for that port),
//   4. register a runtime NSServiceViewController subclass "VBServiceVC" whose view
//      is SwiftUI (TextField + Button(@State counter) + .onHover color),
//   5. hand our anonymous endpoint to the broker for the host to pick up,
//   6. run the AppKit/XPC runloop.
//
// Every load-bearing private call is logged so a failure pins the exact layer.

import AppKit
import SwiftUI
import ObjectiveC.runtime

// MARK: - SwiftUI content shown by the service VC

struct ServiceContent: View {
    @State private var count = 0
    @State private var text = ""
    @State private var hovering = false
    var body: some View {
        VStack(spacing: 16) {
            Text("ViewBridge spike service")
                .font(.headline)
            Text("count: \(count)")
                .font(.system(size: 28, weight: .bold))
                .foregroundStyle(hovering ? Color.green : Color.primary)
            Button("Increment") { count += 1 }
                .buttonStyle(.borderedProminent)
            TextField("type here", text: $text)
                .textFieldStyle(.roundedBorder)
            Text("echo: \(text)")
            Spacer()
        }
        .padding()
        .frame(minWidth: 240, minHeight: 320)
        .background(hovering ? Color.yellow.opacity(0.15) : Color.clear)
        .onHover { hovering = $0 }
    }
}

// MARK: - Runtime NSServiceViewController subclass

enum ServiceVCFactory {
    static let className = "VBServiceVC"
    static func register() -> Bool {
        guard let superCls = NSClassFromString("NSServiceViewController") else {
            SpikeLog.err("SERVICE", "NSServiceViewController class missing"); return false
        }
        if NSClassFromString(className) != nil { return true }
        guard let pair = objc_allocateClassPair(superCls, className, 0) else {
            SpikeLog.err("SERVICE", "objc_allocateClassPair failed"); return false
        }
        // Override -loadView to install an NSHostingView with our SwiftUI content.
        let loadView: @convention(block) (AnyObject) -> Void = { obj in
            SpikeLog.err("SERVICE", "VBServiceVC.loadView invoked")
            let host = NSHostingView(rootView: ServiceContent())
            host.frame = NSRect(x: 0, y: 0, width: 280, height: 360)
            (obj as? NSViewController)?.view = host
        }
        let imp = imp_implementationWithBlock(loadView)
        class_addMethod(pair, NSSelectorFromString("loadView"), imp, "v@:")
        objc_registerClassPair(pair)
        SpikeLog.err("SERVICE", "registered \(className)")
        return true
    }
}

// MARK: - Service-side ViewBridge bootstrap

enum ServiceBootstrap {
    // Returns the anonymous endpoint that the host should request against, or nil.
    static func standUp() -> NSXPCListenerEndpoint? {
        // (a) shared service listener
        guard let sharedCls = NSClassFromString("NSXPCSharedListener") as AnyObject? else {
            SpikeLog.err("SERVICE", "NSXPCSharedListener missing"); return nil
        }
        // Escalation probe: ViewBridge accepts a marshal connection only when the
        // process has a validated service *configuration*, which it reads from the
        // service bundle's NSExtension Info dictionary. We must adopt a service
        // bundle (cacheMainBundleAsServiceBundle) BEFORE reading serviceConfiguration,
        // or +serviceConfiguration asserts "unable to obtain service bundle info
        // dictionary". On a plain CLI the main bundle has no Info dict; on the .app
        // shell rung the main bundle carries an NSExtension dict, so this is the
        // real test of whether a hand-built bundle satisfies the config gate.
        if let appCls = NSClassFromString("NSViewServiceApplication") as AnyObject? {
            let cacheSel = NSSelectorFromString("cacheMainBundleAsServiceBundle")
            if appCls.responds(to: cacheSel) {
                _ = appCls.perform(cacheSel)
                SpikeLog.err("SERVICE", "called cacheMainBundleAsServiceBundle; mainBundle=\(Bundle.main.bundlePath); hasNSExtension=\(Bundle.main.object(forInfoDictionaryKey: "NSExtension") != nil)")
            }
            let cfgSel = NSSelectorFromString("serviceConfiguration")
            if appCls.responds(to: cfgSel) {
                let cfg = appCls.perform(cfgSel)?.takeUnretainedValue()
                SpikeLog.err("SERVICE", "serviceConfiguration = \(String(describing: cfg))")
            }
        }
        // bootstrap via NSViewServiceApplication if available (sets up service config)
        if let appCls = NSClassFromString("NSViewServiceApplication") as AnyObject?,
           appCls.responds(to: NSSelectorFromString("bootstrapSharedServiceListener")) {
            _ = appCls.perform(NSSelectorFromString("bootstrapSharedServiceListener"))
            SpikeLog.err("SERVICE", "called NSViewServiceApplication.bootstrapSharedServiceListener")
        }
        guard sharedCls.responds(to: NSSelectorFromString("sharedServiceListener")),
              let shared = sharedCls.perform(NSSelectorFromString("sharedServiceListener"))?.takeUnretainedValue() else {
            SpikeLog.err("SERVICE", "sharedServiceListener nil"); return nil
        }
        SpikeLog.err("SERVICE", "sharedServiceListener = \(shared)")

        // (b) our own anonymous listener whose connections are handled by the
        // shared ViewBridge listener (its delegate vends the service protocol).
        // The canonical name "com.apple.view-bridge" is already owned by the
        // shared listener (registering it throws "cannot replace existing
        // listener named com.apple.view-bridge"), so register under a private
        // name of our own and read the endpoint back via listenerEndpointWithName:.
        let serviceName = "com.cmux.vbridge.service"
        let anon = NSXPCListener.anonymous()
        let addSel = NSSelectorFromString("addListener:withName:")
        if shared.responds(to: addSel) {
            _ = shared.perform(addSel, with: anon, with: serviceName)
            SpikeLog.err("SERVICE", "added anon listener to shared under \(serviceName); anon.delegate=\(String(describing: anon.delegate))")
        } else {
            SpikeLog.err("SERVICE", "shared listener has no addListener:withName:")
        }
        // addListener:withName: takes ownership of the anonymous listener and
        // resumes it through the shared listener's own machinery. Calling
        // anon.resume() ourselves is a double-resume that traps with
        // _xpc_api_misuse, so we must NOT resume or set a delegate by hand.
        var endpoint: NSXPCListenerEndpoint?
        let epSel = NSSelectorFromString("listenerEndpointWithName:")
        if shared.responds(to: epSel),
           let ep = shared.perform(epSel, with: serviceName)?.takeUnretainedValue() as? NSXPCListenerEndpoint {
            endpoint = ep
            SpikeLog.err("SERVICE", "shared.listenerEndpointWithName -> \(ep)")
        }
        if endpoint == nil { endpoint = anon.endpoint }
        SpikeLog.err("SERVICE", "service endpoint = \(String(describing: endpoint))")
        return endpoint
    }
}

// MARK: - main

SpikeLog.err("SERVICE", "pid \(getpid()) starting")

// Try to make NSApp the ViewBridge service application subclass.
if let vsaCls = NSClassFromString("NSViewServiceApplication") as AnyObject?,
   vsaCls.responds(to: NSSelectorFromString("sharedApplication")) {
    _ = vsaCls.perform(NSSelectorFromString("sharedApplication"))
    SpikeLog.err("SERVICE", "NSApp class = \(type(of: NSApplication.shared))")
} else {
    _ = NSApplication.shared
}
NSApp.setActivationPolicy(.accessory)

guard ServiceVCFactory.register() else { exit(3) }
guard let endpoint = ServiceBootstrap.standUp() else {
    SpikeLog.err("SERVICE", "FAILED to stand up service endpoint"); exit(4)
}

// Hand endpoint to broker.
let conn = NSXPCConnection(machServiceName: kBrokerMachName, options: [])
conn.remoteObjectInterface = NSXPCInterface(with: VBBrokerProtocol.self)
conn.resume()
if let proxy = conn.remoteObjectProxyWithErrorHandler({ err in
    SpikeLog.err("SERVICE", "broker connect error \(err)")
}) as? VBBrokerProtocol {
    proxy.setServiceEndpoint(endpoint)
    SpikeLog.err("SERVICE", "sent endpoint to broker")
} else {
    SpikeLog.err("SERVICE", "broker proxy nil")
}

SpikeLog.err("SERVICE", "entering runloop")
NSApp.run()
