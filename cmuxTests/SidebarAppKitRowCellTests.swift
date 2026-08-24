import AppKit
import CmuxSidebar
import CmuxWorkspaces
import SwiftUI
import Testing
@testable import cmux_DEV

extension EnvironmentValues {
    static func sidebarTableTestValues(
        colorScheme: ColorScheme,
        colorSchemeContrast: ColorSchemeContrast = .standard
    ) -> Self {
        var values = Self()
        values.colorScheme = colorScheme
        // `colorSchemeContrast` is read-only in production. Its writable mirror
        // is used only by tests that need to simulate the accessibility setting.
        values._colorSchemeContrast = colorSchemeContrast
        return values
    }
}

/// Behavior tests for the pure-AppKit sidebar cells: hover enforcement,
/// palette parity, and optimistic selection paint semantics.
@Suite
@MainActor
struct SidebarAppKitRowCellTests {
    fileprivate static var tableEnvironment: SidebarWorkspaceTableEnvironmentSnapshot {
        SidebarWorkspaceTableEnvironmentSnapshot(
            environment: .sidebarTableTestValues(colorScheme: .dark),
            globalFontMagnificationPercent: 100,
            lazyContractProbe: SidebarLazyContractProbe()
        )
    }

    private static func makeGroupHeaderModel(
        groupId: UUID,
        anchorWorkspaceId: UUID,
        isAnchorActive: Bool,
        shortcutHintText: String? = nil
    ) -> SidebarGroupHeaderRowModel {
        SidebarGroupHeaderRowModel(
            groupId: groupId, anchorWorkspaceId: anchorWorkspaceId,
            name: "for next version stuff", iconSymbol: "folder", tintHex: nil,
            isCollapsed: false, isPinned: false,
            isAnchorActive: isAnchorActive,
            isMultiSelected: false,
            multiSelectionBackgroundStyle: .clear,
            memberCount: 1, anchorUnreadCount: 0,
            canMarkRead: false, canMarkUnread: true, hasLatestNotifications: false,
            canMarkAllRead: false, canMarkAllUnread: true,
            shortcutHintText: shortcutHintText, shortcutHintXOffset: 0, shortcutHintYOffset: 0,
            fontScale: 1, globalFontMagnificationPercent: 100, cwdContextMenuItems: [],
            rowSpacing: 2, isFirstRow: true, isBeingDragged: false,
            topDropIndicatorVisible: false, bottomDropIndicatorVisible: false,
            colorSchemeIsDark: true
        )
    }

    private static func makeSnapshot(
        title: String = "Workspace",
        customDescription: String? = nil,
        isPinned: Bool = false,
        metadataEntries: [SidebarStatusEntry] = [],
        progress: SidebarProgressState? = nil,
        checklistItems: [WorkspaceChecklistItem] = []
    ) -> SidebarWorkspaceSnapshotBuilder.Snapshot {
        let completedCount = checklistItems.count { $0.state == .completed }
        let firstUncheckedText = checklistItems.first { $0.state != .completed }?.text
        return SidebarWorkspaceSnapshotBuilder.Snapshot(
            presentationKey: SidebarWorkspaceSnapshotFactory.presentationKey(
                settings: SidebarTabItemSettingsSnapshot(defaults: UserDefaults(suiteName: UUID().uuidString)!),
                showsAgentActivity: false
            ),
            title: title,
            customDescription: customDescription,
            isPinned: isPinned,
            customColorHex: nil,
            remoteWorkspaceSidebarText: nil,
            remoteConnectionStatusText: "",
            remoteStateHelpText: "",
            showsRemoteReconnectAffordance: false,
            copyableSidebarSSHError: nil,
            latestConversationMessage: nil,
            metadataEntries: metadataEntries,
            metadataBlocks: [],
            latestLog: nil,
            progress: progress,
            activeCodingAgentCount: 0,
            compactGitBranchSummaryText: nil,
            compactDirectoryCandidates: [],
            compactBranchDirectoryCandidates: [],
            branchDirectoryLines: [],
            branchLinesContainBranch: false,
            pullRequestRows: [],
            listeningPorts: [],
            finderDirectoryPath: nil,
            mediaActivity: BrowserMediaActivity(),
            taskStatus: nil,
            todoStatusMenuModel: nil,
            hasManualTaskStatus: false,
            checklistItems: checklistItems,
            checklistCompletedCount: completedCount,
            checklistTotalCount: checklistItems.count,
            checklistFirstUncheckedText: firstUncheckedText
        )
    }

    fileprivate static func makeModel(
        workspaceId: UUID = UUID(),
        isActive: Bool = false,
        isPinned: Bool = false,
        canClose: Bool = true,
        settings: SidebarTabItemSettingsSnapshot? = nil,
        customDescription: String? = nil,
        metadataEntries: [SidebarStatusEntry] = [],
        progress: SidebarProgressState? = nil,
        shortcutHintText: String? = nil,
        checklistItems: [WorkspaceChecklistItem] = []
    ) -> SidebarWorkspaceRowModel {
        let resolvedSettings = settings
            ?? SidebarTabItemSettingsSnapshot(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        return SidebarWorkspaceRowModel(
            workspaceId: workspaceId,
            index: 0,
            snapshot: makeSnapshot(
                customDescription: customDescription,
                isPinned: isPinned,
                metadataEntries: metadataEntries,
                progress: progress,
                checklistItems: checklistItems
            ),
            settings: resolvedSettings,
            isActive: isActive,
            isMultiSelected: false,
            hasUserCustomTitle: false,
            canCloseWorkspace: canClose,
            accessibilityWorkspaceCount: 1,
            unreadCount: 0,
            latestNotificationText: nil,
            showsAgentActivity: resolvedSettings.details.showAgentActivity,
            rowSpacing: 8,
            isBeingDragged: false,
            topDropIndicatorVisible: false,
            bottomDropIndicatorVisible: false,
            isGrouped: false,
            isFirstRow: true,
            shortcutHintText: shortcutHintText,
            showsShortcutHints: shortcutHintText != nil,
            globalFontMagnificationPercent: 100,
            isChecklistExpanded: false,
            checklistAddFieldActivationToken: 0,
            isChecklistPopoverPresented: false,
            editingChecklistItemId: nil,
            todoControlsEnabled: false,
            isMetadataExpanded: false,
            isMarkdownExpanded: false
        )
    }

    private static func makeSwiftUIRow(
        settings: SidebarTabItemSettingsSnapshot
    ) -> SidebarWorkspaceRowSnapshot {
        SidebarWorkspaceRowSnapshot(
            workspaceId: UUID(),
            groupId: nil,
            index: 0,
            workspaceCount: 1,
            workspace: makeSnapshot(),
            isActive: false,
            isMultiSelected: false,
            hasUserCustomTitle: false,
            hasCustomTitle: false,
            hasCustomDescription: false,
            customTitle: nil,
            workspaceShortcutDigit: nil,
            workspaceShortcutModifierSymbol: "⌘",
            canCloseWorkspace: true,
            unreadCount: 0,
            latestNotificationText: nil,
            showsAgentActivity: settings.details.showAgentActivity,
            rowSpacing: 8,
            showsModifierShortcutHints: false,
            isPointerHovering: false,
            isBeingDragged: false,
            topDropIndicatorVisible: false,
            bottomDropIndicatorVisible: false,
            isBonsplitWorkspaceDropActive: false,
            settings: settings,
            isChecklistExpanded: false,
            checklistAddFieldActivationToken: 0,
            isChecklistPopoverPresented: false,
            contextMenu: SidebarWorkspaceContextMenuSnapshot(
                targetWorkspaceIds: [],
                remoteTargetWorkspaceIds: [],
                allRemoteTargetsConnecting: false,
                allRemoteTargetsDisconnected: false,
                pinState: nil,
                groupMenuSnapshot: WorkspaceGroupMenuSnapshot(items: []),
                canCreateEmptyGroup: true,
                eligibleGroupTargetIds: [],
                allEligibleTargetsGroupId: nil,
                hasGroupedEligibleTarget: false,
                todoStatusLanes: [],
                canMarkRead: false,
                canMarkUnread: false,
                hasLatestNotification: false,
                notifications: []
            )
        )
    }

    private static func makeDefaults() -> UserDefaults {
        UserDefaults(suiteName: "SidebarAppKitRowCellTests.\(UUID().uuidString)")!
    }

    private static func makeActions(
        model: SidebarWorkspaceRowModel,
        tab: Workspace? = nil,
        tabManager: TabManager? = nil,
        onOpenWorkspaceDescriptionURL: @escaping (URL) -> Void = { _ in },
        onOpenStatusURL: @escaping (URL) -> Void = { _ in }
    ) -> SidebarAppKitRowActions {
        let resolvedTab = tab ?? Workspace()
        let commands = SidebarWorkspaceRowCommands(
            tab: resolvedTab,
            tabManager: tabManager,
            notificationStore: nil,
            index: model.index,
            contextMenuWorkspaceIds: [model.workspaceId],
            remoteContextMenuWorkspaceIds: [],
            allRemoteContextMenuTargetsConnecting: false,
            allRemoteContextMenuTargetsDisconnected: false,
            contextMenuPinState: nil,
            workspaceGroupMenuSnapshot: WorkspaceGroupMenuSnapshot(items: []),
            colorScheme: .dark,
            refreshSnapshot: {},
            readSelectedTabIds: { [] },
            writeSelectedTabIds: { _ in },
            readLastSelectionIndex: { nil },
            writeLastSelectionIndex: { _ in },
            setSelectionToTabs: {},
            snapshotProvider: { nil }
        )
        return SidebarAppKitRowActions(
            commands: commands,
            onOpenStatusURL: onOpenStatusURL,
            onOpenWorkspaceDescriptionURL: onOpenWorkspaceDescriptionURL,
            onOpenPullRequest: { _ in },
            onOpenPort: { _ in },
            onToggleChecklistExpansion: {},
            onToggleMetadataExpansion: {},
            onToggleMarkdownExpansion: {},
            onConsumeChecklistAddFieldActivation: {},
            checklistSetItemState: { _, _ in },
            checklistRemoveItem: { _ in },
            checklistAddItem: { _ in },
            checklistEditItem: { _, _ in },
            checklistMoveItem: { _, _ in },
            checklistOpenPane: {},
            checklistAddAttachments: { _ in },
            checklistRemoveAttachment: { _, _ in },
            checklistOpenAttachments: { _, _ in },
            onChecklistPopoverPresentedChange: { _ in },
            onBeginChecklistItemEdit: { _ in },
            onEndChecklistItemEdit: { _ in },
            applyTodoStatus: { _ in },
            hideTodoStatus: {},
            commitRename: { _ in }
        )
    }

    fileprivate static func configuredCell(
        model: SidebarWorkspaceRowModel,
        environment: SidebarWorkspaceTableEnvironmentSnapshot? = nil,
        tab: Workspace? = nil,
        tabManager: TabManager? = nil,
        onOpenWorkspaceDescriptionURL: @escaping (URL) -> Void = { _ in },
        onOpenStatusURL: @escaping (URL) -> Void = { _ in }
    ) -> SidebarWorkspaceRowTableCellView {
        let cell = SidebarWorkspaceRowTableCellView()
        cell.configure(
            model: model,
            environment: environment ?? tableEnvironment,
            actions: makeActions(
                model: model,
                tab: tab,
                tabManager: tabManager,
                onOpenWorkspaceDescriptionURL: onOpenWorkspaceDescriptionURL,
                onOpenStatusURL: onOpenStatusURL
            ),
            isPointerHovering: false,
            contextMenuDidOpen: {},
            contextMenuDidClose: {}
        )
        return cell
    }

    fileprivate static func descendants(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap { descendants(of: $0) }
    }

    private static func resolvedTextColor(
        in view: NSView,
        matching text: String
    ) throws -> NSColor {
        let field = try #require(
            descendants(of: view)
                .compactMap { $0 as? NSTextField }
                .first { $0.stringValue == text }
        )
        var resolvedColor: NSColor?
        field.effectiveAppearance.performAsCurrentDrawingAppearance {
            resolvedColor = field.textColor?.usingColorSpace(.sRGB)
        }
        return try #require(resolvedColor)
    }

    private static func appKitColor(from resolved: Color.Resolved) throws -> NSColor {
        let colorSpace = try #require(CGColorSpace(name: CGColorSpace.extendedLinearSRGB))
        let components = [
            CGFloat(resolved.linearRed),
            CGFloat(resolved.linearGreen),
            CGFloat(resolved.linearBlue),
            CGFloat(resolved.opacity),
        ]
        let cgColor = try #require(CGColor(colorSpace: colorSpace, components: components))
        let color = try #require(NSColor(cgColor: cgColor))
        return try #require(color.usingColorSpace(.sRGB))
    }

    private static func textView(in cell: SidebarWorkspaceRowTableCellView, linkedTo url: URL) -> SidebarRowTextView? {
        descendants(of: cell)
            .compactMap { $0 as? SidebarRowTextView }
            .first { view in
                attributedString(view.attributedStringValue, containsLink: url)
            }
    }

    private static func attributedString(_ attributedString: NSAttributedString, containsLink url: URL) -> Bool {
        guard attributedString.length > 0 else { return false }
        var location = 0
        while location < attributedString.length {
            var range = NSRange(location: 0, length: 0)
            let value = attributedString.attribute(.sidebarRowLink, at: location, effectiveRange: &range)
            if linkURL(from: value) == url {
                return true
            }
            location = max(location + 1, range.location + max(range.length, 1))
        }
        return false
    }

    private static func linkURL(from value: Any?) -> URL? {
        switch value {
        case let url as URL:
            return url
        case let url as NSURL:
            return url as URL
        case let string as String:
            return URL(string: string)
        default:
            return nil
        }
    }

    @discardableResult
    private static func layoutCell(_ cell: SidebarWorkspaceRowTableCellView, model: SidebarWorkspaceRowModel, width: CGFloat = 440) -> NSWindow {
        let height = cell.layoutContent(model: model, width: width, apply: false)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        let host = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        window.contentView = host
        cell.frame = host.bounds
        host.addSubview(cell)
        cell.needsLayout = true
        cell.layoutSubtreeIfNeeded()
        return window
    }

    @discardableResult
    private static func click(_ view: NSView, in window: NSWindow, at point: NSPoint) throws -> NSView {
        #expect(view.window === window)
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        let windowPoint = view.convert(point, to: nil)
        let windowNumber = window.windowNumber
        let timestamp = ProcessInfo.processInfo.systemUptime
        let down = try #require(NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: windowPoint,
            modifierFlags: [],
            timestamp: timestamp,
            windowNumber: windowNumber,
            context: nil,
            eventNumber: 1,
            clickCount: 1,
            pressure: 1
        ))
        let up = try #require(NSEvent.mouseEvent(
            with: .leftMouseUp,
            location: windowPoint,
            modifierFlags: [],
            timestamp: timestamp + 0.01,
            windowNumber: windowNumber,
            context: nil,
            eventNumber: 2,
            clickCount: 1,
            pressure: 0
        ))
        let hitView = try #require(window.contentView?.hitTest(windowPoint))
        window.sendEvent(down)
        window.sendEvent(up)
        return hitView
    }

    private static let linkedMetadataMarkdown =
        "[acme/widgets](https://github.com/acme/widgets/tree/branch) • " +
        "[PR#123](https://github.com/acme/widgets/pull/123) • " +
        "[dev-7](http://127.0.0.1:53000/workspaces/7)"

    private static let linkedMetadataURLs = [
        URL(string: "https://github.com/acme/widgets/tree/branch")!,
        URL(string: "https://github.com/acme/widgets/pull/123")!,
        URL(string: "http://127.0.0.1:53000/workspaces/7")!,
    ]

    private static func links(in textView: NSTextView) -> [(range: NSRange, url: URL)] {
        var links: [(range: NSRange, url: URL)] = []
        let fullRange = NSRange(location: 0, length: textView.textStorage?.length ?? 0)
        textView.textStorage?.enumerateAttribute(.link, in: fullRange) { value, range, _ in
            let url: URL?
            if let value = value as? URL {
                url = value
            } else if let value = value as? String {
                url = URL(string: value)
            } else {
                url = nil
            }
            if let url {
                links.append((range, url))
            }
        }
        return links
    }

    @discardableResult
    private static func activateLink(
        _ link: (range: NSRange, url: URL),
        in textView: NSTextView
    ) -> Bool {
        textView.delegate?.textView?(
            textView,
            clickedOnLink: link.url,
            at: link.range.location
        ) ?? false
    }

    private static func hitTestPoint(
        forCharacterAt characterIndex: Int,
        in textView: NSTextView
    ) throws -> NSPoint {
        let layoutManager = try #require(textView.layoutManager)
        let textContainer = try #require(textView.textContainer)
        layoutManager.ensureLayout(for: textContainer)
        let glyphRange = layoutManager.glyphRange(
            forCharacterRange: NSRange(location: characterIndex, length: 1),
            actualCharacterRange: nil
        )
        let glyphBounds = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
        let localPoint = NSPoint(
            x: textView.textContainerOrigin.x + glyphBounds.midX,
            y: textView.textContainerOrigin.y + glyphBounds.midY
        )
        return textView.convert(localPoint, to: textView.superview)
    }

    @Test(arguments: zip(["codex", "claude_code"], ["Running", "Needs input"]))
    func metadataStatusTextOmitsRawAgentKey(_ key: String, _ status: String) throws {
        let model = Self.makeModel()
        let row = SidebarRowIconTextLine()

        row.configureMetadataEntry(
            SidebarStatusEntry(key: key, value: status, icon: "bolt.fill"),
            model: model,
            color: .labelColor,
            onOpenURL: { _ in }
        )

        let textView = try #require(row.subviews.compactMap { $0 as? SidebarRowTextView }.first)
        #expect(textView.stringValue == status)
        #expect(!textView.stringValue.contains(key))
    }

    @Test
    func metadataStatusURLRendersAnActionBoundToItsDestination() throws {
        let url = try #require(URL(string: "https://example.com/issues/8520"))
        let model = Self.makeModel(
            metadataEntries: [SidebarStatusEntry(key: "repro_link", value: "click me", url: url)]
        )
        var openedURL: URL?
        let cell = Self.configuredCell(model: model, onOpenStatusURL: { openedURL = $0 })
        _ = Self.layoutCell(cell, model: model)
        let buttons = Self.descendants(of: cell).compactMap { $0 as? NSButton }

        let link = try #require(buttons.first { $0.toolTip == url.absoluteString })
        let action = try #require(link.action)
        let target = try #require(link.target)
        #expect(link.isEnabled)
        #expect(NSApp.sendAction(action, to: target, from: link))
        #expect(openedURL == url)
    }

    @Test(arguments: [
        "http://example.com/page",
        "https://linear.app/attendu/issue/ATD-366",
    ])
    func workspaceDescriptionURLClickOpensLinkWithoutEnablingTextSelection(
        _ urlString: String
    ) throws {
        let url = try #require(URL(string: urlString))
        let model = Self.makeModel(customDescription: url.absoluteString)
        var openedURL: URL?
        let cell = Self.configuredCell(
            model: model,
            onOpenWorkspaceDescriptionURL: { openedURL = $0 }
        )
        let window = Self.layoutCell(cell, model: model)
        let textView = try #require(Self.textView(in: cell, linkedTo: url))

        #expect(!textView.isSelectable)

        let hitView = try Self.click(
            textView,
            in: window,
            at: NSPoint(x: min(16, textView.bounds.width / 2), y: textView.bounds.midY)
        )

        #expect(hitView === textView)
        #expect(openedURL == url)
        #expect(!textView.isSelectable)
    }

    @Test
    func workspaceDescriptionURLClickDoesNotExpandIntoAdjacentPlainText() throws {
        let url = try #require(URL(string: "https://linear.app/attendu/issue/ATD-366"))
        let prefix = "See "
        let model = Self.makeModel(customDescription: "\(prefix)\(url.absoluteString)")
        var openedURL: URL?
        let cell = Self.configuredCell(
            model: model,
            onOpenWorkspaceDescriptionURL: { openedURL = $0 }
        )
        let window = Self.layoutCell(cell, model: model)
        let textView = try #require(Self.textView(in: cell, linkedTo: url))
        let font = try #require(textView.attributedStringValue.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        let prefixWidth = (prefix as NSString).size(withAttributes: [.font: font]).width

        let hitView = try Self.click(
            textView,
            in: window,
            at: NSPoint(x: max(0, prefixWidth - 0.5), y: textView.bounds.midY)
        )

        #expect(hitView !== textView)
        #expect(openedURL == nil)
    }

    @Test
    func workspaceDescriptionURLClickOpensWrappedTopLineLink() throws {
        let url = try #require(URL(string: "https://linear.app/attendu/issue/ATD-366"))
        let model = Self.makeModel(customDescription: "\(url.absoluteString) plain text after the link wraps below")
        var openedURL: URL?
        let cell = Self.configuredCell(
            model: model,
            onOpenWorkspaceDescriptionURL: { openedURL = $0 }
        )
        let window = Self.layoutCell(cell, model: model, width: 240)
        let textView = try #require(Self.textView(in: cell, linkedTo: url))
        let font = try #require(textView.attributedStringValue.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)

        #expect(textView.bounds.height > font.ascender - font.descender)
        #expect(textView.isFlipped)

        let hitView = try Self.click(
            textView,
            in: window,
            at: NSPoint(x: min(16, textView.bounds.width / 2), y: ceil((font.ascender - font.descender) / 2))
        )

        #expect(hitView === textView)
        #expect(openedURL == url)
    }

    @Test(arguments: ["file:///tmp/not-ok.command", "x-custom://open"])
    func workspaceDescriptionUnsafeURLClickIsIgnored(_ urlString: String) throws {
        let url = try #require(URL(string: urlString))
        let model = Self.makeModel(customDescription: "[launch](\(url.absoluteString))")
        var openedURL: URL?
        let cell = Self.configuredCell(
            model: model,
            onOpenWorkspaceDescriptionURL: { openedURL = $0 }
        )
        let window = Self.layoutCell(cell, model: model)
        let textView = try #require(Self.textView(in: cell, linkedTo: url))

        let hitView = try Self.click(
            textView,
            in: window,
            at: NSPoint(x: min(12, textView.bounds.width / 2), y: textView.bounds.midY)
        )

        #expect(hitView !== textView)
        #expect(openedURL == nil)
    }

    @Test
    func markdownMetadataRendersLabelsAndIndependentLinks() throws {
        let model = Self.makeModel(
            metadataEntries: [
                SidebarStatusEntry(
                    key: "repo_workspace",
                    value: Self.linkedMetadataMarkdown,
                    format: .markdown
                ),
            ]
        )
        let cell = Self.configuredCell(model: model)
        let textView = try #require(
            Self.descendants(of: cell)
                .compactMap { $0 as? NSTextView }
                .first { !$0.isHidden }
        )

        #expect(textView.string == "acme/widgets • PR#123 • dev-7")
        #expect(!textView.string.contains("["))
        #expect(Self.links(in: textView).map(\.url) == Self.linkedMetadataURLs)
    }

    @Test
    func markdownMetadataDoesNotCaptureKeyboardFocus() throws {
        let model = Self.makeModel(
            metadataEntries: [
                SidebarStatusEntry(
                    key: "repo_workspace",
                    value: Self.linkedMetadataMarkdown,
                    format: .markdown
                ),
            ]
        )
        let cell = Self.configuredCell(model: model)
        let textView = try #require(
            Self.descendants(of: cell)
                .compactMap { $0 as? NSTextView }
                .first { !$0.isHidden }
        )

        #expect(!textView.acceptsFirstResponder)
    }

    @Test
    func markdownMetadataExplicitURLPreservesFormattedRowAction() throws {
        let explicitURL = try #require(URL(string: "https://example.com/explicit"))
        let model = Self.makeModel(
            metadataEntries: [
                SidebarStatusEntry(
                    key: "repo_workspace",
                    value: Self.linkedMetadataMarkdown,
                    url: explicitURL,
                    format: .markdown
                ),
            ]
        )
        var openedURL: URL?
        let cell = Self.configuredCell(model: model) { openedURL = $0 }
        let textView = try #require(
            Self.descendants(of: cell)
                .compactMap { $0 as? NSTextView }
                .first { !$0.isHidden }
        )

        #expect(textView.string == "acme/widgets • PR#123 • dev-7")
        let links = Self.links(in: textView)
        #expect(links.count == 1)
        let link = try #require(links.first)
        #expect(link.range == NSRange(location: 0, length: textView.string.utf16.count))
        #expect(link.url == explicitURL)
        #expect(Self.activateLink(link, in: textView))
        #expect(openedURL == explicitURL)
    }

    @Test
    func markdownMetadataOnlyCapturesClicksOnLinkGlyphs() throws {
        let row = SidebarRowIconTextLine()
        row.configureMetadataEntry(
            SidebarStatusEntry(
                key: "links",
                value: "plain [link](https://example.com)",
                format: .markdown
            ),
            model: Self.makeModel(),
            color: .secondaryLabelColor,
            onOpenURL: { _ in }
        )

        let height = row.measuredHeight(width: 220)
        row.frame = NSRect(x: 0, y: 0, width: 220, height: height)
        row.layoutSubtreeIfNeeded()
        let textView = try #require(
            Self.descendants(of: row)
                .compactMap { $0 as? NSTextView }
                .first { !$0.isHidden }
        )
        let links = Self.links(in: textView)
        #expect(links.count == 1)
        let link = try #require(links.first)
        let plainPoint = try Self.hitTestPoint(forCharacterAt: 0, in: textView)
        let linkPoint = try Self.hitTestPoint(forCharacterAt: link.range.location, in: textView)

        #expect(textView.hitTest(plainPoint) == nil)
        #expect(textView.hitTest(linkPoint) === textView)
    }

    @Test
    func markdownMetadataLinkSelectionPrecedesEachOpen() throws {
        let manager = TabManager()
        let originalWorkspaceId = try #require(manager.selectedTabId)
        let targetWorkspace = manager.addWorkspace(select: false)
        let model = Self.makeModel(
            workspaceId: targetWorkspace.id,
            metadataEntries: [
                SidebarStatusEntry(
                    key: "repo_workspace",
                    value: Self.linkedMetadataMarkdown,
                    format: .markdown
                ),
            ]
        )
        var opened: [URL] = []
        var wasSelectedBeforeOpen: [Bool] = []
        let cell = Self.configuredCell(
            model: model,
            tab: targetWorkspace,
            tabManager: manager
        ) { url in
            wasSelectedBeforeOpen.append(manager.selectedTabId == targetWorkspace.id)
            opened.append(url)
        }
        let textView = try #require(
            Self.descendants(of: cell)
                .compactMap { $0 as? NSTextView }
                .first { !$0.isHidden }
        )

        #expect(manager.selectedTabId == originalWorkspaceId)
        for link in Self.links(in: textView) {
            #expect(Self.activateLink(link, in: textView))
        }
        #expect(opened == Self.linkedMetadataURLs)
        #expect(wasSelectedBeforeOpen == [true, true, true])
    }

    @Test
    func markdownMetadataLeavesUnsafeSchemeLabelInert() throws {
        let markdown = "[safe](https://example.com) • [unsafe](javascript:alert(1))"
        let model = Self.makeModel(
            metadataEntries: [
                SidebarStatusEntry(key: "links", value: markdown, format: .markdown),
            ]
        )
        let cell = Self.configuredCell(model: model)
        let textView = try #require(
            Self.descendants(of: cell)
                .compactMap { $0 as? NSTextView }
                .first { !$0.isHidden }
        )

        #expect(textView.string == "safe • unsafe")
        #expect(Self.links(in: textView).map(\.url) == [URL(string: "https://example.com")!])
    }

    @Test
    func markdownMetadataStaysSingleLineAndHeightStable() throws {
        let markdown = (1...20)
            .map { "[workspace-\($0)](https://example.com/workspaces/\($0))" }
            .joined(separator: " • ")
        let row = SidebarRowIconTextLine()
        row.configureMetadataEntry(
            SidebarStatusEntry(key: "links", value: markdown, format: .markdown),
            model: Self.makeModel(),
            color: .secondaryLabelColor,
            onOpenURL: { _ in }
        )

        let beforeLayout = row.measuredHeight(width: 120)
        row.frame = NSRect(x: 0, y: 0, width: 120, height: beforeLayout)
        row.layoutSubtreeIfNeeded()
        let afterLayout = row.measuredHeight(width: 120)
        let textView = try #require(
            Self.descendants(of: row)
                .compactMap { $0 as? NSTextView }
                .first { !$0.isHidden }
        )

        #expect(textView.textContainer?.maximumNumberOfLines == 1)
        #expect(textView.textContainer?.lineBreakMode == .byTruncatingTail)
        #expect(afterLayout == beforeLayout)
    }

    @Test
    func markdownMetadataTextContainerHasDrawableHeight() throws {
        let row = SidebarRowIconTextLine()
        row.configureMetadataEntry(
            SidebarStatusEntry(
                key: "repo_workspace",
                value: Self.linkedMetadataMarkdown,
                format: .markdown
            ),
            model: Self.makeModel(),
            color: .secondaryLabelColor,
            onOpenURL: { _ in }
        )

        let height = row.measuredHeight(width: 220)
        row.frame = NSRect(x: 0, y: 0, width: 220, height: height)
        row.layoutSubtreeIfNeeded()
        let textView = try #require(
            Self.descendants(of: row)
                .compactMap { $0 as? NSTextView }
                .first { !$0.isHidden }
        )
        let textContainer = try #require(textView.textContainer)
        let layoutManager = try #require(textView.layoutManager)

        layoutManager.ensureLayout(for: textContainer)
        #expect(textContainer.containerSize.height > 0)
        #expect(layoutManager.usedRect(for: textContainer).height > 0)
    }

    @Test
    func metadataRowReconfigurationClearsMutuallyExclusiveState() throws {
        let row = SidebarRowIconTextLine()
        let model = Self.makeModel()
        var firstOpened = 0
        row.configureMetadataEntry(
            SidebarStatusEntry(
                key: "repo_workspace",
                value: Self.linkedMetadataMarkdown,
                format: .markdown
            ),
            model: model,
            color: .secondaryLabelColor,
            onOpenURL: { _ in firstOpened += 1 }
        )
        let markdownView = try #require(
            Self.descendants(of: row).compactMap { $0 as? NSTextView }.first
        )
        let staleLink = try #require(Self.links(in: markdownView).first)

        row.configureMetadataEntry(
            SidebarStatusEntry(key: "plain", value: "plain value"),
            model: model,
            color: .secondaryLabelColor,
            onOpenURL: { _ in }
        )
        #expect(markdownView.isHidden)
        #expect(markdownView.string.isEmpty)
        #expect(Self.links(in: markdownView).isEmpty)
        #expect(!Self.activateLink(staleLink, in: markdownView))
        #expect(firstOpened == 0)

        let explicitURL = try #require(URL(string: "https://example.com/plain"))
        row.configureMetadataEntry(
            SidebarStatusEntry(key: "plain-link", value: "plain link", url: explicitURL),
            model: model,
            color: .secondaryLabelColor,
            onOpenURL: { _ in }
        )
        #expect(markdownView.isHidden)
        #expect(markdownView.string.isEmpty)

        var secondOpened: URL?
        row.configureMetadataEntry(
            SidebarStatusEntry(
                key: "markdown-again",
                value: "[again](https://example.com/again)",
                format: .markdown
            ),
            model: model,
            color: .secondaryLabelColor,
            onOpenURL: { secondOpened = $0 }
        )
        let currentLink = try #require(Self.links(in: markdownView).first)
        #expect(!markdownView.isHidden)
        #expect(markdownView.string == "again")
        #expect(Self.activateLink(currentLink, in: markdownView))
        #expect(secondOpened == URL(string: "https://example.com/again"))
        #expect(firstOpened == 0)
    }

    @Test
    func hoverEnforcementShortCircuitsWhenAlreadyCorrect() {
        let model = Self.makeModel()
        let cell = Self.configuredCell(model: model)
        var applies = 0
        cell.applyModelProbeForTesting = { _ in applies += 1 }

        cell.enforcePointerHovering(false)
        #expect(applies == 0)

        cell.enforcePointerHovering(true)
        #expect(applies == 1)

        cell.enforcePointerHovering(true)
        #expect(applies == 1)
    }

    @Test
    func shortcutHintPillKeepsVisibleDuringFadeOut() async throws {
        let pill = SidebarShortcutHintPillView(reduceMotionProvider: { false })
        pill.configure(
            text: "⌘1", fontSize: 10, emphasis: 1, textColor: .labelColor
        )

        pill.configure(
            text: nil, fontSize: 10, emphasis: 1, textColor: .labelColor
        )

        #expect(!pill.isHidden)
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(1)
        while !pill.isHidden, clock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(pill.isHidden)
    }

    @Test
    func shortcutHintPillUsesExplicitOpacityAnimationInsideDisabledTransaction() {
        let pill = SidebarShortcutHintPillView(reduceMotionProvider: { false })

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        pill.configure(
            text: "⌘1", fontSize: 9, emphasis: 1, textColor: .labelColor
        )
        CATransaction.commit()

        let visibilityAnimation = pill.layer?.animation(forKey: "shortcutHintVisibility")
        #expect(visibilityAnimation != nil)
    }

    @Test
    func shortcutHintPillAppliesReducedMotionVisibilityImmediately() {
        let pill = SidebarShortcutHintPillView(reduceMotionProvider: { true })

        pill.configure(
            text: "⌘1", fontSize: 9, emphasis: 1, textColor: .labelColor
        )
        #expect(!pill.isHidden)
        #expect(pill.layer?.opacity == 1)
        #expect((pill.layer?.animationKeys() ?? []).isEmpty)

        pill.configure(
            text: nil, fontSize: 9, emphasis: 1, textColor: .labelColor
        )
        #expect(pill.isHidden)
        #expect(pill.layer?.opacity == 0)
        #expect((pill.layer?.animationKeys() ?? []).isEmpty)
    }

    @Test
    func reusedWorkspaceCellClearsPreviousShortcutHintImmediately() throws {
        let workspaceId = UUID()
        let first = Self.makeModel(workspaceId: workspaceId, shortcutHintText: "⌘1")
        let cell = Self.configuredCell(model: first)
        let pill = try #require(Self.descendants(of: cell).compactMap { $0 as? SidebarShortcutHintPillView }.first)

        cell.prepareForReuse()
        let replacement = Self.makeModel(workspaceId: workspaceId)
        cell.configure(
            model: replacement,
            environment: Self.tableEnvironment,
            actions: Self.makeActions(model: replacement),
            isPointerHovering: false,
            contextMenuDidOpen: {},
            contextMenuDidClose: {}
        )

        #expect(pill.isHidden)
        #expect((pill.layer?.animationKeys() ?? []).isEmpty)
    }

    @Test
    func shortcutHintPillNeverInterceptsPointerEvents() {
        let pill = SidebarShortcutHintPillView()
        pill.frame = NSRect(x: 0, y: 0, width: 32, height: 18)
        pill.configure(
            text: "⌘1", fontSize: 9, emphasis: 1, textColor: .labelColor
        )
        pill.layoutSubtreeIfNeeded()

        #expect(pill.hitTest(NSPoint(x: 16, y: 9)) == nil)
    }

    @Test
    func shortcutHintPillUsesCompactHorizontalPadding() throws {
        let pill = SidebarShortcutHintPillView()
        pill.configure(
            text: "⌘1", fontSize: 9, emphasis: 1, textColor: .labelColor
        )
        let label = try #require(Self.descendants(of: pill).compactMap { $0 as? NSTextField }.first)

        #expect(pill.fittingPillSize().width == ceil(label.sidebarNaturalCellSize.width) + 8)
    }

    @Test
    func shortcutHintPillClipsMaterialToItsCapsule() throws {
        let pill = SidebarShortcutHintPillView()
        pill.frame = NSRect(x: 0, y: 0, width: 36, height: 18)
        pill.configure(
            text: "⌘1", fontSize: 10, emphasis: 1, textColor: .labelColor
        )
        pill.layoutSubtreeIfNeeded()

        let material = try #require(Self.descendants(of: pill).compactMap { $0 as? NSVisualEffectView }.first)
        #expect(material.layer?.masksToBounds == true)
        #expect(material.layer?.cornerRadius == pill.bounds.height / 2)
    }

    @Test
    func optimisticSelectionPaintsFlippedModelButKeepsAuthoritativeState() {
        let model = Self.makeModel(isActive: false)
        let cell = Self.configuredCell(model: model)
        var appliedActive: [Bool] = []
        cell.applyModelProbeForTesting = { appliedActive.append($0.isActive) }

        cell.showOptimisticSelectionHighlight()
        // Full selected treatment painted from a flipped copy...
        #expect(appliedActive == [true])
        // ...while the stored model stays authoritative (not selected).
        #expect(cell.currentModelForMeasurement?.isActive == false)
    }

    @Test
    func optimisticDeselectionOnlyActsOnSelectedRows() {
        let inactive = Self.makeModel(isActive: false)
        let cell = Self.configuredCell(model: inactive)
        var applies = 0
        cell.applyModelProbeForTesting = { _ in applies += 1 }

        cell.showOptimisticDeselection()
        #expect(applies == 0)

        let active = Self.makeModel(isActive: true)
        let activeCell = Self.configuredCell(model: active)
        var activeApplied: [Bool] = []
        activeCell.applyModelProbeForTesting = { activeApplied.append($0.isActive) }
        activeCell.showOptimisticDeselection()
        #expect(activeApplied == [false])
        #expect(activeCell.currentModelForMeasurement?.isActive == true)
    }

    @Test
    func groupHeaderTitleMatchesDefaultWorkspaceTitleAcrossSelectionInDarkMode() throws {
        let appearance = try #require(NSAppearance(named: .darkAqua))
        let workspaceCell = Self.configuredCell(model: Self.makeModel())
        let headerCell = SidebarGroupHeaderTableCellView()
        let groupId = UUID()
        let anchorWorkspaceId = UUID()
        let inactiveHeader = Self.makeGroupHeaderModel(
            groupId: groupId,
            anchorWorkspaceId: anchorWorkspaceId,
            isAnchorActive: false
        )
        let activeHeader = Self.makeGroupHeaderModel(
            groupId: groupId,
            anchorWorkspaceId: anchorWorkspaceId,
            isAnchorActive: true
        )
        headerCell.configurePresentation(
            model: inactiveHeader,
            environment: Self.tableEnvironment
        )

        let root = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 120))
        root.addSubview(workspaceCell)
        root.addSubview(headerCell)
        let window = NSWindow(
            contentRect: root.bounds,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.appearance = appearance
        window.contentView = root
        defer {
            window.contentView = nil
            window.close()
        }

        let workspaceTitleColor = try Self.resolvedTextColor(
            in: workspaceCell,
            matching: "Workspace"
        )
        let inactiveHeaderColor = try Self.resolvedTextColor(
            in: headerCell,
            matching: inactiveHeader.name
        )

        headerCell.showOptimisticAnchorActive()
        let optimisticActiveHeaderColor = try Self.resolvedTextColor(
            in: headerCell,
            matching: inactiveHeader.name
        )

        headerCell.configurePresentation(
            model: activeHeader,
            environment: Self.tableEnvironment
        )
        let activeHeaderColor = try Self.resolvedTextColor(
            in: headerCell,
            matching: activeHeader.name
        )

        headerCell.showOptimisticDeselection()
        let optimisticInactiveHeaderColor = try Self.resolvedTextColor(
            in: headerCell,
            matching: activeHeader.name
        )

        #expect(inactiveHeaderColor == workspaceTitleColor)
        #expect(optimisticActiveHeaderColor == workspaceTitleColor)
        #expect(activeHeaderColor == workspaceTitleColor)
        #expect(optimisticInactiveHeaderColor == workspaceTitleColor)
    }

    @Test
    func shortcutHintMaterialUsesTableAppearanceWhenBackingAppearanceDiffers() throws {
        let tableEnvironment = SidebarWorkspaceTableEnvironmentSnapshot(
            environment: .sidebarTableTestValues(colorScheme: .light),
            globalFontMagnificationPercent: 100,
            lazyContractProbe: SidebarLazyContractProbe()
        )
        let headerCell = SidebarGroupHeaderTableCellView()
        headerCell.configurePresentation(
            model: Self.makeGroupHeaderModel(
                groupId: UUID(),
                anchorWorkspaceId: UUID(),
                isAnchorActive: false,
                shortcutHintText: "⌘1"
            ),
            environment: tableEnvironment
        )
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 80))
        root.addSubview(headerCell)
        let window = NSWindow(
            contentRect: root.bounds,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.appearance = try #require(NSAppearance(named: .darkAqua))
        window.contentView = root
        defer {
            window.contentView = nil
            window.close()
        }

        let material = try #require(
            Self.descendants(of: headerCell)
                .compactMap { $0 as? NSVisualEffectView }
                .first
        )
        #expect(
            material.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .aqua,
            "The shortcut material must use the table's light appearance, not its dark backing window."
        )
    }

    @Test
    func shortcutHintUsesOpaqueFallbackForIncreasedContrastAppearanceMismatch() throws {
        let tableEnvironment = SidebarWorkspaceTableEnvironmentSnapshot(
            environment: .sidebarTableTestValues(
                colorScheme: .light,
                colorSchemeContrast: .increased
            ),
            globalFontMagnificationPercent: 100,
            lazyContractProbe: SidebarLazyContractProbe()
        )
        let headerCell = SidebarGroupHeaderTableCellView()
        headerCell.configurePresentation(
            model: Self.makeGroupHeaderModel(
                groupId: UUID(),
                anchorWorkspaceId: UUID(),
                isAnchorActive: false,
                shortcutHintText: "⌘1"
            ),
            environment: tableEnvironment
        )
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 80))
        root.addSubview(headerCell)
        let window = NSWindow(
            contentRect: root.bounds,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.appearance = try #require(NSAppearance(named: .darkAqua))
        window.contentView = root
        defer {
            window.contentView = nil
            window.close()
        }

        let material = try #require(
            Self.descendants(of: headerCell)
                .compactMap { $0 as? NSVisualEffectView }
                .first
        )
        let pill = try #require(material.superview as? SidebarShortcutHintPillView)
        let opaqueBackdrop = try #require(
            Self.descendants(of: pill).first { view in
                guard view !== material,
                      !view.isHidden,
                      let backgroundColor = view.layer?.backgroundColor,
                      let color = NSColor(cgColor: backgroundColor)?.usingColorSpace(.sRGB) else {
                    return false
                }
                return color.alphaComponent == 1
            }
        )
        let backgroundColor = try #require(opaqueBackdrop.layer?.backgroundColor)
        let fallbackColor = try #require(NSColor(cgColor: backgroundColor)?.usingColorSpace(.sRGB))
        let expectedColor = try #require(NSColor.white.usingColorSpace(.sRGB))

        #expect(material.appearance == nil)
        #expect(fallbackColor == expectedColor)
    }

    @Test
    func tablePaletteMatchesIncreasedContrastSwiftUISemantics() throws {
        let swiftUIEnvironment = EnvironmentValues.sidebarTableTestValues(
            colorScheme: .dark,
            colorSchemeContrast: .increased
        )

        let tableEnvironment = SidebarWorkspaceTableEnvironmentSnapshot(
            environment: swiftUIEnvironment,
            globalFontMagnificationPercent: 100,
            lazyContractProbe: SidebarLazyContractProbe()
        )
        let standardTableEnvironment = SidebarWorkspaceTableEnvironmentSnapshot(
            environment: .sidebarTableTestValues(colorScheme: .dark),
            globalFontMagnificationPercent: 100,
            lazyContractProbe: SidebarLazyContractProbe()
        )
        let expectedPrimary = try Self.appKitColor(
            from: Color.primary.resolve(in: swiftUIEnvironment)
        )
        let expectedSecondary = try Self.appKitColor(
            from: Color.secondary.resolve(in: swiftUIEnvironment)
        )
        let actualPrimary = try #require(tableEnvironment.primaryTextColor.usingColorSpace(.sRGB))
        let actualSecondary = try #require(tableEnvironment.secondaryTextColor.usingColorSpace(.sRGB))

        #expect(tableEnvironment.colorSchemeContrast == .increased)
        #expect(!tableEnvironment.hasEquivalentPresentation(to: standardTableEnvironment))
        #expect(actualPrimary == expectedPrimary)
        #expect(actualSecondary == expectedSecondary)

        let headerModel = Self.makeGroupHeaderModel(
            groupId: UUID(),
            anchorWorkspaceId: UUID(),
            isAnchorActive: false
        )
        let workspaceCell = Self.configuredCell(
            model: Self.makeModel(),
            environment: tableEnvironment
        )
        let headerCell = SidebarGroupHeaderTableCellView()
        headerCell.configurePresentation(model: headerModel, environment: tableEnvironment)
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 120))
        root.addSubview(workspaceCell)
        root.addSubview(headerCell)
        let window = NSWindow(
            contentRect: root.bounds,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = root
        defer {
            window.contentView = nil
            window.close()
        }

        let workspaceTitleColor = try Self.resolvedTextColor(in: workspaceCell, matching: "Workspace")
        let headerTitleColor = try Self.resolvedTextColor(in: headerCell, matching: headerModel.name)
        #expect(workspaceTitleColor == expectedPrimary)
        #expect(headerTitleColor == expectedPrimary)
    }

    @Test
    func checklistPaletteReconfiguresWhenContrastChanges() throws {
        let checklistText = "Verify contrast repaint"
        let model = Self.makeModel(
            checklistItems: [WorkspaceChecklistItem(text: checklistText)]
        )
        let standardSwiftUIEnvironment = EnvironmentValues.sidebarTableTestValues(
            colorScheme: .dark
        )
        let increasedSwiftUIEnvironment = EnvironmentValues.sidebarTableTestValues(
            colorScheme: .dark,
            colorSchemeContrast: .increased
        )
        let standardTableEnvironment = SidebarWorkspaceTableEnvironmentSnapshot(
            environment: standardSwiftUIEnvironment,
            globalFontMagnificationPercent: 100,
            lazyContractProbe: SidebarLazyContractProbe()
        )
        let increasedTableEnvironment = SidebarWorkspaceTableEnvironmentSnapshot(
            environment: increasedSwiftUIEnvironment,
            globalFontMagnificationPercent: 100,
            lazyContractProbe: SidebarLazyContractProbe()
        )
        let expectedStandard = try Self.appKitColor(
            from: Color.secondary.resolve(in: standardSwiftUIEnvironment)
        )
        let expectedIncreased = try Self.appKitColor(
            from: Color.secondary.resolve(in: increasedSwiftUIEnvironment)
        )
        let cell = Self.configuredCell(
            model: model,
            environment: standardTableEnvironment
        )

        let standardColor = try Self.resolvedTextColor(
            in: cell,
            matching: checklistText
        )
        cell.configure(
            model: model,
            environment: increasedTableEnvironment,
            actions: Self.makeActions(model: model),
            isPointerHovering: false,
            contextMenuDidOpen: {},
            contextMenuDidClose: {}
        )
        let increasedColor = try Self.resolvedTextColor(
            in: cell,
            matching: checklistText
        )

        #expect(expectedStandard != expectedIncreased)
        #expect(standardColor == expectedStandard)
        #expect(increasedColor == expectedIncreased)
    }

    @Test
    func inactiveSecondaryOpacityMultipliesResolvedSemanticAlpha() throws {
        let tableEnvironment = SidebarWorkspaceTableEnvironmentSnapshot(
            environment: .sidebarTableTestValues(
                colorScheme: .dark,
                colorSchemeContrast: .increased
            ),
            globalFontMagnificationPercent: 100,
            lazyContractProbe: SidebarLazyContractProbe()
        )
        let description = "Contrast-aware description"
        let metadataEntries = (0..<4).map {
            SidebarStatusEntry(key: "key-\($0)", value: "value-\($0)")
        }
        let model = Self.makeModel(
            customDescription: description,
            metadataEntries: metadataEntries,
            progress: SidebarProgressState(value: 0.5, label: "Halfway")
        )
        let cell = Self.configuredCell(
            model: model,
            environment: tableEnvironment
        )
        let semanticSecondary = try #require(
            tableEnvironment.secondaryTextColor.usingColorSpace(.sRGB)
        )

        let descriptionField = try #require(
            Self.descendants(of: cell)
                .compactMap { $0 as? NSTextField }
                .first { $0.stringValue == description }
        )
        let descriptionColor = try #require(
            descriptionField.attributedStringValue.attribute(
                .foregroundColor,
                at: 0,
                effectiveRange: nil
            ) as? NSColor
        )

        let metadataToggle = try #require(
            Self.descendants(of: cell)
                .compactMap { $0 as? SidebarRowLinkButton }
                .first { !$0.isHidden && !$0.attributedTitle.string.isEmpty }
        )
        let metadataToggleColor = try #require(
            metadataToggle.attributedTitle.attribute(
                .foregroundColor,
                at: 0,
                effectiveRange: nil
            ) as? NSColor
        )

        let progressView = try #require(
            Self.descendants(of: cell)
                .compactMap { $0 as? SidebarRowProgressView }
                .first { !$0.isHidden }
        )
        let progressTrack = try #require(progressView.subviews.first)
        let progressTrackCGColor = try #require(progressTrack.layer?.backgroundColor)
        let progressTrackColor = try #require(NSColor(cgColor: progressTrackCGColor))

        #expect(abs(descriptionColor.alphaComponent - semanticSecondary.alphaComponent * 0.95) < 0.001)
        #expect(abs(metadataToggleColor.alphaComponent - semanticSecondary.alphaComponent * 0.9) < 0.001)
        #expect(abs(progressTrackColor.alphaComponent - semanticSecondary.alphaComponent * 0.2) < 0.001)
    }

    @Test
    func defaultSettingsResolveTheSameStackedVerticalBranchLayoutForBothRows() {
        let settings = SidebarTabItemSettingsSnapshot(defaults: Self.makeDefaults())
        let swiftUIRow = Self.makeSwiftUIRow(settings: settings)
        let appKitRow = Self.makeModel(settings: settings)

        #expect(settings.branchDirectory.branchLayout == .vertical)
        #expect(settings.branchDirectory.branchDirectoryPlacement == .stacked)
        #expect(!settings.branchDirectory.usesLastSegmentPath)
        #expect(!settings.wrapsWorkspaceTitles)
        #expect(swiftUIRow.settings.branchDirectory == settings.branchDirectory)
        #expect(appKitRow.settings.branchDirectory == settings.branchDirectory)
    }

    @Test(arguments: [false, true])
    func storedLegacyBranchLayoutControlsBothRows(_ usesVerticalLayout: Bool) {
        let defaults = Self.makeDefaults()
        defaults.set(usesVerticalLayout, forKey: "sidebarBranchVerticalLayout")
        defaults.set(false, forKey: "sidebarBranchDirectoryStacked")
        let settings = SidebarTabItemSettingsSnapshot(defaults: defaults)
        let expectedLayout: SidebarWorkspaceBranchDirectorySettings.BranchLayout = usesVerticalLayout
            ? .vertical
            : .inline
        let expectedPlacement: SidebarWorkspaceBranchDirectorySettings.BranchDirectoryPlacement = usesVerticalLayout
            ? .stacked
            : .inline

        #expect(settings.branchDirectory.branchLayout == expectedLayout)
        #expect(settings.branchDirectory.branchDirectoryPlacement == expectedPlacement)
        #expect(Self.makeSwiftUIRow(settings: settings).settings.branchDirectory == settings.branchDirectory)
        #expect(Self.makeModel(settings: settings).settings.branchDirectory == settings.branchDirectory)
    }

    @Test(arguments: [false, true])
    func storedBranchDirectoryPlacementRemainsAnIndependentSetting(_ stacks: Bool) {
        let defaults = Self.makeDefaults()
        defaults.set(false, forKey: "sidebarBranchVerticalLayout")
        defaults.set(stacks, forKey: "sidebarBranchDirectoryStacked")
        let settings = SidebarTabItemSettingsSnapshot(defaults: defaults)
        let expected: SidebarWorkspaceBranchDirectorySettings.BranchDirectoryPlacement = stacks
            ? .stacked
            : .inline

        #expect(settings.branchDirectory.branchLayout == .inline)
        #expect(settings.branchDirectory.branchDirectoryPlacement == expected)
        #expect(Self.makeSwiftUIRow(settings: settings).settings.branchDirectory == settings.branchDirectory)
        #expect(Self.makeModel(settings: settings).settings.branchDirectory == settings.branchDirectory)
    }

    @Test(arguments: [false, true])
    func storedPathAndTitlePreferencesAreSharedByBothRows(_ enabled: Bool) {
        let defaults = Self.makeDefaults()
        defaults.set(enabled, forKey: "sidebarPathLastSegmentOnly")
        defaults.set(enabled, forKey: SidebarWorkspaceTitleWrapSettings.key)
        let settings = SidebarTabItemSettingsSnapshot(defaults: defaults)
        let swiftUISettings = Self.makeSwiftUIRow(settings: settings).settings
        let appKitSettings = Self.makeModel(settings: settings).settings

        #expect(settings.branchDirectory.usesLastSegmentPath == enabled)
        #expect(settings.wrapsWorkspaceTitles == enabled)
        #expect(swiftUISettings.branchDirectory.usesLastSegmentPath == enabled)
        #expect(swiftUISettings.wrapsWorkspaceTitles == enabled)
        #expect(appKitSettings.branchDirectory.usesLastSegmentPath == enabled)
        #expect(appKitSettings.wrapsWorkspaceTitles == enabled)
    }

    @Test
    func everyWorkspaceDetailSettingUsesCatalogDefaultsInBothRows() {
        let settings = SidebarTabItemSettingsSnapshot(defaults: Self.makeDefaults())
        let swiftUIDetails = Self.makeSwiftUIRow(settings: settings).settings.details
        let appKitDetails = Self.makeModel(settings: settings).settings.details
        let keys: [KeyPath<SidebarWorkspaceDetailSettings, Bool>] = [
            \.showBranchDirectory,
            \.showPullRequests,
            \.watchGitStatus,
            \.showSSH,
            \.showPorts,
            \.showLog,
            \.showProgress,
            \.showAgentActivity,
            \.showCustomMetadata,
        ]

        for key in keys {
            #expect(settings.details[keyPath: key])
            #expect(swiftUIDetails[keyPath: key] == settings.details[keyPath: key])
            #expect(appKitDetails[keyPath: key] == settings.details[keyPath: key])
        }
    }

    @Test
    func everyStoredWorkspaceDetailPreferenceIsHonoredInBothRows() {
        let cases: [(String, KeyPath<SidebarWorkspaceDetailSettings, Bool>)] = [
            ("sidebarShowBranchDirectory", \.showBranchDirectory),
            ("sidebarShowPullRequest", \.showPullRequests),
            ("sidebarWatchGitStatus", \.watchGitStatus),
            ("sidebarShowSSH", \.showSSH),
            ("sidebarShowPorts", \.showPorts),
            ("sidebarShowLog", \.showLog),
            ("sidebarShowProgress", \.showProgress),
            ("sidebarShowAgentActivity", \.showAgentActivity),
            ("sidebarShowStatusPills", \.showCustomMetadata),
        ]

        for (defaultsKey, detailKey) in cases {
            let defaults = Self.makeDefaults()
            defaults.set(false, forKey: defaultsKey)
            let settings = SidebarTabItemSettingsSnapshot(defaults: defaults)

            #expect(!settings.details[keyPath: detailKey])
            #expect(!Self.makeSwiftUIRow(settings: settings).settings.details[keyPath: detailKey])
            #expect(!Self.makeModel(settings: settings).settings.details[keyPath: detailKey])
        }
    }
}

@Suite
@MainActor
struct SidebarPinnedIndicatorColorTests {
    @Test
    func pinnedGroupUsesWorkspacePinColor() throws {
        let workspaceCell = SidebarAppKitRowCellTests.configuredCell(
            model: SidebarAppKitRowCellTests.makeModel(isPinned: true)
        )
        let groupCell = SidebarGroupHeaderTableCellView()
        groupCell.configurePresentation(
            model: SidebarGroupHeaderRowModel(
                groupId: UUID(),
                anchorWorkspaceId: UUID(),
                name: "Group",
                iconSymbol: "folder",
                tintHex: nil,
                isCollapsed: false,
                isPinned: true,
                isAnchorActive: false,
                isMultiSelected: false,
                multiSelectionBackgroundStyle: .clear,
                memberCount: 1,
                anchorUnreadCount: 0,
                canMarkRead: false,
                canMarkUnread: false,
                hasLatestNotifications: false,
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
                colorSchemeIsDark: true
            ),
            environment: SidebarAppKitRowCellTests.tableEnvironment
        )

        let workspacePin = try #require(
            SidebarAppKitRowCellTests.descendants(of: workspaceCell)
                .compactMap { $0 as? NSImageView }
                .first { !$0.isHidden && $0.toolTip != nil }
        )
        let groupPin = try #require(
            SidebarAppKitRowCellTests.descendants(of: groupCell)
                .compactMap { $0 as? NSImageView }
                .first { !$0.isHidden && $0.toolTip != nil }
        )

        #expect(groupPin.contentTintColor == workspacePin.contentTintColor)
    }
}
