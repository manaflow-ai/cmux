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
    func agentErrorIsTheOnlyRedTriangle() {
        let glyph = Glyph.resolve(.init(
            agentEntries: [Self.entry("codex", "Error", icon: "exclamationmark.triangle.fill")],
            lifecycleStates: [.needsInput, .running],
            hasActiveAgent: true,
            pullRequests: [Self.openPR]
        ))
        #expect(glyph.kind == .error)
        #expect(glyph.symbolName == "exclamationmark.triangle.fill")
    }

    @Test
    func needsInputIsAYellowDotAboveRunningAndPullRequests() {
        let glyph = Glyph.resolve(.init(
            agentEntries: [Self.entry("claude_code", "Needs input", icon: "bell.fill")],
            lifecycleStates: [.running, .needsInput],
            hasActiveAgent: true,
            pullRequests: [Self.openPR],
            branch: "main"
        ))
        #expect(glyph.kind == .needsInput)
        #expect(glyph.symbolName == "circle.fill")
        #expect(glyph.color(isActive: false, selected: .white, secondary: .gray) == .systemYellow)
    }

    @Test
    func runningIsAPulsingGrayDotWithOrWithoutALifecycleReport() {
        for input in [
            Glyph.Input(lifecycleStates: [.running], pullRequests: [Self.openPR]),
            Glyph.Input(hasActiveAgent: true, branch: "main"),
        ] {
            let glyph = Glyph.resolve(input)
            #expect(glyph.kind == .running)
            #expect(glyph.pulses)
            #expect(glyph.symbolName == "circle.fill")
            #expect(glyph.color(isActive: false, selected: .white, secondary: .gray) == .gray)
        }
    }

    @Test
    func startingAgentIsAHollowRingAbovePullRequests() {
        let glyph = Glyph.resolve(.init(lifecycleStates: [.idle, .unknown], pullRequests: [Self.openPR]))
        #expect(glyph.kind == .pending)
        #expect(glyph.symbolName == "circle.dashed")
        #expect(!glyph.pulses)
    }

    @Test
    func pullRequestColorsFollowMergeAndChecks() {
        let cases: [(SidebarPullRequestStatus, Glyph.Checks?, NSColor, String)] = [
            (.open, .conflict, .systemOrange, "arrow.triangle.pull"),
            (.open, .passing, .systemGreen, "arrow.triangle.pull"),
            (.open, .failing, .systemRed, "arrow.triangle.pull"),
            (.open, nil, .gray, "arrow.triangle.pull"),
            (.merged, nil, .systemPurple, "arrow.triangle.merge"),
            (.closed, nil, .gray, "arrow.triangle.pull"),
        ]
        for (status, checks, color, symbol) in cases {
            let glyph = Glyph.resolve(.init(
                lifecycleStates: [.idle],
                pullRequests: [.init(label: "PR", number: 7, status: status, checks: checks)],
                branch: "feature"
            ))
            #expect(glyph.color(isActive: false, selected: .white, secondary: .gray) == color)
            #expect(glyph.symbolName == symbol)
        }
    }

    @Test
    func settledRowsGetSymbolsNotDots() {
        let cases: [(Glyph.Input, Glyph.Kind, String)] = [
            (Glyph.Input(), .terminal, "terminal"),
            (Glyph.Input(branch: "main"), .branch, "arrow.triangle.branch"),
            (Glyph.Input(lifecycleStates: [.idle], branch: "main"), .idle, "checkmark.circle"),
        ]
        for (input, kind, symbol) in cases {
            let glyph = Glyph.resolve(input)
            #expect(glyph.kind == kind)
            #expect(glyph.symbolName == symbol)
            #expect(glyph.badgeSymbolName == nil)
            #expect(!glyph.pulses)
        }
    }

    @Test
    func pullRequestStatesShareOneGlyphWithABadge() {
        let badges: [(Glyph.Checks?, SidebarPullRequestStatus, String?)] = [
            (.passing, .open, "checkmark.circle.fill"),
            (.failing, .open, "xmark.circle.fill"),
            (.conflict, .open, "exclamationmark.circle.fill"),
            (nil, .open, nil),
            (nil, .closed, "minus.circle.fill"),
            (nil, .merged, nil),
        ]
        for (checks, status, badge) in badges {
            let glyph = Glyph.resolve(.init(pullRequests: [.init(label: "PR", number: 3, status: status, checks: checks)]))
            #expect(glyph.badgeSymbolName == badge)
        }
    }

    @Test
    func configuredIconsReplaceTheSymbolAndBadgeAndSurviveUnread() {
        let icons = Glyph.validIconOverrides([
            "terminal": " apple.terminal ",
            "pullRequestFailing": "flame.fill",
            "unseen": "envelope.badge.fill",
            "notAState": "star",
            "idle": "   ",
        ])
        #expect(icons == ["terminal": "apple.terminal", "pullRequestFailing": "flame.fill", "unseen": "envelope.badge.fill"])

        let terminal = Glyph.resolve(.init(iconOverrides: icons))
        #expect(terminal.symbolName == "apple.terminal")
        #expect(terminal.defaultSymbolName == "terminal")
        #expect(terminal.applyingUnread(1, latestNotificationText: nil).symbolName == "envelope.badge.fill")

        let failing = Glyph.resolve(.init(
            pullRequests: [.init(label: "PR", number: 3, status: .open, checks: .failing)],
            iconOverrides: icons
        ))
        #expect(failing.symbolName == "flame.fill")
        #expect(failing.badgeSymbolName == nil)
        #expect(failing.color(isActive: false, selected: .white, secondary: .gray) == .systemRed)

        let idle = Glyph.resolve(.init(lifecycleStates: [.idle], iconOverrides: icons))
        #expect(idle.symbolName == "checkmark.circle")
    }

    @Test
    func everyIconSlotHasADistinctState() {
        #expect(Glyph.IconSlot.allCases.count == 14)
        #expect(Set(Glyph.IconSlot.allCases.map(\.rawValue)).count == 14)
    }

    @Test
    func unreadTurnsSettledRowsBlueButNotActiveOnes() {
        let settled = [
            Glyph.resolve(.init(lifecycleStates: [.idle])),
            Glyph.resolve(.init(pullRequests: [Self.openPR])),
        ]
        for glyph in settled {
            let unseen = glyph.applyingUnread(2, latestNotificationText: "Finished")
            #expect(unseen.kind == .unseen)
            #expect(unseen.tooltip.hasPrefix("Finished"))
            #expect(unseen.color(isActive: false, selected: .white, secondary: .gray) == .systemBlue)
            #expect(glyph.applyingUnread(0, latestNotificationText: "Finished") == glyph)
        }
        for input in [
            Glyph.Input(lifecycleStates: [.needsInput]),
            Glyph.Input(hasActiveAgent: true),
            Glyph.Input(lifecycleStates: [.unknown]),
        ] {
            let glyph = Glyph.resolve(input)
            let unread = glyph.applyingUnread(1, latestNotificationText: "Finished")
            #expect(unread.kind == glyph.kind)
            #expect(unread.tooltip.hasPrefix("Finished"))
        }
    }

    @Test
    func tooltipCarriesEveryDetailOnItsOwnLine() {
        let glyph = Glyph.resolve(.init(
            agentEntries: [Self.entry("claude_code", "Idle", icon: "pause.circle.fill")],
            lifecycleStates: [.idle],
            pullRequests: [Self.openPR],
            branch: "feat/sidebar",
            directory: "~/Projects/cmux"
        ))
        let lines = glyph.tooltip.split(separator: "\n").map(String.init)

        #expect(lines.count == 4)
        #expect(lines[0].contains("Claude Code") && lines[0].contains("Idle"))
        #expect(lines[1].contains("PR #12"))
        #expect(lines[2] == "feat/sidebar")
        #expect(lines[3] == "~/Projects/cmux")
    }

    @Test
    func lifecycleOnlyGlyphsStillNameTheirState() {
        let needsInput = Glyph.resolve(.init(lifecycleStates: [.needsInput]))
        let idle = Glyph.resolve(.init(lifecycleStates: [.idle], branch: "main"))

        #expect(needsInput.tooltip == "Needs input")
        #expect(idle.tooltip.split(separator: "\n").map(String.init) == ["Idle", "main"])
    }

    @Test
    func selectedRowsFlattenTheColor() {
        let glyph = Glyph.resolve(.init(lifecycleStates: [.needsInput]))
        #expect(glyph.color(isActive: true, selected: .white, secondary: .gray) == .white)
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
        let glyph = Glyph.resolve(.init(
            agentEntries: [needsInput],
            lifecycleStates: [.needsInput]
        ))
        let compact = SidebarAppKitRowCellTests.makeModel(compactStatusGlyph: glyph)

        let rowCell = SidebarAppKitRowCellTests.configuredCell(model: asRow)
        let compactCell = SidebarAppKitRowCellTests.configuredCell(model: compact)
        let rowHeight = rowCell.layoutContent(model: asRow, width: 280, apply: false)
        compactCell.frame = NSRect(x: 0, y: 0, width: 280, height: 60)
        let compactHeight = compactCell.layoutContent(model: compact, width: 280, apply: true)

        #expect(compactHeight < rowHeight)

        let glyphView = try #require(
            SidebarAppKitRowCellTests.descendants(of: compactCell)
                .compactMap { $0 as? SidebarCompactStatusGlyphImageView }
                .first { !$0.isHidden && $0.toolTip == glyph.tooltip }
        )
        let titleView = try #require(
            SidebarAppKitRowCellTests.descendants(of: compactCell)
                .compactMap { $0 as? SidebarRowTextView }
                .first { !$0.isHidden && $0.stringValue == compact.snapshot.title }
        )
        #expect(glyphView.image != nil)
        #expect(glyphView.contentTintColor == .systemYellow)
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

    @Test
    func appKitCompactRowShowsUnreadAsTheBlueGlyphNotACountBadge() throws {
        var model = SidebarAppKitRowCellTests.makeModel(
            compactStatusGlyph: Glyph.resolve(.init(lifecycleStates: [.idle]))
        )
        model.unreadCount = 3
        let cell = SidebarAppKitRowCellTests.configuredCell(model: model)
        cell.frame = NSRect(x: 0, y: 0, width: 280, height: 60)
        _ = cell.layoutContent(model: model, width: 280, apply: true)
        let views = SidebarAppKitRowCellTests.descendants(of: cell)

        let glyphView = try #require(views.compactMap { $0 as? SidebarCompactStatusGlyphImageView }.first)
        #expect(!glyphView.isHidden)
        #expect(glyphView.contentTintColor == .systemBlue)
        let badges = views.compactMap { $0 as? SidebarRowUnreadBadgeView }
        let visibleBadges = badges.filter { !$0.isHidden }
        #expect(visibleBadges.isEmpty)
    }
}
