import XCTest

@testable import CMUXAgentLaunch

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class TaskManagerResourcesTests: XCTestCase {
    func testGrokCodingAgentDefinitionMatchesSymlinkLaunch() throws {
        let definition = try XCTUnwrap(CmuxTaskManagerCodingAgentDefinition.matchingDefinition(
            processName: "grok",
            processPath: "/Users/example/.grok/bin/grok",
            arguments: ["/Users/example/.grok/bin/grok", "--no-alt-screen"],
            environment: [:]
        ))

        XCTAssertEqual(definition.id, "grok")
        XCTAssertTrue(definition.directBasenames.contains("grok"))
        XCTAssertTrue(definition.argumentNeedles.contains("grok-build"))
    }

    func testGrokCodingAgentDefinitionMatchesResolvedBinaryLaunch() throws {
        let definition = try XCTUnwrap(CmuxTaskManagerCodingAgentDefinition.matchingDefinition(
            processName: "grok-macos-aarch",
            processPath: "/Users/example/.grok/downloads/grok-macos-aarch64",
            arguments: ["/Users/example/.grok/downloads/grok-macos-aarch64"],
            environment: [:]
        ))

        XCTAssertEqual(definition.id, "grok")
    }

    func testAntigravityCodingAgentDefinitionUsesBrandedIconAsset() throws {
        let definition = try XCTUnwrap(CmuxTaskManagerCodingAgentDefinition.matchingDefinition(
            processName: "agy",
            processPath: "/Users/example/.local/bin/agy",
            arguments: ["/Users/example/.local/bin/agy", "--conversation", "conversation-123"],
            environment: [:]
        ))

        XCTAssertEqual(definition.id, "antigravity")
        XCTAssertEqual(definition.assetName, "AgentIcons/Antigravity")
    }


    func testAttributedPayloadProratesSharedResourceMeasurements() {
        let summary = resourceSummary()

        let payload = summary.attributedPayload(sharedAcross: 2)

        XCTAssertEqual(double(payload["cpu_percent"]), 21)
        XCTAssertEqual(int64(payload["memory_bytes"]), 1500)
        XCTAssertEqual(int64(payload["resident_bytes"]), 500)
        XCTAssertEqual(int64(payload["virtual_bytes"]), 1000)
        XCTAssertEqual(int(payload["process_count"]), 1)
        XCTAssertEqual(intArray(payload["pids"]), [101])
        XCTAssertEqual(intArray(payload["missing_pids"]), [202])
        XCTAssertEqual(intArray(payload["memory_source_fallback_pids"]), [303])
        XCTAssertEqual(int(payload["memory_source_fallback_count"]), 1)
        XCTAssertEqual(intArray(payload["resident_memory_source_fallback_pids"]), [404])
        XCTAssertEqual(int(payload["resident_memory_source_fallback_count"]), 1)
        XCTAssertEqual(intArray(payload["unavailable_memory_pids"]), [505])
        XCTAssertEqual(int(payload["unavailable_memory_count"]), 1)
        XCTAssertEqual(intArray(payload["unavailable_resident_memory_pids"]), [606])
        XCTAssertEqual(int(payload["unavailable_resident_memory_count"]), 1)
    }

    func testAttributedPayloadReturnsUnmodifiedPayloadForSingleOccurrence() {
        let payload = resourceSummary().attributedPayload(sharedAcross: 1)

        assertUnmodifiedAttributedPayload(payload)
    }

    func testAttributedPayloadReturnsUnmodifiedPayloadForZeroOccurrences() {
        let payload = resourceSummary().attributedPayload(sharedAcross: 0)

        assertUnmodifiedAttributedPayload(payload)
    }

    func testAttributedPayloadReturnsUnmodifiedPayloadForNegativeOccurrences() {
        let payload = resourceSummary().attributedPayload(sharedAcross: -1)

        assertUnmodifiedAttributedPayload(payload)
    }

    func testParsesTypedIntPIDArrayFromSummaryPayload() {
        let payload: [String: Any] = [
            "cpu_percent": 3.5,
            "memory_bytes": 8192,
            "resident_bytes": 4096,
            "process_count": 2,
            "pids": [101, 202],
        ]

        let resources = CmuxTaskManagerResources(payload)

        XCTAssertEqual(resources.memoryBytes, 8192)
        XCTAssertEqual(resources.residentBytes, 4096)
        XCTAssertEqual(resources.processIds, [101, 202])
    }

    func testResourceMemoryFallsBackToResidentBytesForLegacyPayloads() {
        let resources = CmuxTaskManagerResources([
            "cpu_percent": 3.5,
            "resident_bytes": 4096,
            "process_count": 2,
        ])

        XCTAssertEqual(resources.memoryBytes, 4096)
        XCTAssertEqual(resources.residentBytes, 4096)
    }

    func testParsesAnyPIDArrayFromPayload() {
        let payload: [String: Any] = [
            "cpu_percent": 3.5,
            "resident_bytes": 4096,
            "process_count": 2,
            "pids": [101 as Any, "202" as Any],
        ]

        let resources = CmuxTaskManagerResources(payload)

        XCTAssertEqual(resources.processIds, [101, 202])
    }

    func testSortOrderSortsSiblingRowsByCPUWhilePreservingHierarchy() {
        let rows = [
            taskManagerRow("window", level: 0, cpuPercent: 40),
            taskManagerRow("workspace-a", level: 1, cpuPercent: 10),
            taskManagerRow("surface-a", level: 2, cpuPercent: 8),
            taskManagerRow("process-low", level: 3, cpuPercent: 1),
            taskManagerRow("process-high", level: 3, cpuPercent: 7),
            taskManagerRow("workspace-b", level: 1, cpuPercent: 30),
        ]

        let sortedRows = CmuxTaskManagerSortOrder.defaultOrder.sortedRows(rows)

        XCTAssertEqual(
            sortedRows.map(\.id),
            ["window", "workspace-b", "workspace-a", "surface-a", "process-high", "process-low"]
        )
    }

    func testSortOrderUsesAscendingNameSortWhenNameColumnIsSelected() {
        let rows = [
            taskManagerRow("window", level: 0, title: "Window"),
            taskManagerRow("beta", level: 1, title: "Beta"),
            taskManagerRow("alpha", level: 1, title: "Alpha"),
        ]

        let sortedRows = CmuxTaskManagerSortOrder(
            column: .name,
            direction: .ascending
        ).sortedRows(rows)

        XCTAssertEqual(sortedRows.map(\.id), ["window", "alpha", "beta"])
    }

    func testSortOrderSortsMemoryAndProcessColumnsDescending() {
        let rows = [
            taskManagerRow("window", level: 0),
            taskManagerRow("small-many", level: 1, residentBytes: 4_000, memoryBytes: 1_000, processCount: 9),
            taskManagerRow("large-few", level: 1, residentBytes: 1_000, memoryBytes: 4_000, processCount: 2),
        ]

        let memorySortedRows = CmuxTaskManagerSortOrder(
            column: .memory,
            direction: .descending
        ).sortedRows(rows)
        let processSortedRows = CmuxTaskManagerSortOrder(
            column: .processes,
            direction: .descending
        ).sortedRows(rows)

        XCTAssertEqual(memorySortedRows.map(\.id), ["window", "large-few", "small-many"])
        XCTAssertEqual(processSortedRows.map(\.id), ["window", "small-many", "large-few"])
    }

    func testSortOrderTogglesCurrentColumnAndUsesMetricDefaultsForNewColumns() {
        let cpuDescending = CmuxTaskManagerSortOrder.defaultOrder
        let cpuAscending = cpuDescending.toggled(for: .cpu)
        let memoryDescending = cpuAscending.toggled(for: .memory)
        let nameAscending = memoryDescending.toggled(for: .name)

        XCTAssertEqual(cpuAscending, CmuxTaskManagerSortOrder(column: .cpu, direction: .ascending))
        XCTAssertEqual(memoryDescending, CmuxTaskManagerSortOrder(column: .memory, direction: .descending))
        XCTAssertEqual(nameAscending, CmuxTaskManagerSortOrder(column: .name, direction: .ascending))
    }

    func testSnapshotBuildsProgramAggregateRowsForRepeatedProcessNames() throws {
        let snapshot = CmuxTaskManagerSnapshot(
            rows: [
                taskManagerRow(
                    "node-101-a",
                    kind: .process,
                    level: 0,
                    title: "node",
                    cpuPercent: 2,
                    residentBytes: 100,
                    processCount: 1,
                    processId: 101
                ),
                taskManagerRow(
                    "node-101-b",
                    kind: .process,
                    level: 0,
                    title: "node",
                    cpuPercent: 2,
                    residentBytes: 100,
                    processCount: 1,
                    processId: 101
                ),
                taskManagerRow(
                    "node-202",
                    kind: .process,
                    level: 0,
                    title: "node",
                    cpuPercent: 3,
                    residentBytes: 200,
                    processCount: 1,
                    processId: 202
                ),
                taskManagerRow(
                    "zsh-303",
                    kind: .process,
                    level: 0,
                    title: "zsh",
                    cpuPercent: 7,
                    residentBytes: 400,
                    processCount: 1,
                    processId: 303
                ),
            ],
            total: .zero,
            sampledAt: nil
        )

        XCTAssertEqual(snapshot.aggregateRows.count, 1)
        let aggregateRow = try XCTUnwrap(snapshot.aggregateRows.first)
        XCTAssertEqual(aggregateRow.title, "node")
        XCTAssertEqual(aggregateRow.resources.cpuPercent, 5)
        XCTAssertEqual(aggregateRow.resources.residentBytes, 300)
        XCTAssertEqual(aggregateRow.resources.processCount, 2)
        XCTAssertEqual(aggregateRow.resources.processIds, [101, 202])
        XCTAssertEqual(aggregateRow.detail, "2 processes")
    }

    func testSnapshotParsesProgramTotalsFromTopPayloadWithoutProcessRows() throws {
        let snapshot = CmuxTaskManagerSnapshot(payload: [
            "sample": ["sampled_at": "2026-05-13T12:00:00Z"],
            "totals": [:],
            "program_totals": [
                [
                    "id": "node",
                    "name": "node",
                    "resources": [
                        "cpu_percent": 9.5,
                        "resident_bytes": 8192,
                        "process_count": 3,
                        "pids": [101, 202, 303],
                    ],
                ],
            ],
            "windows": [],
        ])

        XCTAssertTrue(snapshot.rows.isEmpty)
        XCTAssertEqual(snapshot.aggregateRows.count, 1)
        let aggregateRow = try XCTUnwrap(snapshot.aggregateRows.first)
        XCTAssertEqual(aggregateRow.id, "programAggregate:node")
        XCTAssertEqual(aggregateRow.title, "node")
        XCTAssertEqual(aggregateRow.resources.cpuPercent, 9.5)
        XCTAssertEqual(aggregateRow.resources.processIds, [101, 202, 303])
        XCTAssertEqual(aggregateRow.detail, "3 processes")
    }

    func testSnapshotParsesSingleProcessProgramTotalsFromTopPayload() throws {
        let snapshot = CmuxTaskManagerSnapshot(payload: [
            "sample": ["sampled_at": "2026-05-13T12:00:00Z"],
            "totals": [:],
            "program_totals": [
                [
                    "id": "claude",
                    "name": "claude",
                    "resources": [
                        "cpu_percent": 2.0,
                        "resident_bytes": 4096,
                        "process_count": 1,
                        "pids": [101],
                    ],
                ],
            ],
            "windows": [],
        ])

        XCTAssertEqual(snapshot.aggregateRows.count, 1)
        let aggregateRow = try XCTUnwrap(snapshot.aggregateRows.first)
        XCTAssertEqual(aggregateRow.title, "claude")
        XCTAssertEqual(aggregateRow.resources.processCount, 1)
        XCTAssertEqual(aggregateRow.resources.processIds, [101])
        XCTAssertEqual(aggregateRow.detail, "1 process")
    }

    func testSnapshotOnlyCountsAsLoadedAfterSamplingOrRowsArrive() {
        XCTAssertFalse(CmuxTaskManagerSnapshot.empty.hasLoadedResourceUsage)

        let sampledSnapshot = CmuxTaskManagerSnapshot(
            rows: [],
            total: .zero,
            sampledAt: Date(timeIntervalSince1970: 0)
        )

        XCTAssertTrue(sampledSnapshot.hasLoadedResourceUsage)
    }

    func testSnapshotParsesCodingAgentRowsFromTopPayload() throws {
        let snapshot = CmuxTaskManagerSnapshot(payload: [
            "sample": ["sampled_at": "2026-05-13T12:00:00Z"],
            "totals": [:],
            "coding_agents": [
                [
                    "id": "codex",
                    "display_name": "Codex",
                    "asset_name": "AgentIcons/Codex",
                    "resources": [
                        "cpu_percent": 12.5,
                        "resident_bytes": 4096,
                        "process_count": 2,
                        "pids": [101, 202],
                    ],
                ],
            ],
            "windows": [],
        ])

        XCTAssertEqual(snapshot.agentRows.count, 1)
        let agentRow = try XCTUnwrap(snapshot.agentRows.first)
        XCTAssertEqual(agentRow.id, "codingAgentAggregate:codex")
        XCTAssertEqual(agentRow.kind, .codingAgentAggregate)
        XCTAssertEqual(agentRow.title, "Codex")
        XCTAssertEqual(agentRow.agentAssetName, "AgentIcons/Codex")
        XCTAssertEqual(agentRow.resources.cpuPercent, 12.5)
        XCTAssertEqual(agentRow.resources.processIds, [101, 202])
        XCTAssertEqual(agentRow.detail, "2 processes")
    }

    func testSnapshotAnnotatesRestoredHierarchyRowsFromAgentProcessTotals() throws {
        let resources: [String: Any] = [
            "cpu_percent": 2.0,
            "resident_bytes": 512,
            "process_count": 1,
            "pids": [101],
        ]
        let snapshot = CmuxTaskManagerSnapshot(payload: [
            "sample": ["sampled_at": "2026-05-13T12:00:00Z"],
            "totals": resources,
            "coding_agents": [
                [
                    "id": "claude",
                    "display_name": "Claude Code",
                    "asset_name": "AgentIcons/Claude",
                    "resources": resources,
                ],
            ],
            "windows": [
                [
                    "id": "window-1",
                    "ref": "window:1",
                    "resources": resources,
                    "workspaces": [
                        [
                            "id": "7F587C98-0069-4605-B066-F6FB941D54B4",
                            "ref": "workspace:1",
                            "title": "* Explore meaning of life",
                            "resources": resources,
                            "panes": [
                                [
                                    "id": "pane-1",
                                    "ref": "pane:1",
                                    "resources": resources,
                                    "surfaces": [
                                        [
                                            "id": "38457A72-7D87-40FC-8ED5-899B59572FD0",
                                            "ref": "surface:1",
                                            "type": "terminal",
                                            "title": "* Explore meaning of life",
                                            "resources": resources,
                                        ],
                                    ],
                                ],
                            ],
                        ],
                    ],
                ],
            ],
        ])

        let workspaceRow = try XCTUnwrap(snapshot.rows.first { $0.kind == .workspace })
        let paneRow = try XCTUnwrap(snapshot.rows.first { $0.kind == .pane })
        let surfaceRow = try XCTUnwrap(snapshot.rows.first { $0.kind == .terminalSurface })
        let windowRow = try XCTUnwrap(snapshot.rows.first { $0.kind == .window })

        XCTAssertEqual(workspaceRow.agentAssetName, "AgentIcons/Claude")
        XCTAssertEqual(paneRow.agentAssetName, "AgentIcons/Claude")
        XCTAssertEqual(surfaceRow.agentAssetName, "AgentIcons/Claude")
        XCTAssertNil(windowRow.agentAssetName)
    }

    func testCodingAgentMatcherUsesSupportedAgentNamesAndLaunchMetadata() {
        XCTAssertEqual(
            CmuxTaskManagerCodingAgentDefinition.matchingDefinition(
                processName: "node",
                processPath: nil,
                arguments: ["node", "/usr/local/lib/node_modules/@anthropic-ai/claude-code/cli.js"],
                environment: [:]
            )?.id,
            "claude"
        )
        XCTAssertEqual(
            CmuxTaskManagerCodingAgentDefinition.matchingDefinition(
                processName: "acli",
                processPath: nil,
                arguments: ["acli", "rovodev", "run"],
                environment: [:]
            )?.id,
            "rovodev"
        )
        XCTAssertEqual(
            CmuxTaskManagerCodingAgentDefinition.matchingDefinition(
                processName: "claude_code",
                processPath: nil,
                arguments: [],
                environment: [:]
            )?.id,
            "claude"
        )
        XCTAssertTrue(CmuxTaskManagerCodingAgentDefinition.shouldReadArguments(
            processName: "2.1.140",
            processPath: "/Users/lawrence/.local/share/claude/versions/2.1.140"
        ))
        XCTAssertTrue(CmuxTaskManagerCodingAgentDefinition.shouldReadArguments(
            processName: "2.1.140",
            processPath: nil
        ))
        XCTAssertEqual(
            CmuxTaskManagerCodingAgentDefinition.matchingDefinition(
                processName: "2.1.140",
                processPath: "/Users/lawrence/.local/share/claude/versions/2.1.140",
                arguments: ["/Users/lawrence/.local/bin/claude", "--resume", "session-id"],
                environment: [:]
            )?.id,
            "claude"
        )
        XCTAssertEqual(
            CmuxTaskManagerCodingAgentDefinition.matchingDefinition(
                processName: "2.1.140",
                processPath: nil,
                arguments: ["/Users/lawrence/.local/bin/claude", "--resume", "session-id"],
                environment: [:]
            )?.id,
            "claude"
        )
        XCTAssertEqual(
            CmuxTaskManagerCodingAgentDefinition.matchingDefinition(
                processName: "2.1.140",
                processPath: "/Users/lawrence/.local/share/claude/versions/2.1.140",
                arguments: ["/Users/lawrence/.local/share/claude/versions/2.1.140", "--resume", "session-id"],
                environment: [:]
            )?.id,
            "claude"
        )
        XCTAssertNil(CmuxTaskManagerCodingAgentDefinition.matchingDefinition(
            processName: "2.1.140",
            processPath: nil,
            arguments: [],
            environment: [:]
        ))
        XCTAssertEqual(
            CmuxTaskManagerCodingAgentDefinition.matchingDefinition(
                processName: "node",
                processPath: nil,
                arguments: ["node", "agent.js"],
                environment: ["CMUX_AGENT_LAUNCH_KIND": "claudeTeams"]
            )?.id,
            "claude"
        )
        XCTAssertEqual(
            CmuxTaskManagerCodingAgentDefinition.matchingDefinition(
                processName: "bun",
                processPath: nil,
                arguments: ["bun", "opencode"],
                environment: ["CMUX_AGENT_LAUNCH_KIND": "omo"]
            )?.id,
            "opencode"
        )
        XCTAssertEqual(
            CmuxTaskManagerCodingAgentDefinition.matchingDefinition(
                processName: "omo",
                processPath: nil,
                arguments: [],
                environment: [:]
            )?.id,
            "opencode"
        )
        XCTAssertEqual(
            CmuxTaskManagerCodingAgentDefinition.matchingDefinition(
                processName: "node",
                processPath: nil,
                arguments: ["node", "agent.js"],
                environment: ["CMUX_AGENT_LAUNCH_KIND": "codex"]
            )?.id,
            "codex"
        )
        XCTAssertEqual(
            CmuxTaskManagerCodingAgentDefinition.matchingDefinition(
                processName: "node",
                processPath: nil,
                arguments: ["node", "agent.js"],
                environment: ["CMUX_AGENT_LAUNCH_KIND": "omx"]
            )?.id,
            "codex"
        )
        XCTAssertNil(CmuxTaskManagerCodingAgentDefinition.matchingDefinition(
            processName: "node",
            processPath: nil,
            arguments: ["node", "api/server.js"],
            environment: [:]
        ))
        XCTAssertNil(CmuxTaskManagerCodingAgentDefinition.matchingDefinition(
            processName: "node",
            processPath: nil,
            arguments: ["node", "/tmp/gemini-api-test/server.js"],
            environment: [:]
        ))
        XCTAssertNil(CmuxTaskManagerCodingAgentDefinition.matchingDefinition(
            processName: "node",
            processPath: nil,
            arguments: ["node", "/tmp/factory-reset-tool/index.js"],
            environment: [:]
        ))
        XCTAssertEqual(
            CmuxTaskManagerCodingAgentDefinition.matchingDefinition(
                processName: "node",
                processPath: nil,
                arguments: ["node", "/usr/local/lib/node_modules/@openai/codex/bin/codex.js"],
                environment: [:]
            )?.id,
            "codex"
        )
    }

    func testCodingAgentMatcherCoversSupportedAgentExecutableNames() {
        let cases: [(processName: String, expectedId: String)] = [
            ("claude_code", "claude"),
            ("codex", "codex"),
            ("opencode", "opencode"),
            ("pi", "pi"),
            ("pi-coding-agent", "pi"),
            ("amp", "amp"),
            ("cursor-agent", "cursor"),
            ("gemini", "gemini"),
            ("agy", "antigravity"),
            ("antigravity", "antigravity"),
            ("hermes", "hermes-agent"),
            ("hermes-agent", "hermes-agent"),
            ("copilot", "copilot"),
            ("codebuddy", "codebuddy"),
            ("droid", "factory"),
            ("factory", "factory"),
            ("qodercli", "qoder"),
        ]

        for testCase in cases {
            XCTAssertEqual(
                CmuxTaskManagerCodingAgentDefinition.matchingDefinition(
                    processName: testCase.processName,
                    processPath: nil,
                    arguments: [],
                    environment: [:]
                )?.id,
                testCase.expectedId,
                testCase.processName
            )
        }
    }

    private func resourceSummary() -> CmuxTopResourceSummary {
        var summary = CmuxTopResourceSummary()
        summary.cpuPercent = 42
        summary.memoryBytes = 3001
        summary.residentBytes = 1001
        summary.virtualBytes = 2001
        summary.processCount = 1
        summary.pids = [101]
        summary.missingPIDs = [202]
        summary.memorySourceFallbackPIDs = [303]
        summary.residentMemorySourceFallbackPIDs = [404]
        summary.unavailableMemoryPIDs = [505]
        summary.unavailableResidentMemoryPIDs = [606]
        return summary
    }

    private func taskManagerRow(
        _ id: String,
        kind: CmuxTaskManagerRow.Kind = .workspace,
        level: Int,
        title: String? = nil,
        cpuPercent: Double = 0,
        residentBytes: Int64 = 0,
        memoryBytes: Int64? = nil,
        processCount: Int = 0,
        processId: Int? = nil
    ) -> CmuxTaskManagerRow {
        let processIds = processId.map { [$0] } ?? []
        return CmuxTaskManagerRow(
            id: id,
            kind: kind,
            level: level,
            title: title ?? id,
            detail: "",
            resources: CmuxTaskManagerResources(
                cpuPercent: cpuPercent,
                residentBytes: residentBytes,
                memoryBytes: memoryBytes,
                processCount: processCount,
                processIds: processIds
            ),
            isDimmed: false,
            workspaceId: nil,
            surfaceId: nil,
            terminalSurfaceId: nil,
            processId: processId,
            rootProcessIds: processIds,
            foregroundProcessGroupIds: [],
            agentAssetName: nil
        )
    }

    private func assertUnmodifiedAttributedPayload(
        _ payload: [String: Any],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(double(payload["cpu_percent"]), 42, file: file, line: line)
        XCTAssertEqual(int64(payload["memory_bytes"]), 3001, file: file, line: line)
        XCTAssertEqual(int64(payload["resident_bytes"]), 1001, file: file, line: line)
        XCTAssertEqual(int64(payload["virtual_bytes"]), 2001, file: file, line: line)
        XCTAssertEqual(int(payload["process_count"]), 1, file: file, line: line)
        XCTAssertEqual(intArray(payload["pids"]), [101], file: file, line: line)
        XCTAssertEqual(intArray(payload["missing_pids"]), [202], file: file, line: line)
        XCTAssertEqual(intArray(payload["memory_source_fallback_pids"]), [303], file: file, line: line)
        XCTAssertEqual(int(payload["memory_source_fallback_count"]), 1, file: file, line: line)
        XCTAssertEqual(intArray(payload["resident_memory_source_fallback_pids"]), [404], file: file, line: line)
        XCTAssertEqual(int(payload["resident_memory_source_fallback_count"]), 1, file: file, line: line)
        XCTAssertEqual(intArray(payload["unavailable_memory_pids"]), [505], file: file, line: line)
        XCTAssertEqual(int(payload["unavailable_memory_count"]), 1, file: file, line: line)
        XCTAssertEqual(intArray(payload["unavailable_resident_memory_pids"]), [606], file: file, line: line)
        XCTAssertEqual(int(payload["unavailable_resident_memory_count"]), 1, file: file, line: line)
    }

    private func double(_ raw: Any?) -> Double {
        if let value = raw as? Double { return value }
        if let value = raw as? NSNumber { return value.doubleValue }
        return 0
    }

    private func int64(_ raw: Any?) -> Int64 {
        if let value = raw as? Int64 { return value }
        if let value = raw as? Int { return Int64(value) }
        if let value = raw as? NSNumber { return value.int64Value }
        return 0
    }

    private func int(_ raw: Any?) -> Int {
        if let value = raw as? Int { return value }
        if let value = raw as? NSNumber { return value.intValue }
        return 0
    }

    private func intArray(_ raw: Any?) -> [Int] {
        if let values = raw as? [Int] { return values }
        guard let values = raw as? [Any] else { return [] }
        return values.compactMap { raw in
            if let value = raw as? Int { return value }
            if let value = raw as? NSNumber { return value.intValue }
            if let value = raw as? String { return Int(value) }
            return nil
        }
    }
}
