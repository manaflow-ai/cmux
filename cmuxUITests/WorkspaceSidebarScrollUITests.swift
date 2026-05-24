import Foundation
import XCTest

final class WorkspaceSidebarScrollUITests: XCTestCase {
    private let topTitlebarWorkspaceClearance: CGFloat = 32
    private let rowHeightTolerance: CGFloat = 0.25
    private let maxSidebarOverflowWorkspaceCount = 80
    private var notificationTriggerPath = ""
    private var notificationStatePath = ""
    private var rowHeightProbePath = ""
    private var notificationRequestName = ""
    private var notificationStateName = ""
    private var rowHeightProbeNotificationName = ""
    private var temporaryDirectoryPath = ""
    private var appLogPath = ""
    private var launchTag = ""
    private var appProcess: Process?
    private var sidebarHeightProbeApp: XCUIApplication?
    private let sidebarHeightObservationLock = NSLock()
    private var observedNotificationState: [String: String] = [:]
    private var observedSidebarHeightProbeEvents: [SidebarHeightProbe] = []

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        let token = UUID().uuidString
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-ui-test-sidebar-height-\(token)", isDirectory: true)
        try? FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        temporaryDirectoryPath = temporaryDirectory.path
        notificationTriggerPath = temporaryDirectory.appendingPathComponent("trigger").path
        notificationStatePath = temporaryDirectory.appendingPathComponent("state.json").path
        rowHeightProbePath = temporaryDirectory.appendingPathComponent("row.json").path
        appLogPath = temporaryDirectory.appendingPathComponent("app.log").path
        notificationRequestName = "dev.cmux.ui.sidebarRowHeight.request.\(token)"
        notificationStateName = "dev.cmux.ui.sidebarRowHeight.state.\(token)"
        rowHeightProbeNotificationName = "dev.cmux.ui.sidebarRowHeight.probe.\(token)"
        launchTag = "ui-sidebar-\(UUID().uuidString.prefix(8))"
        observedNotificationState = [:]
        observedSidebarHeightProbeEvents = []
        installSidebarHeightNotificationObservers()
        try? FileManager.default.removeItem(atPath: notificationTriggerPath)
        try? FileManager.default.removeItem(atPath: notificationStatePath)
        try? FileManager.default.removeItem(atPath: rowHeightProbePath)
    }

    override func tearDown() {
        sidebarHeightProbeApp?.terminate()
        sidebarHeightProbeApp = nil
        terminateAppProcess()
        removeSidebarHeightNotificationObservers()
        try? FileManager.default.removeItem(atPath: notificationTriggerPath)
        try? FileManager.default.removeItem(atPath: notificationStatePath)
        try? FileManager.default.removeItem(atPath: rowHeightProbePath)
        if !temporaryDirectoryPath.isEmpty {
            try? FileManager.default.removeItem(atPath: temporaryDirectoryPath)
        }
        super.tearDown()
    }

    func testWorkspaceSelectionKeepsSidebarRowVisible() {
        let app = XCUIApplication()
        configureLaunch(app)
        launchAndEnsureRunning(app)
        XCTAssertTrue(waitForWindowCount(atLeast: 1, app: app, timeout: 8.0), "Expected a main window")
        XCTAssertTrue(
            waitForWorkspaceRowHittable(index: 1, count: 1, app: app, timeout: 8.0),
            "Expected the initial workspace row to be visible"
        )

        let workspaceCount = 20
        for expectedCount in 2...workspaceCount {
            app.typeKey("n", modifierFlags: [.command])
            XCTAssertTrue(
                waitForWorkspaceRowHittable(index: expectedCount, count: expectedCount, app: app, timeout: 6.0),
                "Expected the newly selected workspace \(expectedCount) to be visible"
            )
        }

        XCTAssertTrue(
            waitForWorkspaceRowHittable(index: workspaceCount, count: workspaceCount, app: app, timeout: 6.0),
            "Expected the newly selected bottom workspace to be visible"
        )

        app.typeKey("1", modifierFlags: [.command])
        XCTAssertTrue(
            waitForWorkspaceRowHittable(index: 1, count: workspaceCount, app: app, timeout: 6.0),
            "Expected Cmd+1 to scroll the first workspace back into view"
        )
        XCTAssertTrue(
            waitForWorkspaceRowClearsTitlebar(index: 1, count: workspaceCount, app: app, timeout: 6.0),
            "Expected Cmd+1 to keep the first workspace below the titlebar controls"
        )
    }

    func testCommandPaletteMoveWorkspaceToTopKeepsMovedWorkspaceVisible() {
        let app = XCUIApplication()
        configureLaunch(app)
        launchAndEnsureRunning(app)
        XCTAssertTrue(waitForWindowCount(atLeast: 1, app: app, timeout: 8.0), "Expected a main window")
        XCTAssertTrue(
            waitForWorkspaceRowHittable(index: 1, count: 1, app: app, timeout: 8.0),
            "Expected the initial workspace row to be visible"
        )

        let workspaceCount = 20
        for expectedCount in 2...workspaceCount {
            app.typeKey("n", modifierFlags: [.command])
            XCTAssertTrue(
                waitForWorkspaceRowHittable(index: expectedCount, count: expectedCount, app: app, timeout: 6.0),
                "Expected the newly selected workspace \(expectedCount) to be visible"
            )
        }

        runCommandPaletteMoveToTop(app: app)

        XCTAssertTrue(
            waitForWorkspaceRowHittable(index: 1, count: workspaceCount, app: app, timeout: 6.0),
            "Expected Cmd+Shift+P Move to Top to scroll the moved workspace back into view"
        )
    }

    func testSidebarScrollerVisibilityFollowsWorkspaceOverflow() {
        let app = XCUIApplication()
        configureLaunch(app)
        launchAndEnsureRunning(app)
        XCTAssertTrue(waitForWindowCount(atLeast: 1, app: app, timeout: 8.0), "Expected a main window")
        XCTAssertTrue(
            waitForWorkspaceRowHittable(index: 1, count: 1, app: app, timeout: 8.0),
            "Expected the initial workspace row to be visible"
        )

        let sidebar = app.descendants(matching: .any)["Sidebar"].firstMatch
        XCTAssertTrue(sidebar.waitForExistence(timeout: 5.0), "Expected the workspace sidebar to exist")
        XCTAssertTrue(
            waitForSidebarVerticalScrollerHidden(app: app, sidebar: sidebar, timeout: 4.0),
            "Expected the sidebar scroller to hide when the workspace content fits"
        )

        let overflowProbeStartCount = sidebarOverflowProbeStartCount(app: app, sidebar: sidebar)
        var overflowReached = false
        for expectedCount in 2...maxSidebarOverflowWorkspaceCount {
            app.typeKey("n", modifierFlags: [.command])
            XCTAssertTrue(
                waitForWorkspaceRowHittable(index: expectedCount, count: expectedCount, app: app, timeout: 6.0),
                "Expected the newly selected workspace \(expectedCount) to be visible"
            )

            guard expectedCount >= overflowProbeStartCount else { continue }
            if revealSidebarVerticalScroller(app: app, sidebar: sidebar, timeout: 1.0) {
                overflowReached = true
                break
            }
        }

        XCTAssertTrue(
            overflowReached,
            "Expected the sidebar scroller to appear before creating \(maxSidebarOverflowWorkspaceCount) workspaces"
        )
    }

    func testCompactWorkspaceRowHeightStaysStableWhenNotificationAppears() throws {
        try launchSidebarHeightProbeApp()
        XCTAssertTrue(
            waitForNotificationStateValue(key: "ready", value: "1", timeout: 20.0),
            "Expected the sidebar row height notification test trigger to become ready. \(sidebarHeightProbeDiagnostics())"
        )

        guard let baselineProbe = waitForSidebarHeightProbe(
            timeout: 4.0,
            matching: { $0.index == 1 && $0.count == 1 && $0.isSelected && $0.unreadCount == 0 }
        ) else {
            XCTFail("Expected first row baseline height probe data. \(sidebarHeightProbeDiagnostics())")
            return
        }
        XCTAssertGreaterThan(baselineProbe.height, 10, "Expected the baseline row probe to measure a laid-out row")

        try triggerSidebarHeightNotification()
        XCTAssertTrue(
            waitForNotificationStateValue(key: "notified", value: "1", timeout: 4.0),
            "Expected the sidebar row height notification trigger to deliver"
        )
        let notificationProbes = waitForSidebarHeightProbeEvents(
            timeout: 8.0,
            matching: { $0.index == 1 && $0.count == 1 && $0.isSelected && $0.unreadCount > 0 }
        )
        guard !notificationProbes.isEmpty else {
            XCTFail("Expected first row height probe data after notification. \(sidebarHeightProbeDiagnostics())")
            return
        }
        print(
            "Sidebar row height baseline=\(baselineProbe.height) notificationHeights=\(notificationProbes.map(\.height))"
        )
        for notificationProbe in notificationProbes {
            XCTAssertGreaterThan(notificationProbe.height, 10, "Expected the notification row probe to measure a laid-out row")
            XCTAssertEqual(
                notificationProbe.height,
                baselineProbe.height,
                accuracy: rowHeightTolerance,
                "Compact sidebar workspace row layout must not grow when the unread notification badge appears"
            )
        }
    }

    private func configureLaunch(_ app: XCUIApplication) {
        app.launchArguments += baseLaunchArguments
        baseLaunchEnvironment.forEach { key, value in
            app.launchEnvironment[key] = value
        }
    }

    private var baseLaunchArguments: [String] {
        ["-newWorkspacePlacement", "end", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
    }

    private var baseLaunchEnvironment: [String: String] {
        [
            "CMUX_UI_TEST_MODE": "1",
            "CMUX_TAG": launchTag,
        ]
    }

    private var compactSidebarLaunchArguments: [String] {
        [
            "-sidebarHideAllDetails", "true",
            "-sidebarShowWorkspaceDescription", "false",
            "-sidebarShowNotificationMessage", "false",
            "-sidebarShowBranchDirectory", "false",
            "-sidebarShowPullRequest", "false",
            "-sidebarShowSSH", "false",
            "-sidebarShowPorts", "false",
            "-sidebarShowLog", "false",
            "-sidebarShowProgress", "false",
            "-sidebarShowStatusPills", "false",
        ]
    }

    private func configureSidebarHeightProbeLaunch(_ app: XCUIApplication) {
        configureLaunch(app)
        app.launchArguments += compactSidebarLaunchArguments + sidebarHeightNotificationLaunchArguments
        sidebarHeightNotificationLaunchEnvironment.forEach { key, value in
            app.launchEnvironment[key] = value
        }
    }

    private var sidebarHeightNotificationLaunchEnvironment: [String: String] {
        var environment = [
            "CMUX_UI_TEST_SIDEBAR_ROW_HEIGHT_NOTIFICATION_SETUP": "1",
            "CMUX_UI_TEST_SIDEBAR_ROW_HEIGHT_NOTIFICATION_TRIGGER_PATH": notificationTriggerPath,
            "CMUX_UI_TEST_SIDEBAR_ROW_HEIGHT_NOTIFICATION_STATE_PATH": notificationStatePath,
            "CMUX_UI_TEST_SIDEBAR_ROW_HEIGHT_NOTIFICATION_TARGET": "first",
            "CMUX_UI_TEST_SIDEBAR_ROW_HEIGHT_PROBE": "1",
            "CMUX_UI_TEST_SIDEBAR_ROW_HEIGHT_PROBE_PATH": rowHeightProbePath,
            "CMUX_UI_TEST_SIDEBAR_ROW_HEIGHT_PROBE_NAME": rowHeightProbeNotificationName,
            "CMUX_UI_TEST_SIDEBAR_ROW_HEIGHT_TITLE_FONT_SIZE": "1",
            "CMUX_UI_TEST_SIDEBAR_ROW_HEIGHT_TITLE_HEIGHT": "1",
        ]
        if usesXCTestManagedSidebarHeightLaunch {
            environment["CMUX_UI_TEST_SIDEBAR_ROW_HEIGHT_NOTIFICATION_REQUEST_NAME"] = notificationRequestName
            environment["CMUX_UI_TEST_SIDEBAR_ROW_HEIGHT_NOTIFICATION_STATE_NAME"] = notificationStateName
        }
        return environment
    }

    private var sidebarHeightNotificationLaunchArguments: [String] {
        var arguments = [
            "-CMUX_UI_TEST_SIDEBAR_ROW_HEIGHT_NOTIFICATION_SETUP", "1",
            "-CMUX_UI_TEST_SIDEBAR_ROW_HEIGHT_NOTIFICATION_TRIGGER_PATH", notificationTriggerPath,
            "-CMUX_UI_TEST_SIDEBAR_ROW_HEIGHT_NOTIFICATION_STATE_PATH", notificationStatePath,
            "-CMUX_UI_TEST_SIDEBAR_ROW_HEIGHT_NOTIFICATION_TARGET", "first",
            "-CMUX_UI_TEST_SIDEBAR_ROW_HEIGHT_PROBE", "1",
            "-CMUX_UI_TEST_SIDEBAR_ROW_HEIGHT_PROBE_PATH", rowHeightProbePath,
            "-CMUX_UI_TEST_SIDEBAR_ROW_HEIGHT_PROBE_NAME", rowHeightProbeNotificationName,
            "-CMUX_UI_TEST_SIDEBAR_ROW_HEIGHT_TITLE_FONT_SIZE", "1",
            "-CMUX_UI_TEST_SIDEBAR_ROW_HEIGHT_TITLE_HEIGHT", "1",
        ]
        if usesXCTestManagedSidebarHeightLaunch {
            arguments += [
                "-CMUX_UI_TEST_SIDEBAR_ROW_HEIGHT_NOTIFICATION_REQUEST_NAME", notificationRequestName,
                "-CMUX_UI_TEST_SIDEBAR_ROW_HEIGHT_NOTIFICATION_STATE_NAME", notificationStateName,
            ]
        }
        return arguments
    }

    private func waitForWorkspaceRowHittable(
        index: Int,
        count: Int,
        app: XCUIApplication,
        timeout: TimeInterval
    ) -> Bool {
        return pollUntil(timeout: timeout) {
            let row = workspaceRow(index: index, count: count, app: app)
            return row.exists && row.isHittable
        }
    }

    private func waitForWorkspaceRowClearsTitlebar(
        index: Int,
        count: Int,
        app: XCUIApplication,
        timeout: TimeInterval
    ) -> Bool {
        pollUntil(timeout: timeout) {
            let row = workspaceRow(index: index, count: count, app: app)
            let window = app.windows.firstMatch
            guard row.exists, row.isHittable, window.exists else { return false }
            return row.frame.minY >= window.frame.minY + topTitlebarWorkspaceClearance
        }
    }

    private func workspaceRow(index: Int, count: Int, app: XCUIApplication) -> XCUIElement {
        let position = "workspace \(index) of \(count)"
        return app.descendants(matching: .other)
            .matching(NSPredicate(format: "label ENDSWITH %@", position))
            .firstMatch
    }

    private func sidebarOverflowProbeStartCount(app: XCUIApplication, sidebar: XCUIElement) -> Int {
        let firstRow = workspaceRow(index: 1, count: 1, app: app)
        guard sidebar.exists, firstRow.exists else { return 8 }

        let rowHeight = max(firstRow.frame.height, 1)
        let visibleRows = Int(ceil(sidebar.frame.height / rowHeight))
        return min(maxSidebarOverflowWorkspaceCount, max(3, visibleRows + 1))
    }

    private func waitForWindowCount(atLeast count: Int, app: XCUIApplication, timeout: TimeInterval) -> Bool {
        pollUntil(timeout: timeout) {
            app.windows.count >= count
        }
    }

    private func waitForSidebarVerticalScrollerHidden(
        app: XCUIApplication,
        sidebar: XCUIElement,
        timeout: TimeInterval
    ) -> Bool {
        pollUntil(timeout: timeout) {
            visibleSidebarVerticalScrollers(app: app, sidebar: sidebar).isEmpty
        }
    }

    private func waitForSidebarVerticalScrollerVisible(
        app: XCUIApplication,
        sidebar: XCUIElement,
        timeout: TimeInterval
    ) -> Bool {
        pollUntil(timeout: timeout) {
            !visibleSidebarVerticalScrollers(app: app, sidebar: sidebar).isEmpty
        }
    }

    private func runCommandPaletteMoveToTop(app: XCUIApplication) {
        let searchField = app.textFields["CommandPaletteSearchField"].firstMatch
        app.typeKey("p", modifierFlags: [.command, .shift])
        XCTAssertTrue(searchField.waitForExistence(timeout: 5.0), "Expected command palette search field")
        searchField.click()
        searchField.typeText("move to top")

        let row = app.descendants(matching: .any)
            .matching(
                NSPredicate(
                    format: "identifier BEGINSWITH %@ AND value == %@",
                    "CommandPaletteResultRow.",
                    "palette.moveWorkspaceToTop"
                )
            )
            .firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5.0), "Expected Move to Top command palette row")
        row.click()
        XCTAssertTrue(
            waitForNonExistence(searchField, timeout: 5.0),
            "Expected command palette to dismiss after Move to Top"
        )
    }

    private func waitForNonExistence(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        pollUntil(timeout: timeout) {
            !element.exists
        }
    }

    private func revealSidebarVerticalScroller(
        app: XCUIApplication,
        sidebar: XCUIElement,
        timeout: TimeInterval
    ) -> Bool {
        sidebar.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.5)).hover()
        if waitForSidebarVerticalScrollerVisible(app: app, sidebar: sidebar, timeout: min(0.25, timeout)) {
            return true
        }
        sidebar.swipeUp()
        return waitForSidebarVerticalScrollerVisible(app: app, sidebar: sidebar, timeout: timeout)
    }

    private func visibleSidebarVerticalScrollers(
        app: XCUIApplication,
        sidebar: XCUIElement
    ) -> [XCUIElement] {
        guard sidebar.exists else { return [] }
        let sidebarFrame = sidebar.frame
        return app.descendants(matching: .scrollBar).allElementsBoundByIndex.filter { scroller in
            guard scroller.exists, scroller.isHittable else { return false }
            let frame = scroller.frame
            guard frame.width > 0, frame.height > frame.width else { return false }
            return frame.midX >= sidebarFrame.minX
                && frame.midX <= sidebarFrame.maxX
                && frame.maxY > sidebarFrame.minY
                && frame.minY < sidebarFrame.maxY
        }
    }

    private func launchAndEnsureRunning(_ app: XCUIApplication) {
        let options = XCTExpectedFailure.Options()
        options.isStrict = false
        XCTExpectFailure("Headless CI may launch the app without foreground activation", options: options) {
            app.launch()
        }
        XCTAssertTrue(
            pollUntil(timeout: 10.0) {
                app.state == .runningForeground || app.state == .runningBackground
            },
            "App failed to launch. state=\(app.state.rawValue)"
        )
    }

    private var usesXCTestManagedSidebarHeightLaunch: Bool {
        let environment = ProcessInfo.processInfo.environment
        if environment["GITHUB_ACTIONS"] == "true" || environment["CI"] == "true" {
            return true
        }
        return NSHomeDirectory().contains("/Users/runner/")
    }

    private func launchSidebarHeightProbeApp() throws {
        if usesXCTestManagedSidebarHeightLaunch {
            let app = XCUIApplication()
            configureSidebarHeightProbeLaunch(app)
            launchAndEnsureRunning(app)
            sidebarHeightProbeApp = app
            return
        }
        try launchAppProcessForSidebarHeightProbe()
    }

    private func launchAppProcessForSidebarHeightProbe() throws {
        let binaryPath = try resolveAppBinaryPath()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binaryPath)
        process.arguments = baseLaunchArguments + compactSidebarLaunchArguments + sidebarHeightNotificationLaunchArguments

        var environment = ProcessInfo.processInfo.environment
        for (key, value) in baseLaunchEnvironment {
            environment[key] = value
        }
        for (key, value) in sidebarHeightNotificationLaunchEnvironment {
            environment[key] = value
        }
        process.environment = environment

        FileManager.default.createFile(atPath: appLogPath, contents: nil)
        let logHandle = FileHandle(forWritingAtPath: appLogPath)
        process.standardOutput = logHandle
        process.standardError = logHandle

        try process.run()
        appProcess = process
    }

    private func resolveAppBinaryPath() throws -> String {
        let testBundle = Bundle(for: Self.self)
        let productsDir = testBundle.bundleURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let binaryPath = productsDir
            .appendingPathComponent("cmux DEV.app")
            .appendingPathComponent("Contents/MacOS/cmux DEV")
            .path
        if FileManager.default.fileExists(atPath: binaryPath) {
            return binaryPath
        }
        throw NSError(domain: "WorkspaceSidebarScrollUITests", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "App binary not found at \(binaryPath). testBundle=\(testBundle.bundleURL.path)"
        ])
    }

    private func terminateAppProcess() {
        guard let process = appProcess else { return }
        defer { appProcess = nil }
        guard process.isRunning else { return }
        process.terminate()
        let deadline = Date().addingTimeInterval(5.0)
        while process.isRunning && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        if process.isRunning {
            process.interrupt()
        }
    }

    private func triggerSidebarHeightNotification() throws {
        if usesXCTestManagedSidebarHeightLaunch {
            DistributedNotificationCenter.default().postNotificationName(
                Notification.Name(notificationRequestName),
                object: nil,
                userInfo: [:],
                deliverImmediately: true
            )
        }
        try? "notify\n".write(
            to: URL(fileURLWithPath: notificationTriggerPath),
            atomically: false,
            encoding: .utf8
        )
    }

    private func waitForNotificationStateValue(key: String, value: String, timeout: TimeInterval) -> Bool {
        pollUntil(timeout: timeout) {
            self.observedNotificationStateValue(key: key) == value
                || self.readStringState(at: self.notificationStatePath)?[key] == value
        }
    }

    private func waitForSidebarHeightProbe(
        timeout: TimeInterval,
        matching predicate: @escaping (SidebarHeightProbe) -> Bool
    ) -> SidebarHeightProbe? {
        var match: SidebarHeightProbe?
        _ = pollUntil(timeout: timeout) {
            if let probe = self.readSidebarHeightProbeEvents().last(where: predicate) {
                match = probe
                return true
            }
            return false
        }
        return match
    }

    private func waitForSidebarHeightProbeEvents(
        timeout: TimeInterval,
        matching predicate: @escaping (SidebarHeightProbe) -> Bool
    ) -> [SidebarHeightProbe] {
        var matches: [SidebarHeightProbe] = []
        _ = pollUntil(timeout: timeout) {
            matches = self.readSidebarHeightProbeEvents().filter(predicate)
            return !matches.isEmpty
        }
        return matches
    }

    private func readSidebarHeightProbeEvents() -> [SidebarHeightProbe] {
        let observedEvents = observedSidebarHeightProbeEventsSnapshot()
        guard let payload = readJSONDictionary(at: rowHeightProbePath) else { return observedEvents }
        guard let events = payload["events"] as? [[String: Any]] else {
            return observedEvents + (sidebarHeightProbe(from: payload).map { [$0] } ?? [])
        }
        return observedEvents + events.compactMap(sidebarHeightProbe(from:))
    }

    private func sidebarHeightProbe(from payload: [String: Any]) -> SidebarHeightProbe? {
        guard let unreadCount = intValue(payload["unreadCount"]),
              let height = doubleValue(payload["height"]),
              let index = intValue(payload["index"]),
              let count = intValue(payload["count"]),
              let isSelected = boolValue(payload["isSelected"]) else {
            return nil
        }
        return SidebarHeightProbe(
            height: CGFloat(height),
            unreadCount: unreadCount,
            workspaceId: payload["workspaceId"] as? String,
            index: index,
            count: count,
            isSelected: isSelected
        )
    }

    private func intValue(_ value: Any?) -> Int? {
        if let value = value as? Int {
            return value
        }
        if let value = value as? NSNumber {
            return value.intValue
        }
        if let value = value as? String {
            return Int(value)
        }
        return nil
    }

    private func doubleValue(_ value: Any?) -> Double? {
        if let value = value as? Double {
            return value
        }
        if let value = value as? NSNumber {
            return value.doubleValue
        }
        if let value = value as? String {
            return Double(value)
        }
        return nil
    }

    private func boolValue(_ value: Any?) -> Bool? {
        if let value = value as? Bool {
            return value
        }
        if let value = value as? NSNumber {
            return value.boolValue
        }
        if let value = value as? String {
            return value == "1" || value.lowercased() == "true"
        }
        return nil
    }

    private func sidebarHeightProbeDiagnostics() -> String {
        let state = readJSONDictionary(at: notificationStatePath) ?? [:]
        let probe = readJSONDictionary(at: rowHeightProbePath) ?? [:]
        let fileManager = FileManager.default
        let xctestAppState = sidebarHeightProbeApp.map { String($0.state.rawValue) } ?? "none"
        return "state=\(state) observedState=\(observedNotificationStateSnapshot()) "
            + "probe=\(probe) observedProbeEvents=\(observedSidebarHeightProbeEventsSnapshot().count) "
            + "statePath=\(notificationStatePath) stateExists=\(fileManager.fileExists(atPath: notificationStatePath)) "
            + "probePath=\(rowHeightProbePath) probeExists=\(fileManager.fileExists(atPath: rowHeightProbePath)) "
            + "appRunning=\(appProcess?.isRunning == true) xctestAppState=\(xctestAppState) "
            + "appLog=\(appLogTail()) "
            + "requestName=\(notificationRequestName)"
    }

    private func appLogTail() -> String {
        guard !appLogPath.isEmpty,
              let log = try? String(contentsOfFile: appLogPath, encoding: .utf8),
              !log.isEmpty else {
            return "<empty>"
        }
        return String(log.suffix(1200))
    }

    private func installSidebarHeightNotificationObservers() {
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(handleSidebarHeightStateNotification(_:)),
            name: Notification.Name(notificationStateName),
            object: nil,
            suspensionBehavior: .deliverImmediately
        )
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(handleSidebarHeightProbeNotification(_:)),
            name: Notification.Name(rowHeightProbeNotificationName),
            object: nil,
            suspensionBehavior: .deliverImmediately
        )
    }

    private func removeSidebarHeightNotificationObservers() {
        if !notificationStateName.isEmpty {
            DistributedNotificationCenter.default().removeObserver(
                self,
                name: Notification.Name(notificationStateName),
                object: nil
            )
        }
        if !rowHeightProbeNotificationName.isEmpty {
            DistributedNotificationCenter.default().removeObserver(
                self,
                name: Notification.Name(rowHeightProbeNotificationName),
                object: nil
            )
        }
    }

    @objc private func handleSidebarHeightStateNotification(_ notification: Notification) {
        let payload = stringKeyedPayload(from: notification)
        let updates = payload.reduce(into: [String: String]()) { result, entry in
            guard let value = entry.value as? String else { return }
            result[entry.key] = value
        }
        guard !updates.isEmpty else { return }
        sidebarHeightObservationLock.lock()
        for (key, value) in updates {
            observedNotificationState[key] = value
        }
        sidebarHeightObservationLock.unlock()
    }

    @objc private func handleSidebarHeightProbeNotification(_ notification: Notification) {
        guard let probe = sidebarHeightProbe(from: stringKeyedPayload(from: notification)) else { return }
        sidebarHeightObservationLock.lock()
        observedSidebarHeightProbeEvents.append(probe)
        sidebarHeightObservationLock.unlock()
    }

    private func stringKeyedPayload(from notification: Notification) -> [String: Any] {
        (notification.userInfo ?? [:]).reduce(into: [String: Any]()) { result, entry in
            result[String(describing: entry.key)] = entry.value
        }
    }

    private func observedNotificationStateValue(key: String) -> String? {
        sidebarHeightObservationLock.lock()
        let value = observedNotificationState[key]
        sidebarHeightObservationLock.unlock()
        return value
    }

    private func observedNotificationStateSnapshot() -> [String: String] {
        sidebarHeightObservationLock.lock()
        let snapshot = observedNotificationState
        sidebarHeightObservationLock.unlock()
        return snapshot
    }

    private func observedSidebarHeightProbeEventsSnapshot() -> [SidebarHeightProbe] {
        sidebarHeightObservationLock.lock()
        let snapshot = observedSidebarHeightProbeEvents
        sidebarHeightObservationLock.unlock()
        return snapshot
    }

    private func readStringState(at path: String) -> [String: String]? {
        guard let payload = readJSONDictionary(at: path) else { return nil }
        return payload.reduce(into: [String: String]()) { result, entry in
            if let value = entry.value as? String {
                result[entry.key] = value
            }
        }
    }

    private func readJSONDictionary(at path: String) -> [String: Any]? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return payload
    }

    private struct SidebarHeightProbe {
        let height: CGFloat
        let unreadCount: Int
        let workspaceId: String?
        let index: Int
        let count: Int
        let isSelected: Bool
    }

    private func pollUntil(
        timeout: TimeInterval,
        interval: TimeInterval = 0.05,
        condition: () -> Bool
    ) -> Bool {
        let start = ProcessInfo.processInfo.systemUptime
        while true {
            if condition() {
                return true
            }
            if ProcessInfo.processInfo.systemUptime - start >= timeout {
                return false
            }
            RunLoop.current.run(until: Date().addingTimeInterval(interval))
        }
    }
}
