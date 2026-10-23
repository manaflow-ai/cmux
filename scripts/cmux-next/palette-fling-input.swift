// Real pointer and wheel input for bench-palette-fling.py (test harness only, no cmux code).
//
// Puts the pointer at a screen point and keeps it still there, then posts one trackpad fling at the
// window server: a continuous gesture (began, changed..., ended) at the display's rate, then the
// momentum phase (begin, continue... with decaying deltas, end), as a real two-finger flick does.
//
//   swiftc -O -o fling scripts/cmux-next/palette-fling-input.swift
//   ./fling --x 800 --y 500 [--appkit-y] --dy -40 [--events 8] [--momentum 90] [--hz 120] [--decay 0.95] [--move-only]
//
// x, y are global display coordinates (top-left origin, points). dy < 0 scrolls the content down
// (toward later rows). Prints one JSON line: whether this process may post events, and what it sent.
import CoreGraphics
import Foundation

var x = 0.0, y = 0.0, dy = -40.0, events = 8, momentum = 90, hz = 120.0, decay = 0.95, moveOnly = false, flip = false
var args = CommandLine.arguments.dropFirst().makeIterator()
while let key = args.next() {
    switch key {
    case "--x": x = Double(args.next() ?? "") ?? x
    case "--y": y = Double(args.next() ?? "") ?? y
    case "--dy": dy = Double(args.next() ?? "") ?? dy
    case "--events": events = Int(args.next() ?? "") ?? events
    case "--momentum": momentum = Int(args.next() ?? "") ?? momentum
    case "--hz": hz = Double(args.next() ?? "") ?? hz
    case "--decay": decay = Double(args.next() ?? "") ?? decay
    case "--move-only": moveOnly = true
    case "--appkit-y": flip = true
    default: break
    }
}

// --appkit-y: y is AppKit screen points (bottom-left origin of the main display), as NSWindow.frame.
if flip { y = CGDisplayBounds(CGMainDisplayID()).height - y }
let point = CGPoint(x: x, y: y)
let allowed = CGPreflightPostEventAccess()
// Moving the pointer needs no grant; the mouse-moved event tells the window the pointer arrived.
CGWarpMouseCursorPosition(point)
CGAssociateMouseAndMouseCursorPosition(1)
if let move = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left) {
    move.post(tap: .cghidEventTap)
}
var sent = 0
let period = 1.0 / hz
func at(_ deadline: Double) {
    // Harness pacing: one event per display refresh, as a trackpad delivers them.
    let wait = deadline - CFAbsoluteTimeGetCurrent()
    if wait > 0 { usleep(useconds_t(wait * 1_000_000)) }
}
func post(delta: Double, phase: Int64, momentumPhase: Int64) {
    guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
                              wheel1: Int32(delta.rounded()), wheel2: 0, wheel3: 0) else { return }
    event.location = point
    event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
    event.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
    event.setIntegerValueField(.scrollWheelEventMomentumPhase, value: momentumPhase)
    event.setDoubleValueField(.scrollWheelEventPointDeltaAxis1, value: delta)
    event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: delta)
    event.post(tap: .cghidEventTap)
    sent += 1
}
let start = CFAbsoluteTimeGetCurrent() + 0.15
if !moveOnly {
    // kCGScrollPhaseBegan 1, Changed 2, Ended 4; kCGMomentumScrollPhaseBegin 1, Continue 2, End 3.
    var tick = 0
    for index in 0..<max(2, events) {
        at(start + Double(tick) * period); tick += 1
        post(delta: dy, phase: index == 0 ? 1 : 2, momentumPhase: 0)
    }
    at(start + Double(tick) * period); tick += 1
    post(delta: 0, phase: 4, momentumPhase: 0)
    var velocity = dy
    for index in 0..<max(2, momentum) {
        at(start + Double(tick) * period); tick += 1
        velocity *= decay
        post(delta: velocity, phase: 0, momentumPhase: index == 0 ? 1 : 2)
    }
    at(start + Double(tick) * period)
    post(delta: 0, phase: 0, momentumPhase: 3)
}
let now = CGEvent(source: nil)?.location ?? .zero
print("{\"post_event_access\": \(allowed), \"sent\": \(sent), \"pointer\": [\(now.x), \(now.y)], \"target\": [\(x), \(y)]}")
