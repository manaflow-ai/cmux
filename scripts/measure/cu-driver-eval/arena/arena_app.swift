// The arena's own app (scripts/measure/cu-driver-eval/arena/README.md): one binary, one window per
// task, each writing what the person would see as JSON to STATE after every change, so a checker
// reads the outcome and never the agent's word for it.
//
//   arena-app MODE STATE [SEED]
//
// Modes:
//   form       a sign-up form: Name, Email, a Plan pop-up, an "I agree" box and Submit
//   settings   a preferences window with a General / Appearance / Advanced sidebar; the task's
//              controls (Scrollback lines, Send usage data) are only on Advanced
//   readout    a 6-character code in a normal label (the accessibility tree has it)
//   canvas     the same code drawn into a custom view (no text in the accessibility tree: the
//              model has to read the pixels)
//   modal      opens behind an "Unsaved changes" sheet that must be dismissed before the field
//              under it can be used
//   list       60 invoice rows in a scroll view; only some fit, the target needs scrolling
//   minimized  the form, started minimized into the Dock
//
// SEED picks the code and the target row, so a rep cannot be answered from an earlier one.
// The app is named "Arena" in the menu bar and the window titles say the mode ("Arena Form").
import AppKit

let args = CommandLine.arguments
let modes = ["form", "settings", "readout", "canvas", "modal", "list", "minimized"]
guard args.count >= 3, modes.contains(args[1]) else {
  FileHandle.standardError.write("usage: arena-app \(modes.joined(separator: "|")) STATE [SEED]\n".data(using: .utf8)!)
  exit(2)
}
let mode = args[1]
let stateURL = URL(fileURLWithPath: args[2])
let seed = args.count > 3 ? (UInt64(args[3]) ?? 1) : 1

// A small deterministic generator, so the same SEED gives the same code everywhere.
var rng = seed &* 6364136223846793005 &+ 1442695040888963407
func next() -> UInt64 {
  rng = rng &* 6364136223846793005 &+ 1442695040888963407
  return rng >> 33
}
let alphabet = Array("ACDEFHJKMNPRTUVWXY34679")  // no look-alikes (0/O, 1/I/L, 5/S, 8/B, 2/Z)
let code = String((0..<6).map { _ in alphabet[Int(next() % UInt64(alphabet.count))] })
let targetRow = 30 + Int(next() % 25)  // always below the first screenful

var state: [String: Any] = ["mode": mode, "seed": seed, "pid": ProcessInfo.processInfo.processIdentifier]
func save() {
  state["t"] = Date().timeIntervalSince1970
  guard let data = try? JSONSerialization.data(withJSONObject: state, options: [.sortedKeys, .prettyPrinted]) else { return }
  // Atomic: a temporary file renamed over STATE, which also makes STATE when it is absent.
  try? data.write(to: stateURL, options: .atomic)
}

func label(_ text: String, bold: Bool = false) -> NSTextField {
  let field = NSTextField(labelWithString: text)
  field.font = bold ? .boldSystemFont(ofSize: 13) : .systemFont(ofSize: 13)
  return field
}

func stack(_ views: [NSView], spacing: CGFloat = 10) -> NSStackView {
  let s = NSStackView(views: views)
  s.orientation = .vertical
  s.alignment = .leading
  s.spacing = spacing
  s.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
  return s
}

func row(_ title: String, _ control: NSView) -> NSStackView {
  let l = label(title)
  l.alignment = .right
  l.widthAnchor.constraint(equalToConstant: 110).isActive = true
  let s = NSStackView(views: [l, control])
  s.orientation = .horizontal
  s.spacing = 8
  return s
}

final class Handler: NSObject, NSTextFieldDelegate, NSTableViewDataSource, NSTableViewDelegate {
  var fields: [String: NSTextField] = [:]
  var checks: [String: NSButton] = [:]
  var popups: [String: NSPopUpButton] = [:]
  var done = Set<Int>()

  func controlTextDidChange(_ note: Notification) { sync() }
  func controlTextDidEndEditing(_ note: Notification) { sync() }
  @objc func changed(_ sender: Any?) { sync() }

  func sync() {
    for (key, field) in fields { state[key] = field.stringValue }
    for (key, check) in checks { state[key] = check.state == .on }
    for (key, popup) in popups { state[key] = popup.titleOfSelectedItem ?? "" }
    save()
  }

  @objc func submit(_ sender: Any?) {
    sync()
    state["submitted"] = true
    state["submit_count"] = ((state["submit_count"] as? Int) ?? 0) + 1
    save()
  }

  // list mode
  func numberOfRows(in tableView: NSTableView) -> Int { 60 }
  func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
    if column?.identifier.rawValue == "done" {
      let box = NSButton(checkboxWithTitle: "Paid", target: self, action: #selector(toggled(_:)))
      box.tag = row
      box.state = done.contains(row) ? .on : .off
      box.setAccessibilityLabel("Paid, Invoice \(String(format: "%04d", row + 1))")
      return box
    }
    return label("Invoice \(String(format: "%04d", row + 1))   \(String(format: "$%d.00", 100 + (row * 37) % 900))")
  }
  @objc func toggled(_ sender: NSButton) {
    if sender.state == .on { done.insert(sender.tag) } else { done.remove(sender.tag) }
    state["paid"] = done.sorted().map { String(format: "%04d", $0 + 1) }
    save()
  }
}

// The settings window's sidebar: one pane shown at a time.
final class Sidebar: NSObject {
  let panes: [String: NSView]
  init(_ panes: [String: NSView]) { self.panes = panes }
  @objc func pick(_ sender: NSButton) {
    for (name, pane) in panes { pane.isHidden = name != sender.title }
    state["pane"] = sender.title
    save()
  }
}
var keepSidebar: Sidebar?

// Draws the code as pixels only: the view has no accessibility value or children.
final class CanvasView: NSView {
  override func draw(_ dirtyRect: NSRect) {
    NSColor.windowBackgroundColor.setFill()
    dirtyRect.fill()
    let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 34, weight: .semibold),
                                                .foregroundColor: NSColor.labelColor]
    ("Code  " + code as NSString).draw(at: NSPoint(x: 24, y: bounds.midY - 20), withAttributes: attrs)
  }
  override func isAccessibilityElement() -> Bool { false }
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let handler = Handler()
let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 380),
                      styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
window.title = "Arena " + mode.capitalized
window.isReleasedWhenClosed = false

func formView() -> NSView {
  let name = NSTextField(string: ""), email = NSTextField(string: "")
  for f in [name, email] {
    f.widthAnchor.constraint(equalToConstant: 260).isActive = true
    f.delegate = handler
  }
  name.placeholderString = "Full name"
  email.placeholderString = "name@example.com"
  let plan = NSPopUpButton(frame: .zero, pullsDown: false)
  plan.addItems(withTitles: ["Free", "Pro", "Team", "Enterprise"])
  plan.target = handler
  plan.action = #selector(Handler.changed(_:))
  let agree = NSButton(checkboxWithTitle: "I agree to the terms", target: handler, action: #selector(Handler.changed(_:)))
  let submit = NSButton(title: "Submit", target: handler, action: #selector(Handler.submit(_:)))
  submit.keyEquivalent = "\r"
  handler.fields = ["name": name, "email": email]
  handler.popups = ["plan": plan]
  handler.checks = ["agree": agree]
  state["submitted"] = false
  return stack([label("Create your account", bold: true), row("Name", name), row("Email", email), row("Plan", plan),
                row("", agree), row("", submit)])
}

func settingsView() -> NSView {
  // A sidebar of three panes; each pane is a stack, only one shown at a time.
  let scroll = NSTextField(string: "1000")
  scroll.widthAnchor.constraint(equalToConstant: 90).isActive = true
  scroll.delegate = handler
  let telemetry = NSButton(checkboxWithTitle: "Send usage data", target: handler, action: #selector(Handler.changed(_:)))
  telemetry.state = .on
  let theme = NSPopUpButton(frame: .zero, pullsDown: false)
  theme.addItems(withTitles: ["System", "Light", "Dark"])
  theme.target = handler
  theme.action = #selector(Handler.changed(_:))
  let restore = NSButton(checkboxWithTitle: "Restore windows at launch", target: handler, action: #selector(Handler.changed(_:)))
  handler.fields = ["scrollback": scroll]
  handler.checks = ["telemetry": telemetry, "restore": restore]
  handler.popups = ["theme": theme]
  let panes: [String: NSView] = [
    "General": stack([label("General", bold: true), row("", restore)]),
    "Appearance": stack([label("Appearance", bold: true), row("Theme", theme)]),
    "Advanced": stack([label("Advanced", bold: true), row("Scrollback lines", scroll), row("", telemetry)]),
  ]
  let container = NSView()
  for (_, pane) in panes {
    pane.translatesAutoresizingMaskIntoConstraints = false
    container.addSubview(pane)
    NSLayoutConstraint.activate([pane.topAnchor.constraint(equalTo: container.topAnchor),
                                 pane.leadingAnchor.constraint(equalTo: container.leadingAnchor)])
  }
  container.widthAnchor.constraint(equalToConstant: 340).isActive = true
  container.heightAnchor.constraint(equalToConstant: 300).isActive = true
  let sidebar = Sidebar(panes)
  keepSidebar = sidebar
  var buttons: [NSView] = []
  for name in ["General", "Appearance", "Advanced"] {
    let b = NSButton(radioButtonWithTitle: name, target: sidebar, action: #selector(Sidebar.pick(_:)))
    b.state = name == "General" ? .on : .off
    buttons.append(b)
  }
  for (name, pane) in panes { pane.isHidden = name != "General" }
  state["pane"] = "General"
  let side = stack(buttons, spacing: 6)
  let rule = NSBox()
  rule.boxType = .separator
  let split = NSStackView(views: [side, rule, container])
  split.orientation = .horizontal
  split.alignment = .top
  return split
}

func readoutView(canvas: Bool) -> NSView {
  state["code"] = code
  let note = label("Your one-time code:")
  if canvas {
    let view = CanvasView()
    view.widthAnchor.constraint(equalToConstant: 360).isActive = true
    view.heightAnchor.constraint(equalToConstant: 80).isActive = true
    return stack([note, view])
  }
  let value = label(code, bold: true)
  value.font = .monospacedSystemFont(ofSize: 34, weight: .semibold)
  return stack([note, value])
}

func modalView() -> NSView {
  let field = NSTextField(string: "")
  field.widthAnchor.constraint(equalToConstant: 260).isActive = true
  field.delegate = handler
  field.placeholderString = "Project name"
  let save = NSButton(title: "Save", target: handler, action: #selector(Handler.submit(_:)))
  handler.fields = ["project": field]
  state["submitted"] = false
  state["sheet"] = "open"
  return stack([label("New project", bold: true), row("Project name", field), row("", save)])
}

func listView() -> NSView {
  state["target"] = String(format: "%04d", targetRow + 1)
  state["paid"] = [String]()
  let table = NSTableView()
  for (id, width) in [("name", 300.0), ("done", 120.0)] {
    let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
    column.width = width
    column.title = id == "name" ? "Invoice" : "Status"
    table.addTableColumn(column)
  }
  table.dataSource = handler
  table.delegate = handler
  table.rowHeight = 24
  let scroll = NSScrollView()
  scroll.documentView = table
  scroll.hasVerticalScroller = true
  scroll.heightAnchor.constraint(equalToConstant: 260).isActive = true
  scroll.widthAnchor.constraint(equalToConstant: 460).isActive = true
  return stack([label("Invoices", bold: true), scroll])
}

switch mode {
case "form", "minimized": window.contentView = formView()
case "settings": window.contentView = settingsView()
case "readout": window.contentView = readoutView(canvas: false)
case "canvas": window.contentView = readoutView(canvas: true)
case "modal": window.contentView = modalView()
default: window.contentView = listView()
}
save()

final class AppDelegate: NSObject, NSApplicationDelegate {
  func applicationDidFinishLaunching(_ note: Notification) {
    window.center()
    window.makeKeyAndOrderFront(nil)
    app.activate(ignoringOtherApps: true)
    if mode == "minimized" {
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
        window.miniaturize(nil)
        state["started_minimized"] = true
        save()
      }
    }
    if mode == "modal" {
      let sheet = NSAlert()
      sheet.messageText = "Unsaved changes"
      sheet.informativeText = "The last project was not saved. Discard it and start a new one?"
      sheet.addButton(withTitle: "Discard")
      sheet.addButton(withTitle: "Cancel")
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
        sheet.beginSheetModal(for: window) { response in
          state["sheet"] = response == .alertFirstButtonReturn ? "discarded" : "cancelled"
          save()
          if response != .alertFirstButtonReturn {
            // Cancel puts the question back: the only way forward is Discard.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
              state["sheet"] = "open"
              save()
              sheet.beginSheetModal(for: window) { again in
                state["sheet"] = again == .alertFirstButtonReturn ? "discarded" : "cancelled"
                save()
              }
            }
          }
        }
      }
    }
  }
  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
let delegate = AppDelegate()
app.delegate = delegate
let menu = NSMenu()
let appItem = NSMenuItem()
menu.addItem(appItem)
let appMenu = NSMenu()
appMenu.addItem(withTitle: "Quit Arena", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
appItem.submenu = appMenu
app.mainMenu = menu
app.run()
