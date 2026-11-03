// What an app sees when it captures its own window that shows a page drawn by another process (a WKWebView,
// like a Chromium page, draws through the GPU process), without the Screen Recording grant: screen_capture_check.py
// compiles and runs this from the bench's process, so it answers to the same responsible process as the app.
//
// Shows a window whose page is solid red with black text, then reads the page's middle through:
//   cgwindow        CGWindowListCreateImage of the window (frame_strip's capture)
//   sck_window      ScreenCaptureKit, current-process content, the window alone
//   sck_display     ScreenCaptureKit, current-process content, the display showing only this app's windows
// Prints one JSON object: each method's middle pixel, whether it is the page's red, an error if it failed, and
// where its PNG went (argv[1], a folder).
import AppKit
import ScreenCaptureKit
import WebKit

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : NSTemporaryDirectory()
var report: [String: Any] = ["preflight": CGPreflightScreenCaptureAccess()]

func pixel(_ image: CGImage, at point: CGPoint) -> [Int] {
    var bytes = [UInt8](repeating: 0, count: 4)
    let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
        guard let context = CGContext(data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return false }
        context.draw(image, in: CGRect(x: -point.x, y: -(Double(image.height) - point.y), width: Double(image.width), height: Double(image.height)))
        return true
    }
    return drawn ? bytes.prefix(3).map(Int.init) : []
}

func record(_ name: String, _ image: CGImage?, error: String? = nil) {
    var entry: [String: Any] = [:]
    if let error { entry["error"] = error }
    if let image {
        let middle = pixel(image, at: CGPoint(x: Double(image.width) / 2, y: Double(image.height) * 0.6))
        entry["size"] = [image.width, image.height]
        entry["middle_rgb"] = middle
        entry["page_red"] = middle.count == 3 && middle[0] > 200 && middle[1] < 60 && middle[2] < 60
        let path = (outDir as NSString).appendingPathComponent("probe-\(name).png")
        if let destination = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, "public.png" as CFString, 1, nil) {
            CGImageDestinationAddImage(destination, image, nil)
            if CGImageDestinationFinalize(destination) { entry["png"] = path }
        }
    } else if error == nil {
        entry["error"] = "no image"
    }
    report[name] = entry
}

final class Probe: NSObject, NSApplicationDelegate, WKNavigationDelegate {
    var window: NSWindow!
    var web: WKWebView!

    func applicationDidFinishLaunching(_ notification: Notification) {
        window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 640, height: 420), styleMask: [.titled], backing: .buffered, defer: false)
        web = WKWebView(frame: window.contentView!.bounds)
        web.autoresizingMask = [.width, .height]
        web.navigationDelegate = self
        window.contentView!.addSubview(web)
        window.level = .floating
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        web.loadHTMLString("<html><body style='margin:0;background:#ff0000;font:bold 48px sans-serif;color:#000'>"
            + "<p style='padding:40px'>page pixels from another process</p></body></html>", baseURL: nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { self.finish(timedOut: true) }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { Task { await self.capture() } }
    }

    @MainActor func capture() async {
        let number = CGWindowID(window.windowNumber)
        typealias CreateImage = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        if let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") {
            let create = unsafeBitCast(symbol, to: CreateImage.self)
            record("cgwindow", create(.null, 1 << 3, number, (1 << 0) | (1 << 9))?.takeRetainedValue())
        } else {
            record("cgwindow", nil, error: "no CGWindowListCreateImage")
        }
        do {
            let content = try await SCShareableContent.currentProcess
            report["sck_windows"] = content.windows.count
            report["sck_displays"] = content.displays.count
            if let target = content.windows.first(where: { $0.windowID == number }) {
                let configuration = SCStreamConfiguration()
                configuration.width = Int(window.frame.width * window.backingScaleFactor)
                configuration.height = Int(window.frame.height * window.backingScaleFactor)
                configuration.showsCursor = false
                do {
                    record("sck_window", try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: target), configuration: configuration))
                } catch { record("sck_window", nil, error: "\(error)") }
                if let display = content.displays.first(where: { $0.frame.intersects(target.frame) }) ?? content.displays.first {
                    let filter = SCContentFilter(display: display, including: content.windows.filter(\.isOnScreen))
                    let shot = SCStreamConfiguration()
                    shot.sourceRect = target.frame.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY)
                    shot.width = configuration.width
                    shot.height = configuration.height
                    shot.showsCursor = false
                    do { record("sck_display", try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: shot)) } catch {
                        record("sck_display", nil, error: "\(error)")
                    }
                }
            } else {
                record("sck_window", nil, error: "current-process content lists no window \(number)")
            }
        } catch {
            record("sck_window", nil, error: "currentProcess: \(error)")
        }
        finish(timedOut: false)
    }

    func finish(timedOut: Bool) {
        if timedOut { report["timed_out"] = true }
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]) {
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data([0x0A]))
        }
        exit(0)
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let probe = Probe()
app.delegate = probe
app.run()
