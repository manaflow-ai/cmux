import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class SchedulerSidebarTests: XCTestCase {

    // MARK: - SidebarSelection ↔ SessionSidebarSelection round-trip

    func testSidebarSelectionSchedulerMapsToTabsInSessionSidebarSelection() {
        // Scheduler is now an independent right panel, not a sidebar selection.
        // Converting .scheduler to SessionSidebarSelection maps to .tabs.
        let session = SessionSidebarSelection(selection: .scheduler)
        XCTAssertEqual(session, .tabs)
        XCTAssertEqual(session.sidebarSelection, .tabs)
    }

    func testSessionSidebarSelectionSchedulerDecodesBackwardCompat() {
        // Old sessions with .scheduler stored should map to .tabs on restore
        let oldSession = SessionSidebarSelection.scheduler
        XCTAssertEqual(oldSession.sidebarSelection, .tabs)
    }

    func testSidebarSelectionTabsRoundTripsToSessionSidebarSelection() {
        let session = SessionSidebarSelection(selection: .tabs)
        XCTAssertEqual(session, .tabs)
        XCTAssertEqual(session.sidebarSelection, .tabs)
    }

    func testSidebarSelectionNotificationsRoundTripsToSessionSidebarSelection() {
        let session = SessionSidebarSelection(selection: .notifications)
        XCTAssertEqual(session, .notifications)
        XCTAssertEqual(session.sidebarSelection, .notifications)
    }

    func testSessionSidebarSelectionSchedulerCodableRoundTrip() throws {
        let original = SessionSidebarSelection.scheduler
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(SessionSidebarSelection.self, from: data)
        XCTAssertEqual(decoded, .scheduler)
    }

    func testSessionSidebarSelectionSchedulerDecodesFromString() throws {
        let json = "\"scheduler\"".data(using: .utf8)!
        let decoded = try JSONDecoder().decode(SessionSidebarSelection.self, from: json)
        XCTAssertEqual(decoded, .scheduler)
    }

    func testSessionSidebarSnapshotPreservesSchedulerSelection() throws {
        let snapshot = SessionSidebarSnapshot(
            isVisible: true,
            selection: .scheduler,
            width: 240
        )
        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(SessionSidebarSnapshot.self, from: data)
        XCTAssertEqual(decoded.selection, .scheduler)
        XCTAssertEqual(decoded.isVisible, true)
        XCTAssertEqual(decoded.width, 240)
    }

    // MARK: - Fingerprint hasher handles scheduler case

    func testFingerprintHasherDistinguishesSchedulerFromTabsAndNotifications() {
        // Verify the enum's Hashable conformance produces distinct entries in a Set.
        let allCases: Set<SidebarSelection> = [.tabs, .notifications, .scheduler]
        XCTAssertEqual(allCases.count, 3, "All sidebar selections must be distinct in a Set")

        // Verify each case survives round-trip through Set insertion
        XCTAssertTrue(allCases.contains(.tabs))
        XCTAssertTrue(allCases.contains(.notifications))
        XCTAssertTrue(allCases.contains(.scheduler))
    }

    // MARK: - KeyboardShortcutSettings.showScheduler

    func testShowSchedulerShortcutExists() {
        let action = KeyboardShortcutSettings.Action.showScheduler
        XCTAssertEqual(action.label, "Show Scheduler")
        XCTAssertEqual(action.defaultsKey, "shortcut.showScheduler")

        let shortcut = action.defaultShortcut
        XCTAssertEqual(shortcut.key, "j")
        XCTAssertTrue(shortcut.command)
        XCTAssertFalse(shortcut.shift)
        XCTAssertFalse(shortcut.option)
        XCTAssertFalse(shortcut.control)
    }

    func testShowSchedulerShortcutDoesNotCollideWithExistingDefaults() {
        let schedulerShortcut = KeyboardShortcutSettings.Action.showScheduler.defaultShortcut
        for action in KeyboardShortcutSettings.Action.allCases where action != .showScheduler {
            let other = action.defaultShortcut
            let sameKey = schedulerShortcut.key == other.key
                && schedulerShortcut.command == other.command
                && schedulerShortcut.shift == other.shift
                && schedulerShortcut.option == other.option
                && schedulerShortcut.control == other.control
            XCTAssertFalse(sameKey, "showScheduler shortcut collides with \(action.rawValue)")
        }
    }

    // MARK: - ClaudeTokenTracker

    func testParseEmptyJSONLReturnsZeroUsage() {
        let tempFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-empty-\(UUID().uuidString).jsonl")
        FileManager.default.createFile(atPath: tempFile.path, contents: Data())
        defer { try? FileManager.default.removeItem(at: tempFile) }

        let usage = ClaudeTokenTracker.parseJSONL(at: tempFile)
        XCTAssertEqual(usage.totalTokens, 0)
        XCTAssertEqual(usage.estimatedCostUSD, 0.0, accuracy: 0.001)
    }

    func testParseJSONLExtractsTokenUsage() throws {
        let tempFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-tokens-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: tempFile) }

        let line = """
        {"type":"assistant","message":{"usage":{"input_tokens":100,"output_tokens":50,"cache_creation_input_tokens":200,"cache_read_input_tokens":300}}}
        """
        try line.write(to: tempFile, atomically: true, encoding: .utf8)

        let usage = ClaudeTokenTracker.parseJSONL(at: tempFile)
        XCTAssertEqual(usage.inputTokens, 100)
        XCTAssertEqual(usage.outputTokens, 50)
        XCTAssertEqual(usage.cacheCreationTokens, 200)
        XCTAssertEqual(usage.cacheReadTokens, 300)
        XCTAssertEqual(usage.totalTokens, 650)
        XCTAssertGreaterThan(usage.estimatedCostUSD, 0)
    }

    func testParseJSONLAggregatesMultipleLines() throws {
        let tempFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-multi-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: tempFile) }

        let lines = """
        {"type":"assistant","message":{"usage":{"input_tokens":10,"output_tokens":5,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}
        {"type":"assistant","message":{"usage":{"input_tokens":20,"output_tokens":15,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}
        """
        try lines.write(to: tempFile, atomically: true, encoding: .utf8)

        let usage = ClaudeTokenTracker.parseJSONL(at: tempFile)
        XCTAssertEqual(usage.inputTokens, 30)
        XCTAssertEqual(usage.outputTokens, 20)
    }

    func testParseMissingJSONLReturnsZeroUsage() {
        let usage = ClaudeTokenTracker.parseJSONL(
            at: URL(fileURLWithPath: "/nonexistent/file.jsonl")
        )
        XCTAssertEqual(usage.totalTokens, 0)
    }

    func testFormatTokens() {
        XCTAssertEqual(ClaudeTokenTracker.formatTokens(0), "0")
        XCTAssertEqual(ClaudeTokenTracker.formatTokens(500), "500")
        XCTAssertEqual(ClaudeTokenTracker.formatTokens(1_500), "2K")
        XCTAssertEqual(ClaudeTokenTracker.formatTokens(1_500_000), "1.5M")
    }

    func testFormatCost() {
        XCTAssertEqual(ClaudeTokenTracker.formatCost(0.005), "<$0.01")
        XCTAssertEqual(ClaudeTokenTracker.formatCost(1.234), "$1.23")
        XCTAssertEqual(ClaudeTokenTracker.formatCost(10.0), "$10.00")
    }

    func testTokenUsageAdd() {
        var a = ClaudeTokenTracker.TokenUsage(
            inputTokens: 10, outputTokens: 20,
            cacheCreationTokens: 30, cacheReadTokens: 40
        )
        let b = ClaudeTokenTracker.TokenUsage(
            inputTokens: 5, outputTokens: 10,
            cacheCreationTokens: 15, cacheReadTokens: 20
        )
        a.add(b)
        XCTAssertEqual(a.inputTokens, 15)
        XCTAssertEqual(a.outputTokens, 30)
        XCTAssertEqual(a.cacheCreationTokens, 45)
        XCTAssertEqual(a.cacheReadTokens, 60)
    }

    func testAggregateUsageWithMissingDirectoryReturnsZero() {
        let usage = ClaudeTokenTracker.aggregateUsage(
            projectsDirectory: URL(fileURLWithPath: "/nonexistent/dir")
        )
        XCTAssertEqual(usage.totalTokens, 0)
    }

    func testAggregateUsageReadsFromProjectDirectory() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-aggregate-\(UUID().uuidString)", isDirectory: true)
        let subdir = tempDir.appendingPathComponent("project-abc", isDirectory: true)
        try FileManager.default.createDirectory(at: subdir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let line = """
        {"type":"assistant","message":{"usage":{"input_tokens":1000,"output_tokens":500,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}
        """
        let jsonlFile = subdir.appendingPathComponent("session1.jsonl")
        try line.write(to: jsonlFile, atomically: true, encoding: .utf8)

        let usage = ClaudeTokenTracker.aggregateUsage(projectsDirectory: tempDir)
        XCTAssertEqual(usage.inputTokens, 1000)
        XCTAssertEqual(usage.outputTokens, 500)
    }

    // MARK: - SchedulerPage empty state (data-layer test)

    @MainActor
    func testSchedulerPageEmptyStateCondition() {
        // When SchedulerEngine has no tasks, SchedulerPage renders its empty state.
        // Verify the data condition that drives empty state rendering.
        let tempFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("scheduler-empty-\(UUID().uuidString).json")
        // Don't create the file — load should return empty
        defer { try? FileManager.default.removeItem(at: tempFile) }

        let engine = SchedulerEngine(persistenceFileURL: tempFile)
        XCTAssertTrue(engine.tasks.isEmpty, "Empty engine should have no tasks (drives empty state)")
        XCTAssertEqual(engine.runningTaskCount, 0, "Empty engine should have no running tasks")
        XCTAssertTrue(engine.runs.isEmpty, "Empty engine should have no runs")
    }

    @MainActor
    func testSchedulerPageShowsTasksWhenPresent() {
        let tempFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("scheduler-tasks-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tempFile) }

        let engine = SchedulerEngine(persistenceFileURL: tempFile)
        let task = ScheduledTask(
            name: "Test Task",
            cronExpression: "*/5 * * * *",
            command: "echo hello"
        )
        engine.addTask(task)
        XCTAssertFalse(engine.tasks.isEmpty, "Engine with tasks should not show empty state")
        XCTAssertEqual(engine.tasks.count, 1)
        XCTAssertEqual(engine.tasks.first?.name, "Test Task")
    }

    // MARK: - Cron Preset Validation

    func testCronPresetRawValuesAreValidExpressions() {
        for preset in CronPreset.allCases where preset != .custom {
            guard let expression = preset.expression else {
                XCTFail("Non-custom preset \(preset.rawValue) should have an expression")
                continue
            }
            XCTAssertNotNil(
                CronExpression(expression),
                "Preset \"\(preset.rawValue)\" expression \"\(expression)\" should parse as valid CronExpression"
            )
        }
    }

    func testNextFireDateGeneratesThreeConsecutiveDates() {
        guard let cron = CronExpression("*/5 * * * *") else {
            XCTFail("*/5 * * * * should be a valid cron expression")
            return
        }

        var dates: [Date] = []
        var reference = Date()
        for _ in 0..<3 {
            guard let next = cron.nextFireDate(after: reference) else {
                XCTFail("Should generate next fire date")
                return
            }
            dates.append(next)
            reference = next
        }

        XCTAssertEqual(dates.count, 3, "Should generate exactly 3 dates")

        // Each consecutive date should be ~5 minutes apart (300 seconds)
        for i in 1..<dates.count {
            let interval = dates[i].timeIntervalSince(dates[i - 1])
            XCTAssertEqual(interval, 300, accuracy: 1, "Consecutive dates should be ~5 minutes apart")
        }
    }

    // MARK: - Task CRUD via Engine

    @MainActor
    func testAddTaskThenManuallyRunCallsOnTaskDue() {
        let tempFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("scheduler-run-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tempFile) }

        let expectation = expectation(description: "onTaskDue called")
        let engine = SchedulerEngine(persistenceFileURL: tempFile)
        engine.onTaskDue = { _, _ in
            expectation.fulfill()
        }

        let task = ScheduledTask(
            name: "Run Now Test",
            cronExpression: "0 0 * * *",
            command: "echo test"
        )
        engine.addTask(task)
        let run = engine.manuallyRunTask(task)
        XCTAssertNotNil(run, "manuallyRunTask should return a TaskRun")

        waitForExpectations(timeout: 2)
    }

    // MARK: - Claude Mode Types

    func testClaudeToolPresetReadOnlyContainsExpectedTools() {
        let tools = ClaudeToolPreset.readOnly.tools
        XCTAssertNotNil(tools)
        XCTAssertEqual(tools, ["Read", "Glob", "Grep", "WebSearch"])
    }

    func testClaudeToolPresetStandardContainsExpectedTools() {
        let tools = ClaudeToolPreset.standard.tools
        XCTAssertNotNil(tools)
        XCTAssertEqual(tools, ["Read", "Glob", "Grep", "Edit", "Bash", "Write", "WebSearch"])
    }

    func testClaudeToolPresetFullReturnsNil() {
        XCTAssertNil(ClaudeToolPreset.full.tools, "Full preset should return nil (all tools)")
    }

    func testClaudeModelEnumHasThreeModels() {
        XCTAssertEqual(ClaudeModel.allCases.count, 3)
        XCTAssertTrue(ClaudeModel.allCases.contains(.opus))
        XCTAssertTrue(ClaudeModel.allCases.contains(.sonnet))
        XCTAssertTrue(ClaudeModel.allCases.contains(.haiku))
    }

    func testClaudePermissionModeCLIFlags() {
        XCTAssertEqual(
            ClaudePermissionMode.plan.cliFlag,
            "--permission-mode plan"
        )
        XCTAssertEqual(
            ClaudePermissionMode.autoEdit.cliFlag,
            "--permission-mode acceptEdits"
        )
        XCTAssertEqual(
            ClaudePermissionMode.fullAuto.cliFlag,
            "--dangerously-skip-permissions"
        )
    }

    func testTaskTypeModeDefaultIsClaude() {
        XCTAssertEqual(TaskTypeMode.allCases.first, .claude)
    }

    func testClaudeToolAllContainsTenTools() {
        XCTAssertEqual(ClaudeTool.all.count, 10)
        let names = Set(ClaudeTool.all.map(\.name))
        XCTAssertTrue(names.contains("Read"))
        XCTAssertTrue(names.contains("Bash"))
        XCTAssertTrue(names.contains("Agent"))
    }

    // MARK: - Task CRUD via Engine (continued)

    @MainActor
    func testUpdateTaskPreservesIdAndUpdatesFields() {
        let tempFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("scheduler-update-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tempFile) }

        let engine = SchedulerEngine(persistenceFileURL: tempFile)
        let original = ScheduledTask(
            name: "Original",
            cronExpression: "*/5 * * * *",
            command: "echo original"
        )
        engine.addTask(original)

        var updated = original
        updated.name = "Updated"
        updated.command = "echo updated"
        engine.updateTask(updated)

        XCTAssertEqual(engine.tasks.count, 1, "Should still have exactly one task")
        let result = engine.tasks.first!
        XCTAssertEqual(result.id, original.id, "Task ID should be preserved after update")
        XCTAssertEqual(result.name, "Updated", "Task name should be updated")
        XCTAssertEqual(result.command, "echo updated", "Task command should be updated")
    }
}
