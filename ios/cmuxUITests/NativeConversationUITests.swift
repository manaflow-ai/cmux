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
            let newTask = app.descendants(matching: .any)["ConversationNewTaskButton"]
            XCTAssertTrue(newTask.waitForExistence(timeout: 8))
            newTask.tap()
            let sheet = app.descendants(matching: .any)["ConversationNewTaskSheet"]
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
            XCTAssertTrue(app.descendants(matching: .any)["ConversationDetail"].waitForExistence(timeout: 8))
            capture(app, name: "native-new-provider-workspace-task-created")

        case .toolExpanded:
            try openDetail(in: app)
            let tool = app.descendants(matching: .any)["ConversationTool-shell"]
            XCTAssertTrue(tool.waitForExistence(timeout: 5))
            tool.tap()
            capture(app, name: "native-tool-expanded")

        case .steerQueueMenu:
            try openDetail(in: app)
            let composer = app.descendants(matching: .any)["ConversationComposerTextEditor"]
            XCTAssertTrue(composer.waitForExistence(timeout: 5))
            composer.tap()
            composer.typeText("choose queue from the long press menu")
            let send = app.descendants(matching: .any)["ConversationSendButton"]
            XCTAssertTrue(send.waitForExistence(timeout: 5))
            send.press(forDuration: 1.0)
            let queueAction = app.buttons["Queue"]
            XCTAssertTrue(queueAction.waitForExistence(timeout: 5))
            queueAction.tap()
            XCTAssertTrue(app.descendants(matching: .any)["ConversationQueuedRow-0"].waitForExistence(timeout: 5))
            capture(app, name: "native-steer-queue-menu")

        case .queueLifecycle:
            try openDetail(in: app)
            let composer = app.descendants(matching: .any)["ConversationComposerTextEditor"]
            XCTAssertTrue(composer.waitForExistence(timeout: 5))
            composer.tap()
            composer.typeText("queued follow up")
            // The queue fixture starts with a live turn, so an empty composer
            // intentionally shows Stop. Typing the follow-up switches the
            // control to Send before the queue lifecycle begins.
            let send = app.descendants(matching: .any)["ConversationSendButton"]
            XCTAssertTrue(send.waitForExistence(timeout: 5))
            send.tap()
            let row = app.descendants(matching: .any)["ConversationQueuedRow-0"]
            XCTAssertTrue(row.waitForExistence(timeout: 5))
            XCTAssertTrue(app.descendants(matching: .any)["ConversationReceiptAccepted"].waitForExistence(timeout: 5))
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
            let composer = app.descendants(matching: .any)["ConversationComposerTextEditor"]
            XCTAssertTrue(composer.waitForExistence(timeout: 5))
            composer.tap()
            composer.typeText("steer the current turn")
            app.descendants(matching: .any)["ConversationSendButton"].tap()
            XCTAssertTrue(app.descendants(matching: .any)["ConversationReceiptApplied"].waitForExistence(timeout: 5))
            capture(app, name: "native-steer-receipt")

        case .stopReceipt:
            try openDetail(in: app)
            let stop = app.descendants(matching: .any)["ConversationStopButton"]
            XCTAssertTrue(stop.waitForExistence(timeout: 5))
            stop.tap()
            XCTAssertTrue(app.descendants(matching: .any)["ConversationReceiptApplied"].waitForExistence(timeout: 5))
            capture(app, name: "native-stop-receipt")

        case .stopWithLiveTool:
            try openDetail(in: app)
            let stop = app.descendants(matching: .any)["ConversationStopButton"]
            XCTAssertTrue(stop.waitForExistence(timeout: 5))
            XCTAssertTrue(app.descendants(matching: .any)["ConversationTool-shell"].waitForExistence(timeout: 5))
            stop.tap()
            XCTAssertTrue(app.descendants(matching: .any)["ConversationReceiptApplied"].waitForExistence(timeout: 5))
            XCTAssertTrue(app.staticTexts["Running"].waitForExistence(timeout: 5), "stopping keeps the live tool visible")
            capture(app, name: "native-stop-with-live-tool")

        case .approval:
            try openDetail(in: app)
            let request = app.descendants(matching: .any)["ConversationBlockingRequest-fixture-approval"]
            XCTAssertTrue(request.waitForExistence(timeout: 5))
            capture(app, name: "native-approval")
            let approve = app.buttons["Approve"]
            XCTAssertTrue(approve.waitForExistence(timeout: 3))
            approve.tap()
            XCTAssertTrue(app.descendants(matching: .any)["ConversationReceiptApplied"].waitForExistence(timeout: 5))
            capture(app, name: "native-approval-applied")

        case .questionPaging:
            try openDetail(in: app)
            let question = app.descendants(matching: .any)["ConversationBlockingQuestion"]
            XCTAssertTrue(question.waitForExistence(timeout: 5))
            XCTAssertTrue(app.staticTexts["1 of 2"].waitForExistence(timeout: 3))
            capture(app, name: "native-question-page-1")
            app.descendants(matching: .any)["ConversationQuestionOption-yes"].tap()
            XCTAssertTrue(app.staticTexts["2 of 2"].waitForExistence(timeout: 5))
            capture(app, name: "native-question-page-2")

        case .singleQuestion:
            try openDetail(in: app)
            XCTAssertTrue(app.descendants(matching: .any)["ConversationBlockingQuestion"].waitForExistence(timeout: 5))
            XCTAssertTrue(app.textFields["ConversationQuestionCustomAnswer"].waitForExistence(timeout: 3))
            capture(app, name: "native-single-question")

        case .singleQuestionCustomAnswer:
            try openDetail(in: app)
            XCTAssertTrue(app.descendants(matching: .any)["ConversationBlockingQuestion"].waitForExistence(timeout: 5))
            let customAnswer = app.textFields["ConversationQuestionCustomAnswer"]
            XCTAssertTrue(customAnswer.waitForExistence(timeout: 3))
            capture(app, name: "native-single-question-custom-answer")
            customAnswer.tap()
            customAnswer.typeText("a custom answer")
            app.descendants(matching: .any)["ConversationQuestionSendButton"].tap()
            XCTAssertTrue(app.descendants(matching: .any)["ConversationReceiptApplied"].waitForExistence(timeout: 5))
            capture(app, name: "native-single-question-custom-answer-applied")

        case .asyncQuestion:
            try openDetail(in: app)
            let question = app.descendants(matching: .any)["ConversationAsyncQuestion"]
            XCTAssertTrue(question.waitForExistence(timeout: 5))
            capture(app, name: "native-async-question")

        case .reconnectedPendingRequest:
            try openDetail(in: app)
            XCTAssertTrue(app.descendants(matching: .any)["ConversationBlockingRequest-fixture-approval"].waitForExistence(timeout: 5))
            XCTAssertTrue(app.images["Disconnected"].waitForExistence(timeout: 5))
            capture(app, name: "native-reconnected-pending-request")

        case .disconnectedRetainedTranscript:
            try openDetail(in: app)
            XCTAssertTrue(app.descendants(matching: .any)["ConversationTranscript"].waitForExistence(timeout: 5))
            XCTAssertTrue(app.staticTexts["Workspace is ready."].waitForExistence(timeout: 5))
            XCTAssertFalse(app.descendants(matching: .any)["ConversationSendButton"].isEnabled)
            capture(app, name: "native-disconnected-retained-transcript")

        case .streamingAssistantDelta:
            try openDetail(in: app)
            XCTAssertTrue(app.staticTexts["Streaming"].waitForExistence(timeout: 5))
            capture(app, name: "native-streaming-assistant-initial")
            let composer = app.descendants(matching: .any)["ConversationComposerTextEditor"]
            XCTAssertTrue(composer.waitForExistence(timeout: 5))
            composer.tap()
            composer.typeText("start streaming")
            app.descendants(matching: .any)["ConversationSendButton"].tap()
            XCTAssertTrue(app.staticTexts["Streaming assistant output"].waitForExistence(timeout: 5))
            capture(app, name: "native-streaming-assistant-delta")

        case .rejectedCommand:
            try openDetail(in: app)
            let composer = app.descendants(matching: .any)["ConversationComposerTextEditor"]
            XCTAssertTrue(composer.waitForExistence(timeout: 5))
            composer.tap()
            composer.typeText("reject this command")
            app.descendants(matching: .any)["ConversationSendButton"].tap()
            XCTAssertTrue(app.descendants(matching: .any)["ConversationErrorNotice"].waitForExistence(timeout: 5))
            XCTAssertTrue((composer.value as? String ?? "").contains("reject this command"))
            capture(app, name: "native-rejected-command")

        case .uncertainCommand:
            try openDetail(in: app)
            let composer = app.descendants(matching: .any)["ConversationComposerTextEditor"]
            XCTAssertTrue(composer.waitForExistence(timeout: 5))
            composer.tap()
            composer.typeText("uncertain command")
            app.descendants(matching: .any)["ConversationSendButton"].tap()
            XCTAssertTrue(app.descendants(matching: .any)["ConversationUncertainReceipt"].waitForExistence(timeout: 5))
            XCTAssertTrue((composer.value as? String ?? "").contains("uncertain command"))
            capture(app, name: "native-uncertain-command")

        case .modelSettings:
            try openDetail(in: app)
            let actions = app.descendants(matching: .any)["ConversationActionsMenu"]
            XCTAssertTrue(actions.waitForExistence(timeout: 5))
            actions.tap()
            let settings = app.buttons["Model and effort"]
            XCTAssertTrue(settings.waitForExistence(timeout: 3))
            settings.tap()
            XCTAssertTrue(app.descendants(matching: .any)["ConversationModelSettings"].waitForExistence(timeout: 5))
            XCTAssertTrue(app.descendants(matching: .any)["ConversationModelPicker"].waitForExistence(timeout: 3))
            XCTAssertTrue(app.descendants(matching: .any)["ConversationEffortPicker"].waitForExistence(timeout: 3))
            XCTAssertTrue(app.descendants(matching: .any)["ConversationSpeedPicker"].waitForExistence(timeout: 3))
            capture(app, name: "native-model-settings")
            app.descendants(matching: .any)["ConversationSettingsDone"].tap()

        case .filesDiff:
            try openDetail(in: app)
            try openFilesSheet(in: app)
            XCTAssertTrue(app.descendants(matching: .any)["ConversationFilesSheet"].waitForExistence(timeout: 5))
            capture(app, name: "native-files-diff-list")
            // The transcript also contains a Sources/App.swift card behind the
            // sheet. Target the sheet's stable row identifier so XCTest does
            // not resolve the covered transcript card and report it as
            // non-hittable.
            let path = app.buttons["ConversationFilesSheetItem-Sources/App.swift"]
            XCTAssertTrue(path.waitForExistence(timeout: 3))
            if !path.isHittable {
                let filesSheet = app.descendants(matching: .any)["ConversationFilesSheet"]
                if filesSheet.exists {
                    // The sheet opens at its medium detent.  Swipe the sheet
                    // itself first so the list can use the full viewport;
                    // swiping only the list leaves its last row clipped by
                    // the detent boundary on both iPhone and iPad.
                    filesSheet.swipeUp()
                }
            }
            if !path.isHittable {
                // The files sheet opens at its medium detent on iPadOS.  The
                // fixture's last row can therefore sit just below the
                // viewport even though it exists in the list.  Exercise the
                // same scroll a user would perform before opening it.
                let list = app.tables.firstMatch
                if list.exists {
                    list.swipeUp()
                } else {
                    app.swipeUp()
                }
            }
            XCTAssertTrue(path.isHittable)
            path.tap()
            XCTAssertTrue(app.descendants(matching: .any)["ConversationDiffView-Sources/App.swift"].waitForExistence(timeout: 5))
            capture(app, name: "native-files-diff-expanded")

        case .emptyFiles:
            try openDetail(in: app)
            try openFilesSheet(in: app)
            XCTAssertTrue(app.descendants(matching: .any)["ConversationFilesEmptyState"].waitForExistence(timeout: 5))
            capture(app, name: "native-empty-files")

        case .noGit:
            try openDetail(in: app)
            try openFilesSheet(in: app)
            XCTAssertTrue(app.descendants(matching: .any)["ConversationFilesEmptyState"].waitForExistence(timeout: 5))
            capture(app, name: "native-no-git")

        case .noLastTurn:
            try openDetail(in: app)
            try openFilesSheet(in: app)
            XCTAssertTrue(app.descendants(matching: .any)["ConversationFilesEmptyState"].waitForExistence(timeout: 5))
            capture(app, name: "native-no-last-turn")

        case .artifactPreview:
            try openDetail(in: app)
            let artifact = app.descendants(matching: .any)["ConversationArtifact-fixture-artifact"]
            XCTAssertTrue(artifact.waitForExistence(timeout: 5))
            artifact.tap()
            let preview = app.descendants(matching: .any)["ConversationArtifactPreview-fixture-artifact"]
            XCTAssertTrue(preview.waitForExistence(timeout: 3))
            preview.tap()
            XCTAssertTrue(app.descendants(matching: .any)["ConversationArtifactShare-fixture-artifact"].waitForExistence(timeout: 5))
            capture(app, name: "native-artifact-preview")

        case .emptyTask:
            try openDetail(in: app)
            XCTAssertTrue(app.descendants(matching: .any)["ConversationWelcome"].waitForExistence(timeout: 5))
            capture(app, name: "native-empty-task")

        case .emptyTaskList:
            try waitForTaskList(in: app)
            XCTAssertTrue(app.descendants(matching: .any)["ConversationEmptyState"].waitForExistence(timeout: 5))
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
    func testNativeConversationEmptyTaskUsesProviderName() throws {
        for (sessionID, providerName) in [
            ("fixture-codex", "Codex"),
            ("fixture-claude", "Claude Code"),
            ("fixture-opencode", "OpenCode"),
        ] {
            let app = makeFixtureApplication(scenario: "empty")
            app.launch()
            defer { app.terminate() }
            try waitForTaskList(in: app)
            let task = app.descendants(matching: .any)["ConversationTaskRow-\(sessionID)"]
            XCTAssertTrue(task.waitForExistence(timeout: 5))
            task.tap()
            let heading = app.staticTexts["Work with \(providerName)"]
            XCTAssertTrue(heading.waitForExistence(timeout: 5), "Empty conversation must name its provider without literal interpolation syntax")
            let screenshot = XCTAttachment(screenshot: app.screenshot())
            screenshot.name = "native-empty-provider-\(sessionID)"
            screenshot.lifetime = .keepAlways
            add(screenshot)
        }
    }

    @MainActor
    func testNativeConversationLocalizedEmptyTask() throws {
        for (language, locale, heading, sendLabel) in [
            ("de", "de_DE", "Mit Codex arbeiten", "Nachricht senden"),
            ("ar", "ar_SA", "العمل مع Codex", "إرسال رسالة"),
        ] {
            let app = makeFixtureApplication(scenario: "empty", language: language, locale: locale)
            app.launch()
            defer { app.terminate() }
            try openDetail(in: app)
            let localizedHeading = app.staticTexts
                .matching(identifier: "ConversationWelcome")
                .allElementsBoundByIndex
                .first { removingDirectionalIsolates(from: $0.label) == heading }
            XCTAssertNotNil(localizedHeading, "Empty conversation heading should match the localized provider name")
            let send = app.buttons["ConversationSendButton"]
            XCTAssertTrue(send.exists)
            XCTAssertEqual(send.label, sendLabel)
            capture(app, name: "native-localized-empty-\(language)")
        }
    }

    @MainActor
    func testNativeConversationSecretQuestionUsesSecureField() throws {
        let app = makeFixtureApplication(scenario: "secret-question")
        app.launch()
        defer { app.terminate() }
        try openDetail(in: app)
        XCTAssertTrue(app.descendants(matching: .any)["ConversationBlockingQuestion"].waitForExistence(timeout: 5))
        // SwiftUI reports SecureField as a secure text field on iPhone and as
        // a wrapped text field on some iPadOS releases. Assert the security
        // trait through the typed query while retaining the explicit view
        // identifier for any-host accessibility and automation queries.
        let customAnswer = app.descendants(matching: .any)["ConversationQuestionCustomAnswer"]
        XCTAssertTrue(customAnswer.waitForExistence(timeout: 3))
        // iPadOS 26 exposes SwiftUI SecureField through a wrapped text-field
        // node, while iPhone exposes the native secure-text-field query.
        XCTAssertTrue(
            app.secureTextFields.firstMatch.exists
                || app.textFields["ConversationQuestionCustomAnswer"].exists,
            "the custom answer control must retain a secure or wrapped text-field representation"
        )
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
            // The iOS app's composition root performs its first-run runtime
            // setup before SwiftUI presents the debug conversation fixture.
            // Give that real launch path enough time on hosted simulators so
            // this metric measures the screen rather than a launch race.
            _ = app.descendants(matching: .any)["ConversationTaskList"].waitForExistence(timeout: 30)
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
            let list = app.descendants(matching: .any)["ConversationTaskList"]
            _ = list.waitForExistence(timeout: 30)
            let task = app.descendants(matching: .any)["ConversationTaskRow-fixture-codex"]
            _ = task.waitForExistence(timeout: 15)
            task.tap()
            let detail = app.descendants(matching: .any)["ConversationDetail"]
            _ = detail.waitForExistence(timeout: 15)
            let composer = app.descendants(matching: .any)["ConversationComposerTextEditor"]
            _ = composer.waitForExistence(timeout: 10)
            composer.tap()
            composer.typeText("performance queue")
            app.descendants(matching: .any)["ConversationSendButton"].tap()
            _ = app.descendants(matching: .any)["ConversationQueuedRow-0"].waitForExistence(timeout: 5)
            app.terminate()
        }
    }

    @MainActor
    private func makeFixtureApplication(
        scenario: String,
        lightMode: Bool = false,
        largeText: Bool = false,
        language: String = "en",
        locale: String = "en_US"
    ) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(\(language))", "-AppleLocale", locale]
        if lightMode { app.launchArguments += ["-AppleInterfaceStyle", "Light"] }
        if largeText {
            app.launchArguments += ["-UIPreferredContentSizeCategory", "UICTContentSizeCategoryAccessibilityXXXL"]
        }
        app.launchEnvironment["CMUX_UITEST_MOCK_DATA"] = "0"
        app.launchEnvironment["CMUX_UITEST_CONVERSATION_FIXTURE"] = "1"
        app.launchEnvironment["CMUX_UITEST_CONVERSATION_SCENARIO"] = scenario
        return app
    }

    private func removingDirectionalIsolates(from value: String) -> String {
        let isolates: Set<UInt32> = [0x2066, 0x2067, 0x2068, 0x2069]
        return String(value.unicodeScalars.filter { !isolates.contains($0.value) })
    }

    @MainActor
    private func waitForTaskList(in app: XCUIApplication) throws {
        let list = app.descendants(matching: .any)["ConversationTaskList"]
        // The fixture is mounted after the shared iOS composition root has
        // initialized auth, diagnostics, and transport state. Hosted Macs can
        // take ~15 seconds on a clean simulator before the first frame, so a
        // 30-second bound avoids reporting a launch race as a UI failure.
        XCTAssertTrue(list.waitForExistence(timeout: 30), "native conversation task list did not appear")
    }

    @MainActor
    private func openDetail(in app: XCUIApplication) throws {
        try waitForTaskList(in: app)
        let task = app.descendants(matching: .any)["ConversationTaskRow-fixture-codex"]
        XCTAssertTrue(task.waitForExistence(timeout: 15), "fixture task row did not appear")
        task.tap()
        XCTAssertTrue(app.descendants(matching: .any)["ConversationDetail"].waitForExistence(timeout: 15))
    }

    @MainActor
    private func openFilesSheet(in app: XCUIApplication) throws {
        let actions = app.descendants(matching: .any)["ConversationActionsMenu"]
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
        do {
            // One immutable accessibility snapshot keeps the capture coherent
            // and avoids separate simulator round trips for every attribute.
            let snapshot = try app.snapshot()
            var pending = Array(snapshot.children.reversed())
            var entries: [[String: Any]] = []
            var visited = 0
            while let element = pending.popLast(), visited < 220 {
                visited += 1
                pending.append(contentsOf: element.children.reversed())
                guard !element.identifier.isEmpty else { continue }
                let frame = element.frame
                entries.append([
                    "identifier": element.identifier,
                    "label": element.label,
                    "type": element.elementType.rawValue,
                    "x": Double(frame.origin.x),
                    "y": Double(frame.origin.y),
                    "width": Double(frame.width),
                    "height": Double(frame.height),
                ])
            }
            return try JSONSerialization.data(withJSONObject: entries, options: [.prettyPrinted, .sortedKeys])
        } catch {
            XCTFail("Could not capture accessibility frames: \(error)")
            return Data("[]".utf8)
        }
    }
}
