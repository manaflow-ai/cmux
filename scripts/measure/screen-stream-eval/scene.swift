// The screen stream eval's fixed workload (README.md): one borderless window over the whole main
// display showing a 5000-line code file at 13 pt Menlo, black on white, that runs the same
// timeline for every target once the harness creates GO_FILE:
//
//   settle 3 s  ->  idle 30 s  ->  typing 20 s  ->  scroll 20 s  ->  ocr 8 s  ->  exit
//
// idle: nothing changes. typing: a scripted burst, 12 characters a second typed into the line
// under the top of the view (the same text every run). scroll: the file scrolls down at 600 pt a
// second, a step every display refresh. ocr: back to the top, still; after 3 s the host's own
// screenshot of the display (`screencapture -x -D 1`) goes to SHOT_PNG. Each phase's start and
// end go to PHASES_JSONL on the Unix ms clock the viewers stamp their seconds with.
//
//   swiftc -O -o screen-eval-scene scene.swift
//   screen-eval-scene GO_FILE PHASES_JSONL SHOT_PNG TRUTH_TXT
//
// TRUTH_TXT gets the lines the ocr phase shows, for checking the OCR itself.
// Test hosts only: it covers the menu bar and the Dock while it runs.

import AppKit

let args = CommandLine.arguments
guard args.count == 5 else {
    FileHandle.standardError.write(Data("usage: screen-eval-scene GO_FILE PHASES_JSONL SHOT_PNG TRUTH_TXT\n".utf8))
    exit(2)
}
let (goFile, phasesFile, shotFile, truthFile) = (args[1], args[2], args[3], args[4])

/// The phases in order, in seconds; the harness reads the same names from PHASES_JSONL.
let timeline: [(String, Double)] = [("settle", 3), ("idle", 30), ("typing", 20), ("scroll", 20), ("ocr", 8)]

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

final class Scene: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var scroll: NSScrollView!
    var text: NSTextView!
    let burst = Array("    let typed = stream.encode(frame, at: latency) // a scripted typing burst ")
    var typedCount = 0
    var timer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let screen = NSScreen.main!
        window = NSWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.level = .screenSaver
        window.backgroundColor = .white
        scroll = NSScrollView(frame: NSRect(origin: .zero, size: screen.frame.size))
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
        window.contentView = scroll
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        try? FileManager.default.removeItem(atPath: phasesFile)
        FileManager.default.createFile(atPath: phasesFile, contents: nil)
        writeTruth()
        // Bounded wait for the harness's GO_FILE (its viewer has its first frame): 120 s.
        let started = Date()
        Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { timer in
            if FileManager.default.fileExists(atPath: goFile) {
                timer.invalidate()
                self.run(0)
            } else if Date().timeIntervalSince(started) > 120 {
                FileHandle.standardError.write(Data("scene: no GO_FILE within 120 s\n".utf8))
                exit(3)
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
    }

    func run(_ index: Int) {
        guard index < timeline.count else { exit(0) }
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
            }
        case "scroll":
            var y: CGFloat = 0
            let step = 600.0 / Double(NSScreen.main?.maximumFramesPerSecond ?? 60)
            timer = Timer.scheduledTimer(withTimeInterval: 1.0 / Double(NSScreen.main?.maximumFramesPerSecond ?? 60), repeats: true) { _ in
                y += step
                self.scrollTo(y)
            }
        case "ocr":
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
        default:
            break
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
            record(phase, start, unixMs())
            self.run(index + 1)
        }
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let scene = Scene()
app.delegate = scene
app.run()
