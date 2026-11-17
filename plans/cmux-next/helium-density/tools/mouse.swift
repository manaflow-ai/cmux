import CoreGraphics
import ApplicationServices
import Foundation
// usage: mouse X Y  (global points, top-left origin): warp, then post a mouseMoved
let a = CommandLine.arguments
let p = CGPoint(x: Double(a[1])!, y: Double(a[2])!)
CGWarpMouseCursorPosition(p)
CGAssociateMouseAndMouseCursorPosition(1)
if let e = CGEvent(mouseEventSource: CGEventSource(stateID: .hidSystemState), mouseType: .mouseMoved, mouseCursorPosition: p, mouseButton: .left) {
    e.post(tap: .cghidEventTap)
}
print("trusted:", AXIsProcessTrusted())
