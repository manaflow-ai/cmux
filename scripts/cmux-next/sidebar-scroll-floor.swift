// Host floor for the sidebar scroll bench (scripts/cmux-next/sidebar-rows-perf-release.py --floor).
//
// A plain AppKit window with no cmux code: a view-based NSTableView of `--rows` text rows in an
// NSScrollView on the left `--sidebar-width` points of the window, the rest empty. The bench puts it
// in the same frame and screen as the cmux window and sends it the same wheel gesture, so the
// hitches it records are what the host makes by itself.
//
//   swiftc -O -o floor scripts/cmux-next/sidebar-scroll-floor.swift
//   ./floor --frame 40,40,1100,820 [--screen last] [--rows 1000] [--vibrancy] [--fade]
//
// --vibrancy puts a behind-window sidebar material under the rows (clear table background), as the
// cmux sidebar does. --fade adds a top/bottom gradient mask on the scroll view. Both are off by
// default (the plain floor). --opt-out uses an NSScrollView subclass that overrides scrollWheel(with:)
// (it only calls super), which opts the view out of responsive scrolling, as the cmux sidebar's does. The process prints "ready <pid>" when the window is on screen and
// quits on SIGTERM or when stdin closes.
import AppKit

struct Options {
    var frame = CGRect(x: 40, y: 40, width: 1100, height: 820)
    var lastScreen = true
    var rows = 1000
    var rowHeight: CGFloat = 30
    var sidebarWidth: CGFloat = 260
    var vibrancy = false
    var fade = false
    var optOut = false

    init(_ args: [String]) {
        var i = 1
        while i < args.count {
            let key = args[i]
            let value = i + 1 < args.count ? args[i + 1] : ""
            switch key {
            case "--frame":
                let p = value.split(separator: ",").compactMap { Double($0) }
                if p.count == 4 { frame = CGRect(x: p[0], y: p[1], width: p[2], height: p[3]) }
                i += 1
            case "--screen": lastScreen = value == "last"; i += 1
            case "--rows": rows = Int(value) ?? rows; i += 1
            case "--row-height": rowHeight = CGFloat(Double(value) ?? 30); i += 1
            case "--sidebar-width": sidebarWidth = CGFloat(Double(value) ?? 260); i += 1
            case "--vibrancy": vibrancy = true
            case "--fade": fade = true
            case "--opt-out": optOut = true
            default: break
            }
            i += 1
        }
    }
}

/// Overrides scrollWheel(with:) only to call super: AppKit then scrolls on the main thread
/// (no responsive scrolling), like a scroll view that inspects wheel events.
final class OptOutScrollView: NSScrollView {
    override func scrollWheel(with event: NSEvent) { super.scrollWheel(with: event) }
}

final class Rows: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    let count: Int
    init(count: Int) { self.count = count }
    func numberOfRows(in tableView: NSTableView) -> Int { count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("row")
        let cell: NSTableCellView
        if let reused = tableView.makeView(withIdentifier: id, owner: nil) as? NSTableCellView {
            cell = reused
        } else {
            cell = NSTableCellView()
            cell.identifier = id
            let label = NSTextField(labelWithString: "")
            label.translatesAutoresizingMaskIntoConstraints = false
            label.lineBreakMode = .byTruncatingTail
            cell.addSubview(label)
            cell.textField = label
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 12),
                label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
                label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
        }
        cell.textField?.stringValue = String(format: "floor-%04d", row)
        return cell
    }
}

let options = Options(CommandLine.arguments)
let app = NSApplication.shared
app.setActivationPolicy(.regular)
let rows = Rows(count: options.rows)

let screens = NSScreen.screens
let screen = (options.lastScreen ? screens.last : screens.first) ?? NSScreen.main!
let visible = screen.visibleFrame
let width = min(options.frame.width, visible.width)
let height = min(options.frame.height, visible.height)
let rect = CGRect(x: visible.minX + options.frame.minX, y: visible.maxY - options.frame.minY - height,
                  width: width, height: height)
let window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
                      backing: .buffered, defer: false)
window.titlebarAppearsTransparent = true
window.title = "sidebar scroll floor"
window.setFrame(rect, display: false)
window.isReleasedWhenClosed = false

let content = NSView(frame: CGRect(origin: .zero, size: rect.size))
content.wantsLayer = true
window.contentView = content

let sidebarFrame = CGRect(x: 0, y: 0, width: options.sidebarWidth, height: rect.height)
let host: NSView
if options.vibrancy {
    let effect = NSVisualEffectView(frame: sidebarFrame)
    effect.material = .sidebar
    effect.blendingMode = .behindWindow
    effect.state = .followsWindowActiveState
    host = effect
} else {
    host = NSView(frame: sidebarFrame)
}
host.autoresizingMask = [.height]
content.addSubview(host)

let table = NSTableView()
table.headerView = nil
table.rowHeight = options.rowHeight
table.intercellSpacing = .zero
table.style = .plain
table.backgroundColor = options.vibrancy ? .clear : .windowBackgroundColor
let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("c"))
column.width = options.sidebarWidth
table.addTableColumn(column)
table.dataSource = rows
table.delegate = rows

let scrollFrame = CGRect(x: 0, y: 0, width: options.sidebarWidth, height: rect.height - 52)
let scroll: NSScrollView = options.optOut ? OptOutScrollView(frame: scrollFrame) : NSScrollView(frame: scrollFrame)
scroll.autoresizingMask = [.height]
scroll.documentView = table
scroll.hasVerticalScroller = true
scroll.drawsBackground = !options.vibrancy
scroll.wantsLayer = true
if options.fade {
    let mask = CAGradientLayer()
    mask.colors = [NSColor.clear.cgColor, NSColor.black.cgColor, NSColor.black.cgColor, NSColor.clear.cgColor]
    mask.locations = [0, 0.04, 0.96, 1]
    mask.frame = scroll.bounds
    scroll.layer?.mask = mask
}
host.addSubview(scroll)

signal(SIGTERM, SIG_IGN)
let term = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
term.setEventHandler { app.terminate(nil) }
term.resume()
// The bench holds stdin open; its end (the bench ended or died) quits the floor.
FileHandle.standardInput.readabilityHandler = { handle in
    if handle.availableData.isEmpty {
        handle.readabilityHandler = nil
        DispatchQueue.main.async { app.terminate(nil) }
    }
}

window.orderFrontRegardless()
print("ready \(ProcessInfo.processInfo.processIdentifier)")
fflush(stdout)
app.run()
