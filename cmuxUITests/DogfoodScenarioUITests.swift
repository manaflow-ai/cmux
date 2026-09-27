import XCTest
import Foundation
import Darwin

/// Runs an agent-written dogfood tour against the built app and keeps a
/// screenshot and accessibility tree for every step that asks for one.
///
/// The scenario arrives at run time, so a new tour of an already-built commit
/// compiles nothing: `scripts/run-e2e.sh --scenario tour.json --frames`
/// base64-encodes the file into test-e2e.yml's `dogfood_scenario` input, the
/// e2e action forwards it as `TEST_RUNNER_CMUX_DOGFOOD_SCENARIO_B64`, and this
/// test reads it back. Without a scenario the test skips, so ordinary UI runs
/// never pay for it. The format is documented in
/// skills/cmux-testing/references/dogfood-scenarios.md.
///
/// A failing step is recorded and the tour continues, so one bad identifier
/// still leaves every later screenshot; the test fails at the end listing them.
final class DogfoodScenarioUITests: XCTestCase {
    private var socketPath = ""
    private var lastSocketError = "no attempt"
    private var diagnosticsPath = ""
    private var saved: [String: Any] = [:]
    private var log: [String] = []
    private var failures: [String] = []

    override func setUp() {
        super.setUp()
        continueAfterFailure = true
        let id = UUID().uuidString.prefix(8).lowercased()
        // The runner is sandboxed: connect(2) to a socket in /tmp fails with
        // EPERM. Its own temporary directory is reachable from both sides,
        // as in HookPromptLengthUITests. Short name: sun_path is 104 bytes.
        socketPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("d\(id.prefix(6)).sock").path
        diagnosticsPath = "/tmp/cmux-ui-test-dogfood-\(id).json"
        for path in [socketPath, diagnosticsPath] {
            try? FileManager.default.removeItem(atPath: path)
        }
    }

    override func tearDown() {
        for path in [socketPath, diagnosticsPath] {
            try? FileManager.default.removeItem(atPath: path)
        }
        super.tearDown()
    }

    func testRunScenario() throws {
        guard let encoded = ProcessInfo.processInfo.environment["CMUX_DOGFOOD_SCENARIO_B64"],
              !encoded.isEmpty else {
            throw XCTSkip("No dogfood scenario; dispatch with scripts/run-e2e.sh --scenario <file>")
        }
        guard let data = Data(base64Encoded: encoded, options: .ignoreUnknownCharacters) else {
            XCTFail("CMUX_DOGFOOD_SCENARIO_B64 is not base64")
            return
        }
        let scenario = try DogfoodScenario.decode(data)
        attachText(String(decoding: data, as: UTF8.self), name: "scenario.json")

        let app = XCUIApplication.cmuxTestApplication()
        app.launchArguments += [
            "-socketControlMode", "allowAll",
            "-AppleLanguages", "(\(scenario.language ?? "en"))",
            "-AppleLocale", scenario.locale ?? "en_US",
            "-NSAppSleepDisabled", "YES",
        ] + scenario.launchArguments
        // The environment overrides beat the settings file and defaults; on
        // the first live tour the launch argument alone left the socket off.
        app.launchEnvironment["CMUX_UI_TEST_MODE"] = "1"
        app.launchEnvironment["CMUX_SOCKET_ENABLE"] = "1"
        app.launchEnvironment["CMUX_SOCKET_MODE"] = "allowAll"
        app.launchEnvironment["CMUX_SOCKET_PATH"] = socketPath
        app.launchEnvironment["CMUX_ALLOW_SOCKET_OVERRIDE"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_SOCKET_SANITY"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_DIAGNOSTICS_PATH"] = diagnosticsPath
        if let path = ProcessInfo.processInfo.environment["PATH"], !path.isEmpty {
            app.launchEnvironment["PATH"] = path
        }
        for (key, value) in scenario.launchEnvironment {
            app.launchEnvironment[key] = value
        }
        defer { app.terminate() }

        launchAllowingHeadlessBackground(app)
        if !app.wait(for: .runningForeground, timeout: 20) {
            app.activate()
            _ = app.wait(for: .runningForeground, timeout: 10)
        }
        _ = app.windows.firstMatch.waitForExistence(timeout: 20)
        if scenario.zoomsWindow {
            zoomFrontWindow(in: app)
        }
        if scenario.usesSocket, !waitForSocket(timeout: 30) {
            record(failure: "control socket never answered ping at \(socketCandidates().joined(separator: ", ")): \(lastSocketError)")
            attachSocketDiagnostics(app: app)
        }
        shot("00-launched", app: app)

        for (index, step) in scenario.steps.enumerated() {
            let label = String(format: "%02d", index + 1)
            do {
                try run(step, label: label, app: app)
                log.append("\(label) ok \(step.summary)")
            } catch {
                record(failure: "step \(label) \(step.summary): \(error)")
                shot("\(label)-failed", app: app)
            }
        }
        shot("99-final", app: app)
        shot("99-final-screen", app: app, screen: true)
        attachText(log.joined(separator: "\n"), name: "steps.log")
        if !failures.isEmpty {
            XCTFail("Dogfood steps failed:\n" + failures.joined(separator: "\n"))
        }
    }

    /// Blacksmith's headless displays can leave a fresh launch in the
    /// background, and XCUITest then records "Failed to activate application"
    /// and ends the test. Absorb only that issue, as AutomationSocketUITests
    /// does, and activate explicitly afterwards; the result then reads
    /// Expected Failure, which steps.log explains.
    private func launchAllowingHeadlessBackground(_ app: XCUIApplication) {
        let options = XCTExpectedFailure.Options()
        options.isStrict = false
        options.issueMatcher = { issue in
            let text = [issue.compactDescription, issue.detailedDescription ?? ""].joined(separator: "\n")
            return text.contains("Failed to activate application") && text.contains("Running Background")
        }
        XCTExpectFailure("App activation may fail on headless CI runners", options: options) {
            app.launch()
        }
        if app.state == .runningBackground {
            log.append("launch: app started in the background; activating")
            app.activate()
        }
    }

    // MARK: Steps

    private func run(_ step: DogfoodStep, label: String, app: XCUIApplication) throws {
        switch step {
        case .shot(let name, let screen):
            shot("\(label)-\(name)", app: app, screen: screen)
        case .tree(let name):
            attachText(app.debugDescription, name: "\(label)-\(name).tree.txt")
        case .wait(let seconds):
            RunLoop.current.run(until: Date().addingTimeInterval(seconds))
        case .key(let key, let modifiers):
            app.typeKey(key, modifierFlags: modifiers)
        case .type(let text):
            app.typeText(text)
        case .click(let target):
            try element(target, in: app).click()
        case .doubleClick(let target):
            try element(target, in: app).doubleClick()
        case .rightClick(let target):
            try element(target, in: app).rightClick()
        case .hover(let target):
            try element(target, in: app).hover()
        case .clickAt(let x, let y):
            app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: x, dy: y)).click()
        case .hoverAt(let x, let y):
            app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: x, dy: y)).hover()
        case .menu(let path):
            try clickMenu(path, in: app)
        case .socket(let method, let params, let saveAs):
            let resolved = substitute(params)
            guard let response = socketRequest(method: method, params: resolved) else {
                throw DogfoodError("no reply from \(method): \(lastSocketError)")
            }
            attachText(prettyJSON(response), name: "\(label)-\(method).json")
            guard response["ok"] as? Bool == true else {
                throw DogfoodError("\(method) failed: \(prettyJSON(response["error"] ?? response))")
            }
            if let saveAs {
                saved[saveAs] = response["result"] ?? [:]
            }
        case .expect(let target, let exists):
            let matches = query(target, in: app)
            let element = target.index.map { matches.element(boundBy: $0) } ?? matches.firstMatch
            let found = element.waitForExistence(timeout: exists ? 5 : 0.5)
            if found != exists {
                throw DogfoodError("expected \(target) to \(exists ? "exist" : "be absent")")
            }
        }
    }

    private func query(_ target: DogfoodTarget, in app: XCUIApplication) -> XCUIElementQuery {
        let all = app.descendants(matching: target.elementType)
        switch target.match {
        case .identifier(let id): return all.matching(identifier: id)
        case .label(let label): return all.matching(NSPredicate(format: "label == %@", label))
        case .labelContains(let text): return all.matching(NSPredicate(format: "label CONTAINS %@", text))
        }
    }

    private func element(_ target: DogfoodTarget, in app: XCUIApplication) throws -> XCUIElement {
        let matches = query(target, in: app)
        let element = target.index.map { matches.element(boundBy: $0) } ?? matches.firstMatch
        guard element.waitForExistence(timeout: 5) else {
            throw DogfoodError("no element for \(target); add a tree step to see what exists")
        }
        return element
    }

    private func clickMenu(_ path: [String], in app: XCUIApplication) throws {
        guard let top = path.first else { throw DogfoodError("empty menu path") }
        let bar = app.menuBars.menuBarItems[top]
        guard bar.waitForExistence(timeout: 5) else { throw DogfoodError("no menu \(top)") }
        bar.click()
        for item in path.dropFirst() {
            let menuItem = app.menuItems[item]
            guard menuItem.waitForExistence(timeout: 3) else {
                app.typeKey(.escape, modifierFlags: [])
                throw DogfoodError("no menu item \(item)")
            }
            menuItem.click()
        }
    }

    // MARK: Attachments

    /// The app's front window by default: shared CI desktops carry other
    /// windows and system prompts, and a window crop keeps more pixels for
    /// the app after frames are downscaled. `"screen": true` takes the display.
    private func shot(_ name: String, app: XCUIApplication, screen: Bool = false) {
        let window = app.windows.firstMatch
        let image = !screen && window.exists ? window.screenshot() : XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: image)
        attachment.name = name
        // Step screenshots of a passing test are dropped unless kept.
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func attachText(_ text: String, name: String) {
        let attachment = XCTAttachment(string: text)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func record(failure: String) {
        failures.append(failure)
        log.append("FAIL \(failure)")
    }

    // MARK: Socket

    /// `"${name.key}"` in a param string takes that field of a saved result,
    /// so a later step can target the workspace or surface an earlier one made.
    private func substitute(_ value: Any) -> Any {
        if let string = value as? String,
           string.hasPrefix("${"), string.hasSuffix("}") {
            let path = string.dropFirst(2).dropLast().split(separator: ".").map(String.init)
            var current: Any? = saved[path.first ?? ""]
            for key in path.dropFirst() {
                current = (current as? [String: Any])?[key]
            }
            return current ?? string
        }
        if let dictionary = value as? [String: Any] {
            return dictionary.mapValues { substitute($0) }
        }
        if let array = value as? [Any] {
            return array.map { substitute($0) }
        }
        return value
    }

    /// Window > Zoom, best effort: the app opens at a small default size, and
    /// tours read better filling the display. Not every locale says "Zoom".
    private func zoomFrontWindow(in app: XCUIApplication) {
        let windowMenu = app.menuBars.menuBarItems["Window"]
        guard windowMenu.waitForExistence(timeout: 3) else { return }
        windowMenu.click()
        let zoom = app.menuItems["Zoom"]
        if zoom.waitForExistence(timeout: 2) {
            zoom.click()
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        } else {
            app.typeKey(.escape, modifierFlags: [])
        }
    }

    /// The listener may bind the requested path or the path the app reports
    /// in its diagnostics; the first one that answers wins.
    private func waitForSocket(timeout: TimeInterval) -> Bool {
        var resolved: String?
        let ready = waitForControlSocketReady(
            pingTimeout: timeout,
            socketFileExists: { self.socketCandidates().contains { FileManager.default.fileExists(atPath: $0) } },
            pingReturnsPong: {
                for candidate in self.socketCandidates() where FileManager.default.fileExists(atPath: candidate) {
                    if self.socketLine("ping", path: candidate, timeout: 1) == "PONG" {
                        resolved = candidate
                        return true
                    }
                }
                return false
            }
        )
        if ready, let resolved {
            socketPath = resolved
        }
        return ready
    }

    /// What the next attempt needs when the socket stays silent: the app's
    /// own socket diagnostics, the socket files that exist, and the launch env.
    private func attachSocketDiagnostics(app: XCUIApplication) {
        let diagnostics = (try? String(contentsOfFile: diagnosticsPath, encoding: .utf8))
            ?? "missing: \(diagnosticsPath)"
        let socketDirectory = (socketPath as NSString).deletingLastPathComponent
        let sockets = ((try? FileManager.default.contentsOfDirectory(atPath: socketDirectory)) ?? [])
            .filter { $0.hasSuffix(".sock") }
            .sorted()
            .joined(separator: "\n")
        let environment = app.launchEnvironment
            .map { "\($0.key)=\($0.value)" }
            .sorted()
            .joined(separator: "\n")
        attachText(
            "diagnostics:\n\(diagnostics)\n\nsockets in \(socketDirectory):\n\(sockets)\n\nlaunch environment:\n\(environment)\n\nlaunch arguments:\n\(app.launchArguments.joined(separator: " "))",
            name: "socket-diagnostics.txt"
        )
    }

    private func socketCandidates() -> [String] {
        var candidates = [socketPath]
        if let data = try? Data(contentsOf: URL(fileURLWithPath: diagnosticsPath)),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let expected = object["socketExpectedPath"] as? String, !expected.isEmpty {
            candidates.append(expected)
        }
        var seen = Set<String>()
        return candidates.filter { seen.insert($0).inserted }
    }

    private func socketRequest(method: String, params: Any) -> [String: Any]? {
        let request: [String: Any] = ["id": UUID().uuidString, "method": method, "params": params]
        guard JSONSerialization.isValidJSONObject(request),
              let data = try? JSONSerialization.data(withJSONObject: request),
              let reply = socketLine(String(decoding: data, as: UTF8.self), path: socketPath, timeout: 15),
              let replyData = reply.data(using: .utf8) else {
            return nil
        }
        return (try? JSONSerialization.jsonObject(with: replyData)) as? [String: Any]
    }

    /// `lastSocketError` keeps why the last attempt failed for the step log.
    private func socketLine(_ line: String, path: String, timeout: TimeInterval) -> String? {
        let client = DogfoodSocketClient(path: path, responseTimeout: timeout)
        guard let reply = client.sendLine(line) else {
            lastSocketError = client.lastError ?? "no reply"
            return nil
        }
        return reply
    }

    private func prettyJSON(_ value: Any) -> String {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]) else {
            return String(describing: value)
        }
        return String(decoding: data, as: UTF8.self)
    }
}

// MARK: - Scenario format

struct DogfoodError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

struct DogfoodTarget: CustomStringConvertible {
    enum Match {
        case identifier(String)
        case label(String)
        case labelContains(String)
    }

    let match: Match
    let elementType: XCUIElement.ElementType
    let index: Int?

    var description: String {
        switch match {
        case .identifier(let id): return "id=\(id)"
        case .label(let label): return "label=\(label)"
        case .labelContains(let text): return "labelContains=\(text)"
        }
    }

    /// A bare string is an accessibility identifier; an object names one of
    /// `id`, `label`, or `labelContains`, plus optional `type` and `index`.
    init(json: Any) throws {
        if let id = json as? String {
            match = .identifier(id)
            elementType = .any
            index = nil
            return
        }
        guard let object = json as? [String: Any] else { throw DogfoodError("target must be a string or object") }
        if let id = object["id"] as? String {
            match = .identifier(id)
        } else if let label = object["label"] as? String {
            match = .label(label)
        } else if let text = object["labelContains"] as? String {
            match = .labelContains(text)
        } else {
            throw DogfoodError("target needs id, label, or labelContains")
        }
        elementType = try Self.elementType(object["type"] as? String)
        index = object["index"] as? Int
    }

    private static func elementType(_ name: String?) throws -> XCUIElement.ElementType {
        switch name?.lowercased() {
        case nil, "any": return .any
        case "button": return .button
        case "textfield": return .textField
        case "statictext", "text": return .staticText
        case "menuitem": return .menuItem
        case "checkbox": return .checkBox
        case "image": return .image
        case "group": return .group
        case "cell": return .cell
        case "tab": return .tab
        case "window": return .window
        case "popover": return .popover
        default: throw DogfoodError("unknown element type \(name ?? "")")
        }
    }
}

enum DogfoodStep {
    case shot(String, screen: Bool)
    case tree(String)
    case wait(TimeInterval)
    case key(String, XCUIElement.KeyModifierFlags)
    case type(String)
    case click(DogfoodTarget)
    case doubleClick(DogfoodTarget)
    case rightClick(DogfoodTarget)
    case hover(DogfoodTarget)
    case clickAt(Double, Double)
    case hoverAt(Double, Double)
    case menu([String])
    case socket(method: String, params: Any, saveAs: String?)
    case expect(DogfoodTarget, exists: Bool)

    var summary: String {
        switch self {
        case .shot(let name, let screen): return screen ? "shot \(name) (screen)" : "shot \(name)"
        case .tree(let name): return "tree \(name)"
        case .wait(let seconds): return "wait \(seconds)"
        case .key(let key, let modifiers): return "key \(key) modifiers=\(modifiers.rawValue)"
        case .type(let text): return "type \(text.debugDescription)"
        case .click(let target): return "click \(target)"
        case .doubleClick(let target): return "doubleClick \(target)"
        case .rightClick(let target): return "rightClick \(target)"
        case .hover(let target): return "hover \(target)"
        case .clickAt(let x, let y): return "clickAt \(x),\(y)"
        case .hoverAt(let x, let y): return "hoverAt \(x),\(y)"
        case .menu(let path): return "menu \(path.joined(separator: " > "))"
        case .socket(let method, _, _): return "socket \(method)"
        case .expect(let target, let exists): return "expect \(target) exists=\(exists)"
        }
    }

    var usesSocket: Bool {
        if case .socket = self { return true }
        return false
    }

    init(json: Any) throws {
        guard let object = json as? [String: Any], let (kind, value) = object.first(where: { Self.kinds.contains($0.key) }) else {
            throw DogfoodError("each step is an object with one of \(Self.kinds.sorted().joined(separator: ", "))")
        }
        switch kind {
        case "shot": self = .shot(value as? String ?? "shot", screen: object["screen"] as? Bool ?? false)
        case "tree": self = .tree(value as? String ?? "tree")
        case "wait": self = .wait((value as? NSNumber)?.doubleValue ?? 1)
        case "type":
            guard let text = value as? String else { throw DogfoodError("type takes a string") }
            self = .type(text)
        case "key":
            guard let key = object["key"] as? String else { throw DogfoodError("key takes a string") }
            self = .key(Self.key(named: key), try Self.modifiers(object["modifiers"]))
        case "click": self = .click(try DogfoodTarget(json: value))
        case "doubleClick": self = .doubleClick(try DogfoodTarget(json: value))
        case "rightClick": self = .rightClick(try DogfoodTarget(json: value))
        case "hover": self = .hover(try DogfoodTarget(json: value))
        case "clickAt", "hoverAt":
            guard let point = value as? [String: Any],
                  let x = (point["x"] as? NSNumber)?.doubleValue,
                  let y = (point["y"] as? NSNumber)?.doubleValue else {
                throw DogfoodError("\(kind) takes {\"x\": 0-1, \"y\": 0-1} in window space")
            }
            self = kind == "clickAt" ? .clickAt(x, y) : .hoverAt(x, y)
        case "menu":
            guard let path = value as? [String], !path.isEmpty else { throw DogfoodError("menu takes a path array") }
            self = .menu(path)
        case "socket":
            guard let method = value as? String else { throw DogfoodError("socket takes a method name") }
            self = .socket(method: method, params: object["params"] ?? [String: Any](), saveAs: object["save"] as? String)
        case "expect":
            self = .expect(try DogfoodTarget(json: value), exists: object["exists"] as? Bool ?? true)
        default:
            throw DogfoodError("unknown step \(kind)")
        }
    }

    private static let kinds: Set<String> = [
        "shot", "tree", "wait", "type", "key", "click", "doubleClick", "rightClick",
        "hover", "clickAt", "hoverAt", "menu", "socket", "expect",
    ]

    private static func key(named name: String) -> String {
        switch name.lowercased() {
        case "return", "enter": return XCUIKeyboardKey.return.rawValue
        case "escape", "esc": return XCUIKeyboardKey.escape.rawValue
        case "tab": return XCUIKeyboardKey.tab.rawValue
        case "delete", "backspace": return XCUIKeyboardKey.delete.rawValue
        case "forwarddelete": return XCUIKeyboardKey.forwardDelete.rawValue
        case "space": return XCUIKeyboardKey.space.rawValue
        case "up": return XCUIKeyboardKey.upArrow.rawValue
        case "down": return XCUIKeyboardKey.downArrow.rawValue
        case "left": return XCUIKeyboardKey.leftArrow.rawValue
        case "right": return XCUIKeyboardKey.rightArrow.rawValue
        case "home": return XCUIKeyboardKey.home.rawValue
        case "end": return XCUIKeyboardKey.end.rawValue
        case "pageup": return XCUIKeyboardKey.pageUp.rawValue
        case "pagedown": return XCUIKeyboardKey.pageDown.rawValue
        default: return name
        }
    }

    private static func modifiers(_ json: Any?) throws -> XCUIElement.KeyModifierFlags {
        guard let names = json as? [String] else { return [] }
        var flags: XCUIElement.KeyModifierFlags = []
        for name in names {
            switch name.lowercased() {
            case "command", "cmd": flags.insert(.command)
            case "shift": flags.insert(.shift)
            case "option", "alt": flags.insert(.option)
            case "control", "ctrl": flags.insert(.control)
            case "function", "fn": flags.insert(.function)
            default: throw DogfoodError("unknown modifier \(name)")
            }
        }
        return flags
    }
}

struct DogfoodScenario {
    let steps: [DogfoodStep]
    let launchArguments: [String]
    let launchEnvironment: [String: String]
    let language: String?
    let locale: String?
    let zoomsWindow: Bool

    var usesSocket: Bool { steps.contains { $0.usesSocket } }

    static func decode(_ data: Data) throws -> DogfoodScenario {
        let json = try JSONSerialization.jsonObject(with: data)
        let object: [String: Any]
        if let steps = json as? [Any] {
            object = ["steps": steps]
        } else if let dictionary = json as? [String: Any] {
            object = dictionary
        } else {
            throw DogfoodError("a scenario is a steps array or an object with steps")
        }
        guard let rawSteps = object["steps"] as? [Any] else { throw DogfoodError("scenario has no steps") }
        let launch = object["launch"] as? [String: Any] ?? [:]
        return DogfoodScenario(
            steps: try rawSteps.map(DogfoodStep.init(json:)),
            launchArguments: launch["args"] as? [String] ?? [],
            launchEnvironment: launch["env"] as? [String: String] ?? [:],
            language: launch["language"] as? String,
            locale: launch["locale"] as? String,
            zoomsWindow: launch["zoom"] as? Bool ?? true
        )
    }
}

// MARK: - Socket client

private final class DogfoodSocketClient {
    private let path: String
    private let responseTimeout: TimeInterval
    private(set) var lastError: String?

    init(path: String, responseTimeout: TimeInterval) {
        self.path = path
        self.responseTimeout = responseTimeout
    }

    func sendLine(_ line: String) -> String? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return fail("socket") }
        defer { close(fd) }

        var timeout = timeval(
            tv_sec: Int(responseTimeout),
            tv_usec: Int32((responseTimeout - floor(responseTimeout)) * 1_000_000)
        )
        withUnsafePointer(to: &timeout) { pointer in
            _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, pointer, socklen_t(MemoryLayout<timeval>.size))
            _ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, pointer, socklen_t(MemoryLayout<timeval>.size))
        }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8CString)
        guard pathBytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            lastError = "path longer than sun_path"
            return nil
        }
        withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            let raw = UnsafeMutableRawPointer(pointer).assumingMemoryBound(to: CChar.self)
            for index in 0..<pathBytes.count {
                raw[index] = pathBytes[index]
            }
        }
        let pathOffset = MemoryLayout<sockaddr_un>.offset(of: \.sun_path) ?? 0
        let length = socklen_t(pathOffset + pathBytes.count)
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, length)
            }
        }
        guard connected == 0 else { return fail("connect") }

        let payload = Array((line + "\n").utf8)
        let wrote = payload.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return true }
            return Darwin.write(fd, base, buffer.count) == buffer.count
        }
        guard wrote else { return fail("write") }

        var buffer = [UInt8](repeating: 0, count: 65_536)
        var received = Data()
        let deadline = Date().addingTimeInterval(responseTimeout)
        while Date() < deadline {
            let count = Darwin.read(fd, &buffer, buffer.count)
            guard count > 0 else {
                if count < 0 { _ = fail("read") } else { lastError = "read: closed after \(received.count) bytes" }
                break
            }
            received.append(contentsOf: buffer[0..<count])
            if let newline = received.firstIndex(of: UInt8(ascii: "\n")) {
                return String(decoding: received[..<newline], as: UTF8.self)
            }
        }
        return received.isEmpty ? nil : String(decoding: received, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func fail(_ call: String) -> String? {
        lastError = "\(call): \(String(cString: strerror(errno))) (errno \(errno))"
        return nil
    }
}
