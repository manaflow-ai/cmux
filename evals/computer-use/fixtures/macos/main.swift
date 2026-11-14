// SPDX-License-Identifier: MIT
// CU eval fixture for macOS: a native AppKit app with a real accessibility tree and a
// ground-truth oracle. It replaces the Tk fixture on macOS, where Tk exposes no AX tree and
// takes pointer positions from the hardware pointer (so no tool can drive it in the background).
//
// Modes (same state schema as fixtures/fixture_app.py, so cueval tasks and checks are unchanged):
//   form      "CU Eval Form": name, subscribe, increment + count, answer, Save, 100-row list, slider, code
//   settings  "Eval Settings": one "Enable sync" checkbox (tasks deny this app)
//   person    "Person": takes focus, "types" in-process on a timer, records every key event it receives
//   lab       the matrix fixture: windows "Truth Form" (every standard control, sheet, popover, context
//             menu, tabs, 100-row table), "Truth Text" (text view), "Truth Canvas" (a canvas with no AX
//             element, a drag source and a drop target), "Truth Twin" (a near-identical small form)
//
// The oracle:
//   --state PATH   whole state as JSON, rewritten atomically after every change
//   --events PATH  JSONL, one line per state change and per input event the app receives, each with
//                  wall-clock time t (Unix seconds, same clock as the harness's time.time())
//   --sock PATH    Unix socket; one line in, one JSON line out: "state", "reset", "ping"
//
// Every state event says how it arrived ("via": the type of NSApp.currentEvent when the change ran:
// "mouse", "key", "scroll", "ax" when there was no input event, i.e. an accessibility action).
// Frames are in points, relative to the window's top-left INCLUDING the title bar (the same space as a
// window screenshot), plus "screen" frames in global top-left points.

import AppKit
import Darwin

// MARK: - args

struct Args {
    var mode = "lab"
    var state = "/tmp/cueval-fixture.state.json"
    var events = ""
    var sock = ""
    var geometry = ""
    var code = "0000"
    var title = ""
    var typeIntervalMs = 120
    var activate = false
}

func parseArgs() -> Args {
    var a = Args()
    var it = CommandLine.arguments.dropFirst().makeIterator()
    while let k = it.next() {
        func v() -> String { it.next() ?? "" }
        switch k {
        case "--mode": a.mode = v()
        case "--state": a.state = v()
        case "--events": a.events = v()
        case "--sock": a.sock = v()
        case "--geometry": a.geometry = v()
        case "--code": a.code = v()
        case "--title": a.title = v()
        case "--type-interval-ms": a.typeIntervalMs = Int(v()) ?? 120
        case "--activate": a.activate = true
        case "--wm-class": _ = v()  // Tk compatibility; the bundle carries the app identity on macOS
        default: break
        }
    }
    if a.events.isEmpty { a.events = a.state.replacingOccurrences(of: ".state.json", with: "") + ".events.jsonl" }
    if a.sock.isEmpty { a.sock = a.state.replacingOccurrences(of: ".state.json", with: "") + ".sock" }
    return a
}

let args = parseArgs()

// MARK: - oracle

final class Oracle {
    private var fh: FileHandle?
    private var seq = 0
    var snapshot: () -> [String: Any] = { [:] }
    var suspended = false

    init(path: String) {
        FileManager.default.createFile(atPath: path, contents: nil)
        fh = FileHandle(forWritingAtPath: path)
        fh?.seekToEndOfFile()
    }

    static func via() -> String {
        guard let e = NSApp.currentEvent else { return "ax" }
        switch e.type {
        case .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp,
             .leftMouseDragged, .rightMouseDragged:
            return "mouse"
        case .keyDown, .keyUp, .flagsChanged: return "key"
        case .scrollWheel: return "scroll"
        case .appKitDefined, .systemDefined, .applicationDefined, .periodic: return "ax"
        default: return "other:\(e.type.rawValue)"
        }
    }

    func log(_ kind: String, win: String, el: String, _ fields: [String: Any] = [:]) {
        seq += 1
        var d: [String: Any] = ["t": Date().timeIntervalSince1970, "seq": seq, "kind": kind, "win": win, "el": el,
                                "pid": Int(getpid())]
        for (k, v) in fields { d[k] = v }
        if kind == "state", d["via"] == nil { d["via"] = Oracle.via() }
        if let data = try? JSONSerialization.data(withJSONObject: d, options: [.sortedKeys]) {
            fh?.write(data)
            fh?.write("\n".data(using: .utf8)!)
        }
        if kind == "state" || kind == "focus" { writeState() }
    }

    func writeState() {
        guard !suspended else { return }
        let s = snapshot()
        guard let data = try? JSONSerialization.data(withJSONObject: s, options: [.sortedKeys, .prettyPrinted]) else { return }
        let tmp = args.state + ".tmp"
        FileManager.default.createFile(atPath: tmp, contents: data)
        _ = rename(tmp, args.state)
    }
}

let oracle = Oracle(path: args.events)

// MARK: - geometry helpers

func primaryHeight() -> CGFloat { NSScreen.screens.first?.frame.height ?? 900 }

/// A view's frame relative to its window's top-left, title bar included (window-screenshot space).
func winFrame(_ v: NSView) -> [String: Double] {
    guard let w = v.window else { return [:] }
    let r = v.convert(v.bounds, to: nil)
    let h = w.frame.height
    return ["x": Double(r.minX), "y": Double(h - r.maxY), "w": Double(r.width), "h": Double(r.height)]
}

func screenFrame(_ v: NSView) -> [String: Double] {
    guard let w = v.window else { return [:] }
    let r = v.convert(v.bounds, to: nil)
    return ["x": Double(w.frame.minX + r.minX), "y": Double(primaryHeight() - (w.frame.minY + r.maxY)),
            "w": Double(r.width), "h": Double(r.height)]
}

func windowFrame(_ w: NSWindow) -> [String: Double] {
    ["x": Double(w.frame.minX), "y": Double(primaryHeight() - w.frame.maxY), "w": Double(w.frame.width), "h": Double(w.frame.height)]
}

/// "WxH+X+Y" (Tk style: content size, top-left position in global top-left points).
func placeWindow(_ w: NSWindow, _ geometry: String, defaultSize: NSSize, defaultOrigin: NSPoint) {
    var size = defaultSize, origin = defaultOrigin
    let parts = geometry.split(whereSeparator: { $0 == "x" || $0 == "+" }).compactMap { Double($0) }
    if parts.count >= 2 { size = NSSize(width: parts[0], height: parts[1]) }
    if parts.count >= 4 { origin = NSPoint(x: parts[2], y: parts[3]) }
    w.setContentSize(size)
    w.setFrameTopLeftPoint(NSPoint(x: origin.x, y: primaryHeight() - origin.y))
}

func makeWindow(_ title: String, _ size: NSSize) -> NSWindow {
    let w = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                     styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
    w.title = title
    w.isReleasedWhenClosed = false
    w.contentView = FlippedView(frame: NSRect(origin: .zero, size: size))
    return w
}

final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

// MARK: - small control factory

final class Target: NSObject {
    let fn: (Any?) -> Void
    init(_ fn: @escaping (Any?) -> Void) { self.fn = fn }
    @objc func fire(_ sender: Any?) { fn(sender) }
}

var keepAlive: [AnyObject] = []

func target(_ fn: @escaping (Any?) -> Void) -> Target {
    let t = Target(fn)
    keepAlive.append(t)
    return t
}

func label(_ s: String, _ frame: NSRect, in v: NSView) -> NSTextField {
    let l = NSTextField(labelWithString: s)
    l.frame = frame
    v.addSubview(l)
    return l
}

func field(_ name: String, _ ident: String, _ frame: NSRect, in v: NSView, secure: Bool = false) -> NSTextField {
    let f: NSTextField = secure ? NSSecureTextField(frame: frame) : NSTextField(frame: frame)
    f.identifier = NSUserInterfaceItemIdentifier(ident)
    f.placeholderString = name
    f.setAccessibilityLabel(name)
    f.setAccessibilityIdentifier(ident)
    v.addSubview(f)
    return f
}

func button(_ title: String, _ ident: String, _ frame: NSRect, in v: NSView, type: NSButton.ButtonType = .momentaryPushIn,
            _ fn: @escaping (NSButton) -> Void) -> NSButton {
    let b = NSButton(frame: frame)
    b.title = title
    b.setButtonType(type)
    if type == .momentaryPushIn { b.bezelStyle = .rounded }
    b.identifier = NSUserInterfaceItemIdentifier(ident)
    b.setAccessibilityIdentifier(ident)
    let t = target { s in fn(s as! NSButton) }
    b.target = t
    b.action = #selector(Target.fire(_:))
    v.addSubview(b)
    return b
}

// MARK: - text-change delegate shared by fields

final class FieldDelegate: NSObject, NSTextFieldDelegate {
    let win: String
    let onChange: (String, String) -> Void  // (ident, value)
    init(win: String, _ onChange: @escaping (String, String) -> Void) { self.win = win; self.onChange = onChange }
    func controlTextDidChange(_ n: Notification) {
        guard let f = n.object as? NSTextField else { return }
        onChange(f.identifier?.rawValue ?? "?", f.stringValue)
    }
    func controlTextDidEndEditing(_ n: Notification) {
        guard let f = n.object as? NSTextField else { return }
        onChange(f.identifier?.rawValue ?? "?", f.stringValue)
    }
}

// MARK: - list (NSTableView, 100 rows)

final class ListController: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    let win: String, ident: String, prefix: String
    let table = NSTableView()
    let scroll = NSScrollView()
    var selected: Int? = nil
    var firstVisible = 1
    var onChange: () -> Void = {}

    init(win: String, ident: String, prefix: String, frame: NSRect, in v: NSView) {
        self.win = win; self.ident = ident; self.prefix = prefix
        super.init()
        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("c"))
        col.title = "Items"
        col.width = frame.width - 24
        table.addTableColumn(col)
        table.headerView = nil
        table.rowHeight = 18
        table.dataSource = self
        table.delegate = self
        table.identifier = NSUserInterfaceItemIdentifier(ident)
        table.setAccessibilityIdentifier(ident)
        table.setAccessibilityLabel(ident == "list" ? "Items" : "Rows")
        scroll.frame = frame
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.identifier = NSUserInterfaceItemIdentifier(ident + "_scroll")
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(scrolled(_:)),
                                               name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        v.addSubview(scroll)
    }

    func numberOfRows(in tableView: NSTableView) -> Int { 100 }
    func tableView(_ tv: NSTableView, viewFor col: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("cell")
        let c = (tv.makeView(withIdentifier: id, owner: nil) as? NSTableCellView) ?? {
            let cv = NSTableCellView()
            cv.identifier = id
            let t = NSTextField(labelWithString: "")
            t.translatesAutoresizingMaskIntoConstraints = true
            t.frame = NSRect(x: 2, y: 0, width: 300, height: 17)
            cv.addSubview(t)
            cv.textField = t
            return cv
        }()
        c.textField?.stringValue = "\(prefix) \(row + 1)"
        return c
    }
    func tableViewSelectionDidChange(_ n: Notification) {
        let r = table.selectedRow
        selected = r >= 0 ? r + 1 : nil
        oracle.log("state", win: win, el: ident, ["what": "selected", "value": selected as Any])
        onChange()
    }
    @objc func scrolled(_ n: Notification) {
        let y = scroll.contentView.bounds.minY
        let fv = Int(floor(y / (table.rowHeight + table.intercellSpacing.height))) + 1
        if fv != firstVisible {
            firstVisible = fv
            oracle.log("state", win: win, el: ident, ["what": "first_visible", "value": fv])
            onChange()
        }
    }
    func reset() {
        table.deselectAll(nil)
        selected = nil
        table.scrollRowToVisible(0)
        scroll.contentView.scroll(to: .zero)
        firstVisible = 1
    }
}

// MARK: - the Tk-compatible form ("form" mode, and the twin in lab mode)

final class FormWindow: NSObject {
    let window: NSWindow
    let title: String
    var name: NSTextField!, answer: NSTextField!, subscribe: NSButton!, countLabel: NSTextField!, slider: NSSlider!
    var list: ListController!
    var widgets: [String: NSView] = [:]
    var counter = 0, saved = false, savedName: String? = nil
    var fieldDelegate: FieldDelegate!
    let code: String

    init(title: String, code: String, geometry: String, origin: NSPoint, withList: Bool = true) {
        self.title = title
        self.code = code
        let size = NSSize(width: 420, height: withList ? 520 : 260)
        window = makeWindow(title, size)
        super.init()
        let v = window.contentView!
        fieldDelegate = FieldDelegate(win: title) { [weak self] ident, value in
            oracle.log("state", win: title, el: ident, ["what": "value", "value": value])
            _ = self
        }
        _ = label("Name", NSRect(x: 12, y: 14, width: 60, height: 20), in: v)
        name = field("Name", "name", NSRect(x: 80, y: 12, width: 320, height: 24), in: v)
        name.delegate = fieldDelegate
        name.target = target { [weak self] _ in self?.save(via: "return") }
        name.action = #selector(Target.fire(_:))
        subscribe = button("Subscribe to updates", "subscribe", NSRect(x: 80, y: 44, width: 240, height: 22), in: v, type: .switch) { b in
            oracle.log("state", win: title, el: "subscribe", ["what": "value", "value": b.state == .on])
        }
        let inc = button("Increment", "increment", NSRect(x: 8, y: 72, width: 110, height: 30), in: v) { [weak self] _ in
            guard let self else { return }
            self.counter += 1
            self.countLabel.stringValue = "Count: \(self.counter)"
            oracle.log("state", win: title, el: "increment", ["what": "counter", "value": self.counter])
        }
        countLabel = label("Count: 0", NSRect(x: 130, y: 78, width: 120, height: 20), in: v)
        _ = label("Answer", NSRect(x: 12, y: 114, width: 60, height: 20), in: v)
        answer = field("Answer", "answer", NSRect(x: 80, y: 112, width: 320, height: 24), in: v)
        answer.delegate = fieldDelegate
        let save = button("Save", "save", NSRect(x: 320, y: 144, width: 84, height: 30), in: v) { [weak self] _ in
            self?.save(via: nil)
        }
        widgets = ["name": name, "subscribe": subscribe, "increment": inc, "answer": answer, "save": save]
        if withList {
            list = ListController(win: title, ident: "list", prefix: "Item", frame: NSRect(x: 12, y: 184, width: 396, height: 200), in: v)
            widgets["list"] = list.scroll
            _ = label("Volume", NSRect(x: 12, y: 400, width: 60, height: 20), in: v)
            slider = NSSlider(value: 0, minValue: 0, maxValue: 100, target: nil, action: nil)
            slider.frame = NSRect(x: 80, y: 398, width: 300, height: 24)
            slider.identifier = NSUserInterfaceItemIdentifier("slider")
            slider.setAccessibilityLabel("Volume")
            slider.isContinuous = true
            let st = target { [weak self] _ in
                guard let self else { return }
                oracle.log("state", win: title, el: "slider", ["what": "value", "value": Int(self.slider.doubleValue.rounded())])
            }
            slider.target = st
            slider.action = #selector(Target.fire(_:))
            v.addSubview(slider)
            widgets["slider"] = slider
            let cl = label("Verification code: \(code)", NSRect(x: 12, y: 440, width: 300, height: 20), in: v)
            cl.identifier = NSUserInterfaceItemIdentifier("code")
            widgets["code"] = cl
        }
        placeWindow(window, geometry, defaultSize: size, defaultOrigin: origin)
    }

    func save(via: String?) {
        saved = true
        savedName = name.stringValue
        var f: [String: Any] = ["what": "saved", "value": name.stringValue]
        if let via { f["trigger"] = via }
        oracle.log("state", win: title, el: "save", f)
    }

    func state() -> [String: Any] {
        var widgetFrames: [String: Any] = [:], screen: [String: Any] = [:]
        for (k, v) in widgets { widgetFrames[k] = winFrame(v); screen[k] = screenFrame(v) }
        var s: [String: Any] = [
            "title": title, "name": name.stringValue, "subscribe": subscribe.state == .on, "counter": counter,
            "answer": answer.stringValue, "saved": saved, "saved_name": savedName as Any, "code": code,
            "widgets": widgetFrames, "widgets_screen": screen, "window": windowFrame(window),
            "is_key": window.isKeyWindow, "is_visible": window.isVisible,
        ]
        if let list {
            s["selected"] = list.selected as Any
            s["first_visible"] = list.firstVisible
            s["slider"] = Int(slider.doubleValue.rounded())
        }
        return s
    }

    func reset() {
        oracle.suspended = true
        window.makeFirstResponder(nil)  // end editing first, or the field editor commits its old text back
        name.stringValue = ""; answer.stringValue = ""; subscribe.state = .off
        counter = 0; countLabel.stringValue = "Count: 0"; saved = false; savedName = nil
        list?.reset(); slider?.doubleValue = 0
        window.makeFirstResponder(nil)
        oracle.suspended = false
    }
}

// MARK: - lab: the full-control form

final class LabForm: NSObject, NSTabViewDelegate, NSMenuDelegate {
    let win = "Truth Form"
    let window: NSWindow
    var form: [String: NSView] = [:]
    var name: NSTextField!, password: NSTextField!, subscribe: NSButton!, radios: [NSButton] = []
    var popup: NSPopUpButton!, slider: NSSlider!, stepper: NSStepper!, stepLabel: NSTextField!
    var countLabel: NSTextField!, tabs: NSTabView!, advanced: NSButton!, list: ListController!
    var counter = 0, saved = false, savedName: String? = nil
    var menuCount = 0, nested = 0, disabledFired = 0, contextLast: String? = nil
    var sheetOpen = false, sheetResult: String? = nil, sheetValue: String? = nil
    var popoverOpen = false, popoverActions = 0
    var sheet: NSWindow? = nil, sheetField: NSTextField? = nil
    var popover: NSPopover? = nil
    var popoverObserver: NSObjectProtocol? = nil
    var fieldDelegate: FieldDelegate!
    var contextTarget: NSView!

    override init() {
        window = makeWindow(win, NSSize(width: 540, height: 760))
        super.init()
        let v = window.contentView!
        fieldDelegate = FieldDelegate(win: win) { ident, value in
            oracle.log("state", win: "Truth Form", el: ident, ["what": "value", "value": value])
        }
        var y: CGFloat = 12
        _ = label("Name", NSRect(x: 12, y: y + 2, width: 80, height: 20), in: v)
        name = field("Name", "name", NSRect(x: 100, y: y, width: 300, height: 24), in: v)
        name.delegate = fieldDelegate
        name.target = target { [weak self] _ in self?.save(trigger: "return") }
        name.action = #selector(Target.fire(_:))
        y += 32
        _ = label("Password", NSRect(x: 12, y: y + 2, width: 80, height: 20), in: v)
        password = field("Password", "password", NSRect(x: 100, y: y, width: 300, height: 24), in: v, secure: true)
        password.delegate = fieldDelegate
        y += 32
        subscribe = button("Subscribe to updates", "subscribe", NSRect(x: 100, y: y, width: 240, height: 22), in: v, type: .switch) { b in
            oracle.log("state", win: "Truth Form", el: "subscribe", ["what": "value", "value": b.state == .on])
        }
        y += 28
        _ = label("Size", NSRect(x: 12, y: y + 2, width: 80, height: 20), in: v)
        for (i, s) in ["Small", "Medium", "Large"].enumerated() {
            let r = button(s, "size_\(s.lowercased())", NSRect(x: 100 + CGFloat(i) * 100, y: y, width: 96, height: 22), in: v, type: .radio) { [weak self] b in
                guard let self else { return }
                for o in self.radios where o !== b { o.state = .off }
                oracle.log("state", win: "Truth Form", el: "size", ["what": "value", "value": b.title])
            }
            radios.append(r)
        }
        radios[0].state = .on
        y += 30
        _ = label("Color", NSRect(x: 12, y: y + 3, width: 80, height: 20), in: v)
        popup = NSPopUpButton(frame: NSRect(x: 100, y: y, width: 160, height: 26), pullsDown: false)
        popup.addItems(withTitles: ["Red", "Green", "Blue"])
        popup.identifier = NSUserInterfaceItemIdentifier("color")
        popup.setAccessibilityLabel("Color")
        popup.target = target { [weak self] _ in
            oracle.log("state", win: "Truth Form", el: "color", ["what": "value", "value": self?.popup.titleOfSelectedItem as Any])
        }
        popup.action = #selector(Target.fire(_:))
        v.addSubview(popup)
        y += 34
        _ = label("Volume", NSRect(x: 12, y: y + 2, width: 80, height: 20), in: v)
        slider = NSSlider(value: 0, minValue: 0, maxValue: 100, target: nil, action: nil)
        slider.frame = NSRect(x: 100, y: y, width: 300, height: 24)
        slider.identifier = NSUserInterfaceItemIdentifier("volume")
        slider.setAccessibilityLabel("Volume")
        slider.target = target { [weak self] _ in
            oracle.log("state", win: "Truth Form", el: "volume", ["what": "value", "value": Int((self?.slider.doubleValue ?? 0).rounded())])
        }
        slider.action = #selector(Target.fire(_:))
        v.addSubview(slider)
        y += 32
        _ = label("Copies", NSRect(x: 12, y: y + 2, width: 80, height: 20), in: v)
        stepLabel = label("0", NSRect(x: 100, y: y + 2, width: 40, height: 20), in: v)
        stepper = NSStepper(frame: NSRect(x: 140, y: y, width: 20, height: 26))
        stepper.minValue = 0; stepper.maxValue = 20; stepper.increment = 1; stepper.valueWraps = false
        stepper.identifier = NSUserInterfaceItemIdentifier("copies")
        stepper.setAccessibilityLabel("Copies")
        stepper.target = target { [weak self] _ in
            guard let self else { return }
            self.stepLabel.stringValue = "\(self.stepper.integerValue)"
            oracle.log("state", win: "Truth Form", el: "copies", ["what": "value", "value": self.stepper.integerValue])
        }
        stepper.action = #selector(Target.fire(_:))
        v.addSubview(stepper)
        y += 34
        let inc = button("Increment", "increment", NSRect(x: 8, y: y, width: 110, height: 30), in: v) { [weak self] _ in
            guard let self else { return }
            self.counter += 1
            self.countLabel.stringValue = "Count: \(self.counter)"
            oracle.log("state", win: "Truth Form", el: "increment", ["what": "counter", "value": self.counter])
        }
        countLabel = label("Count: 0", NSRect(x: 130, y: y + 6, width: 100, height: 20), in: v)
        let save = button("Save", "save", NSRect(x: 420, y: y, width: 100, height: 30), in: v) { [weak self] _ in self?.save(trigger: nil) }
        y += 38
        let sheetB = button("Show Sheet", "show_sheet", NSRect(x: 8, y: y, width: 130, height: 30), in: v) { [weak self] _ in self?.showSheet() }
        let popB = button("Show Popover", "show_popover", NSRect(x: 146, y: y, width: 140, height: 30), in: v) { [weak self] b in self?.showPopover(b) }
        let ctx = NSTextField(labelWithString: "Context Target (right-click)")
        ctx.frame = NSRect(x: 300, y: y + 6, width: 220, height: 20)
        ctx.identifier = NSUserInterfaceItemIdentifier("context_target")
        ctx.setAccessibilityLabel("Context Target")
        let m = NSMenu(title: "Context")
        for t in ["Context Alpha", "Context Beta"] {
            let it = NSMenuItem(title: t, action: #selector(Target.fire(_:)), keyEquivalent: "")
            it.target = target { [weak self] _ in
                self?.contextLast = t
                oracle.log("state", win: "Truth Form", el: "context_menu", ["what": "chosen", "value": t])
            }
            m.addItem(it)
        }
        m.delegate = self
        ctx.menu = m
        v.addSubview(ctx)
        contextTarget = ctx
        y += 40
        tabs = NSTabView(frame: NSRect(x: 8, y: y, width: 520, height: 110))
        tabs.identifier = NSUserInterfaceItemIdentifier("tabs")
        let t1 = NSTabViewItem(identifier: "general"); t1.label = "General"
        let g = FlippedView(frame: NSRect(x: 0, y: 0, width: 500, height: 70))
        _ = label("General settings live here.", NSRect(x: 10, y: 10, width: 300, height: 20), in: g)
        t1.view = g
        let t2 = NSTabViewItem(identifier: "advanced"); t2.label = "Advanced"
        let av = FlippedView(frame: NSRect(x: 0, y: 0, width: 500, height: 70))
        advanced = button("Advanced Option", "advanced_option", NSRect(x: 10, y: 10, width: 200, height: 22), in: av, type: .switch) { b in
            oracle.log("state", win: "Truth Form", el: "advanced_option", ["what": "value", "value": b.state == .on])
        }
        t2.view = av
        tabs.addTabViewItem(t1); tabs.addTabViewItem(t2)
        tabs.delegate = self
        v.addSubview(tabs)
        y += 118
        list = ListController(win: win, ident: "table", prefix: "Row", frame: NSRect(x: 8, y: y, width: 520, height: 200), in: v)
        y += 210
        let cl = label("Verification code: \(args.code)", NSRect(x: 12, y: y, width: 300, height: 20), in: v)
        cl.identifier = NSUserInterfaceItemIdentifier("code")
        form = ["name": name, "password": password, "subscribe": subscribe, "size_small": radios[0], "size_medium": radios[1],
                "size_large": radios[2], "color": popup, "volume": slider, "copies": stepper, "increment": inc, "save": save,
                "show_sheet": sheetB, "show_popover": popB, "context_target": ctx, "tabs": tabs, "table": list.scroll, "code": cl]
        placeWindow(window, "", defaultSize: NSSize(width: 540, height: 760), defaultOrigin: NSPoint(x: 120, y: 60))
    }

    var contextOpen = false
    func menuWillOpen(_ menu: NSMenu) {
        contextOpen = true
        oracle.log("state", win: win, el: "context_menu", ["what": "open", "value": true])
    }
    func menuDidClose(_ menu: NSMenu) {
        contextOpen = false
        oracle.log("state", win: win, el: "context_menu", ["what": "open", "value": false])
    }

    func tabView(_ tv: NSTabView, didSelect item: NSTabViewItem?) {
        oracle.log("state", win: win, el: "tabs", ["what": "selected", "value": item?.label as Any])
    }

    func save(trigger: String?) {
        saved = true
        savedName = name.stringValue
        var f: [String: Any] = ["what": "saved", "value": name.stringValue]
        if let trigger { f["trigger"] = trigger }
        oracle.log("state", win: win, el: "save", f)
    }

    func showSheet() {
        guard sheet == nil else { return }
        let s = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 130), styleMask: [.titled], backing: .buffered, defer: false)
        s.title = "Truth Sheet"
        let v = FlippedView(frame: NSRect(x: 0, y: 0, width: 320, height: 130))
        s.contentView = v
        _ = label("Sheet Field", NSRect(x: 12, y: 14, width: 90, height: 20), in: v)
        let f = field("Sheet Field", "sheet_field", NSRect(x: 100, y: 12, width: 200, height: 24), in: v)
        let d = FieldDelegate(win: "Truth Sheet") { ident, value in
            oracle.log("state", win: "Truth Sheet", el: ident, ["what": "value", "value": value])
        }
        keepAlive.append(d)
        f.delegate = d
        sheetField = f
        let ok = button("OK", "sheet_ok", NSRect(x: 220, y: 84, width: 84, height: 30), in: v) { [weak self] _ in self?.endSheet("ok") }
        ok.keyEquivalent = "\r"
        _ = button("Cancel", "sheet_cancel", NSRect(x: 130, y: 84, width: 84, height: 30), in: v) { [weak self] _ in self?.endSheet("cancel") }
        sheet = s
        sheetOpen = true
        oracle.log("state", win: win, el: "sheet", ["what": "open", "value": true])
        window.beginSheet(s) { _ in }
    }

    func endSheet(_ result: String) {
        guard let s = sheet else { return }
        sheetResult = result
        sheetValue = sheetField?.stringValue
        window.endSheet(s)
        s.orderOut(nil)
        sheet = nil
        sheetOpen = false
        oracle.log("state", win: win, el: "sheet", ["what": "closed", "value": result, "field": sheetValue as Any])
    }

    func showPopover(_ anchor: NSButton) {
        if popover?.isShown == true { return }
        let p = NSPopover()
        p.behavior = .transient
        let vc = NSViewController()
        let v = FlippedView(frame: NSRect(x: 0, y: 0, width: 200, height: 60))
        _ = button("Popover Action", "popover_action", NSRect(x: 20, y: 14, width: 160, height: 30), in: v) { [weak self] _ in
            guard let self else { return }
            self.popoverActions += 1
            oracle.log("state", win: self.win, el: "popover_action", ["what": "count", "value": self.popoverActions])
        }
        vc.view = v
        p.contentViewController = vc
        popoverObserver = NotificationCenter.default.addObserver(forName: NSPopover.didCloseNotification, object: p, queue: .main) { [weak self] _ in
            self?.popoverOpen = false
            oracle.log("state", win: "Truth Form", el: "popover", ["what": "open", "value": false])
        }
        popover = p
        p.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
        popoverOpen = true
        oracle.log("state", win: win, el: "popover", ["what": "open", "value": true])
    }

    func state() -> [String: Any] {
        var fr: [String: Any] = [:], sc: [String: Any] = [:]
        for (k, v) in form { fr[k] = winFrame(v); sc[k] = screenFrame(v) }
        return ["title": win, "name": name.stringValue, "password": password.stringValue, "subscribe": subscribe.state == .on,
                "size": radios.first(where: { $0.state == .on })?.title as Any, "color": popup.titleOfSelectedItem as Any,
                "volume": Int(slider.doubleValue.rounded()), "copies": stepper.integerValue, "counter": counter,
                "saved": saved, "saved_name": savedName as Any, "tab": tabs.selectedTabViewItem?.label as Any,
                "advanced_option": advanced.state == .on, "selected": list.selected as Any, "first_visible": list.firstVisible,
                "menu_count": menuCount, "nested": nested, "disabled_fired": disabledFired, "context_last": contextLast as Any,
                "sheet_open": sheetOpen, "sheet_result": sheetResult as Any, "sheet_value": sheetValue as Any,
                "popover_open": popoverOpen, "popover_actions": popoverActions, "context_open": contextOpen,
                "widgets": fr, "widgets_screen": sc, "window": windowFrame(window), "is_key": window.isKeyWindow]
    }

    func reset() {
        oracle.suspended = true
        window.makeFirstResponder(nil)  // end editing first, or the field editor commits its old text back
        if sheet != nil { endSheet("reset") }
        if let o = popoverObserver { NotificationCenter.default.removeObserver(o); popoverObserver = nil }
        popover?.close(); popover = nil; popoverOpen = false
        contextTarget.menu?.cancelTrackingWithoutAnimation()
        NSApp.mainMenu?.cancelTrackingWithoutAnimation()
        name.stringValue = ""; password.stringValue = ""; subscribe.state = .off
        for (i, r) in radios.enumerated() { r.state = i == 0 ? .on : .off }
        popup.selectItem(at: 0); slider.doubleValue = 0; stepper.integerValue = 0; stepLabel.stringValue = "0"
        counter = 0; countLabel.stringValue = "Count: 0"; saved = false; savedName = nil
        tabs.selectTabViewItem(at: 0); advanced.state = .off; list.reset()
        menuCount = 0; nested = 0; disabledFired = 0; contextLast = nil
        sheetResult = nil; sheetValue = nil; popoverActions = 0
        window.makeFirstResponder(nil)
        oracle.suspended = false
    }
}

// MARK: - lab: text window

final class LabText: NSObject, NSTextViewDelegate {
    let win = "Truth Text"
    let window: NSWindow
    let textView: NSTextView
    let scroll: NSScrollView
    static let initial = (1...60).map { "line \($0) the quick brown fox jumps over the lazy dog" }.joined(separator: "\n") + "\n"
    var lastLen = 0

    override init() {
        window = makeWindow(win, NSSize(width: 560, height: 420))
        scroll = NSTextView.scrollableTextView()
        textView = scroll.documentView as! NSTextView
        super.init()
        scroll.frame = window.contentView!.bounds
        scroll.autoresizingMask = [.width, .height]
        textView.isRichText = false
        textView.allowsUndo = true
        textView.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.string = LabText.initial
        textView.delegate = self
        textView.identifier = NSUserInterfaceItemIdentifier("text")
        textView.setAccessibilityIdentifier("text")
        textView.setAccessibilityLabel("Body")
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(scrolled), name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        window.contentView!.addSubview(scroll)
        lastLen = textView.string.utf16.count
        window.initialFirstResponder = textView
        window.makeFirstResponder(textView)
        placeWindow(window, "", defaultSize: NSSize(width: 560, height: 420), defaultOrigin: NSPoint(x: 700, y: 80))
    }

    func textDidChange(_ n: Notification) {
        let s = textView.string
        let len = s.utf16.count
        oracle.log("state", win: win, el: "text", ["what": "text", "len": len, "delta": len - lastLen,
                                                    "tail": String(s.suffix(60)), "sel": textView.selectedRange().location])
        lastLen = len
    }

    func textViewDidChangeSelection(_ n: Notification) {
        let r = textView.selectedRange()
        oracle.log("state", win: win, el: "text", ["what": "selection", "loc": r.location, "len": r.length])
    }

    var lastTop: Int = 0
    @objc func scrolled() {
        let top = Int(scroll.contentView.bounds.minY)
        if abs(top - lastTop) >= 1 {
            lastTop = top
            oracle.log("state", win: win, el: "text", ["what": "scroll", "value": top])
        }
    }

    func state() -> [String: Any] {
        let r = textView.selectedRange()
        return ["title": win, "text": textView.string, "len": textView.string.utf16.count,
                "sel": ["loc": r.location, "len": r.length], "scroll_top": Int(scroll.contentView.bounds.minY),
                "widgets": ["text": winFrame(scroll)], "widgets_screen": ["text": screenFrame(scroll)],
                "window": windowFrame(window), "is_key": window.isKeyWindow,
                "first_responder_is_text": window.firstResponder === textView]
    }

    func reset() {
        oracle.suspended = true
        textView.string = LabText.initial
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        textView.scroll(.zero)
        lastLen = textView.string.utf16.count
        lastTop = 0
        textView.undoManager?.removeAllActions()
        window.makeFirstResponder(textView)
        oracle.suspended = false
    }
}

// MARK: - lab: canvas (no AX element), drag source, drop target

final class CanvasView: NSView {
    var clicks: [[String: Double]] = []
    var keys: [String] = []
    var strokes = 0
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func isAccessibilityElement() -> Bool { false }
    override func accessibilityChildren() -> [Any]? { nil }
    override func accessibilityRole() -> NSAccessibility.Role? { nil }
    override func draw(_ r: NSRect) {
        NSColor(white: 0.95, alpha: 1).setFill(); bounds.fill()
        NSColor.systemBlue.setFill()
        for c in clicks.suffix(50) { NSBezierPath(ovalIn: NSRect(x: c["x"]! - 4, y: c["y"]! - 4, width: 8, height: 8)).fill() }
        NSColor.gray.setStroke(); NSBezierPath(rect: bounds.insetBy(dx: 0.5, dy: 0.5)).stroke()
    }
    override func mouseDown(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        window?.makeFirstResponder(self)
        clicks.append(["x": Double(p.x), "y": Double(p.y), "n": Double(e.clickCount)])
        oracle.log("state", win: "Truth Canvas", el: "canvas", ["what": "click", "x": Double(p.x), "y": Double(p.y),
                                                                  "count": e.clickCount, "n": clicks.count])
        needsDisplay = true
    }
    var dragStart: NSPoint? = nil
    override func mouseDragged(with e: NSEvent) {
        if dragStart == nil { dragStart = convert(e.locationInWindow, from: nil) }
    }
    override func mouseUp(with e: NSEvent) {
        if let s = dragStart {
            let p = convert(e.locationInWindow, from: nil)
            strokes += 1
            oracle.log("state", win: "Truth Canvas", el: "canvas", ["what": "stroke", "from": [s.x, s.y], "to": [p.x, p.y], "n": strokes])
        }
        dragStart = nil
    }
    override func keyDown(with e: NSEvent) {
        keys.append(e.characters ?? "")
        oracle.log("state", win: "Truth Canvas", el: "canvas", ["what": "key", "chars": e.characters ?? "", "n": keys.count])
    }
}

final class ChipView: NSView, NSDraggingSource {
    override var isFlipped: Bool { true }
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func accessibilityLabel() -> String? { "Drag Chip" }
    override func draw(_ r: NSRect) {
        NSColor.systemOrange.setFill(); NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
        ("Drag Chip" as NSString).draw(at: NSPoint(x: 10, y: 8), withAttributes: [.foregroundColor: NSColor.white])
    }
    override func mouseDragged(with e: NSEvent) {
        let item = NSDraggingItem(pasteboardWriter: "truth-chip" as NSString)
        item.setDraggingFrame(bounds, contents: nil)
        oracle.log("state", win: "Truth Canvas", el: "chip", ["what": "drag_started"])
        beginDraggingSession(with: [item], event: e, source: self)
    }
    func draggingSession(_ s: NSDraggingSession, sourceOperationMaskFor c: NSDraggingContext) -> NSDragOperation { .copy }
}

final class DropView: NSView {
    var drops = 0
    var last: String? = nil
    override var isFlipped: Bool { true }
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .group }
    override func accessibilityLabel() -> String? { "Drop Zone" }
    override func draw(_ r: NSRect) {
        (drops > 0 ? NSColor.systemGreen : NSColor(white: 0.85, alpha: 1)).setFill(); bounds.fill()
        ("Drop Zone (\(drops))" as NSString).draw(at: NSPoint(x: 10, y: 10), withAttributes: [:])
    }
    override func draggingEntered(_ s: NSDraggingInfo) -> NSDragOperation { .copy }
    override func performDragOperation(_ s: NSDraggingInfo) -> Bool {
        drops += 1
        last = s.draggingPasteboard.string(forType: .string)
        oracle.log("state", win: "Truth Canvas", el: "drop", ["what": "dropped", "value": last as Any, "n": drops])
        needsDisplay = true
        return true
    }
}

final class LabCanvas: NSObject {
    let win = "Truth Canvas"
    let window: NSWindow
    let canvas: CanvasView, chip: ChipView, drop: DropView

    override init() {
        window = makeWindow(win, NSSize(width: 480, height: 400))
        canvas = CanvasView(frame: NSRect(x: 10, y: 10, width: 460, height: 260))
        chip = ChipView(frame: NSRect(x: 20, y: 300, width: 110, height: 34))
        drop = DropView(frame: NSRect(x: 260, y: 290, width: 200, height: 90))
        super.init()
        drop.registerForDraggedTypes([.string])
        for v in [canvas, chip, drop] as [NSView] { window.contentView!.addSubview(v) }
        placeWindow(window, "", defaultSize: NSSize(width: 480, height: 400), defaultOrigin: NSPoint(x: 760, y: 420))
    }

    func state() -> [String: Any] {
        ["title": win, "canvas_clicks": canvas.clicks, "canvas_keys": canvas.keys, "strokes": canvas.strokes,
         "drops": drop.drops, "drop_value": drop.last as Any,
         "widgets": ["canvas": winFrame(canvas), "chip": winFrame(chip), "drop": winFrame(drop)],
         "widgets_screen": ["canvas": screenFrame(canvas), "chip": screenFrame(chip), "drop": screenFrame(drop)],
         "window": windowFrame(window), "is_key": window.isKeyWindow]
    }

    func reset() {
        canvas.clicks = []; canvas.keys = []; canvas.strokes = 0; drop.drops = 0; drop.last = nil
        canvas.needsDisplay = true; drop.needsDisplay = true
    }
}

// MARK: - settings and person modes

final class SettingsWindow: NSObject {
    let window: NSWindow
    var sync: NSButton!
    init(geometry: String) {
        window = makeWindow("Eval Settings", NSSize(width: 240, height: 120))
        super.init()
        sync = button("Enable sync", "sync", NSRect(x: 20, y: 40, width: 180, height: 22), in: window.contentView!, type: .switch) { b in
            oracle.log("state", win: "Eval Settings", el: "sync", ["what": "value", "value": b.state == .on])
        }
        placeWindow(window, geometry, defaultSize: NSSize(width: 240, height: 120), defaultOrigin: NSPoint(x: 40, y: 600))
    }
    func state() -> [String: Any] {
        ["title": "Eval Settings", "sync": sync.state == .on, "widgets": ["sync": winFrame(sync)],
         "widgets_screen": ["sync": screenFrame(sync)], "window": windowFrame(window), "is_key": window.isKeyWindow]
    }
}

final class PersonWindow: NSObject {
    let window: NSWindow
    let textView: NSTextView
    var typed = "", keysReceived: [String] = [], focusLost = 0, pos = 0
    static let script = Array("the quick brown fox jumps over the lazy dog. ")

    init(geometry: String) {
        window = makeWindow("Person", NSSize(width: 420, height: 260))
        let sv = NSTextView.scrollableTextView()
        textView = sv.documentView as! NSTextView
        super.init()
        sv.frame = window.contentView!.bounds
        sv.autoresizingMask = [.width, .height]
        textView.setAccessibilityLabel("Notes")
        window.contentView!.addSubview(sv)
        placeWindow(window, geometry, defaultSize: NSSize(width: 420, height: 260), defaultOrigin: NSPoint(x: 520, y: 40))
    }

    func tick() {
        let ch = PersonWindow.script[pos % PersonWindow.script.count]
        pos += 1
        // In-process insertion, never a key event: any key event this app sees came from outside.
        textView.textStorage?.append(NSAttributedString(string: String(ch)))
        typed.append(ch)
        if pos % 10 == 0 { oracle.writeState() }
    }

    func state() -> [String: Any] {
        ["title": "Person", "typed": typed, "keys_received": keysReceived, "focus_lost": focusLost,
         "has_focus": NSApp.isActive && window.isKeyWindow, "window": windowFrame(window),
         "widgets": ["notes": winFrame(textView.enclosingScrollView ?? textView)]]
    }
}

// MARK: - socket (state / reset / ping)

final class ControlSocket {
    let path: String
    var handler: (String) -> String = { _ in "{}" }
    init(path: String) { self.path = path }

    func start() {
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8.prefix(103))
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            for (i, b) in bytes.enumerated() { raw[i] = b }
            raw[bytes.count] = 0
        }
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard ok == 0, listen(fd, 8) == 0 else { close(fd); return }
        Thread.detachNewThread { [self] in
            while true {
                let c = accept(fd, nil, nil)
                if c < 0 { continue }
                var buf = [UInt8](repeating: 0, count: 4096)
                var line = ""
                while !line.contains("\n") {
                    let n = read(c, &buf, buf.count)
                    if n <= 0 { break }
                    line += String(decoding: buf[0..<n], as: UTF8.self)
                }
                let cmd = line.trimmingCharacters(in: .whitespacesAndNewlines)
                var out = "{}"
                DispatchQueue.main.sync { out = self.handler(cmd) }
                let data = Array((out + "\n").utf8)
                var off = 0
                while off < data.count {
                    let n = data[off...].withUnsafeBufferPointer { write(c, $0.baseAddress, $0.count) }
                    if n <= 0 { break }
                    off += n
                }
                close(c)
            }
        }
    }
}

// MARK: - app

final class App: NSObject, NSApplicationDelegate {
    var form: FormWindow?, twin: FormWindow?, lab: LabForm?, text: LabText?, canvas: LabCanvas?
    var settings: SettingsWindow?, person: PersonWindow?
    var timer: Timer?
    let sock = ControlSocket(path: args.sock)

    func windows() -> [NSWindow] {
        [lab?.window, text?.window, canvas?.window, twin?.window, form?.window, settings?.window, person?.window].compactMap { $0 }
    }

    func buildMenus() {
        let main = NSMenu()
        let appItem = NSMenuItem(); main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        let editItem = NSMenuItem(); main.addItem(editItem)
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        if let lab {
            let tItem = NSMenuItem(); main.addItem(tItem)
            let t = NSMenu(title: "Truth")
            t.autoenablesItems = false
            let inc = NSMenuItem(title: "Increment Counter", action: #selector(Target.fire(_:)), keyEquivalent: "k")
            inc.keyEquivalentModifierMask = [.command, .shift]
            inc.target = target { _ in
                lab.menuCount += 1
                lab.counter += 1
                lab.countLabel.stringValue = "Count: \(lab.counter)"
                oracle.log("state", win: "Truth Form", el: "menu_increment", ["what": "counter", "value": lab.counter, "menu_count": lab.menuCount])
            }
            t.addItem(inc)
            let more = NSMenuItem(title: "More", action: nil, keyEquivalent: "")
            let sub = NSMenu(title: "More")
            let nested = NSMenuItem(title: "Nested Action", action: #selector(Target.fire(_:)), keyEquivalent: "")
            nested.target = target { _ in
                lab.nested += 1
                oracle.log("state", win: "Truth Form", el: "menu_nested", ["what": "count", "value": lab.nested])
            }
            sub.addItem(nested)
            more.submenu = sub
            t.addItem(more)
            let dis = NSMenuItem(title: "Disabled Item", action: #selector(Target.fire(_:)), keyEquivalent: "")
            dis.target = target { _ in
                lab.disabledFired += 1
                oracle.log("state", win: "Truth Form", el: "menu_disabled", ["what": "fired", "value": lab.disabledFired])
            }
            dis.isEnabled = false
            t.addItem(dis)
            tItem.submenu = t
        }
        NSApp.mainMenu = main
    }

    func snapshot() -> [String: Any] {
        var s: [String: Any] = ["mode": args.mode, "pid": Int(getpid()), "app_active": NSApp.isActive,
                                "frame_origin": "window_top_left_incl_titlebar", "t": Date().timeIntervalSince1970]
        if let form { for (k, v) in form.state() { s[k] = v } }
        if let settings { for (k, v) in settings.state() { s[k] = v } }
        if let person { for (k, v) in person.state() { s[k] = v } }
        if let lab {
            s["title"] = "Truth Form"
            s["form"] = lab.state()
            s["text"] = text?.state()
            s["canvas"] = canvas?.state()
            s["twin"] = twin?.state()
            s["key_window"] = NSApp.keyWindow?.title as Any
            s["windows"] = windows().map { ["title": $0.title, "frame": windowFrame($0), "number": $0.windowNumber,
                                             "visible": $0.isVisible, "key": $0.isKeyWindow] }
        }
        if args.mode != "lab", let w = windows().first { s["has_focus"] = s["has_focus"] ?? (NSApp.isActive && w.isKeyWindow); _ = w }
        return s
    }

    func applicationDidFinishLaunching(_ n: Notification) {
        switch args.mode {
        case "form":
            form = FormWindow(title: args.title.isEmpty ? "CU Eval Form" : args.title, code: args.code,
                              geometry: args.geometry, origin: NSPoint(x: 40, y: 40))
        case "settings":
            settings = SettingsWindow(geometry: args.geometry)
        case "person":
            person = PersonWindow(geometry: args.geometry)
        default:
            lab = LabForm()
            text = LabText()
            canvas = LabCanvas()
            twin = FormWindow(title: "Truth Twin", code: "9999", geometry: "", origin: NSPoint(x: 140, y: 560), withList: false)
            twin?.name.setAccessibilityLabel("Name")
        }
        buildMenus()
        oracle.snapshot = { [weak self] in self?.snapshot() ?? [:] }
        for w in windows() { w.orderFront(nil) }
        let nc = NotificationCenter.default
        for (name, what) in [(NSWindow.didBecomeKeyNotification, "became_key"), (NSWindow.didResignKeyNotification, "resigned_key"),
                             (NSWindow.didBecomeMainNotification, "became_main")] {
            nc.addObserver(forName: name, object: nil, queue: .main) { n in
                guard let w = n.object as? NSWindow else { return }
                oracle.log("focus", win: w.title, el: "window", ["what": what])
            }
        }
        nc.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            oracle.log("focus", win: "", el: "app", ["what": "became_active"])
        }
        nc.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            if let p = self?.person { p.focusLost += 1 }
            oracle.log("focus", win: "", el: "app", ["what": "resigned_active"])
        }
        // Every input event the app receives, before AppKit dispatches it.
        NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .keyDown,
                                                    .scrollWheel, .leftMouseDragged]) { [weak self] e in
            var f: [String: Any] = ["type": "\(e.type.rawValue)", "loc": [Double(e.locationInWindow.x), Double(e.locationInWindow.y)],
                                    "mods": e.modifierFlags.intersection(.deviceIndependentFlagsMask).rawValue]
            if e.type == .keyDown { f["chars"] = e.characters ?? ""; f["code"] = Int(e.keyCode) }
            if e.type == .scrollWheel { f["dy"] = Double(e.scrollingDeltaY) }
            if e.type == .leftMouseDown || e.type == .rightMouseDown { f["clicks"] = e.clickCount }
            if let w = e.window {
                f["win_h"] = Double(w.frame.height)
                // the same point in window-screenshot space (top-left, title bar included)
                f["pt"] = [Double(e.locationInWindow.x), Double(w.frame.height - e.locationInWindow.y)]
            }
            oracle.log("input", win: e.window?.title ?? "", el: "event", f)
            if let p = self?.person, e.type == .keyDown {
                p.keysReceived.append(e.charactersIgnoringModifiers ?? "?")
                oracle.writeState()
                return nil  // the person's field takes no outside keys
            }
            return e
        }
        sock.handler = { [weak self] cmd in
            guard let self else { return "{}" }
            switch cmd {
            case "ping": return "{\"ok\":true}"
            case "reset":
                self.lab?.reset(); self.text?.reset(); self.canvas?.reset(); self.twin?.reset(); self.form?.reset()
                oracle.log("reset", win: "", el: "", [:])
                oracle.writeState()
                return "{\"ok\":true,\"t\":\(Date().timeIntervalSince1970)}"
            default:
                let d = (try? JSONSerialization.data(withJSONObject: self.snapshot(), options: [.sortedKeys])) ?? Data()
                return String(decoding: d, as: UTF8.self)
            }
        }
        sock.start()
        if let person {
            NSApp.activate(ignoringOtherApps: true)
            person.window.makeKeyAndOrderFront(nil)
            person.window.makeFirstResponder(person.textView)
            timer = Timer.scheduledTimer(withTimeInterval: Double(args.typeIntervalMs) / 1000, repeats: true) { _ in person.tick() }
        } else if args.activate {
            NSApp.activate(ignoringOtherApps: true)
        }
        oracle.log("ready", win: "", el: "", ["mode": args.mode])
        oracle.writeState()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { oracle.writeState() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { false }
}

let app = NSApplication.shared
let delegate = App()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
