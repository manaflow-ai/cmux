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
    }

    private struct SetupData {
        let expectedPath: String
        let payload: [String: Any]
    }

    private var hoverDiagnosticsPath = ""
    private var openCapturePath = ""
    private var setupDataPath = ""
    private var commandPath = ""
    private var fixtureDirectoryURL: URL!

    override func setUp() {
        super.setUp()
        continueAfterFailure = false

        fixtureDirectoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-ui-test-terminal-cmd-click-\(UUID().uuidString)", isDirectory: true)
        hoverDiagnosticsPath = fixtureDirectoryURL.appendingPathComponent("hover.json").path
        openCapturePath = fixtureDirectoryURL.appendingPathComponent("open.log").path
        setupDataPath = fixtureDirectoryURL.appendingPathComponent("setup.json").path
        commandPath = fixtureDirectoryURL.appendingPathComponent("command.json").path

        try? FileManager.default.removeItem(atPath: hoverDiagnosticsPath)
        try? FileManager.default.removeItem(atPath: openCapturePath)
        try? FileManager.default.removeItem(atPath: setupDataPath)
        try? FileManager.default.removeItem(atPath: commandPath)
        try? FileManager.default.createDirectory(at: fixtureDirectoryURL, withIntermediateDirectories: true)
        XCTAssertTrue(
            FileManager.default.createFile(
                atPath: commandPath,
                contents: Data("{}".utf8)
            ),
            "Expected shared command file to be writable at \(commandPath)"
        )
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: hoverDiagnosticsPath)
        try? FileManager.default.removeItem(atPath: openCapturePath)
        try? FileManager.default.removeItem(atPath: setupDataPath)
        try? FileManager.default.removeItem(atPath: commandPath)
        try? FileManager.default.removeItem(at: fixtureDirectoryURL)
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

        guard let openedPaths = waitForCapturedOpenPaths(timeout: 5.0) else {
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

        guard let openedPaths = waitForCapturedOpenPaths(timeout: 5.0) else {
            XCTFail("Expected cmd-click capture log after running the raw-space command harness. result=\(result)")
            return
        }

        XCTAssertTrue(
            openedPaths.contains(expectedPath),
            "Expected cmd-click to resolve the raw-space path to the real file. opened=\(openedPaths) expected=\(expectedPath)"
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

        guard let openedPaths = waitForCapturedOpenPaths(timeout: 5.0) else {
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

        guard let openedPaths = waitForCapturedOpenPaths(timeout: 5.0) else {
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

        guard let openedPaths = waitForCapturedOpenPaths(timeout: 5.0) else {
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

    private func launchApp(
        displayMode: DisplayMode = .escaped,
        lineFormat: LineFormat = .grid,
        fileName: String = "Cmd Click Fixture.txt",
        linePrefix: String = "",
        extraFileNames: [String] = [],
        captureOpenPaths: Bool,
        captureHoverDiagnostics: Bool,
        quicklookOverride: String? = nil,
        viewportOffsetDelta: Int? = nil
    ) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_TAG"] = "ui-test-terminal-cmd-click"
        app.launchEnvironment["CMUX_UI_TEST_MODE"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_TERMINAL_CMD_CLICK_SETUP"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_TERMINAL_CMD_CLICK_PATH"] = setupDataPath
        app.launchEnvironment["CMUX_UI_TEST_TERMINAL_CMD_CLICK_COMMAND_PATH"] = commandPath
        app.launchEnvironment["CMUX_UI_TEST_TERMINAL_CMD_CLICK_FIXTURE_DIR"] = fixtureDirectoryURL.path
        app.launchEnvironment["CMUX_UI_TEST_TERMINAL_CMD_CLICK_FILE_NAME"] = fileName
        app.launchEnvironment["CMUX_UI_TEST_TERMINAL_CMD_CLICK_DISPLAY_MODE"] = displayMode.rawValue
        app.launchEnvironment["CMUX_UI_TEST_TERMINAL_CMD_CLICK_LINE_FORMAT"] = lineFormat.rawValue
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

    private func waitForCapturedOpenPaths(timeout: TimeInterval) -> [String]? {
        var openedPaths: [String]?
        let matched = waitForCondition(timeout: timeout) {
            let lines = self.loadCapturedOpenPaths()
            guard !lines.isEmpty else { return false }
            openedPaths = lines
            return true
        }
        return matched ? openedPaths : nil
    }

    private func loadCapturedOpenPaths() -> [String] {
        guard let contents = try? String(contentsOfFile: openCapturePath, encoding: .utf8) else {
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

    private func waitForOpenCountToStay(_ expectedCount: Int, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if loadCapturedOpenPaths().count != expectedCount {
                return false
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return loadCapturedOpenPaths().count == expectedCount
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

    private func launchAndEnsureForeground(_ app: XCUIApplication, timeout: TimeInterval = 12.0) {
        let options = XCTExpectedFailure.Options()
        options.isStrict = false
        XCTExpectFailure("App activation may fail on headless GUI runners", options: options) {
            app.launch()
        }

        guard app.state == .runningForeground || app.state == .runningBackground else {
            XCTFail("App failed to start. state=\(app.state.rawValue)")
            return
        }

        app.activate()
        let foregrounded = waitForCondition(timeout: timeout) {
            app.state == .runningForeground || app.windows.firstMatch.exists
        }
        XCTAssertTrue(
            foregrounded,
            "Expected app activation before driving cmd-key harness. state=\(app.state.rawValue)"
        )
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
