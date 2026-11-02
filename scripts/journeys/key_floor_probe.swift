// key_floor_probe: the macOS key-to-photon FLOOR for SHORTCUT FRAMES (Lawrence via the lead, 2026-11-02): a plain AppKit
// app, no cmux code, filmed with the same ScreenCaptureKit set-up as the harness recorder (display filter with this
// process's window, minimumFrameInterval 1/240, display time per frame) on the same mini and 120 Hz virtual display,
// with the same real HID keys (CuaDriver, sent by ext_keyfloor.py).
//
//   key_floor_probe SECONDS OUT.json READY_FILE
// Opens a 900x600 window and changes it on each key, in three phases chosen by the key:
//   "a"       keyDown in an NSView: a CALayer's color changes in the key's turn (actions off)      -> region "layer"
//   cmd+k     a main-menu key equivalent (performKeyEquivalent path, as most cmux shortcuts): same layer -> "layer"
//   "1" then "b".."z"  "1" moves the keyboard to an NSTextView (TextEdit-like); each letter adds one glyph -> "text"
// Every ScreenCaptureKit frame is kept as [display time s, status, layer region checksum, text region checksum]; every
// key as [NSEvent.timestamp s, kind]. Both are mach host time (systemUptime), the clock of the harness's frames.json.
// Writes OUT.json at the end (SECONDS after start) and READY_FILE once frames come.
import AppKit
import CoreMedia
import QuartzCore
import ScreenCaptureKit

final class Recorder: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let lock = NSLock()
    var frames: [[Any]] = []
    var stopped: String?
    var layerRect = CGRect.zero, textRect = CGRect.zero  // in captured pixels, top-left origin
    static let tick: Double = { var t = mach_timebase_info_data_t(); mach_timebase_info(&t); return Double(t.numer) / Double(t.denom) / 1e9 }()

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen,
              let info = (CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]])?.first,
              let raw = info[.status] as? Int else { return }
        let t = Double((info[.displayTime] as? NSNumber)?.uint64Value ?? 0) * Self.tick
        var row: [Any] = [t, raw == SCFrameStatus.complete.rawValue ? "complete" : (raw == SCFrameStatus.idle.rawValue ? "idle" : "other:\(raw)")]
        if raw == SCFrameStatus.complete.rawValue, let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) {
            CVPixelBufferLockBaseAddress(buffer, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
            let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
            let stride = CVPixelBufferGetBytesPerRow(buffer), w = CVPixelBufferGetWidth(buffer), h = CVPixelBufferGetHeight(buffer)
            lock.lock(); let rects = [layerRect, textRect]; lock.unlock()
            for r in rects {
                var sum: UInt64 = 1469598103934665603
                let x0 = max(0, Int(r.minX)), x1 = min(w, Int(r.maxX)), y0 = max(0, Int(r.minY)), y1 = min(h, Int(r.maxY))
                if x0 < x1 && y0 < y1 {
                    for y in Swift.stride(from: y0, to: y1, by: 2) {
                        let rowp = base + y * stride
                        for x in Swift.stride(from: x0, to: x1, by: 2) {
                            let p = rowp + x * 4
                            sum = (sum ^ UInt64(p[0]) ^ (UInt64(p[1]) << 8) ^ (UInt64(p[2]) << 16)) &* 1099511628211
                        }
                    }
                }
                row.append(String(sum, radix: 16))
            }
        }
        lock.lock(); frames.append(row); lock.unlock()
    }
    func stream(_ stream: SCStream, didStopWithError error: any Error) { lock.lock(); stopped = "\(error)"; lock.unlock() }
}

final class KeyView: NSView {
    let swatch = CALayer()
    var hue: CGFloat = 0
    var keys: [[Any]] = []
    weak var text: NSTextView?
    override var acceptsFirstResponder: Bool { true }
    func flip() {
        hue = (hue + 0.37).truncatingRemainder(dividingBy: 1)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        swatch.backgroundColor = NSColor(hue: hue, saturation: 1, brightness: 1, alpha: 1).cgColor
        CATransaction.commit()
    }
    override func keyDown(with event: NSEvent) {
        keys.append([event.timestamp, "layer-keydown", event.charactersIgnoringModifiers ?? ""])
        // "1" (not measured) moves the keyboard to the text view: the typing phase.
        if event.charactersIgnoringModifiers == "1" { window?.makeFirstResponder(text); return }
        if event.charactersIgnoringModifiers == "a" { flip() } else { super.keyDown(with: event) }
    }
    @objc func menuFlip(_ sender: Any?) {
        keys.append([NSApp.currentEvent?.timestamp ?? 0, "layer-menu", "cmd+k"])
        flip()
    }
}

final class TextView: NSTextView {
    weak var log: KeyView?
    override func keyDown(with event: NSEvent) {
        if event.charactersIgnoringModifiers == "a" { return log?.keyDown(with: event) ?? () }
        log?.keys.append([event.timestamp, "text", event.charactersIgnoringModifiers ?? ""])
        super.keyDown(with: event)
    }
}

final class Delegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) { Task { await Probe.run() } }
}

enum Probe {
    @MainActor static var view: KeyView!
    static func run() async {
        let args = CommandLine.arguments
        let seconds = Double(args.count > 1 ? args[1] : "30") ?? 30
        let out = args.count > 2 ? args[2] : "/tmp/key_floor_probe.json"
        let ready = args.count > 3 ? args[3] : "/tmp/key_floor_probe.ready"
        let (window, view) = await MainActor.run { () -> (NSWindow, KeyView) in
            let menu = NSMenu(), appItem = NSMenuItem(), appMenu = NSMenu()
            let item = NSMenuItem(title: "Flip", action: #selector(KeyView.menuFlip(_:)), keyEquivalent: "k")
            item.keyEquivalentModifierMask = [.command]
            appMenu.addItem(item); appItem.submenu = appMenu; menu.addItem(appItem); NSApp.mainMenu = menu
            let w = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 900, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
            let v = KeyView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
            v.wantsLayer = true
            v.layer?.backgroundColor = NSColor(white: 0.1, alpha: 1).cgColor
            v.swatch.frame = CGRect(x: 40, y: 340, width: 220, height: 220)
            v.swatch.backgroundColor = NSColor.red.cgColor
            v.layer?.addSublayer(v.swatch)
            let scroll = NSScrollView(frame: NSRect(x: 320, y: 40, width: 540, height: 200))
            let text = TextView(frame: scroll.bounds)
            text.font = NSFont.monospacedSystemFont(ofSize: 28, weight: .regular)
            text.log = v
            v.text = text
            scroll.documentView = text
            v.addSubview(scroll)
            item.target = v
            w.contentView = v
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            w.makeFirstResponder(v)
            Probe.view = v
            return (w, v)
        }
        let recorder = Recorder()
        var result: [String: Any] = ["os": ProcessInfo.processInfo.operatingSystemVersionString]
        do {
            try? await Task.sleep(for: .milliseconds(500))
            let content = try await SCShareableContent.currentProcess
            let number = await MainActor.run { CGWindowID(window.windowNumber) }
            guard let target = content.windows.first(where: { $0.windowID == number }),
                  let display = content.displays.first(where: { $0.frame.intersects(target.frame) }) ?? content.displays.first else {
                throw NSError(domain: "probe", code: 1, userInfo: [NSLocalizedDescriptionKey: "no own window or display"])
            }
            let (scale, refresh) = await MainActor.run { (window.backingScaleFactor, window.screen?.maximumFramesPerSecond ?? 0) }
            result["scale"] = scale
            result["max_fps"] = refresh
            // Regions in captured pixels: the display filter captures the whole display (top-left origin).
            let frame = target.frame  // points, top-left origin (ScreenCaptureKit)
            let dframe = display.frame
            func px(_ r: CGRect) -> CGRect {  // r: window-content rect, bottom-left origin within a 600 pt-high window
                let x = (frame.minX - dframe.minX + r.minX) * scale
                let top = (frame.minY - dframe.minY + (frame.height - 600) + (600 - r.maxY)) * scale
                return CGRect(x: x, y: top, width: r.width * scale, height: r.height * scale)
            }
            recorder.layerRect = px(CGRect(x: 60, y: 360, width: 180, height: 180))
            recorder.textRect = px(CGRect(x: 320, y: 40, width: 540, height: 200))
            result["regions_px"] = ["layer": "\(recorder.layerRect)", "text": "\(recorder.textRect)"]
            let configuration = SCStreamConfiguration()
            configuration.width = Int(dframe.width * scale)
            configuration.height = Int(dframe.height * scale)
            configuration.minimumFrameInterval = CMTime(value: 1, timescale: 240)
            configuration.pixelFormat = kCVPixelFormatType_32BGRA
            configuration.showsCursor = false
            configuration.queueDepth = 8
            let stream = SCStream(filter: SCContentFilter(display: display, including: [target]), configuration: configuration, delegate: recorder)
            try stream.addStreamOutput(recorder, type: .screen, sampleHandlerQueue: DispatchQueue(label: "probe"))
            try await stream.startCapture()
            FileManager.default.createFile(atPath: ready, contents: Data("ready\n".utf8))
            try? await Task.sleep(for: .seconds(seconds))
            try? await stream.stopCapture()
        } catch {
            result["error"] = "\(error)"
        }
        let keys = await MainActor.run { view.keys }
        recorder.lock.lock()
        result["frames"] = recorder.frames
        result["stopped"] = recorder.stopped ?? ""
        recorder.lock.unlock()
        result["keys"] = keys
        if let data = try? JSONSerialization.data(withJSONObject: result) { try? data.write(to: URL(fileURLWithPath: out)) }
        exit(0)
    }
}

setvbuf(stdout, nil, _IONBF, 0)
let delegate = Delegate()
NSApplication.shared.setActivationPolicy(.regular)
NSApplication.shared.delegate = delegate
NSApplication.shared.run()
