//! Action policy: which actions are browser-only, frontend-local, create a
//! destination, are available in surface-only mode, or prepare a PTY release;
//! provider action error messages; key binding matching.

use cmux_tui_core::SurfaceId;
use crossterm::event::KeyEvent;

use crate::app::{BRACKETED_PASTE_MARKER_BYTES, MenuAction};
use crate::config::Action;
use crate::localization;
use crate::machine::ProviderActionInputError;

pub(super) fn browser_only_action(action: Action) -> bool {
    matches!(
        action,
        Action::BrowserBack
            | Action::BrowserForward
            | Action::BrowserReload
            | Action::BrowserEditUrl
    )
}

pub(super) fn action_is_frontend_local(action: Action) -> bool {
    matches!(
        action,
        Action::NextTab
            | Action::PrevTab
            | Action::SelectTab(_)
            | Action::PrevScreen
            | Action::NextScreen
            | Action::SelectScreen(_)
            | Action::PrevWorkspace
            | Action::NextWorkspace
            | Action::ToggleSidebar
            | Action::ToggleSidebarCompact
            | Action::ToggleSidebarView
            | Action::FocusSidebar
            | Action::ProviderMenu
            | Action::FocusLeft
            | Action::FocusRight
            | Action::FocusUp
            | Action::FocusDown
            | Action::FocusNextPane
            | Action::ScrollUp
            | Action::ScrollDown
            | Action::BrowserEditUrl
            | Action::ShowShortcuts
    )
}

pub(super) fn action_creates_destination(action: Action) -> bool {
    matches!(
        action,
        Action::NewTab
            | Action::NewBrowserTab
            | Action::NewPaneSmart
            | Action::SplitRight
            | Action::SplitDown
            | Action::NewScreen
            | Action::NewWorkspace
            | Action::NewPaneRight
    )
}

pub(super) fn publishes_global_cell_metrics(surface_only: Option<SurfaceId>) -> bool {
    surface_only.is_none()
}

pub(super) fn action_available_in_mode(action: Action, surface_only: bool) -> bool {
    !surface_only
        || matches!(
            action,
            Action::SendPrefix
                | Action::CloseTab
                | Action::RenameTab
                | Action::ScrollUp
                | Action::ScrollDown
                | Action::ClearHistory
                | Action::ShowShortcuts
                | Action::Detach
        )
}

pub(super) fn action_prepares_pty_release(action: Action) -> bool {
    !matches!(
        action,
        Action::SendPrefix
            | Action::RenameTab
            | Action::RenameScreen
            | Action::RenameWorkspace
            | Action::NewWorkspace
            | Action::NewPaneRight
            | Action::ScrollUp
            | Action::ScrollDown
            | Action::BrowserEditUrl
            | Action::ShowShortcuts
    )
}

pub(super) fn menu_action_prepares_pty_release(action: MenuAction) -> bool {
    !matches!(
        action,
        MenuAction::RenameClientMachine(_)
            | MenuAction::RenameManagedMachine(_)
            | MenuAction::DeleteManagedMachine(_)
            | MenuAction::RestoreManagedMachine(_)
            | MenuAction::PurgeManagedMachine(_)
            | MenuAction::RenameWorkspace(_)
            | MenuAction::RenameManagedWorkspace(_)
            | MenuAction::DeleteManagedWorkspace(_)
            | MenuAction::RestoreManagedWorkspace(_)
            | MenuAction::PurgeManagedWorkspace(_)
            | MenuAction::CopyWorkspaceId(_)
            | MenuAction::RenameScreen(_)
            | MenuAction::BrowserEditUrl(_)
            | MenuAction::BrowserCopyUrl(_)
            | MenuAction::RenameTab(_)
            | MenuAction::RenameSurface(_)
            | MenuAction::CopyTabId(_)
            | MenuAction::CopyPaneId(_)
            | MenuAction::CopyStatusMessage
            | MenuAction::SelectProviderScope(_)
            | MenuAction::InvokeProviderAction(_)
            | MenuAction::ConnectMachineTarget(_)
            | MenuAction::ConnectOtherMachine
            | MenuAction::ActivateSidebarProfile(_)
            | MenuAction::SetSidebarViewVisible { .. }
    )
}

pub(super) fn provider_action_error_message(error: ProviderActionInputError) -> &'static str {
    let messages = &localization::catalog().sidebar;
    match error {
        ProviderActionInputError::Required => messages.action_required,
        ProviderActionInputError::TooLong => messages.action_too_long,
        ProviderActionInputError::InvalidEmail => messages.action_invalid_email,
        ProviderActionInputError::InvalidInteger => messages.action_invalid_integer,
        ProviderActionInputError::BelowMinimum => messages.action_below_minimum,
        ProviderActionInputError::AboveMaximum => messages.action_above_maximum,
        ProviderActionInputError::MissingSelectedMachine => {
            messages.action_missing_selected_machine
        }
        ProviderActionInputError::MissingSelectedWorkspace => {
            messages.action_missing_selected_workspace
        }
        ProviderActionInputError::UnsupportedFieldCount => {
            messages.action_multiple_fields_unsupported
        }
    }
}

pub(super) fn deferred_paste_bytes(text: &str) -> usize {
    text.len().saturating_add(BRACKETED_PASTE_MARKER_BYTES)
}

pub(super) fn binding_matches(
    chord: &crate::config::Chord,
    key: &KeyEvent,
    fallback: Option<&KeyEvent>,
) -> bool {
    chord.matches(key) || fallback.is_some_and(|fallback| chord.matches(fallback))
}

pub(super) fn action_for_binding(
    keys: &crate::config::Keys,
    key: &KeyEvent,
    fallback: Option<&KeyEvent>,
) -> Option<Action> {
    keys.action_for(key).or_else(|| fallback.and_then(|fallback| keys.action_for(fallback)))
}

pub(super) fn modeless_action_for_binding(
    keys: &crate::config::Keys,
    key: &KeyEvent,
    fallback: Option<&KeyEvent>,
) -> Option<Action> {
    keys.modeless_action_for(key)
        .or_else(|| fallback.and_then(|fallback| keys.modeless_action_for(fallback)))
}
