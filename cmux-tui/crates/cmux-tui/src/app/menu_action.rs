//! The menu action vocabulary: every action a context menu item can run, its
//! label and resource helpers, and the keyboard action each menu action
//! adapts (`keyboard_action_for_menu`, read by check-spec-inventory.py).

use cmux_tui_core::sizing_policy::TerminalSizingMode;
use cmux_tui_core::{PaneId, ScreenId, SurfaceId, WorkspaceId};

use crate::app::menu::items::size_mode_label;
use crate::config::Action;
use crate::localization;
use crate::machine::MachineKey;

/// A context-menu entry: what activating it does (the label is derived).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MenuAction {
    RenameClientMachine(MachineKey),
    RenameManagedMachine(MachineKey),
    DeleteManagedMachine(MachineKey),
    RestoreManagedMachine(MachineKey),
    PurgeManagedMachine(MachineKey),
    RenameWorkspace(WorkspaceId),
    RenameManagedWorkspace(WorkspaceId),
    CopyWorkspaceId(WorkspaceId),
    CloseWorkspace(WorkspaceId),
    DeleteManagedWorkspace(WorkspaceId),
    RestoreManagedWorkspace(usize),
    PurgeManagedWorkspace(usize),
    RenameScreen(ScreenId),
    CloseScreen(ScreenId),
    BrowserBack(PaneId),
    BrowserForward(PaneId),
    BrowserReload(PaneId),
    BrowserEditUrl(PaneId),
    BrowserCopyUrl(PaneId),
    BrowserActivate(PaneId),
    RenameTab(PaneId),
    RenameSurface(SurfaceId),
    MoveTabToWorkspace {
        surface: SurfaceId,
        workspace: Option<WorkspaceId>,
    },
    CopyTabId(PaneId),
    CopyPaneId(PaneId),
    CopyStatusMessage,
    NewPaneSmart(PaneId),
    NewTab(PaneId),
    NewBrowserTab(PaneId),
    SplitRight(PaneId),
    SplitDown(PaneId),
    CloseTab(PaneId),
    ClosePane(PaneId),
    TogglePaneZoom {
        pane: PaneId,
        zoomed: bool,
    },
    ToggleSidebar {
        visible: bool,
    },
    ToggleSidebarCompact {
        compact: bool,
    },
    FocusSidebar,
    ActivateSidebarProfile(usize),
    SetSidebarViewVisible {
        view: usize,
        visible: bool,
    },
    ShowShortcuts,
    SetClientSizing {
        surface: SurfaceId,
        client: u64,
        enabled: bool,
    },
    UseClientSize {
        surface: SurfaceId,
        client: u64,
    },
    RestoreAllClientSizing(SurfaceId),
    DisconnectClient(u64),
    /// Shared sizing (docs/shared-terminal-sizing.md): the terminal's mode.
    SetSizeMode {
        surface: SurfaceId,
        mode: TerminalSizingMode,
    },
    /// Toggle one participant's counts-toward-size choice. `participant`
    /// indexes the size state of `generation`, the one the menu showed.
    SetSizeCounts {
        surface: SurfaceId,
        generation: u64,
        participant: usize,
        counts: bool,
    },
    /// Disconnect one participant of the size state of `generation`.
    DisconnectSizeParticipant {
        surface: SurfaceId,
        generation: u64,
        participant: usize,
    },
    SelectProviderScope(usize),
    InvokeProviderAction(usize),
    CreateMachineFrom(usize),
    ConnectMachineTarget(usize),
    ConnectOtherMachine,
    /// A configured action from a customizable menu (for example a `+`
    /// button's right-click menu), targeting an optional pane.
    RunConfigured {
        action: Action,
        pane: Option<PaneId>,
    },
}

impl MenuAction {
    pub fn label(&self) -> &'static str {
        let menu = &localization::catalog().menu;
        match self {
            // Menus always wrap this variant in a labeled item; the catalog
            // label is the keyboard-help fallback only.
            MenuAction::RunConfigured { action, .. } => {
                localization::catalog().action_label(*action)
            }
            MenuAction::RenameClientMachine(_) | MenuAction::RenameManagedMachine(_) => {
                localization::catalog().sidebar.rename_machine
            }
            MenuAction::DeleteManagedMachine(_) => localization::catalog().sidebar.delete_machine,
            MenuAction::RestoreManagedMachine(_) => localization::catalog().sidebar.restore_machine,
            MenuAction::PurgeManagedMachine(_) => localization::catalog().sidebar.purge_machine,
            MenuAction::RenameWorkspace(_) => {
                localization::catalog().action_label(Action::RenameWorkspace)
            }
            MenuAction::RenameManagedWorkspace(_) => {
                localization::catalog().sidebar.rename_workspace
            }
            MenuAction::CopyWorkspaceId(_) => menu.copy_workspace_id,
            MenuAction::CloseWorkspace(_) => {
                localization::catalog().action_label(Action::CloseWorkspace)
            }
            MenuAction::DeleteManagedWorkspace(_) => {
                localization::catalog().sidebar.delete_workspace
            }
            MenuAction::RestoreManagedWorkspace(_) => {
                localization::catalog().sidebar.restore_workspace
            }
            MenuAction::PurgeManagedWorkspace(_) => localization::catalog().sidebar.purge_workspace,
            MenuAction::RenameScreen(_) => {
                localization::catalog().action_label(Action::RenameScreen)
            }
            MenuAction::CloseScreen(_) => localization::catalog().action_label(Action::CloseScreen),
            MenuAction::BrowserBack(_) => localization::catalog().action_label(Action::BrowserBack),
            MenuAction::BrowserForward(_) => {
                localization::catalog().action_label(Action::BrowserForward)
            }
            MenuAction::BrowserReload(_) => {
                localization::catalog().action_label(Action::BrowserReload)
            }
            MenuAction::BrowserEditUrl(_) => {
                localization::catalog().action_label(Action::BrowserEditUrl)
            }
            MenuAction::BrowserCopyUrl(_) => menu.copy_url,
            MenuAction::BrowserActivate(_) => menu.show_in_chrome,
            MenuAction::RenameTab(_) | MenuAction::RenameSurface(_) => {
                localization::catalog().action_label(Action::RenameTab)
            }
            MenuAction::MoveTabToWorkspace { workspace: None, .. } => menu.move_tab_new_workspace,
            MenuAction::MoveTabToWorkspace { .. } => menu.move_tab_workspace,
            MenuAction::CopyTabId(_) => menu.copy_tab_id,
            MenuAction::CopyPaneId(_) => menu.copy_pane_id,
            MenuAction::CopyStatusMessage => menu.copy_message,
            MenuAction::NewPaneSmart(_) => {
                localization::catalog().action_label(Action::NewPaneSmart)
            }
            MenuAction::NewTab(_) => localization::catalog().action_label(Action::NewTab),
            MenuAction::NewBrowserTab(_) => {
                localization::catalog().action_label(Action::NewBrowserTab)
            }
            MenuAction::SplitRight(_) => localization::catalog().action_label(Action::SplitRight),
            MenuAction::SplitDown(_) => localization::catalog().action_label(Action::SplitDown),
            MenuAction::CloseTab(_) => localization::catalog().action_label(Action::CloseTab),
            MenuAction::ClosePane(_) => localization::catalog().action_label(Action::ClosePane),
            MenuAction::TogglePaneZoom { zoomed: false, .. } => menu.maximize_pane,
            MenuAction::TogglePaneZoom { zoomed: true, .. } => menu.restore_pane_layout,
            MenuAction::ToggleSidebar { visible: false } => menu.show_sidebar,
            MenuAction::ToggleSidebar { visible: true } => menu.hide_sidebar,
            MenuAction::ToggleSidebarCompact { compact: false } => menu.compact_sidebar,
            MenuAction::ToggleSidebarCompact { compact: true } => menu.full_sidebar,
            MenuAction::FocusSidebar => menu.focus_sidebar,
            MenuAction::ActivateSidebarProfile(_) => menu.sidebar_profiles,
            MenuAction::SetSidebarViewVisible { visible: true, .. } => menu.show_sidebar_view,
            MenuAction::SetSidebarViewVisible { visible: false, .. } => menu.hide_sidebar_view,
            MenuAction::ShowShortcuts => {
                localization::catalog().action_label(Action::ShowShortcuts)
            }
            MenuAction::SetClientSizing { enabled: true, .. } => menu.include_client_size,
            MenuAction::SetClientSizing { enabled: false, .. } => menu.excluded,
            MenuAction::UseClientSize { .. } => menu.use_only_client_size,
            MenuAction::RestoreAllClientSizing(_) => menu.restore_all_client_sizing,
            MenuAction::DisconnectClient(_) => menu.disconnect_client,
            MenuAction::SetSizeMode { mode, .. } => size_mode_label(*mode),
            MenuAction::SetSizeCounts { .. } => menu.size_counts,
            MenuAction::DisconnectSizeParticipant { .. } => menu.size_disconnect,
            MenuAction::SelectProviderScope(_) | MenuAction::InvokeProviderAction(_) => {
                localization::catalog().sidebar.provider_actions
            }
            MenuAction::CreateMachineFrom(_) => localization::catalog().sidebar.new_machine,
            MenuAction::ConnectMachineTarget(_) => localization::catalog().sidebar.connect_machine,
            MenuAction::ConnectOtherMachine => localization::catalog().sidebar.other_host,
        }
    }
}

pub(super) fn keyboard_action_for_menu(action: MenuAction) -> Option<Action> {
    match action {
        MenuAction::RenameWorkspace(_) => Some(Action::RenameWorkspace),
        MenuAction::CloseWorkspace(_) => Some(Action::CloseWorkspace),
        MenuAction::RenameScreen(_) => Some(Action::RenameScreen),
        MenuAction::CloseScreen(_) => Some(Action::CloseScreen),
        MenuAction::BrowserBack(_) => Some(Action::BrowserBack),
        MenuAction::BrowserForward(_) => Some(Action::BrowserForward),
        MenuAction::BrowserReload(_) => Some(Action::BrowserReload),
        MenuAction::BrowserEditUrl(_) => Some(Action::BrowserEditUrl),
        MenuAction::RenameTab(_) => Some(Action::RenameTab),
        MenuAction::NewPaneSmart(_) => Some(Action::NewPaneSmart),
        MenuAction::NewTab(_) => Some(Action::NewTab),
        MenuAction::NewBrowserTab(_) => Some(Action::NewBrowserTab),
        MenuAction::SplitRight(_) => Some(Action::SplitRight),
        MenuAction::SplitDown(_) => Some(Action::SplitDown),
        MenuAction::CloseTab(_) => Some(Action::CloseTab),
        MenuAction::ClosePane(_) => Some(Action::ClosePane),
        MenuAction::TogglePaneZoom { .. } => Some(Action::ZoomPane),
        MenuAction::ToggleSidebar { .. } => Some(Action::ToggleSidebar),
        MenuAction::ToggleSidebarCompact { .. } => Some(Action::ToggleSidebarCompact),
        MenuAction::FocusSidebar => Some(Action::FocusSidebar),
        MenuAction::ShowShortcuts => Some(Action::ShowShortcuts),
        _ => None,
    }
}
