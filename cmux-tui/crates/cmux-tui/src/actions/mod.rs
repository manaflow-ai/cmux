//! Shared user-action catalog for keyboard, menu, sidebar, and palette entrypoints.
//!
//! Built-in actions keep their existing [`Action`] values and config keys. This
//! layer adds stable IDs, captured context, typed availability, and an explicit
//! invocation boundary without teaching plugins to control a PTY.

mod context;
mod plugin;
mod search;

use std::cmp::Reverse;

use cmux_tui_core::SurfaceKind;

use crate::config::{Action, Keys, action_definitions};
use crate::localization::Catalog;

pub(crate) use context::{
    ActionContextSnapshot, ActionFocus, ActionOverlay, ActionTargetFence, DisabledReason,
};
pub(crate) use plugin::{
    PluginActionContribution, PluginActionInvocation, PluginActionPermission,
};
pub(crate) use search::search_score;

/// Stable action identity. Built-ins use `cmux.<config-key>`. Future plugin
/// actions use `plugin.<plugin-id>.<action-id>` and carry a manifest revision.
#[derive(Clone, Debug, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub(crate) struct ActionId(String);

impl ActionId {
    pub(crate) fn built_in(action: Action) -> Self {
        Self(format!("cmux.{}", action.definition().config_key))
    }

    pub(crate) fn plugin(plugin_id: &str, action_id: &str) -> Option<Self> {
        let valid = |part: &str| {
            !part.is_empty()
                && part
                    .bytes()
                    .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'_' | b'.'))
        };
        (valid(plugin_id) && valid(action_id))
            .then(|| Self(format!("plugin.{plugin_id}.{action_id}")))
    }

    pub(crate) fn as_str(&self) -> &str {
        &self.0
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum ActionSource {
    Keyboard,
    ContextMenu,
    Sidebar,
    Palette,
    Internal,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) enum RegisteredAction {
    BuiltIn(Action),
    Plugin(PluginActionInvocation),
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct ActionInvocation {
    pub command: RegisteredAction,
    pub source: ActionSource,
    pub target: Option<ActionTargetFence>,
}

impl ActionInvocation {
    pub(crate) fn built_in(action: Action, source: ActionSource) -> Self {
        Self { command: RegisteredAction::BuiltIn(action), source, target: None }
    }

    pub(crate) fn palette(action: RegisteredAction, target: ActionTargetFence) -> Self {
        Self { command: action, source: ActionSource::Palette, target: Some(target) }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum ActionAvailability {
    Enabled,
    Disabled(DisabledReason),
}

impl ActionAvailability {
    pub(crate) fn is_enabled(self) -> bool {
        matches!(self, Self::Enabled)
    }

    pub(crate) fn disabled_reason(self) -> Option<DisabledReason> {
        match self {
            Self::Enabled => None,
            Self::Disabled(reason) => Some(reason),
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct ActionCandidate {
    pub id: ActionId,
    pub command: RegisteredAction,
    pub title: String,
    pub subtitle: String,
    pub shortcut: Option<String>,
    pub availability: ActionAvailability,
    pub focus_rank: u16,
    catalog_order: usize,
}

impl ActionCandidate {
    pub(crate) fn disabled_reason(&self) -> Option<DisabledReason> {
        match self.availability {
            ActionAvailability::Enabled => None,
            ActionAvailability::Disabled(reason) => Some(reason),
        }
    }
}

/// One immutable registry projection for the context captured when a command
/// surface opens. Rebuild it after focus or resource identity changes.
pub(crate) struct ActionRegistry;

impl ActionRegistry {
    pub(crate) fn candidates(
        context: &ActionContextSnapshot,
        keys: &Keys,
        catalog: &Catalog,
        plugin_actions: &[PluginActionContribution],
    ) -> Vec<ActionCandidate> {
        let mut candidates = action_definitions()
            .iter()
            .enumerate()
            .map(|(index, definition)| {
                let action = definition.action;
                let availability = Self::availability(action, context);
                ActionCandidate {
                    id: ActionId::built_in(action),
                    command: RegisteredAction::BuiltIn(action),
                    title: dynamic_title(action, context, catalog),
                    subtitle: category_label(action, catalog).to_string(),
                    shortcut: keys.shortcut_label(action),
                    availability,
                    focus_rank: focus_rank(action, context),
                    catalog_order: index,
                }
            })
            .collect::<Vec<_>>();

        for contribution in plugin_actions {
            let Some(id) = ActionId::plugin(&contribution.plugin_id, &contribution.action_id) else {
                continue;
            };
            let availability = contribution.availability(context);
            candidates.push(ActionCandidate {
                id,
                command: RegisteredAction::Plugin(contribution.invocation()),
                title: contribution.title.clone(),
                subtitle: contribution.subtitle.clone(),
                shortcut: None,
                availability,
                focus_rank: contribution.focus_rank(context),
                catalog_order: candidates.len(),
            });
        }

        candidates.sort_by_key(|candidate| {
            (
                Reverse(candidate.availability.is_enabled()),
                Reverse(candidate.focus_rank),
                candidate.catalog_order,
            )
        });
        candidates
    }

    pub(crate) fn availability(
        action: Action,
        context: &ActionContextSnapshot,
    ) -> ActionAvailability {
        if context.overlay.blocks_actions()
            && !matches!(action, Action::OpenCommandPalette | Action::Detach)
        {
            return ActionAvailability::Disabled(DisabledReason::BlockedByOverlay);
        }
        if context.surface_only && !surface_only_action(action) {
            return ActionAvailability::Disabled(DisabledReason::SurfaceOnly);
        }
        if needs_workspace(action) && !context.has_workspace {
            return ActionAvailability::Disabled(DisabledReason::NoWorkspace);
        }
        if needs_screen(action) && !context.has_screen {
            return ActionAvailability::Disabled(DisabledReason::NoScreen);
        }
        if needs_pane(action) && !context.has_pane {
            return ActionAvailability::Disabled(DisabledReason::NoPane);
        }
        if terminal_only_action(action) && context.surface_kind != Some(SurfaceKind::Pty) {
            return ActionAvailability::Disabled(DisabledReason::NoTerminal);
        }
        if browser_only_action(action) && context.surface_kind != Some(SurfaceKind::Browser) {
            return ActionAvailability::Disabled(DisabledReason::NoBrowser);
        }
        ActionAvailability::Enabled
    }
}

pub(crate) fn action_needs_target_fence(action: Action) -> bool {
    !matches!(
        action,
        Action::OpenCommandPalette
            | Action::ShowShortcuts
            | Action::ToggleSidebar
            | Action::ToggleSidebarCompact
            | Action::ToggleSidebarView
            | Action::FocusSidebar
            | Action::Detach
    )
}

fn dynamic_title(action: Action, context: &ActionContextSnapshot, catalog: &Catalog) -> String {
    match action {
        Action::ToggleSidebar if context.sidebar_visible => catalog.menu.hide_sidebar.to_string(),
        Action::ToggleSidebar => catalog.menu.show_sidebar.to_string(),
        Action::ToggleSidebarCompact if context.sidebar_compact => {
            catalog.menu.full_sidebar.to_string()
        }
        Action::ToggleSidebarCompact => catalog.menu.compact_sidebar.to_string(),
        Action::ZoomPane if context.pane_zoomed => catalog.menu.restore_pane_layout.to_string(),
        Action::ZoomPane => catalog.menu.maximize_pane.to_string(),
        _ => catalog.action_label(action).to_string(),
    }
}

fn category_label(action: Action, catalog: &Catalog) -> &'static str {
    if browser_only_action(action) {
        catalog.palette.category_browser
    } else if matches!(
        action,
        Action::ToggleSidebar
            | Action::ToggleSidebarCompact
            | Action::ToggleSidebarView
            | Action::FocusSidebar
    ) {
        catalog.palette.category_sidebar
    } else if matches!(
        action,
        Action::PrevWorkspace
            | Action::NextWorkspace
            | Action::NewWorkspace
            | Action::CloseWorkspace
            | Action::RenameWorkspace
    ) {
        catalog.palette.category_workspace
    } else if matches!(
        action,
        Action::PrevScreen
            | Action::NextScreen
            | Action::SelectScreen(_)
            | Action::NewScreen
            | Action::CloseScreen
            | Action::RenameScreen
    ) {
        catalog.palette.category_screen
    } else if matches!(
        action,
        Action::OpenCommandPalette | Action::ShowShortcuts | Action::Detach
    ) {
        catalog.palette.category_application
    } else {
        catalog.palette.category_pane
    }
}

fn focus_rank(action: Action, context: &ActionContextSnapshot) -> u16 {
    let category = match context.focus {
        ActionFocus::Pane => {
            if browser_only_action(action) && context.surface_kind == Some(SurfaceKind::Browser) {
                90
            } else if needs_pane(action) || terminal_only_action(action) {
                75
            } else {
                20
            }
        }
        ActionFocus::MachineRail => {
            if matches!(action, Action::FocusSidebar | Action::ToggleSidebar) { 70 } else { 15 }
        }
        ActionFocus::WorkspaceRail => {
            if matches!(
                action,
                Action::PrevWorkspace
                    | Action::NextWorkspace
                    | Action::NewWorkspace
                    | Action::CloseWorkspace
                    | Action::RenameWorkspace
                    | Action::FocusSidebar
            ) {
                85
            } else {
                15
            }
        }
        ActionFocus::TabsRail => {
            if matches!(
                action,
                Action::NewTab
                    | Action::CloseTab
                    | Action::RenameTab
                    | Action::NextTab
                    | Action::PrevTab
                    | Action::SelectTab(_)
            ) {
                85
            } else {
                15
            }
        }
        ActionFocus::ProjectionRail(_) => {
            if matches!(action, Action::FocusSidebar | Action::ToggleSidebar) { 75 } else { 15 }
        }
    };
    category + u16::from(matches!(action, Action::OpenCommandPalette))
}

fn needs_workspace(action: Action) -> bool {
    !matches!(
        action,
        Action::OpenCommandPalette
            | Action::ToggleSidebar
            | Action::ToggleSidebarCompact
            | Action::ToggleSidebarView
            | Action::FocusSidebar
            | Action::NewWorkspace
            | Action::ShowShortcuts
            | Action::Detach
    )
}

fn needs_screen(action: Action) -> bool {
    matches!(
        action,
        Action::NewTab
            | Action::NewBrowserTab
            | Action::NewPaneSmart
            | Action::NextTab
            | Action::PrevTab
            | Action::SelectTab(_)
            | Action::SplitRight
            | Action::SplitDown
            | Action::CloseTab
            | Action::ClosePane
            | Action::RenameTab
            | Action::RenameScreen
            | Action::CloseScreen
            | Action::NewPaneRight
            | Action::UndoLayout
            | Action::FocusLeft
            | Action::FocusRight
            | Action::FocusUp
            | Action::FocusDown
            | Action::FocusNextPane
            | Action::SwapPanePrev
            | Action::SwapPaneNext
            | Action::ZoomPane
            | Action::ResizeGrow
            | Action::ResizeShrink
            | Action::ScrollUp
            | Action::ScrollDown
            | Action::ClearHistory
            | Action::BrowserBack
            | Action::BrowserForward
            | Action::BrowserReload
            | Action::BrowserEditUrl
            | Action::SendPrefix
    )
}

fn needs_pane(action: Action) -> bool {
    matches!(
        action,
        Action::SendPrefix
            | Action::NewTab
            | Action::NewBrowserTab
            | Action::NewPaneSmart
            | Action::NextTab
            | Action::PrevTab
            | Action::SelectTab(_)
            | Action::SplitRight
            | Action::SplitDown
            | Action::CloseTab
            | Action::ClosePane
            | Action::RenameTab
            | Action::NewPaneRight
            | Action::UndoLayout
            | Action::FocusLeft
            | Action::FocusRight
            | Action::FocusUp
            | Action::FocusDown
            | Action::FocusNextPane
            | Action::SwapPanePrev
            | Action::SwapPaneNext
            | Action::ZoomPane
            | Action::ResizeGrow
            | Action::ResizeShrink
            | Action::ScrollUp
            | Action::ScrollDown
            | Action::ClearHistory
            | Action::BrowserBack
            | Action::BrowserForward
            | Action::BrowserReload
            | Action::BrowserEditUrl
    )
}

fn terminal_only_action(action: Action) -> bool {
    matches!(
        action,
        Action::SendPrefix | Action::ScrollUp | Action::ScrollDown | Action::ClearHistory
    )
}

fn browser_only_action(action: Action) -> bool {
    matches!(
        action,
        Action::BrowserBack
            | Action::BrowserForward
            | Action::BrowserReload
            | Action::BrowserEditUrl
    )
}

fn surface_only_action(action: Action) -> bool {
    matches!(
        action,
        Action::SendPrefix
            | Action::CloseTab
            | Action::RenameTab
            | Action::ScrollUp
            | Action::ScrollDown
            | Action::ClearHistory
            | Action::OpenCommandPalette
            | Action::ShowShortcuts
            | Action::Detach
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::localization::catalog_for_locale;

    fn context(focus: ActionFocus, kind: SurfaceKind) -> ActionContextSnapshot {
        ActionContextSnapshot::for_test(focus, kind)
    }

    #[test]
    fn built_in_ids_are_stable_and_plugin_ids_are_namespaced() {
        assert_eq!(ActionId::built_in(Action::NewTab).as_str(), "cmux.new-tab");
        assert_eq!(
            ActionId::plugin("git", "open-pr").expect("valid plugin action").as_str(),
            "plugin.git.open-pr"
        );
        assert!(ActionId::plugin("bad id", "open-pr").is_none());
    }

    #[test]
    fn browser_actions_stay_visible_but_disabled_for_a_terminal() {
        let candidates = ActionRegistry::candidates(
            &context(ActionFocus::Pane, SurfaceKind::Pty),
            &Keys::default(),
            catalog_for_locale("en"),
            &[],
        );
        let back = candidates
            .iter()
            .find(|candidate| candidate.id.as_str() == "cmux.browser-back")
            .expect("browser action remains searchable");
        assert_eq!(
            back.availability,
            ActionAvailability::Disabled(DisabledReason::NoBrowser)
        );
    }

    #[test]
    fn focused_surface_actions_rank_before_unrelated_actions() {
        let candidates = ActionRegistry::candidates(
            &context(ActionFocus::TabsRail, SurfaceKind::Pty),
            &Keys::default(),
            catalog_for_locale("en"),
            &[],
        );
        let new_tab = candidates.iter().position(|row| row.id.as_str() == "cmux.new-tab").unwrap();
        let new_workspace = candidates
            .iter()
            .position(|row| row.id.as_str() == "cmux.new-workspace")
            .unwrap();
        assert!(new_tab < new_workspace);
    }
}
