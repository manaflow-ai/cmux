//! Test-only action metadata: programmability classification and execution routing per Action, read by the spec inventory checker.

use super::*;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[cfg(test)]
pub(crate) enum ActionExecution {
    SendPrefix,
    NewTab,
    NewBrowserTab,
    NewPaneSmart,
    NextTab,
    PrevTab,
    SelectTab(ActionIndex),
    SplitRight,
    SplitDown,
    CloseTab,
    ClosePane,
    RenameTab,
    RenameScreen,
    RenameWorkspace,
    CloseScreen,
    PrevScreen,
    NextScreen,
    SelectScreen(ActionIndex),
    NewScreen,
    PrevWorkspace,
    NextWorkspace,
    NewWorkspace,
    CloseWorkspace,
    ToggleSidebar,
    ToggleSidebarCompact,
    ToggleSidebarView,
    FocusSidebar,
    ProviderMenu,
    NewPaneRight,
    UndoLayout,
    FocusLeft,
    FocusRight,
    FocusUp,
    FocusDown,
    FocusNextPane,
    SwapPanePrev,
    SwapPaneNext,
    ZoomPane,
    ResizeGrow,
    ResizeShrink,
    ScrollUp,
    ScrollDown,
    ClearHistory,
    BrowserBack,
    BrowserForward,
    BrowserReload,
    BrowserEditUrl,
    ShowShortcuts,
    Detach,
    UserCommand(UserCommandIndex),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[cfg(test)]
pub(super) enum ActionClassification {
    Direct,
    Composite,
    PresentationOnly,
}

#[cfg(test)]
impl ActionClassification {
    const fn inventory_name(self) -> &'static str {
        match self {
            Self::Direct => "direct",
            Self::Composite => "composite",
            Self::PresentationOnly => "presentation-only",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[cfg(test)]
pub(super) enum WorkspaceOwnershipSource {
    ActiveWorkspaceSession,
}

#[cfg(test)]
impl WorkspaceOwnershipSource {
    const fn inventory_name(self) -> &'static str {
        match self {
            Self::ActiveWorkspaceSession => "active-workspace-session",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[cfg(test)]
pub(super) enum ActionRouteTarget {
    MuxCommand(&'static str),
    MachineProviderRequest(&'static str),
}

#[cfg(test)]
impl ActionRouteTarget {
    const fn inventory_kind(self) -> &'static str {
        match self {
            Self::MuxCommand(_) => "mux-command",
            Self::MachineProviderRequest(_) => "machine-provider-request",
        }
    }

    const fn operation(self) -> &'static str {
        match self {
            Self::MuxCommand(operation) | Self::MachineProviderRequest(operation) => operation,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[cfg(test)]
pub(super) enum UnknownOwnership {
    Reject,
}

#[cfg(test)]
impl UnknownOwnership {
    const fn inventory_name(self) -> &'static str {
        match self {
            Self::Reject => "reject",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[cfg(test)]
pub(super) enum ActionRoute {
    Static(&'static str),
    WorkspaceOwnership {
        source: WorkspaceOwnershipSource,
        session_owned: ActionRouteTarget,
        provider_owned: ActionRouteTarget,
        unknown: UnknownOwnership,
    },
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[cfg(test)]
pub(crate) struct ActionMetadata {
    pub(super) key: &'static str,
    classification: ActionClassification,
    route: ActionRoute,
    execution: ActionExecution,
}

#[cfg(test)]
impl ActionMetadata {
    const fn new(
        key: &'static str,
        classification: ActionClassification,
        route: &'static str,
        execution: ActionExecution,
    ) -> Self {
        Self { key, classification, route: ActionRoute::Static(route), execution }
    }

    const fn workspace_ownership(
        key: &'static str,
        classification: ActionClassification,
        source: WorkspaceOwnershipSource,
        session_owned: ActionRouteTarget,
        provider_owned: ActionRouteTarget,
        unknown: UnknownOwnership,
        execution: ActionExecution,
    ) -> Self {
        Self {
            key,
            classification,
            route: ActionRoute::WorkspaceOwnership {
                source,
                session_owned,
                provider_owned,
                unknown,
            },
            execution,
        }
    }

    pub(crate) fn execution(self) -> ActionExecution {
        debug_assert!(!self.key.is_empty());
        debug_assert!(!self.classification.inventory_name().is_empty());
        match self.route {
            ActionRoute::Static(route) => debug_assert!(!route.is_empty()),
            ActionRoute::WorkspaceOwnership { source, session_owned, provider_owned, unknown } => {
                debug_assert!(!source.inventory_name().is_empty());
                debug_assert_eq!(session_owned.inventory_kind(), "mux-command");
                debug_assert!(!session_owned.operation().is_empty());
                debug_assert_eq!(provider_owned.inventory_kind(), "machine-provider-request");
                debug_assert!(!provider_owned.operation().is_empty());
                debug_assert_eq!(unknown.inventory_name(), "reject");
            }
        }
        self.execution
    }
}

impl Action {
    /// Compiled source of truth for programmability classification and
    /// execution routing. The specification inventory checker reads this
    /// exhaustive catalog.
    #[cfg(test)]
    pub(crate) fn metadata(&self) -> ActionMetadata {
        match self {
            Action::SendPrefix => ActionMetadata::new(
                "send-prefix",
                ActionClassification::Composite,
                "frontend prefix config + active surface + send-key",
                ActionExecution::SendPrefix,
            ),
            Action::NewTab => ActionMetadata::new(
                "new-tab",
                ActionClassification::Direct,
                "new-tab",
                ActionExecution::NewTab,
            ),
            Action::NewBrowserTab => ActionMetadata::new(
                "new-browser-tab",
                ActionClassification::Composite,
                "frontend omnibar + new-browser-tab",
                ActionExecution::NewBrowserTab,
            ),
            Action::NewPaneSmart => ActionMetadata::new(
                "new-pane-smart",
                ActionClassification::Composite,
                "list-workspaces + new-pane",
                ActionExecution::NewPaneSmart,
            ),
            Action::NextTab => ActionMetadata::new(
                "next-tab",
                ActionClassification::Direct,
                "select-tab delta:+1",
                ActionExecution::NextTab,
            ),
            Action::PrevTab => ActionMetadata::new(
                "prev-tab",
                ActionClassification::Direct,
                "select-tab delta:-1",
                ActionExecution::PrevTab,
            ),
            Action::SelectTab(index) => ActionMetadata::new(
                "select-tab-{number}",
                ActionClassification::Direct,
                "select-tab index",
                ActionExecution::SelectTab(*index),
            ),
            Action::SplitRight => ActionMetadata::new(
                "split-right",
                ActionClassification::Direct,
                "split dir:right",
                ActionExecution::SplitRight,
            ),
            Action::SplitDown => ActionMetadata::new(
                "split-down",
                ActionClassification::Direct,
                "split dir:down",
                ActionExecution::SplitDown,
            ),
            Action::CloseTab => ActionMetadata::new(
                "close-tab",
                ActionClassification::Direct,
                "close-surface",
                ActionExecution::CloseTab,
            ),
            Action::ClosePane => ActionMetadata::new(
                "close-pane",
                ActionClassification::Direct,
                "close-pane",
                ActionExecution::ClosePane,
            ),
            Action::RenameTab => ActionMetadata::new(
                "rename-tab",
                ActionClassification::Composite,
                "frontend prompt + rename-surface",
                ActionExecution::RenameTab,
            ),
            Action::RenameScreen => ActionMetadata::new(
                "rename-screen",
                ActionClassification::Composite,
                "frontend prompt + rename-screen",
                ActionExecution::RenameScreen,
            ),
            Action::RenameWorkspace => ActionMetadata::new(
                "rename-workspace",
                ActionClassification::Composite,
                "frontend prompt + rename-workspace",
                ActionExecution::RenameWorkspace,
            ),
            Action::CloseScreen => ActionMetadata::new(
                "close-screen",
                ActionClassification::Direct,
                "close-screen",
                ActionExecution::CloseScreen,
            ),
            Action::PrevScreen => ActionMetadata::new(
                "prev-screen",
                ActionClassification::Direct,
                "select-screen delta:-1",
                ActionExecution::PrevScreen,
            ),
            Action::NextScreen => ActionMetadata::new(
                "next-screen",
                ActionClassification::Direct,
                "select-screen delta:+1",
                ActionExecution::NextScreen,
            ),
            Action::SelectScreen(index) => ActionMetadata::new(
                "select-screen-{number}",
                ActionClassification::Direct,
                "select-screen index",
                ActionExecution::SelectScreen(*index),
            ),
            Action::NewScreen => ActionMetadata::new(
                "new-screen",
                ActionClassification::Direct,
                "new-screen",
                ActionExecution::NewScreen,
            ),
            Action::PrevWorkspace => ActionMetadata::new(
                "prev-workspace",
                ActionClassification::Direct,
                "select-workspace delta:-1",
                ActionExecution::PrevWorkspace,
            ),
            Action::NextWorkspace => ActionMetadata::new(
                "next-workspace",
                ActionClassification::Direct,
                "select-workspace delta:+1",
                ActionExecution::NextWorkspace,
            ),
            Action::NewWorkspace => ActionMetadata::workspace_ownership(
                "new-workspace",
                ActionClassification::Composite,
                WorkspaceOwnershipSource::ActiveWorkspaceSession,
                ActionRouteTarget::MuxCommand("new-workspace"),
                ActionRouteTarget::MachineProviderRequest("create_workspace"),
                UnknownOwnership::Reject,
                ActionExecution::NewWorkspace,
            ),
            Action::CloseWorkspace => ActionMetadata::workspace_ownership(
                "close-workspace",
                ActionClassification::Composite,
                WorkspaceOwnershipSource::ActiveWorkspaceSession,
                ActionRouteTarget::MuxCommand("close-workspace"),
                ActionRouteTarget::MachineProviderRequest("delete_workspace"),
                UnknownOwnership::Reject,
                ActionExecution::CloseWorkspace,
            ),
            Action::ToggleSidebar => ActionMetadata::new(
                "toggle-sidebar",
                ActionClassification::PresentationOnly,
                "frontend action adapter",
                ActionExecution::ToggleSidebar,
            ),
            Action::ToggleSidebarCompact => ActionMetadata::new(
                "toggle-sidebar-compact",
                ActionClassification::PresentationOnly,
                "frontend action adapter",
                ActionExecution::ToggleSidebarCompact,
            ),
            Action::ToggleSidebarView => ActionMetadata::new(
                "toggle-sidebar-view",
                ActionClassification::PresentationOnly,
                "frontend action adapter",
                ActionExecution::ToggleSidebarView,
            ),
            Action::FocusSidebar => ActionMetadata::new(
                "focus-sidebar",
                ActionClassification::PresentationOnly,
                "frontend action adapter",
                ActionExecution::FocusSidebar,
            ),
            Action::ProviderMenu => ActionMetadata::new(
                "provider-menu",
                ActionClassification::PresentationOnly,
                "frontend machine provider menu",
                ActionExecution::ProviderMenu,
            ),
            Action::NewPaneRight => ActionMetadata::new(
                "new-pane-right",
                ActionClassification::Direct,
                "new-pane-right",
                ActionExecution::NewPaneRight,
            ),
            Action::UndoLayout => ActionMetadata::new(
                "undo-layout",
                ActionClassification::Direct,
                "undo-layout",
                ActionExecution::UndoLayout,
            ),
            Action::FocusLeft => ActionMetadata::new(
                "focus-left",
                ActionClassification::Composite,
                "frontend geometry + focus-pane",
                ActionExecution::FocusLeft,
            ),
            Action::FocusRight => ActionMetadata::new(
                "focus-right",
                ActionClassification::Composite,
                "frontend geometry + focus-pane",
                ActionExecution::FocusRight,
            ),
            Action::FocusUp => ActionMetadata::new(
                "focus-up",
                ActionClassification::Composite,
                "frontend geometry + focus-pane",
                ActionExecution::FocusUp,
            ),
            Action::FocusDown => ActionMetadata::new(
                "focus-down",
                ActionClassification::Composite,
                "frontend geometry + focus-pane",
                ActionExecution::FocusDown,
            ),
            Action::FocusNextPane => ActionMetadata::new(
                "focus-next-pane",
                ActionClassification::Composite,
                "list-workspaces + focus-pane",
                ActionExecution::FocusNextPane,
            ),
            Action::SwapPanePrev => ActionMetadata::new(
                "swap-pane-prev",
                ActionClassification::Composite,
                "list-workspaces + swap-pane",
                ActionExecution::SwapPanePrev,
            ),
            Action::SwapPaneNext => ActionMetadata::new(
                "swap-pane-next",
                ActionClassification::Composite,
                "list-workspaces + swap-pane",
                ActionExecution::SwapPaneNext,
            ),
            Action::ZoomPane => ActionMetadata::new(
                "zoom-pane",
                ActionClassification::Direct,
                "zoom-pane",
                ActionExecution::ZoomPane,
            ),
            Action::ResizeGrow => ActionMetadata::new(
                "resize-grow",
                ActionClassification::Composite,
                "list-workspaces + set-split-ratio",
                ActionExecution::ResizeGrow,
            ),
            Action::ResizeShrink => ActionMetadata::new(
                "resize-shrink",
                ActionClassification::Composite,
                "list-workspaces + set-split-ratio",
                ActionExecution::ResizeShrink,
            ),
            Action::ScrollUp => ActionMetadata::new(
                "scroll-up",
                ActionClassification::PresentationOnly,
                "frontend viewport adapter; scroll-surface for shared local viewport",
                ActionExecution::ScrollUp,
            ),
            Action::ScrollDown => ActionMetadata::new(
                "scroll-down",
                ActionClassification::PresentationOnly,
                "frontend viewport adapter; scroll-surface for shared local viewport",
                ActionExecution::ScrollDown,
            ),
            Action::ClearHistory => ActionMetadata::new(
                "clear-history",
                ActionClassification::Direct,
                "clear-history",
                ActionExecution::ClearHistory,
            ),
            Action::BrowserBack => ActionMetadata::new(
                "browser-back",
                ActionClassification::Direct,
                "browser-back",
                ActionExecution::BrowserBack,
            ),
            Action::BrowserForward => ActionMetadata::new(
                "browser-forward",
                ActionClassification::Direct,
                "browser-forward",
                ActionExecution::BrowserForward,
            ),
            Action::BrowserReload => ActionMetadata::new(
                "browser-reload",
                ActionClassification::Direct,
                "browser-reload",
                ActionExecution::BrowserReload,
            ),
            Action::BrowserEditUrl => ActionMetadata::new(
                "browser-edit-url",
                ActionClassification::Composite,
                "frontend prompt + browser-navigate",
                ActionExecution::BrowserEditUrl,
            ),
            Action::ShowShortcuts => ActionMetadata::new(
                "show-shortcuts",
                ActionClassification::PresentationOnly,
                "frontend shortcut overlay",
                ActionExecution::ShowShortcuts,
            ),
            Action::Detach => ActionMetadata::new(
                "detach",
                ActionClassification::PresentationOnly,
                "close frontend transport",
                ActionExecution::Detach,
            ),
            Action::UserCommand(index) => ActionMetadata::new(
                "user-command-{index}",
                ActionClassification::Composite,
                "frontend command config + run",
                ActionExecution::UserCommand(*index),
            ),
        }
    }
}
