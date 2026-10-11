//! Clear history helpers: localized failure text, failure classification,
//! shortcut claim policy, and active tab adjustment after a tab is removed.

use cmux_tui_core::{ClearHistoryDelivery, ClearHistoryFailure, SurfaceKind};

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

pub(super) fn adjust_active_tab_after_removal(pane: &mut PaneView, removed_tab_index: usize) {
    if pane.active_tab > removed_tab_index {
        pane.active_tab -= 1;
    } else if pane.active_tab >= pane.tabs.len() {
        pane.active_tab = pane.tabs.len().saturating_sub(1);
    }
}
