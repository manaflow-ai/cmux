import XCTest

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
        let app = launchApp(mode: "freeze", statusToken: statusToken, stallTimeout: 5)
        _ = try openTerminal(in: app)

        let status = app.descendants(matching: .any)["longhaul.status"]
        XCTAssertTrue(status.waitForExistence(timeout: 10))
        let start = app.descendants(matching: .any)["longhaul.start"]
        XCTAssertTrue(start.waitForExistence(timeout: 10))
        start.tap()
        XCTAssertTrue(probe.wait(for: .running, timeout: 30), "observed events: \(probe.snapshot())")
        let outcome = probe.waitForOutcome(app: app, timeout: 20)
        XCTAssertEqual(outcome, .failed, "observed events: \(probe.snapshot())")
    }

    @MainActor
    private func runStress(
        mode: String,
        targetDuration: TimeInterval
    ) throws {
        let statusToken = "longhaul-\(UUID().uuidString)"
        let probe = CmxLongHaulNotificationProbe(token: statusToken)
        let app = launchApp(mode: mode, statusToken: statusToken, stallTimeout: nil)
        _ = try openTerminal(in: app)

        let status = app.descendants(matching: .any)["longhaul.status"]
        XCTAssertTrue(status.waitForExistence(timeout: 10))
        let start = app.descendants(matching: .any)["longhaul.start"]
        XCTAssertTrue(start.waitForExistence(timeout: 10))
        start.tap()
        XCTAssertTrue(probe.wait(for: .running, timeout: 30), "observed events: \(probe.snapshot())")
        let startedAt = Date()
        let outcome = probe.waitForOutcome(app: app, timeout: targetDuration + 180)
        XCTAssertEqual(outcome, .complete, "observed events: \(probe.snapshot())")
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(startedAt), targetDuration - 1)
    }

    @MainActor
    private func launchApp(
        mode: String,
        statusToken: String,
        stallTimeout: TimeInterval?
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
        if let stallTimeout {
            app.launchEnvironment["CMUX_IOS_LONG_HAUL_STALL_TIMEOUT_SECONDS"] = "\(stallTimeout)"
        } else if let stallTimeout = ProcessInfo.processInfo.environment["CMUX_IOS_LONG_HAUL_STALL_TIMEOUT_SECONDS"] {
            app.launchEnvironment["CMUX_IOS_LONG_HAUL_STALL_TIMEOUT_SECONDS"] = stallTimeout
        } else {
            app.launchEnvironment["CMUX_IOS_LONG_HAUL_STALL_TIMEOUT_SECONDS"] = "20"
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

    private static let directTicket = #"{"version":1,"alpn":"/cmux/cmx/3","endpoint":{"id":"ui-test-endpoint","addrs":[]},"auth":{"mode":"direct"},"node":{"id":"ui-test-node","name":"UI Test Mac","subtitle":"Ghostty echo session","kind":"macbook"}}"#
}

private final class CmxLongHaulNotificationProbe {
    enum Outcome: Equatable {
        case complete
        case failed
        case appExited
        case timedOut
    }

    enum Event: String, CaseIterable {
        case running
        case complete
        case failed
    }

    private let token: String
    private let prefix: String
    private let lock = NSLock()
    private var counts: [Event: Int] = [:]

    init(token: String) {
        self.token = token
        self.prefix = "dev.cmux.ios.longhaul.\(token)."
        for event in Event.allCases {
            addObserver(named: "\(prefix)\(event.rawValue)")
        }
    }

    deinit {
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
    func waitForOutcome(app: XCUIApplication, timeout: TimeInterval) -> Outcome {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if hasSeen(.complete) {
                return .complete
            }
            if hasSeen(.failed) {
                return .failed
            }
            if app.state == .notRunning {
                return .appExited
            }
            RunLoop.current.run(until: Date().addingTimeInterval(1))
        }
        if hasSeen(.complete) {
            return .complete
        }
        if hasSeen(.failed) {
            return .failed
        }
        return .timedOut
    }

    func snapshot() -> String {
        lock.lock()
        defer { lock.unlock() }
        let events = Event.allCases
            .map { "\($0.rawValue)=\(counts[$0, default: 0])" }
            .joined(separator: " ")
        return events
    }

    func hasSeen(_ event: Event) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return counts[event, default: 0] > 0
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
        }
        lock.unlock()
    }
}
