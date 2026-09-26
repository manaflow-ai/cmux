import AppKit
import CmuxSidebar
import Testing
@testable import cmux_DEV

/// `sidebar.compactAgentStatus`: agent hook status rows fold into one
/// leading glyph that also carries pull request and branch state.
@Suite
@MainActor
struct SidebarCompactAgentStatusTests {
    private typealias Glyph = SidebarCompactStatusGlyph

    private static func entry(
        _ key: String,
        _ value: String,
        icon: String? = "bolt.fill"
    ) -> SidebarStatusEntry {
        SidebarStatusEntry(key: key, value: value, icon: icon, color: "#4C8DFF")
    }

    private static func makeDefaults() -> UserDefaults {
        UserDefaults(suiteName: "SidebarCompactAgentStatusTests.\(UUID().uuidString)")!
    }

    private static let openPR = Glyph.Input.PullRequest(label: "PR", number: 12, status: .open)

    // MARK: Partition

    @Test
    func offKeepsEveryStatusEntryAsARow() {
        let entries = [Self.entry("claude_code", "Running"), Self.entry("deploy", "green")]
        let result = Glyph.partition(entries, compacts: false)

        #expect(result.agent.isEmpty)
        #expect(result.rows == entries)
    }

    @Test
    func onMovesOnlyAgentKeysOutOfTheRows() {
        let custom = Self.entry("deploy", "green", icon: "checkmark")
        let result = Glyph.partition(
            [Self.entry("claude_code", "Running"), custom, Self.entry("codex", "Needs input")],
            compacts: true
        )

        #expect(result.rows == [custom])
        #expect(result.agent.map(\.key) == ["claude_code", "codex"])
    }

    // MARK: Resolution

    @Test
    func needsInputOutranksEverything() {
        let glyph = Glyph.resolve(.init(
            agentEntries: [Self.entry("claude_code", "Needs input", icon: "bell.fill")],
            lifecycleStates: [.running, .needsInput],
            showsRunningSpinner: true,
            pullRequests: [Self.openPR],
            branch: "main"
        ))
        #expect(glyph?.kind == .attention)
        #expect(glyph?.symbolName == "exclamationmark.triangle.fill")
    }

    @Test
    func agentErrorIconIsAttention() {
        let glyph = Glyph.resolve(.init(
            agentEntries: [Self.entry("codex", "Error", icon: "exclamationmark.triangle.fill")],
            lifecycleStates: [.idle]
        ))
        #expect(glyph?.kind == .attention)
    }

    @Test
    func runningDefersToTheAnimatedSpinner() {
        let running = Glyph.Input(lifecycleStates: [.running], showsRunningSpinner: true, branch: "main")
        #expect(Glyph.resolve(running) == nil)

        var spinnerOff = running
        spinnerOff.showsRunningSpinner = false
        #expect(Glyph.resolve(spinnerOff)?.kind == .branch)
    }

    @Test
    func pullRequestStateBeatsBranchAndIdle() {
        for (status, kind) in [
            (SidebarPullRequestStatus.open, Glyph.Kind.pullRequestOpen),
            (.merged, .pullRequestMerged),
            (.closed, .pullRequestClosed),
        ] {
            let glyph = Glyph.resolve(.init(
                lifecycleStates: [.idle],
                pullRequests: [.init(label: "PR", number: 7, status: status)],
                branch: "feature"
            ))
            #expect(glyph?.kind == kind)
        }
    }

    @Test
    func idleUnknownAndEmptyWorkspaces() {
        #expect(Glyph.resolve(.init(lifecycleStates: [.idle]))?.kind == .idle)
        #expect(Glyph.resolve(.init(lifecycleStates: [.idle]))?.symbolName == "circle.fill")
        #expect(Glyph.resolve(.init(lifecycleStates: [.unknown]))?.kind == .pending)
        #expect(Glyph.resolve(.init(lifecycleStates: [.unknown]))?.symbolName == "circle")
        #expect(Glyph.resolve(.init()) == nil)
    }

    @Test
    func tooltipCarriesEveryDetailOnItsOwnLine() throws {
        let glyph = try #require(Glyph.resolve(.init(
            agentEntries: [Self.entry("claude_code", "Idle", icon: "pause.circle.fill")],
            lifecycleStates: [.idle],
            pullRequests: [Self.openPR],
            branch: "feat/sidebar"
        )))
        let lines = glyph.tooltip.split(separator: "\n").map(String.init)

        #expect(lines.count == 3)
        #expect(lines[0].contains("Claude Code") && lines[0].contains("Idle"))
        #expect(lines[1].contains("PR #12"))
        #expect(lines[2] == "feat/sidebar")
    }

    @Test
    func colorsFollowTheStateAndFlattenWhenSelected() throws {
        let selected = NSColor.white
        let secondary = NSColor.gray
        let open = try #require(Glyph.resolve(.init(pullRequests: [Self.openPR])))
        let branch = try #require(Glyph.resolve(.init(branch: "main")))

        #expect(open.color(isActive: false, selected: selected, secondary: secondary) == .systemGreen)
        #expect(branch.color(isActive: false, selected: selected, secondary: secondary) == .systemPurple)
        #expect(open.color(isActive: true, selected: selected, secondary: secondary) == selected)
    }

    @Test
    func agentDisplayNamesUseBuiltInDefinitions() {
        #expect(Glyph.agentDisplayName(forStatusKey: "claude_code") == "Claude Code")
        #expect(Glyph.agentDisplayName(forStatusKey: "codex") == "Codex")
        #expect(Glyph.agentDisplayName(forStatusKey: "future_agent") == "Future Agent")
    }

    // MARK: Setting and row

    @Test
    func settingDefaultsOffAndInvalidatesCachedSnapshots() {
        let off = SidebarTabItemSettingsSnapshot(defaults: Self.makeDefaults())
        #expect(!off.compactsAgentStatus)

        let defaultsOn = Self.makeDefaults()
        defaultsOn.set(true, forKey: "sidebarCompactAgentStatus")
        let on = SidebarTabItemSettingsSnapshot(defaults: defaultsOn)
        #expect(on.compactsAgentStatus)

        #expect(
            SidebarWorkspaceSnapshotFactory.presentationKey(settings: off, showsAgentActivity: true)
                != SidebarWorkspaceSnapshotFactory.presentationKey(settings: on, showsAgentActivity: true)
        )
    }

    @Test
    func appKitRowDrawsOneGlyphBeforeTheTitleInsteadOfAStatusRow() throws {
        let needsInput = Self.entry("claude_code", "Needs input", icon: "bell.fill")
        let asRow = SidebarAppKitRowCellTests.makeModel(metadataEntries: [needsInput])
        let glyph = try #require(Glyph.resolve(.init(
            agentEntries: [needsInput],
            lifecycleStates: [.needsInput]
        )))
        let compact = SidebarAppKitRowCellTests.makeModel(compactStatusGlyph: glyph)

        let rowCell = SidebarAppKitRowCellTests.configuredCell(model: asRow)
        let compactCell = SidebarAppKitRowCellTests.configuredCell(model: compact)
        let rowHeight = rowCell.layoutContent(model: asRow, width: 280, apply: false)
        compactCell.frame = NSRect(x: 0, y: 0, width: 280, height: 60)
        let compactHeight = compactCell.layoutContent(model: compact, width: 280, apply: true)

        #expect(compactHeight < rowHeight)

        let glyphView = try #require(
            SidebarAppKitRowCellTests.descendants(of: compactCell)
                .compactMap { $0 as? NSImageView }
                .first { !$0.isHidden && $0.toolTip == glyph.tooltip }
        )
        let titleView = try #require(
            SidebarAppKitRowCellTests.descendants(of: compactCell)
                .compactMap { $0 as? SidebarRowTextView }
                .first { !$0.isHidden && $0.stringValue == compact.snapshot.title }
        )
        #expect(glyphView.image != nil)
        #expect(glyphView.contentTintColor == .systemRed)
        #expect(glyphView.frame.maxX <= titleView.frame.minX)

        // Reuse: a row without a glyph hides the view again.
        compactCell.configure(
            model: asRow,
            actions: SidebarAppKitRowCellTests.makeActions(model: asRow),
            isPointerHovering: false,
            contextMenuDidOpen: {},
            contextMenuDidClose: {}
        )
        #expect(glyphView.isHidden)
    }
}
