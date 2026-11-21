//! Clear history helpers: localized failure text, failure classification,
//! shortcut claim policy, and active tab adjustment after a tab is removed.

use cmux_tui_core::{ClearHistoryDelivery, ClearHistoryFailure, SurfaceKind};
use std::collections::HashSet;

use crate::localization;
use crate::pty_input::mark_operation_known_not_delivered;
use crate::session::CLEAR_HISTORY_UNSUPPORTED_ERROR;
use crate::session::tree::PaneView;

pub(super) fn localized_clear_history_failure(error: &str) -> &'static str {
    let messages = &localization::catalog().terminal;
    match error {
        CLEAR_HISTORY_UNSUPPORTED_ERROR => messages.clear_history_unsupported,
        cmux_tui_core::CLEAR_HISTORY_FALLBACK_UNREPRESENTABLE_ERROR => {
            messages.clear_history_fallback_unrepresentable
        }
        cmux_tui_core::CLEAR_HISTORY_PRESERVATION_ERROR => {
            messages.clear_history_preservation_impossible
        }
        cmux_tui_core::CLEAR_HISTORY_STREAM_TIMEOUT_ERROR => messages.clear_history_stream_timeout,
        cmux_tui_core::CLEAR_HISTORY_FALLBACK_WRITE_TIMEOUT_ERROR => {
            messages.clear_history_fallback_write_timeout
        }
        "terminal host does not support clear-history" => messages.clear_history_host_unsupported,
        "terminal host has exited" => messages.clear_history_host_exited,
        "terminal host failed to apply clear-history" => messages.clear_history_host_failed,
        "terminal host returned a malformed clear-history response" => {
            messages.clear_history_host_malformed_response
        }
        "remote session did not respond" => messages.clear_history_remote_no_response,
        "remote response wait canceled for shutdown" => messages.clear_history_remote_disconnected,
        _ if error.starts_with("terminal host did not acknowledge ClearHistory:") => {
            messages.clear_history_host_no_response
        }
        _ if error.starts_with("remote transport write failed:") => {
            messages.clear_history_remote_disconnected
        }
        _ if error.starts_with("remote command rejected:") => {
            messages.clear_history_remote_rejected
        }
        _ => messages.clear_history_unexpected,
    }
}

pub(super) fn classify_clear_history_failure(failure: ClearHistoryFailure) -> anyhow::Error {
    let delivery = failure.delivery();
    let error = failure.into_error();
    if delivery == ClearHistoryDelivery::KnownNotDelivered {
        mark_operation_known_not_delivered(error)
    } else {
        error
    }
}

pub(super) fn should_claim_clear_history_shortcut(
    surface_kind: SurfaceKind,
    supports_atomic_fallback: bool,
) -> bool {
    surface_kind == SurfaceKind::Pty && supports_atomic_fallback
}

/// Repairs `pane`'s selection after the tab at `removed_tab_index` left it (already removed):
/// the daemon's and the app's rule, from the one place it lives (cmux-focus-core
/// `close_focus::tab`, Chrome's, positional here): the tab after the closed one, else the one
/// before it; an unselected close keeps the selection. The rule runs over the strip positions before the removal.
pub(super) fn adjust_active_tab_after_removal(pane: &mut PaneView, removed_tab_index: usize) {
    let old: Vec<usize> = (0..=pane.tabs.len()).collect();
    let surviving: Vec<usize> =
        old.iter().copied().filter(|index| *index != removed_tab_index).collect();
    let shown: HashSet<usize> = surviving.iter().copied().collect();
    // A stale index past the old strip stands for its last tab, as before the shared rule.
    let active = pane.active_tab.min(pane.tabs.len());
    let relations = cmux_focus_core::close_focus::TabRelations::<usize>::default();
    let pick =
        cmux_focus_core::close_focus::tab(Some(&active), &old, &surviving, &shown, &relations);
    let index = pick.map_or(0, |index| index - usize::from(index > removed_tab_index));
    pane.active_tab = index.min(pane.tabs.len().saturating_sub(1));
}
