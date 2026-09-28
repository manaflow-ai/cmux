import AppKit
import CmuxSidebar
import Testing
@testable import cmux_DEV

/// `sidebar.compactAgentStatus`: agent hook status rows fold into one
/// leading glyph that also carries pull request and branch state.
@Suite(.serialized)
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

    // MARK: Group headers

    private static func member(_ title: String, _ kind: Glyph.Kind, _ tooltip: String = "detail") -> Glyph.GroupMember {
        Glyph.GroupMember(title: title, glyph: Glyph(kind: kind, tooltip: tooltip))
    }

    @Test
    func groupRollUpShowsTheLoudestMemberAndNamesEveryOneAskingForAttention() {
        let glyph = Glyph.rollUp([
            Self.member("api", .running, "Claude Code: Running"),
            Self.member("docs", .pullRequest(.open)),
            Self.member("web", .needsInput, "Codex: Needs input\nfeat/web"),
            Self.member("cli", .unseen, "Finished"),
        ])

        #expect(glyph?.kind == .needsInput)
        // Loudest first, one line each; settled members stay out.
        #expect(glyph?.tooltip == "web: Codex: Needs input\napi: Claude Code: Running\ncli: Finished")
    }

    @Test
    func groupRollUpIsNilWhenEveryMemberIsSettled() {
        #expect(Glyph.rollUp([
            Self.member("a", .pullRequest(.merged)),
            Self.member("b", .idle),
            Self.member("c", .branch),
            Self.member("d", .terminal),
            Self.member("e", .pending),
        ]) == nil)
    }

    @Test
    func groupRollUpRanksErrorAboveEveryOtherAttentionState() {
        // A pull request asks for nothing, so it never speaks for a group.
        #expect(Glyph.rollUp([
            Self.member("a", .running),
            Self.member("b", .pullRequest(.open)),
        ])?.kind == .running)
        #expect(Glyph.rollUp([
            Self.member("a", .running),
            Self.member("b", .needsInput),
            Self.member("c", .error),
        ])?.kind == .error)
    }

    @Test
    func expandedGroupHeaderSpeaksForItsAnchorAndCollapsedForEveryMember() {
        let anchor = UUID(), member = UUID()
        let members = [
            anchor: Self.member("anchor", .idle),
            member: Self.member("member", .needsInput),
        ]
        func header(collapsed: Bool, unreadAnchor: Int = 0) -> Glyph? {
            Glyph.groupHeader(
                isCollapsed: collapsed,
                anchorId: anchor,
                memberIds: [anchor, member],
                members: members,
                unread: { ($0 == anchor ? unreadAnchor : 0, $0 == anchor ? "Done" : nil) }
            )
        }

        // Expanded: the member has its own row; the idle anchor says nothing.
        #expect(header(collapsed: false) == nil)
        // Unread on the anchor turns it blue, with the notification leading.
        #expect(header(collapsed: false, unreadAnchor: 2)?.kind == .unseen)
        #expect(header(collapsed: false, unreadAnchor: 2)?.tooltip == "anchor: Done")
        // Collapsed: the hidden member's needs-input surfaces.
        #expect(header(collapsed: true)?.kind == .needsInput)
    }

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
        #expect(glyph.color(isActive: false, selected: .white, secondary: .gray) == Glyph.needsInputColor)
        #expect(glyph.sizeScale < 1)
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

    /// cmux does not fetch a pull request's checks or mergeability, so merge
    /// state is the only thing that colors the glyph.
    @Test
    func pullRequestColorsFollowMergeStateAlone() {
        let cases: [(SidebarPullRequestStatus, NSColor, String)] = [
            (.open, .gray, "cmux.pullrequest"),
            (.merged, .systemPurple, "cmux.merge"),
            (.closed, .gray, "cmux.pullrequest"),
        ]
        for (status, color, symbol) in cases {
            let glyph = Glyph.resolve(.init(
                lifecycleStates: [.idle],
                pullRequests: [.init(label: "PR", number: 7, status: status)],
                branch: "feature"
            ))
            #expect(glyph.color(isActive: false, selected: .white, secondary: .gray) == color)
            #expect(glyph.symbolName == symbol)
        }
    }

    @Test
    func aStalePullRequestDoesNotSetTheGlyphButStaysInTheTooltip() {
        // Three failed refreshes in a row mark the row stale; an unconfirmed
        // state must not color the glyph.
        let stale = Glyph.Input.PullRequest(label: "PR", number: 9, status: .merged, isStale: true)
        let glyph = Glyph.resolve(.init(pullRequests: [stale], branch: "feature"))
        #expect(glyph.kind == .branch)
        #expect(glyph.tooltip.contains("PR #9"))
        // A confirmed row behind a stale one still sets the glyph.
        #expect(Glyph.resolve(.init(pullRequests: [stale, Self.openPR])).kind == .pullRequest(.open))
    }

    @Test
    func pullRequestGlyphsAreDrawnToFillTheirSquare() throws {
        for drawn in [SidebarCompactStatusDrawnGlyph.pullRequest, .merge] {
            let image = drawn.image(pointSize: 11)
            #expect(image.size == NSSize(width: 11, height: 11))
            #expect(image.isTemplate)
            // SF's arrow.triangle.pull is under half as wide as it is tall.
            let bounds = drawn.path(in: NSRect(x: 0, y: 0, width: 16, height: 16)).bounds
            #expect(bounds.width > 10 && bounds.height > 12)
            // Also accepted as a configured icon name.
            #expect(SidebarCompactStatusGlyphImageView.image(symbol: drawn.rawValue, badge: nil, pointSize: 11) != nil)
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
            #expect(glyph.isDrawn == (kind != .terminal))
            #expect(glyph.symbolName == symbol)
            #expect(glyph.badgeSymbolName == nil)
            #expect(!glyph.pulses)
        }
    }

    @Test
    func onlyAClosedPullRequestCarriesABadge() {
        let badges: [(SidebarPullRequestStatus, String?)] = [
            (.open, nil),
            (.closed, "minus.circle.fill"),
            (.merged, nil),
        ]
        for (status, badge) in badges {
            let glyph = Glyph.resolve(.init(pullRequests: [.init(label: "PR", number: 3, status: status)]))
            #expect(glyph.badgeSymbolName == badge)
        }
    }

    @Test
    func configuredIconsReplaceTheSymbolAndBadgeAndSurviveUnread() {
        let icons = Glyph.validIconOverrides([
            "terminal": " apple.terminal ",
            "pullRequestClosed": "flame.fill",
            "unseen": "envelope.badge.fill",
            "notAState": "star",
            "idle": "   ",
        ])
        #expect(icons == ["terminal": "apple.terminal", "pullRequestClosed": "flame.fill", "unseen": "envelope.badge.fill"])

        let terminal = Glyph.resolve(.init(iconOverrides: icons))
        #expect(terminal.isDrawn)
        #expect(terminal.symbolName == "apple.terminal")
        #expect(terminal.defaultSymbolName == "terminal")
        #expect(terminal.applyingUnread(1, latestNotificationText: nil).symbolName == "envelope.badge.fill")

        // A configured symbol replaces the whole glyph, closed badge included.
        let closed = Glyph.resolve(.init(
            pullRequests: [.init(label: "PR", number: 3, status: .closed)],
            iconOverrides: icons
        ))
        #expect(closed.symbolName == "flame.fill")
        #expect(closed.badgeSymbolName == nil)
        #expect(closed.color(isActive: false, selected: .white, secondary: .gray) == .gray)

        let idle = Glyph.resolve(.init(lifecycleStates: [.idle], iconOverrides: icons))
        #expect(idle.symbolName == "checkmark.circle")
    }

    @Test
    func everyIconSlotHasADistinctState() {
        #expect(Glyph.IconSlot.allCases.count == 11)
        #expect(Set(Glyph.IconSlot.allCases.map(\.rawValue)).count == 11)
        // Every slot is a state the app can actually reach.
        #expect(Set(Glyph.IconSlot.allCases) == Set([
            .error, .needsInput, .running, .starting, .unseen,
            .pullRequestOpen, .pullRequestMerged, .pullRequestClosed,
            .idle, .branch, .terminal,
        ]))
    }

    @Test
    func unreadTurnsSettledRowsBlueButNotActiveOnes() {
        let settled = [
            Glyph.resolve(.init(lifecycleStates: [.idle])),
            Glyph.resolve(.init(pullRequests: [Self.openPR])),
            // "Starting" asks for nothing, so unread outranks it and a group
            // header still shows the unread state instead of a count badge.
            Glyph.resolve(.init(lifecycleStates: [.unknown])),
        ]
        #expect(Glyph.resolve(.init()).applyingUnread(1, latestNotificationText: nil).isDrawn)
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
    func profileLabelsComeFromTheConfigDirectory() {
        let home = "/Users/me"
        func label(_ env: [String: String]?) -> String? {
            SidebarAgentProfileLabel.label(environment: env, homeDirectory: home)
        }

        #expect(label(nil) == nil)
        #expect(label([:]) == nil)
        #expect(label(["CLAUDE_CONFIG_DIR": "/Users/me/.claude"]) == nil)
        #expect(label(["CODEX_HOME": "~/.codex"]) == nil)
        #expect(label(["CLAUDE_CONFIG_DIR": "/Users/me/.claude-outlook"]) == "outlook")
        #expect(label(["CLAUDE_CONFIG_DIR": "~/.claude-work/"]) == "work")
        #expect(label(["CODEX_HOME": "/Volumes/x/codex-personal"]) == "personal")
        #expect(
            label(["CLAUDE_CONFIG_DIR": "/Users/me/.subrouter/codex/claude-proxy/7e6dd05e630d2ac6f783e242"])
                == SidebarAgentProfileLabel.routedProxyLabel
        )
    }

    @Test
    func indexChangesRefreshOnlyTheWorkspacesTheyName() {
        let a = UUID(), b = UUID(), c = UUID()
        let all = [a, b, c]
        func changed(_ userInfo: [AnyHashable: Any]?) -> [UUID] {
            SidebarAgentProfileLabel.changedWorkspaceIds(userInfo, allWorkspaceIds: all)
        }

        #expect(changed(nil) == all)
        #expect(changed(["panelIdsByWorkspaceId": [b: Set([UUID()])]]) == [b])
        #expect(changed(["workspaceId": c]) == [c])
        #expect(changed(["workspaceId": UUID()]).isEmpty)
    }

    @Test
    func tooltipListsProfilesAfterAgentStatuses() {
        let glyph = Glyph.resolve(.init(
            agentEntries: [Self.entry("claude_code", "Idle", icon: "pause.circle.fill")],
            lifecycleStates: [.idle],
            profiles: ["outlook", "proxy"]
        ))
        let lines = glyph.tooltip.split(separator: "\n").map(String.init)

        #expect(lines.count == 2)
        #expect(lines[1].contains("outlook, proxy"))
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
        #expect(glyphView.contentTintColor == Glyph.needsInputColor)
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

    @Test
    func aConfiguredSymbolForADotStateDrawsFullSize() {
        let cases: [(Glyph.IconSlot, Glyph.Input)] = [
            (.needsInput, Glyph.Input(lifecycleStates: [.needsInput])),
            (.running, Glyph.Input(hasActiveAgent: true)),
        ]
        for (slot, input) in cases {
            #expect(Glyph.resolve(input).sizeScale < 1)
            var configured = input
            configured.iconOverrides = [slot.rawValue: "bolt.fill"]
            let glyph = Glyph.resolve(configured)
            #expect(glyph.symbolName == "bolt.fill")
            #expect(glyph.sizeScale == 1)
        }
        let unseen = Glyph
            .resolve(.init(lifecycleStates: [.idle], iconOverrides: ["unseen": "envelope.fill"]))
            .applyingUnread(1, latestNotificationText: nil)
        #expect(unseen.symbolName == "envelope.fill")
        #expect(unseen.sizeScale == 1)
    }

    /// A symbol name that no installed SF Symbols version resolves must fall
    /// back to the built-in glyph as if nothing were configured: the dot states
    /// back at their small scale, and a closed pull request keeping the minus
    /// badge that tells it apart from an open one.
    @Test
    func anUnresolvableConfiguredSymbolFallsBackToTheBuiltInGlyph() {
        let dot = Glyph.resolve(
            .init(lifecycleStates: [.needsInput], iconOverrides: ["needsInput": "not.a.real.symbol"])
        )
        #expect(dot.sizeScale == 1)
        let dotFallback = dot.droppingCustomSymbol
        #expect(dotFallback.customSymbolName == nil)
        #expect(dotFallback.symbolName == "circle.fill")
        #expect(dotFallback.sizeScale < 1)

        var closedInput = Glyph.Input(
            pullRequests: [Glyph.Input.PullRequest(label: "PR", number: 7, status: .closed)]
        )
        closedInput.iconOverrides = ["pullRequestClosed": "not.a.real.symbol"]
        let closed = Glyph.resolve(closedInput)
        #expect(closed.kind == .pullRequest(.closed))
        #expect(closed.badgeSymbolName == nil)
        let closedFallback = closed.droppingCustomSymbol
        #expect(closedFallback.symbolName == SidebarCompactStatusDrawnGlyph.pullRequest.rawValue)
        #expect(closedFallback.badgeSymbolName == "minus.circle.fill")

        // A resolvable configured symbol is not a fallback candidate.
        let good = Glyph.resolve(.init(lifecycleStates: [.idle], iconOverrides: ["idle": "moon.zzz"]))
        #expect(good.droppingCustomSymbol.symbolName == "checkmark.circle")
        #expect(SidebarCompactStatusGlyphImageView.image(good, pointSize: 11) != nil)
    }

    @Test
    func compactRowsHoldTheTitleToOneLineEvenWhenTitleWrappingIsOn() {
        let defaults = Self.makeDefaults()
        defaults.set(true, forKey: SidebarWorkspaceTitleWrapSettings.key)
        let settings = SidebarTabItemSettingsSnapshot(defaults: defaults)
        #expect(settings.wrapsWorkspaceTitles)

        func titleLines(compact: Bool) -> Int {
            let model = SidebarAppKitRowCellTests.makeModel(
                settings: settings,
                compactStatusGlyph: compact ? Glyph.resolve(.init(lifecycleStates: [.idle])) : nil
            )
            let cell = SidebarAppKitRowCellTests.configuredCell(model: model)
            cell.frame = NSRect(x: 0, y: 0, width: 280, height: 60)
            _ = cell.layoutContent(model: model, width: 280, apply: true)
            return SidebarAppKitRowCellTests.descendants(of: cell)
                .compactMap { $0 as? SidebarRowTextView }
                .first { !$0.isHidden && $0.stringValue == model.snapshot.title }?
                .maximumNumberOfLines ?? 0
        }

        #expect(titleLines(compact: false) > 1)
        #expect(titleLines(compact: true) == 1)
    }

    @Test
    func compactGroupHeadersDropTheUnreadCountBadgeEvenWithNothingToRollUp() {
        func visibleBadgeCount(compacts: Bool) -> Int {
            let cell = SidebarGroupHeaderTableCellView()
            cell.configurePresentation(model: Self.makeGroupHeaderModel(compacts: compacts))
            return SidebarAppKitRowCellTests.descendants(of: cell)
                .compactMap { $0 as? SidebarRowUnreadBadgeView }
                .filter { !$0.isHidden }
                .count
        }

        // Off: the header still counts its anchor's unread notifications.
        #expect(visibleBadgeCount(compacts: false) == 1)
        // On: unread shows as the blue glyph, so no count badge comes back
        // even for a state that does not roll up.
        #expect(visibleBadgeCount(compacts: true) == 0)
    }

    private static func makeGroupHeaderModel(compacts: Bool) -> SidebarGroupHeaderRowModel {
        var model = SidebarGroupHeaderRowModel(
            groupId: UUID(),
            anchorWorkspaceId: UUID(),
            name: "Group",
            iconSymbol: "folder",
            tintHex: nil,
            isCollapsed: false,
            isPinned: false,
            isAnchorActive: false,
            isMultiSelected: false,
            multiSelectionBackgroundStyle: .clear,
            memberCount: 2,
            anchorUnreadCount: 3,
            canMarkRead: true,
            canMarkUnread: false,
            hasLatestNotifications: true,
            canMarkAllRead: false,
            canMarkAllUnread: false,
            shortcutHintText: nil,
            shortcutHintXOffset: 0,
            shortcutHintYOffset: 0,
            fontScale: 1,
            globalFontMagnificationPercent: 100,
            cwdContextMenuItems: [],
            rowSpacing: 2,
            isFirstRow: true,
            isBeingDragged: false,
            topDropIndicatorVisible: false,
            bottomDropIndicatorVisible: false,
            colorSchemeIsDark: true,
            notificationBadgeColorHex: nil
        )
        model.compactsAgentStatus = compacts
        return model
    }

    // MARK: Factory

    /// The snapshot factory is the single place both sidebar engines read, so
    /// it is where a pull request's real state has to arrive.
    @Test
    func factoryGivesAnOpenPullRequestTheGrayGlyphAndIgnoresAStaleOne() throws {
        let defaults = Self.makeDefaults()
        defaults.set(true, forKey: "sidebarCompactAgentStatus")
        let settings = SidebarTabItemSettingsSnapshot(defaults: defaults)
        let workspace = Workspace(
            title: "Project",
            workingDirectory: FileManager.default.currentDirectoryPath,
            portOrdinal: 0
        )
        defer { workspace.teardownAllPanels() }
        let panelId = try #require(workspace.focusedPanelId)
        let url = try #require(URL(string: "https://github.com/manaflow-ai/cmux/pull/42"))
        let factory = SidebarWorkspaceSnapshotFactory(
            workspace: workspace,
            settings: settings,
            showsAgentActivity: false
        )

        workspace.updatePanelPullRequest(panelId: panelId, number: 42, label: "cmux", url: url, status: .open)
        let open = try #require(factory.makeSnapshot().compactStatusGlyph)
        #expect(open.kind == .pullRequest(.open))
        // No checks or mergeability data reaches the sidebar, so an open pull
        // request draws secondary gray whatever its CI says.
        #expect(open.color(isActive: false, selected: .white, secondary: .gray) == .gray)
        #expect(open.badgeSymbolName == nil)
        #expect(open.tooltip.contains("cmux #42"))

        workspace.updatePanelPullRequest(
            panelId: panelId,
            number: 42,
            label: "cmux",
            url: url,
            status: .merged,
            isStale: true
        )
        let stale = try #require(factory.makeSnapshot().compactStatusGlyph)
        #expect(stale.kind == .terminal)
        #expect(stale.tooltip.contains("cmux #42"))

        // With the setting off the row keeps its pull request line and no glyph.
        let plain = SidebarWorkspaceSnapshotFactory(
            workspace: workspace,
            settings: SidebarTabItemSettingsSnapshot(defaults: Self.makeDefaults()),
            showsAgentActivity: false
        ).makeSnapshot()
        #expect(plain.compactStatusGlyph == nil)
        #expect(!plain.pullRequestRows.isEmpty)
    }

    /// The setting-to-snapshot path. `partition` is covered directly above and
    /// the glyph resolution below it, but neither proves the factory calls them
    /// with the setting's own value, which is the wiring the user toggles.
    @Test
    func factoryFoldsAgentRowsAndKeepsCustomOnesWhenCompact() {
        let workspace = Workspace(
            title: "Project",
            workingDirectory: FileManager.default.currentDirectoryPath,
            portOrdinal: 0
        )
        defer { workspace.teardownAllPanels() }
        workspace.statusEntries["claude_code"] = Self.entry("claude_code", "Needs input")
        workspace.statusEntries["deploy"] = Self.entry("deploy", "green")
        // A structured agent key is suppressed by
        // `sidebarStatusEntriesVisibleForDisplay()` until something proves an
        // agent owns it, and `partition` keys off the same allow-list. So
        // without this the entry never reaches the factory at all and both
        // sides of the comparison below would read `["deploy"]`, which is what
        // the first version of this test asserted against and why it was wrong.
        // A PID with no panel binding is the smallest such proof.
        workspace.agentPIDs["claude_code"] = 4242

        func snapshot(compact: Bool) -> SidebarWorkspaceSnapshotBuilder.Snapshot {
            let defaults = Self.makeDefaults()
            defaults.set(compact, forKey: "sidebarCompactAgentStatus")
            return SidebarWorkspaceSnapshotFactory(
                workspace: workspace,
                settings: SidebarTabItemSettingsSnapshot(defaults: defaults),
                showsAgentActivity: false
            ).makeSnapshot()
        }

        // On: the agent key leaves the rows and becomes the glyph; the key the
        // user wrote themselves stays a row. A non-nil glyph on its own would
        // not prove the entry is what produced it, since the factory also
        // builds one from a branch or a pull request, so assert where it came
        // from. The kind is `.idle` rather than `.needsInput` because the kind
        // is read from `AgentHibernationLifecycleState`, which this workspace
        // has none of; with no lifecycle state the `.idle` branch is reachable
        // only through a non-empty `agentEntries`. The tooltip then carries the
        // entry's own text, which nothing else in this fixture could supply.
        let on = snapshot(compact: true)
        #expect(on.metadataEntries.map(\.key) == ["deploy"])
        #expect(on.compactStatusGlyph?.kind == .idle)
        #expect(on.compactStatusGlyph?.tooltip.contains("Needs input") == true)

        // Off: both keys are rows and no glyph is built at all.
        let off = snapshot(compact: false)
        #expect(Set(off.metadataEntries.map(\.key)) == ["claude_code", "deploy"])
        #expect(off.compactStatusGlyph == nil)
    }
}
