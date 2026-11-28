// Frosted art at 2x: does a layer-filter blur (CIAffineClamp + CIGaussianBlur, WindowMaterialView.applyArtBlur)
// cover the whole art view on a backing-scale-2 screen? usage: repro MODE OUTDIR  (MODE: none | filters | filters-sublayer | blur | blur-sublayer | blur-outset | blur-outset-view | preblur)
// The art is a 4 px black/white checkerboard over a red window: sharp = unblurred, gray = blurred, red = not covered.
import AppKit
import CoreImage
import ScreenCaptureKit

let args = CommandLine.arguments
let mode = args.count > 1 ? args[1] : "filters"
let out = URL(fileURLWithPath: args.count > 2 ? args[2] : ".")
let radius = 30

func checkerboard(width: Int, height: Int) -> CGImage {
    let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(.white); ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    ctx.setFillColor(.black)
    for y in stride(from: 0, to: height, by: 4) { for x in stride(from: 0, to: width, by: 4) where (x / 4 + y / 4) % 2 == 0 {
        ctx.fill(CGRect(x: x, y: y, width: 4, height: 4)) } }
    return ctx.makeImage()!
}

func preblurred(_ image: CGImage, radius: Double) -> CGImage {
    let input = CIImage(cgImage: image)
    let blurred = input.clampedToExtent().applyingGaussianBlur(sigma: radius).cropped(to: input.extent)
    return CIContext().createCGImage(blurred, from: input.extent)!
}

func analyze(_ image: CGImage, label: String) {
    let w = image.width, h = image.height
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
    let p = ctx.data!.assumingMemoryBound(to: UInt8.self)
    // Skip a title-bar band at the top (row 0 of the buffer is the image's top).
    let top = h / 8
    var report: [String] = []
    for (name, xr, yr) in [("TL", 0..<w/2, top..<(top + h) / 2), ("TR", w/2..<w, top..<(top + h) / 2),
                           ("BL", 0..<w/2, (top + h) / 2..<h), ("BR", w/2..<w, (top + h) / 2..<h)] {
        var red = 0, sharp = 0, gray = 0, n = 0
        for y in stride(from: yr.lowerBound + 2, to: yr.upperBound - 2, by: 3) {
            for x in stride(from: xr.lowerBound + 2, to: xr.upperBound - 2, by: 3) {
                let i = (y * w + x) * 4
                let r = Int(p[i]), g = Int(p[i + 1]), b = Int(p[i + 2])
                n += 1
                if r > 150 && g < 90 && b < 90 { red += 1; continue }
                let lum = (r + g + b) / 3
                let j = (y * w + x + 2) * 4
                let lum2 = (Int(p[j]) + Int(p[j + 1]) + Int(p[j + 2])) / 3
                if abs(lum - lum2) > 60 { sharp += 1 } else if lum > 60 && lum < 200 { gray += 1 }
            }
        }
        report.append(String(format: "%@ blurred=%.0f%% sharp=%.0f%% uncovered=%.0f%%", name,
                             100 * Double(gray) / Double(n), 100 * Double(sharp) / Double(n), 100 * Double(red) / Double(n)))
    }
    // The rim: samples along the four edges (inside the title bar band) that the red window
    // shows through, as a blur that fades to transparent at the edges leaves.
    var rim = 0, edge = 0
    for y in stride(from: top + 4, to: h - 4, by: 7) { for x in [3, 8, w - 9, w - 4] {
        let i = (y * w + x) * 4; edge += 1; if Int(p[i]) - Int(p[i + 1]) > 40 { rim += 1 } } }
    for x in stride(from: 4, to: w - 4, by: 7) { for y in [top + 3, top + 8, h - 9, h - 4] {
        let i = (y * w + x) * 4; edge += 1; if Int(p[i]) - Int(p[i + 1]) > 40 { rim += 1 } } }
    report.append(String(format: "rim=%.0f%%", 100 * Double(rim) / Double(edge)))
    print("RESULT mode=\(mode) \(label) \(w)x\(h)px: " + report.joined(separator: " | "))
    fflush(stdout)
}

final class Runner: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    let art = NSView()
    func applicationDidFinishLaunching(_ note: Notification) {
        let screens = NSScreen.screens.map { "\($0.localizedName) scale=\($0.backingScaleFactor) \($0.frame)" }
        print("screens: \(screens)")
        guard let screen = NSScreen.screens.first(where: { $0.backingScaleFactor >= 2 }) else {
            print("RESULT no 2x screen"); exit(3)
        }
        let frame = NSRect(x: screen.frame.minX + 60, y: screen.frame.minY + 60, width: 900, height: 560)
        window = NSWindow(contentRect: frame, styleMask: [.titled, .resizable], backing: .buffered, defer: false, screen: screen)
        let content = NSView(frame: NSRect(origin: .zero, size: frame.size))
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1).cgColor
        window.contentView = content
        // WindowMaterialView's art view, as configured there.
        art.wantsLayer = true
        art.frame = content.bounds
        art.autoresizingMask = [.width, .height]
        art.layerContentsRedrawPolicy = .never
        art.layerContentsPlacement = .scaleProportionallyToFill
        art.layer?.contentsGravity = .resizeAspectFill
        art.layer?.masksToBounds = true
        if mode == "blur-outset-view" {
            // The fix's video and living wallpaper views: the view itself runs the blur's reach past
            // a clip view, its own layer blurred alone (no clamp).
            let clip = NSView(frame: content.bounds)
            clip.wantsLayer = true
            clip.autoresizingMask = [.width, .height]
            clip.layer?.masksToBounds = true
            content.addSubview(clip)
            art.frame = clip.bounds.insetBy(dx: -CGFloat(radius * 3), dy: -CGFloat(radius * 3))
            clip.addSubview(art)
        } else {
            content.addSubview(art)
        }
        let board = checkerboard(width: 3024, height: 1964)
        let shown = mode == "preblur" ? preblurred(board, radius: Double(radius) * 1964 / 560 / 2) : board
        let picture = NSImage(cgImage: shown, size: NSSize(width: shown.width / 2, height: shown.height / 2))
        if mode == "blur-outset" {
            // The fix's video and living wallpaper: the picture in a sublayer that runs the blur's
            // reach past every edge, blurred alone (no clamp), clipped by the view.
            let reach = CGFloat(radius * 3)
            let sub = CALayer()
            sub.frame = art.bounds.insetBy(dx: -reach, dy: -reach)
            sub.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
            sub.contentsGravity = .resizeAspectFill
            sub.contents = picture
            sub.filters = [CIFilter(name: "CIGaussianBlur", parameters: [kCIInputRadiusKey: radius])].compactMap { $0 }
            art.layerUsesCoreImageFilters = true
            art.layer?.addSublayer(sub)
        } else if mode.hasSuffix("sublayer") {
            // The video and living wallpaper views: the picture in a sublayer that autoresizes, the
            // filters on the view's own layer.
            let sub = CALayer()
            sub.frame = art.bounds
            sub.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
            sub.contentsGravity = .resizeAspectFill
            sub.contents = picture
            art.layer?.addSublayer(sub)
        } else {
            art.layer?.contents = picture
        }
        if mode.hasPrefix("filters") {
            art.layerUsesCoreImageFilters = true
            art.layer?.filters = [CIFilter(name: "CIAffineClamp"), CIFilter(name: "CIGaussianBlur", parameters: [kCIInputRadiusKey: radius])]
                .compactMap { $0 }
        } else if mode.hasPrefix("blur"), mode != "blur-outset" {
            // The blur alone, no clamp (its output has a finite extent).
            art.layerUsesCoreImageFilters = true
            art.layer?.filters = [CIFilter(name: "CIGaussianBlur", parameters: [kCIInputRadiusKey: radius])].compactMap { $0 }
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            await self.capture("initial")
            // A resize in steps, like a live resize, then a settle.
            for step in 1...10 {
                var f = self.window.frame
                f.size = NSSize(width: 900 + 50 * step, height: 560 + 30 * step)
                self.window.setFrame(f, display: true)
                try? await Task.sleep(for: .milliseconds(50))
            }
            try? await Task.sleep(for: .seconds(1.5))
            await self.capture("resized")
            exit(0)
        }
    }

    @MainActor func capture(_ label: String) async {
        let wid = CGWindowID(window.windowNumber)
        let path = out.appendingPathComponent("\(mode)-\(label).png").path
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        p.arguments = ["-x", "-o", "-l\(wid)", path]
        try? p.run(); p.waitUntilExit()
        if let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
           let image = CGImageSourceCreateImageAtIndex(src, 0, nil) {
            analyze(image, label: label + " (screencapture)")
            return
        }
        // A process may capture its own windows without a Screen Recording grant (the call is
        // unavailable to Swift on the current SDK, so it is looked up at run time).
        typealias ListImage = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        if let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") {
            let fn = unsafeBitCast(sym, to: ListImage.self)
            // kCGWindowListOptionIncludingWindow = 8, kCGWindowImageBoundsIgnoreFraming = 1 | BestResolution = 8
            if let image = fn(.null, 8, wid, 1 | 8)?.takeRetainedValue(), image.width > 10 {
                if let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, "public.png" as CFString, 1, nil) {
                    CGImageDestinationAddImage(dest, image, nil); CGImageDestinationFinalize(dest)
                }
                analyze(image, label: label + " (own-window)")
                return
            }
        }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let scw = content.windows.first(where: { $0.windowID == wid }) else { print("RESULT \(label): window not shareable"); return }
            let config = SCStreamConfiguration()
            config.width = Int(window.frame.width * 2); config.height = Int(window.frame.height * 2)
            let image = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: scw), configuration: config)
            analyze(image, label: label + " (sck)")
        } catch { print("RESULT \(label): capture failed \(error)") }
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let runner = Runner()
app.delegate = runner
app.run()
