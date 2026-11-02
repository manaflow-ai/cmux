// sck_probe: does ScreenCaptureKit deliver frames of this process's own window on this mini, and for which
// kinds of change? (handoff resize-videos/KIT.md; the recorder fault of 2026-11-02: 0 callbacks in cmux.)
//
//   sck_probe SECONDS   opens a 900x600 window on the main display, starts an own-window stream
//                       (SCShareableContent.currentProcess, the cmux recorder's set-up), and for SECONDS/3 s each
//                       changes the window in one way: "still" (no change), "layer" (a CALayer's color each display
//                       frame), "draw" (an NSView redrawn with setNeedsDisplay each frame). Prints one JSON line:
//                       callbacks and complete frames per phase, the display, CGPreflightScreenCaptureAccess, and the
//                       configuration. Run with `open` (the GUI session), output with --stdout.
import AppKit
import CoreMedia
import QuartzCore
import ScreenCaptureKit

final class Counter: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let lock = NSLock()
    var callbacks = 0, complete = 0, idle = 0
    var stopped: String?
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen else { return }
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]]
        let raw = attachments?.first?[.status] as? Int
        lock.lock(); defer { lock.unlock() }
        callbacks += 1
        if raw == SCFrameStatus.complete.rawValue { complete += 1 }
        if raw == SCFrameStatus.idle.rawValue { idle += 1 }
    }
    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        lock.lock(); stopped = String(describing: error); lock.unlock()
    }
    func snapshot() -> [Int] { lock.lock(); defer { lock.unlock() }; return [callbacks, complete, idle] }
}

final class DrawView: NSView {
    var hue: CGFloat = 0
    override func draw(_ dirtyRect: NSRect) {
        NSColor(hue: hue, saturation: 0.8, brightness: 0.9, alpha: 1).setFill()
        dirtyRect.fill()
    }
}

final class Delegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { await Probe.run() }
    }
}

enum Probe {
    static func run() async {
        let seconds = Double(CommandLine.arguments.dropFirst().first ?? "9") ?? 9
        let app = NSApplication.shared
        let window = await MainActor.run { () -> NSWindow in
            let w = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 900, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
            let view = DrawView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
            view.wantsLayer = true
            let layer = CALayer()
            layer.frame = CGRect(x: 20, y: 20, width: 200, height: 200)
            layer.backgroundColor = NSColor.red.cgColor
            view.layer?.addSublayer(layer)
            w.contentView = view
            w.makeKeyAndOrderFront(nil)
            app.activate(ignoringOtherApps: true)
            return w
        }
        try? await Task.sleep(for: .seconds(1))
        var result: [String: Any] = ["preflight": CGPreflightScreenCaptureAccess(),
                                     "os": ProcessInfo.processInfo.operatingSystemVersionString]
        if let screen = await MainActor.run(body: { window.screen }) {
            result["screen"] = ["frame": "\(screen.frame)", "scale": screen.backingScaleFactor,
                                "max_fps": screen.maximumFramesPerSecond]
        }
        let counter = Counter()
        do {
            let content = try await SCShareableContent.currentProcess
            let number = await MainActor.run { CGWindowID(window.windowNumber) }
            guard let target = content.windows.first(where: { $0.windowID == number }) else {
                result["error"] = "no own window in currentProcess (\(content.windows.count) listed)"
                print(String(data: try JSONSerialization.data(withJSONObject: result), encoding: .utf8) ?? "{}")
                exit(0)
            }
            let configuration = SCStreamConfiguration()
            configuration.width = 1800
            configuration.height = 1200
            configuration.minimumFrameInterval = CMTime(value: 1, timescale: 240)
            configuration.pixelFormat = kCVPixelFormatType_32BGRA
            configuration.showsCursor = false
            configuration.queueDepth = 8
            let stream = SCStream(filter: SCContentFilter(desktopIndependentWindow: target), configuration: configuration, delegate: counter)
            try stream.addStreamOutput(counter, type: .screen, sampleHandlerQueue: DispatchQueue(label: "probe"))
            try await stream.startCapture()
            var phases: [String: [Int]] = [:]
            for phase in ["still", "layer", "draw"] {
                let before = counter.snapshot()
                let end = Date().addingTimeInterval(seconds / 3)
                var hue: CGFloat = 0
                while Date() < end {
                    hue = (hue + 0.01).truncatingRemainder(dividingBy: 1)
                    let h = hue
                    await MainActor.run {
                        guard let view = window.contentView as? DrawView else { return }
                        if phase == "layer" {
                            CATransaction.begin(); CATransaction.setDisableActions(true)
                            view.layer?.sublayers?.first?.backgroundColor = NSColor(hue: h, saturation: 1, brightness: 1, alpha: 1).cgColor
                            CATransaction.commit()
                        } else if phase == "draw" {
                            view.hue = h
                            view.needsDisplay = true
                        }
                    }
                    try? await Task.sleep(for: .milliseconds(8))
                }
                let after = counter.snapshot()
                phases[phase] = zip(after, before).map { $0 - $1 }
            }
            try? await stream.stopCapture()
            result["phases_callbacks_complete_idle"] = phases
            result["stopped"] = counter.stopped ?? ""
        } catch {
            result["error"] = String(describing: error)
        }
        print(String(data: (try? JSONSerialization.data(withJSONObject: result)) ?? Data(), encoding: .utf8) ?? "{}")
        exit(0)
    }
}

setvbuf(stdout, nil, _IONBF, 0)
let delegate = Delegate()
NSApplication.shared.setActivationPolicy(.regular)
NSApplication.shared.delegate = delegate
NSApplication.shared.run()
