import XCTest
import struct CmuxSettings.AccountCatalogSection

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
final class WorkspaceStressProfileTests: XCTestCase {
    private struct StressConfig {
        let workspaceCount: Int
        let tabsPerWorkspace: Int
        let switchPasses: Int
        let createP95BudgetMs: Double?
        let switchP95BudgetMs: Double?

        static func current(environment: [String: String] = ProcessInfo.processInfo.environment) -> StressConfig {
            StressConfig(
                workspaceCount: parseInt(environment["CMUX_WORKSPACE_STRESS_WORKSPACES"], default: 48, minimum: 2),
                tabsPerWorkspace: parseInt(environment["CMUX_WORKSPACE_STRESS_TABS_PER_WORKSPACE"], default: 10, minimum: 1),
                switchPasses: parseInt(environment["CMUX_WORKSPACE_STRESS_SWITCH_PASSES"], default: 6, minimum: 1),
                createP95BudgetMs: parseDouble(environment["CMUX_WORKSPACE_STRESS_CREATE_P95_BUDGET_MS"]),
                switchP95BudgetMs: parseDouble(environment["CMUX_WORKSPACE_STRESS_SWITCH_P95_BUDGET_MS"])
            )
        }

        private static func parseInt(_ value: String?, default defaultValue: Int, minimum: Int) -> Int {
            guard let value, let parsed = Int(value) else { return defaultValue }
            return max(minimum, parsed)
        }

        private static func parseDouble(_ value: String?) -> Double? {
            guard let value, let parsed = Double(value) else { return nil }
            return parsed
        }
    }

    private struct TimedSample {
        let label: String
        let elapsedMs: Double
    }

    private struct TimingSummary {
        let count: Int
        let averageMs: Double
        let medianMs: Double
        let p95Ms: Double
        let maxMs: Double
        let totalMs: Double

        init(samples: [TimedSample]) {
            let sorted = samples.map(\.elapsedMs).sorted()
            count = sorted.count
            totalMs = sorted.reduce(0, +)
            averageMs = count > 0 ? totalMs / Double(count) : 0
            medianMs = Self.percentile(0.50, in: sorted)
            p95Ms = Self.percentile(0.95, in: sorted)
            maxMs = sorted.last ?? 0
        }

        private static func percentile(_ percentile: Double, in sortedValues: [Double]) -> Double {
            guard !sortedValues.isEmpty else { return 0 }
            let clamped = min(max(percentile, 0), 1)
            let index = Int((Double(sortedValues.count - 1) * clamped).rounded(.up))
            return sortedValues[min(sortedValues.count - 1, max(0, index))]
        }
    }

    func testWorkspaceCreationAndSwitchingStressProfile() {
        let config = StressConfig.current()
        let welcomeShownKey = AccountCatalogSection().welcomeShown.userDefaultsKey
        let welcomeWasShown = UserDefaults.standard.object(forKey: welcomeShownKey)
        UserDefaults.standard.set(true, forKey: welcomeShownKey)
        defer {
            if let welcomeWasShown {
                UserDefaults.standard.set(welcomeWasShown, forKey: welcomeShownKey)
            } else {
                UserDefaults.standard.removeObject(forKey: welcomeShownKey)
            }
        }

        var creationSamples: [TimedSample] = []
        var populationSamples: [TimedSample] = []
        var switchSamples: [TimedSample] = []
        var switchDispatchSamples: [TimedSample] = []
        var switchFirstDrainSamples: [TimedSample] = []
        var switchUnfocusSamples: [TimedSample] = []
        var switchSecondDrainSamples: [TimedSample] = []

        let manager = timed("workspace-000-create", collectInto: &creationSamples) {
            TabManager()
        }

        guard let bootstrapWorkspace = manager.selectedWorkspace else {
            XCTFail("Expected bootstrap workspace")
            return
        }

        timed("workspace-000-populate", collectInto: &populationSamples) {
            populate(workspace: bootstrapWorkspace, tabsPerWorkspace: config.tabsPerWorkspace)
        }
        settleWorkspaceSelection(manager)

        for workspaceIndex in 1..<config.workspaceCount {
            let workspace = timed("workspace-\(label(for: workspaceIndex))-create", collectInto: &creationSamples) {
                manager.addWorkspace(
                    select: true,
                    eagerLoadTerminal: false,
                    autoWelcomeIfNeeded: false
                )
            }

            settleWorkspaceSelection(manager)

            timed("workspace-\(label(for: workspaceIndex))-populate", collectInto: &populationSamples) {
                populate(workspace: workspace, tabsPerWorkspace: config.tabsPerWorkspace)
            }
            settleWorkspaceSelection(manager)
        }

        XCTAssertEqual(manager.tabs.count, config.workspaceCount)
        XCTAssertTrue(manager.tabs.allSatisfy { $0.panels.count == config.tabsPerWorkspace })

        for pass in 0..<config.switchPasses {
            for switchIndex in 0..<manager.tabs.count {
                timed("pass-\(label(for: pass))-next-\(label(for: switchIndex))", collectInto: &switchSamples) {
                    timed("pass-\(label(for: pass))-next-dispatch-\(label(for: switchIndex))", collectInto: &switchDispatchSamples) {
                        manager.selectNextTab()
                    }
                    timed("pass-\(label(for: pass))-next-drain1-\(label(for: switchIndex))", collectInto: &switchFirstDrainSamples) {
                        drainMainQueue()
                    }
                    timed("pass-\(label(for: pass))-next-unfocus-\(label(for: switchIndex))", collectInto: &switchUnfocusSamples) {
                        manager.completePendingWorkspaceUnfocus(reason: "workspace_stress_profile")
                    }
                    timed("pass-\(label(for: pass))-next-drain2-\(label(for: switchIndex))", collectInto: &switchSecondDrainSamples) {
                        drainMainQueue()
                    }
                }
            }

            for switchIndex in 0..<manager.tabs.count {
                timed("pass-\(label(for: pass))-prev-\(label(for: switchIndex))", collectInto: &switchSamples) {
                    timed("pass-\(label(for: pass))-prev-dispatch-\(label(for: switchIndex))", collectInto: &switchDispatchSamples) {
                        manager.selectPreviousTab()
                    }
                    timed("pass-\(label(for: pass))-prev-drain1-\(label(for: switchIndex))", collectInto: &switchFirstDrainSamples) {
                        drainMainQueue()
                    }
                    timed("pass-\(label(for: pass))-prev-unfocus-\(label(for: switchIndex))", collectInto: &switchUnfocusSamples) {
                        manager.completePendingWorkspaceUnfocus(reason: "workspace_stress_profile")
                    }
                    timed("pass-\(label(for: pass))-prev-drain2-\(label(for: switchIndex))", collectInto: &switchSecondDrainSamples) {
                        drainMainQueue()
                    }
                }
            }
        }

        XCTAssertNotNil(manager.selectedWorkspace)

        let creationSummary = TimingSummary(samples: creationSamples)
        let populationSummary = TimingSummary(samples: populationSamples)
        let switchSummary = TimingSummary(samples: switchSamples)
        let switchDispatchSummary = TimingSummary(samples: switchDispatchSamples)
        let switchFirstDrainSummary = TimingSummary(samples: switchFirstDrainSamples)
        let switchUnfocusSummary = TimingSummary(samples: switchUnfocusSamples)
        let switchSecondDrainSummary = TimingSummary(samples: switchSecondDrainSamples)

        let report = [
            "Workspace stress config workspaces=\(config.workspaceCount) tabsPerWorkspace=\(config.tabsPerWorkspace) switchPasses=\(config.switchPasses)",
            reportLine(title: "create", summary: creationSummary, slowest: slowest(creationSamples)),
            reportLine(title: "populate", summary: populationSummary, slowest: slowest(populationSamples)),
            reportLine(title: "switch", summary: switchSummary, slowest: slowest(switchSamples)),
            reportLine(title: "switch.dispatch", summary: switchDispatchSummary, slowest: slowest(switchDispatchSamples)),
            reportLine(title: "switch.drain1", summary: switchFirstDrainSummary, slowest: slowest(switchFirstDrainSamples)),
            reportLine(title: "switch.unfocus", summary: switchUnfocusSummary, slowest: slowest(switchUnfocusSamples)),
            reportLine(title: "switch.drain2", summary: switchSecondDrainSummary, slowest: slowest(switchSecondDrainSamples))
        ].joined(separator: "\n")

        print(report)
        let attachment = XCTAttachment(string: report)
        attachment.name = "workspace-stress-profile"
        attachment.lifetime = .keepAlways
        add(attachment)

        if let createP95BudgetMs = config.createP95BudgetMs {
            XCTAssertLessThanOrEqual(
                creationSummary.p95Ms,
                createP95BudgetMs,
                "Workspace creation p95 exceeded budget"
            )
        }
        if let switchP95BudgetMs = config.switchP95BudgetMs {
            XCTAssertLessThanOrEqual(
                switchSummary.p95Ms,
                switchP95BudgetMs,
                "Workspace switch p95 exceeded budget"
            )
        }
    }

    func testWorkspaceBatchActionsStressProfile() {
        let config = StressConfig.current()
        let welcomeShownKey = AccountCatalogSection().welcomeShown.userDefaultsKey
        let welcomeWasShown = UserDefaults.standard.object(forKey: welcomeShownKey)
        UserDefaults.standard.set(true, forKey: welcomeShownKey)
        defer {
            if let welcomeWasShown {
                UserDefaults.standard.set(welcomeWasShown, forKey: welcomeShownKey)
            } else {
                UserDefaults.standard.removeObject(forKey: welcomeShownKey)
            }
        }

        let manager = TabManager(autoWelcomeIfNeeded: false)
        for workspaceIndex in 1..<config.workspaceCount {
            _ = manager.addWorkspace(
                title: "Workspace \(label(for: workspaceIndex))",
                select: false,
                eagerLoadTerminal: false,
                autoWelcomeIfNeeded: false
            )
        }

        let workspaceIds = manager.tabs.map(\.id)
        let anchorWorkspaceId = workspaceIds[0]
        var colorSamples: [TimedSample] = []
        var scrollBarSamples: [TimedSample] = []
        var pinSamples: [TimedSample] = []
        var unpinSamples: [TimedSample] = []

        for pass in 0..<config.switchPasses {
            timed("pass-\(label(for: pass))-color-apply", collectInto: &colorSamples) {
                manager.applyWorkspaceColor("#1565C0", toWorkspaceIds: workspaceIds)
            }
            XCTAssertTrue(manager.tabs.allSatisfy { $0.customColor == "#1565C0" })
            timed("pass-\(label(for: pass))-color-clear", collectInto: &colorSamples) {
                manager.applyWorkspaceColor(nil, toWorkspaceIds: workspaceIds)
            }
            XCTAssertTrue(manager.tabs.allSatisfy { $0.customColor == nil })
            timed("pass-\(label(for: pass))-scrollbar-hide", collectInto: &scrollBarSamples) {
                manager.setWorkspaceTerminalScrollBarHidden(hidden: true, forWorkspaceIds: workspaceIds)
            }
            XCTAssertTrue(manager.tabs.allSatisfy { $0.terminalScrollBarHidden })
            timed("pass-\(label(for: pass))-scrollbar-show", collectInto: &scrollBarSamples) {
                manager.setWorkspaceTerminalScrollBarHidden(hidden: false, forWorkspaceIds: workspaceIds)
            }
            XCTAssertTrue(manager.tabs.allSatisfy { !$0.terminalScrollBarHidden })
            let pinResult = timed("pass-\(label(for: pass))-pin", collectInto: &pinSamples) {
                WorkspaceActionDispatcher.performPinAction(
                    WorkspaceActionDispatcher.PinState(
                        targetWorkspaceIds: workspaceIds,
                        anchorWorkspaceId: anchorWorkspaceId,
                        pinned: true
                    ),
                    in: manager
                )
            }
            XCTAssertFalse(pinResult.changedWorkspaceIds.isEmpty)
            XCTAssertTrue(manager.tabs.allSatisfy { $0.isPinned })
            let unpinResult = timed("pass-\(label(for: pass))-unpin", collectInto: &unpinSamples) {
                WorkspaceActionDispatcher.performPinAction(
                    WorkspaceActionDispatcher.PinState(
                        targetWorkspaceIds: workspaceIds,
                        anchorWorkspaceId: anchorWorkspaceId,
                        pinned: false
                    ),
                    in: manager
                )
            }
            XCTAssertFalse(unpinResult.changedWorkspaceIds.isEmpty)
            XCTAssertTrue(manager.tabs.allSatisfy { !$0.isPinned })
        }

        XCTAssertEqual(manager.tabs.count, config.workspaceCount)
        XCTAssertTrue(manager.tabs.allSatisfy { !$0.isPinned })
        XCTAssertTrue(manager.tabs.allSatisfy { $0.customColor == nil })
        XCTAssertTrue(manager.tabs.allSatisfy { !$0.terminalScrollBarHidden })

        let report = [
            "Workspace batch action stress config workspaces=\(config.workspaceCount) passes=\(config.switchPasses)",
            reportLine(title: "color", summary: TimingSummary(samples: colorSamples), slowest: slowest(colorSamples)),
            reportLine(title: "scrollbar", summary: TimingSummary(samples: scrollBarSamples), slowest: slowest(scrollBarSamples)),
            reportLine(title: "pin", summary: TimingSummary(samples: pinSamples), slowest: slowest(pinSamples)),
            reportLine(title: "unpin", summary: TimingSummary(samples: unpinSamples), slowest: slowest(unpinSamples))
        ].joined(separator: "\n")

        print(report)
        let attachment = XCTAttachment(string: report)
        attachment.name = "workspace-batch-actions-stress-profile"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func populate(workspace: Workspace, tabsPerWorkspace: Int) {
        guard tabsPerWorkspace > 0 else { return }
        while workspace.panels.count < tabsPerWorkspace {
            let created = workspace.newTerminalSurfaceInFocusedPane(focus: false)
            guard created != nil else {
                XCTFail("Expected terminal tab creation to succeed")
                return
            }
        }
    }

    private func settleWorkspaceSelection(_ manager: TabManager) {
        drainMainQueue()
        manager.completePendingWorkspaceUnfocus(reason: "workspace_stress_profile")
        drainMainQueue()
    }

    private func drainMainQueue() {
        let deadline = Date(timeIntervalSinceNow: 1.0)
        var drained = false
        DispatchQueue.main.async {
            drained = true
        }
        while !drained {
            if Date() >= deadline {
                XCTFail("Timed out draining main queue")
                return
            }
            let sliceDeadline = min(deadline, Date(timeIntervalSinceNow: 0.001))
            _ = RunLoop.main.run(mode: .default, before: sliceDeadline)
        }
    }

    @discardableResult
    private func timed<T>(
        _ label: String,
        collectInto samples: inout [TimedSample],
        operation: () -> T
    ) -> T {
        let startedAt = ProcessInfo.processInfo.systemUptime
        let value = operation()
        let elapsedMs = (ProcessInfo.processInfo.systemUptime - startedAt) * 1000.0
        samples.append(TimedSample(label: label, elapsedMs: elapsedMs))
        return value
    }

    private func slowest(_ samples: [TimedSample], count: Int = 5) -> String {
        samples
            .sorted { lhs, rhs in
                if lhs.elapsedMs == rhs.elapsedMs {
                    return lhs.label < rhs.label
                }
                return lhs.elapsedMs > rhs.elapsedMs
            }
            .prefix(count)
            .map { "\($0.label)=\(formatMs($0.elapsedMs))" }
            .joined(separator: ", ")
    }

    private func reportLine(title: String, summary: TimingSummary, slowest: String) -> String {
        [
            "\(title):",
            "count=\(summary.count)",
            "avg=\(formatMs(summary.averageMs))",
            "median=\(formatMs(summary.medianMs))",
            "p95=\(formatMs(summary.p95Ms))",
            "max=\(formatMs(summary.maxMs))",
            "total=\(formatMs(summary.totalMs))",
            "slowest=[\(slowest)]"
        ].joined(separator: " ")
    }

    private func formatMs(_ value: Double) -> String {
        String(format: "%.2fms", value)
    }

    private func label(for index: Int) -> String {
        String(format: "%03d", index)
    }
}
