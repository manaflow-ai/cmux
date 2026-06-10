import Darwin
import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif


// MARK: - Surface resume approval records and prompts
extension SessionPersistenceTests {
    func testSurfaceResumeApprovalAutoPolicyAppliesSignedPrefix() throws {
        let storeURL = try makeSurfaceResumeApprovalStoreURL()
        let secret = Data("approval-secret".utf8)
        let binding = SurfaceResumeBindingSnapshot(
            name: "tmux work",
            kind: "tmux",
            command: "tmux attach -t 'work session'",
            cwd: "/tmp/project",
            source: "cli",
            environment: ["PATH": "/usr/bin:/bin"]
        )

        let record = try XCTUnwrap(SurfaceResumeApprovalStore.approve(
            binding: binding,
            policy: .auto,
            commandPrefix: ["tmux", "attach"],
            fileURL: storeURL,
            signingSecret: secret
        ))
        XCTAssertTrue(record.hasValidSignature(secret: secret))

        let effectiveBinding = SurfaceResumeApprovalStore.applyingStoredApproval(
            to: binding,
            fileURL: storeURL,
            signingSecret: secret
        )
        XCTAssertEqual(effectiveBinding.approvalPolicy, .auto)
        XCTAssertEqual(effectiveBinding.approvalRecordId, record.id)
        XCTAssertTrue(effectiveBinding.allowsAutomaticResume)

        let changedEnvironmentBinding = SurfaceResumeBindingSnapshot(
            name: "tmux work",
            kind: "tmux",
            command: "tmux attach -t 'work session'",
            cwd: "/tmp/project",
            source: "cli",
            environment: ["PATH": "/tmp/bin"]
        )
        let changedEnvironmentEffectiveBinding = SurfaceResumeApprovalStore.applyingStoredApproval(
            to: changedEnvironmentBinding,
            fileURL: storeURL,
            signingSecret: secret
        )
        XCTAssertEqual(changedEnvironmentEffectiveBinding.approvalPolicy, .manual)
        XCTAssertFalse(changedEnvironmentEffectiveBinding.allowsAutomaticResume)
    }

    func testSurfaceResumeApprovalRejectsTamperedRecord() throws {
        let storeURL = try makeSurfaceResumeApprovalStoreURL()
        let secret = Data("approval-secret".utf8)
        let binding = SurfaceResumeBindingSnapshot(
            command: "tmux attach -t work",
            cwd: "/tmp/project",
            source: "cli"
        )

        var record = try XCTUnwrap(SurfaceResumeApprovalStore.approve(
            binding: binding,
            policy: .manual,
            fileURL: storeURL,
            signingSecret: secret
        ))
        record.policy = .auto
        let encoder = JSONEncoder()
        let data = try encoder.encode(SurfaceResumeApprovalStore.StoredFile(version: 1, records: [record]))
        try data.write(to: storeURL, options: [.atomic])

        let effectiveBinding = SurfaceResumeApprovalStore.applyingStoredApproval(
            to: binding,
            fileURL: storeURL,
            signingSecret: secret
        )
        XCTAssertEqual(effectiveBinding.approvalPolicy, .manual)
        XCTAssertNil(effectiveBinding.approvalRecordId)
        XCTAssertFalse(effectiveBinding.allowsAutomaticResume)
    }

    func testSurfaceResumeApprovalMissingRecordResetsStalePromptPolicy() throws {
        let binding = SurfaceResumeBindingSnapshot(
            command: "tmux attach -t work",
            cwd: "/tmp/project",
            source: "cli",
            autoResume: false,
            approvalPolicy: .prompt,
            approvalRecordId: "deleted-record"
        )

        let effectiveBinding = SurfaceResumeApprovalStore.applyingStoredApproval(
            to: binding,
            fileURL: URL(fileURLWithPath: "/tmp/cmux-missing-\(UUID().uuidString).json"),
            signingSecret: Data("approval-secret".utf8)
        )
        XCTAssertEqual(effectiveBinding.approvalPolicy, .manual)
        XCTAssertNil(effectiveBinding.approvalRecordId)
        XCTAssertFalse(effectiveBinding.allowsAutomaticResume)
    }

    func testSurfaceResumeApprovalDoesNotPromptForExplicitCLICommand() throws {
        let binding = SurfaceResumeBindingSnapshot(
            command: "tmux attach -t work",
            cwd: "/tmp/project",
            source: "cli"
        )

        XCTAssertFalse(SurfaceResumeApprovalStore.shouldPromptForProposal(
            binding: binding,
            existingRecord: nil,
            isMainThread: true,
            isRunningTests: false
        ))
    }

    func testSurfaceResumeApprovalCreatesManualRecordForPromptlessCLICommand() throws {
        let storeURL = try makeSurfaceResumeApprovalStoreURL()
        let secret = Data("approval-secret".utf8)
        let binding = SurfaceResumeBindingSnapshot(
            name: "tmux work",
            kind: "tmux",
            command: "tmux attach -t work",
            cwd: "/tmp/project",
            source: "cli",
            environment: ["PATH": "/usr/bin:/bin"]
        )

        let effectiveBinding = try XCTUnwrap(SurfaceResumeApprovalStore.applyingPromptlessCLIManualApprovalIfNeeded(
            to: binding,
            existingRecord: nil,
            fileURL: storeURL,
            signingSecret: secret
        ))
        XCTAssertEqual(effectiveBinding.approvalPolicy, .manual)
        XCTAssertFalse(effectiveBinding.allowsAutomaticResume)
        XCTAssertNotNil(effectiveBinding.approvalRecordId)

        let records = SurfaceResumeApprovalStore.validRecords(
            fileURL: storeURL,
            signingSecret: secret
        )
        let record = try XCTUnwrap(records.first)
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(record.policy, .manual)
        XCTAssertEqual(record.source, "cli")
        XCTAssertEqual(record.commandPrefixText, "tmux attach -t work")
        XCTAssertEqual(effectiveBinding.approvalRecordId, record.id)

        XCTAssertNil(SurfaceResumeApprovalStore.applyingPromptlessCLIManualApprovalIfNeeded(
            to: binding,
            existingRecord: record,
            fileURL: storeURL,
            signingSecret: secret
        ))
    }

    func testSurfaceResumeApprovalWritesRecordsIntoCmuxJSON() throws {
        let settingsURL = try makeSurfaceResumeApprovalCmuxSettingsURL()
        let secret = Data("approval-secret".utf8)
        let initialSettings = """
        {
          "$schema": "https://raw.githubusercontent.com/manaflow-ai/cmux/main/web/data/cmux.schema.json",
          // keep root comment
          "schemaVersion": 1,
          "terminal": {
            // keep terminal comment
            "showScrollBar": false
          }
        }
        """.replacingOccurrences(of: "\n", with: "\r\n")
        try initialSettings.write(to: settingsURL, atomically: true, encoding: .utf8)

        let binding = SurfaceResumeBindingSnapshot(
            name: "tmux work",
            kind: "tmux",
            command: "tmux attach -t work",
            cwd: "/tmp/project",
            source: "cli",
            environment: ["PATH": "/usr/bin:/bin"]
        )

        let record = try XCTUnwrap(SurfaceResumeApprovalStore.approve(
            binding: binding,
            policy: .auto,
            commandPrefix: ["tmux", "attach"],
            fileURL: settingsURL,
            signingSecret: secret
        ))

        let root = try jsonObject(at: settingsURL)
        let terminal = try XCTUnwrap(root["terminal"] as? [String: Any])
        XCTAssertEqual(terminal["showScrollBar"] as? Bool, false)
        let storedRecords = try XCTUnwrap(terminal["resumeCommands"] as? [[String: Any]])
        XCTAssertEqual(storedRecords.count, 1)
        XCTAssertEqual(storedRecords.first?["id"] as? String, record.id)
        let updatedSettings = try String(contentsOf: settingsURL, encoding: .utf8)
        XCTAssertTrue(updatedSettings.contains("// keep root comment"))
        XCTAssertTrue(updatedSettings.contains("// keep terminal comment"))
        XCTAssertTrue(updatedSettings.contains("\r\n    \"resumeCommands\""))

        let validRecords = SurfaceResumeApprovalStore.validRecords(
            fileURL: settingsURL,
            signingSecret: secret
        )
        XCTAssertEqual(validRecords.map(\.id), [record.id])
        XCTAssertEqual(validRecords.first?.policy, .auto)
    }

    func testSurfaceResumeApprovalWritesNonUTF8CmuxJSON() throws {
        let settingsURL = try makeSurfaceResumeApprovalCmuxSettingsURL()
        let secret = Data("approval-secret".utf8)
        let initialSettings = """
        {
          "$schema": "https://raw.githubusercontent.com/manaflow-ai/cmux/main/web/data/cmux.schema.json",
          // keep utf16 comment
          "schemaVersion": 1,
          "terminal": {
            "showScrollBar": false
          }
        }
        """
        try XCTUnwrap(initialSettings.data(using: .utf16LittleEndian))
            .write(to: settingsURL, options: [.atomic])

        let binding = SurfaceResumeBindingSnapshot(
            name: "tmux work",
            kind: "tmux",
            command: "tmux attach -t work",
            cwd: "/tmp/project",
            source: "cli",
            environment: ["PATH": "/usr/bin:/bin"]
        )

        let record = try XCTUnwrap(SurfaceResumeApprovalStore.approve(
            binding: binding,
            policy: .auto,
            commandPrefix: ["tmux", "attach"],
            fileURL: settingsURL,
            signingSecret: secret
        ))

        let updatedData = try Data(contentsOf: settingsURL)
        let updatedSettings = try XCTUnwrap(String(data: updatedData, encoding: .utf16LittleEndian))
        XCTAssertTrue(updatedSettings.contains("// keep utf16 comment"))
        XCTAssertTrue(updatedSettings.contains("\"resumeCommands\""))
        let root = try jsonObject(at: settingsURL)
        let terminal = try XCTUnwrap(root["terminal"] as? [String: Any])
        let storedRecords = try XCTUnwrap(terminal["resumeCommands"] as? [[String: Any]])
        XCTAssertEqual(storedRecords.first?["id"] as? String, record.id)
    }

    func testSurfaceResumeApprovalMigratesLegacyRecordsIntoCmuxJSON() throws {
        let settingsURL = try makeSurfaceResumeApprovalCmuxSettingsURL()
        let legacyURL = settingsURL.deletingLastPathComponent()
            .appendingPathComponent("resume-commands.json", isDirectory: false)
        let secret = Data("approval-secret".utf8)
        try """
        {
          "$schema": "https://raw.githubusercontent.com/manaflow-ai/cmux/main/web/data/cmux.schema.json",
          // keep migration comment
          "schemaVersion": 1,
          "rightSidebar": {
            "width": 320
          }
        }
        """.write(to: settingsURL, atomically: true, encoding: .utf8)

        let binding = SurfaceResumeBindingSnapshot(
            name: "tmux work",
            kind: "tmux",
            command: "tmux attach -t work",
            cwd: "/tmp/project",
            source: "cli",
            environment: ["PATH": "/usr/bin:/bin"]
        )

        let record = try XCTUnwrap(SurfaceResumeApprovalStore.approve(
            binding: binding,
            policy: .auto,
            commandPrefix: ["tmux", "attach"],
            fileURL: legacyURL,
            signingSecret: secret
        ))

        XCTAssertTrue(FileManager.default.fileExists(atPath: legacyURL.path))
        XCTAssertTrue(SurfaceResumeApprovalStore.migrateLegacyRecordsIfNeeded(
            fileURL: settingsURL,
            legacyFileURL: legacyURL
        ))

        let root = try jsonObject(at: settingsURL)
        let terminal = try XCTUnwrap(root["terminal"] as? [String: Any])
        let rightSidebar = try XCTUnwrap(root["rightSidebar"] as? [String: Any])
        XCTAssertEqual((rightSidebar["width"] as? NSNumber)?.intValue, 320)
        let storedRecords = try XCTUnwrap(terminal["resumeCommands"] as? [[String: Any]])
        XCTAssertEqual(storedRecords.count, 1)
        XCTAssertEqual(storedRecords.first?["id"] as? String, record.id)
        let updatedSettings = try String(contentsOf: settingsURL, encoding: .utf8)
        XCTAssertTrue(updatedSettings.contains("// keep migration comment"))

        let validRecords = SurfaceResumeApprovalStore.validRecords(
            fileURL: settingsURL,
            signingSecret: secret
        )
        XCTAssertEqual(validRecords.map(\.id), [record.id])
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacyURL.path))

        XCTAssertFalse(SurfaceResumeApprovalStore.migrateLegacyRecordsIfNeeded(
            fileURL: settingsURL,
            legacyFileURL: legacyURL
        ))
        let rootAfterSecondMigration = try jsonObject(at: settingsURL)
        let terminalAfterSecondMigration = try XCTUnwrap(rootAfterSecondMigration["terminal"] as? [String: Any])
        let storedRecordsAfterSecondMigration = try XCTUnwrap(terminalAfterSecondMigration["resumeCommands"] as? [[String: Any]])
        XCTAssertEqual(storedRecordsAfterSecondMigration.count, 1)
    }

    func testSurfaceResumeApprovalDoesNotOverwriteInvalidCmuxJSON() throws {
        let settingsURL = try makeSurfaceResumeApprovalCmuxSettingsURL()
        let legacyURL = settingsURL.deletingLastPathComponent()
            .appendingPathComponent("resume-commands.json", isDirectory: false)
        let secret = Data("approval-secret".utf8)
        let invalidSettingsData = Data("{ \"terminal\":".utf8)
        try invalidSettingsData.write(to: settingsURL, options: [.atomic])

        let binding = SurfaceResumeBindingSnapshot(
            name: "tmux work",
            kind: "tmux",
            command: "tmux attach -t work",
            cwd: "/tmp/project",
            source: "cli",
            environment: ["PATH": "/usr/bin:/bin"]
        )

        let legacyRecord = try XCTUnwrap(SurfaceResumeApprovalStore.approve(
            binding: binding,
            policy: .auto,
            commandPrefix: ["tmux", "attach"],
            fileURL: legacyURL,
            signingSecret: secret
        ))

        XCTAssertEqual(SurfaceResumeApprovalStore.loadRecords(
            fileURL: settingsURL,
            defaultSettingsURL: settingsURL
        ).map(\.id), [legacyRecord.id])
        XCTAssertEqual(try Data(contentsOf: settingsURL), invalidSettingsData)

        XCTAssertFalse(SurfaceResumeApprovalStore.migrateLegacyRecordsIfNeeded(
            fileURL: settingsURL,
            legacyFileURL: legacyURL
        ))
        XCTAssertEqual(try Data(contentsOf: settingsURL), invalidSettingsData)

        XCTAssertNotNil(SurfaceResumeApprovalStore.approve(
            binding: binding,
            policy: .auto,
            commandPrefix: ["tmux", "attach"],
            fileURL: settingsURL,
            signingSecret: secret
        ))
        XCTAssertEqual(try Data(contentsOf: settingsURL), invalidSettingsData)
        XCTAssertTrue(SurfaceResumeApprovalStore.validRecords(
            fileURL: settingsURL,
            signingSecret: secret
        ).isEmpty)
        XCTAssertEqual(SurfaceResumeApprovalStore.validRecords(
            fileURL: legacyURL,
            signingSecret: secret
        ).map(\.id), [legacyRecord.id])
    }

    func testSurfaceResumeApprovalPromptsForUnknownManualProposal() throws {
        let binding = SurfaceResumeBindingSnapshot(
            command: "tmux attach -t work",
            cwd: "/tmp/project",
            source: nil
        )

        XCTAssertTrue(SurfaceResumeApprovalStore.shouldPromptForProposal(
            binding: binding,
            existingRecord: nil,
            isMainThread: true,
            isRunningTests: false
        ))
    }

    func testSurfaceResumePromptPolicyDoesNotRunAutomaticallyUnderTest() throws {
        let storeURL = try makeSurfaceResumeApprovalStoreURL()
        let secret = Data("approval-secret".utf8)
        let binding = SurfaceResumeBindingSnapshot(
            command: "tmux attach -t work",
            cwd: "/tmp/project",
            source: "cli"
        )

        XCTAssertNotNil(SurfaceResumeApprovalStore.approve(
            binding: binding,
            policy: .prompt,
            fileURL: storeURL,
            signingSecret: secret
        ))

        let input = Workspace.surfaceResumeStartupInput(
            binding,
            autoResumeAgentSessions: true,
            approvalStoreURL: storeURL,
            approvalSigningSecret: secret
        )
        XCTAssertNil(input)
    }

    func testSurfaceResumePromptPolicyDoesNotPromptDuringSnapshot() throws {
        let storeURL = try makeSurfaceResumeApprovalStoreURL()
        let secret = Data("approval-secret".utf8)
        let binding = SurfaceResumeBindingSnapshot(
            command: "tmux attach -t work",
            cwd: "/tmp/project",
            source: "cli"
        )

        XCTAssertNotNil(SurfaceResumeApprovalStore.approve(
            binding: binding,
            policy: .prompt,
            fileURL: storeURL,
            signingSecret: secret
        ))

        let input = Workspace.surfaceResumeStartupInput(
            binding,
            autoResumeAgentSessions: true,
            promptForApproval: false,
            approvalStoreURL: storeURL,
            approvalSigningSecret: secret
        )
        XCTAssertNil(input)
    }

    func testProcessDetectedSurfaceResumeRemainsTrustedWithoutApprovalRecord() {
        let binding = SurfaceResumeBindingSnapshot(
            command: "tmux attach -t work",
            cwd: "/tmp/project",
            source: "process-detected"
        )

        let effectiveBinding = SurfaceResumeApprovalStore.applyingStoredApproval(
            to: binding,
            fileURL: URL(fileURLWithPath: "/tmp/cmux-missing-\(UUID().uuidString).json"),
            signingSecret: Data("approval-secret".utf8)
        )
        XCTAssertEqual(effectiveBinding.approvalPolicy, .auto)
        XCTAssertTrue(effectiveBinding.allowsAutomaticResume)
    }

    func testAgentHookSurfaceResumeAutoResumeRemainsTrustedWithoutApprovalRecord() {
        let binding = SurfaceResumeBindingSnapshot(
            command: "codex resume session",
            cwd: "/tmp/project",
            source: "agent-hook",
            autoResume: true
        )

        let effectiveBinding = SurfaceResumeApprovalStore.applyingStoredApproval(
            to: binding,
            fileURL: URL(fileURLWithPath: "/tmp/cmux-missing-\(UUID().uuidString).json"),
            signingSecret: Data("approval-secret".utf8)
        )
        XCTAssertEqual(effectiveBinding.approvalPolicy, .auto)
        XCTAssertTrue(effectiveBinding.allowsAutomaticResume)
    }

    private func makeSurfaceResumeApprovalStoreURL() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-surface-resume-approvals-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
        }
        return root.appendingPathComponent("resume-commands.json", isDirectory: false)
    }

    private func makeSurfaceResumeApprovalCmuxSettingsURL() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-surface-resume-settings-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
        }
        return root.appendingPathComponent("cmux.json", isDirectory: false)
    }

    private func jsonObject(at url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        let sanitized = try JSONCParser.preprocess(data: data)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: sanitized) as? [String: Any])
    }

}
