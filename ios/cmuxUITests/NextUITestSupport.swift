import XCTest

/// Launch and query helpers for the cmux-next flow UI tests
/// (plans/cmux-next/ios-next/d3-dogfood.md). Shell launches are the DEBUG
/// preview: Home's mock owner without an account (`CMUX_IOS_HOME_PREVIEW=1`),
/// every feature seam on its mock (`CMUX_IOS_SOURCES=mock`), every feature
/// tab flag on, and a launch tab (`CMUX_IOS_SHELL_TAB`). No network, no
/// account, English, so labels in the assertions are the source defaults.
@MainActor
enum NextUITest {
    /// The shell tab raw values (`ShellTab`), in tab order.
    static let tabs = ["home", "feed", "workspaces", "compose", "hosts", "search", "cloud", "settings"]

    /// The root element each tab's screen carries.
    static let tabRoots: [String: String] = [
        "home": "home.screen",
        "feed": "feed.screen",
        "workspaces": "workspaces.list",
        "compose": "composer.screen",
        "hosts": "ssh.hosts.list",
        "search": "search.screen",
        "cloud": "cloud.screen",
        "settings": "shell.settings",
    ]

    /// English tab titles (`ShellTab.title` defaults), for tab bar lookups.
    static let tabTitles: [String: String] = [
        "home": "Home", "feed": "Feed", "workspaces": "Workspaces", "compose": "Compose",
        "hosts": "Hosts", "search": "Search", "cloud": "Cloud", "settings": "Settings",
    ]

    /// Launches the signed-in shell on the mock seams, optionally on `tab`.
    static func launchShell(tab: String? = nil, extra: [String: String] = [:]) -> XCUIApplication {
        var environment: [String: String] = [
            "CMUX_IOS_HOME_PREVIEW": "1",
            "CMUX_IOS_SOURCES": "mock",
            "CMUX_IOS_ONBOARDING": "0",
            "CMUX_IOS_FLAG_FEED_TAB": "1",
            "CMUX_IOS_FLAG_WORKSPACES_TAB": "1",
            "CMUX_IOS_FLAG_COMPOSE_TAB": "1",
            "CMUX_IOS_FLAG_HOSTS_TAB": "1",
            "CMUX_IOS_FLAG_SEARCH_TAB": "1",
            "CMUX_IOS_FLAG_CLOUD_TAB": "1",
        ]
        if let tab { environment["CMUX_IOS_SHELL_TAB"] = tab }
        for (key, value) in extra { environment[key] = value }
        return launch(environment)
    }

    /// Launches signed out with a fresh in-memory onboarding run
    /// (`CMUX_IOS_ONBOARDING=1`), optionally from `step`.
    static func launchOnboarding(step: String? = nil) -> XCUIApplication {
        var environment = ["CMUX_IOS_ONBOARDING": "1", "CMUX_IOS_SOURCES": "mock"]
        if let step { environment["CMUX_IOS_ONBOARDING_STEP"] = step }
        return launch(environment)
    }

    static func launch(_ environment: [String: String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        for (key, value) in environment { app.launchEnvironment[key] = value }
        app.launch()
        return app
    }

    /// Any element with `identifier` (views, cells, buttons, text).
    static func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    /// The first element whose identifier starts with `prefix`.
    static func element(_ app: XCUIApplication, prefix: String) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", prefix)).firstMatch
    }

    /// Waits until `predicate` holds for `element` or `timeout` passes.
    @discardableResult
    static func wait(_ element: XCUIElement, _ format: String, timeout: TimeInterval = 10) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: format), object: element)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    static func waitHittable(_ element: XCUIElement, timeout: TimeInterval = 10) -> Bool {
        wait(element, "exists == true AND hittable == true", timeout: timeout)
    }

    static func waitGone(_ element: XCUIElement, timeout: TimeInterval = 10) -> Bool {
        wait(element, "exists == false", timeout: timeout)
    }

    /// Scrolls the screen's main list up until `element` is hittable, at most
    /// `swipes` times. Lists build cells lazily, so off-screen rows only
    /// exist after a scroll.
    @discardableResult
    static func scrollTo(_ element: XCUIElement, in app: XCUIApplication, swipes: Int = 10) -> Bool {
        let list = app.collectionViews.firstMatch.exists ? app.collectionViews.firstMatch : app.tables.firstMatch
        var remaining = swipes
        while !(element.exists && element.isHittable) && remaining > 0 {
            if list.exists { list.swipeUp(velocity: .slow) } else { app.swipeUp(velocity: .slow) }
            remaining -= 1
        }
        return element.exists && element.isHittable
    }

    /// Taps `identifier` after scrolling it into view; fails the test when missing.
    static func tap(_ app: XCUIApplication, _ identifier: String, scroll: Bool = false,
                    file: StaticString = #filePath, line: UInt = #line) {
        let target = element(app, identifier)
        if scroll { scrollTo(target, in: app) }
        XCTAssertTrue(waitHittable(target), "\(identifier) is not on screen", file: file, line: line)
        target.tap()
    }

    /// Asserts the tab's root screen shows.
    static func assertTabRoot(_ app: XCUIApplication, _ tab: String, timeout: TimeInterval = 15,
                              file: StaticString = #filePath, line: UInt = #line) {
        let root = tabRoots[tab] ?? tab
        XCTAssertTrue(element(app, root).waitForExistence(timeout: timeout),
                      "tab \(tab): \(root) did not show", file: file, line: line)
    }
}
