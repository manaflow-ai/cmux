//! The session a new session reports its turns to (`hub/lane_reports.rs`), from its
//! `session/new`: the session the connection proved it runs in. A run tied to its connection
//! (`ephemeral`) is no lane and has none.

use super::Conn;
use crate::hub::Hub;
use serde_json::Value;
use std::sync::Arc;

/// The parent's exact id, or none.
pub(super) fn lane_parent(hub: &Arc<Hub>, conn: &Conn, params: &Value) -> Option<String> {
    if super::ephemeral::requested(params) {
        return None;
    }
    let caller = conn.caller().filter(|_| !conn.is_person())?;
    // Exactly the proven session: a lookup by name or id prefix could find another session once
    // the caller is gone (one named the caller's former id).
    hub.resolve(caller).ok().filter(|s| s.id == caller).map(|s| s.id.clone())
}
