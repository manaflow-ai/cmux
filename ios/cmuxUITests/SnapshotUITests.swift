import XCTest
import UIKit

/// App Store screenshot capture, driven by `fastlane snapshot` (see
/// ios/fastlane/Snapfile / Fastfile). Runs against a DEBUG build using the app's
/// standalone preview hooks, which render real UI deterministically with no
/// sign-in, Mac pairing, or network. The terminal shots replay REAL recorded
/// agent sessions (see TerminalPreviewTranscripts). Each shot is a separate
/// launch with a fresh environment; `snapshot()` is called after the screen
/// settles.
///
/// The shot roster mirrors the live App Store listing 1:1 (see
/// ios/fastlane/appstore-shots-plan.json; `ios/scripts/appstore-shots.sh`
/// post-processes captures to exact ASC pixel dimensions and stages uploads).
/// Numbering matches the listing order. 05 (lock-screen inline reply) cannot be
/// driven from XCUITest and is produced by `appstore-shots.sh lockshot`.
final class SnapshotUITests: XCTestCase {
    private let app = XCUIApplication()
    private lazy var springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")

    override func setUpWithError() throws {
        continueAfterFailure = true
    }

    @MainActor
    func testCaptureAppStoreScreenshots() throws {
        setupSnapshot(app)

        // 01/02) Claude + Codex, full terminal showing a real recorded session.
        // TARGET_COLS auto-fits the font so the 76-col fixtures fill the width
        // edge-to-edge on both iPhone and iPad. The believable workspace name
        // shown in the nav title pill belongs to each recorded transcript
        // (re-record with ios/fastlane/frame_assets/record_sessions.sh). The
        // terminal background is auto-derived from each transcript's own
        // dominant background (TerminalPreviewTranscripts.dominantBackgroundHex).
        shootTerminal("01-Claude", transcript: "claude", title: "App entry point")
        shootTerminal("02-Codex", transcript: "codex", title: "Readability pass")

        // 03) Workspace list.
        shoot("03-Workspaces", [
            "CMUX_UITEST_WORKSPACE_LIST_PREVIEW": "1",
        ])

        // 04) Notifications feed tab.
        shoot("04-Notifications", [
            "CMUX_UITEST_NOTIFICATION_FEED_PREVIEW": "1",
        ])

        // 06) Per-file diff: ChangesPreviewView mode "diff" opens directly on
        // the Sources/SessionStore.swift fixture.
        shoot("06-DiffFile", [
            "CMUX_UITEST_CHANGES_PREVIEW": "diff",
        ])

        // 07) OpenCode session.
        shootTerminal("07-Opencode", transcript: "opencode", title: "String catalogs")

        // 08) Task Composer.
        shoot("08-Composer", [
            "CMUX_UITEST_TASK_COMPOSER_PREVIEW": "1",
        ])

        // 09) A REAL agent push notification over the workspace list: the app
        // requests authorization and schedules a genuine local notification, so
        // the system renders the actual banner (real icon, "cmux" display name).
        // Source for the framed marketing pages; excluded from the 6.9" store
        // set by the plan.
        shoot("09-Banner", [
            "CMUX_UITEST_WORKSPACE_LIST_PREVIEW": "1",
            "CMUX_UITEST_NOTIFICATION_BANNER": "1",
        ], waitForRealNotification: true)

        // 10) Pi session (kept out of the store set by the plan).
        shootTerminal("10-Pi", transcript: "pi", title: "Ship improvements")
    }

    @MainActor
    private func shootTerminal(_ name: String, transcript: String, title: String) {
        shoot(name, [
            "CMUX_UITEST_TERMINAL_PREVIEW": "1",
            "CMUX_UITEST_TERMINAL_PREVIEW_CONTENT": "1",
            "CMUX_UITEST_TERMINAL_TRANSCRIPT": transcript,
            "CMUX_UITEST_TERMINAL_TARGET_COLS": "76",
            "CMUX_UITEST_TERMINAL_TITLE": title,
        ])
    }

    @MainActor
    private func shoot(_ name: String, _ env: [String: String], waitForRealNotification: Bool = false) {
        var full = env
        full["CMUX_UITEST_MOCK_DATA"] = "1"
        // Workspace detail can show a one-time educational changes hint over
        // the content. It is not listing content, so keep it out of every
        // store capture and assert that the fixture honors the contract.
        full["CMUX_UITEST_HIDE_WORKSPACE_CHANGES_HINT"] = "1"
        app.launchEnvironment = full
        app.launch()
        // The live App Store 13" iPad set is portrait full-bleed; landscape
        // remains available for framed marketing compositions via
        // SNAPSHOT_IPAD_LANDSCAPE=1 (see Fastfile).
        if UIDevice.current.userInterfaceIdiom == .pad {
            XCUIDevice.shared.orientation =
                ProcessInfo.processInfo.environment["SNAPSHOT_IPAD_LANDSCAPE"] == "1"
                    ? .landscapeLeft : .portrait
        }
        if waitForRealNotification {
            settleForNotification()
        } else {
            settle()
        }
        if full["CMUX_UITEST_HIDE_WORKSPACE_CHANGES_HINT"] == "1" {
            let hint = app.descendants(matching: .any)
                .matching(identifier: "MobileChangesHint")
                .firstMatch
            XCTAssertFalse(
                hint.waitForExistence(timeout: 1),
                "workspace changes education banner must not be present in screenshots"
            )
        }
        snapshot(name)
        app.terminate()
    }

    @MainActor
    private func settle() {
        _ = app.wait(for: .runningForeground, timeout: 15)
        _ = app.windows.firstMatch.waitForExistence(timeout: 15)
        _ = app.staticTexts.firstMatch.waitForExistence(timeout: 8)
        // Fresh simulators show a one-time "Ready for Apple Intelligence" banner
        // that overlays the top; swipe any notification banner off-screen, then
        // let layout/terminal output settle.
        let banner = springboard.otherElements["NotificationShortLookView"]
        if banner.waitForExistence(timeout: 3) {
            banner.swipeUp()
        }
        Thread.sleep(forTimeInterval: 2.5)
    }

    /// Settle path for the notification shot: grant the authorization prompt,
    /// then wait for the app's real local notification banner to appear (and
    /// leave it on screen for the snapshot).
    @MainActor
    private func settleForNotification() {
        _ = app.wait(for: .runningForeground, timeout: 15)
        _ = app.windows.firstMatch.waitForExistence(timeout: 15)
        _ = app.staticTexts.firstMatch.waitForExistence(timeout: 8)
        // The app requests notification authorization on appear; approve the
        // springboard system alert so the banner can be delivered.
        let allowLabels = ["Allow", "許可", "許可する"]
        for label in allowLabels {
            let allow = springboard.buttons[label]
            if allow.waitForExistence(timeout: 4) {
                allow.tap()
                break
            }
        }
        // The scheduled local notification fires ~0.6s after the grant and the
        // foreground banner is on screen for ~5s. Querying the banner element is
        // unreliable (it's a system-process overlay, and waiting past its
        // lifetime captures an empty screen), so snapshot at a fixed time inside
        // the banner's visible window.
        Thread.sleep(forTimeInterval: 2.5)
    }
}

/// Exercises the real Agent Chat navigation and cards against the DEBUG-only
/// typed source fixture. This is intentionally separate from the App Store
/// capture method: the screenshot lane remains deterministic while the normal
/// iPhone UI lane verifies the interactive surface.
final class AgentChatModeUITests: XCTestCase {
    @MainActor
    func testAgentChatPreviewRendersProvidersCardsAndComposer() {
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_UITEST_AGENT_CHAT_PREVIEW"] = "1"
        app.launchEnvironment["CMUX_UITEST_MOCK_DATA"] = "0"
        app.launch()
        defer { app.terminate() }

        XCTAssertTrue(app.otherElements["MobileAgentChatMode"].waitForExistence(timeout: 12))
        let claude = app.buttons["Claude, Implement the authentication flow, Needs input"]
        XCTAssertTrue(claude.waitForExistence(timeout: 8))
        claude.tap()
        XCTAssertTrue(app.otherElements["MobileAgentConversation"].waitForExistence(timeout: 8))
        let usage = app.otherElements["MobileAgentUsageContextCard"]
        XCTAssertTrue(reveal(usage, in: app), "Claude usage/context card should be reachable")
        keepScreenshot(app, named: "agent-claude-context")

        let permissionTitle = app.staticTexts["Claude wants to run"]
        XCTAssertTrue(reveal(permissionTitle, in: app), "Claude permission card should be reachable")
        let allowOnce = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Allow once")).firstMatch
        XCTAssertTrue(reveal(allowOnce, in: app), "Allow once should be reachable")
        XCTAssertTrue(app.textFields["Message your agent"].waitForExistence(timeout: 8))

        keepScreenshot(app, named: "agent-claude-permission-pending")
        allowOnce.tap()
        XCTAssertTrue(app.staticTexts["Allowed once"].waitForExistence(timeout: 5))
        let localDevelopment = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Local development")).firstMatch
        XCTAssertTrue(reveal(localDevelopment, in: app), "Claude question must remain pending after permission answer")
        keepScreenshot(app, named: "agent-claude-permission-resolved")
        localDevelopment.tap()
        XCTAssertTrue(app.staticTexts["Answered: Local development"].waitForExistence(timeout: 5))
        keepScreenshot(app, named: "agent-claude-question-resolved")

        let sessionsButton = app.buttons["Agent sessions"]
        XCTAssertTrue(sessionsButton.waitForExistence(timeout: 8))
        sessionsButton.tap()
        let search = app.searchFields["Search sessions"]
        XCTAssertTrue(search.waitForExistence(timeout: 8))
        search.tap()
        search.typeText("networking")
        XCTAssertTrue(app.staticTexts["Review the networking changes"].waitForExistence(timeout: 8))
    }

    @MainActor
    func testAgentChatPreviewCanSwitchProviderAndSendPrompt() {
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_UITEST_AGENT_CHAT_PREVIEW"] = "1"
        app.launchEnvironment["CMUX_UITEST_MOCK_DATA"] = "0"
        app.launch()
        defer { app.terminate() }

        XCTAssertTrue(app.otherElements["MobileAgentChatMode"].waitForExistence(timeout: 12))
        let codex = app.buttons["Codex, Review the networking changes, Working"]
        XCTAssertTrue(codex.waitForExistence(timeout: 8))
        codex.tap()
        XCTAssertTrue(app.otherElements["MobileAgentConversation"].waitForExistence(timeout: 8))
        let initialPrompt = app.staticTexts["Review the networking changes and summarize risks."]
        XCTAssertTrue(reveal(initialPrompt, in: app), "Codex initial prompt should be reachable")
        let usage = app.otherElements["MobileAgentUsageContextCard"]
        XCTAssertTrue(reveal(usage, in: app), "Codex usage/context card should be reachable")
        let diffPath = app.staticTexts["Sources/Network/RetryPolicy.swift"]
        XCTAssertTrue(reveal(diffPath, in: app), "Codex diff card should be reachable")
        let webSearch = app.otherElements["MobileAgentWebSearchCard"]
        XCTAssertTrue(reveal(webSearch, in: app), "Codex web-search card should be reachable")
        let markdownCode = app.staticTexts["let delay = min(8, attempt * 2)"]
        XCTAssertTrue(reveal(markdownCode, in: app), "Codex Markdown code block should be reachable")
        keepScreenshot(app, named: "agent-codex-review")

        let composer = app.textFields["Message your agent"]
        XCTAssertTrue(composer.waitForExistence(timeout: 8))
        composer.tap()
        composer.typeText("Show the failing test")
        let sendInstruction = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Send instruction")).firstMatch
        XCTAssertTrue(sendInstruction.waitForExistence(timeout: 8))
        sendInstruction.tap()
        let queue = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Queue for next turn")).firstMatch
        XCTAssertTrue(queue.waitForExistence(timeout: 8))
        queue.tap()
        let queuedBubble = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", "Queued: Show the failing test"))
            .firstMatch
        let queuedPrompt = app.staticTexts["Show the failing test"]
        let queuedVisible = reveal(queuedBubble, in: app) || reveal(queuedPrompt, in: app)
        XCTAssertTrue(queuedVisible, "Queued Codex prompt should be visible")
        keepScreenshot(app, named: "agent-codex-queued")

        let stop = app.buttons["Stop agent"]
        XCTAssertTrue(reveal(stop, in: app), "Working Codex session should expose Stop agent")
        stop.tap()
        let stopTurn = app.buttons["Stop turn"]
        XCTAssertTrue(stopTurn.waitForExistence(timeout: 5), "Stop agent menu should expose a polite stop")
        stopTurn.tap()
        XCTAssertTrue(app.buttons["Send"].waitForExistence(timeout: 8), "Interrupt should return the composer to idle send mode")
        XCTAssertTrue(reveal(queuedPrompt, in: app), "Queued follow-up must survive interrupt delivery")
        XCTAssertTrue(app.staticTexts["I received the instruction and finished this preview turn."].waitForExistence(timeout: 8))
        keepScreenshot(app, named: "agent-codex-interrupted-followup")

        let sessionsButton = app.buttons["Agent sessions"]
        XCTAssertTrue(sessionsButton.waitForExistence(timeout: 8))
        sessionsButton.tap()
        let openCode = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "OpenCode, Polish the release notes")).firstMatch
        XCTAssertTrue(openCode.waitForExistence(timeout: 8))
        openCode.tap()
        XCTAssertTrue(app.otherElements["MobileAgentConversation"].waitForExistence(timeout: 8))
        let includeMigration = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Include it")).firstMatch
        XCTAssertTrue(reveal(includeMigration, in: app), "OpenCode question should be reachable")
        keepScreenshot(app, named: "agent-opencode-question")
        includeMigration.tap()
        XCTAssertTrue(app.staticTexts["Answered: Include it"].waitForExistence(timeout: 5))
        let openCodeComposer = app.textFields["Message your agent"]
        XCTAssertTrue(openCodeComposer.waitForExistence(timeout: 8))
        openCodeComposer.tap()
        openCodeComposer.typeText("Ship it")
        app.buttons["Send"].tap()
        XCTAssertTrue(app.staticTexts["Ship it"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["I updated the release notes and kept the migration note concise."].waitForExistence(timeout: 8))
        keepScreenshot(app, named: "agent-opencode-followup")
    }

    @MainActor
    func testAgentChatPreviewDarkLargeTextKeepsProviderAndComposerVisible() {
        let app = XCUIApplication()
        app.launchArguments += [
            "-AppleInterfaceStyle", "Dark",
            "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryXXXL",
        ]
        app.launchEnvironment["CMUX_UITEST_AGENT_CHAT_PREVIEW"] = "1"
        app.launchEnvironment["CMUX_UITEST_MOCK_DATA"] = "0"
        app.launch()
        defer { app.terminate() }

        XCTAssertTrue(app.otherElements["MobileAgentChatMode"].waitForExistence(timeout: 12))
        let codex = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Codex, Review the networking changes")).firstMatch
        XCTAssertTrue(codex.waitForExistence(timeout: 8))
        codex.tap()
        XCTAssertTrue(app.otherElements["MobileAgentConversation"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.textFields["Message your agent"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["Codex"].firstMatch.exists)
        keepScreenshot(app, named: "agent-codex-dark-xxxl")
    }

    @MainActor
    func testAgentChatPreviewCanCloseAndReopenFromBothNavigationColumns() {
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_UITEST_AGENT_CHAT_PREVIEW"] = "1"
        app.launchEnvironment["CMUX_UITEST_MOCK_DATA"] = "0"
        app.launch()
        defer { app.terminate() }

        XCTAssertTrue(app.otherElements["MobileAgentChatMode"].waitForExistence(timeout: 12))
        let close = app.buttons["MobileAgentCloseMode"]
        XCTAssertTrue(close.waitForExistence(timeout: 8))
        close.tap()
        let reopen = app.buttons["OpenAgentMode"]
        XCTAssertTrue(reopen.waitForExistence(timeout: 8), "Closing the sidebar should dismiss the full-screen Agent mode")
        reopen.tap()
        XCTAssertTrue(app.otherElements["MobileAgentChatMode"].waitForExistence(timeout: 8))

        let codex = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Codex, Review the networking changes")).firstMatch
        XCTAssertTrue(codex.waitForExistence(timeout: 8))
        codex.tap()
        let options = app.buttons["Agent mode options"]
        XCTAssertTrue(options.waitForExistence(timeout: 8))
        options.tap()
        let detailClose = app.buttons["Close"]
        XCTAssertTrue(detailClose.waitForExistence(timeout: 8))
        detailClose.tap()
        XCTAssertTrue(reopen.waitForExistence(timeout: 8), "Closing from the detail navigation should dismiss Agent mode")
    }

    @MainActor
    private func reveal(_ element: XCUIElement, in app: XCUIApplication, maxSwipes: Int = 10) -> Bool {
        let transcript = app.scrollViews["MobileAgentTranscript"].exists
            ? app.scrollViews["MobileAgentTranscript"]
            : app.scrollViews.firstMatch
        for _ in 0...maxSwipes {
            if element.exists && element.isHittable { return true }
            if transcript.exists { transcript.swipeUp() } else { app.swipeUp() }
        }
        for _ in 0...maxSwipes {
            if element.exists && element.isHittable { return true }
            if transcript.exists { transcript.swipeDown() } else { app.swipeDown() }
        }
        return element.exists && element.isHittable
    }

    @MainActor
    private func keepScreenshot(_ app: XCUIApplication, named name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
