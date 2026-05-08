import XCTest

@_silgen_name("notify_register_check")
private func cmxNotifyRegisterCheck(_ name: UnsafePointer<CChar>, _ outToken: UnsafeMutablePointer<Int32>) -> UInt32

@_silgen_name("notify_get_state")
private func cmxNotifyGetState(_ token: Int32, _ state: UnsafeMutablePointer<UInt64>) -> UInt32

@_silgen_name("notify_cancel")
private func cmxNotifyCancel(_ token: Int32) -> UInt32

final class CmxLongHaulStressUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testThirtySecondTerminalWorkspaceReconnectAndResizeStressSmoke() throws {
        try runStress(mode: "smoke", targetDuration: 30)
    }

    @MainActor
    func testOneHourTerminalWorkspaceReconnectAndResizeStress() throws {
        try runStress(mode: "hour", targetDuration: 3_600)
    }

    @MainActor
    func testMainActorFreezeFailsFast() throws {
        let statusToken = "longhaul-\(UUID().uuidString)"
        let probe = CmxLongHaulNotificationProbe(token: statusToken)
        let stallTimeout: TimeInterval = 5
        let app = launchApp(
            mode: "freeze",
            statusToken: statusToken,
            stallTimeout: stallTimeout,
            autostart: false
        )
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
        let status = app.descendants(matching: .any)["longhaul.status"]
        XCTAssertTrue(status.waitForExistence(timeout: 10))
        probe.postStart()
        XCTAssertTrue(probe.wait(for: .running, timeout: 30), "observed events: \(probe.snapshot())")
        let outcome = probe.waitForOutcome(
            app: app,
            timeout: 20,
            inactivityTimeout: stallTimeout + 7
        )
        XCTAssertEqual(outcome, .failed, "observed events: \(probe.snapshot())")
    }

    @MainActor
    private func runStress(
        mode: String,
        targetDuration: TimeInterval
    ) throws {
        let statusToken = "longhaul-\(UUID().uuidString)"
        let probe = CmxLongHaulNotificationProbe(token: statusToken)
        let app = launchApp(mode: mode, statusToken: statusToken, stallTimeout: nil, autostart: true)
        _ = try openTerminal(in: app)

        let status = app.descendants(matching: .any)["longhaul.status"]
        XCTAssertTrue(status.waitForExistence(timeout: 10))
        XCTAssertTrue(probe.wait(for: .running, timeout: 30), "observed events: \(probe.snapshot())")
        let outcome = probe.waitForOutcome(
            app: app,
            timeout: targetDuration + 180,
            inactivityTimeout: 45
        )
        XCTAssertEqual(outcome, .complete, "observed events: \(probe.snapshot())")
        let statusValue = waitForStatusValue(status, containing: "long-haul complete", timeout: 10)
        XCTAssertGreaterThanOrEqual(Self.elapsedSeconds(in: statusValue), targetDuration - 1)
    }

    @MainActor
    private func launchApp(
        mode: String,
        statusToken: String,
        stallTimeout: TimeInterval?,
        autostart: Bool
    ) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment = [
            "CMUX_IOS_BRIDGE_TICKET": Self.directTicket,
            "CMUX_IOS_AUTOCONNECT": "1",
            "CMUX_IOS_UI_TESTING_ECHO_SESSION": "1",
            "CMUX_IOS_SHOW_TERMINAL_BOUNDS": "1",
            "CMUX_IOS_LONG_HAUL_STRESS_MODE": mode,
            "CMUX_IOS_LONG_HAUL_STATUS_TOKEN": statusToken,
        ]
        if autostart {
            app.launchEnvironment["CMUX_IOS_LONG_HAUL_AUTOSTART"] = "1"
        }
        if let stallTimeout {
            app.launchEnvironment["CMUX_IOS_LONG_HAUL_STALL_TIMEOUT_SECONDS"] = "\(stallTimeout)"
        } else if let stallTimeout = ProcessInfo.processInfo.environment["CMUX_IOS_LONG_HAUL_STALL_TIMEOUT_SECONDS"] {
            app.launchEnvironment["CMUX_IOS_LONG_HAUL_STALL_TIMEOUT_SECONDS"] = stallTimeout
        } else {
            app.launchEnvironment["CMUX_IOS_LONG_HAUL_STALL_TIMEOUT_SECONDS"] = "12"
        }
        app.launch()
        return app
    }

    @MainActor
    private func openTerminal(in app: XCUIApplication) throws -> XCUIElement {
        let workspace = app.descendants(matching: .any)["workspace.row.1"]
        XCTAssertTrue(workspace.waitForExistence(timeout: 10))
        workspace.tap()
        let terminal = try waitForTerminal(app: app)
        return terminal
    }

    @MainActor
    private func waitForTerminal(app: XCUIApplication) throws -> XCUIElement {
        let terminal = app.descendants(matching: .any)["terminal.surface"]
        XCTAssertTrue(terminal.waitForExistence(timeout: 10))
        XCTAssertFalse(app.descendants(matching: .any)["terminal.empty"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["terminal.loading"].exists)
        return terminal
    }

    @MainActor
    private func waitForStatusValue(
        _ status: XCUIElement,
        containing expected: String,
        timeout: TimeInterval
    ) -> String {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let value = (status.value as? String) ?? status.label
            if value.contains(expected) {
                return value
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return (status.value as? String) ?? status.label
    }

    private static func elapsedSeconds(in statusValue: String) -> TimeInterval {
        guard let range = statusValue.range(of: "elapsed=") else { return 0 }
        let suffix = statusValue[range.upperBound...]
        let value = suffix.prefix { character in
            character.isNumber || character == "."
        }
        return TimeInterval(value) ?? 0
    }

    private static let directTicket = #"{"version":1,"alpn":"/cmux/cmx/3","endpoint":{"id":"ui-test-endpoint","addrs":[]},"auth":{"mode":"direct"},"node":{"id":"ui-test-node","name":"UI Test Mac","subtitle":"Ghostty echo session","kind":"macbook"}}"#
}

private final class CmxLongHaulNotificationProbe {
    enum Outcome: Equatable {
        case complete
        case failed
        case appExited
        case inactive
        case timedOut
    }

    enum Event: String, CaseIterable {
        case running
        case progress
        case heartbeat
        case complete
        case failed
    }

    private let token: String
    private let prefix: String
    private let lock = NSLock()
    private var counts: [Event: Int] = [:]
    private var lastAction: String?
    private var progressStateToken: Int32 = 0
    private var completeStateToken: Int32 = 0
    private var failedStateToken: Int32 = 0

    init(token: String) {
        self.token = token
        self.prefix = "dev.cmux.ios.longhaul.\(token)."
        for event in Event.allCases {
            addObserver(named: "\(prefix)\(event.rawValue)")
        }
        for action in Self.observedActions {
            addObserver(named: "\(prefix)action.\(action)")
        }
        registerStateToken("\(prefix)state.progress", token: &progressStateToken)
        registerStateToken("\(prefix)state.complete", token: &completeStateToken)
        registerStateToken("\(prefix)state.failed", token: &failedStateToken)
    }

    deinit {
        cancelStateToken(progressStateToken)
        cancelStateToken(completeStateToken)
        cancelStateToken(failedStateToken)
        CFNotificationCenterRemoveObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(self).toOpaque(),
            nil,
            nil
        )
    }

    func wait(for event: Event, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if hasSeen(event) {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return hasSeen(event)
    }

    @MainActor
    func waitForOutcome(
        app: XCUIApplication,
        timeout: TimeInterval,
        inactivityTimeout: TimeInterval
    ) -> Outcome {
        let deadline = Date().addingTimeInterval(timeout)
        var lastActivityAt = Date()
        var lastActivity = activitySnapshot()
        var lastProgressState = stateValue(progressStateToken)
        while Date() < deadline {
            if hasSeen(.complete) {
                return .complete
            }
            if hasSeen(.failed) {
                return .failed
            }
            if stateValue(completeStateToken) > 0 {
                return .complete
            }
            if stateValue(failedStateToken) > 0 {
                return .failed
            }
            let currentActivity = activitySnapshot()
            if currentActivity != lastActivity {
                lastActivity = currentActivity
                lastActivityAt = Date()
            }
            let currentProgressState = stateValue(progressStateToken)
            if currentProgressState != lastProgressState {
                lastProgressState = currentProgressState
                lastActivityAt = Date()
            }
            if app.state == .notRunning {
                return .appExited
            }
            if Date().timeIntervalSince(lastActivityAt) >= inactivityTimeout {
                return .inactive
            }
            RunLoop.current.run(until: Date().addingTimeInterval(1))
        }
        if hasSeen(.complete) || stateValue(completeStateToken) > 0 {
            return .complete
        }
        if hasSeen(.failed) || stateValue(failedStateToken) > 0 {
            return .failed
        }
        return .timedOut
    }

    private func registerStateToken(_ name: String, token: inout Int32) {
        name.withCString { pointer in
            _ = cmxNotifyRegisterCheck(pointer, &token)
        }
    }

    private func cancelStateToken(_ token: Int32) {
        guard token != 0 else { return }
        _ = cmxNotifyCancel(token)
    }

    private func stateValue(_ token: Int32) -> UInt64 {
        guard token != 0 else { return 0 }
        var value: UInt64 = 0
        _ = cmxNotifyGetState(token, &value)
        return value
    }

    @MainActor
    private func statusValue(_ status: XCUIElement) -> String {
        (status.value as? String) ?? status.label
    }

    func snapshot() -> String {
        lock.lock()
        defer { lock.unlock() }
        let events = Event.allCases
            .map { "\($0.rawValue)=\(counts[$0, default: 0])" }
            .joined(separator: " ")
        if let lastAction {
            return "\(events) lastAction=\(lastAction)"
        }
        return events
    }

    func hasSeen(_ event: Event) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return counts[event, default: 0] > 0
    }

    func postStart() {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName("\(prefix)start" as CFString),
            nil,
            nil,
            true
        )
    }

    private func activitySnapshot() -> String {
        lock.lock()
        defer { lock.unlock() }
        let count = Event.allCases
            .map { counts[$0, default: 0] }
            .reduce(0, +)
        return "\(count):\(lastAction ?? "")"
    }

    private func addObserver(named name: String) {
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(self).toOpaque(),
            { _, observer, name, _, _ in
                guard let observer, let name else { return }
                Unmanaged<CmxLongHaulNotificationProbe>
                    .fromOpaque(observer)
                    .takeUnretainedValue()
                    .recordNotification(named: name.rawValue as String)
            },
            name as CFString,
            nil,
            .deliverImmediately
        )
    }

    private func recordNotification(named name: String) {
        guard name.hasPrefix(prefix) else {
            return
        }
        lock.lock()
        if let event = Event.allCases.first(where: { name == "\(prefix)\($0.rawValue)" }) {
            counts[event, default: 0] += 1
        } else if name.hasPrefix("\(prefix)action.") {
            lastAction = String(name.dropFirst("\(prefix)action.".count))
        }
        lock.unlock()
    }

    private static let observedActions: [String] = {
        let baseActions = [
            "type-single",
            "type-multiline",
            "select-workspace",
            "resize-small",
            "resize-small-applied",
            "resize-small-rendered",
            "resize-large",
            "resize-large-applied",
            "resize-echo",
            "alt-screen-enter",
            "alt-screen-exit",
            "new-workspace",
            "cycle-workspace",
            "rename-workspace",
            "new-space",
            "new-tab",
            "select-terminal",
            "terminal-switch-echo",
            "select-space",
            "space-switch-echo",
            "terminal-hide-show",
            "terminal-hide-show-hidden",
            "terminal-hide-show-showing",
            "terminal-hide-show-shown",
            "terminal-hide-show-ready",
            "move-workspace",
            "freeze-main-actor",
        ]
        let sendPhaseSuffixes = ["", "-sent", "-seen", "-rendered"]
        return baseActions.flatMap { action in
            sendPhaseSuffixes.map { "\(action)\($0)" }
        }
    }()
}
