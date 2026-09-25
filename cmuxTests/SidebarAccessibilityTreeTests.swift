import AppKit
import Testing
@testable import cmux_DEV

/// Regression coverage for the AppKit sidebar accessibility ownership boundary.
@Suite(.serialized)
@MainActor
struct SidebarAccessibilityTreeTests {
    @Test
    func mountedSidebarRowAccessibilityWalkIsAcyclic() async throws {
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
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 240),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = container
        window.orderFront(nil)
        defer {
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
        container.layoutSubtreeIfNeeded()
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
        #expect(
            children.allSatisfy { $0 is SidebarRowTextAccessibilityLink },
            "A row text field must expose only its own link elements, never AppKit cell aliases."
        )

        var walk = AccessibilityWalk()
        walk.visit(window)
        #expect(walk.cycle == nil, "Accessibility children must not point back to an ancestor: \(walk.cycle ?? [])")
        #expect(walk.maxDepth < 256, "Accessibility walk exceeded the safety depth: \(walk.maxDepth)")
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

    @MainActor
    private struct AccessibilityWalk {
        var visited = Set<ObjectIdentifier>()
        var active = Set<ObjectIdentifier>()
        var cycle: [String]?
        var maxDepth = 0

        mutating func visit(_ node: Any, depth: Int = 0, path: [String] = []) {
            guard cycle == nil else { return }
            guard depth < 256 else {
                cycle = path + ["<depth-limit>"]
                return
            }
            let object = node as AnyObject
            let identity = ObjectIdentifier(object)
            let name = String(describing: type(of: object))
            guard active.insert(identity).inserted else {
                cycle = path + [name]
                return
            }
            defer { active.remove(identity) }
            guard visited.insert(identity).inserted else { return }
            maxDepth = max(maxDepth, depth)
            for child in Self.children(of: object) {
                visit(child, depth: depth + 1, path: path + [name])
            }
        }

        private static func children(of object: AnyObject) -> [Any] {
            let rawChildren: [Any]?
            if let view = object as? NSView {
                rawChildren = view.accessibilityChildren()
            } else if let element = object as? NSAccessibilityElement {
                rawChildren = element.accessibilityChildren()
            } else if let object = object as? NSObject {
                let selector = NSSelectorFromString("accessibilityAttributeValue:")
                rawChildren = object.responds(to: selector)
                    ? object.perform(selector, with: NSAccessibility.Attribute.children.rawValue)?
                        .takeUnretainedValue() as? [Any]
                    : nil
            } else {
                rawChildren = nil
            }
            return rawChildren.map { NSAccessibility.unignoredChildren(from: $0) } ?? []
        }
    }
}
