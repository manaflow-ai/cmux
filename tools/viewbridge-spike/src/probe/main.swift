// VB spike RUNG-3 probe. Throwaway demo binary (localization-exempt).
//
// Rung 3 of the escalation ladder is "the real service entry point":
// NSViewServiceApplicationMain / NSViewServiceApplication's extension bootstrap.
// Those are what an OS-launched ViewService (appex) runs. This probe calls the
// non-blocking bootstrap entry points and logs their result/error so we can show
// exactly why a self-launched process cannot become a ViewBridge service: it has
// no validated service configuration and no system-brokered host handshake.
//
// We deliberately do NOT call NSViewServiceApplicationMain() itself, because it
// blocks waiting for a launchd-provided check-in endpoint that never arrives for
// a process the OS did not launch as an extension (it would hang). The bootstrap
// selectors it calls internally are probed here instead.

import AppKit
import ObjectiveC.runtime

func log(_ m: String) { FileHandle.standardError.write("PROBE: \(m)\n".data(using: .utf8)!) }

_ = NSApplication.shared

guard let appCls = NSClassFromString("NSViewServiceApplication") as AnyObject? else {
    log("NSViewServiceApplication missing"); exit(1)
}

// NOTE: +[NSViewServiceApplication bootstrapKind] asserts 'unknown bootstrap
// kind' for any process the OS did not launch as an extension/XPC service, so we
// do not call it here (it hard-crashes). That assertion is itself the headline
// result: a self-launched CLI has no ViewBridge bootstrap context. We go straight
// to the bootstrap entry points to capture their errors.

// (1) commonBootstrapForExtensionWithError: the non-EXK extension bootstrap.
let cbSel = NSSelectorFromString("commonBootstrapForExtensionWithError:")
if let m = class_getClassMethod(appCls as? AnyClass, cbSel) {
    typealias Fn = @convention(c) (AnyObject, Selector, UnsafeMutablePointer<NSError?>?) -> Bool
    let fn = unsafeBitCast(method_getImplementation(m), to: Fn.self)
    var err: NSError?
    let ok = fn(appCls, cbSel, &err)
    log("commonBootstrapForExtensionWithError: ok=\(ok) err=\(String(describing: err))")
} else {
    log("commonBootstrapForExtensionWithError: selector unavailable")
}

// (4) bootstrapForExtensionKitWithDelegate:error: the ExtensionKit/EXHost entry.
//     This is the path EXHost drives; it needs a delegate that receives the
//     system-brokered host connection. We pass a do-nothing delegate to capture
//     the error a self-launched process gets (no EXHost handshake present).
final class DummyDelegate: NSObject {}
let ekSel = NSSelectorFromString("bootstrapForExtensionKitWithDelegate:error:")
if let m = class_getClassMethod(appCls as? AnyClass, ekSel) {
    typealias Fn = @convention(c) (AnyObject, Selector, AnyObject, UnsafeMutablePointer<NSError?>?) -> Bool
    let fn = unsafeBitCast(method_getImplementation(m), to: Fn.self)
    var err: NSError?
    let ok = fn(appCls, ekSel, DummyDelegate(), &err)
    log("bootstrapForExtensionKitWithDelegate:error: ok=\(ok) err=\(String(describing: err))")
} else {
    log("bootstrapForExtensionKitWithDelegate:error: selector unavailable")
}

log("probe done")
