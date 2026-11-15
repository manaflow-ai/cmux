// The screen stream eval's fixed workload (README.md): one borderless window over the whole main
// display showing a 5000-line code file at 13 pt Menlo, black on white, that runs the same
// timeline for every target once the harness creates GO_FILE:
//
//   settle 3 s -> idle 30 s -> typing 20 s -> scroll 20 s -> [pinned video 20 s] -> ocr 8 s -> hold
//
// hold: the ocr screen stays, still, until the harness creates STOP_FILE (the viewer saves its
// last frame after the timeline), then the scene exits; at most 120 s.
// idle: nothing changes. typing: a scripted burst, 12 characters a second typed into the line
// under the top of the view (the same text every run). scroll: the file scrolls down at 600 pt a
// second, a step every display refresh. ocr: back to the top, still; after 3 s the host's own
// screenshot of the display (`screencapture -x -D 1`) goes to SHOT_PNG. Each phase's start and
// end go to PHASES_JSONL on the Unix ms clock the viewers stamp their seconds with.
//
//   swiftc -O -o screen-eval-scene scene.swift
//   screen-eval-scene GO_FILE STOP_FILE PHASES_JSONL SHOT_PNG TRUTH_TXT
//
// TRUTH_TXT gets the lines the ocr phase shows, for checking the OCR itself.
// Test hosts only: it covers the menu bar and the Dock while it runs.

import AppKit
import AVFoundation
import CoreImage
import CryptoKit

let args = CommandLine.arguments
guard args.count == 6 else {
    FileHandle.standardError.write(Data("usage: screen-eval-scene GO_FILE STOP_FILE PHASES_JSONL SHOT_PNG TRUTH_TXT\n".utf8))
    exit(2)
}
let (goFile, stopFile, phasesFile, shotFile, truthFile) = (args[1], args[2], args[3], args[4], args[5])
let videoPath = ProcessInfo.processInfo.environment["EVAL_VIDEO_PATH"] ?? ""
let videoSHA = ProcessInfo.processInfo.environment["EVAL_VIDEO_SHA256"] ?? ""

// The host chooses a fresh nonce per repeat. Byte pairs form little-endian
// words: 001122...eeff paints 0x1100, 0x3322, ..., 0xffee, LSB first.
let sceneNonce = ProcessInfo.processInfo.environment["EVAL_SCENE_NONCE"] ?? ""
var nonceWords: [UInt16] = []
if !sceneNonce.isEmpty {
    let chars = Array(sceneNonce)
    guard chars.count == 32, chars.allSatisfy({ "0123456789abcdef".contains($0) }) else {
        FileHandle.standardError.write(Data("scene: source nonce must be 32 lowercase hex characters\n".utf8))
        exit(2)
    }
    let bytes = stride(from: 0, to: 32, by: 2).compactMap { UInt8(String(chars[$0 ..< $0 + 2]), radix: 16) }
    nonceWords = stride(from: 0, to: 16, by: 2).map { UInt16(bytes[$0]) | (UInt16(bytes[$0 + 1]) << 8) }
}

/// Counter plus eight static nonce rows, sharing the observer's 20-cell layout.
/// A workload change requests a frame; only drawing it advances the counter.
final class SourceMarkerView: NSView {
    var cell: CGFloat = 16
    var topInset: CGFloat = 0
    var counter: UInt16 = 0
    var pendingFrame = false
    var videoRect: NSRect = .zero
    var videoImage: CGImage?
    var pendingVideo = false
    var presentedVideoFrames = 0
    override var isFlipped: Bool { true }

    func requestFrame() {
        pendingFrame = true
        setNeedsDisplay(NSRect(x: 0, y: topInset, width: 20 * cell, height: cell))
    }

    func presentVideo(_ image: CGImage) {
        videoImage = image
        pendingVideo = true
        pendingFrame = true
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        if pendingFrame { counter &+= 1; pendingFrame = false }
        if pendingVideo { presentedVideoFrames += 1; pendingVideo = false }
        NSColor.white.setFill()
        dirtyRect.fill()
        if let videoImage {
            NSColor.black.setFill()
            videoRect.fill()
            let scale = min(videoRect.width / CGFloat(videoImage.width), videoRect.height / CGFloat(videoImage.height))
            let size = NSSize(width: CGFloat(videoImage.width) * scale, height: CGFloat(videoImage.height) * scale)
            let rect = NSRect(x: videoRect.midX - size.width / 2, y: videoRect.midY - size.height / 2, width: size.width, height: size.height)
            NSImage(cgImage: videoImage, size: size).draw(in: rect, from: .zero, operation: .copy, fraction: 1, respectFlipped: true, hints: nil)
        }
        for (row, word) in ([counter] + nonceWords).enumerated() {
            for column in 0 ..< 20 {
                let white = column < 16 ? (word >> UInt16(column)) & 1 == 1 : [true, false, true, false][column - 16]
                (white ? NSColor.white : NSColor.black).setFill()
                NSRect(x: CGFloat(column) * cell, y: topInset + CGFloat(row) * cell, width: cell, height: cell).fill()
            }
        }
    }
}

/// The phases in order, in seconds; the harness reads the same names from PHASES_JSONL.
let timeline: [(String, Double)] = [("settle", 3), ("idle", 30), ("typing", 20), ("scroll", 20)]
    + (videoPath.isEmpty ? [] : [("video", 20)]) + [("ocr", 8)]

/// A deterministic 5000-line Swift-like file, so every run and every target sees the same text.
func codeFile() -> String {
    let words = ["let", "var", "func", "return", "guard", "struct", "stream", "encoder", "frame", "bitrate",
                 "viewer", "host", "decode", "latency", "pixel", "buffer", "display", "capture", "packet", "queue"]
    var rng: UInt64 = 0x9E37_79B9_7F4A_7C15
    func next() -> Int {
        rng ^= rng << 13; rng ^= rng >> 7; rng ^= rng << 17
        return Int(rng % 1_000_003)
    }
    var lines: [String] = []
    for i in 1 ... 5000 {
        let indent = String(repeating: "    ", count: next() % 3)
        let a = words[next() % words.count], b = words[next() % words.count], c = words[next() % words.count]
        switch next() % 4 {
        case 0: lines.append("\(indent)let \(a)\(i % 97) = \(b).\(c)(\(next() % 4096), at: \(next() % 60))")
        case 1: lines.append("\(indent)func \(a)\(b.capitalized)(_ \(c): Int) -> Int { \(c) * \(next() % 512) }")
        case 2: lines.append("\(indent)// \(a) \(b) \(c): line \(i), \(next() % 100) ms")
        default: lines.append("\(indent)guard \(a) != nil else { return \(b).\(c)[\(next() % 1024)] }")
        }
    }
    return lines.joined(separator: "\n")
}

func record(_ phase: String, _ start: UInt64, _ end: UInt64) {
    let line = "{\"phase\":\"\(phase)\",\"start_unix_ms\":\(start),\"end_unix_ms\":\(end)}\n"
    if let handle = FileHandle(forWritingAtPath: phasesFile) {
        handle.seekToEndOfFile()
        handle.write(Data(line.utf8))
        handle.closeFile()
    }
}

func unixMs() -> UInt64 { UInt64(Date().timeIntervalSince1970 * 1000) }

@MainActor
final class Scene: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var scroll: NSScrollView!
    var text: NSTextView!
    var marker: SourceMarkerView?
    var videoPlayer: AVPlayer?
    var videoOutput: AVPlayerItemVideoOutput?
    var videoInfo: [String: Any] = [:]
    var videoContext: CIContext?
    let burst = Array("    let typed = stream.encode(frame, at: latency) // a scripted typing burst ")
    var typedCount = 0
    var timer: Timer?

    func prepareVideo() async throws {
        guard !videoPath.isEmpty else {
            if !videoSHA.isEmpty { FileHandle.standardError.write(Data("scene: video path and checksum must be paired\n".utf8)); exit(2) }
            return
        }
        guard videoPath.hasPrefix("/"), videoSHA.count == 64,
              videoSHA.allSatisfy({ "0123456789abcdef".contains($0) }), !nonceWords.isEmpty,
              ProcessInfo.processInfo.environment["EVAL_VIDEO_METADATA"] != nil else {
            FileHandle.standardError.write(Data("scene: video needs an absolute prebuilt path, SHA256, source marker, and metadata path\n".utf8))
            exit(2)
        }
        do {
            let path = videoPath, stop = stopFile
            let actual = try await Task.detached(priority: .utility) {
                let file = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
                defer { try? file.close() }
                var hasher = SHA256()
                while let block = try file.read(upToCount: 1_048_576), !block.isEmpty {
                    if FileManager.default.fileExists(atPath: stop) { exit(3) }
                    hasher.update(data: block)
                }
                return hasher.finalize().map { String(format: "%02x", $0) }.joined()
            }.value
            guard actual == videoSHA else {
                FileHandle.standardError.write(Data("scene: video checksum mismatch; no workload started\n".utf8))
                exit(2)
            }
        } catch {
            FileHandle.standardError.write(Data("scene: cannot verify prebuilt video: \(error)\n".utf8))
            exit(2)
        }
        // This preparation runs before showing the source scene or starting a phase.
        // No network URL, generated substitute, or video download is accepted.
        let asset = AVURLAsset(url: URL(fileURLWithPath: videoPath))
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            FileHandle.standardError.write(Data("scene: pinned asset has no video track\n".utf8)); exit(2)
        }
        let duration = CMTimeGetSeconds(try await asset.load(.duration))
        let size = try await track.load(.naturalSize)
        let fps = Double(try await track.load(.nominalFrameRate))
        guard duration.isFinite, duration >= 20, size.width.isFinite, size.height.isFinite,
              size.width > 0, size.height > 0, fps.isFinite, fps > 0 else {
            FileHandle.standardError.write(Data("scene: pinned video must have valid dimensions/fps and at least 20 seconds\n".utf8)); exit(2)
        }
        let item = AVPlayerItem(asset: asset)
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        output.suppressesPlayerRendering = true
        item.add(output)
        let player = AVPlayer(playerItem: item)
        player.isMuted = true
        player.automaticallyWaitsToMinimizeStalling = false
        videoPlayer = player
        videoOutput = output
        videoContext = CIContext()
        videoInfo = ["sha256": videoSHA, "width": Int(size.width), "height": Int(size.height),
                     "nominal_fps": fps, "duration_s": duration, "selected_start_s": 0,
                     "selected_duration_s": 20, "muted": true]
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task {
            do {
                try await prepareVideo()
                showScene()
            } catch {
                FileHandle.standardError.write(Data("scene: cannot prepare pinned video: \(error)\n".utf8))
                exit(2)
            }
        }
    }

    func showScene() {
        let screen = NSScreen.main!
        window = NSWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.level = .screenSaver
        window.backgroundColor = .white
        scroll = NSScrollView(frame: NSRect(origin: .zero, size: screen.frame.size))
        let content = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        if !nonceWords.isEmpty {
            let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID ?? CGMainDisplayID()
            let mode = CGDisplayCopyDisplayMode(id)
            let pixelsWide = CGFloat(mode?.pixelWidth ?? Int(screen.frame.width))
            let pixelsHigh = CGFloat(mode?.pixelHeight ?? Int(screen.frame.height))
            let scale = min(3840 / pixelsWide, 2160 / pixelsHigh, 1)
            let streamedWidth = CGFloat(Int((pixelsWide * scale).rounded()) & ~1)
            let cell = 32 * screen.frame.width / streamedWidth
            let topInset = screen.frame.maxY - screen.visibleFrame.maxY
            let reserved = topInset + 9 * cell
            guard reserved + 32 < screen.frame.height, 20 * cell <= screen.frame.width else {
                FileHandle.standardError.write(Data("scene: display is too small for the source marker and text\n".utf8))
                exit(2)
            }
            let marker = SourceMarkerView(frame: content.bounds)
            marker.cell = cell
            marker.topInset = topInset
            marker.videoRect = NSRect(x: 0, y: reserved, width: screen.frame.width, height: screen.frame.height - reserved)
            self.marker = marker
            scroll.frame.size.height -= reserved
            content.addSubview(marker)
            // Points describe source layout only. Viewer capture pixels require
            // separate calibration; SCK and screencapture need not share a scale.
            let geometry: [String: Any] = [
                "schema": "cmux.source-scene/1", "nonce": sceneNonce,
                "display_size_points": [screen.frame.width, screen.frame.height],
                "marker_origin_points": [0, topInset], "cell_size_points": cell,
                "content_rect_points": [0, reserved, screen.frame.width, screen.frame.height - reserved],
            ]
            do {
                let data = try JSONSerialization.data(withJSONObject: geometry, options: [.sortedKeys])
                if let path = ProcessInfo.processInfo.environment["EVAL_SCENE_GEOMETRY"] {
                    try data.write(to: URL(fileURLWithPath: path), options: [.atomic])
                }
                FileHandle.standardError.write(data + Data("\n".utf8))
            } catch {
                FileHandle.standardError.write(Data("scene: cannot record source geometry: \(error)\n".utf8))
                exit(2)
            }
        }
        scroll.hasVerticalScroller = false
        scroll.drawsBackground = true
        scroll.backgroundColor = .white
        text = NSTextView(frame: scroll.bounds)
        text.isEditable = false
        text.isSelectable = false
        text.drawsBackground = true
        text.backgroundColor = .white
        text.textContainerInset = NSSize(width: 24, height: 16)
        text.font = NSFont(name: "Menlo", size: 13) ?? .monospacedSystemFont(ofSize: 13, weight: .regular)
        text.textColor = .black
        text.string = codeFile()
        text.isVerticallyResizable = true
        text.autoresizingMask = [.width]
        scroll.documentView = text
        content.addSubview(scroll)
        window.contentView = content
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        try? FileManager.default.removeItem(atPath: phasesFile)
        FileManager.default.createFile(atPath: phasesFile, contents: nil)
        writeTruth()
        if let path = ProcessInfo.processInfo.environment["EVAL_SCENE_READY_FILE"] {
            do { try Data().write(to: URL(fileURLWithPath: path), options: [.atomic]) }
            catch { FileHandle.standardError.write(Data("scene: cannot record source readiness: \(error)\n".utf8)); exit(2) }
        }
        // Bounded wait for the harness's GO_FILE (its viewer has its first frame): 120 s.
        let started = Date()
        Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { timer in
            if FileManager.default.fileExists(atPath: stopFile) {
                timer.invalidate()
                FileHandle.standardError.write(Data("scene: stopped before verified viewer readiness\n".utf8))
                exit(3)
            } else if FileManager.default.fileExists(atPath: goFile) {
                timer.invalidate()
                self.run(0)
            } else if Date().timeIntervalSince(started) > 120 {
                FileHandle.standardError.write(Data("scene: no GO_FILE within 120 s\n".utf8))
                exit(3)
            } else {
                self.marker?.requestFrame()
            }
        }
    }

    /// The lines the top of the view shows, as drawn.
    func writeTruth() {
        let lineHeight = text.layoutManager!.defaultLineHeight(for: text.font!)
        let visible = Int((scroll.contentView.bounds.height - 32) / lineHeight)
        let lines = text.string.split(separator: "\n", omittingEmptySubsequences: false).prefix(max(0, visible))
        try? lines.joined(separator: "\n").write(toFile: truthFile, atomically: true, encoding: .utf8)
    }

    func scrollTo(_ y: CGFloat) {
        scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
        scroll.reflectScrolledClipView(scroll.contentView)
        marker?.requestFrame()
    }

    /// Keeps the ocr screen until STOP_FILE (bounded: 120 s).
    func hold() {
        timer?.invalidate()
        let started = Date()
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
            if FileManager.default.fileExists(atPath: stopFile) { exit(0) }
            if Date().timeIntervalSince(started) > 120 {
                FileHandle.standardError.write(Data("scene: no STOP_FILE within 120 s\n".utf8))
                exit(0)
            }
        }
    }

    func run(_ index: Int) {
        guard index < timeline.count else { return hold() }
        let (phase, seconds) = timeline[index]
        let start = unixMs()
        timer?.invalidate()
        switch phase {
        case "typing":
            // Insert into the second line, at the top of the view: a tiny damage area, like real typing.
            let at = (text.string as NSString).range(of: "\n").location + 1
            timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 12, repeats: true) { _ in
                let ch = String(self.burst[self.typedCount % self.burst.count])
                self.text.textStorage?.replaceCharacters(in: NSRange(location: at + self.typedCount, length: 0), with: ch)
                self.typedCount += 1
                self.marker?.requestFrame()
            }
        case "scroll":
            var y: CGFloat = 0
            let step = 600.0 / Double(NSScreen.main?.maximumFramesPerSecond ?? 60)
            timer = Timer.scheduledTimer(withTimeInterval: 1.0 / Double(NSScreen.main?.maximumFramesPerSecond ?? 60), repeats: true) { _ in
                y += step
                self.scrollTo(y)
            }
        case "ocr":
            videoPlayer?.pause()
            marker?.videoImage = nil
            marker?.needsDisplay = true
            scroll.isHidden = false
            // Undo the typing and scroll back to the top: the screen TRUTH_TXT describes.
            if typedCount > 0 {
                let at = (text.string as NSString).range(of: "\n").location + 1
                text.textStorage?.replaceCharacters(in: NSRange(location: at, length: typedCount), with: "")
                typedCount = 0
            }
            scrollTo(0)
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                let shot = Process()
                shot.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                shot.arguments = ["-x", "-D", "1", shotFile]
                try? shot.run()
            }
        case "video":
            guard let output = videoOutput, let player = videoPlayer, let context = videoContext, let marker else {
                FileHandle.standardError.write(Data("scene: requested video was not prepared\n".utf8)); exit(2)
            }
            scroll.isHidden = true
            marker.presentedVideoFrames = 0
            player.play()
            timer = Timer.scheduledTimer(withTimeInterval: 1.0 / Double(NSScreen.main?.maximumFramesPerSecond ?? 60), repeats: true) { _ in
                let itemTime = output.itemTime(forHostTime: CACurrentMediaTime())
                guard output.hasNewPixelBuffer(forItemTime: itemTime),
                      let pixels = output.copyPixelBuffer(forItemTime: itemTime, itemTimeForDisplay: nil) else { return }
                let frame = CIImage(cvPixelBuffer: pixels)
                guard let image = context.createCGImage(frame, from: frame.extent) else { return }
                // The same draw commits this newly decoded image and its counter.
                // Repeated display ticks without a new image add no source frame.
                marker.presentVideo(image)
            }
        default:
            break
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
            let end = unixMs()
            record(phase, start, end)
            if phase == "video" {
                self.videoInfo["presented_frames"] = self.marker?.presentedVideoFrames ?? 0
                self.videoInfo["start_unix_ms"] = start
                self.videoInfo["end_unix_ms"] = end
                do {
                    let data = try JSONSerialization.data(withJSONObject: self.videoInfo, options: [.sortedKeys])
                    guard let path = ProcessInfo.processInfo.environment["EVAL_VIDEO_METADATA"] else { exit(2) }
                    try data.write(to: URL(fileURLWithPath: path), options: [.atomic])
                } catch { FileHandle.standardError.write(Data("scene: cannot record video receipt: \(error)\n".utf8)); exit(2) }
                if self.marker?.presentedVideoFrames == 0 {
                    FileHandle.standardError.write(Data("scene: no decoded video frame was presented\n".utf8)); exit(3)
                }
            }
            self.run(index + 1)
        }
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let scene = Scene()
app.delegate = scene
app.run()
