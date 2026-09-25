import AppKit
import SwiftUI
import Testing
@testable import cmux_DEV

/// Regression coverage for the AppKit sidebar accessibility ownership boundary.
@Suite(.serialized)
@MainActor
struct SidebarAccessibilityTreeTests {
    @Test
    func mountedSidebarAndProjectPanelAccessibilityWalkIsAcyclic() async throws {
        let url = try #require(URL(string: "https://example.com/context"))
        let model = SidebarWorkspaceRowSuspensionTests.makeModel(
            customDescription: "Read \(url.absoluteString)"
        )
        let controller = SidebarWorkspaceTableController()
        let container = controller.makeContainerView()
        let row = SidebarWorkspaceTableRowConfiguration(
            workspaceRowModel: model,
            actions: SidebarWorkspaceRowSuspensionTests.makeActions(model: model),
            groupId: nil,
            isPinned: false,
            environment: SidebarWorkspaceTableEnvironmentSnapshot(
                colorScheme: .light,
                globalFontMagnificationPercent: 100,
                lazyContractProbe: SidebarLazyContractProbe()
            )
        )
        let projectURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("SidebarAX-\(UUID().uuidString).xcodeproj")
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: projectURL) }
        try Data(Self.projectFixture.utf8).write(to: projectURL.appendingPathComponent("project.pbxproj"))
        let panel = ProjectPanel(projectURL: projectURL)
        panel.reload()
        let loaded = await AppKitTestEventPump().waitUntil(timeout: .seconds(5)) {
            panel.loadState.model != nil || panel.lastLoadError != nil
        }
        try #require(loaded && panel.loadState.model != nil, "Project fixture must load: \(panel.lastLoadError ?? "")")
        let projectView = NSHostingView(rootView: ProjectPanelView(
            panel: panel, isFocused: false, onRequestPanelFocus: {}
        ))
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 820, height: 300))
        container.frame = NSRect(x: 0, y: 0, width: 360, height: 300)
        projectView.frame = NSRect(x: 360, y: 0, width: 460, height: 300)
        root.addSubview(container)
        root.addSubview(projectView)
        let window = NSWindow(
            contentRect: root.bounds,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = root
        window.orderFront(nil)
        defer {
            controller.dismantleContainerView(container)
            window.contentView = nil
            window.close()
        }

        controller.apply(
            rows: [row],
            actions: Self.makeTableActions(),
            workspaceIds: [model.workspaceId],
            selectedWorkspaceId: nil,
            selectedScrollTargetWorkspaceId: nil
        )
        await Self.flushStagedTableMutations()
        root.layoutSubtreeIfNeeded()
        container.tableView.layoutSubtreeIfNeeded()

        let cell = try #require(
            container.tableView.view(atColumn: 0, row: 0, makeIfNecessary: false)
                as? SidebarWorkspaceRowTableCellView
        )
        cell.layoutSubtreeIfNeeded()
        let textView = try #require(
            Self.descendants(of: cell)
                .compactMap { $0 as? SidebarRowTextView }
                .first { Self.contains(url: url, in: $0.attributedStringValue) }
        )

        let children = textView.accessibilityChildren() ?? []
        let link = try #require(children.compactMap { $0 as? SidebarRowTextAccessibilityLink }.first)
        #expect(
            children.allSatisfy { $0 is SidebarRowTextAccessibilityLink },
            "A row text field must expose only its own link elements, never AppKit cell aliases."
        )

        // NSHostingView publishes the project panel's LazyVStack rows to the
        // accessibility tree only after SwiftUI's own render pass, which runs on
        // a later main-loop turn than the AppKit layout above. Walk until it has.
        var walk = SidebarAccessibilityTreeWalk()
        _ = await AppKitTestEventPump().waitUntil(timeout: .seconds(5)) {
            // A mounted hosting view still needs its display pass before it
            // publishes SwiftUI accessibility children on a headless runner.
            projectView.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            walk = SidebarAccessibilityTreeWalk()
            walk.visit(window)
            return walk.cycle != nil || walk.textValues.contains { $0.contains("Context.swift") }
        }
        #expect(walk.cycle == nil, "Accessibility children must not point back to an ancestor: \(walk.cycle ?? [])")
        #expect(walk.maxDepth < 256, "Accessibility walk exceeded the safety depth: \(walk.maxDepth)")
        #expect(walk.visited.contains(ObjectIdentifier(textView)))
        #expect(walk.visited.contains(ObjectIdentifier(link)))
        // NSHostingView can be ignored in the AX tree; verify its rendered content.
        #expect(
            walk.textValues.contains { $0.contains("Context.swift") },
            "Project panel text missing from the AX walk: \(walk.textValues.sorted())"
        )

        let updated = SidebarWorkspaceRowSuspensionTests.makeModel(
            customDescription: "Changed https://example.com/updated", workspaceId: model.workspaceId
        )
        cell.applyRebuiltModel(updated)
        cell.layoutSubtreeIfNeeded()
        var updatedWalk = SidebarAccessibilityTreeWalk()
        updatedWalk.visit(window)
        #expect(updatedWalk.cycle == nil)
        #expect(updatedWalk.visited.contains(ObjectIdentifier(textView)))
        #expect(updatedWalk.textValues.contains { $0.contains("https://example.com/updated") })
    }

    @Test(arguments: [1, 2, 12])
    func plainTextRemainsReadableWithoutCellChildren(lines: Int) throws {
        let field = SidebarRowTextView(lines: lines)
        field.configurePlainText("Workspace context", font: .systemFont(ofSize: 12), color: .labelColor)
        let elements = NSAccessibility.unignoredChildren(from: [field])
        let text = try #require(elements.first as? NSObject)
        #expect(text.value(forKey: "accessibilityValue") as? String == "Workspace context")
        #expect(text.value(forKey: "accessibilityRole") as? String == NSAccessibility.Role.staticText.rawValue)
    }

    @Test
    func readingLinkChildrenDoesNotRewriteRenderedText() throws {
        let field = try Self.makeLinkedField()
        let rendered = NSAttributedString(attributedString: field.attributedStringValue)
        let children = field.accessibilityChildren() ?? []
        let link = try #require(children.compactMap { $0 as? SidebarRowTextAccessibilityLink }.first)

        #expect(field.attributedStringValue.isEqual(to: rendered))
        #expect((link.accessibilityParent() as AnyObject?) === field)
        #expect(link.accessibilityURL()?.absoluteString == "https://example.com/context")
        #expect(!link.accessibilityFrameInParentSpace().isEmpty)
    }

    @Test
    func attributedAccessibilityTextUsesOwnedLinksWithoutRewritingDisplay() throws {
        let field = try Self.makeLinkedField()
        let rendered = NSAttributedString(attributedString: field.attributedStringValue)
        let range = NSRange(location: 0, length: rendered.length)
        let attributed = try #require(field.accessibilityAttributedString(for: range))
        let link = try #require(attributed.attribute(.accessibilityLink, at: 0, effectiveRange: nil)
            as? SidebarRowTextAccessibilityLink)
        let children = field.accessibilityChildren() ?? []

        #expect(children.contains { ($0 as AnyObject) === link })
        #expect(attributed.string == rendered.string)
        #expect(field.attributedStringValue.isEqual(to: rendered))
        #expect(field.accessibilityNumberOfCharacters() == rendered.length)
        #expect(field.accessibilityVisibleCharacterRange() == range)
        #expect(field.accessibilityAttributedString(for: NSRange(location: NSNotFound, length: 1)) == nil)
    }

    private static func makeLinkedField() throws -> SidebarRowTextView {
        let source = NSAttributedString(
            string: "Documentation",
            attributes: [.link: try #require(URL(string: "https://example.com/context"))]
        )
        let field = SidebarRowTextView(lines: 1)
        field.frame = NSRect(x: 0, y: 0, width: 320, height: 40)
        field.configureAttributedText(
            try AttributedString(source, including: AttributeScopes.AppKitAttributes.self),
            font: .systemFont(ofSize: 12), color: .labelColor, linkColor: .linkColor
        )
        return field
    }

    private static func contains(url: URL, in attributedString: NSAttributedString) -> Bool {
        guard attributedString.length > 0 else { return false }
        var location = 0
        while location < attributedString.length {
            var range = NSRange(location: 0, length: 0)
            let value = attributedString.attribute(
                .sidebarRowLink,
                at: location,
                effectiveRange: &range
            )
            if let valueURL = value as? URL, valueURL == url { return true }
            location = max(location + 1, range.location + max(range.length, 1))
        }
        return false
    }

    private static func descendants(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap { descendants(of: $0) }
    }

    private static func makeTableActions() -> SidebarWorkspaceTableActions {
        SidebarWorkspaceTableActions(
            attachScrollView: { _ in },
            closeWorkspace: { _ in },
            createWorkspaceAtEnd: {},
            createEmptyWorkspaceGroup: {},
            beginWorkspaceDrag: { _ in },
            movingWorkspaceCount: { _ in 1 },
            endWorkspaceDrag: {},
            isValidWorkspaceDrag: { true },
            updateWorkspaceDrag: { _, _, _ in nil },
            performWorkspaceDrop: { _, _, _ in false },
            commitWorkspaceDropPlan: { _ in false },
            clearWorkspaceDropIndicator: {},
            currentDropIndicator: { nil },
            currentDropIndicatorScope: { .raw },
            canPerformBonsplitAction: { _, _ in false },
            moveBonsplitToExistingWorkspace: { _, _ in false },
            moveBonsplitToNewWorkspace: { _, _ in nil },
            didMoveBonsplitToWorkspace: { _ in },
            updateDragAutoscroll: {},
            setBonsplitDropTargetCollectionActive: { _ in },
            setBonsplitDropIndicator: { _ in }
        )
    }

    private static func flushStagedTableMutations() async {
        await withCheckedContinuation { continuation in
            RunLoop.main.perform(inModes: [.common]) {
                continuation.resume()
            }
        }
    }

    private static let projectFixture = """
    {
        archiveVersion = 1;
        objectVersion = 56;
        objects = {
            P0 = {isa = PBXProject; mainGroup = G0; targets = (); };
            G0 = {isa = PBXGroup; children = (F0); sourceTree = "<group>"; };
            F0 = {isa = PBXFileReference; path = Context.swift; sourceTree = "<group>"; };
        };
        rootObject = P0;
    }
    """
}
