#!/usr/bin/env swift
// Minimal test: NiriTabBarView in a plain window. Does drag work?
import AppKit
import CoreText

final class TestTabBar: NSView {
    var tabs: [String] = ["Tab 1", "Tab 2", "Tab 3"]
    var selectedIndex = 0
    private var dragSrcIdx: Int?
    private var dragStartX: CGFloat = 0
    private var dragActive = false
    private var dropIdx: Int?

    override var mouseDownCanMoveWindow: Bool { false }
    override var isFlipped: Bool { false }
    override var acceptsFirstResponder: Bool { true }

    var tabWidth: CGFloat { bounds.width / CGFloat(max(1, tabs.count)) }

    func tabIndex(at pt: NSPoint) -> Int? {
        let idx = Int(pt.x / tabWidth)
        return idx >= 0 && idx < tabs.count ? idx : nil
    }

    func insertionIndex(at pt: NSPoint) -> Int {
        max(0, min(tabs.count, Int(pt.x / tabWidth + 0.5)))
    }

    override func mouseDown(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        dragSrcIdx = tabIndex(at: pt)
        dragStartX = pt.x
        dragActive = false
        print("mouseDown pt=\(pt) idx=\(dragSrcIdx ?? -1)")
    }

    override func mouseDragged(with event: NSEvent) {
        guard let src = dragSrcIdx else { return }
        let pt = convert(event.locationInWindow, from: nil)
        if !dragActive && abs(pt.x - dragStartX) > 5 { dragActive = true }
        guard dragActive else { return }
        let ins = insertionIndex(at: pt)
        dropIdx = (ins != src && ins != src + 1) ? ins : nil
        print("mouseDragged pt=\(pt) dropIdx=\(dropIdx ?? -1)")
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        print("mouseUp dragActive=\(dragActive) src=\(dragSrcIdx ?? -1)")
        if dragActive, let src = dragSrcIdx, let ins = dropIdx {
            var dest = ins
            if dest > src { dest -= 1 }
            if dest != src && dest >= 0 && dest < tabs.count {
                let tab = tabs.remove(at: src)
                tabs.insert(tab, at: dest)
                selectedIndex = dest
                print("REORDER: \(src) -> \(dest) tabs=\(tabs)")
            }
        } else if let idx = dragSrcIdx {
            selectedIndex = idx
            print("SELECT: \(idx)")
        }
        dragSrcIdx = nil; dragActive = false; dropIdx = nil
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.setFillColor(CGColor(gray: 0.15, alpha: 1))
        ctx.fill(bounds)

        let tw = tabWidth
        for (i, title) in tabs.enumerated() {
            let x = CGFloat(i) * tw
            if i == selectedIndex {
                ctx.setFillColor(CGColor(gray: 0.25, alpha: 1))
                ctx.fill(CGRect(x: x, y: 0, width: tw, height: bounds.height))
                ctx.setFillColor(CGColor(srgbRed: 0, green: 0.48, blue: 1, alpha: 1))
                ctx.fill(CGRect(x: x, y: 0, width: tw, height: 2))
            }
            if i > 0 {
                ctx.setFillColor(CGColor(gray: 0.3, alpha: 1))
                ctx.fill(CGRect(x: x, y: 5, width: 1, height: bounds.height - 10))
            }
            let font = CTFontCreateWithName("Helvetica Neue" as CFString, 12, nil)
            let attrs: [CFString: Any] = [kCTFontAttributeName: font, kCTForegroundColorFromContextAttributeName: true]
            let str = CFAttributedStringCreate(nil, title as CFString, attrs as CFDictionary)!
            let line = CTLineCreateWithAttributedString(str)
            ctx.saveGState()
            ctx.setFillColor(CGColor(gray: 1, alpha: 0.8))
            ctx.textPosition = CGPoint(x: x + 10, y: bounds.height / 2 - 4)
            CTLineDraw(line, ctx)
            ctx.restoreGState()
        }

        // Drop indicator
        if let di = dropIdx {
            let dx = CGFloat(di) * tw
            ctx.setFillColor(CGColor(srgbRed: 0, green: 0.48, blue: 1, alpha: 1))
            ctx.fill(CGRect(x: dx - 1.5, y: 4, width: 3, height: bounds.height - 8))
        }
    }
}

// -- App --
let app = NSApplication.shared
app.setActivationPolicy(.regular)

let w = NSWindow(contentRect: NSRect(x: 400, y: 400, width: 600, height: 400),
                 styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
w.title = "Tab Bar Test"

let content = NSView(frame: w.contentView!.bounds)
content.autoresizingMask = [.width, .height]
content.wantsLayer = true
content.layer?.backgroundColor = CGColor(gray: 0.1, alpha: 1)

let tabBar = TestTabBar(frame: NSRect(x: 0, y: content.bounds.height - 30, width: content.bounds.width, height: 30))
tabBar.autoresizingMask = [.width, .minYMargin]
content.addSubview(tabBar)

w.contentView = content
w.makeKeyAndOrderFront(nil)
app.activate(ignoringOtherApps: true)

print("Tab bar test running. Click and drag tabs to reorder.")
app.run()
