import XCTest
import Foundation

final class TerminalCmdClickUITests: XCTestCase {
    private enum DisplayMode: String {
        case escaped
        case raw
    }

    private enum LineFormat: String {
        case grid
        case log
        case altScreenLog = "alt_screen_log"
        case osc8
        case plainURL = "url"
    }

    private struct SetupData {
        let expectedPath: String
        let payload: [String: Any]
    }

    private var hoverDiagnosticsPath = ""
    private var openCapturePath = ""
    private var openURLCapturePath = ""
    private var setupDataPath = ""
    private var commandPath = ""
    private var wrapSetupDataPath = ""
    private var wrapCommandPath = ""
    private var fixtureDirectoryURL: URL!
    private var harnessDirectoryURL: URL!

    override func setUp() {
        super.setUp()
        continueAfterFailure = false

        fixtureDirectoryURL = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("c-\(UUID().uuidString.prefix(8))", isDirectory: true)
        harnessDirectoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-ui-test-terminal-cmd-click-\(UUID().uuidString)", isDirectory: true)
        hoverDiagnosticsPath = harnessDirectoryURL.appendingPathComponent("hover.json").path
        openCapturePath = harnessDirectoryURL.appendingPathComponent("open.log").path
        openURLCapturePath = harnessDirectoryURL.appendingPathComponent("open-url.log").path
        setupDataPath = harnessDirectoryURL.appendingPathComponent("setup.json").path
        commandPath = harnessDirectoryURL.appendingPathComponent("command.json").path
        wrapSetupDataPath = harnessDirectoryURL.appendingPathComponent("wrap-setup.json").path
        wrapCommandPath = harnessDirectoryURL.appendingPathComponent("wrap-command.json").path

        try? FileManager.default.removeItem(atPath: hoverDiagnosticsPath)
        try? FileManager.default.removeItem(atPath: openCapturePath)
        try? FileManager.default.removeItem(atPath: openURLCapturePath)
        try? FileManager.default.removeItem(atPath: setupDataPath)
        try? FileManager.default.removeItem(atPath: commandPath)
        try? FileManager.default.removeItem(atPath: wrapSetupDataPath)
        try? FileManager.default.removeItem(atPath: wrapCommandPath)
        try? FileManager.default.createDirectory(at: harnessDirectoryURL, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: fixtureDirectoryURL, withIntermediateDirectories: true)
        XCTAssertTrue(
            FileManager.default.createFile(
                atPath: commandPath,
                contents: Data("{}".utf8)
            ),
            "Expected shared command file to be writable at \(commandPath)"
        )
        XCTAssertTrue(
            FileManager.default.createFile(
                atPath: wrapCommandPath,
                contents: Data("{}".utf8)
            ),
            "Expected shared wrap command file to be writable at \(wrapCommandPath)"
        )
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: hoverDiagnosticsPath)
        try? FileManager.default.removeItem(atPath: openCapturePath)
        try? FileManager.default.removeItem(atPath: openURLCapturePath)
        try? FileManager.default.removeItem(atPath: setupDataPath)
        try? FileManager.default.removeItem(atPath: commandPath)
        try? FileManager.default.removeItem(atPath: wrapSetupDataPath)
        try? FileManager.default.removeItem(atPath: wrapCommandPath)
        try? FileManager.default.removeItem(at: fixtureDirectoryURL)
        try? FileManager.default.removeItem(at: harnessDirectoryURL)
        super.tearDown()
    }

    func testHoldingCommandAfterSelectionSuppresssCommandHoverDispatch() throws {
        let app = launchApp(captureOpenPaths: false, captureHoverDiagnostics: true)
        defer { app.terminate() }

        _ = try waitForReadySetup()
        let result = try runCommand(action: "select_token_and_hold_command")

        XCTAssertEqual(
            result["lastCommandSucceeded"] as? String,
            "1",
            "Expected setup harness to create a selection and suppress cmd-hover. result=\(result)"
        )
        XCTAssertEqual(
            result["lastCommandSelectionActive"] as? String,
            "1",
            "Expected a real Ghostty selection before holding Command. result=\(result)"
        )
        XCTAssertEqual(
            result["lastCommandHoverSuppressed"] as? String,
            "1",
            "Expected cmd-hover suppression to trigger while selection stayed active. result=\(result)"
        )

        guard let diagnostics = waitForHoverDiagnostics(timeout: 5.0) else {
            XCTFail("Expected hover diagnostics after holding Command with an active selection. result=\(result)")
            return
        }

        let suppressedCount = diagnostics["suppressed_command_hover_count"] as? Int ?? 0
        let forwardedCount = diagnostics["forwarded_command_hover_count"] as? Int ?? 0
        XCTAssertGreaterThanOrEqual(
            suppressedCount,
            1,
            "Expected holding Command after selecting text to suppress command hover dispatch. diagnostics=\(diagnostics)"
        )
        XCTAssertEqual(
            forwardedCount,
            0,
            "Expected no command-modified hover dispatch to reach Ghostty while selection is active. diagnostics=\(diagnostics)"
        )
    }

    func testBackgroundAppIsNotReadyForInteraction() {
        XCTAssertFalse(
            Self.isReadyForInteraction(.runningBackground),
            "A backgrounded app can still have windows; readiness requires runningForeground."
        )
        XCTAssertTrue(Self.isReadyForInteraction(.runningForeground))
    }

    func testCmdClickEscapedPathWithSpacesOpensResolvedFile() throws {
        let app = launchApp(
            displayMode: .escaped,
            captureOpenPaths: true,
            captureHoverDiagnostics: false
        )
        defer { app.terminate() }

        let fileName = "Cmd Click Fixture.txt"
        let setup = try waitForReadySetup()
        let expectedPath = fixtureDirectoryURL.appendingPathComponent(fileName).path

        XCTAssertEqual(setup.expectedPath, expectedPath)

        let result = try runCommand(action: "cmd_click_token")
        XCTAssertEqual(
            result["lastCommandSucceeded"] as? String,
            "1",
            "Expected cmd-click harness to open the escaped-space path. result=\(result)"
        )
        XCTAssertEqual(
            result["lastCommandOpenedPath"] as? String,
            expectedPath,
            "Expected cmd-click to resolve the escaped-space path to the real file. result=\(result)"
        )

        let openedPaths = waitForCapturedOpenPaths(timeout: 5.0)
        guard !openedPaths.isEmpty else {
            XCTFail("Expected cmd-click capture log after running the command harness. result=\(result)")
            return
        }

        XCTAssertTrue(
            openedPaths.contains(expectedPath),
            "Expected cmd-click to resolve the escaped-space path to the real file. opened=\(openedPaths) expected=\(expectedPath)"
        )
    }

    func testCmdClickRawLsStylePathWithSpacesOpensResolvedFile() throws {
        let app = launchApp(
            displayMode: .raw,
            captureOpenPaths: true,
            captureHoverDiagnostics: false
        )
        defer { app.terminate() }

        let fileName = "Cmd Click Fixture.txt"
        let setup = try waitForReadySetup()
        let expectedPath = fixtureDirectoryURL.appendingPathComponent(fileName).path

        XCTAssertEqual(setup.expectedPath, expectedPath)

        let result = try runCommand(action: "cmd_click_token")
        XCTAssertEqual(
            result["lastCommandSucceeded"] as? String,
            "1",
            "Expected cmd-click harness to open the raw-space path. result=\(result)"
        )
        XCTAssertEqual(
            result["lastCommandOpenedPath"] as? String,
            expectedPath,
            "Expected cmd-click to resolve the raw-space path to the real file. result=\(result)"
        )

        let openedPaths = waitForCapturedOpenPaths(timeout: 5.0)
        guard !openedPaths.isEmpty else {
            XCTFail("Expected cmd-click capture log after running the raw-space command harness. result=\(result)")
            return
        }

        XCTAssertTrue(
            openedPaths.contains(expectedPath),
            "Expected cmd-click to resolve the raw-space path to the real file. opened=\(openedPaths) expected=\(expectedPath)"
        )
    }

    func testStationaryCmdClickOsc8FileHyperlinkOpensURL() throws {
        let fileName = "Issue 3557 Link.md"
        let app = launchApp(
            displayMode: .raw,
            lineFormat: .osc8,
            fileName: fileName,
            captureOpenPaths: false,
            captureHoverDiagnostics: false
        )
        defer { app.terminate() }

        let setup = try waitForReadySetup()
        let expectedURL = URL(fileURLWithPath: expectedPath(for: fileName)).absoluteString
        XCTAssertEqual(URL(fileURLWithPath: setup.expectedPath).absoluteString, expectedURL)

        let result = try runCommand(action: "stationary_cmd_click_token")
        XCTAssertEqual(
            result["lastCommandSucceeded"] as? String,
            "1",
            "Expected stationary cmd-click on an OSC 8 file hyperlink to open the URL. result=\(result)"
        )
        XCTAssertEqual(
            result["lastCommandOpenedURL"] as? String,
            expectedURL,
            "Expected OSC 8 cmd-click to route through Ghostty's open-url action. result=\(result)"
        )

        let openedURLs = waitForCapturedOpenPaths(timeout: 5.0, path: openURLCapturePath)
        guard !openedURLs.isEmpty else {
            XCTFail("Expected open capture after stationary OSC 8 cmd-click. result=\(result)")
            return
        }
        XCTAssertEqual(
            openedURLs.count,
            1,
            "Expected exactly one stationary OSC 8 open. opened=\(openedURLs)"
        )
        XCTAssertTrue(
            openedURLs.contains(expectedURL),
            "Expected stationary OSC 8 cmd-click to open \(expectedURL). opened=\(openedURLs)"
        )
        XCTAssertTrue(
            waitForOpenCountToStay(1, timeout: 1.0, path: openURLCapturePath),
            "Expected exactly one OSC 8 open throughout the stability window. opened=\(loadCapturedOpenPaths(path: openURLCapturePath))"
        )
    }

    func testStationaryCmdClickPlainURLWithMouseReportingOpensURL() throws {
        let app = launchApp(
            displayMode: .raw,
            lineFormat: .plainURL,
            captureOpenPaths: false,
            captureHoverDiagnostics: false,
            mouseReporting: true
        )
        defer { app.terminate() }

        let setup = try waitForReadySetup()
        XCTAssertEqual(
            setup.payload["mouseReportingCaptured"] as? String,
            "1",
            "Expected the fixture to enable terminal mouse reporting before the click. payload=\(setup.payload)"
        )
        let expectedURL = "https://github.com"
        let result = try runCommand(action: "stationary_cmd_click_token")
        XCTAssertEqual(
            result["lastCommandSucceeded"] as? String,
            "1",
            "Expected Cmd-click to open a plain URL while mouse reporting is active. result=\(result)"
        )

        let openedURLs = waitForCapturedOpenPaths(timeout: 5.0, path: openURLCapturePath)
        XCTAssertTrue(
            openedURLs.contains(expectedURL),
            "Expected Cmd-click to emit the plain URL while mouse reporting is active. opened=\(openedURLs)"
        )
    }

    func testCmdClickOsc8FileHyperlinkOpensExactlyOneHandler() throws {
        let fileName = "Cmd Click Fixture.txt"
        let app = launchApp(
            displayMode: .raw,
            lineFormat: .osc8,
            fileName: fileName,
            captureOpenPaths: true,
            captureHoverDiagnostics: false
        )
        defer { app.terminate() }

        let setup = try waitForReadySetup()
        let expectedURL = URL(fileURLWithPath: setup.expectedPath).absoluteString

        let result = try runCommand(action: "cmd_click_token")

        let openedURLs = waitForCapturedOpenPaths(timeout: 5.0, path: openURLCapturePath)
        XCTAssertEqual(
            openedURLs,
            [expectedURL],
            "Expected Ghostty's open-url action to route the OSC 8 file link exactly once. result=\(result)"
        )

        // Issue #10222: when Ghostty consumes the click and dispatches its
        // open-url action, the cmd-click word-path fallback must not ALSO open
        // the same file through the preferred-editor/system path — that is the
        // double-open (e.g. Preview and the preferred editor at once).
        XCTAssertTrue(
            waitForOpenCountToStay(0, timeout: 1.5),
            "Cmd-click dispatched a second open for the same click: the word-path fallback ran even though Ghostty already routed the link. opened=\(loadCapturedOpenPaths()) result=\(result)"
        )
        // The open-url route itself must also stay at exactly one dispatch
        // through the settle window — never a duplicate primary open either.
        XCTAssertEqual(
            loadCapturedOpenPaths(path: openURLCapturePath),
            [expectedURL],
            "Expected exactly one open-url dispatch for the click after settling. result=\(result)"
        )
    }

    func testCmdClickRawLsStylePathPrefersSnapshotWhenQuicklookDisagrees() throws {
        let app = launchApp(
            displayMode: .raw,
            captureOpenPaths: true,
            captureHoverDiagnostics: false,
            quicklookOverride: "OtherFile"
        )
        defer { app.terminate() }

        let fileName = "Cmd Click Fixture.txt"
        let setup = try waitForReadySetup()
        let expectedPath = fixtureDirectoryURL.appendingPathComponent(fileName).path
        let wrongQuicklookPath = fixtureDirectoryURL.appendingPathComponent("OtherFile").path

        XCTAssertEqual(setup.expectedPath, expectedPath)

        let result = try runCommand(action: "cmd_click_token")
        XCTAssertEqual(
            result["lastCommandSucceeded"] as? String,
            "1",
            "Expected cmd-click to prefer the snapshot-expanded raw-space path when quicklook disagrees. result=\(result)"
        )
        XCTAssertEqual(
            result["lastCommandOpenedPath"] as? String,
            expectedPath,
            "Expected cmd-click to prefer the snapshot-expanded raw-space path when quicklook disagrees. result=\(result)"
        )
        if let lastCommandResult = result["lastCommandResult"] as? [String: Any] {
            XCTAssertEqual(
                lastCommandResult["resolutionSource"] as? String,
                "snapshot",
                "Expected disagreement cases to resolve through the snapshot path expander. result=\(result)"
            )
        }

        let openedPaths = waitForCapturedOpenPaths(timeout: 5.0)
        guard !openedPaths.isEmpty else {
            XCTFail("Expected cmd-click capture log after forcing a quicklook mismatch. result=\(result)")
            return
        }

        XCTAssertTrue(
            openedPaths.contains(expectedPath),
            "Expected cmd-click to open the intended raw-space path. opened=\(openedPaths) expected=\(expectedPath)"
        )
        XCTAssertFalse(
            openedPaths.contains(wrongQuicklookPath),
            "Expected cmd-click to reject the mismatched quicklook path. opened=\(openedPaths) wrong=\(wrongQuicklookPath)"
        )
    }

    func testCmdClickRawLsStylePathPrefersPointSnapshotWhenViewportOffsetDisagrees() throws {
        let app = launchApp(
            displayMode: .raw,
            captureOpenPaths: true,
            captureHoverDiagnostics: false,
            viewportOffsetDelta: 24
        )
        defer { app.terminate() }

        let fileName = "Cmd Click Fixture.txt"
        let setup = try waitForReadySetup()
        let expectedPath = fixtureDirectoryURL.appendingPathComponent(fileName).path
        let wrongViewportPath = fixtureDirectoryURL.appendingPathComponent("OtherFile").path

        XCTAssertEqual(setup.expectedPath, expectedPath)

        let result = try runCommand(action: "cmd_click_token")
        XCTAssertEqual(
            result["lastCommandSucceeded"] as? String,
            "1",
            "Expected cmd-click to prefer the click-point snapshot when viewport offsets disagree. result=\(result)"
        )
        XCTAssertEqual(
            result["lastCommandOpenedPath"] as? String,
            expectedPath,
            "Expected cmd-click to keep the clicked raw-space path when viewport offsets disagree. result=\(result)"
        )
        if let lastCommandResult = result["lastCommandResult"] as? [String: Any] {
            XCTAssertEqual(
                lastCommandResult["resolutionSource"] as? String,
                "snapshot",
                "Expected disagreement cases to resolve through the click-point snapshot. result=\(result)"
            )
            XCTAssertEqual(
                lastCommandResult["rawToken"] as? String,
                fileName,
                "Expected disagreement cases to keep the clicked raw token. result=\(result)"
            )
        }

        let openedPaths = waitForCapturedOpenPaths(timeout: 5.0)
        guard !openedPaths.isEmpty else {
            XCTFail("Expected cmd-click capture log after forcing a viewport mismatch. result=\(result)")
            return
        }

        XCTAssertTrue(
            openedPaths.contains(expectedPath),
            "Expected cmd-click to open the clicked raw-space path. opened=\(openedPaths) expected=\(expectedPath)"
        )
        XCTAssertFalse(
            openedPaths.contains(wrongViewportPath),
            "Expected cmd-click to reject the mismatched viewport path. opened=\(openedPaths) wrong=\(wrongViewportPath)"
        )
    }

    func testCmdHoverLsStylePathResolvesFullConsultantAgreementDocx() throws {
        try assertCommandHoverResolves(
            fileName: "Standard - Consultant Agreement - Form of Consulting Agreement.docx",
            lineFormat: .grid,
            linePrefix: "",
            extraFileNames: ["Agreement.docx"],
            disallowedFileName: "Agreement.docx"
        )
    }

    func testCmdClickLsStylePathOpensFullConsultantAgreementDocx() throws {
        try assertCommandClickOpensAcrossEveryCharacter(
            fileName: "Standard - Consultant Agreement - Form of Consulting Agreement.docx",
            lineFormat: .grid,
            linePrefix: "",
            extraFileNames: ["Agreement.docx"],
            disallowedFileName: "Agreement.docx"
        )
    }

    func testCmdHoverLsStylePathResolvesFullNintendoMkv() throws {
        try assertCommandHoverResolves(
            fileName: "(NINTENDO) BOTW Guardian Sound Effect.mkv",
            lineFormat: .grid,
            linePrefix: ""
        )
    }

    func testCmdClickLsStylePathOpensFullNintendoMkv() throws {
        try assertCommandClickOpensAcrossEveryCharacter(
            fileName: "(NINTENDO) BOTW Guardian Sound Effect.mkv",
            lineFormat: .grid,
            linePrefix: ""
        )
    }

    func testCmdClickPngOpensInCmuxFilePreviewWhenEnabled() throws {
        let app = launchApp(
            displayMode: .raw,
            fileName: "Command Click Fixture.png",
            captureOpenPaths: true,
            captureHoverDiagnostics: false,
            openSupportedFilesInCmux: true
        )
        defer { app.terminate() }

        let setup = try waitForReadySetup()
        let expectedResolvedPath = expectedPath(for: "Command Click Fixture.png")
        XCTAssertEqual(setup.expectedPath, expectedResolvedPath)

        let result = try runCommand(action: "cmd_click_token")
        XCTAssertEqual(
            result["lastCommandSucceeded"] as? String,
            "1",
            "Expected cmd-click to open the PNG path. result=\(result)"
        )
        XCTAssertEqual(
            result["lastCommandOpenedPath"] as? String,
            expectedResolvedPath,
            "Expected cmd-click to resolve the PNG path. result=\(result)"
        )
        XCTAssertEqual(
            result["lastCommandOpenedInFilePreview"] as? String,
            "1",
            "Expected supported-file routing to create a cmux file preview. result=\(result)"
        )
        XCTAssertTrue(
            waitForOpenCountToStay(0, timeout: 0.75),
            "Expected cmux file preview routing to avoid the external opener. opened=\(loadCapturedOpenPaths())"
        )
    }

    func testCmdClickMarketingSkillMarkdownPathWithTrailingPeriodOpensMarkdownViewer() throws {
        let fileName = "skills/marketing/data/lawrencecchen-tweets.md"
        let app = launchApp(
            displayMode: .raw,
            lineFormat: .log,
            fileName: fileName,
            displaySuffix: ".",
            captureOpenPaths: true,
            captureHoverDiagnostics: false,
            openMarkdownInCmuxViewer: true
        )
        defer { app.terminate() }

        let setup = try waitForReadySetup()
        let expectedResolvedPath = expectedPath(for: fileName)
        XCTAssertEqual(setup.expectedPath, expectedResolvedPath)

        let result = try runCommand(action: "cmd_click_token")
        XCTAssertEqual(
            result["lastCommandSucceeded"] as? String,
            "1",
            "Expected cmd-click to open the Markdown path without the trailing period. result=\(result)"
        )
        XCTAssertEqual(
            result["lastCommandOpenedPath"] as? String,
            expectedResolvedPath,
            "Expected cmd-click to trim the prose period from the Markdown path. result=\(result)"
        )
        XCTAssertEqual(
            result["lastCommandOpenedInMarkdownViewer"] as? String,
            "1",
            "Expected Markdown paths to open in the cmux Markdown viewer. result=\(result)"
        )
        XCTAssertEqual(
            result["lastCommandOpenedInFilePreview"] as? String,
            "0",
            "Expected Markdown paths not to fall through to the generic file preview. result=\(result)"
        )
        XCTAssertTrue(
            waitForOpenCountToStay(0, timeout: 0.75),
            "Expected cmux Markdown routing to avoid the external opener. opened=\(loadCapturedOpenPaths())"
        )
    }

    func testCmdClickQuotedAbsoluteMarkdownPathWithTrailingPeriodOpensMarkdownViewer() throws {
        let fileName = "skills/marketing/data/lawrencecchen-tweets.md"
        let app = launchApp(
            displayMode: .raw,
            lineFormat: .log,
            fileName: fileName,
            linePrefix: "\"",
            displaySuffix: ".\"",
            displayAsAbsolutePath: true,
            captureOpenPaths: true,
            captureHoverDiagnostics: false,
            openMarkdownInCmuxViewer: true
        )
        defer { app.terminate() }

        let setup = try waitForReadySetup()
        let expectedResolvedPath = expectedPath(for: fileName)
        XCTAssertEqual(setup.expectedPath, expectedResolvedPath)

        let result = try runCommand(action: "cmd_click_token")
        XCTAssertEqual(
            result["lastCommandSucceeded"] as? String,
            "1",
            "Expected cmd-click to open the quoted absolute Markdown path without the trailing period. result=\(result)"
        )
        XCTAssertEqual(
            result["lastCommandOpenedPath"] as? String,
            expectedResolvedPath,
            "Expected cmd-click to trim the prose period from the absolute Markdown path. result=\(result)"
        )
        XCTAssertEqual(
            result["lastCommandOpenedInMarkdownViewer"] as? String,
            "1",
            "Expected absolute Markdown paths to open in the cmux Markdown viewer. result=\(result)"
        )
        XCTAssertEqual(
            result["lastCommandOpenedInFilePreview"] as? String,
            "0",
            "Expected Markdown routing, not generic file preview. result=\(result)"
        )
        XCTAssertTrue(
            waitForOpenCountToStay(0, timeout: 0.75),
            "Expected cmux Markdown routing to avoid the external opener. opened=\(loadCapturedOpenPaths())"
        )
    }

    // Issue #8810 exact repro: a hard wrap that splits mid-word, with no
    // punctuation before the break, e.g. `/…/TMLlaborator` on one physical
    // row and `y` alone on the next. Neither existing native Ghostty link
    // detection nor the pre-fix cmux fallback can see across that boundary,
    // so cmd-click on either row must now resolve the joined absolute path.
    //
    // This uses a dedicated harness (`launchWrapScenarioApp`,
    // `CMUX_UI_TEST_TERMINAL_CMD_CLICK_WRAP_*`) rather than the generic
    // cmd-click harness above: the fixture filename must be sized to the
    // live terminal column count so the wrap lands exactly one character
    // past the row edge, which the app alone can measure.
    func testCmdClickHardWrappedPathTopRowOpensJoinedPath() throws {
        try assertHardWrappedPathClick(
            action: "cmd_click_wrapped_token_top",
            rowDescription: "leading wrapped row"
        )
    }

    func testCmdClickHardWrappedPathBottomRowOpensJoinedPath() throws {
        try assertHardWrappedPathClick(
            action: "cmd_click_wrapped_token_bottom",
            rowDescription: "trailing wrapped row"
        )
    }

    private func assertHardWrappedPathClick(
        action: String,
        rowDescription: String
    ) throws {
        let app = launchWrapScenarioApp(captureOpenPaths: true)
        defer { app.terminate() }

        let expectedResolvedPath = try waitForWrapReadySetup()

        let result = try runWrapCommand(action: action)
        XCTAssertEqual(
            result["lastCommandSucceeded"] as? String,
            "1",
            "Expected cmd-click on the \(rowDescription) to open the joined path. result=\(result)"
        )
        XCTAssertEqual(
            result["lastCommandOpenedPath"] as? String,
            expectedResolvedPath,
            "Expected cmd-click to join the hard-wrapped absolute path across both rows. result=\(result)"
        )

        let openedPaths = waitForCapturedOpenPaths(timeout: 5.0)
        guard !openedPaths.isEmpty else {
            XCTFail("Expected an open-path capture after the wrapped-path click. result=\(result)")
            return
        }
        XCTAssertEqual(
            openedPaths.count,
            1,
            "Expected the hard-wrapped path to open exactly once. opened=\(openedPaths)"
        )
        guard waitForOpenCountToStay(1, timeout: 1.0) else {
            XCTFail("Expected exactly one wrapped-path open throughout the stability window. opened=\(loadCapturedOpenPaths())")
            return
        }
        XCTAssertTrue(
            openedPaths.contains(expectedResolvedPath),
            "Expected the joined path to open. opened=\(openedPaths) expected=\(expectedResolvedPath)"
        )
    }

    func testCmdClickLsStyleInvalidCellsDoNothingForConsultantAgreementDocx() throws {
        try assertCommandClickDoesNothingAtInvalidOffsets(
            fileName: "Standard - Consultant Agreement - Form of Consulting Agreement.docx",
            lineFormat: .grid,
            linePrefix: "",
            extraFileNames: ["Agreement.docx"]
        )
    }

    func testCmdClickLsStyleInvalidCellsDoNothingForNintendoMkv() throws {
        try assertCommandClickDoesNothingAtInvalidOffsets(
            fileName: "(NINTENDO) BOTW Guardian Sound Effect.mkv",
            lineFormat: .grid,
            linePrefix: ""
        )
    }

    func testCmdHoverDashPrefixedLogPathResolvesFullConsultantAgreementDocx() throws {
        try assertCommandHoverResolves(
            fileName: "Standard - Consultant Agreement - Form of Consulting Agreement.docx",
            lineFormat: .log,
            linePrefix: "- ",
            extraFileNames: ["Agreement.docx"],
            disallowedFileName: "Agreement.docx"
        )
    }

    func testCmdClickDashPrefixedLogPathOpensFullConsultantAgreementDocx() throws {
        try assertCommandClickOpens(
            fileName: "Standard - Consultant Agreement - Form of Consulting Agreement.docx",
            lineFormat: .log,
            linePrefix: "- ",
            extraFileNames: ["Agreement.docx"],
            disallowedFileName: "Agreement.docx"
        )
    }

    func testCmdHoverDashPrefixedLogPathResolvesFullNintendoMkv() throws {
        try assertCommandHoverResolves(
            fileName: "(NINTENDO) BOTW Guardian Sound Effect.mkv",
            lineFormat: .log,
            linePrefix: "- "
        )
    }

    func testCmdClickDashPrefixedLogPathOpensFullNintendoMkv() throws {
        try assertCommandClickOpens(
            fileName: "(NINTENDO) BOTW Guardian Sound Effect.mkv",
            lineFormat: .log,
            linePrefix: "- "
        )
    }

    func testCmdHoverAltScreenDashPrefixedLogPathResolvesFullConsultantAgreementDocx() throws {
        try assertCommandHoverResolves(
            fileName: "Standard - Consultant Agreement - Form of Consulting Agreement.docx",
            lineFormat: .altScreenLog,
            linePrefix: "- ",
            extraFileNames: ["Agreement.docx"],
            disallowedFileName: "Agreement.docx"
        )
    }

    func testCmdClickAltScreenDashPrefixedLogPathOpensFullConsultantAgreementDocx() throws {
        try assertCommandClickOpens(
            fileName: "Standard - Consultant Agreement - Form of Consulting Agreement.docx",
            lineFormat: .altScreenLog,
            linePrefix: "- ",
            extraFileNames: ["Agreement.docx"],
            disallowedFileName: "Agreement.docx"
        )
    }

    func testCmdHoverAltScreenDashPrefixedLogPathResolvesFullNintendoMkv() throws {
        try assertCommandHoverResolves(
            fileName: "(NINTENDO) BOTW Guardian Sound Effect.mkv",
            lineFormat: .altScreenLog,
            linePrefix: "- "
        )
    }

    func testCmdClickAltScreenDashPrefixedLogPathOpensFullNintendoMkv() throws {
        try assertCommandClickOpens(
            fileName: "(NINTENDO) BOTW Guardian Sound Effect.mkv",
            lineFormat: .altScreenLog,
            linePrefix: "- "
        )
    }

    private func assertCommandHoverResolves(
        fileName: String,
        lineFormat: LineFormat,
        linePrefix: String,
        extraFileNames: [String] = [],
        disallowedFileName: String? = nil
    ) throws {
        let app = launchApp(
            displayMode: .raw,
            lineFormat: lineFormat,
            fileName: fileName,
            linePrefix: linePrefix,
            extraFileNames: extraFileNames,
            captureOpenPaths: false,
            captureHoverDiagnostics: false
        )
        defer { app.terminate() }

        let setup = try waitForReadySetup()
        let expectedResolvedPath = expectedPath(for: fileName)
        XCTAssertEqual(setup.expectedPath, expectedResolvedPath)

        let result = try runCommand(action: "hover_token")
        XCTAssertEqual(
            result["lastCommandSucceeded"] as? String,
            "1",
            "Expected cmd-hover to resolve the full spaced path. result=\(result)"
        )
        XCTAssertEqual(
            result["lastCommandHoverActive"] as? String,
            "1",
            "Expected cmd-hover to activate the pointing cursor for the full spaced path. result=\(result)"
        )
        XCTAssertEqual(
            result["lastCommandResolvedPath"] as? String,
            expectedResolvedPath,
            "Expected cmd-hover to resolve the full spaced path, not a suffix token. result=\(result)"
        )

        if let disallowedFileName {
            XCTAssertNotEqual(
                result["lastCommandResolvedPath"] as? String,
                expectedPath(for: disallowedFileName),
                "Expected cmd-hover to reject suffix-token decoys. result=\(result)"
            )
        }
    }

    private func assertCommandClickOpens(
        fileName: String,
        lineFormat: LineFormat,
        linePrefix: String,
        extraFileNames: [String] = [],
        disallowedFileName: String? = nil
    ) throws {
        let app = launchApp(
            displayMode: .raw,
            lineFormat: lineFormat,
            fileName: fileName,
            linePrefix: linePrefix,
            extraFileNames: extraFileNames,
            captureOpenPaths: true,
            captureHoverDiagnostics: false
        )
        defer { app.terminate() }

        let setup = try waitForReadySetup()
        let expectedResolvedPath = expectedPath(for: fileName)
        XCTAssertEqual(setup.expectedPath, expectedResolvedPath)

        let result = try runCommand(action: "cmd_click_token")
        XCTAssertEqual(
            result["lastCommandSucceeded"] as? String,
            "1",
            "Expected cmd-click to open the full spaced path. result=\(result)"
        )
        XCTAssertEqual(
            result["lastCommandOpenedPath"] as? String,
            expectedResolvedPath,
            "Expected cmd-click to open the full spaced path, not a suffix token. result=\(result)"
        )

        let openedPaths = waitForCapturedOpenPaths(timeout: 5.0)
        guard !openedPaths.isEmpty else {
            XCTFail("Expected open capture after cmd-clicking the spaced path. result=\(result)")
            return
        }

        XCTAssertTrue(
            openedPaths.contains(expectedResolvedPath),
            "Expected cmd-click to open the intended spaced path. opened=\(openedPaths) expected=\(expectedResolvedPath)"
        )

        if let disallowedFileName {
            let disallowedPath = expectedPath(for: disallowedFileName)
            XCTAssertFalse(
                openedPaths.contains(disallowedPath),
                "Expected cmd-click to reject suffix-token decoys. opened=\(openedPaths) wrong=\(disallowedPath)"
            )
        }
    }

    private func assertCommandClickOpensAcrossEveryCharacter(
        fileName: String,
        lineFormat: LineFormat,
        linePrefix: String,
        extraFileNames: [String] = [],
        disallowedFileName: String? = nil
    ) throws {
        let app = launchApp(
            displayMode: .raw,
            lineFormat: lineFormat,
            fileName: fileName,
            linePrefix: linePrefix,
            extraFileNames: extraFileNames,
            captureOpenPaths: true,
            captureHoverDiagnostics: false
        )
        defer { app.terminate() }

        let setup = try waitForReadySetup()
        let expectedResolvedPath = expectedPath(for: fileName)
        XCTAssertEqual(setup.expectedPath, expectedResolvedPath)

        var previousOpenCount = loadCapturedOpenPaths().count
        for tokenColumnOffset in 0..<fileName.count {
            let result = try runCommand(
                action: "cmd_click_token",
                additionalPayload: ["tokenColumnOffset": tokenColumnOffset]
            )
            XCTAssertEqual(
                result["lastCommandSucceeded"] as? String,
                "1",
                "Expected cmd-click to open the full spaced path from token column \(tokenColumnOffset). result=\(result)"
            )
            XCTAssertEqual(
                result["lastCommandOpenedPath"] as? String,
                expectedResolvedPath,
                "Expected cmd-click at token column \(tokenColumnOffset) to open the full spaced path. result=\(result)"
            )

            let openedPaths = try waitForOpenCount(previousOpenCount + 1, timeout: 5.0)
            XCTAssertEqual(
                openedPaths.last,
                expectedResolvedPath,
                "Expected cmd-click at token column \(tokenColumnOffset) to open the intended spaced path. opened=\(openedPaths)"
            )

            if let disallowedFileName {
                XCTAssertNotEqual(
                    openedPaths.last,
                    expectedPath(for: disallowedFileName),
                    "Expected cmd-click at token column \(tokenColumnOffset) to reject suffix-token decoys. opened=\(openedPaths)"
                )
            }

            previousOpenCount = openedPaths.count
        }
    }

    private func assertCommandClickDoesNothingAtInvalidOffsets(
        fileName: String,
        lineFormat: LineFormat,
        linePrefix: String,
        extraFileNames: [String] = []
    ) throws {
        let app = launchApp(
            displayMode: .raw,
            lineFormat: lineFormat,
            fileName: fileName,
            linePrefix: linePrefix,
            extraFileNames: extraFileNames,
            captureOpenPaths: true,
            captureHoverDiagnostics: false
        )
        defer { app.terminate() }

        let setup = try waitForReadySetup()
        let expectedResolvedPath = expectedPath(for: fileName)
        XCTAssertEqual(setup.expectedPath, expectedResolvedPath)

        let invalidOffsets = invalidTokenColumnOffsets(for: fileName)
        let previousOpenCount = loadCapturedOpenPaths().count
        for tokenColumnOffset in invalidOffsets {
            let result = try runCommand(
                action: "cmd_click_token",
                additionalPayload: ["tokenColumnOffset": tokenColumnOffset]
            )
            XCTAssertNil(
                result["lastCommandOpenedPath"] as? String,
                "Expected cmd-click on invalid token column \(tokenColumnOffset) to open nothing. result=\(result)"
            )
            XCTAssertEqual(
                result["lastCommandSucceeded"] as? String,
                "0",
                "Expected cmd-click on invalid token column \(tokenColumnOffset) to stay unresolved. result=\(result)"
            )
            XCTAssertTrue(
                waitForOpenCountToStay(previousOpenCount, timeout: 0.75),
                "Expected cmd-click on invalid token column \(tokenColumnOffset) to leave open count unchanged. opened=\(loadCapturedOpenPaths())"
            )
        }
    }

    private func expectedPath(for fileName: String) -> String {
        fixtureDirectoryURL.appendingPathComponent(fileName).path
    }

    private func invalidTokenColumnOffsets(for fileName: String) -> [Int] {
        let separatorStart = fileName.count
        let separatorOffsets = Array(separatorStart..<(separatorStart + 4))
        let trailingBlankOffset = separatorStart + 4 + "OtherFile".count + 2
        return separatorOffsets + [trailingBlankOffset]
    }

    func testSSHCmdClickDownloadsSpacedPathIntoPreview() throws {
        let socketPath = "/tmp/cmux-ui-ssh-preview-\(UUID().uuidString).sock"
        let hostKey = fixtureDirectoryURL.appendingPathComponent("host-key").path
        let clientKey = fixtureDirectoryURL.appendingPathComponent("client-key").path
        _ = try runSSHPreviewFixtureTool("/usr/bin/ssh-keygen", ["-q", "-t", "ed25519", "-N", "", "-f", hostKey])
        _ = try runSSHPreviewFixtureTool("/usr/bin/ssh-keygen", ["-q", "-t", "ed25519", "-N", "", "-f", clientKey])
        let port = try XCTUnwrap(Int(try runSSHPreviewFixtureTool("/usr/bin/python3", [
            "-c", "import socket; s=socket.socket(); s.bind(('127.0.0.1',0)); print(s.getsockname()[1])"
        ]).trimmingCharacters(in: .whitespacesAndNewlines)))
        let config = fixtureDirectoryURL.appendingPathComponent("sshd-config")
        try """
        Port \(port)
        ListenAddress 127.0.0.1
        HostKey \(hostKey)
        PidFile \(fixtureDirectoryURL.appendingPathComponent("sshd.pid").path)
        AuthorizedKeysFile \(clientKey).pub
        PasswordAuthentication no
        KbdInteractiveAuthentication no
        UsePAM no
        StrictModes no
        AllowUsers \(NSUserName())
        LogLevel ERROR
        """.write(to: config, atomically: true, encoding: .utf8)
        let server = Process()
        server.executableURL = URL(fileURLWithPath: "/usr/sbin/sshd")
        server.arguments = ["-D", "-e", "-f", config.path]
        server.standardOutput = FileHandle.nullDevice
        server.standardError = FileHandle.nullDevice
        try server.run()
        defer {
            if server.isRunning { server.terminate() }
            server.waitUntilExit()
            try? FileManager.default.removeItem(atPath: socketPath)
        }
        let sshOptions = [
            "BatchMode=yes", "ConnectTimeout=1", "StrictHostKeyChecking=accept-new",
            "UserKnownHostsFile=\(fixtureDirectoryURL.appendingPathComponent("known-hosts").path)"
        ]
        let sshArgs = ["-p", String(port), "-i", clientKey]
            + sshOptions.flatMap { ["-o", $0] }
            + ["\(NSUserName())@127.0.0.1", "true"]
        XCTAssertTrue(waitForCondition(timeout: 10) {
            (try? self.runSSHPreviewFixtureTool("/usr/bin/ssh", sshArgs)) != nil
        }, "Expected the isolated SSH server to accept the test key")

        let fileName = "SSH preview file.txt"
        let marker = "REMOTE_PREVIEW_\(UUID().uuidString)\n"
        try marker.write(to: fixtureDirectoryURL.appendingPathComponent(fileName), atomically: true, encoding: .utf8)
        let app = launchApp(
            displayMode: .raw,
            fileName: fileName,
            displayAsAbsolutePath: false,
            captureOpenPaths: true,
            captureHoverDiagnostics: false,
            openSupportedFilesInCmux: true,
            socketPath: socketPath
        )
        defer { app.terminate() }
        let setup = try waitForReadySetup()
        XCTAssertTrue(waitForControlSocketReady(socketPath: socketPath, pingTimeout: 10) {
            self.controlSocketCommandViaNetcat("ping", socketPath: socketPath) == "PONG"
        })
        let terminalID = try XCTUnwrap(setup.payload["surfaceId"] as? String)
        let debug = try sshPreviewRPC("debug.terminals", socketPath: socketPath)
        let terminals = try XCTUnwrap(debug["terminals"] as? [[String: Any]])
        let workspaceID = try XCTUnwrap(terminals.first { $0["surface_id"] as? String == terminalID }?["workspace_id"] as? String)
        // Configure the existing pointer fixture as a managed SSH source. Both
        // the terminal transcript and the preview download use real loopback SSH.
        _ = try sshPreviewRPC("workspace.remote.configure", socketPath: socketPath, params: [
            "workspace_id": workspaceID, "destination": "\(NSUserName())@127.0.0.1",
            "port": port, "identity_file": clientKey, "ssh_options": sshOptions,
            "auto_connect": false, "skip_daemon_bootstrap": true, "terminal_startup_command": "ssh"
        ])
        let transcriptMarker = "SSH_TRANSCRIPT_" + UUID().uuidString
        let remoteDirectory = "'" + fixtureDirectoryURL.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let remoteCommand = "cd \(remoteDirectory) || exit; printf '\\033[2J\\033[H'; i=0; while [ $i -lt 48 ]; do printf '%s\\n' "
            + "'\(fileName)    OtherFile \(transcriptMarker)'; i=$((i+1)); done; exec /bin/cat"
        let terminalArguments = ["/usr/bin/ssh", "-tt"] + Array(sshArgs.dropLast()) + [remoteCommand]
        let terminalCommand = terminalArguments.map { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }
            .joined(separator: " ")
        _ = try sshPreviewRPC("surface.send_text", socketPath: socketPath, params: [
            "workspace_id": workspaceID, "surface_id": terminalID, "text": terminalCommand + "\n"
        ])
        XCTAssertTrue(waitForCondition(timeout: 15) {
            guard let result = self.sshPreviewRPCResultIfAvailable("surface.read_text", socketPath: socketPath, params: [
                "workspace_id": workspaceID, "surface_id": terminalID
            ]), let text = result["text"] as? String else { return false }
            return text.components(separatedBy: transcriptMarker).count > 10
        }, "Expected actual SSH output before clicking the path")
        _ = try sshPreviewRPC("surface.report_pwd", socketPath: socketPath, params: [
            "workspace_id": workspaceID, "surface_id": terminalID, "path": fixtureDirectoryURL.path
        ])
        _ = try runCommand(action: "cmd_click_token")
        XCTAssertTrue(waitForCondition(timeout: 20) {
            guard let result = self.sshPreviewRPCResultIfAvailable("surface.list", socketPath: socketPath, params: ["workspace_id": workspaceID]),
                  let surfaces = result["surfaces"] as? [[String: Any]] else { return false }
            return surfaces.contains { $0["type"] as? String == "filepreview" }
        }, "Expected Cmd-click in the SSH terminal to create a file preview")
        XCTAssertTrue(loadCapturedOpenPaths().isEmpty, "Remote paths must not reach the local preferred editor")
        let cache = FileManager.default.temporaryDirectory.appendingPathComponent("cmux-remote-terminal-previews")
        let entries = FileManager.default.enumerator(at: cache, includingPropertiesForKeys: nil)
        let downloaded = (entries?.allObjects as? [URL] ?? []).first {
            $0.lastPathComponent == fileName && (try? String(contentsOf: $0, encoding: .utf8)) == marker
        }
        XCTAssertNotNil(downloaded, "Expected SSH bytes in the preview cache, not the original local shadow file")
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "SSH command-click file preview"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    private func runSSHPreviewFixtureTool(_ executable: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "SSHPreviewFixture", code: Int(process.terminationStatus))
        }
        return String(decoding: data, as: UTF8.self)
    }

    private func sshPreviewRPCResultIfAvailable(
        _ method: String,
        socketPath: String,
        params: [String: Any] = [:]
    ) -> [String: Any]? {
        guard let response = controlSocketJSONViaNetcat([
            "id": UUID().uuidString, "method": method, "params": params
        ], socketPath: socketPath), response["error"] == nil else { return nil }
        return response["result"] as? [String: Any]
    }

    private func sshPreviewRPC(
        _ method: String,
        socketPath: String,
        params: [String: Any] = [:]
    ) throws -> [String: Any] {
        let response = try XCTUnwrap(controlSocketJSONViaNetcat([
            "id": UUID().uuidString, "method": method, "params": params
        ], socketPath: socketPath))
        XCTAssertNil(response["error"], "RPC failed: \(response)")
        return try XCTUnwrap(response["result"] as? [String: Any])
    }

    private func launchApp(
        displayMode: DisplayMode = .escaped,
        lineFormat: LineFormat = .grid,
        fileName: String = "Cmd Click Fixture.txt",
        linePrefix: String = "",
        displaySuffix: String = "",
        displayAsAbsolutePath: Bool = false,
        extraFileNames: [String] = [],
        captureOpenPaths: Bool,
        captureHoverDiagnostics: Bool,
        openSupportedFilesInCmux: Bool = false,
        openMarkdownInCmuxViewer: Bool? = nil,
        quicklookOverride: String? = nil,
        viewportOffsetDelta: Int? = nil,
        mouseReporting: Bool = false,
        socketPath: String? = nil
    ) -> XCUIApplication {
        let app = XCUIApplication.cmuxTestApplication()
        if let socketPath {
            app.launchArguments += ["-socketControlMode", "allowAll"]
            app.launchEnvironment["CMUX_SOCKET_PATH"] = socketPath
            app.launchEnvironment["CMUX_SOCKET_ENABLE"] = "1"
            app.launchEnvironment["CMUX_SOCKET_MODE"] = "allowAll"
        }
        app.launchEnvironment["CMUX_TAG"] = "ui-test-terminal-cmd-click"
        app.launchEnvironment["CMUX_UI_TEST_MODE"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_TERMINAL_CMD_CLICK_SETUP"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_TERMINAL_CMD_CLICK_PATH"] = setupDataPath
        app.launchEnvironment["CMUX_UI_TEST_TERMINAL_CMD_CLICK_COMMAND_PATH"] = commandPath
        app.launchEnvironment["CMUX_UI_TEST_TERMINAL_CMD_CLICK_FIXTURE_DIR"] = fixtureDirectoryURL.path
        app.launchEnvironment["CMUX_UI_TEST_TERMINAL_CMD_CLICK_FILE_NAME"] = fileName
        app.launchEnvironment["CMUX_UI_TEST_TERMINAL_CMD_CLICK_DISPLAY_MODE"] = displayMode.rawValue
        app.launchEnvironment["CMUX_UI_TEST_TERMINAL_CMD_CLICK_LINE_FORMAT"] = lineFormat.rawValue
        if mouseReporting {
            app.launchEnvironment["CMUX_UI_TEST_TERMINAL_CMD_CLICK_MOUSE_REPORTING"] = "1"
        }
        app.launchEnvironment["CMUX_UI_TEST_OPEN_SUPPORTED_FILES_IN_CMUX"] = openSupportedFilesInCmux ? "1" : "0"
        if !displaySuffix.isEmpty {
            app.launchEnvironment["CMUX_UI_TEST_TERMINAL_CMD_CLICK_DISPLAY_SUFFIX"] = displaySuffix
        }
        if displayAsAbsolutePath {
            app.launchEnvironment["CMUX_UI_TEST_TERMINAL_CMD_CLICK_DISPLAY_AS_ABSOLUTE_PATH"] = "1"
        }
        if let openMarkdownInCmuxViewer {
            app.launchEnvironment["CMUX_UI_TEST_OPEN_MARKDOWN_IN_CMUX_VIEWER"] = openMarkdownInCmuxViewer ? "1" : "0"
        }
        if !linePrefix.isEmpty {
            app.launchEnvironment["CMUX_UI_TEST_TERMINAL_CMD_CLICK_LINE_PREFIX"] = linePrefix
        }
        if !extraFileNames.isEmpty,
           let data = try? JSONSerialization.data(withJSONObject: extraFileNames, options: [.sortedKeys]),
           let json = String(data: data, encoding: .utf8) {
            app.launchEnvironment["CMUX_UI_TEST_TERMINAL_CMD_CLICK_EXTRA_FILE_NAMES_JSON"] = json
        }
        if captureOpenPaths {
            app.launchEnvironment["CMUX_UI_TEST_CAPTURE_OPEN_PATH"] = openCapturePath
        }
        if lineFormat == .osc8 || lineFormat == .plainURL {
            app.launchEnvironment["CMUX_UI_TEST_CAPTURE_OPEN_URL_PATH"] = openURLCapturePath
        }
        if captureHoverDiagnostics {
            app.launchEnvironment["CMUX_UI_TEST_CMD_HOVER_DIAGNOSTICS_PATH"] = hoverDiagnosticsPath
        }
        if let quicklookOverride {
            app.launchEnvironment["CMUX_UI_TEST_TERMINAL_CMD_CLICK_QUICKLOOK_OVERRIDE"] = quicklookOverride
        }
        if let viewportOffsetDelta {
            app.launchEnvironment["CMUX_UI_TEST_TERMINAL_CMD_CLICK_VIEWPORT_OFFSET_DELTA"] = String(viewportOffsetDelta)
        }
        launchAndEnsureForeground(app)
        return app
    }

    /// Launches with the dedicated hard-wrap harness
    /// (`setupTerminalCmdClickWrapUITestIfNeeded`), which sizes its fixture
    /// filename to the live terminal column count rather than a
    /// compile-time guess. See `testCmdClickHardWrappedPathTopRowOpensJoinedPath`.
    private func launchWrapScenarioApp(captureOpenPaths: Bool) -> XCUIApplication {
        let app = XCUIApplication.cmuxTestApplication()
        app.launchEnvironment["CMUX_TAG"] = "ui-test-terminal-cmd-click-wrap"
        app.launchEnvironment["CMUX_UI_TEST_MODE"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_TERMINAL_CMD_CLICK_WRAP_SETUP"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_TERMINAL_CMD_CLICK_WRAP_PATH"] = wrapSetupDataPath
        app.launchEnvironment["CMUX_UI_TEST_TERMINAL_CMD_CLICK_WRAP_COMMAND_PATH"] = wrapCommandPath
        app.launchEnvironment["CMUX_UI_TEST_TERMINAL_CMD_CLICK_WRAP_FIXTURE_DIR"] = fixtureDirectoryURL.path
        app.launchEnvironment["CMUX_UI_TEST_OPEN_SUPPORTED_FILES_IN_CMUX"] = "0"
        if captureOpenPaths {
            app.launchEnvironment["CMUX_UI_TEST_CAPTURE_OPEN_PATH"] = openCapturePath
        }
        launchAndEnsureForeground(app)
        return app
    }

    /// Waits for the wrap harness to report readiness and returns the
    /// fixture's expected path, as computed by the app from the live
    /// terminal column count (the test can't predict it in advance).
    private func waitForWrapReadySetup(timeout: TimeInterval = 15.0) throws -> String {
        var expectedResolvedPath: String?
        let matched = waitForCondition(timeout: timeout) {
            guard let payload = self.loadWrapSetupData(),
                  payload["ready"] as? String == "1",
                  let expectedPath = payload["expectedPath"] as? String else {
                return false
            }
            expectedResolvedPath = expectedPath
            return true
        }

        guard matched, let expectedResolvedPath else {
            throw NSError(domain: "TerminalCmdClickUITests", code: 5, userInfo: [
                NSLocalizedDescriptionKey: "Expected wrap harness setup data. payload=\(loadWrapSetupData() ?? [:])"
            ])
        }
        return expectedResolvedPath
    }

    private func runWrapCommand(
        action: String,
        timeout: TimeInterval = 10.0
    ) throws -> [String: Any] {
        let commandID = UUID().uuidString
        let request: [String: Any] = [
            "id": commandID,
            "action": action,
        ]
        let data = try JSONSerialization.data(withJSONObject: request, options: [.sortedKeys])
        try data.write(to: URL(fileURLWithPath: wrapCommandPath), options: .atomic)

        var result: [String: Any]?
        let matched = waitForCondition(timeout: timeout) {
            guard let payload = self.loadWrapSetupData(),
                  payload["lastCommandId"] as? String == commandID else {
                return false
            }
            result = payload
            return true
        }

        guard matched, let result else {
            throw NSError(domain: "TerminalCmdClickUITests", code: 6, userInfo: [
                NSLocalizedDescriptionKey: "Expected wrap command result for \(action). payload=\(loadWrapSetupData() ?? [:])"
            ])
        }
        return result
    }

    private func loadWrapSetupData() -> [String: Any]? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: wrapSetupDataPath)),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return object
    }

    private func waitForCapturedOpenPaths(timeout: TimeInterval, path: String? = nil) -> [String] {
        var openedPaths: [String] = []
        let matched = waitForCondition(timeout: timeout) {
            let lines = self.loadCapturedOpenPaths(path: path)
            guard !lines.isEmpty else { return false }
            openedPaths = lines
            return true
        }
        return matched ? openedPaths : []
    }

    private func loadCapturedOpenPaths(path: String? = nil) -> [String] {
        let capturePath = path ?? openCapturePath
        guard let contents = try? String(contentsOfFile: capturePath, encoding: .utf8) else {
            return []
        }

        return contents
            .split(separator: "\n")
            .map(String.init)
            .filter { !$0.isEmpty }
    }

    private func waitForOpenCount(_ expectedCount: Int, timeout: TimeInterval) throws -> [String] {
        var openedPaths: [String] = []
        let matched = waitForCondition(timeout: timeout) {
            let lines = self.loadCapturedOpenPaths()
            guard lines.count >= expectedCount else { return false }
            openedPaths = lines
            return true
        }

        guard matched else {
            throw NSError(domain: "TerminalCmdClickUITests", code: 4, userInfo: [
                NSLocalizedDescriptionKey: "Expected at least \(expectedCount) opened paths. opened=\(loadCapturedOpenPaths())"
            ])
        }

        return openedPaths
    }

    private func waitForOpenCountToStay(
        _ expectedCount: Int,
        timeout: TimeInterval,
        path: String? = nil
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if loadCapturedOpenPaths(path: path).count != expectedCount {
                return false
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return loadCapturedOpenPaths(path: path).count == expectedCount
    }

    private func waitForHoverDiagnostics(timeout: TimeInterval) -> [String: Any]? {
        var diagnostics: [String: Any]?
        let matched = waitForCondition(timeout: timeout) {
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: self.hoverDiagnosticsPath)),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  (object["suppressed_command_hover_count"] as? Int ?? 0) > 0 else {
                return false
            }
            diagnostics = object
            return true
        }
        return matched ? diagnostics : nil
    }

    private func waitForReadySetup(timeout: TimeInterval = 15.0) throws -> SetupData {
        var setup: SetupData?
        let matched = waitForCondition(timeout: timeout) {
            guard let payload = self.loadSetupData(),
                  payload["ready"] as? String == "1",
                  let expectedPath = payload["expectedPath"] as? String else {
                return false
            }
            setup = SetupData(expectedPath: expectedPath, payload: payload)
            return true
        }

        guard matched, let setup else {
            throw NSError(domain: "TerminalCmdClickUITests", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Expected terminal cmd-click setup data. payload=\(loadSetupData() ?? [:])"
            ])
        }
        return setup
    }

    private func runCommand(
        action: String,
        additionalPayload: [String: Any] = [:],
        timeout: TimeInterval = 10.0
    ) throws -> [String: Any] {
        var request: [String: Any] = [
            "id": UUID().uuidString,
            "action": action,
        ]
        for (key, value) in additionalPayload {
            request[key] = value
        }
        let commandID = request["id"] as! String
        let data = try JSONSerialization.data(withJSONObject: request, options: [.sortedKeys])
        try data.write(to: URL(fileURLWithPath: commandPath))

        var result: [String: Any]?
        let matched = waitForCondition(timeout: timeout) {
            guard let payload = self.loadSetupData(),
                  payload["lastCommandId"] as? String == commandID else {
                return false
            }
            result = payload
            return true
        }

        guard matched, let result else {
            throw NSError(domain: "TerminalCmdClickUITests", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "Expected command result for \(action). payload=\(loadSetupData() ?? [:])"
            ])
        }
        return result
    }

    private func loadSetupData() -> [String: Any]? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: setupDataPath)),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return object
    }

    /// Launches the app and fails unless it reaches the foreground before UI input begins.
    private func launchAndEnsureForeground(_ app: XCUIApplication, timeout: TimeInterval = 12.0) {
        // Activation is required before this suite drives keyboard and pointer
        // input. Do not mask launch failures with XCTExpectFailure: with
        // continueAfterFailure disabled, XCTest can stop the test here and
        // report the expected failure as a passing test without running its body.
        app.launch()

        guard app.state == .runningForeground || app.state == .runningBackground else {
            XCTFail("App failed to start. state=\(app.state.rawValue)")
            return
        }

        app.activate()
        let foregrounded = waitForCondition(timeout: timeout) {
            Self.isReadyForInteraction(app.state)
        }
        XCTAssertTrue(
            foregrounded,
            "Expected app activation before driving cmd-key harness. state=\(app.state.rawValue)"
        )
    }

    private static func isReadyForInteraction(_ state: XCUIApplication.State) -> Bool {
        state == .runningForeground
    }

    private func waitForCondition(
        timeout: TimeInterval,
        pollInterval: TimeInterval = 0.05,
        predicate: @escaping () -> Bool
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(pollInterval))
        }
        return predicate()
    }
}
