import CmuxiOSSearch
import CmuxiOSShell
import CmuxiOSSSH
import CmuxiOSWorkspaces

/// The feature entry points one shell build made, kept so routes and search
/// can drive them (open a workspace, an SSH host, a settings page).
@MainActor
struct ShellFeatures {
    let workspaces: WorkspacesFeature
    let ssh: SSHFeature
    let settings: ShellSettingsModel
    let search: SearchFeature
}
