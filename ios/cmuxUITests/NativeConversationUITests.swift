import XCTest

/// UI proof for the fresh native conversation flow. The fixture is a DEBUG
/// transport, so these tests exercise the production model and views while
/// remaining deterministic on isolated simulators.
final class NativeConversationUITests: XCTestCase {
    private let scenarios = ["all", "approval", "question", "files", "running", "disconnected"]

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testNativeConversationStateMatrix() throws {
        for scenario in scenarios {
            let app = launchFixture(scenario: scenario)
            defer { app.terminate() }
            try waitForTaskList(in: app)
            capture(app, name: "native-(scenario)-task-list")

            let task = app.descendants(matching: .any)["ConversationTaskRow-fixture-codex"]
            XCTAssertTrue(task.waitForExistence(timeout: 8), "fixture task row for (scenario)")
            task.tap()
            XCTAssertTrue(app.otherElements["ConversationDetail"].waitForExistence(timeout: 8))
            capture(app, name: "native-(scenario)-detail")

            switch scenario {
            case "approval":
                XCTAssertTrue(app.otherElements["ConversationBlockingRequest-fixture-approval"].waitForExistence(timeout: 5))
                capture(app, name: "native-approval-blocking-request")
            case "question":
                let question = app.otherElements["ConversationBlockingQuestion"]
                let asyncQuestion = app.otherElements["ConversationAsyncQuestion"]
                XCTAssertTrue(question.waitForExistence(timeout: 5) || asyncQuestion.waitForExistence(timeout: 5))
                capture(app, name: "native-question-request")
            case "files":
                app.buttons["ConversationActionsMenu"].tap()
                XCTAssertTrue(app.buttons["Files"].waitForExistence(timeout: 3))
                app.buttons["Files"].tap()
                XCTAssertTrue(app.otherElements["ConversationFilesSheet"].waitForExistence(timeout: 5))
                capture(app, name: "native-files-sheet")
                app.buttons["Close"].firstMatch.tap()
            case "running":
                XCTAssertTrue(app.buttons["ConversationStopButton"].waitForExistence(timeout: 5))
                capture(app, name: "native-running-stop")
                app.buttons["ConversationStopButton"].tap()
                capture(app, name: "native-running-stopped")
            case "disconnected":
                XCTAssertTrue(app.otherElements["ConversationConnectionBanner"].waitForExistence(timeout: 5) || app.images["Disconnected"].exists)
                XCTAssertFalse(app.buttons["ConversationSendButton"].isEnabled)
                capture(app, name: "native-disconnected-retained")
            default:
                let transcript = app.otherElements["ConversationTranscript"]
                XCTAssertTrue(transcript.exists)
                let send = app.buttons["ConversationSendButton"]
                XCTAssertTrue(send.waitForExistence(timeout: 5))
                let composer = app.textViews["ConversationComposerTextEditor"]
                XCTAssertTrue(composer.waitForExistence(timeout: 5))
                composer.tap()
                composer.typeText("queue this follow up")
                send.tap()
                capture(app, name: "native-queue-or-turn")
            }
        }
    }

    @MainActor
    func testNativeConversationInteractionIdentifiersAndFrames() throws {
        let app = launchFixture(scenario: "all")
        defer { app.terminate() }
        try waitForTaskList(in: app)
        app.descendants(matching: .any)["ConversationTaskRow-fixture-codex"].tap()
        XCTAssertTrue(app.otherElements["ConversationDetail"].waitForExistence(timeout: 8))

        let identifiers = [
            "ConversationDetail", "ConversationTranscript", "ConversationComposer",
            "ConversationComposerTextEditor", "ConversationSendButton", "ConversationActionsMenu",
        ]
        for identifier in identifiers {
            let element = app.descendants(matching: .any)[identifier]
            XCTAssertTrue(element.waitForExistence(timeout: 5), identifier)
        }
        let frameAttachment = XCTAttachment(data: accessibilityFrames(for: app), uniformTypeIdentifier: "public.json")
        frameAttachment.name = "native-conversation-accessibility-frames"
        frameAttachment.lifetime = .keepAlways
        add(frameAttachment)
    }

    @MainActor
    func testNativeConversationLaunchPerformance() {
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            let app = launchFixture(scenario: "all")
            _ = app.otherElements["ConversationTaskList"].waitForExistence(timeout: 8)
            app.terminate()
        }
    }

    @MainActor
    private func launchFixture(scenario: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launchEnvironment["CMUX_UITEST_MOCK_DATA"] = "0"
        app.launchEnvironment["CMUX_UITEST_CONVERSATION_FIXTURE"] = "1"
        app.launchEnvironment["CMUX_UITEST_CONVERSATION_SCENARIO"] = scenario
        app.launch()
        return app
    }

    @MainActor
    private func waitForTaskList(in app: XCUIApplication) throws {
        let list = app.otherElements["ConversationTaskList"]
        XCTAssertTrue(list.waitForExistence(timeout: 12), "native conversation task list did not appear")
    }

    @MainActor
    private func capture(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    private func accessibilityFrames(for app: XCUIApplication) -> Data {
        var entries: [[String: Any]] = []
        for element in app.descendants(matching: .any).allElementsBoundByIndex.prefix(180) {
            guard !element.identifier.isEmpty, element.exists else { continue }
            entries.append([
                "identifier": element.identifier,
                "label": element.label,
                "type": element.elementType.rawValue,
                "x": element.frame.origin.x,
                "y": element.frame.origin.y,
                "width": element.frame.width,
                "height": element.frame.height,
            ])
        }
        return (try? JSONSerialization.data(withJSONObject: entries, options: [.prettyPrinted, .sortedKeys])) ?? Data("[]".utf8)
    }
}
