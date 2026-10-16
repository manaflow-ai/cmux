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

    // The header still measures both team-name layout candidates. Measuring
    // their ideal widths needs no accessibility client, unlike reading the
    // SwiftUI tree.
    @Test("Narrow Cloud headers move machine actions into one overflow menu")
    func narrowHeaderCollapsesMachineActions() async throws {
        let inline = try await idealRowWidth(.inline, teamName: Self.longTeamName)
        #expect(inline > Self.barContentWidth(220),
                "The inline row (\(inline)pt) fits a 220pt sidebar, so the overflow menu never shows")
    }

    @Test("A wide Cloud header keeps its action row stable")
    func wideHeaderKeepsActionRowStable() async throws {
        let inline = try await idealRowWidth(.inline, teamName: "Team A")
        #expect(inline <= Self.barContentWidth(420),
                "The header action row (\(inline)pt) overflows a 420pt sidebar")
        let overflow = try await idealRowWidth(.overflowMenu, teamName: "Team A")
        #expect(overflow <= inline,
                "The overflow menu should be no wider than the inline action row")
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

    @Test("A confirmed delete takes its machine out of the count before the next list read")
    func deletedMachinesLeaveTheCount() throws {
        let fleet = ["a", "b", "c", "d"].map {
            MachineSnapshot(id: $0, provider: "freestyle", image: "base", isDesktop: false, activity: .ready)
        }
        let usage = CloudMachinesUsage(activeCount: fleet.count, maxActiveVms: 50, isPaidPlan: false)
        let visible = try #require(MachinesPanelViewModel.usage(usage, machines: fleet, hiding: ["d"]))
        #expect(visible.compactCount == "3/50")
        #expect(visible.countLabel == "3 of 50 machines")

        // A free plan's only machine: no orange "1/1" beside "No machines yet".
        let freeUsage = CloudMachinesUsage(activeCount: 1, maxActiveVms: 1, isPaidPlan: false)
        let empty = try #require(MachinesPanelViewModel.usage(freeUsage, machines: [fleet[0]], hiding: ["a"]))
        #expect(empty.compactCount == "0/1")
        #expect(!empty.isAtLimit)

        // Only hidden machines the list still counts come off.
        #expect(MachinesPanelViewModel.usage(usage, machines: fleet, hiding: ["gone"]) == usage)
        #expect(MachinesPanelViewModel.usage(nil, machines: fleet, hiding: ["d"]) == nil)
    }

    @Test("A scope-checked sheet-cache usage keeps the header visible during a list refresh")
    func cachedUsageFillsTheListReadGap() throws {
        let machines = [MachineSnapshot(id: "a", provider: "freestyle", image: "base", isDesktop: false, activity: .ready)]
        let cached = CloudMachinesUsage(activeCount: 1, maxActiveVms: 5, isPaidPlan: false)
        let visible = try #require(MachinesPanelViewModel.usage(
            nil, fallback: cached, machines: machines, hiding: []
        ))
        #expect(visible.compactCount == "1/5")

        let current = CloudMachinesUsage(activeCount: 0, maxActiveVms: 5, isPaidPlan: false)
        #expect(MachinesPanelViewModel.usage(
            current, fallback: cached, machines: machines, hiding: []
        ) == current)
    }

    @Test("VoiceOver reads the header with its spelled-out usage")
    func headerCellSpeaksTheUsage() {
        let cell = headerCell(usage: CloudMachinesUsage(activeCount: 1, maxActiveVms: 50, isPaidPlan: false))
        #expect(cell.accessibilityLabel() == "Cloud Machines, 1 of 50 machines")
    }

    @Test("Hovering the header shows the plan's help", arguments: [
        (1, "Machines on your plan. Sleeping machines cost nothing."),
        (50, "Your plan includes 50 machines. Upgrade to create more."),
    ])
    func headerRowCarriesThePlanHelp(activeCount: Int, help: String) {
        // The count's own view never hit-tests, so the tooltip has to live on the row.
        let cell = headerCell(usage: CloudMachinesUsage(activeCount: activeCount, maxActiveVms: 50, isPaidPlan: false))
        #expect(cell.toolTip == help)

        cell.configure(node: CloudTreeNode(id: "cloud-machines-section", kind: .cloudMachinesSection(canCreateMachine: true)),
                       machineActions: machineActions(), nodeActions: nodeActions())
        #expect(cell.toolTip == nil, "No plan, no help: a reused row must not keep the last team's")
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
        fixture.container.layoutSubtreeIfNeeded()
        let outline = try #require(fixture.coordinator.outlineView)
        let header = try #require(outline.item(atRow: 0) as? CloudTreeNode)
        #expect(header.structureTag == "cloudMachinesSection")
        #expect(onScreenHeaderLabel(outline) == "Cloud Machines, 1 of 50 machines")

        inputs.cloudMachinesUsage = CloudMachinesUsage(activeCount: 2, maxActiveVms: 50, isPaidPlan: false)
        fixture.coordinator.update(inputs: inputs)
        fixture.container.layoutSubtreeIfNeeded()

        #expect(outline.item(atRow: 0) as? CloudTreeNode === header, "The header keeps its identity")
        #expect(CloudTreeRowContentView.groupCount(for: header.kind)?.text == "2/50")
        #expect(onScreenHeaderLabel(outline) == "Cloud Machines, 2 of 50 machines",
                "The row already on screen reloads with the new count")
    }

    @Test("The count stays on the header expanded and collapsed, light and dark",
          arguments: [false, true], [1, 50])
    func countShowsInBothExpansionStates(dark: Bool, activeCount: Int) throws {
        let fixture = CloudSidebarOrderingFixture()
        defer { fixture.close() }
        fixture.window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        fixture.coordinator.update(inputs: CloudTreeBuildInputs(
            machines: [MachineSnapshot(id: "ordering-fixture", provider: "freestyle", image: "base",
                                       isDesktop: false, activity: .ready)],
            snapshot: fixture.snapshot(), source: .cloudWithDevicesSection, canCreateCloudMachine: true,
            cloudMachinesUsage: CloudMachinesUsage(activeCount: activeCount, maxActiveVms: 50, isPaidPlan: false)
        ))
        fixture.container.layoutSubtreeIfNeeded()
        let outline = try #require(fixture.coordinator.outlineView)
        let header = try #require(outline.item(atRow: 0) as? CloudTreeNode)
        for expanded in [true, false] {
            if outline.isItemExpanded(header) != expanded { fixture.coordinator.open(header) }
            fixture.container.layoutSubtreeIfNeeded()
            #expect(outline.isItemExpanded(header) == expanded)
            let cell = try #require(outline.view(atColumn: 0, row: 0, makeIfNecessary: false) as? CloudTreeCellView)
            #expect(cell.accessibilityLabel() == "Cloud Machines, \(activeCount) of 50 machines")
            // Hover the full plan so the capture shows the + beside the orange count.
            cell.setHovered(activeCount == 50)
            try fixture.attachScreenshot(
                named: "cloud-machines-\(activeCount)of50-\(expanded ? "expanded" : "collapsed")-\(dark ? "dark" : "light")"
            )
        }
    }

    @Test("The hover + never covers the drawn count, and the title truncates before the count")
    func hoverPlusLeavesRoomForTheCount() throws {
        let roomy = try hoveredFullPlanHeader(width: 380)
        let narrow = try hoveredFullPlanHeader(width: 160)
        #expect(narrow.count.lowerBound < roomy.count.lowerBound, "The 160pt title should have given up room")
        #expect(narrow.count.upperBound <= narrow.plusMinX, "Count \(narrow.count) runs under + at \(narrow.plusMinX)")
        #expect(abs(narrow.count.upperBound - narrow.count.lowerBound - (roomy.count.upperBound - roomy.count.lowerBound)) <= 1,
                "The count was clipped: \(narrow.count) at 160pt, \(roomy.count) at 380pt")
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

    @Test("Persistent list status and tree errors keep their row", arguments: ["listStatus", "treeError"])
    func fleetStatusStillShows(message: String) {
        let height = headerHeight {
            fleetStatus(
                listStatus: message == "listStatus" ? .reconnecting : nil,
                treeError: message == "treeError" ? "Cloud tree unavailable" : nil
            )
        }
        #expect(height >= RightSidebarChromeMetrics.secondaryBarHeight + 8,
                "The \(message) row is missing: header is \(height)pt")
    }

    private func fleetStatus(
        listStatus: MachineListStatus? = nil, treeError: String? = nil
    ) -> MachinesCloudStatus {
        MachinesCloudStatus(listStatus: listStatus, listError: nil,
                            treeError: treeError, onDismissStale: { _ in }, onDismissTreeError: { _ in },
                            performListStatusAction: { _ in })
    }

    private func headerHeight<Status: View>(@ViewBuilder status: @escaping () -> Status) -> CGFloat {
        NSHostingView(rootView: CloudTeamPickerHeader(
            accountFlow: nil, presentation: nil, chromeBackgroundColor: .windowBackgroundColor,
            isRefreshing: false, onRefresh: {}, onNewMachine: {},
            status: status
        )).fittingSize.height
    }

    /// The mounted header cell only; never makes a fresh one that would read current state.
    private func onScreenHeaderLabel(_ outline: NSOutlineView) -> String? {
        (outline.view(atColumn: 0, row: 0, makeIfNecessary: false) as? CloudTreeCellView)?.accessibilityLabel()
    }

    /// Where the production outline draws a hovered 50/50 header's orange count, and where its + starts.
    private func hoveredFullPlanHeader(width: CGFloat) throws -> (count: ClosedRange<CGFloat>, plusMinX: CGFloat) {
        let fixture = CloudSidebarOrderingFixture()
        defer { fixture.close() }
        fixture.window.setContentSize(NSSize(width: width, height: 560))
        fixture.coordinator.update(inputs: CloudTreeBuildInputs(
            machines: [], snapshot: fixture.snapshot(), source: .cloudWithDevicesSection, canCreateCloudMachine: true,
            cloudMachinesUsage: CloudMachinesUsage(activeCount: 50, maxActiveVms: 50, isPaidPlan: false)
        ))
        fixture.container.layoutSubtreeIfNeeded()
        let outline = try #require(fixture.coordinator.outlineView)
        let cell = try #require(outline.view(atColumn: 0, row: 0, makeIfNecessary: false) as? CloudTreeCellView)
        cell.setHovered(true)
        cell.layoutSubtreeIfNeeded()
        let buttons = try #require(cell.subviews.first { $0 is CloudTreeRowControlsHostingView })
        #expect(!buttons.isHidden)
        let count = try #require(try orangeSpan(in: cell), "No orange count drawn at \(width)pt")
        return (count, buttons.frame.minX)
    }

    /// The horizontal span, in points, that the view draws in the at-limit orange.
    private func orangeSpan(in view: NSView) throws -> ClosedRange<CGFloat>? {
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let image = try #require(bitmap.cgImage)
        let (width, height) = (image.width, image.height)
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            // Flatten onto white so every pixel is opaque sRGB; gray text stays gray, orange keeps red > blue.
            guard let sRGB = CGColorSpace(name: CGColorSpace.sRGB), let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        try #require(drawn)
        let columns = (0..<width).filter { x in
            (0..<height).contains { y in Int(pixels[(y * width + x) * 4]) - Int(pixels[(y * width + x) * 4 + 2]) > 80 }
        }
        guard let first = columns.first, let last = columns.last else { return nil }
        let scale = CGFloat(width) / view.bounds.width
        return CGFloat(first) / scale...CGFloat(last + 1) / scale
    }

    private static let longTeamName = "Team with a long name for the narrow Cloud sidebar"

    /// The width the header's `ViewThatFits` gets inside a sidebar `width` points wide.
    private static func barContentWidth(_ width: CGFloat) -> CGFloat {
        width - 2 * RightSidebarChromeMetrics.barHorizontalPadding
    }

    /// The ideal width of one candidate header row, the size `ViewThatFits` compares.
    private func idealRowWidth(_ actions: CloudHeaderMachineActions, teamName: String) async throws -> CGFloat {
        _ = NSApplication.shared
        let flow = try await HostAccountFlow.makeForTeamChangeTests(client: TeamChangeAuthClient(firstTeamName: teamName))
        let header = CloudTeamPickerHeader(
            accountFlow: flow, presentation: nil, chromeBackgroundColor: .windowBackgroundColor,
            isRefreshing: false, onRefresh: {}, onNewMachine: {},
            status: { EmptyView() }
        )
        let row = NSHostingView(rootView: header.actionsRow(actions, picker: CloudTeamPickerPresentation()).fixedSize())
        return row.fittingSize.width
    }

    private func headerCell(usage: CloudMachinesUsage) -> CloudTreeCellView {
        let cell = CloudTreeCellView(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        let node = CloudTreeNode(id: "cloud-machines-section", kind: .cloudMachinesSection(canCreateMachine: true, usage: usage))
        cell.configure(node: node, machineActions: machineActions(), nodeActions: nodeActions())
        return cell
    }

    private func headerCount(_ usage: CloudMachinesUsage) -> CloudTreeGroupCount? {
        CloudTreeRowContentView.groupCount(for: .cloudMachinesSection(canCreateMachine: true, usage: usage))
    }

    private func machineActions() -> MachineRowActions {
        MachineRowActions(openShell: { _ in }, openDesktop: { _ in }, runCommand: { _, _ in },
                    confirmDelete: { _ in }, promptRename: { _ in }, resizeDisk: { _, _ in }, promptUpgrade: {})
    }

    private func nodeActions() -> CloudTreeNodeActions {
        CloudTreeNodeActions(project: { _, _, _ in }, projectRemoteView: { _, _, _, _ in },
            projectInLocalWorkspace: { _, _ in }, projectRemoteViewInLocalWorkspace: { _, _, _ in },
            newTerminal: { _, _ in }, openGroup: { _, _, _, _ in }, openGroupAsWorkspace: { _, _, _ in },
            newWorkspace: { _ in }, closeTerminal: { _ in }, closeWorkspace: { _, _ in }, renameWorkspace: { _, _ in },
            renameTerminal: { _, _ in }, selectLocalWorkspace: { _ in }, copyToPasteboard: { _ in }, copyPortLink: { _ in }, refresh: {})
    }
}
