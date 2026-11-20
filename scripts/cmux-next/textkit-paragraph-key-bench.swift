import AppKit
// The key cost at the end of one long paragraph, TextKit 2 against TextKit 1 (offscreen NSTextView; a key's insert,
// layout and display). Run on a fleet Mac with a GUI session: swiftc -O -o /tmp/tk-para textkit-paragraph-key-bench.swift && /tmp/tk-para
// cmux21, macOS 27, p50: TextKit 2 0.59 / 0.97 / 2.10 / 2.82 ms at 250 / 1000 / 3000 / 6000 characters; TextKit 1 0.33 / 0.32 / 0.34 / 0.45 ms.
@MainActor func run(tk2: Bool, chars: Int) -> (Double, Double) {
    let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
    let sv = NSScrollView(frame: NSRect(x: 0, y: 0, width: 520, height: 295))
    let tv = NSTextView(usingTextLayoutManager: tk2)
    tv.frame = NSRect(x: 0, y: 0, width: 520, height: 295)
    tv.isVerticallyResizable = true; tv.isRichText = false
    tv.font = NSFont.systemFont(ofSize: 13)
    tv.textContainer?.containerSize = NSSize(width: 500, height: CGFloat.greatestFiniteMagnitude)
    tv.textContainer?.widthTracksTextView = false
    tv.isContinuousSpellCheckingEnabled = false
    sv.documentView = tv; w.contentView = sv
    let sentence = "the chief reads your note and starts on the work in a new workspace "
    tv.string = String(String(repeating: sentence, count: chars / sentence.count + 1).prefix(chars))
    tv.setSelectedRange(NSRange(location: (tv.string as NSString).length, length: 0))
    w.makeFirstResponder(tv); w.displayIfNeeded()
    var times: [Double] = []
    for c in "and then it reports back with what it found and more words " {
        let t0 = DispatchTime.now().uptimeNanoseconds
        tv.insertText(String(c), replacementRange: tv.selectedRange())
        w.contentView?.layoutSubtreeIfNeeded(); w.displayIfNeeded(); CATransaction.flush()
        times.append(Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6)
    }
    times.sort()
    return (times[times.count / 2], times[Int(Double(times.count) * 0.95)])
}
MainActor.assumeIsolated {
    _ = NSApplication.shared
    for tk2 in [true, false] { for chars in [250, 1000, 3000, 6000] {
        let (p50, p95) = run(tk2: tk2, chars: chars)
        print(String(format: "%@ %5d chars: key p50 %.3f ms p95 %.3f ms", tk2 ? "TK2" : "TK1", chars, p50, p95))
    } }
}
