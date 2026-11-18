//! A hidden page's list (`_acpmux/watch {shown}`). Leo, 2026-11-18: "Why should non visible thing
//! even affect the renderer thread anyways?"
//!
//! Every agent page watches the whole session list, the hidden New Tab page and the prewarmed
//! spare page too, and all of them share one renderer: each change of any chat went to every page
//! and was parsed and folded there, seen or not. A page says when it is hidden; while it is, its
//! connection hears only the chats it is attached to (`deliver`, `processes::push_update`, the
//! peer states in `fanout`). Shown again, its watch follows the list (`hub/row_log.rs`) from the
//! last position the connection was sent while shown, so it reads exactly the rows it was not
//! sent, whatever the list's size; a log that cannot follow answers the list, marked `reset`.
//!
//! A client that never names `shown` (an older page, a peer's link, the CLI) is shown: it hears
//! every chat as before.

use super::{Conn, Hub, Ordering, harness_admin};
use crate::rpc::RpcError;
use serde_json::Value;

/// The `initialize` capability of a daemon that takes `shown` on `_acpmux/watch`.
pub const CAPABILITY: &str = "session-list-shown-v1";

/// What a watch's `shown` did to the connection.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum Change {
    /// Nothing.
    Same,
    /// A shown list was hidden.
    Hidden,
    /// A hidden list was shown; `sent`: the last position it was sent while shown.
    Shown { sent: u64 },
}

/// `shown` of a watch: None when the client names none.
pub(super) fn shown(params: &Value) -> Result<Option<bool>, RpcError> {
    match params.get("shown") {
        None | Some(Value::Null) => Ok(None),
        Some(Value::Bool(shown)) => Ok(Some(*shown)),
        Some(_) => Err(RpcError::invalid_params("shown must be a boolean")),
    }
}

/// Hides or shows the connection's list. A show reads the last position sent before the list is
/// shown: a change dropped while hidden is past it, and one sent after is too. Each peer's last
/// state, which a hidden page did not hear, goes out again.
pub(super) fn set(hub: &Hub, conn: &Conn, shown: Option<bool>, on: bool) -> Change {
    match shown {
        None => Change::Same,
        Some(false) => {
            if conn.list_hidden.swap(true, Ordering::SeqCst) {
                Change::Same
            } else {
                Change::Hidden
            }
        }
        Some(true) => {
            let sent = conn.list_sent.load(Ordering::SeqCst);
            if !conn.list_hidden.swap(false, Ordering::SeqCst) || !on {
                return Change::Same;
            }
            if conn.origin != super::Origin::Peer {
                for note in hub.peer_states().snapshot() {
                    harness_admin::watch_note(conn, note);
                }
            }
            Change::Shown { sent }
        }
    }
}

/// The watch's reply is current to list position `head`: the connection was sent every row to it,
/// unless this watch hid a list it already watched. That hide's reply is not applied (the page
/// heard its rows as notices, `sessionPages.ts` `hide`), and a change stamped before `head` but
/// not yet sent here when the list hid is dropped, so the show must follow from before it.
pub(super) fn answered(conn: &Conn, change: Change, was_watching: bool, head: u64) {
    if change == Change::Hidden && was_watching {
        return;
    }
    conn.list_sent.fetch_max(head, Ordering::SeqCst);
}

/// The cursor a show follows from: the client's, or the last position this connection was sent if
/// that is lower (a notice of a chat it is attached to may have moved the client's past rows it was
/// not sent). A cursor of another run stays one (`u64::MAX`), which the log answers `reset`.
pub(super) fn follow_from(change: Change, after: Option<u64>) -> Option<u64> {
    match (change, after) {
        (Change::Shown { sent }, Some(after)) if after != u64::MAX => Some(after.min(sent)),
        (_, after) => after,
    }
}
