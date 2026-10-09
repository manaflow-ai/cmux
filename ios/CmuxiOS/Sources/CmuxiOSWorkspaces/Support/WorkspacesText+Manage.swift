import Foundation

/// Localized strings of E3: groups, reorder, customize and SSH sessions.
extension WorkspacesText {
    static var customize: String { String(localized: "workspaces.action.customize", defaultValue: "Customize…", bundle: .module) }
    static var customizeTitle: String { String(localized: "workspaces.customize.title", defaultValue: "Customize Workspace", bundle: .module) }
    static var customizeName: String { String(localized: "workspaces.customize.name", defaultValue: "Name", bundle: .module) }
    static var customizeColor: String { String(localized: "workspaces.customize.color", defaultValue: "Color", bundle: .module) }
    static var customizeIcon: String { String(localized: "workspaces.customize.icon", defaultValue: "Icon", bundle: .module) }
    static var customizeNone: String { String(localized: "workspaces.customize.none", defaultValue: "None", bundle: .module) }
    static var save: String { String(localized: "workspaces.action.save", defaultValue: "Save", bundle: .module) }
    static var moveToGroup: String { String(localized: "workspaces.action.move-to-group", defaultValue: "Move to Group", bundle: .module) }
    static var noGroup: String { String(localized: "workspaces.group.none", defaultValue: "No Group", bundle: .module) }
    static var renameGroup: String { String(localized: "workspaces.action.rename-group", defaultValue: "Rename Group", bundle: .module) }
    static var renameGroupTitle: String { String(localized: "workspaces.rename-group.title", defaultValue: "Rename Group", bundle: .module) }
    static var collapse: String { String(localized: "workspaces.group.collapse", defaultValue: "Collapse", bundle: .module) }
    static var expand: String { String(localized: "workspaces.group.expand", defaultValue: "Expand", bundle: .module) }
    static var collapsed: String { String(localized: "workspaces.group.collapsed", defaultValue: "Collapsed", bundle: .module) }
    static var expanded: String { String(localized: "workspaces.group.expanded", defaultValue: "Expanded", bundle: .module) }
    static var groupActions: String { String(localized: "workspaces.group.actions", defaultValue: "Group Actions", bundle: .module) }
    static var reorderHint: String {
        String(localized: "workspaces.reorder.hint", defaultValue: "Drag workspaces to reorder them or move them between groups.", bundle: .module)
    }

    // SSH hosts
    static var sshUntrustedKey: String {
        String(localized: "workspaces.ssh.untrusted", defaultValue: "Open this host in Hosts once to trust its key", bundle: .module)
    }
    static var sshNeedsLogin: String { String(localized: "workspaces.ssh.login", defaultValue: "Set up a login in Hosts", bundle: .module) }
    static var sshUnreachable: String { String(localized: "workspaces.ssh.unreachable", defaultValue: "Can’t reach the server", bundle: .module) }
    static var sshRefused: String { String(localized: "workspaces.ssh.refused", defaultValue: "Sessions unavailable", bundle: .module) }

    // Palette tokens the Mac uses (CmuxNextDesign GroupColor).
    static func colorName(_ token: String) -> String {
        switch token {
        case "grey": String(localized: "workspaces.color.grey", defaultValue: "Grey", bundle: .module)
        case "blue": String(localized: "workspaces.color.blue", defaultValue: "Blue", bundle: .module)
        case "red": String(localized: "workspaces.color.red", defaultValue: "Red", bundle: .module)
        case "yellow": String(localized: "workspaces.color.yellow", defaultValue: "Yellow", bundle: .module)
        case "green": String(localized: "workspaces.color.green", defaultValue: "Green", bundle: .module)
        case "pink": String(localized: "workspaces.color.pink", defaultValue: "Pink", bundle: .module)
        case "purple": String(localized: "workspaces.color.purple", defaultValue: "Purple", bundle: .module)
        case "cyan": String(localized: "workspaces.color.cyan", defaultValue: "Cyan", bundle: .module)
        case "orange": String(localized: "workspaces.color.orange", defaultValue: "Orange", bundle: .module)
        default: token
        }
    }
}
