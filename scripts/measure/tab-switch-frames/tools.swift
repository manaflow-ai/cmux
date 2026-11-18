// The tab switch harness's two Mac tools (scripts/cmux-next/tab_switch_frames.py); neither needs a TCC grant, so a
// copy compiled fresh on every run works. The pixels come from CuaDriver (/Applications/CuaDriver.app), the one
// signed recorder the fleet grants Screen Recording to: it records the main display as an mp4.
//
//   swiftc -O -o tab-switch-tools tools.swift
//
//   tab-switch-tools marker PID
//     A small borderless window in the main display's top-left corner, above every other window, that flips between
//     black and white on command: each flip is one sync mark in the recording. Prints one JSON line once it shows:
//     {"ready": true, "window": [x, y, w, h] (PID's largest on-screen window, points, top-left origin; window bounds
//     need no grant), "display": [...], "scale", "display_hz", "marker": [x, y, w, h]} or {"error": ...}. Then reads
//     stdin: `flip NAME` flips and prints {"flipped": NAME, "n": N}; `window` prints the window line again; `quit`.
//
//   tab-switch-tools windows INTERVAL_MS
//     Every INTERVAL_MS a JSON line {"windows": [{pid, owner, layer, alpha, bounds [x, y, w, h]}]} of every on-screen window
//     (CGWindowList, no grant needed): the harness leaves out rounds a window that is not the app's covered.
//
//   tab-switch-tools decode MP4 OUT X Y W H OUTW MX MY MW MH
//     Every frame of MP4 (AVAssetReader, presentation order): the rect X Y W H (video pixels) scaled to OUTW wide,
//     8-bit gray, appended to OUT as records of an 8-byte little-endian Float64 (the frame's presentation time,
//     seconds) and the gray bytes (tab_switch_judge.read_segment's format); and the marker rect MX MY MW MH's mean
//     gray per frame. Prints {"frames": N, "w": OUTW, "h": OUTH, "fps": F, "video": [W, H], "marker": [[t, mean], ...]}.

import AppKit
import AVFoundation
import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation

setvbuf(stdout, nil, _IOLBF, 0)

func emit(_ object: [String: Any]) {
    if let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
       let line = String(data: data, encoding: .utf8) {
        print(line)
        fflush(stdout)
    }
}

func box(_ rect: CGRect) -> [Double] { [Double(rect.minX), Double(rect.minY), Double(rect.width), Double(rect.height)] }

// MARK: marker

/// PID's largest on-screen window in global points, top-left origin (CGWindowList bounds; no grant needed).
func appWindow(_ pid: Int32) -> CGRect? {
    guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
    var best: CGRect?
    var bestArea: Double = 0
    for info in list {
        guard (info[kCGWindowOwnerPID as String] as? Int32) == pid, (info[kCGWindowLayer as String] as? Int) == 0,
              let bounds = info[kCGWindowBounds as String] as? NSDictionary,
              let rect = CGRect(dictionaryRepresentation: bounds) else { continue }
        let area = Double(rect.width) * Double(rect.height)
        if area > bestArea {
            bestArea = area
            best = rect
        }
    }
    return best
}

final class Marker: NSObject {
    let pid: Int32
    let window: NSWindow
    var white = false
    var flips = 0
    let side: CGFloat = 24

    init(pid: Int32) {
        self.pid = pid
        let screen = NSScreen.screens.first ?? NSScreen.main!
        let frame = NSRect(x: screen.frame.minX, y: screen.frame.maxY - side, width: side, height: side)
        window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        super.init()
        window.level = .screenSaver
        window.isOpaque = true
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.canJoinAllSpaces, .stationary]
        window.backgroundColor = .black
        window.orderFrontRegardless()
    }

    func readyLine() -> [String: Any] {
        let screen = NSScreen.screens.first ?? NSScreen.main!
        let hz = screen.maximumFramesPerSecond > 0 ? Double(screen.maximumFramesPerSecond) : 60
        var fields: [String: Any] = [:]
        fields["ready"] = true
        fields["display"] = box(CGRect(x: 0, y: 0, width: screen.frame.width, height: screen.frame.height))
        fields["scale"] = Double(screen.backingScaleFactor)
        fields["display_hz"] = hz
        fields["marker"] = [0.0, 0.0, Double(side), Double(side)]
        if let rect = appWindow(pid) { fields["window"] = box(rect) } else { fields["window"] = NSNull() }
        return fields
    }

    func flip(_ name: String) {
        white.toggle()
        flips += 1
        window.backgroundColor = white ? .white : .black
        window.displayIfNeeded()
        CATransaction.flush()
        emit(["flipped": name, "n": flips, "white": white])
    }
}

func runMarker(_ pid: Int32) -> Never {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let marker = Marker(pid: pid)
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { emit(marker.readyLine()) }
    Thread.detachNewThread {
        while let line = readLine() {
            let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
            DispatchQueue.main.async {
                switch parts.first {
                case "flip": marker.flip(parts.count == 2 ? parts[1] : "")
                case "window": emit(marker.readyLine())
                case "quit": exit(0)
                default: emit(["error": "unknown command \(line)"])
                }
            }
        }
        DispatchQueue.main.async { exit(0) }
    }
    app.run()
    exit(0)
}

// MARK: decode

func grayRect(_ buffer: CVPixelBuffer, _ rect: CGRect, outW: Int, outH: Int) -> [UInt8] {
    CVPixelBufferLockBaseAddress(buffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
    var out = [UInt8](repeating: 0, count: outW * outH)
    guard let base = CVPixelBufferGetBaseAddress(buffer) else { return out }
    let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
    let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
    let pixels = base.assumingMemoryBound(to: UInt8.self)
    let x0: Double = Double(rect.minX), y0: Double = Double(rect.minY)
    let sx: Double = Double(rect.width) / Double(outW), sy: Double = Double(rect.height) / Double(outH)
    for oy in 0..<outH {
        let yy: Int = min(height - 1, max(0, Int(y0 + (Double(oy) + 0.5) * sy)))
        let row: UnsafeMutablePointer<UInt8> = pixels + yy * rowBytes
        for ox in 0..<outW {
            let xx: Int = min(width - 1, max(0, Int(x0 + (Double(ox) + 0.5) * sx)))
            let p: UnsafeMutablePointer<UInt8> = row + xx * 4 // B, G, R, A
            let r: Int = Int(p[2]) * 77
            let g: Int = Int(p[1]) * 150
            let b: Int = Int(p[0]) * 29
            let luma: Int = (r + g + b) >> 8
            out[oy * outW + ox] = UInt8(luma)
        }
    }
    return out
}

func meanGray(_ buffer: CVPixelBuffer, _ rect: CGRect) -> Double {
    let gray = grayRect(buffer, rect, outW: 8, outH: 8)
    var sum = 0
    for v in gray { sum += Int(v) }
    return Double(sum) / Double(gray.count)
}

func runDecode(_ a: [String]) -> Never {
    // a: [tool, "decode", MP4, OUT, X, Y, W, H, OUTW, MX, MY, MW, MH]
    guard a.count >= 13, let x = Double(a[4]), let y = Double(a[5]), let w = Double(a[6]), let h = Double(a[7]),
          let outW = Int(a[8]), let mx = Double(a[9]), let my = Double(a[10]), let mw = Double(a[11]),
          let mhValue = Double(a[12]), w > 0, h > 0, outW > 0 else {
        emit(["error": "usage: decode MP4 OUT X Y W H OUTW MX MY MW MH"])
        exit(2)
    }
    let asset = AVURLAsset(url: URL(fileURLWithPath: a[2]))
    let semaphore = DispatchSemaphore(value: 0)
    var track: AVAssetTrack?
    var fps: Double = 0
    var natural = CGSize.zero
    Task {
        track = try? await asset.loadTracks(withMediaType: .video).first
        if let track {
            fps = Double((try? await track.load(.nominalFrameRate)) ?? 0)
            natural = (try? await track.load(.naturalSize)) ?? .zero
        }
        semaphore.signal()
    }
    semaphore.wait()
    guard let track, let reader = try? AVAssetReader(asset: asset) else {
        emit(["error": "no video track in \(a[2])"])
        exit(1)
    }
    let output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
    output.alwaysCopiesSampleData = false
    reader.add(output)
    guard reader.startReading() else {
        emit(["error": "cannot read \(a[2]): \(reader.error.map { "\($0)" } ?? "")"])
        exit(1)
    }
    let rect = CGRect(x: x, y: y, width: w, height: h)
    let markerRect = CGRect(x: mx, y: my, width: mw, height: mhValue)
    let outH = max(32, Int((Double(outW) * h / w).rounded()))
    guard FileManager.default.createFile(atPath: a[3], contents: nil), let file = FileHandle(forWritingAtPath: a[3]) else {
        emit(["error": "cannot write \(a[3])"])
        exit(1)
    }
    var frames = 0
    var marks: [[Double]] = []
    while let sample = output.copyNextSampleBuffer() {
        guard let buffer = CMSampleBufferGetImageBuffer(sample) else { continue }
        let t: Double = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample))
        var stamp = t.bitPattern.littleEndian
        var record = Data(bytes: &stamp, count: 8)
        record.append(contentsOf: grayRect(buffer, rect, outW: outW, outH: outH))
        file.write(record)
        marks.append([t, meanGray(buffer, markerRect)])
        frames += 1
    }
    file.closeFile()
    var fields: [String: Any] = [:]
    fields["frames"] = frames
    fields["w"] = outW
    fields["h"] = outH
    fields["fps"] = fps
    fields["video"] = [Double(natural.width), Double(natural.height)]
    fields["marker"] = marks
    emit(fields)
    exit(0)
}

// MARK: windows

/// `tab-switch-tools windows INTERVAL_MS`: every INTERVAL_MS, one JSON line {"windows": [{"pid", "owner", "layer",
/// "alpha", "bounds": [x, y, w, h]}]} of every on-screen window (global points, top-left origin; CGWindowList needs no
/// grant for owners and bounds), front to back. The harness decides which are foreign (tab_switch_foreign.py).
func runWindows(_ intervalMs: Int) -> Never {
    while true {
        var rows: [[String: Any]] = []
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        for info in list {
            guard let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds) else { continue }
            rows.append(["pid": Int(info[kCGWindowOwnerPID as String] as? Int32 ?? 0),
                         "owner": info[kCGWindowOwnerName as String] as? String ?? "",
                         "layer": info[kCGWindowLayer as String] as? Int ?? 0,
                         "alpha": info[kCGWindowAlpha as String] as? Double ?? 1.0,
                         "bounds": box(rect)])
        }
        emit(["windows": rows])
        usleep(UInt32(max(20, intervalMs)) * 1000)
    }
}

let args = CommandLine.arguments
if args.count >= 3, args[1] == "marker", let pid = Int32(args[2]) {
    runMarker(pid)
} else if args.count >= 3, args[1] == "windows", let interval = Int(args[2]) {
    runWindows(interval)
} else if args.count >= 2, args[1] == "decode" {
    runDecode(args)
} else {
    FileHandle.standardError.write(Data("usage: tab-switch-tools marker PID | windows INTERVAL_MS | decode MP4 OUT X Y W H OUTW MX MY MW MH\n".utf8))
    exit(2)
}
