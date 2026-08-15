use cmux_tui_core::SurfaceKind;
use cmux_tui_core::resource::{
    ContentPublicId, PanePublicId, ScreenPublicId, TabPublicId, TerminalPublicId,
    WorkspacePublicId,
};

#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) enum ActionFocus {
    Pane,
    MachineRail,
    WorkspaceRail,
    TabsRail,
    ProjectionRail(String),
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub(crate) enum ActionOverlay {
    #[default]
    None,
    Menu,
    Prompt,
    ShortcutHelp,
    Omnibar,
    CommandPalette,
    Pairing,
}

impl ActionOverlay {
    pub(crate) fn blocks_actions(self) -> bool {
        !matches!(self, Self::None | Self::CommandPalette)
    }
}

/// Public resource identities and revisions captured when an action surface
/// opens. Internal row indexes and `SurfaceId` slots are intentionally absent.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub(crate) struct ActionTargetFence {
    pub session: String,
    pub workspace: Option<WorkspacePublicId>,
    pub screen: Option<ScreenPublicId>,
    pub pane: Option<PanePublicId>,
    pub tab: Option<TabPublicId>,
    pub content: Option<ContentPublicId>,
    pub terminal: Option<TerminalPublicId>,
    pub workspace_revision: u64,
    pub pane_revision: Option<u64>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct ActionContextSnapshot {
    pub session: String,
    pub focus: ActionFocus,
    pub overlay: ActionOverlay,
    pub surface_kind: Option<SurfaceKind>,
    pub has_workspace: bool,
    pub has_screen: bool,
    pub has_pane: bool,
    pub pane_zoomed: bool,
    pub sidebar_visible: bool,
    pub sidebar_compact: bool,
    pub surface_only: bool,
    pub machine_present: bool,
    pub machine_connected: bool,
    pub sidebar_plugin_active: bool,
    pub target: ActionTargetFence,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum DisabledReason {
    NoWorkspace,
    NoScreen,
    NoPane,
    NoTerminal,
    NoBrowser,
    SurfaceOnly,
    BlockedByOverlay,
    TargetChanged,
    PluginUnavailable,
    PermissionDenied,
}

#[cfg(test)]
impl ActionContextSnapshot {
    pub(crate) fn for_test(focus: ActionFocus, surface_kind: SurfaceKind) -> Self {
        Self {
            session: "test".to_string(),
            focus,
            overlay: ActionOverlay::None,
            surface_kind: Some(surface_kind),
            has_workspace: true,
            has_screen: true,
            has_pane: true,
            pane_zoomed: false,
            sidebar_visible: true,
            sidebar_compact: false,
            surface_only: false,
            machine_present: false,
            machine_connected: false,
            sidebar_plugin_active: false,
            target: ActionTargetFence { session: "test".to_string(), ..Default::default() },
        }
    }
}
