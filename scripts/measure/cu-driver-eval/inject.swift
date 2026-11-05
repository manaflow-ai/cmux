// The input A/B's injector and observer (scripts/measure/cu-driver-eval/README.md).
//
//   cu-eval-inject grants                       {"accessibility","post_event","screen_recording"}
//   cu-eval-inject observe                      {"front_pid","cursor":[x,y],"order":[wid,...],"screen":[w,h]}
//   cu-eval-inject find-window PID              {"wid","frame":[x,y,w,h]} of PID's largest window
//   cu-eval-inject tap-click X Y                a real click through the session tap (setup only)
//   cu-eval-inject warp X Y                     park the pointer
//   cu-eval-inject post ROUTE GESTURE PID WID WX WY WW WH LX LY
//
// post sends one GESTURE (click: down and up; key: "a" down and up; scroll: 5 wheel lines) to
// window WID of PID at window-local point LX,LY (top-left points; the window's frame is WX,WY,WW,WH
// in top-left screen points) through one ROUTE:
//   cg-pid       CGEventPostToPid with a plain CGEvent at the screen point (Petal's dead route 1)
//   sl-pid       SkyLight SLEventPostToPid with the same event (Petal's dead route 2)
//   session-tap  CGEventPost at the session tap: the universal route; it moves the pointer
//   nsevent-pid  an NSEvent built with windowNumber WID and the window-local location, converted
//                with -[NSEvent CGEvent] and posted with CGEventPostToPid (Hopp's idea; not their code)
//   stamped-pid  Cua Driver's field stamps without its focus step: a mouseMoved primer, then fields
//                1, 3, 7, 40, 51, 58, 91, 92 and CGEventSetWindowLocation, posted through
//                SLEventPostToPid and then CGEventPostToPid (ported from trycua/cua, MIT:
//                libs/cua-driver/rust/crates/platform-macos/src/input/mouse.rs post_mouse_event)
//   stamped-sl   the same stamped events, posted through SLEventPostToPid only
//   stamped-cg   the same stamped events, posted through CGEventPostToPid only (which of the two
//                delivers each gesture, so a driver can post once instead of twice)
// nsevent-pid has no scroll (NSEvent has no public wheel constructor): it prints "unsupported".
// Every route is fire-and-forget; what arrived is read from the target's own log, never from here.
import AppKit
import ApplicationServices

typealias PostToPid = @convention(c) (pid_t, CGEvent) -> Void
typealias SetWindowLocation = @convention(c) (CGEvent, CGPoint) -> Void
typealias SetIntegerField = @convention(c) (CGEvent, UInt32, Int64) -> Void

let rtldDefault = UnsafeMutableRawPointer(bitPattern: -2)
_ = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW)
func symbol<T>(_ name: String, _ type: T.Type) -> T? {
  guard let pointer = dlsym(rtldDefault, name) else { return nil }
  return unsafeBitCast(pointer, to: type)
}
let slPostToPid = symbol("SLEventPostToPid", PostToPid.self)
let setWindowLocation = symbol("CGEventSetWindowLocation", SetWindowLocation.self)
// Raw field numbers: 51 and 58 have no CGEventField case, so set them through the C symbol.
let setIntegerField = symbol("SLEventSetIntegerValueField", SetIntegerField.self)
  ?? symbol("CGEventSetIntegerValueField", SetIntegerField.self)

func emit(_ value: Any) {
  if let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
     let text = String(data: data, encoding: .utf8) {
    print(text)
  }
}

func fail(_ message: String, code: Int32 = 2) -> Never {
  FileHandle.standardError.write("cu-eval-inject: \(message)\n".data(using: .utf8)!)
  exit(code)
}

func windows() -> [[String: Any]] {
  let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
  let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] ?? []
  return list.filter { ($0[kCGWindowLayer as String] as? Int) == 0 }
}

func pause(_ ms: Int) { usleep(useconds_t(ms * 1000)) }

let args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first else { fail("no command") }

switch command {
case "grants":
  emit(["accessibility": AXIsProcessTrusted(), "post_event": CGPreflightPostEventAccess(),
        "screen_recording": CGPreflightScreenCaptureAccess(),
        "sl_post_to_pid": slPostToPid != nil, "cg_set_window_location": setWindowLocation != nil])

case "observe":
  let cursor = CGEvent(source: nil)?.location ?? .zero
  let screen = CGDisplayBounds(CGMainDisplayID())
  emit(["front_pid": Int(NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1),
        "cursor": [cursor.x, cursor.y], "screen": [screen.width, screen.height],
        "order": windows().compactMap { $0[kCGWindowNumber as String] as? Int }])

case "windows":
  // Every on-screen window, front to back, at any layer: what was in front when a driver said so.
  let all = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
  emit(["windows": all.map { info -> [String: Any] in
    let bounds = (info[kCGWindowBounds as String] as? NSDictionary).flatMap { CGRect(dictionaryRepresentation: $0) } ?? .zero
    return ["number": info[kCGWindowNumber as String] as? Int ?? -1, "owner": info[kCGWindowOwnerName as String] as? String ?? "",
            "name": info[kCGWindowName as String] as? String ?? "", "layer": info[kCGWindowLayer as String] as? Int ?? 0,
            "alpha": info[kCGWindowAlpha as String] as? Double ?? 1, "frame": [bounds.minX, bounds.minY, bounds.width, bounds.height]]
  }])

case "find-window":
  guard args.count == 2, let pid = Int(args[1]) else { fail("find-window PID") }
  let mine = windows().filter { ($0[kCGWindowOwnerPID as String] as? Int) == pid }
  let sized = mine.compactMap { info -> (Int, CGRect)? in
    guard let wid = info[kCGWindowNumber as String] as? Int,
          let bounds = info[kCGWindowBounds as String] as? NSDictionary,
          let rect = CGRect(dictionaryRepresentation: bounds) else { return nil }
    return (wid, rect)
  }
  guard let best = sized.max(by: { $0.1.width * $0.1.height < $1.1.width * $1.1.height }) else { fail("no window for \(pid)", code: 1) }
  emit(["wid": best.0, "frame": [best.1.minX, best.1.minY, best.1.width, best.1.height]])

case "tap-click", "warp":
  guard args.count == 3, let x = Double(args[1]), let y = Double(args[2]) else { fail("\(command) X Y") }
  let point = CGPoint(x: x, y: y)
  if command == "warp" {
    CGWarpMouseCursorPosition(point)
    CGAssociateMouseAndMouseCursorPosition(1)
  } else {
    for type in [CGEventType.mouseMoved, .leftMouseDown, .leftMouseUp] {
      CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cgSessionEventTap)
      pause(40)
    }
  }

case "post":
  guard args.count == 11, let pidValue = Int32(args[3]), let wid = Int(args[4]) else {
    fail("post ROUTE GESTURE PID WID WX WY WW WH LX LY")
  }
  let route = args[1], gesture = args[2], pid = pidValue
  let numbers = args[5...10].compactMap { Double($0) }
  guard numbers.count == 6 else { fail("bad geometry") }
  let frame = CGRect(x: numbers[0], y: numbers[1], width: numbers[2], height: numbers[3])
  let local = CGPoint(x: numbers[4], y: numbers[5])
  let screen = CGPoint(x: frame.minX + local.x, y: frame.minY + local.y)
  let source = CGEventSource(stateID: .hidSystemState)
  let clickGroup = Int64.random(in: 1...Int64(Int32.max))

  func stamp(_ event: CGEvent, clickState: Int64, subtype: Int64) {
    setWindowLocation?(event, local)
    let fields: [(UInt32, Int64)] = [(1, clickState), (3, 0), (7, subtype), (51, Int64(wid)), (58, clickGroup),
                                     (91, Int64(wid)), (92, Int64(wid)), (40, Int64(pid))]
    for (field, value) in fields { setIntegerField?(event, field, value) }
  }

  // The three stamped routes build the same events and differ only in how they post them.
  let stamped = route.hasPrefix("stamped-")

  func send(_ event: CGEvent) {
    switch route {
    case "cg-pid", "nsevent-pid": event.postToPid(pid)
    case "sl-pid":
      guard let post = slPostToPid else { fail("SLEventPostToPid is missing", code: 3) }
      post(pid, event)
    case "session-tap": event.post(tap: .cgSessionEventTap)
    case "stamped-pid":
      slPostToPid?(pid, event)
      event.postToPid(pid)
    case "stamped-sl":
      guard let post = slPostToPid else { fail("SLEventPostToPid is missing", code: 3) }
      post(pid, event)
    case "stamped-cg": event.postToPid(pid)
    default: fail("unknown route \(route)")
    }
  }

  func mouse(_ type: CGEventType) -> CGEvent? {
    if route == "nsevent-pid" {
      let nsType: NSEvent.EventType = type == .leftMouseDown ? .leftMouseDown : (type == .leftMouseUp ? .leftMouseUp : .mouseMoved)
      return NSEvent.mouseEvent(with: nsType, location: NSPoint(x: local.x, y: frame.height - local.y), modifierFlags: [],
                                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: wid, context: nil,
                                eventNumber: 0, clickCount: type == .mouseMoved ? 0 : 1, pressure: type == .leftMouseDown ? 1 : 0)?.cgEvent
    }
    guard let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: screen, mouseButton: .left) else { return nil }
    if stamped { stamp(event, clickState: type == .mouseMoved ? 0 : 1, subtype: type == .mouseMoved ? 0 : 3) }
    return event
  }

  func key(_ down: Bool) -> CGEvent? {
    if route == "nsevent-pid" {
      return NSEvent.keyEvent(with: down ? .keyDown : .keyUp, location: .zero, modifierFlags: [],
                              timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: wid, context: nil,
                              characters: "a", charactersIgnoringModifiers: "a", isARepeat: false, keyCode: 0)?.cgEvent
    }
    guard let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down) else { return nil }
    var chars: [UniChar] = [0x61]
    event.keyboardSetUnicodeString(stringLength: 1, unicodeString: &chars)
    if stamped {
      setIntegerField?(event, 51, Int64(wid))
      setIntegerField?(event, 40, Int64(pid))
    }
    return event
  }

  var events: [CGEvent?] = []
  switch gesture {
  case "click":
    if stamped { events.append(mouse(.mouseMoved)) }
    events += [mouse(.leftMouseDown), mouse(.leftMouseUp)]
  case "key":
    events += [key(true), key(false)]
  case "scroll":
    if route == "nsevent-pid" {
      emit(["posted": 0, "unsupported": "NSEvent has no public scroll-wheel constructor"])
      exit(0)
    }
    for _ in 0..<5 {
      let wheel = CGEvent(scrollWheelEvent2Source: source, units: .line, wheelCount: 1, wheel1: -1, wheel2: 0, wheel3: 0)
      wheel?.location = screen
      if let wheel, stamped { stamp(wheel, clickState: 0, subtype: 0) }
      events.append(wheel)
    }
  default: fail("unknown gesture \(gesture)")
  }
  let made = events.compactMap { $0 }
  guard made.count == events.count else { fail("could not build the \(gesture) events for \(route)", code: 3) }
  for event in made {
    send(event)
    pause(30)
  }
  emit(["posted": made.count])

default:
  fail("unknown command \(command)")
}
