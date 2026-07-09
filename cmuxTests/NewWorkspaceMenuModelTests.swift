import AppKit
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Plus-button menu section model: section classification/ordering and the
/// always-present management tail.
struct NewWorkspaceMenuModelTests {

    @MainActor
    private func loadStore(globalJSON: String) throws -> (store: CmuxConfigStore, root: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "cmux-menu-model-tests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let globalConfigURL = root.appendingPathComponent("cmux.json")
        try globalJSON.write(to: globalConfigURL, atomically: true, encoding: .utf8)
        let store = CmuxConfigStore(
            globalConfigPath: globalConfigURL.path,
            localConfigPath: nil,
            startFileWatchers: false
        )
        store.loadAll()
        return (store, root)
    }

    @MainActor
    @Test func emptyMenuStillOffersSaveWorkspaceAsLayout() throws {
        let model = NewWorkspaceMenuModel.build(
            newWorkspaceContextMenuItems: [],
            agentChatAction: nil,
            cloudSectionEnabled: false,
            templateNames: [],
            loadedActions: [],
            newWorkspaceActionID: nil,
            deletable: { _ in false },
            sectionOrder: .customFirst
        )
        guard model.sections.count == 1, case .management(let management) = model.sections[0] else {
            Issue.record("Expected a lone management section, got \(model.sections)")
            return
        }
        #expect(management.deletableActions.isEmpty)
        #expect(management.defaultLayout.entries.isEmpty)

        let (store, root) = try loadStore(globalJSON: "{}")
        defer { try? FileManager.default.removeItem(at: root) }
        let appDelegate = AppDelegate()
        let tabManager = TabManager()
        let windowId = appDelegate.registerMainWindowContextForTesting(
            tabManager: tabManager,
            cmuxConfigStore: store
        )
        defer { appDelegate.unregisterMainWindowContextForTesting(windowId: windowId) }
        let context = try #require(appDelegate.mainWindowContexts.values.first { $0.windowId == windowId })
        let menu = try #require(appDelegate.renderNewWorkspaceContextMenu(
            model: model,
            context: context,
            cmuxConfigStore: store
        ))
        let titles = menu.items.filter { !$0.isSeparatorItem }.map(\.title)
        #expect(titles == [String(localized: "menu.newWorkspace.saveWorkspaceAsLayout", defaultValue: "Save Workspace as Layout…")])
    }

    @MainActor
    @Test func newWorkspaceMenuModelClassifiesAndOrdersSections() throws {
        let (store, root) = try loadStore(globalJSON: """
        {
          "actions": {
            "terminal-command": {
              "type": "command",
              "title": "Terminal Command",
              "command": "echo hi"
            },
            "review-layout": {
              "type": "workspace",
              "title": "Review Layout",
              "workspace": { "name": "Review" }
            }
          },
          "ui": {
            "newWorkspace": {
              "menuSectionOrder": "customFirst",
              "contextMenu": [
                "cmux.newWorkspace",
                { "type": "separator" },
                "review-layout",
                "terminal-command"
              ],
              "action": "terminal-command"
            }
          }
        }
        """)
        defer { try? FileManager.default.removeItem(at: root) }

        let agent = CmuxResolvedConfigAction.builtIn(.newAgentChat)
        let model = NewWorkspaceMenuModel.build(
            newWorkspaceContextMenuItems: store.newWorkspaceContextMenuItems,
            agentChatAction: agent,
            cloudSectionEnabled: true,
            templateNames: ["Template A"],
            loadedActions: store.loadedActions,
            newWorkspaceActionID: store.newWorkspaceActionID,
            deletable: { $0.id == "review-layout" },
            sectionOrder: store.newWorkspaceMenuSectionOrder
        )

        guard case .create(let createRows) = model.sections[0],
              case .cloud = model.sections[1],
              case .layouts(let layoutRows) = model.sections[2],
              case .templates(let templates) = model.sections[3],
              case .management(let management) = model.sections[4] else {
            Issue.record("Unexpected model sections: \(model.sections)")
            return
        }
        let createIDs = createRows.compactMap { row -> String? in
            guard case .action(let action, _, _) = row else { return nil }
            return action.action.id
        }
        #expect(createIDs == [
            CmuxSurfaceTabBarBuiltInAction.newWorkspace.configID,
            "terminal-command",
            CmuxSurfaceTabBarBuiltInAction.newAgentChat.configID,
        ])
        #expect(createRows.contains(.separator))
        #expect(layoutRows.map { $0.menuAction.action.id } == ["review-layout"])
        #expect(layoutRows.first?.deletable == true)
        #expect(templates == ["Template A"])
        #expect(management.deletableActions.map(\.id) == ["review-layout"])
        if case .action(_, _, let isDefault)? = createRows.first(where: { row in
            guard case .action(let action, _, _) = row else { return false }
            return action.action.id == "terminal-command"
        }) {
            #expect(isDefault)
        } else {
            Issue.record("Expected hand-edited default command in create rows")
        }
    }
}
