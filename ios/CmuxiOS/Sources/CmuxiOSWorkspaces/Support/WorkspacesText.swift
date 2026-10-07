import CmuxiOSWorkspacesCore
import Foundation

/// Localized strings of the Workspaces screens.
enum WorkspacesText {
    // List
    static var title: String { String(localized: "workspaces.title", defaultValue: "Workspaces", bundle: .module) }
    static var pinned: String { String(localized: "workspaces.section.pinned", defaultValue: "Pinned", bundle: .module) }
    static var workspaces: String { String(localized: "workspaces.section.workspaces", defaultValue: "Workspaces", bundle: .module) }
    static var allWorkspaces: String { String(localized: "workspaces.section.all", defaultValue: "All Workspaces", bundle: .module) }
    static var offline: String { String(localized: "workspaces.machine.offline", defaultValue: "Offline", bundle: .module) }
    static var connecting: String { String(localized: "workspaces.machine.connecting", defaultValue: "Connecting…", bundle: .module) }
    static var updating: String { String(localized: "workspaces.machine.updating", defaultValue: "Updating…", bundle: .module) }
    static var noWorkspacesOnMachine: String { String(localized: "workspaces.machine.empty", defaultValue: "No workspaces", bundle: .module) }
    static func workspaceCount(_ count: Int) -> String {
        String(localized: "workspaces.machine.count", defaultValue: "\(count) workspaces", bundle: .module)
    }
    static func paneCount(_ count: Int) -> String {
        String(localized: "workspaces.row.panes", defaultValue: "\(count) panes", bundle: .module)
    }
    static func unreadCount(_ count: Int) -> String {
        String(localized: "workspaces.row.unread", defaultValue: "\(count) unread", bundle: .module)
    }
    static var mockData: String { String(localized: "workspaces.mock", defaultValue: "Mock data", bundle: .module) }
    static var allOffline: String { String(localized: "workspaces.all-offline", defaultValue: "Every Mac is offline", bundle: .module) }

    // Status
    static var statusIdle: String { String(localized: "workspaces.status.idle", defaultValue: "Idle", bundle: .module) }
    static var statusRunning: String { String(localized: "workspaces.status.running", defaultValue: "Running", bundle: .module) }
    static var statusWaiting: String { String(localized: "workspaces.status.waiting", defaultValue: "Needs input", bundle: .module) }
    static var statusFailed: String { String(localized: "workspaces.status.failed", defaultValue: "Failed", bundle: .module) }

    // Surface kinds
    static var kindTerminal: String { String(localized: "workspaces.kind.terminal", defaultValue: "Terminal", bundle: .module) }
    static var kindBrowser: String { String(localized: "workspaces.kind.browser", defaultValue: "Browser", bundle: .module) }
    static var kindAgent: String { String(localized: "workspaces.kind.agent", defaultValue: "Agent", bundle: .module) }
    static var kindOther: String { String(localized: "workspaces.kind.other", defaultValue: "Surface", bundle: .module) }

    // Empty states
    static var loadingTitle: String { String(localized: "workspaces.empty.loading", defaultValue: "Loading Workspaces", bundle: .module) }
    static var noMachinesTitle: String { String(localized: "workspaces.empty.no-macs.title", defaultValue: "No Paired Mac", bundle: .module) }
    static var noMachinesBody: String {
        String(localized: "workspaces.empty.no-macs.body", defaultValue: "Pair a Mac running cmux to see its workspaces here.", bundle: .module)
    }
    static var allHiddenTitle: String { String(localized: "workspaces.empty.hidden.title", defaultValue: "All Macs Hidden", bundle: .module) }
    static var allHiddenBody: String {
        String(localized: "workspaces.empty.hidden.body", defaultValue: "Show a Mac again from Machines.", bundle: .module)
    }
    static var noWorkspacesTitle: String { String(localized: "workspaces.empty.none.title", defaultValue: "No Workspaces", bundle: .module) }
    static var noWorkspacesBody: String {
        String(localized: "workspaces.empty.none.body", defaultValue: "Workspaces you open on your Macs appear here.", bundle: .module)
    }
    static var filterEmptyTitle: String { String(localized: "workspaces.empty.filter.title", defaultValue: "No Matches", bundle: .module) }
    static var filterEmptyBody: String {
        String(localized: "workspaces.empty.filter.body", defaultValue: "No workspace matches “%@”.", bundle: .module)
    }
    static var showAll: String { String(localized: "workspaces.empty.filter.show-all", defaultValue: "Show All", bundle: .module) }

    // Menu
    static var viewOptions: String { String(localized: "workspaces.menu.view", defaultValue: "View Options", bundle: .module) }
    static var filter: String { String(localized: "workspaces.menu.filter", defaultValue: "Filter", bundle: .module) }
    static var sort: String { String(localized: "workspaces.menu.sort", defaultValue: "Sort", bundle: .module) }
    static var grouping: String { String(localized: "workspaces.menu.grouping", defaultValue: "Group", bundle: .module) }
    static var machines: String { String(localized: "workspaces.menu.machines", defaultValue: "Machines", bundle: .module) }
    static var filterAll: String { String(localized: "workspaces.filter.all", defaultValue: "All", bundle: .module) }
    static var filterUnread: String { String(localized: "workspaces.filter.unread", defaultValue: "Unread", bundle: .module) }
    static var filterNeedsInput: String { String(localized: "workspaces.filter.needs-input", defaultValue: "Needs Input", bundle: .module) }
    static var filterRunning: String { String(localized: "workspaces.filter.running", defaultValue: "Running", bundle: .module) }
    static var sortOwner: String { String(localized: "workspaces.sort.owner", defaultValue: "Mac Order", bundle: .module) }
    static var sortRecent: String { String(localized: "workspaces.sort.recent", defaultValue: "Recent Activity", bundle: .module) }
    static var sortByName: String { String(localized: "workspaces.sort.name", defaultValue: "Name", bundle: .module) }
    static var groupByMachine: String { String(localized: "workspaces.group.machine", defaultValue: "By Mac", bundle: .module) }
    static var groupFlat: String { String(localized: "workspaces.group.flat", defaultValue: "One List", bundle: .module) }

    // Actions
    static var markRead: String { String(localized: "workspaces.action.read", defaultValue: "Mark as Read", bundle: .module) }
    static var rename: String { String(localized: "workspaces.action.rename", defaultValue: "Rename", bundle: .module) }
    static var close: String { String(localized: "workspaces.action.close", defaultValue: "Close", bundle: .module) }
    static var cancel: String { String(localized: "workspaces.action.cancel", defaultValue: "Cancel", bundle: .module) }
    static var ok: String { String(localized: "workspaces.action.ok", defaultValue: "OK", bundle: .module) }
    static var done: String { String(localized: "workspaces.action.done", defaultValue: "Done", bundle: .module) }
    static var renameTitle: String { String(localized: "workspaces.rename.title", defaultValue: "Rename Workspace", bundle: .module) }
    static var renamePlaceholder: String { String(localized: "workspaces.rename.placeholder", defaultValue: "Name", bundle: .module) }
    static var closeTitle: String { String(localized: "workspaces.close.title", defaultValue: "Close “%@”?", bundle: .module) }
    static var closeBody: String {
        String(localized: "workspaces.close.body", defaultValue: "Its terminals and tabs close on %@.", bundle: .module)
    }
    static var refusedTitle: String { String(localized: "workspaces.refused.title", defaultValue: "Not Changed", bundle: .module) }
    static var offlineTitle: String { String(localized: "workspaces.offline.title", defaultValue: "Mac Offline", bundle: .module) }
    static var offlineBody: String {
        String(localized: "workspaces.offline.body", defaultValue: "%@ can’t be reached, so nothing was changed.", bundle: .module)
    }

    // Detail
    static func pane(_ number: Int) -> String {
        String(localized: "workspaces.detail.pane", defaultValue: "Pane \(number)", bundle: .module)
    }
    static var closedTitle: String { String(localized: "workspaces.detail.closed.title", defaultValue: "Workspace Closed", bundle: .module) }
    static var closedBody: String {
        String(localized: "workspaces.detail.closed.body", defaultValue: "This workspace was closed on its Mac.", bundle: .module)
    }
    static var machineOffline: String { String(localized: "workspaces.detail.offline", defaultValue: "%@ is offline", bundle: .module) }
    static var noSurfaces: String { String(localized: "workspaces.detail.empty", defaultValue: "No tabs", bundle: .module) }
    static var surfaceUnavailable: String {
        String(localized: "workspaces.detail.unavailable", defaultValue: "Opens on the Mac for now", bundle: .module)
    }

    // Machines
    static var machinesFooter: String {
        String(localized: "workspaces.machines.footer", defaultValue: "Hidden Macs stay paired. Drag to change the order on this iPhone.", bundle: .module)
    }
    static var show: String { String(localized: "workspaces.machines.show", defaultValue: "Show %@", bundle: .module) }

    // Picker
    static var pickerTitle: String { String(localized: "workspaces.picker.title", defaultValue: "Choose Workspace", bundle: .module) }
    static var newWorkspace: String { String(localized: "workspaces.picker.new", defaultValue: "New Workspace", bundle: .module) }

    // Formatting
    static func format(_ template: String, _ args: any CVarArg...) -> String {
        String(format: template, locale: Locale.current, arguments: args)
    }

    static func filterName(_ filter: WorkspaceListFilter) -> String {
        switch filter {
        case .all: filterAll
        case .unread: filterUnread
        case .needsInput: filterNeedsInput
        case .running: filterRunning
        }
    }

    static func sortName(_ sort: WorkspaceListSort) -> String {
        switch sort {
        case .ownerOrder: sortOwner
        case .recentActivity: sortRecent
        case .name: sortByName
        }
    }

    static func groupingName(_ grouping: WorkspaceListGrouping) -> String {
        switch grouping {
        case .byMachine: groupByMachine
        case .flat: groupFlat
        }
    }
}
