import Foundation

struct CmuxLocalSelection: Sendable, Equatable {
    var workspaceID: UInt64
    var screenID: UInt64

    init(workspaceID: UInt64, screenID: UInt64) {
        self.workspaceID = workspaceID
        self.screenID = screenID
    }

    init?(tree: CmuxWorkspaceTree, preferredSurface: UInt64? = nil) {
        if let preferredSurface, let location = tree.location(of: preferredSurface) {
            workspaceID = location.workspace
            screenID = location.screen
            return
        }

        guard let workspace = tree.workspaces.first(where: \.active) ?? tree.workspaces.first,
              let screen = workspace.screens.first(where: \.active) ?? workspace.screens.first
        else {
            return nil
        }
        workspaceID = workspace.id
        screenID = screen.id
    }

    mutating func reconcile(with tree: CmuxWorkspaceTree) -> Bool {
        if let workspace = tree.workspaces.first(where: { $0.id == workspaceID }) {
            if workspace.screens.contains(where: { $0.id == screenID }) {
                return true
            }
            guard let screen = workspace.screens.first(where: \.active) ?? workspace.screens.first else {
                return false
            }
            screenID = screen.id
            return true
        }

        guard let replacement = CmuxLocalSelection(tree: tree) else { return false }
        self = replacement
        return true
    }

    mutating func selectWorkspace(_ id: UInt64, in tree: CmuxWorkspaceTree) -> Bool {
        guard let workspace = tree.workspaces.first(where: { $0.id == id }),
              let screen = workspace.screens.first(where: \.active) ?? workspace.screens.first
        else {
            return false
        }
        workspaceID = workspace.id
        screenID = screen.id
        return true
    }

    mutating func selectScreen(_ id: UInt64, in tree: CmuxWorkspaceTree) -> Bool {
        guard let workspace = tree.workspaces.first(where: { $0.id == workspaceID }),
              workspace.screens.contains(where: { $0.id == id })
        else {
            return false
        }
        screenID = id
        return true
    }
}
