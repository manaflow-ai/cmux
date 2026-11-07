// The input A/B's windows (scripts/measure/cu-driver-eval/README.md): one binary, three modes.
//
//   cu-eval-app witness LOG x,y,w,h   the user's window: it stays in front and logs every change
//                                     of its key and active state, and any input that lands in it
//   cu-eval-app native LOG x,y,w,h    an AppKit target: logs each mouse, key and wheel event that
//                                     reaches the app (local monitor) and the window (sendEvent:)
//   cu-eval-app webkit LOG x,y,w,h    a WKWebView target: logs the DOM events the page receives
//
// x,y,w,h is the window frame in top-left screen points. Each mode appends JSON lines to LOG:
//   {"kind":"ready","pid","wid","frame":[x,y,w,h],"scale"}
//   {"kind":"event","layer":"app"|"window"|"dom","type":"down"|"up"|"key"|"wheel","x","y"}
// x,y are window-local top-left points (DOM: client coordinates, the same thing for a page that
// fills the window). State lines: {"kind":"state","type":"key"|"resign-key"|"active"|"resign-active"}.
import AppKit
import WebKit

let args = CommandLine.arguments
guard args.count == 4, ["witness", "native", "webkit"].contains(args[1]) else {
  FileHandle.standardError.write("usage: cu-eval-app witness|native|webkit LOG x,y,w,h\n".data(using: .utf8)!)
  exit(2)
}
let mode = args[1]
let logURL = URL(fileURLWithPath: args[2])
let parts = args[3].split(separator: ",").compactMap { Double($0) }
guard parts.count == 4 else { exit(2) }
let start = Date()

FileManager.default.createFile(atPath: logURL.path, contents: nil)
// A global, not a top-level guard: the classes below call log(), and a top-level local declared
// with guard cannot be captured by them.
let logHandle: FileHandle = FileHandle(forWritingAtPath: logURL.path) ?? { exit(2) }()
func log(_ fields: [String: Any]) {
  var line = fields
  line["t"] = Int(Date().timeIntervalSince(start) * 1000)
  guard let data = try? JSONSerialization.data(withJSONObject: line, options: [.sortedKeys]) else { return }
  logHandle.seekToEndOfFile()
  logHandle.write(data + "\n".data(using: .utf8)!)
}

func kind(of event: NSEvent) -> String? {
  switch event.type {
  case .leftMouseDown, .rightMouseDown, .otherMouseDown: return "down"
  case .leftMouseUp, .rightMouseUp, .otherMouseUp: return "up"
  case .keyDown: return "key"
  case .scrollWheel: return "wheel"
  default: return nil
  }
}

final class LoggingWindow: NSWindow {
  override var canBecomeKey: Bool { true }
  override func sendEvent(_ event: NSEvent) {
    if let type = kind(of: event) {
      let point = event.locationInWindow
      log(["kind": "event", "layer": "window", "type": type, "x": point.x, "y": frame.height - point.y,
           "chars": event.type == .keyDown ? (event.characters ?? "") : ""])
    }
    super.sendEvent(event)
  }
}

final class KeyView: NSView {
  override var acceptsFirstResponder: Bool { true }
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
  override func keyDown(with event: NSEvent) {}
  override func draw(_ dirtyRect: NSRect) {
    (mode == "witness" ? NSColor.systemYellow : NSColor.systemTeal).setFill()
    dirtyRect.fill()
  }
}

final class DomBridge: NSObject, WKScriptMessageHandler {
  func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
    guard var body = message.body as? [String: Any] else { return }
    body["kind"] = "event"
    body["layer"] = "dom"
    log(body)
  }
}

// The page's listeners. Electron loads the same script (electron/page.html) and reports through
// console-message instead of the message handler.
let pageScript = """
const send = (type, e) => window.webkit.messageHandlers.ev.postMessage({type, x: e.clientX ?? 0, y: e.clientY ?? 0, chars: e.key ?? ""});
addEventListener('mousedown', e => send('down', e), true);
addEventListener('mouseup', e => send('up', e), true);
addEventListener('keydown', e => send('key', e), true);
addEventListener('wheel', e => send('wheel', e), {capture: true, passive: true});
"""
let pageHTML = """
<!doctype html><html><body style="margin:0;height:100vh;overflow:scroll;background:#9cd">
<div style="height:4000px"><input id="f" autofocus style="margin:20px"></div></body></html>
"""

final class Delegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
  var window: LoggingWindow!
  let bridge = DomBridge()

  func applicationDidFinishLaunching(_ note: Notification) {
    let screenHeight = NSScreen.screens.first?.frame.height ?? 1080
    let rect = NSRect(x: parts[0], y: screenHeight - parts[1] - parts[3], width: parts[2], height: parts[3])
    window = LoggingWindow(contentRect: rect, styleMask: [.titled], backing: .buffered, defer: false)
    window.title = "cu-eval \(mode)"
    window.delegate = self
    window.isReleasedWhenClosed = false
    if mode == "webkit" {
      let config = WKWebViewConfiguration()
      config.userContentController.add(bridge, name: "ev")
      config.userContentController.addUserScript(WKUserScript(source: pageScript, injectionTime: .atDocumentStart, forMainFrameOnly: true))
      let web = WKWebView(frame: NSRect(origin: .zero, size: rect.size), configuration: config)
      web.loadHTMLString(pageHTML, baseURL: nil)
      window.contentView = web
    } else {
      window.contentView = KeyView(frame: NSRect(origin: .zero, size: rect.size))
    }
    // The window's frame is the content rect plus the title bar; re-place it so the whole window
    // starts at the requested top-left corner.
    window.setFrameTopLeftPoint(NSPoint(x: parts[0], y: screenHeight - parts[1]))
    window.makeKeyAndOrderFront(nil)
    window.makeFirstResponder(window.contentView)
    NSApp.activate(ignoringOtherApps: true)
    NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp, .keyDown, .scrollWheel]) { event in
      if let type = kind(of: event) {
        let target = event.window ?? self.window!
        let point = event.locationInWindow
        log(["kind": "event", "layer": "app", "type": type, "x": point.x, "y": target.frame.height - point.y,
             "chars": event.type == .keyDown ? (event.characters ?? "") : ""])
      }
      return event
    }
    let f = window.frame
    log(["kind": "ready", "pid": Int(getpid()), "wid": window.windowNumber, "mode": mode,
         "frame": [f.minX, screenHeight - f.maxY, f.width, f.height], "scale": window.backingScaleFactor,
         "title_bar": f.height - window.contentLayoutRect.height,
         "screen": [NSScreen.screens.first?.frame.width ?? 0, screenHeight]])
  }

  func windowDidBecomeKey(_ note: Notification) { log(["kind": "state", "type": "key"]) }
  func windowDidResignKey(_ note: Notification) { log(["kind": "state", "type": "resign-key"]) }
  func applicationDidBecomeActive(_ note: Notification) { log(["kind": "state", "type": "active"]) }
  func applicationDidResignActive(_ note: Notification) { log(["kind": "state", "type": "resign-active"]) }
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = Delegate()
app.delegate = delegate
signal(SIGTERM) { _ in exit(0) }
app.run()
