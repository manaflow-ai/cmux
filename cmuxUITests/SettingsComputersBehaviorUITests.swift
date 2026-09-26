import XCTest

/// Devices is its own Settings section under Remote & Devices, directly
/// below Cloud (https://github.com/manaflow-ai/cmux/issues/14771): the group
/// reads Mobile, Cloud, Devices, Networking. It carries the My Devices
/// switches and the account's Macs, a switch flipped there persists, and
/// search and `cmux settings open computers` both land on it. My Devices runs
/// only while Cloud Machines is on, so the switches are disabled, with the
/// reason shown, while it is off. (Refresh is asserted present and on screen,
/// never enabled: the signed-out test app disables it regardless.)
final class SettingsComputersBehaviorUITests: SettingsUITestCase {
    private let discoveryKey = "devices.discovery.enabled"
    private let discoveryToggleID = "SettingsComputersDiscoveryToggle"
    private let incomingAccessToggleID = "SettingsComputersIncomingAccessToggle"
    private let refreshButtonID = "SettingsComputersRefresh"
    private var cloudOnArguments: [String] { cloudArguments(betaEnabled: true) }

    override func setUp() {
        super.setUp()
        // Fresh installs leave discovery off; start every run from that default.
        resetDefaults([discoveryKey])
    }

    override func tearDown() {
        resetDefaults([discoveryKey])
        super.tearDown()
    }

    /// Forces the Cloud Machines flag on and sets the Beta Features opt-in.
    /// Plist-typed booleans: the flag reader accepts only real booleans, so a
    /// bare "YES" string via the argument domain never enables it. The
    /// argument domain also reaches a tagged bundle's defaults, which a write
    /// to a fixed suite would miss.
    private func cloudArguments(betaEnabled: Bool) -> [String] {
        [
            "-cmux.flags.override.cloud-machines-enabled-release", "<true/>",
            "-cloud.beta.machines.enabled", betaEnabled ? "<true/>" : "<false/>",
        ]
    }

    func testDevicesSectionShowsDiscoveryAndAccessControls() {
        let app = makeLaunchedApp(additionalArguments: cloudOnArguments)
        var window = openSettings(app)

        let before = XCTAttachment(screenshot: window.screenshot())
        before.name = "Settings sidebar with Devices under Cloud"
        before.lifetime = .keepAlways
        add(before)

        let expectedGroup = ["Mobile", "Cloud", "Devices", "Networking"]
        var group: [String] = []
        var titles: [String] = []
        let ordered = poll(timeout: 5) {
            titles = sidebarTexts(window).map(\.title)
            group = rows(of: "Remote & Devices", in: titles, count: expectedGroup.count)
            return group == expectedGroup
        }
        XCTAssertTrue(ordered, "Remote & Devices should list Devices immediately after Cloud: read \(group) from sidebar \(titles)")

        navigate(window, to: "Devices")
        let discovery = toggle(window, id: discoveryToggleID)
        let incomingAccess = toggle(window, id: incomingAccessToggleID)
        let refresh = window.buttons[refreshButtonID]
        XCTAssertTrue(window.descendants(matching: .any)["SettingsComputersHeading"].exists)
        XCTAssertTrue(poll(timeout: 4) { self.isVisible(discovery, in: window) }, "navigating to Devices should scroll Discover other Macs into view")
        XCTAssertTrue(poll(timeout: 4) { self.isVisible(incomingAccess, in: window) }, "navigating to Devices should scroll Make this Mac discoverable into view")
        XCTAssertTrue(poll(timeout: 4) { self.isVisible(refresh, in: window) }, "navigating to Devices should scroll Refresh into view")

        let after = XCTAttachment(screenshot: window.screenshot())
        after.name = "Devices section with discovery and access switches"
        after.lifetime = .keepAlways
        add(after)

        XCTAssertTrue(poll(timeout: 4) { discovery.isEnabled }, "Discover other Macs should be switchable while Cloud Machines is on")
        XCTAssertTrue(poll(timeout: 4) { !self.isToggleOn(discovery) }, "Discover other Macs should start off")
        discovery.click()
        XCTAssertTrue(poll(timeout: 4) { self.isToggleOn(discovery) }, "Discover other Macs should read on after a click")

        // The switch writes the shared My Devices preference, so a fresh
        // Settings window reads the new value back.
        closeSettings(app, window)
        window = openSettings(app)
        defer { closeSettings(app, window) }
        navigate(window, to: "Devices")
        let reopened = toggle(window, id: discoveryToggleID)
        XCTAssertTrue(poll(timeout: 4) { self.isToggleOn(reopened) }, "Discover other Macs should stay on after reopening Settings")
    }

    /// The detail pane is one scrolling stack, so "the Mobile page" is the
    /// span from Mobile's header down to the next section's header, Cloud.
    /// None of the Devices controls may sit inside it.
    func testMobilePageNoLongerShowsDevicesControls() {
        let app = makeLaunchedApp(additionalArguments: cloudOnArguments)
        let window = openSettings(app)
        defer { closeSettings(app, window) }

        navigate(window, to: "Mobile")
        let mobileHeader = detailHeader(window, "Mobile")
        let cloudHeader = detailHeader(window, "Cloud")
        let controls = [
            ("Discover other Macs", toggle(window, id: discoveryToggleID)),
            ("Make this Mac discoverable", toggle(window, id: incomingAccessToggleID)),
            ("Refresh", requireElement(candidates: [window.buttons[refreshButtonID]], timeout: 4, description: "Refresh")),
        ]

        let screenshot = XCTAttachment(screenshot: window.screenshot())
        screenshot.name = "Mobile section without the Devices controls"
        screenshot.lifetime = .keepAlways
        add(screenshot)

        XCTAssertLessThan(mobileHeader.frame.minY, cloudHeader.frame.minY, "Cloud should follow Mobile in the detail pane")
        for (name, control) in controls {
            XCTAssertGreaterThan(
                control.frame.minY,
                cloudHeader.frame.minY,
                "\(name) should sit below Cloud in Devices, not on the Mobile page"
            )
        }
    }

    func testSettingsSearchLandsOnDevices() {
        let app = makeLaunchedApp(additionalArguments: cloudOnArguments)
        let window = openSettings(app)
        defer { closeSettings(app, window) }
        navigate(window, to: "Mobile")

        let search = requireElement(candidates: [window.searchFields.firstMatch], timeout: 5, description: "Settings search field")
        search.click()
        search.typeText("devices")
        // A section result is one line titled Devices; a setting result
        // carries its own title with Devices underneath.
        var first: (title: String, frame: CGRect)?
        var titles: [String] = []
        XCTAssertTrue(
            poll(timeout: 5) {
                let texts = sidebarTexts(window)
                titles = texts.map(\.title)
                first = texts.first
                return first?.title == "Devices"
            },
            "Searching devices should rank the Devices section first: read \(titles)"
        )
        let sidebar = sidebarList(window)
        let row = first?.frame ?? .zero
        sidebar.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: row.midX - sidebar.frame.minX, dy: row.midY - sidebar.frame.minY))
            .click()
        assertLandedOnDevices(window, after: "Choosing the Devices search result")
    }

    func testSettingsOpenComputersCommandLandsOnDevices() throws {
        // Same socket location as the other socket-driven UI tests: /tmp is
        // reachable by both the runner and the app, and short enough for sun_path.
        let socketPath = "/tmp/cmux-ui-test-devices-\(UUID().uuidString.prefix(8)).sock"
        defer {
            try? FileManager.default.removeItem(atPath: socketPath)
            try? FileManager.default.removeItem(atPath: socketPath + ".lock")
        }
        let cli = try bundledCLIPath()

        let app = XCUIApplication.cmuxTestApplication()
        app.launchArguments += settingsLaunchArguments + cloudOnArguments + ["-socketControlMode", "allowAll"]
        app.launchEnvironment["CMUX_UI_TEST_MODE"] = "1"
        app.launchEnvironment["CMUX_SOCKET_PATH"] = socketPath
        app.launchEnvironment["CMUX_SOCKET_ENABLE"] = "1"
        app.launchEnvironment["CMUX_SOCKET_MODE"] = "allowAll"
        app.launchEnvironment["CMUX_ALLOW_SOCKET_OVERRIDE"] = "1"
        launchAndActivate(app)
        XCTAssertTrue(waitForWindowCount(atLeast: 1, app: app, timeout: 8.0), "main window did not appear")

        // With Settings closed, the command opens it on Devices.
        openComputers(cli: cli, socketPath: socketPath)
        let window = app.windows["Settings"]
        XCTAssertTrue(poll(timeout: 8) { window.exists }, "cmux settings open computers should open Settings")
        defer { closeSettings(app, window) }
        assertLandedOnDevices(window, after: "cmux settings open computers")

        // From another section, the command moves the open window to Devices.
        navigate(window, to: "Mobile")
        let mobileHeader = detailHeader(window, "Mobile")
        XCTAssertTrue(poll(timeout: 4) { self.isVisible(mobileHeader, in: window) }, "Mobile should be on screen before the command")
        openComputers(cli: cli, socketPath: socketPath)
        assertLandedOnDevices(window, after: "cmux settings open computers from Mobile")
    }

    func testDevicesSwitchesAreDisabledWhileCloudMachinesIsOff() {
        let app = makeLaunchedApp(additionalArguments: cloudArguments(betaEnabled: false))
        let window = openSettings(app)
        defer { closeSettings(app, window) }

        navigate(window, to: "Devices")
        let discovery = toggle(window, id: discoveryToggleID)
        let incomingAccess = toggle(window, id: incomingAccessToggleID)
        // Match the note's own wording: "Beta Features" alone also matches
        // the sidebar row and would pass without the note.
        let reason = window.staticTexts
            .matching(NSPredicate(format: "label BEGINSWITH %@ OR value BEGINSWITH %@", "Turn on Cloud Machines", "Turn on Cloud Machines"))
            .firstMatch
        XCTAssertTrue(reason.waitForExistence(timeout: 4), "Devices should say to turn on Cloud Machines in Beta Features")

        let screenshot = XCTAttachment(screenshot: window.screenshot())
        screenshot.name = "Devices section while Cloud Machines is off"
        screenshot.lifetime = .keepAlways
        add(screenshot)

        XCTAssertTrue(poll(timeout: 4) { !discovery.isEnabled }, "Discover other Macs should be disabled while Cloud Machines is off")
        XCTAssertTrue(poll(timeout: 4) { !incomingAccess.isEnabled }, "Make this Mac discoverable should be disabled while Cloud Machines is off")
    }

    /// Devices is the navigation target: its header is pinned near the top
    /// of the detail pane, Cloud's header (directly above it) has scrolled
    /// away, and the section's two switches and Refresh are on screen.
    private func assertLandedOnDevices(_ window: XCUIElement, after action: String, line: UInt = #line) {
        var devices: CGRect?
        var cloud: CGRect?
        var viewport = CGRect.zero
        XCTAssertTrue(
            poll(timeout: 6) {
                viewport = self.detailViewport(window)
                devices = self.detailHeaderFrame(window, "Devices")
                cloud = self.detailHeaderFrame(window, "Cloud")
                guard let devices, let cloud else { return false }
                return viewport.contains(CGPoint(x: devices.midX, y: devices.midY))
                    && devices.minY < viewport.minY + viewport.height / 3
                    && !viewport.contains(CGPoint(x: cloud.midX, y: cloud.midY))
            },
            "\(action) should pin the Devices header to the top of Settings: Devices at \(String(describing: devices)), Cloud at \(String(describing: cloud)), viewport \(viewport)",
            line: line
        )
        let controls = [
            toggle(window, id: discoveryToggleID),
            toggle(window, id: incomingAccessToggleID),
            window.buttons[refreshButtonID],
        ]
        XCTAssertTrue(
            poll(timeout: 4) { controls.allSatisfy { self.isVisible($0, in: window) } },
            "\(action) should show both Devices switches and Refresh",
            line: line
        )
        let screenshot = XCTAttachment(screenshot: window.screenshot())
        screenshot.name = "Devices after \(action)"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    /// The detail pane's visible rect: its scroll view, not the sidebar's.
    private func detailViewport(_ window: XCUIElement) -> CGRect {
        let sidebarMaxX = sidebarList(window).frame.maxX
        let bounds = window.frame.insetBy(dx: -1, dy: -1)
        let detail = window.scrollViews.allElementsBoundByIndex
            .map(\.frame)
            .filter { $0.minX >= sidebarMaxX - 2 && !$0.isEmpty && bounds.contains($0) }
            .max { $0.width * $0.height < $1.width * $1.height }
        return detail ?? window.frame
    }

    /// Whether `element`'s center is inside the detail pane's visible rect.
    /// Works for disabled controls, which `isHittable` does not promise.
    private func isVisible(_ element: XCUIElement, in window: XCUIElement) -> Bool {
        guard element.exists else { return false }
        let frame = element.frame
        return !frame.isEmpty && detailViewport(window).contains(CGPoint(x: frame.midX, y: frame.midY))
    }

    /// Runs the bundled CLI against the test app's socket, retrying while the
    /// socket comes up.
    private func openComputers(cli: String, socketPath: String) {
        var result: (status: Int32, output: String) = (-1, "")
        let succeeded = poll(timeout: 30, interval: 0.5) {
            result = runCLI(cli, ["--socket", socketPath, "settings", "open", "computers"])
            return result.status == 0
        }
        XCTAssertTrue(succeeded, "cmux settings open computers failed: exit \(result.status) \(result.output)")
    }

    private func runCLI(_ path: String, _ arguments: [String]) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["CMUXTERM_CLI_RESPONSE_TIMEOUT_SEC"] = "5"
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            return (-1, "could not run \(path): \(error.localizedDescription)")
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }

    /// The `cmux` CLI bundled in the app under test, next to this runner.
    private func bundledCLIPath() throws -> String {
        let products = Bundle(for: Self.self).bundleURL
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let cli = try XCTUnwrap(
            ["cmux DEV", "cmux"]
                .map { products.appendingPathComponent("\($0).app/Contents/Resources/bin/cmux").path }
                .first { FileManager.default.isExecutableFile(atPath: $0) },
            "bundled cmux CLI not found under \(products.path)"
        )
        return cli
    }

    /// The Settings sidebar list.
    private func sidebarList(_ window: XCUIElement) -> XCUIElement {
        let outline = window.outlines.firstMatch
        return outline.exists ? outline : window.tables.firstMatch
    }

    /// The sidebar's texts top to bottom: group headers and row titles while
    /// browsing, result titles and their section subtitles while searching.
    private func sidebarTexts(_ window: XCUIElement) -> [(title: String, frame: CGRect)] {
        guard let root = try? sidebarList(window).snapshot() else { return [] }
        var texts: [(title: String, frame: CGRect)] = []
        func collect(_ node: XCUIElementSnapshot) {
            if node.elementType == .staticText {
                let title = node.label.isEmpty ? (node.value as? String ?? "") : node.label
                if !title.isEmpty { texts.append((title, node.frame)) }
            }
            node.children.forEach(collect)
        }
        collect(root)
        return texts.sorted { ($0.frame.minY, $0.frame.minX) < ($1.frame.minY, $1.frame.minX) }
    }

    /// The `count` sidebar rows under the group header `header`.
    private func rows(of header: String, in titles: [String], count: Int) -> [String] {
        guard let index = titles.firstIndex(where: { $0.caseInsensitiveCompare(header) == .orderedSame }) else { return [] }
        return Array(titles[(index + 1)...].prefix(count))
    }

    /// The detail pane's section header titled `title`, not the sidebar row
    /// with the same text.
    private func detailHeader(_ window: XCUIElement, _ title: String) -> XCUIElement {
        let sidebar = sidebarList(window)
        let matches = window.staticTexts.matching(NSPredicate(format: "label == %@ OR value == %@", title, title))
        var header: XCUIElement?
        _ = poll(timeout: 5) {
            let sidebarMaxX = sidebar.frame.maxX
            header = matches.allElementsBoundByIndex
                .filter { $0.frame.minX >= sidebarMaxX }
                .min { $0.frame.minY < $1.frame.minY }
            return header != nil
        }
        XCTAssertNotNil(header, "Expected the \(title) section header in the Settings detail pane")
        return header ?? matches.firstMatch
    }

    /// The current frame of the detail pane's `title` header, read fresh so
    /// it tracks scrolling; nil while it is missing.
    private func detailHeaderFrame(_ window: XCUIElement, _ title: String) -> CGRect? {
        let sidebarMaxX = sidebarList(window).frame.maxX
        return window.staticTexts
            .matching(NSPredicate(format: "label == %@ OR value == %@", title, title))
            .allElementsBoundByIndex
            .map(\.frame)
            .filter { $0.minX >= sidebarMaxX && !$0.isEmpty }
            .min { $0.minY < $1.minY }
    }

    /// Reads a SwiftUI `Toggle`'s state across the control kinds it can
    /// surface as in XCUITest.
    private func isToggleOn(_ element: XCUIElement) -> Bool {
        if let value = element.value as? String { return value == "1" }
        if let value = element.value as? Bool { return value }
        return element.isSelected
    }
}
