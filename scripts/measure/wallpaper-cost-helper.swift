// wallpaper-cost-helper: the two things scripts/measure/wallpaper-cost.py needs from AppKit and AVFoundation.
// wallpaper-cost.py builds it with `xcrun swiftc -O` into its work folder.
//
//   wallpaper-cost-helper clip OUT WIDTH HEIGHT FPS SECONDS h264|hevc MBPS
//       writes a test video (.mp4) with the hardware encoder: a hue sweep, shifting noise and moving bars, so
//       every frame differs and the decoder has real work. Nothing is downloaded.
//   wallpaper-cost-helper cover SECONDS
//       one opaque black window over every screen, above normal windows, for SECONDS (then it exits); prints
//       `cover N` once the windows are up. The bench ends it earlier by its PID.
import AppKit
import AVFoundation
import CoreVideo

let args = CommandLine.arguments

func fail(_ message: String) -> Never {
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
    exit(2)
}

func clip() {
    guard args.count >= 9, let width = Int(args[3]), let height = Int(args[4]), let fps = Int32(args[5]),
          let seconds = Int(args[6]), let mbps = Double(args[8]) else {
        fail("usage: wallpaper-cost-helper clip OUT WIDTH HEIGHT FPS SECONDS h264|hevc MBPS")
    }
    let out = URL(fileURLWithPath: args[2])
    let codec: AVVideoCodecType = args[7] == "hevc" ? .hevc : .h264
    let partial = out.appendingPathExtension("partial.mp4")
    try? FileManager.default.removeItem(at: partial)
    let writer: AVAssetWriter
    do { writer = try AVAssetWriter(outputURL: partial, fileType: .mp4) } catch { fail("writer: \(error)") }
    let compression: [String: Any] = [AVVideoAverageBitRateKey: Int(mbps * 1_000_000),
                                      AVVideoExpectedSourceFrameRateKey: Int(fps),
                                      AVVideoMaxKeyFrameIntervalKey: Int(fps) * 2]
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
        AVVideoCodecKey: codec, AVVideoWidthKey: width, AVVideoHeightKey: height,
        AVVideoCompressionPropertiesKey: compression,
    ])
    input.expectsMediaDataInRealTime = false
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
    ])
    writer.add(input)
    guard writer.startWriting() else { fail("startWriting: \(String(describing: writer.error))") }
    writer.startSession(atSourceTime: .zero)

    // A grey noise tile, drawn shifted every frame at partial opacity: texture the encoder has to spend bits on.
    let tile = 512
    var noise = [UInt8](repeating: 255, count: tile * tile * 4)
    var seed: UInt64 = 0x9E37_79B9_7F4A_7C15
    for index in stride(from: 0, to: noise.count, by: 4) {
        seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        let value = UInt8(truncatingIfNeeded: seed >> 56)
        noise[index] = value; noise[index + 1] = value; noise[index + 2] = value
    }
    let space = CGColorSpaceCreateDeviceRGB()
    guard let provider = CGDataProvider(data: Data(noise) as CFData),
          let noiseImage = CGImage(width: tile, height: tile, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: tile * 4,
                                   space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                                   provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    else { fail("noise image") }

    let frames = Int(fps) * seconds
    for frame in 0..<frames {
        while !input.isReadyForMoreMediaData { usleep(2000) }  // the encoder's backpressure
        var made: CVPixelBuffer?
        guard let pool = adaptor.pixelBufferPool,
              CVPixelBufferPoolCreatePixelBuffer(nil, pool, &made) == kCVReturnSuccess, let buffer = made
        else { fail("pixel buffer") }
        CVPixelBufferLockBaseAddress(buffer, [])
        guard let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { fail("context") }
        let t = Double(frame) / Double(fps)
        let hue = CGFloat((t / 10).truncatingRemainder(dividingBy: 1))
        context.setFillColor(NSColor(calibratedHue: hue, saturation: 0.6, brightness: 0.55, alpha: 1).cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setAlpha(0.35)
        let dx = (frame * 7) % tile, dy = (frame * 3) % tile
        var y = -dy
        while y < height {
            var x = -dx
            while x < width {
                context.draw(noiseImage, in: CGRect(x: x, y: y, width: tile, height: tile))
                x += tile
            }
            y += tile
        }
        context.setAlpha(1)
        for bar in 0..<8 {
            let phase = t * (0.15 + 0.05 * Double(bar)) + Double(bar) / 8
            let x = CGFloat(phase.truncatingRemainder(dividingBy: 1)) * CGFloat(width)
            context.setFillColor(NSColor(calibratedHue: CGFloat(bar) / 8, saturation: 0.8, brightness: 0.9, alpha: 0.8).cgColor)
            context.fill(CGRect(x: x, y: CGFloat(bar) * CGFloat(height) / 8, width: CGFloat(width) / 12, height: CGFloat(height) / 10))
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        if !adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: fps)) {
            fail("append frame \(frame): \(String(describing: writer.error))")
        }
    }
    input.markAsFinished()
    let done = DispatchSemaphore(value: 0)
    writer.finishWriting { done.signal() }
    done.wait()
    guard writer.status == .completed else { fail("finishWriting: \(String(describing: writer.error))") }
    try? FileManager.default.removeItem(at: out)
    do { try FileManager.default.moveItem(at: partial, to: out) } catch { fail("move: \(error)") }
    print("clip \(out.path) \(width)x\(height) \(fps) fps \(seconds) s \(args[7]) \(mbps) Mbps")
}

func cover() {
    let hold = args.count > 2 ? Double(args[2]) ?? 600 : 600
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    var windows: [NSWindow] = []
    for screen in NSScreen.screens {
        let window = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.setFrame(screen.frame, display: false)
        window.backgroundColor = .black
        window.isOpaque = true
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .stationary]
        window.orderFrontRegardless()
        windows.append(window)
    }
    print("cover \(windows.count)")
    fflush(stdout)
    DispatchQueue.main.asyncAfter(deadline: .now() + hold) { exit(0) }
    app.run()
}

switch args.count > 1 ? args[1] : "" {
case "clip": clip()
case "cover": cover()
default: fail("usage: wallpaper-cost-helper clip OUT WIDTH HEIGHT FPS SECONDS h264|hevc MBPS | cover SECONDS")
}
