// Desktop-wide input and a whole-screen JPEG, the way an X11 desktop agent works with xdotool and
// `import -window root` (the "chief-desktop" arm, chief_computer_mcp.py; README.md, "Arms"). Every
// event goes through the session tap: it moves the pointer and lands in whatever window is there.
//
//   arena-desktop screenshot OUT.jpg WIDTH    the main display scaled to WIDTH pixels, JPEG quality 0.72;
//                                             prints {"width","height","scale"} (scale = pixels per point)
//   arena-desktop click X Y [COUNT] [BUTTON]  X,Y in points; BUTTON left|right|middle
//   arena-desktop move X Y
//   arena-desktop drag X Y TO_X TO_Y
//   arena-desktop scroll X Y up|down|left|right AMOUNT
//   arena-desktop type TEXT
//   arena-desktop key KEYS                    xdotool-style chords: Return, ctrl+a, cmd+s, shift+Tab
import AppKit
import ApplicationServices
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers

let args = CommandLine.arguments
func fail(_ text: String) -> Never {
  FileHandle.standardError.write((text + "\n").data(using: .utf8)!)
  exit(2)
}
guard args.count >= 2 else { fail("usage: arena-desktop screenshot|click|move|drag|scroll|type|key ...") }
let source = CGEventSource(stateID: .hidSystemState)
func num(_ i: Int) -> Double {
  guard args.count > i, let v = Double(args[i]) else { fail("arena-desktop: argument \(i) is not a number") }
  return v
}
func settle() { usleep(30_000) }

func mouse(_ type: CGEventType, _ point: CGPoint, _ button: CGMouseButton, clicks: Int64 = 1) {
  let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: button)
  event?.setIntegerValueField(.mouseEventClickState, value: clicks)
  event?.post(tap: .cgSessionEventTap)
}

let keyCodes: [String: CGKeyCode] = [
  "return": 36, "enter": 36, "tab": 48, "space": 49, "backspace": 51, "delete": 51, "escape": 53, "esc": 53,
  "left": 123, "right": 124, "down": 125, "up": 126, "home": 115, "end": 119, "page_up": 116, "pageup": 116,
  "page_down": 121, "pagedown": 121, "forwarddelete": 117, "f1": 122, "f2": 120, "f3": 99, "f4": 118,
  "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12, "w": 13,
  "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25,
  "7": 26, "-": 27, "8": 28, "0": 29, "o": 31, "u": 32, "i": 34, "p": 35, "l": 37, "j": 38, "k": 40, "n": 45,
  "m": 46, ",": 43, ".": 47, "/": 44, ";": 41, "'": 39, "[": 33, "]": 30, "\\": 42, "`": 50,
]
let modifierFlags: [String: CGEventFlags] = [
  "ctrl": .maskControl, "control": .maskControl, "shift": .maskShift, "alt": .maskAlternate, "option": .maskAlternate,
  "opt": .maskAlternate, "cmd": .maskCommand, "command": .maskCommand, "super": .maskCommand, "meta": .maskCommand,
]

switch args[1] {
case "screenshot":
  guard args.count == 4, let width = Double(args[3]) else { fail("usage: arena-desktop screenshot OUT.jpg WIDTH") }
  let display = CGMainDisplayID()
  let points = CGDisplayBounds(display).size
  let w = Int(width), h = Int((width * points.height / points.width).rounded())
  // ScreenCaptureKit (macOS 26 has no CGDisplayCreateImage): the whole display, without the cursor,
  // as `import -window root` gives it. Its handlers run on its own queue, so the wait here is safe.
  final class Shot: @unchecked Sendable { var image: CGImage?; var failure = "" }
  let shot = Shot(), finished = DispatchSemaphore(value: 0)
  SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { content, error in
    guard let screen = content?.displays.first(where: { $0.displayID == display }) else {
      shot.failure = error?.localizedDescription ?? "no main display in the shareable content"
      finished.signal()
      return
    }
    let config = SCStreamConfiguration()
    config.width = w
    config.height = h
    config.showsCursor = false
    SCScreenshotManager.captureImage(contentFilter: SCContentFilter(display: screen, excludingWindows: []),
                                     configuration: config) { image, error in
      shot.image = image
      shot.failure = error?.localizedDescription ?? ""
      finished.signal()
    }
  }
  if finished.wait(timeout: .now() + 10) == .timedOut {
    fail("arena-desktop: ScreenCaptureKit gave no screenshot in 10 s")
  }
  guard let image = shot.image else { fail("arena-desktop: no screen capture (Screen Recording granted?) \(shot.failure)") }
  guard let context = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
  else { fail("arena-desktop: no context") }
  context.interpolationQuality = .high
  context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
  guard let scaled = context.makeImage(),
        let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: args[2]) as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
  else { fail("arena-desktop: could not encode") }
  CGImageDestinationAddImage(dest, scaled, [kCGImageDestinationLossyCompressionQuality: 0.72] as CFDictionary)
  guard CGImageDestinationFinalize(dest) else { fail("arena-desktop: could not write \(args[2])") }
  print("{\"width\":\(w),\"height\":\(h),\"scale\":\(Double(w) / points.width)}")
case "click":
  let point = CGPoint(x: num(2), y: num(3))
  let count = args.count > 4 ? max(1, Int(args[4]) ?? 1) : 1
  let name = args.count > 5 ? args[5] : "left"
  let button: CGMouseButton = name == "right" ? .right : name == "middle" ? .center : .left
  let (down, up): (CGEventType, CGEventType) = button == .right ? (.rightMouseDown, .rightMouseUp)
    : button == .center ? (.otherMouseDown, .otherMouseUp) : (.leftMouseDown, .leftMouseUp)
  mouse(.mouseMoved, point, button)
  settle()
  for i in 1...count {
    mouse(down, point, button, clicks: Int64(i))
    mouse(up, point, button, clicks: Int64(i))
    settle()
  }
case "move":
  mouse(.mouseMoved, CGPoint(x: num(2), y: num(3)), .left)
case "drag":
  let from = CGPoint(x: num(2), y: num(3)), to = CGPoint(x: num(4), y: num(5))
  mouse(.mouseMoved, from, .left)
  settle()
  mouse(.leftMouseDown, from, .left)
  for step in 1...10 {
    let t = Double(step) / 10
    mouse(.leftMouseDragged, CGPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t), .left)
    settle()
  }
  mouse(.leftMouseUp, to, .left)
case "scroll":
  guard args.count == 6, let amount = Int32(args[5]) else { fail("usage: arena-desktop scroll X Y DIRECTION AMOUNT") }
  mouse(.mouseMoved, CGPoint(x: num(2), y: num(3)), .left)
  settle()
  let (dy, dx): (Int32, Int32) = switch args[4] {
  case "up": (amount, 0)
  case "down": (-amount, 0)
  case "left": (0, amount)
  default: (0, -amount)
  }
  for _ in 0..<3 {
    CGEvent(scrollWheelEvent2Source: source, units: .line, wheelCount: 2, wheel1: dy, wheel2: dx, wheel3: 0)?
      .post(tap: .cgSessionEventTap)
    settle()
  }
case "type":
  guard args.count == 3 else { fail("usage: arena-desktop type TEXT") }
  for scalar in args[2].utf16.map({ $0 }) {
    var unit = scalar
    for down in [true, false] {
      let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down)
      event?.keyboardSetUnicodeString(stringLength: 1, unicodeString: &unit)
      event?.post(tap: .cgSessionEventTap)
    }
    usleep(8_000)
  }
case "key":
  guard args.count == 3 else { fail("usage: arena-desktop key KEYS") }
  for chord in args[2].split(separator: " ") {
    var flags: CGEventFlags = []
    var code: CGKeyCode?
    for part in chord.split(separator: "+").map({ $0.lowercased() }) {
      if let flag = modifierFlags[part] { flags.insert(flag) } else { code = keyCodes[part] }
    }
    guard let key = code else { fail("arena-desktop: unknown key in \(chord)") }
    for down in [true, false] {
      let event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: down)
      event?.flags = flags
      event?.post(tap: .cgSessionEventTap)
    }
    settle()
  }
default:
  fail("arena-desktop: unknown command \(args[1])")
}
