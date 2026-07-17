import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite(.serialized)
struct WorktreeSidebarCustomizationTests {
    @MainActor
    @Test func bundledPresetIsAvailableWithoutBecomingTheDefault() {
        let projectWorktreesID = "com.example.cmux.sidebar.project-worktrees"

        #expect(CmuxExtensionSidebarSelection.defaultProviderId == "cmux.sidebar.default")
        #expect(CmuxExtensionSidebarSelection.defaultProviderId != projectWorktreesID)
        #expect(CmuxExtensionSidebarSelection.descriptors.contains { $0.id == projectWorktreesID })
    }

    @MainActor
    @Test func projectActionOverridesResolveByFieldAndPreserveSourcePaths() throws {
        let root = try temporaryRoot("precedence")
        defer { try? FileManager.default.removeItem(at: root) }
        let globalConfigURL = root.appendingPathComponent("global.json")
        let localConfigURL = root.appendingPathComponent("local.json")
        try """
        {
          "actions": {
            "global-create": { "type": "command", "command": "echo global" },
            "global-open": {
              "type": "workspace",
              "workspace": { "name": "Global Open", "cwd": "." }
            }
          },
          "ui": {
            "projectWorktrees": {
              "createAction": "global-create",
              "openAction": "global-open"
            }
          }
        }
        """.write(to: globalConfigURL, atomically: true, encoding: .utf8)
        try """
        {
          "actions": {
            "local-create": { "type": "command", "command": "echo local" }
          },
          "ui": {
            "projectWorktrees": {
              "createAction": "local-create"
            }
          }
        }
        """.write(to: localConfigURL, atomically: true, encoding: .utf8)

        let store = CmuxConfigStore(
            globalConfigPath: globalConfigURL.path,
            localConfigPath: localConfigURL.path,
            startFileWatchers: false
        )
        store.loadAll()

        #expect(store.projectWorktreesCreateActionID == "local-create")
        #expect(store.projectWorktreesOpenActionID == "global-open")
        #expect(store.resolvedProjectWorktreesCreateAction()?.id == "local-create")
        #expect(store.resolvedProjectWorktreesCreateAction()?.actionSourcePath == localConfigURL.path)
        #expect(store.resolvedProjectWorktreesOpenAction()?.id == "global-open")
        #expect(store.resolvedProjectWorktreesOpenAction()?.actionSourcePath == globalConfigURL.path)
        #expect(store.configurationIssues.isEmpty)
    }

    @MainActor
    @Test func missingConfiguredActionSurfacesIssueAndDoesNotResolve() throws {
        let root = try temporaryRoot("missing-action")
        defer { try? FileManager.default.removeItem(at: root) }
        let configURL = root.appendingPathComponent("cmux.json")
        try """
        {
          "ui": {
            "projectWorktrees": {
              "openAction": "missing-open"
            }
          }
        }
        """.write(to: configURL, atomically: true, encoding: .utf8)

        let store = CmuxConfigStore(
            globalConfigPath: configURL.path,
            localConfigPath: nil,
            startFileWatchers: false
        )
        store.loadAll()

        #expect(store.projectWorktreesOpenActionID == "missing-open")
        #expect(store.resolvedProjectWorktreesOpenAction() == nil)
        #expect(store.configurationIssues.contains { issue in
            issue.kind == .newWorkspaceActionNotFound
                && issue.settingName == "ui.projectWorktrees.openAction"
                && issue.commandName == "missing-open"
                && issue.sourcePath == configURL.path
        })
    }

    @MainActor
    @Test func deadWorkspaceCommandOverrideIsRejected() throws {
        let root = try temporaryRoot("dead-workspace-command")
        defer { try? FileManager.default.removeItem(at: root) }
        let configURL = root.appendingPathComponent("cmux.json")
        try """
        {
          "actions": {
            "open-layout": {
              "type": "workspaceCommand",
              "commandName": "Missing Layout"
            }
          },
          "ui": {
            "projectWorktrees": {
              "openAction": "open-layout"
            }
          }
        }
        """.write(to: configURL, atomically: true, encoding: .utf8)

        let store = CmuxConfigStore(
            globalConfigPath: configURL.path,
            localConfigPath: nil,
            startFileWatchers: false
        )
        store.loadAll()

        #expect(store.resolvedProjectWorktreesOpenAction() == nil)
        #expect(store.configurationIssues.contains { issue in
            issue.settingName == "ui.projectWorktrees.openAction"
                && issue.commandName == "Missing Layout"
        })
    }

    @MainActor
    @Test func configuredCreateActionExecutesInsteadOfRequestingBuiltInFlow() throws {
        let root = try temporaryRoot("controller-create")
        defer { try? FileManager.default.removeItem(at: root) }
        let projectRoot = root.appendingPathComponent("project", isDirectory: true)
        let configDirectory = projectRoot.appendingPathComponent(".cmux", isDirectory: true)
        try FileManager.default.createDirectory(at: configDirectory, withIntermediateDirectories: true)
        try """
        {
          "actions": {
            "custom-create": {
              "type": "builtin",
              "builtin": "cmux.newWorkspace"
            }
          },
          "ui": {
            "projectWorktrees": {
              "createAction": "custom-create"
            }
          }
        }
        """.write(
            to: configDirectory.appendingPathComponent("cmux.json"),
            atomically: true,
            encoding: .utf8
        )

        let globalConfigPath = root.appendingPathComponent("missing-global.json").path
        let primaryStore = CmuxConfigStore(
            globalConfigPath: globalConfigPath,
            localConfigPath: nil,
            startFileWatchers: false
        )
        let previousDelegate = AppDelegate.shared
        let appDelegate = AppDelegate()
        let tabManager = TabManager()
        let windowID = appDelegate.registerMainWindowContextForTesting(
            tabManager: tabManager,
            cmuxConfigStore: primaryStore
        )
        defer {
            appDelegate.unregisterMainWindowContextForTesting(windowId: windowID)
            AppDelegate.shared = previousDelegate
        }
        let originalWorkspaceCount = tabManager.tabs.count

        let didExecute = WorktreeSidebarWorkspaceController(tabManager: tabManager)
            .executeConfiguredCreateActionIfAvailable(projectRootPath: projectRoot.path)

        #expect(didExecute == true)
        #expect(tabManager.tabs.count == originalWorkspaceCount + 1)
    }

    @MainActor
    @Test func relativeWorkspaceOverridesUseProjectAndWorktreeBases() throws {
        let root = try temporaryRoot("relative-workspaces")
        defer { try? FileManager.default.removeItem(at: root) }
        let projectRoot = root.appendingPathComponent("project", isDirectory: true)
        let worktreeRoot = root.appendingPathComponent("linked", isDirectory: true)
        try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: worktreeRoot, withIntermediateDirectories: true)
        let globalConfigURL = root.appendingPathComponent("global.json")
        try """
        {
          "actions": {
            "custom-create": {
              "type": "workspace",
              "workspace": { "name": "Custom Create", "cwd": "flows/create" }
            },
            "custom-open": {
              "type": "workspace",
              "workspace": { "name": "Custom Open", "cwd": "flows/open" }
            }
          },
          "ui": {
            "projectWorktrees": {
              "createAction": "custom-create",
              "openAction": "custom-open"
            }
          }
        }
        """.write(to: globalConfigURL, atomically: true, encoding: .utf8)

        let primaryStore = CmuxConfigStore(
            globalConfigPath: globalConfigURL.path,
            localConfigPath: nil,
            startFileWatchers: false
        )
        let previousDelegate = AppDelegate.shared
        let appDelegate = AppDelegate()
        let tabManager = TabManager()
        let windowID = appDelegate.registerMainWindowContextForTesting(
            tabManager: tabManager,
            cmuxConfigStore: primaryStore
        )
        defer {
            appDelegate.unregisterMainWindowContextForTesting(windowId: windowID)
            AppDelegate.shared = previousDelegate
        }
        let controller = WorktreeSidebarWorkspaceController(tabManager: tabManager)

        #expect(controller.executeConfiguredCreateActionIfAvailable(
            projectRootPath: projectRoot.path
        ) == true)
        let createWorkspace = try #require(tabManager.tabs.first { $0.customTitle == "Custom Create" })
        #expect(createWorkspace.currentDirectory == projectRoot
            .appendingPathComponent("flows/create", isDirectory: true)
            .standardizedFileURL.path)

        #expect(controller.executeConfiguredOpenActionIfAvailable(
            projectRootPath: projectRoot.path,
            worktreePath: worktreeRoot.path
        ) == true)
        let openWorkspace = try #require(tabManager.tabs.first { $0.customTitle == "Custom Open" })
        #expect(openWorkspace.currentDirectory == worktreeRoot
            .appendingPathComponent("flows/open", isDirectory: true)
            .standardizedFileURL.path)
    }

    @MainActor
    @Test func invalidConfiguredOverrideDoesNotFallThrough() throws {
        let root = try temporaryRoot("invalid-controller-override")
        defer { try? FileManager.default.removeItem(at: root) }
        let projectRoot = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: true)
        let globalConfigURL = root.appendingPathComponent("global.json")
        try """
        {
          "ui": {
            "projectWorktrees": {
              "openAction": "missing-open"
            }
          }
        }
        """.write(to: globalConfigURL, atomically: true, encoding: .utf8)

        let primaryStore = CmuxConfigStore(
            globalConfigPath: globalConfigURL.path,
            localConfigPath: nil,
            startFileWatchers: false
        )
        let previousDelegate = AppDelegate.shared
        let appDelegate = AppDelegate()
        let tabManager = TabManager()
        let windowID = appDelegate.registerMainWindowContextForTesting(
            tabManager: tabManager,
            cmuxConfigStore: primaryStore
        )
        defer {
            appDelegate.unregisterMainWindowContextForTesting(windowId: windowID)
            AppDelegate.shared = previousDelegate
        }
        let workspaceCount = tabManager.tabs.count

        #expect(WorktreeSidebarWorkspaceController(tabManager: tabManager)
            .executeConfiguredOpenActionIfAvailable(
                projectRootPath: projectRoot.path,
                worktreePath: projectRoot.path
            ) == false)
        #expect(tabManager.tabs.count == workspaceCount)
    }

    @MainActor
    @Test func omittedOverridesLeaveBuiltInBehaviorAvailable() throws {
        let root = try temporaryRoot("omitted")
        defer { try? FileManager.default.removeItem(at: root) }
        let projectRoot = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: true)

        let primaryStore = CmuxConfigStore(
            globalConfigPath: root.appendingPathComponent("missing-global.json").path,
            localConfigPath: nil,
            startFileWatchers: false
        )
        let previousDelegate = AppDelegate.shared
        let appDelegate = AppDelegate()
        let tabManager = TabManager()
        let windowID = appDelegate.registerMainWindowContextForTesting(
            tabManager: tabManager,
            cmuxConfigStore: primaryStore
        )
        defer {
            appDelegate.unregisterMainWindowContextForTesting(windowId: windowID)
            AppDelegate.shared = previousDelegate
        }

        let controller = WorktreeSidebarWorkspaceController(tabManager: tabManager)
        #expect(controller.executeConfiguredCreateActionIfAvailable(projectRootPath: projectRoot.path) == nil)
        #expect(controller.executeConfiguredOpenActionIfAvailable(
            projectRootPath: projectRoot.path,
            worktreePath: projectRoot.path
        ) == nil)
    }

    private func temporaryRoot(_ suffix: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "cmux-worktree-customization-\(suffix)-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}
