// ax-tour: a computer-use tour of a tagged cmux-next debug app, driven ONLY through the macOS
// accessibility API (AXUIElement reads and AXPress) plus window screenshots, the way OpenAI
// computer use or cmux-cua sees the app. It proves that an agent can find every step's control by
// its stable `cmux.<area>.<control>` identifier and that each step's result shows in the AX tree.
//
//   ax-tour --bundle-id com.cmuxterm.app.debug.<tag> [--out DIR] [--steps a,b,...] [--dump]
//
// Built and run by scripts/cmux-next/ax-tour.sh (swiftc). Safety: it acts only on a running app
// whose bundle id is a tagged debug build (`com.cmuxterm.app.debug.<tag>`); it refuses every other
// bundle id (the user's cmux, NIGHTLY, RC, an untagged DEV) before it reads anything. It never
// activates or focuses an app, never posts mouse or key events, and never quits or launches one.
//
// Steps (default: all, in order):
//   new-workspace   press cmux.sidebar.newWorkspace; a new cmux.sidebar.workspace.* row appears
//   new-tab         press cmux.tabs.newTab; the window has one more cmux.tabs.tab.* element
//   split-pane      press the menu item cmux.action.splitRight; one more cmux.pane.divider.* splitter and tab
//   switch-tab      press an unselected cmux.tabs.tab.*; its AXValue becomes 1
//   palette         press cmux.action.commandPalette; cmux.commandPalette shows; press again to close
//   settings        press cmux.action.openSettings; a settings page tab appears; its x closes it
//   close-split     press the split pane's tab x (the menu bar has no Close Pane); the splitter count returns
//   close-tab       press the new tab's cmux.tabs.tab.<id>.close; the tab count returns to its start
//   close-workspace press cmux.action.closeWorkspace; the workspace count returns to its start
//
// Output: DIR/manifest.json (each step: pass/fail, detail, screenshot) and DIR/shots/NN-step.png.
// Exit 0 when every step passes, 1 when one fails, 2 on a refused target or a missing grant.
import AppKit
import ApplicationServices
import ScreenCaptureKit

// MARK: Arguments and the target guard

struct Options {
    var bundleID = ""
    var out = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ax-tour-\(getpid())")
    var steps: [String] = []
    var dump = false
    var settle: TimeInterval = 8
    /// A capture helper run as `bash HELPER shot --pid PID --with-popups --out FILE` (the GUI build
    /// host's `$NX_CAPTURE`, whose grant the tour process lacks); nil uses ScreenCaptureKit.
    var captureHelper: String?
}

func fail(_ message: String, code: Int32) -> Never {
    FileHandle.standardError.write(Data("ax-tour: \(message)\n".utf8))
    exit(code)
}

func parse() -> Options {
    var options = Options()
    var args = CommandLine.arguments.dropFirst().makeIterator()
    while let arg = args.next() {
        switch arg {
        case "--bundle-id": options.bundleID = args.next() ?? ""
        case "--out": options.out = URL(fileURLWithPath: args.next() ?? "")
        case "--steps": options.steps = (args.next() ?? "").split(separator: ",").map(String.init)
        case "--settle": options.settle = TimeInterval(args.next() ?? "") ?? options.settle
        case "--dump": options.dump = true
        case "--capture-helper": options.captureHelper = args.next()
        default: fail("unknown argument \(arg)", code: 2)
        }
    }
    return options
}

/// Only a tagged debug build: `com.cmuxterm.app.debug.<tag>`. The user's cmux, NIGHTLY, RC, a
/// release and an untagged DEV build share no prefix with it beyond `com.cmuxterm.app`.
func isTaggedDebugBundle(_ id: String) -> Bool {
    let prefix = "com.cmuxterm.app.debug."
    guard id.hasPrefix(prefix) else { return false }
    let tag = id.dropFirst(prefix.count)
    return !tag.isEmpty && tag.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "." }
}

// MARK: AX reads (no writes except AXPress on the target app)

final class AX {
    let app: AXUIElement
    let pid: pid_t

    init(pid: pid_t) {
        self.pid = pid
        app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 5)
    }

    func attr(_ element: AXUIElement, _ name: String) -> AnyObject? {
        var value: AnyObject?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }

    func string(_ element: AXUIElement, _ name: String) -> String { (attr(element, name) as? String) ?? "" }

    func children(_ element: AXUIElement) -> [AXUIElement] { (attr(element, kAXChildrenAttribute) as? [AXUIElement]) ?? [] }

    var windows: [AXUIElement] { (attr(app, kAXWindowsAttribute) as? [AXUIElement]) ?? [] }

    /// Every element under the app's windows (web content is not walked: it is the page's own tree).
    func elements(under roots: [AXUIElement]? = nil, limit: Int = 20_000) -> [AXUIElement] {
        var out: [AXUIElement] = []
        var stack = roots ?? windows
        while let element = stack.popLast(), out.count < limit {
            out.append(element)
            if string(element, kAXRoleAttribute) == "AXWebArea" { continue }
            stack.append(contentsOf: children(element).reversed())
        }
        return out
    }

    func identified(_ prefix: String, in roots: [AXUIElement]? = nil) -> [AXUIElement] {
        elements(under: roots).filter { string($0, kAXIdentifierAttribute).hasPrefix(prefix) }
    }

    /// A menu bar item by identifier (`cmux.action.<id>`); menus are walked closed, nothing opens.
    func menuItem(_ identifier: String) -> AXUIElement? {
        guard let bar = attr(app, kAXMenuBarAttribute) else { return nil }
        // swiftlint:disable:next force_cast
        return elements(under: [bar as! AXUIElement]).first { string($0, kAXIdentifierAttribute) == identifier }
    }

    @discardableResult
    func press(_ element: AXUIElement) -> AXError { AXUIElementPerformAction(element, kAXPressAction as CFString) }

    func value(_ element: AXUIElement) -> Int? { (attr(element, kAXValueAttribute) as? NSNumber)?.intValue }

    /// A printable line for one element (the `--dump` output): role, subrole, identifier,
    /// description, title, enabled, and the actions it accepts.
    func describe(_ element: AXUIElement) -> String {
        var names: CFArray?
        AXUIElementCopyActionNames(element, &names)
        let actions = (names as? [String] ?? []).joined(separator: ",")
        let enabled = (attr(element, kAXEnabledAttribute) as? Bool).map { $0 ? "enabled" : "disabled" } ?? "-"
        return ([kAXRoleAttribute, kAXSubroleAttribute, kAXIdentifierAttribute, kAXDescriptionAttribute, kAXTitleAttribute]
            .map { string(element, $0) } + [enabled, actions]).joined(separator: " | ")
    }
}

/// Waits for a condition the app reaches on its own (an AX read each 100 ms, bounded by `timeout`).
/// A tour is an external observer with no event stream from the app, so a bounded poll is its signal.
func waitFor(_ timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    repeat {
        if condition() { return true }
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    } while Date() < deadline
    return condition()
}

// MARK: Screenshots of the app's own windows

func screenshot(pid: pid_t, to url: URL, helper: String?) -> String? {
    if let helper {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [helper, "shot", "--pid", String(pid), "--with-popups", "--out", url.path]
        do { try process.run() } catch { return "capture helper: \(error.localizedDescription)" }
        process.waitUntilExit()
        return process.terminationStatus == 0 ? nil : "capture helper exited \(process.terminationStatus)"
    }
    let semaphore = DispatchSemaphore(value: 0)
    var problem: String?
    Task {
        defer { semaphore.signal() }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            guard let window = content.windows.filter({ $0.owningApplication?.processID == pid && $0.windowLayer == 0 })
                .max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }) else {
                problem = "no on-screen window of pid \(pid)"
                return
            }
            let configuration = SCStreamConfiguration()
            configuration.width = Int(window.frame.width * 2)
            configuration.height = Int(window.frame.height * 2)
            configuration.showsCursor = false
            let image = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: window),
                                                                   configuration: configuration)
            let rep = NSBitmapImageRep(cgImage: image)
            try rep.representation(using: .png, properties: [:])?.write(to: url)
        } catch {
            problem = "ScreenCaptureKit: \(error.localizedDescription) (Screen Recording grant?)"
        }
    }
    semaphore.wait()
    return problem
}

// MARK: The tour

struct StepResult: Codable {
    let step: String
    let ok: Bool
    let detail: String
    let screenshot: String?
}

final class Tour {
    let ax: AX
    let options: Options
    var results: [StepResult] = []
    // What the tour created, so the closing steps remove only that.
    var startTabs = Set<String>()
    var startDividers = 0
    var newTabID: String?
    var newWorkspaceID: String?
    var splitTabID: String?

    init(ax: AX, options: Options) {
        self.ax = ax
        self.options = options
    }

    /// Identifiers under `prefix` of elements with `role` (a row's or a tab's own buttons have other roles).
    func ids(_ prefix: String, role: String) -> Set<String> {
        Set(ax.identified(prefix).filter { ax.string($0, kAXRoleAttribute) == role }.map { ax.string($0, kAXIdentifierAttribute) })
    }

    var workspaces: Set<String> { ids("cmux.sidebar.workspace.", role: "AXRow") }
    var tabs: Set<String> { ids("cmux.tabs.tab.", role: "AXRadioButton") }
    var dividers: Int { ax.identified("cmux.pane.divider.").count }

    func element(_ identifier: String) -> AXUIElement? {
        ax.elements().first { ax.string($0, kAXIdentifierAttribute) == identifier }
    }

    /// The outcome of one AXPress: `missing` when no element has the identifier (the step fails at
    /// once), else the AX error code when it was not success. A press that acts but reports an
    /// error fails its step: an agent that sees the error presses again and acts twice.
    struct Press {
        var missing: String?
        var note = ""
        var succeeded: Bool { missing == nil && note.isEmpty }
    }

    func pressMenu(_ action: String) -> Press {
        guard let item = ax.menuItem("cmux.action.\(action)") else { return Press(missing: "no menu item cmux.action.\(action)") }
        let error = ax.press(item)
        return Press(note: error == .success ? "" : "; AXPress cmux.action.\(action) returned \(error.rawValue)")
    }

    func pressID(_ identifier: String) -> Press {
        guard let target = element(identifier) else { return Press(missing: "no element \(identifier)") }
        let error = ax.press(target)
        return Press(note: error == .success ? "" : "; AXPress \(identifier) returned \(error.rawValue)")
    }

    /// `count` once a second passes with no change (at most `options.settle`): a late second
    /// workspace or tab from a repeated press shows up here.
    func settled(_ count: () -> Int) -> Int {
        var last = count(), stableSince = Date()
        let deadline = Date().addingTimeInterval(options.settle)
        while Date() < deadline, Date().timeIntervalSince(stableSince) < 1 {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            let now = count()
            if now != last { last = now; stableSince = Date() }
        }
        return last
    }

    func record(_ step: String, _ ok: Bool, _ detail: String) {
        let shots = options.out.appendingPathComponent("shots")
        let shot = shots.appendingPathComponent(String(format: "%02d-%@.png", results.count + 1, step))
        let problem = screenshot(pid: ax.pid, to: shot, helper: options.captureHelper)
        results.append(StepResult(step: step, ok: ok, detail: problem.map { "\(detail); screenshot: \($0)" } ?? detail,
                                  screenshot: problem == nil ? shot.lastPathComponent : nil))
        print("\(ok ? "ok  " : "FAIL") \(step): \(detail)")
    }

    func run(_ step: String) {
        let settle = options.settle
        switch step {
        case "new-workspace":
            let before = workspaces
            let press = pressID("cmux.sidebar.newWorkspace")
            if let missing = press.missing { return record(step, false, missing) }
            let made = waitFor(settle) { workspaces.subtracting(before).count == 1 }
            newWorkspaceID = made ? workspaces.subtracting(before).first : nil
            // One press makes one workspace: a second row after a short wait is a double press.
            let added = settled { workspaces.subtracting(before).count }
            let ok = made && added == 1 && press.succeeded
            record(step, ok, (made ? "new row \(newWorkspaceID ?? ""), \(added) added" : "no new cmux.sidebar.workspace.* row") + press.note)
        case "new-tab":
            let before = tabs
            let press = pressID("cmux.tabs.newTab")
            if let missing = press.missing { return record(step, false, missing) }
            // A new tab first shows a pending id (`pending_tab_...`) and then its model id: wait for that.
            let made = waitFor(settle) { tabs.subtracting(before).count == 1 && !tabs.subtracting(before).contains { $0.contains("pending_") } }
            newTabID = made ? tabs.subtracting(before).first : nil
            let added = settled { tabs.subtracting(before).count }
            let ok = made && added == 1 && press.succeeded
            record(step, ok, (made ? "new tab \(newTabID ?? ""), \(added) added" : "no new cmux.tabs.tab.* element") + press.note)
        case "split-pane":
            let before = dividers, beforeTabs = tabs
            let press = pressMenu("splitRight")
            if let missing = press.missing { return record(step, false, missing) }
            let ok = waitFor(settle) { dividers == before + 1 && tabs.subtracting(beforeTabs).count == 1 }
            splitTabID = ok ? tabs.subtracting(beforeTabs).first : nil
            record(step, ok, "dividers \(before) -> \(dividers), new pane's tab \(splitTabID ?? "none")" + press.note)
        case "switch-tab":
            guard let target = ax.identified("cmux.tabs.tab.").first(where: {
                ax.string($0, kAXRoleAttribute) == "AXRadioButton" && ax.value($0) == 0
            }) else { return record(step, false, "no unselected tab") }
            let id = ax.string(target, kAXIdentifierAttribute)
            ax.press(target)
            let ok = waitFor(settle) { element(id).flatMap(ax.value) == 1 }
            record(step, ok, ok ? "selected \(id)" : "\(id) did not become selected")
        case "palette":
            let press = pressMenu("commandPalette")
            if let missing = press.missing { return record(step, false, missing) }
            let shown = waitFor(settle) { element("cmux.commandPalette") != nil }
            record(step, shown, (shown ? "cmux.commandPalette shows" : "cmux.commandPalette did not show") + press.note)
            guard shown else { return }
            _ = pressMenu("commandPalette")
            if !waitFor(2, { element("cmux.commandPalette") == nil }), let palette = element("cmux.commandPalette") {
                AXUIElementPerformAction(palette, kAXCancelAction as CFString)
            }
            let closed = waitFor(settle) { element("cmux.commandPalette") == nil }
            record("palette-close", closed, closed ? "palette closed" : "palette still shows")
        case "settings":
            // Settings opens as an internal page tab of the window, not as a window.
            let before = tabs
            let press = pressMenu("openSettings")
            if let missing = press.missing { return record(step, false, missing) }
            let opened = waitFor(settle) { tabs.subtracting(before).count == 1 }
            guard opened, let id = tabs.subtracting(before).first else { return record(step, false, "no new settings tab") }
            record(step, true, "settings tab \(id)" + press.note)
            let closePress = pressID("\(id).close")
            if let missing = closePress.missing { return record("settings-close", false, missing) }
            let closed = waitFor(settle) { !tabs.contains(id) }
            record("settings-close", closed, (closed ? "closed \(id)" : "\(id) still open") + closePress.note)
        case "close-split":
            // The menu bar has no Close Pane; closing the split pane's only tab closes the pane.
            guard let id = splitTabID else { return record(step, false, "the tour made no split") }
            let press = pressID("\(id).close")
            if let missing = press.missing { return record(step, false, missing) }
            let ok = waitFor(settle) { dividers == startDividers }
            record(step, ok, "dividers -> \(dividers) (start \(startDividers))" + press.note)
        case "close-tab":
            guard let id = newTabID, let tab = element(id) else { return record(step, false, "the tour's tab is gone or was never made") }
            // Select it first, as a user would; its x is an element either way.
            ax.press(tab)
            guard waitFor(settle, { element("\(id).close") != nil }) else { return record(step, false, "\(id) shows no x") }
            let press = pressID("\(id).close")
            if let missing = press.missing { return record(step, false, missing) }
            let ok = waitFor(settle) { !tabs.contains(id) }
            record(step, ok, (ok ? "closed \(id)" : "\(id) still open") + press.note)
        case "close-workspace":
            // Only the workspace new-workspace made: a row that appeared some other way is not the tour's.
            guard let id = newWorkspaceID else { return record(step, false, "the tour made no workspace") }
            guard let row = element(id) else { return record(step, false, "no \(id)") }
            ax.press(row) // selects it, so Close Workspace acts on the tour's workspace
            let press = pressMenu("closeWorkspace")
            if let missing = press.missing { return record(step, false, missing) }
            let ok = waitFor(settle) { !workspaces.contains(id) }
            record(step, ok, (ok ? "closed \(id)" : "\(id) still open (a confirmation sheet?)") + press.note)
        default:
            record(step, false, "unknown step")
        }
    }
}

// MARK: Main

let options = parse()
guard isTaggedDebugBundle(options.bundleID) else {
    fail("refusing --bundle-id '\(options.bundleID)': only a tagged debug build (com.cmuxterm.app.debug.<tag>) may be driven", code: 2)
}
guard AXIsProcessTrusted() else {
    fail("this process has no Accessibility grant; grant it to the terminal or host that runs the tour (never prompted here)", code: 2)
}
let running = NSRunningApplication.runningApplications(withBundleIdentifier: options.bundleID)
guard running.count == 1, let target = running.first, target.bundleIdentifier == options.bundleID else {
    fail("expected one running \(options.bundleID), found \(running.count); launch the tagged build first (reload.sh --tag)", code: 2)
}
let ax = AX(pid: target.processIdentifier)
if options.dump {
    for element in ax.elements() { print(ax.describe(element)) }
    if let bar = ax.attr(ax.app, kAXMenuBarAttribute) {
        // swiftlint:disable:next force_cast
        for element in ax.elements(under: [bar as! AXUIElement]) where !ax.string(element, kAXIdentifierAttribute).isEmpty {
            print("menu | " + ax.describe(element))
        }
    }
    exit(0)
}
try? FileManager.default.createDirectory(at: options.out.appendingPathComponent("shots"), withIntermediateDirectories: true)
let tour = Tour(ax: ax, options: options)
tour.startTabs = tour.tabs
tour.startDividers = tour.dividers
let all = ["new-workspace", "new-tab", "split-pane", "switch-tab", "palette", "settings", "close-split", "close-tab", "close-workspace"]
for step in options.steps.isEmpty ? all : options.steps { tour.run(step) }
let manifest: [String: Any] = [
    "bundleID": options.bundleID,
    "result": tour.results.allSatisfy(\.ok) ? "pass" : "failed",
    "steps": tour.results.map { ["step": $0.step, "ok": $0.ok, "detail": $0.detail, "screenshot": ($0.screenshot as Any?) ?? NSNull()] as [String: Any] },
]
if let data = try? JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys]) {
    try? data.write(to: options.out.appendingPathComponent("manifest.json"))
}
print("manifest: \(options.out.appendingPathComponent("manifest.json").path)")
exit(tour.results.allSatisfy(\.ok) ? 0 : 1)
