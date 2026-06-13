import AppKit
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite("File explorer keyboard activation")
struct FileExplorerKeyboardActivationTests {
    private final class OpenProbe {
        var openedPaths: [String] = []
    }

    @Test
    func selectedLocalFileOpensThroughSharedActivationPath() {
        let file = FileExplorerNode(name: "README.md", path: "/tmp/project/README.md", isDirectory: false)
        let probe = OpenProbe()
        let (coordinator, outlineView) = makeOutline(nodes: [file], probe: probe)

        outlineView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        coordinator.store.select(node: file)

        #expect(coordinator.openSelectedItem(in: outlineView))
        #expect(probe.openedPaths == [file.path])
    }

    @Test
    func selectedFolderTogglesExpansionThroughSharedActivationPath() {
        let folder = FileExplorerNode(name: "Sources", path: "/tmp/project/Sources", isDirectory: true)
        folder.children = [
            FileExplorerNode(name: "App.swift", path: "/tmp/project/Sources/App.swift", isDirectory: false)
        ]
        let probe = OpenProbe()
        let (coordinator, outlineView) = makeOutline(nodes: [folder], probe: probe)

        outlineView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        coordinator.store.select(node: folder)

        #expect(coordinator.openSelectedItem(in: outlineView))
        #expect(outlineView.isItemExpanded(folder))
        #expect(coordinator.store.isExpanded(folder))

        #expect(coordinator.openSelectedItem(in: outlineView))
        #expect(!outlineView.isItemExpanded(folder))
        #expect(!coordinator.store.isExpanded(folder))
        #expect(probe.openedPaths.isEmpty)
    }

    @Test
    func returnEnterAndConfiguredShortcutMatchOpenSelection() {
        let returnEvent = makeKeyEvent(characters: "\r", keyCode: 36)
        let keypadEnterEvent = makeKeyEvent(characters: "\r", keyCode: 76)
        let downArrow = String(UnicodeScalar(NSDownArrowFunctionKey)!)
        let commandDownEvent = makeKeyEvent(
            modifierFlags: .command,
            characters: downArrow,
            keyCode: 125
        )
        let plainDownEvent = makeKeyEvent(characters: downArrow, keyCode: 125)
        var requestedShortcutAction: KeyboardShortcutSettings.Action?
        let configuredShortcutMatches = FileExplorerKeyboardActivation.matchesOpenSelectionShortcut(
            commandDownEvent,
            shortcutForAction: { action in
                requestedShortcutAction = action
                return action.defaultShortcut
            }
        )

        #expect(FileExplorerKeyboardActivation.isDefaultOpenEvent(returnEvent))
        #expect(FileExplorerKeyboardActivation.isDefaultOpenEvent(keypadEnterEvent))
        #expect(configuredShortcutMatches)
        #expect(requestedShortcutAction == .openFileExplorerSelection)
        #expect(!FileExplorerKeyboardActivation.matchesOpenSelectionShortcut(plainDownEvent))
    }

    @Test
    func openSelectionShortcutDefaultsAndMetadata() {
        let action = KeyboardShortcutSettings.Action.openFileExplorerSelection
        let shortcut = action.defaultShortcut

        #expect(action.label == String(localized: "shortcut.openFileExplorerSelection.label", defaultValue: "File Explorer: Open Selection"))
        #expect(shortcut.key == "↓")
        #expect(shortcut.command)
        #expect(!shortcut.shift)
        #expect(!shortcut.option)
        #expect(!shortcut.control)
    }

    @Test
    func settingsVisibleActionsColocateRightSidebarFileExplorerAndFindShortcuts() {
        let visibleActions = KeyboardShortcutSettings.settingsVisibleActions
        let expectedActions: [KeyboardShortcutSettings.Action] = [
            .focusRightSidebar,
            .toggleRightSidebar,
            .openFileExplorerSelection,
            .findInDirectory,
        ]

        guard let startIndex = visibleActions.firstIndex(of: .focusRightSidebar) else {
            Issue.record("Toggle Right Sidebar Focus should be visible in keyboard shortcut settings")
            return
        }

        let endIndex = startIndex + expectedActions.count
        guard endIndex <= visibleActions.count else {
            Issue.record("Expected shortcut settings to include the full right-sidebar shortcut run")
            return
        }
        #expect(Array(visibleActions[startIndex..<endIndex]) == expectedActions)
    }

    private func makeOutline(
        nodes: [FileExplorerNode],
        probe: OpenProbe
    ) -> (FileExplorerPanelView.Coordinator, FileExplorerNSOutlineView) {
        let store = FileExplorerStore()
        store.provider = LocalFileExplorerProvider()
        store.rootPath = "/tmp/project"
        store.rootNodes = nodes

        let coordinator = FileExplorerPanelView.Coordinator(
            store: store,
            state: FileExplorerState(),
            onOpenFilePreview: { probe.openedPaths.append($0) }
        )

        let outlineView = FileExplorerNSOutlineView()
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column
        outlineView.dataSource = coordinator
        outlineView.delegate = coordinator
        coordinator.outlineView = outlineView
        outlineView.reloadData()

        return (coordinator, outlineView)
    }

    private func makeKeyEvent(
        modifierFlags: NSEvent.ModifierFlags = [],
        characters: String,
        keyCode: UInt16
    ) -> NSEvent {
        guard let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifierFlags,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: keyCode
        ) else {
            fatalError("Failed to construct key event")
        }
        return event
    }
}
