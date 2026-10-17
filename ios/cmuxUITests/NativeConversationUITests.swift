import XCTest

/// UI proof for the fresh native conversation flow. The fixture is a DEBUG
/// transport, so these tests exercise the production model and views while
/// remaining deterministic on isolated simulators.
final class NativeConversationUITests: XCTestCase {
    /// The manifest names every reviewable state. Queue lifecycle and question
    /// paging each produce multiple captures from one scenario, while still
    /// sharing setup and keeping the test runtime bounded.
    private enum MatrixState: String, CaseIterable {
        case taskList = "task-list"
        case taskDetail = "idle-composer"
        case newProviderWorkspaceTask = "new-task-provider"
        case toolExpanded = "expanded-tool"
        case steerQueueMenu = "steer-queue-menu"
        case queueLifecycle = "queued-prompt"
        case steerReceipt = "steering-receipt"
        case stopReceipt = "stop-receipt"
        case stopWithLiveTool = "stop-with-live-tool"
        case approval = "approval"
        case questionPaging = "multi-question"
        case singleQuestion = "single-question"
        case singleQuestionCustomAnswer = "custom-answer"
        case asyncQuestion = "async-question"
        case reconnectedPendingRequest = "reconnected-pending-request"
        case disconnectedRetainedTranscript = "disconnected"
        case streamingAssistantDelta = "streaming-assistant"
        case rejectedCommand = "rejected-or-uncertain-command"
        case uncertainCommand = "uncertain-command"
        case modelSettings = "provider-settings"
        case filesDiff = "file-diff"
        case emptyFiles = "empty-files"
        case noGit = "no-git"
        case noLastTurn = "no-last-turn"
        case artifactPreview = "artifact-preview"
        case emptyTask = "empty-task"
        case emptyTaskList = "empty-task-list"
        case lightMode = "light-mode"
        case largeText = "large-text"

        var fixtureScenario: String {
            switch self {
            case .approval: "approval"
            case .questionPaging: "question"
            case .singleQuestion: "single-question-custom-answer"
            case .singleQuestionCustomAnswer: "single-question-custom-answer"
            case .asyncQuestion: "async-question"
            case .reconnectedPendingRequest: "reconnected-pending-request"
            case .disconnectedRetainedTranscript: "disconnected"
            case .streamingAssistantDelta: "streaming-assistant-delta"
            case .rejectedCommand: "rejected-command"
            case .uncertainCommand: "uncertain-command"
            case .filesDiff: "files"
            case .emptyFiles: "empty-files"
            case .noGit: "no-git"
            case .noLastTurn: "no-last-turn"
            case .artifactPreview: "artifact"
            case .emptyTask: "empty"
            case .emptyTaskList: "empty-list"
            case .steerQueueMenu, .queueLifecycle: "queue"
            case .steerReceipt: "steer"
            case .stopReceipt: "running"
            case .stopWithLiveTool: "stop-with-live-tool"
            default: "all"
            }
        }
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testNativeConversationStateMatrix() throws {
        continueAfterFailure = true
        let manifest = MatrixState.allCases.map(\.rawValue)
        if let data = try? JSONSerialization.data(withJSONObject: ["states": manifest], options: [.prettyPrinted, .sortedKeys]) {
            let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
            attachment.name = "native-conversation-state-manifest.json"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        for state in MatrixState.allCases {
            do {
                try exercise(state)
            } catch {
                XCTFail("\(state.rawValue) evidence case failed before capture: \(error)")
            }
        }
    }

    @MainActor
    private func exercise(_ state: MatrixState) throws {
        let app = makeFixtureApplication(
            scenario: state.fixtureScenario,
            lightMode: state == .lightMode,
            largeText: state == .largeText
        )
        app.launch()
        defer { app.terminate() }

        switch state {
        case .taskList:
            try waitForTaskList(in: app)
            capture(app, name: "native-task-list")

        case .taskDetail:
            try openDetail(in: app)
            capture(app, name: "native-task-detail")

        case .newProviderWorkspaceTask:
            try waitForTaskList(in: app)
            let newTask = app.buttons["ConversationNewTaskButton"]
            XCTAssertTrue(newTask.waitForExistence(timeout: 8))
            newTask.tap()
            let sheet = app.otherElements["ConversationNewTaskSheet"]
            XCTAssertTrue(sheet.waitForExistence(timeout: 5))
            let provider = app.descendants(matching: .any)["ConversationProviderPicker"]
            let workspace = app.descendants(matching: .any)["ConversationWorkspace-fixture"]
            XCTAssertTrue(provider.waitForExistence(timeout: 5))
            XCTAssertTrue(workspace.waitForExistence(timeout: 5))
            capture(app, name: "native-new-provider-workspace-task")
            provider.tap()
            let claude = app.buttons["Claude Code"]
            if claude.waitForExistence(timeout: 3) { claude.tap() }
            workspace.tap()
            let start = app.buttons["Start"]
            XCTAssertTrue(start.waitForExistence(timeout: 3))
            XCTAssertTrue(start.isEnabled)
            start.tap()
            XCTAssertTrue(app.otherElements["ConversationDetail"].waitForExistence(timeout: 8))
            capture(app, name: "native-new-provider-workspace-task-created")

        case .toolExpanded:
            try openDetail(in: app)
            let tool = app.otherElements["ConversationTool-shell"]
            XCTAssertTrue(tool.waitForExistence(timeout: 5))
            tool.tap()
            capture(app, name: "native-tool-expanded")

        case .steerQueueMenu:
            try openDetail(in: app)
            let composer = app.textViews["ConversationComposerTextEditor"]
            XCTAssertTrue(composer.waitForExistence(timeout: 5))
            composer.tap()
            composer.typeText("choose queue from the long press menu")
            let send = app.buttons["ConversationSendButton"]
            XCTAssertTrue(send.waitForExistence(timeout: 5))
            send.press(forDuration: 1.0)
            let queueAction = app.buttons["Queue"]
            XCTAssertTrue(queueAction.waitForExistence(timeout: 5))
            queueAction.tap()
            XCTAssertTrue(app.otherElements["ConversationQueuedRow-0"].waitForExistence(timeout: 5))
            capture(app, name: "native-steer-queue-menu")

        case .queueLifecycle:
            try openDetail(in: app)
            let composer = app.textViews["ConversationComposerTextEditor"]
            let send = app.buttons["ConversationSendButton"]
            XCTAssertTrue(composer.waitForExistence(timeout: 5))
            XCTAssertTrue(send.waitForExistence(timeout: 5))
            composer.tap()
            composer.typeText("queued follow up")
            send.tap()
            let row = app.otherElements["ConversationQueuedRow-0"]
            XCTAssertTrue(row.waitForExistence(timeout: 5))
            XCTAssertTrue(app.otherElements["ConversationReceiptAccepted"].waitForExistence(timeout: 5))
            capture(app, name: "native-queue-add")

            row.press(forDuration: 1.0)
            let edit = app.buttons["Edit"]
            XCTAssertTrue(edit.waitForExistence(timeout: 5))
            edit.tap()
            let queuedField = app.textFields.firstMatch
            XCTAssertTrue(queuedField.waitForExistence(timeout: 5))
            queuedField.tap()
            queuedField.typeText(" edited")
            let save = app.buttons["Save"]
            XCTAssertTrue(save.waitForExistence(timeout: 3))
            save.tap()
            XCTAssertTrue(row.waitForExistence(timeout: 5))
            capture(app, name: "native-queue-edit")

            row.press(forDuration: 1.0)
            let cancel = app.buttons["Cancel"].firstMatch
            XCTAssertTrue(cancel.waitForExistence(timeout: 5))
            cancel.tap()
            XCTAssertFalse(row.waitForExistence(timeout: 3))
            let restored = composer.value as? String ?? ""
            XCTAssertTrue(restored.contains("queued follow up"), "cancel restores the queued text to the composer")
            capture(app, name: "native-queue-cancel-restored")

        case .steerReceipt:
            try openDetail(in: app)
            let composer = app.textViews["ConversationComposerTextEditor"]
            XCTAssertTrue(composer.waitForExistence(timeout: 5))
            composer.tap()
            composer.typeText("steer the current turn")
            app.buttons["ConversationSendButton"].tap()
            XCTAssertTrue(app.otherElements["ConversationReceiptApplied"].waitForExistence(timeout: 5))
            capture(app, name: "native-steer-receipt")

        case .stopReceipt:
            try openDetail(in: app)
            let stop = app.buttons["ConversationStopButton"]
            XCTAssertTrue(stop.waitForExistence(timeout: 5))
            stop.tap()
            XCTAssertTrue(app.otherElements["ConversationReceiptApplied"].waitForExistence(timeout: 5))
            capture(app, name: "native-stop-receipt")

        case .stopWithLiveTool:
            try openDetail(in: app)
            let stop = app.buttons["ConversationStopButton"]
            XCTAssertTrue(stop.waitForExistence(timeout: 5))
            XCTAssertTrue(app.otherElements["ConversationTool-shell"].waitForExistence(timeout: 5))
            stop.tap()
            XCTAssertTrue(app.otherElements["ConversationReceiptApplied"].waitForExistence(timeout: 5))
            XCTAssertTrue(app.staticTexts["Running"].waitForExistence(timeout: 5), "stopping keeps the live tool visible")
            capture(app, name: "native-stop-with-live-tool")

        case .approval:
            try openDetail(in: app)
            let request = app.otherElements["ConversationBlockingRequest-fixture-approval"]
            XCTAssertTrue(request.waitForExistence(timeout: 5))
            capture(app, name: "native-approval")
            let approve = app.buttons["Approve"]
            XCTAssertTrue(approve.waitForExistence(timeout: 3))
            approve.tap()
            XCTAssertTrue(app.otherElements["ConversationReceiptApplied"].waitForExistence(timeout: 5))
            capture(app, name: "native-approval-applied")

        case .questionPaging:
            try openDetail(in: app)
            let question = app.otherElements["ConversationBlockingQuestion"]
            XCTAssertTrue(question.waitForExistence(timeout: 5))
            XCTAssertTrue(app.staticTexts["1 of 2"].waitForExistence(timeout: 3))
            capture(app, name: "native-question-page-1")
            app.buttons["ConversationQuestionOption-yes"].tap()
            XCTAssertTrue(app.staticTexts["2 of 2"].waitForExistence(timeout: 5))
            capture(app, name: "native-question-page-2")

        case .singleQuestion:
            try openDetail(in: app)
            XCTAssertTrue(app.otherElements["ConversationBlockingQuestion"].waitForExistence(timeout: 5))
            XCTAssertTrue(app.textFields["ConversationQuestionCustomAnswer"].waitForExistence(timeout: 3))
            capture(app, name: "native-single-question")

        case .singleQuestionCustomAnswer:
            try openDetail(in: app)
            XCTAssertTrue(app.otherElements["ConversationBlockingQuestion"].waitForExistence(timeout: 5))
            let customAnswer = app.textFields["ConversationQuestionCustomAnswer"]
            XCTAssertTrue(customAnswer.waitForExistence(timeout: 3))
            capture(app, name: "native-single-question-custom-answer")
            customAnswer.tap()
            customAnswer.typeText("a custom answer")
            app.buttons["ConversationQuestionSendButton"].tap()
            XCTAssertTrue(app.otherElements["ConversationReceiptApplied"].waitForExistence(timeout: 5))
            capture(app, name: "native-single-question-custom-answer-applied")

        case .asyncQuestion:
            try openDetail(in: app)
            let question = app.otherElements["ConversationAsyncQuestion"]
            XCTAssertTrue(question.waitForExistence(timeout: 5))
            capture(app, name: "native-async-question")

        case .reconnectedPendingRequest:
            try openDetail(in: app)
            XCTAssertTrue(app.otherElements["ConversationBlockingRequest-fixture-approval"].waitForExistence(timeout: 5))
            XCTAssertTrue(app.images["Disconnected"].waitForExistence(timeout: 5))
            capture(app, name: "native-reconnected-pending-request")

        case .disconnectedRetainedTranscript:
            try openDetail(in: app)
            XCTAssertTrue(app.otherElements["ConversationTranscript"].waitForExistence(timeout: 5))
            XCTAssertTrue(app.staticTexts["Workspace is ready."].waitForExistence(timeout: 5))
            XCTAssertFalse(app.buttons["ConversationSendButton"].isEnabled)
            capture(app, name: "native-disconnected-retained-transcript")

        case .streamingAssistantDelta:
            try openDetail(in: app)
            XCTAssertTrue(app.staticTexts["Streaming"].waitForExistence(timeout: 5))
            capture(app, name: "native-streaming-assistant-initial")
            XCTAssertTrue(app.staticTexts["Streaming assistant output"].waitForExistence(timeout: 5))
            capture(app, name: "native-streaming-assistant-delta")

        case .rejectedCommand:
            try openDetail(in: app)
            let composer = app.textViews["ConversationComposerTextEditor"]
            XCTAssertTrue(composer.waitForExistence(timeout: 5))
            composer.tap()
            composer.typeText("reject this command")
            app.buttons["ConversationSendButton"].tap()
            XCTAssertTrue(app.otherElements["ConversationErrorNotice"].waitForExistence(timeout: 5))
            XCTAssertTrue((composer.value as? String ?? "").contains("reject this command"))
            capture(app, name: "native-rejected-command")

        case .uncertainCommand:
            try openDetail(in: app)
            let composer = app.textViews["ConversationComposerTextEditor"]
            XCTAssertTrue(composer.waitForExistence(timeout: 5))
            composer.tap()
            composer.typeText("uncertain command")
            app.buttons["ConversationSendButton"].tap()
            XCTAssertTrue(app.otherElements["ConversationUncertainReceipt"].waitForExistence(timeout: 5))
            XCTAssertTrue((composer.value as? String ?? "").contains("uncertain command"))
            capture(app, name: "native-uncertain-command")

        case .modelSettings:
            try openDetail(in: app)
            let actions = app.buttons["ConversationActionsMenu"]
            XCTAssertTrue(actions.waitForExistence(timeout: 5))
            actions.tap()
            let settings = app.buttons["Model and effort"]
            XCTAssertTrue(settings.waitForExistence(timeout: 3))
            settings.tap()
            XCTAssertTrue(app.otherElements["ConversationModelSettings"].waitForExistence(timeout: 5))
            XCTAssertTrue(app.descendants(matching: .any)["ConversationModelPicker"].waitForExistence(timeout: 3))
            XCTAssertTrue(app.descendants(matching: .any)["ConversationEffortPicker"].waitForExistence(timeout: 3))
            XCTAssertTrue(app.descendants(matching: .any)["ConversationSpeedPicker"].waitForExistence(timeout: 3))
            capture(app, name: "native-model-settings")
            app.buttons["ConversationSettingsDone"].tap()

        case .filesDiff:
            try openDetail(in: app)
            try openFilesSheet(in: app)
            XCTAssertTrue(app.otherElements["ConversationFilesSheet"].waitForExistence(timeout: 5))
            capture(app, name: "native-files-diff-list")
            let path = app.buttons["Sources/App.swift"]
            XCTAssertTrue(path.waitForExistence(timeout: 3))
            path.tap()
            XCTAssertTrue(app.otherElements["ConversationDiffView-Sources/App.swift"].waitForExistence(timeout: 5))
            capture(app, name: "native-files-diff-expanded")

        case .emptyFiles:
            try openDetail(in: app)
            try openFilesSheet(in: app)
            XCTAssertTrue(app.otherElements["ConversationFilesEmptyState"].waitForExistence(timeout: 5))
            capture(app, name: "native-empty-files")

        case .noGit:
            try openDetail(in: app)
            try openFilesSheet(in: app)
            XCTAssertTrue(app.otherElements["ConversationFilesEmptyState"].waitForExistence(timeout: 5))
            capture(app, name: "native-no-git")

        case .noLastTurn:
            try openDetail(in: app)
            try openFilesSheet(in: app)
            XCTAssertTrue(app.otherElements["ConversationFilesEmptyState"].waitForExistence(timeout: 5))
            capture(app, name: "native-no-last-turn")

        case .artifactPreview:
            try openDetail(in: app)
            let artifact = app.otherElements["ConversationArtifact-fixture-artifact"]
            XCTAssertTrue(artifact.waitForExistence(timeout: 5))
            artifact.tap()
            let preview = app.buttons["ConversationArtifactPreview-fixture-artifact"]
            XCTAssertTrue(preview.waitForExistence(timeout: 3))
            preview.tap()
            XCTAssertTrue(app.buttons["ConversationArtifactShare-fixture-artifact"].waitForExistence(timeout: 5))
            capture(app, name: "native-artifact-preview")

        case .emptyTask:
            try openDetail(in: app)
            XCTAssertTrue(app.otherElements["ConversationWelcome"].waitForExistence(timeout: 5))
            capture(app, name: "native-empty-task")

        case .emptyTaskList:
            try waitForTaskList(in: app)
            XCTAssertTrue(app.otherElements["ConversationEmptyState"].waitForExistence(timeout: 5))
            capture(app, name: "native-empty-task-list")

        case .lightMode:
            try openDetail(in: app)
            capture(app, name: "native-light-mode")

        case .largeText:
            try openDetail(in: app)
            capture(app, name: "native-large-text")
        }
    }

    @MainActor
    func testNativeConversationSecretQuestionUsesSecureField() throws {
        let app = makeFixtureApplication(scenario: "secret-question")
        app.launch()
        defer { app.terminate() }
        try openDetail(in: app)
        XCTAssertTrue(app.otherElements["ConversationBlockingQuestion"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.secureTextFields["ConversationQuestionCustomAnswer"].waitForExistence(timeout: 3))
        capture(app, name: "native-secret-question")
    }

    @MainActor
    func testNativeConversationInteractionIdentifiersAndFrames() throws {
        let app = makeFixtureApplication(scenario: "all")
        app.launch()
        defer { app.terminate() }
        try openDetail(in: app)

        let identifiers = [
            "ConversationDetail", "ConversationTranscript", "ConversationComposer",
            "ConversationComposerTextEditor", "ConversationSendButton", "ConversationActionsMenu",
        ]
        for identifier in identifiers {
            let element = app.descendants(matching: .any)[identifier]
            XCTAssertTrue(element.waitForExistence(timeout: 5), identifier)
        }
        capture(app, name: "native-conversation-identifiers")
    }

    @MainActor
    func testNativeConversationLaunchPerformance() {
        let app = makeFixtureApplication(scenario: "all")
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            app.launch()
            _ = app.otherElements["ConversationTaskList"].waitForExistence(timeout: 8)
            app.terminate()
        }
    }

    /// Measures the same transcript-opening and queue path covered by the
    /// matrix, with resource metrics attached to a real simulator process.
    @MainActor
    func testNativeConversationTranscriptStreamingQueuePerformance() {
        let app = makeFixtureApplication(scenario: "queue")
        measure(metrics: [
            XCTClockMetric(),
            XCTCPUMetric(application: app),
            XCTMemoryMetric(application: app),
        ]) {
            app.launch()
            let list = app.otherElements["ConversationTaskList"]
            _ = list.waitForExistence(timeout: 8)
            let task = app.descendants(matching: .any)["ConversationTaskRow-fixture-codex"]
            _ = task.waitForExistence(timeout: 8)
            task.tap()
            let detail = app.otherElements["ConversationDetail"]
            _ = detail.waitForExistence(timeout: 8)
            let composer = app.textViews["ConversationComposerTextEditor"]
            _ = composer.waitForExistence(timeout: 5)
            composer.tap()
            composer.typeText("performance queue")
            app.buttons["ConversationSendButton"].tap()
            _ = app.otherElements["ConversationQueuedRow-0"].waitForExistence(timeout: 5)
            app.terminate()
        }
    }

    @MainActor
    private func makeFixtureApplication(scenario: String, lightMode: Bool = false, largeText: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        if lightMode { app.launchArguments += ["-AppleInterfaceStyle", "Light"] }
        if largeText {
            app.launchArguments += ["-UIPreferredContentSizeCategory", "UICTContentSizeCategoryAccessibilityXXXL"]
        }
        app.launchEnvironment["CMUX_UITEST_MOCK_DATA"] = "0"
        app.launchEnvironment["CMUX_UITEST_CONVERSATION_FIXTURE"] = "1"
        app.launchEnvironment["CMUX_UITEST_CONVERSATION_SCENARIO"] = scenario
        return app
    }

    @MainActor
    private func waitForTaskList(in app: XCUIApplication) throws {
        let list = app.otherElements["ConversationTaskList"]
        XCTAssertTrue(list.waitForExistence(timeout: 12), "native conversation task list did not appear")
    }

    @MainActor
    private func openDetail(in app: XCUIApplication) throws {
        try waitForTaskList(in: app)
        let task = app.descendants(matching: .any)["ConversationTaskRow-fixture-codex"]
        XCTAssertTrue(task.waitForExistence(timeout: 8), "fixture task row did not appear")
        task.tap()
        XCTAssertTrue(app.otherElements["ConversationDetail"].waitForExistence(timeout: 8))
    }

    @MainActor
    private func openFilesSheet(in app: XCUIApplication) throws {
        let actions = app.buttons["ConversationActionsMenu"]
        XCTAssertTrue(actions.waitForExistence(timeout: 5))
        actions.tap()
        let files = app.buttons["Files"]
        XCTAssertTrue(files.waitForExistence(timeout: 3))
        files.tap()
    }

    @MainActor
    private func capture(_ app: XCUIApplication, name: String) {
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)

        let frames = XCTAttachment(data: accessibilityFrames(for: app), uniformTypeIdentifier: "public.json")
        frames.name = "\(name)-accessibility-frames.json"
        frames.lifetime = .keepAlways
        add(frames)
    }

    @MainActor
    private func accessibilityFrames(for app: XCUIApplication) -> Data {
        var entries: [[String: Any]] = []
        for element in app.descendants(matching: .any).allElementsBoundByIndex.prefix(220) {
            guard !element.identifier.isEmpty, element.exists else { continue }
            entries.append([
                "identifier": element.identifier,
                "label": element.label,
                "type": element.elementType.rawValue,
                "x": Double(element.frame.origin.x),
                "y": Double(element.frame.origin.y),
                "width": Double(element.frame.width),
                "height": Double(element.frame.height),
            ])
        }
        return (try? JSONSerialization.data(withJSONObject: entries, options: [.prettyPrinted, .sortedKeys])) ?? Data("[]".utf8)
    }
}
