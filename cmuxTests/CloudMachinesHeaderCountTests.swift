import AppKit
import CmuxCloud
import SwiftUI
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// The Cloud Machines header carries the plan's usage the way My Devices
/// carries its device count ("Cloud Machines 1/50"), replacing the separate
/// "1 of 50 machines" line under the Cloud toolbar.
@MainActor
@Suite("Cloud Machines header count")
struct CloudMachinesHeaderCountTests {
    private static let genericHelp = "Machines on your plan. Sleeping machines cost nothing."

    @Test("A capped plan shows used/limit in the My Devices count slot")
    func cappedPlanShowsUsedOverLimit() throws {
        let count = try #require(headerCount(CloudMachinesUsage(activeCount: 1, maxActiveVms: 50, isPaidPlan: false)))
        #expect(count.text == "1/50")
        #expect(count.accessibilityLabel == "1 of 50 machines")
        #expect(count.help == Self.genericHelp)
        #expect(!count.isWarning)
    }

    @Test("An uncapped plan shows only the number", arguments: [(3, "3 machines"), (1, "1 machine")])
    func uncappedPlanShowsTheNumber(activeCount: Int, spoken: String) throws {
        let count = try #require(headerCount(CloudMachinesUsage(activeCount: activeCount, maxActiveVms: nil, isPaidPlan: true)))
        #expect(count.text == String(activeCount))
        #expect(count.accessibilityLabel == spoken)
        #expect(!count.isWarning)
    }

    @Test("No count until the plan loads")
    func noCountBeforeThePlanLoads() {
        #expect(CloudTreeRowContentView.groupCount(for: .cloudMachinesSection(canCreateMachine: true)) == nil)
    }

    @Test("A free plan at its limit turns orange and names the upgrade", arguments: [
        (1, "Your plan includes 1 machine. Upgrade to create more."),
        (50, "Your plan includes 50 machines. Upgrade to create more."),
    ])
    func freePlanAtLimitWarns(limit: Int, help: String) throws {
        let count = try #require(headerCount(CloudMachinesUsage(activeCount: limit, maxActiveVms: limit, isPaidPlan: false)))
        #expect(count.text == "\(limit)/\(limit)")
        #expect(count.isWarning)
        #expect(count.help == help)
    }

    @Test("A paid plan at a ceiling warns without an upgrade prompt")
    func paidPlanAtLimitWarnsWithoutUpgrade() throws {
        let count = try #require(headerCount(CloudMachinesUsage(activeCount: 5, maxActiveVms: 5, isPaidPlan: true)))
        #expect(count.text == "5/5")
        #expect(count.isWarning)
        #expect(count.help == Self.genericHelp)
    }

    @Test("VoiceOver reads the header with its spelled-out usage")
    func headerCellSpeaksTheUsage() {
        let cell = CloudTreeCellView(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        let node = CloudTreeNode(
            id: "cloud-machines-section",
            kind: .cloudMachinesSection(
                canCreateMachine: true,
                usage: CloudMachinesUsage(activeCount: 1, maxActiveVms: 50, isPaidPlan: false)
            )
        )
        cell.configure(node: node, machineActions: machineActions(), nodeActions: nodeActions())
        #expect(cell.accessibilityLabel() == "Cloud Machines, 1 of 50 machines")
    }

    @Test("A usage change updates the existing header row without a rebuild")
    func usageChangeUpdatesTheHeaderInPlace() throws {
        let fixture = CloudSidebarOrderingFixture()
        defer { fixture.close() }
        var inputs = CloudTreeBuildInputs(
            machines: [], snapshot: fixture.snapshot(), source: .cloudWithDevicesSection,
            canCreateCloudMachine: true,
            cloudMachinesUsage: CloudMachinesUsage(activeCount: 1, maxActiveVms: 50, isPaidPlan: false)
        )
        fixture.coordinator.update(inputs: inputs)
        let outline = try #require(fixture.coordinator.outlineView)
        let header = try #require(outline.item(atRow: 0) as? CloudTreeNode)
        #expect(header.structureTag == "cloudMachinesSection")

        inputs.cloudMachinesUsage = CloudMachinesUsage(activeCount: 2, maxActiveVms: 50, isPaidPlan: false)
        fixture.coordinator.update(inputs: inputs)
        fixture.container.layoutSubtreeIfNeeded()

        #expect(outline.item(atRow: 0) as? CloudTreeNode === header, "The header keeps its identity")
        #expect(CloudTreeRowContentView.groupCount(for: header.kind)?.text == "2/50")
        let cell = try #require(outline.view(atColumn: 0, row: 0, makeIfNecessary: true) as? CloudTreeCellView)
        #expect(cell.accessibilityLabel() == "Cloud Machines, 2 of 50 machines")
    }

    @Test("The hover + never overlaps the header count")
    func hoverPlusLeavesRoomForTheCount() throws {
        let cell = CloudTreeCellView(frame: NSRect(x: 0, y: 0, width: 160, height: 24))
        let node = CloudTreeNode(
            id: "cloud-machines-section",
            kind: .cloudMachinesSection(
                canCreateMachine: true,
                usage: CloudMachinesUsage(activeCount: 50, maxActiveVms: 50, isPaidPlan: false)
            )
        )
        cell.configure(node: node, machineActions: machineActions(), nodeActions: nodeActions())
        cell.setHovered(true)
        cell.layoutSubtreeIfNeeded()
        let display = try #require(cell.subviews.first { $0 is CloudTreePassthroughHostingView })
        let buttons = try #require(cell.subviews.first { $0 is CloudTreeRowControlsHostingView })
        #expect(!buttons.isHidden)
        #expect(display.frame.maxX <= buttons.frame.minX, "Count area \(display.frame) runs under + \(buttons.frame)")
    }

    @Test("An empty status adds no row under the Cloud toolbar")
    func emptyStatusAddsNoGap() {
        let height = headerHeight { EmptyView() }
        #expect(abs(height - RightSidebarChromeMetrics.secondaryBarHeight) <= 0.5,
                "Header is \(height)pt; the toolbar alone is \(RightSidebarChromeMetrics.secondaryBarHeight)pt")
    }

    @Test("An idle fleet status adds no row under the Cloud toolbar")
    func idleFleetStatusAddsNoGap() {
        let height = headerHeight { fleetStatus() }
        #expect(abs(height - RightSidebarChromeMetrics.secondaryBarHeight) <= 0.5,
                "Header is \(height)pt; the toolbar alone is \(RightSidebarChromeMetrics.secondaryBarHeight)pt")
    }

    @Test("Operations, list status and tree errors keep their row", arguments: ["operation", "listStatus", "treeError"])
    func fleetStatusStillShows(message: String) {
        let height = headerHeight {
            fleetStatus(
                activeOperation: message == "operation" ? "Creating machine" : nil,
                listStatus: message == "listStatus" ? .reconnecting : nil,
                treeError: message == "treeError" ? "Cloud tree unavailable" : nil
            )
        }
        #expect(height >= RightSidebarChromeMetrics.secondaryBarHeight + 8,
                "The \(message) row is missing: header is \(height)pt")
    }

    private func fleetStatus(
        activeOperation: String? = nil, listStatus: MachineListStatus? = nil, treeError: String? = nil
    ) -> MachinesCloudStatus {
        MachinesCloudStatus(activeOperation: activeOperation, listStatus: listStatus, listError: nil,
                            treeError: treeError, onDismissStale: { _ in })
    }

    private func headerHeight<Status: View>(@ViewBuilder status: @escaping () -> Status) -> CGFloat {
        NSHostingView(rootView: CloudTeamPickerHeader(
            accountFlow: nil, presentation: nil, chromeBackgroundColor: .windowBackgroundColor,
            isRefreshing: false, onRefresh: {}, onNewMachine: {},
            agentMenu: { EmptyView() }, status: status
        )).fittingSize.height
    }

    private func headerCount(_ usage: CloudMachinesUsage) -> CloudTreeGroupCount? {
        CloudTreeRowContentView.groupCount(for: .cloudMachinesSection(canCreateMachine: true, usage: usage))
    }

    private func machineActions() -> MachineRowActions {
        MachineRowActions(openShell: { _ in }, openDesktop: { _ in }, runCommand: { _, _ in },
            confirmDelete: { _ in }, promptRename: { _, _ in }, resizeDisk: { _, _ in }, promptUpgrade: {})
    }

    private func nodeActions() -> CloudTreeNodeActions {
        CloudTreeNodeActions(project: { _, _, _ in }, projectRemoteView: { _, _, _, _ in },
            projectInLocalWorkspace: { _, _ in }, projectRemoteViewInLocalWorkspace: { _, _, _ in },
            newTerminal: { _, _ in }, openGroup: { _, _, _, _ in }, openGroupAsWorkspace: { _, _, _ in },
            newWorkspace: { _ in }, closeTerminal: { _ in }, closeWorkspace: { _, _ in }, renameWorkspace: { _, _ in },
            renameTerminal: { _, _ in }, selectLocalWorkspace: { _ in }, copyToPasteboard: { _ in }, copyPortLink: { _ in }, refresh: {})
    }
}
