import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
final class WorkspacePerformanceTests: XCTestCase {
    private struct BenchmarkThresholds {
        let workspaceCreationP95Ms: Double
        let bonsplitPopulationP95Ms: Double
        let sidebarRefreshP95Ms: Double
        let workspaceSwitchP95Ms: Double

        init(environment: [String: String] = ProcessInfo.processInfo.environment) {
            workspaceCreationP95Ms = Self.doubleValue(
                environment["CMUX_WORKSPACE_BENCHMARK_MAX_CREATION_P95_MS"],
                defaultValue: 75
            )
            bonsplitPopulationP95Ms = Self.doubleValue(
                environment["CMUX_WORKSPACE_BENCHMARK_MAX_POPULATION_P95_MS"],
                defaultValue: 50
            )
            sidebarRefreshP95Ms = Self.doubleValue(
                environment["CMUX_WORKSPACE_BENCHMARK_MAX_SIDEBAR_REFRESH_P95_MS"],
                defaultValue: 25
            )
            workspaceSwitchP95Ms = Self.doubleValue(
                environment["CMUX_WORKSPACE_BENCHMARK_MAX_SWITCH_P95_MS"],
                defaultValue: 25
            )
        }

        private static func doubleValue(_ rawValue: String?, defaultValue: Double) -> Double {
            guard let rawValue, let parsed = Double(rawValue) else { return defaultValue }
            return parsed
        }
    }

    private struct BenchmarkConfiguration {
        let workspaceCount: Int
        let tabsPerWorkspace: Int
        let switchPasses: Int

        init(environment: [String: String] = ProcessInfo.processInfo.environment) {
            workspaceCount = Self.intValue(
                environment["CMUX_WORKSPACE_BENCHMARK_WORKSPACES"],
                defaultValue: 60,
                minimum: 2
            )
            tabsPerWorkspace = Self.intValue(
                environment["CMUX_WORKSPACE_BENCHMARK_TABS_PER_WORKSPACE"],
                defaultValue: 20,
                minimum: 1
            )
            switchPasses = Self.intValue(
                environment["CMUX_WORKSPACE_BENCHMARK_SWITCH_PASSES"],
                defaultValue: 6,
                minimum: 1
            )
        }

        private static func intValue(_ rawValue: String?, defaultValue: Int, minimum: Int) -> Int {
            guard let rawValue, let parsed = Int(rawValue) else { return defaultValue }
            return max(minimum, parsed)
        }
    }

    private struct BenchmarkStats {
        let count: Int
        let meanMs: Double
        let p50Ms: Double
        let p95Ms: Double
        let maxMs: Double

        init(samples: [Double]) {
            count = samples.count
            let sorted = samples.sorted()
            meanMs = sorted.isEmpty ? 0 : sorted.reduce(0, +) / Double(sorted.count)
            p50Ms = Self.percentile(0.50, in: sorted)
            p95Ms = Self.percentile(0.95, in: sorted)
            maxMs = sorted.last ?? 0
        }

        private static func percentile(_ percentile: Double, in sorted: [Double]) -> Double {
            guard !sorted.isEmpty else { return 0 }
            let index = Int((Double(sorted.count - 1) * percentile).rounded())
            return sorted[max(0, min(index, sorted.count - 1))]
        }

        var summary: String {
            String(
                format: "count=%d mean=%.2fms p50=%.2fms p95=%.2fms max=%.2fms",
                count,
                meanMs,
                p50Ms,
                p95Ms,
                maxMs
            )
        }
    }

    private struct WorkspaceBenchmarkResult {
        let workspaceCount: Int
        let tabsPerWorkspace: Int
        let switchIterations: Int
        let workspaceCreation: BenchmarkStats
        let bonsplitPopulation: BenchmarkStats
        let sidebarRefresh: BenchmarkStats
        let workspaceSwitchEndToEnd: BenchmarkStats
        let sidebarDigest: Int

        var summary: String {
            [
                "workspaceCount=\(workspaceCount)",
                "tabsPerWorkspace=\(tabsPerWorkspace)",
                "switchIterations=\(switchIterations)",
                "workspaceCreation \(workspaceCreation.summary)",
                "bonsplitPopulation \(bonsplitPopulation.summary)",
                "sidebarRefresh \(sidebarRefresh.summary)",
                "workspaceSwitchEndToEnd \(workspaceSwitchEndToEnd.summary)",
                "sidebarDigest=\(sidebarDigest)",
            ].joined(separator: "\n")
        }
    }

    private func elapsedMs(_ operation: () -> Void) -> Double {
        let start = DispatchTime.now().uptimeNanoseconds
        operation()
        let elapsed = DispatchTime.now().uptimeNanoseconds - start
        return Double(elapsed) / 1_000_000
    }

    private func drainMainQueue() {
        let drained = expectation(description: "main queue drained")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: 1.0)
    }

    private func populateWorkspaceSidebarMetadata(_ workspace: Workspace, workspaceIndex: Int) {
        let orderedPanelIds = workspace.sidebarOrderedPanelIds()
        for (panelIndex, panelId) in orderedPanelIds.enumerated() {
            workspace.panelDirectories[panelId] = "/tmp/ws-\(workspaceIndex)/pane-\(panelIndex)"
            workspace.panelGitBranches[panelId] = SidebarGitBranchState(
                branch: "branch-\(workspaceIndex % 7)-\(panelIndex % 5)",
                isDirty: (panelIndex % 3) == 0
            )
        }
    }

    @discardableResult
    private func materializeSidebarSnapshots(for workspaces: [Workspace]) -> Int {
        var digest = 0
        for workspace in workspaces {
            let orderedPanelIds = workspace.sidebarOrderedPanelIds()
            digest &+= orderedPanelIds.count
            digest &+= workspace.sidebarGitBranchesInDisplayOrder(orderedPanelIds: orderedPanelIds).count
            digest &+= workspace.sidebarBranchDirectoryEntriesInDisplayOrder(orderedPanelIds: orderedPanelIds).count
        }
        return digest
    }

    private func benchmarkWorkspaceCreationAndSwitching(
        configuration: BenchmarkConfiguration = BenchmarkConfiguration()
    ) -> WorkspaceBenchmarkResult {
        let workspaceCount = configuration.workspaceCount
        let tabsPerWorkspace = configuration.tabsPerWorkspace
        let switchPasses = configuration.switchPasses
        XCTAssertGreaterThanOrEqual(workspaceCount, 2)
        XCTAssertGreaterThanOrEqual(tabsPerWorkspace, 1)
        XCTAssertGreaterThanOrEqual(switchPasses, 1)

        let defaults = UserDefaults.standard
        let welcomeShown = defaults.object(forKey: WelcomeSettings.shownKey)
        defaults.set(true, forKey: WelcomeSettings.shownKey)
        defer {
            if let welcomeShown {
                defaults.set(welcomeShown, forKey: WelcomeSettings.shownKey)
            } else {
                defaults.removeObject(forKey: WelcomeSettings.shownKey)
            }
        }

        let manager = TabManager()
        guard let initialWorkspace = manager.selectedWorkspace else {
            XCTFail("Expected TabManager to create an initial workspace")
            return WorkspaceBenchmarkResult(
                workspaceCount: workspaceCount,
                tabsPerWorkspace: tabsPerWorkspace,
                switchIterations: 0,
                workspaceCreation: BenchmarkStats(samples: []),
                bonsplitPopulation: BenchmarkStats(samples: []),
                sidebarRefresh: BenchmarkStats(samples: []),
                workspaceSwitchEndToEnd: BenchmarkStats(samples: []),
                sidebarDigest: 0
            )
        }

        var workspaces: [Workspace] = [initialWorkspace]
        var creationSamples: [Double] = []
        creationSamples.reserveCapacity(max(0, workspaceCount - 1))
        populateWorkspaceSidebarMetadata(initialWorkspace, workspaceIndex: 0)

        for workspaceIndex in 1..<workspaceCount {
            var createdWorkspace: Workspace?
            let elapsed = elapsedMs {
                createdWorkspace = manager.addWorkspace(select: true, autoWelcomeIfNeeded: false)
                if let createdWorkspace {
                    populateWorkspaceSidebarMetadata(createdWorkspace, workspaceIndex: workspaceIndex)
                }
                drainMainQueue()
                _ = materializeSidebarSnapshots(for: workspaces + (createdWorkspace.map { [$0] } ?? []))
            }
            guard let createdWorkspace else {
                XCTFail("Expected addWorkspace to return a workspace")
                continue
            }
            workspaces.append(createdWorkspace)
            creationSamples.append(elapsed)
        }

        XCTAssertEqual(manager.tabs.count, workspaceCount)

        var bonsplitPopulationSamples: [Double] = []
        bonsplitPopulationSamples.reserveCapacity(workspaces.count)

        for workspace in workspaces {
            let elapsed = elapsedMs {
                for _ in 1..<tabsPerWorkspace {
                    let createdPanel = workspace.newTerminalSurfaceInFocusedPane(focus: false)
                    XCTAssertNotNil(createdPanel)
                }
            }
            bonsplitPopulationSamples.append(elapsed)
        }

        XCTAssertTrue(workspaces.allSatisfy { $0.panels.count == tabsPerWorkspace })

        for (workspaceIndex, workspace) in workspaces.enumerated() {
            populateWorkspaceSidebarMetadata(workspace, workspaceIndex: workspaceIndex)
        }

        manager.selectWorkspace(initialWorkspace)
        drainMainQueue()

        let expectedSwitchIterations = (workspaceCount * switchPasses) - 1
        var sidebarRefreshSamples: [Double] = []
        sidebarRefreshSamples.reserveCapacity(max(0, expectedSwitchIterations))
        var endToEndSwitchSamples: [Double] = []
        endToEndSwitchSamples.reserveCapacity(max(0, expectedSwitchIterations))
        var sidebarDigest = materializeSidebarSnapshots(for: workspaces)

        for _ in 0..<switchPasses {
            for index in 0..<workspaces.count {
                if index == 0, endToEndSwitchSamples.isEmpty {
                    continue
                }
                let elapsed = elapsedMs {
                    manager.selectNextTab()
                    drainMainQueue()
                    sidebarDigest = materializeSidebarSnapshots(for: workspaces)
                }
                endToEndSwitchSamples.append(elapsed)

                let sidebarElapsed = elapsedMs {
                    sidebarDigest = materializeSidebarSnapshots(for: workspaces)
                }
                sidebarRefreshSamples.append(sidebarElapsed)
            }
        }

        XCTAssertEqual(endToEndSwitchSamples.count, expectedSwitchIterations)
        XCTAssertEqual(sidebarRefreshSamples.count, expectedSwitchIterations)
        XCTAssertGreaterThan(sidebarDigest, 0)

        return WorkspaceBenchmarkResult(
            workspaceCount: workspaceCount,
            tabsPerWorkspace: tabsPerWorkspace,
            switchIterations: endToEndSwitchSamples.count,
            workspaceCreation: BenchmarkStats(samples: creationSamples),
            bonsplitPopulation: BenchmarkStats(samples: bonsplitPopulationSamples),
            sidebarRefresh: BenchmarkStats(samples: sidebarRefreshSamples),
            workspaceSwitchEndToEnd: BenchmarkStats(samples: endToEndSwitchSamples),
            sidebarDigest: sidebarDigest
        )
    }

    func testWorkspaceCreationAndFastSwitchingBenchmark() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["CMUX_RUN_WORKSPACE_BENCHMARK"] == "1",
            "Set CMUX_RUN_WORKSPACE_BENCHMARK=1 to run the dense workspace benchmark."
        )

        let result = benchmarkWorkspaceCreationAndSwitching()
        let thresholds = BenchmarkThresholds()
        print("WORKSPACE_BENCHMARK\n\(result.summary)")

        XCTContext.runActivity(named: "Workspace benchmark summary") { activity in
            activity.add(XCTAttachment(string: result.summary))
        }

        XCTAssertLessThan(
            result.workspaceCreation.p95Ms,
            thresholds.workspaceCreationP95Ms,
            "Workspace creation p95 should stay below the interactive lag threshold.\n\(result.summary)"
        )
        XCTAssertLessThan(
            result.bonsplitPopulation.p95Ms,
            thresholds.bonsplitPopulationP95Ms,
            "Per-workspace Bonsplit tab population p95 should stay bounded.\n\(result.summary)"
        )
        XCTAssertLessThan(
            result.sidebarRefresh.p95Ms,
            thresholds.sidebarRefreshP95Ms,
            "Sidebar refresh p95 should stay bounded during dense workspace switching.\n\(result.summary)"
        )
        XCTAssertLessThan(
            result.workspaceSwitchEndToEnd.p95Ms,
            thresholds.workspaceSwitchP95Ms,
            "Workspace switching p95 should stay below a frame budget.\n\(result.summary)"
        )
    }
}
