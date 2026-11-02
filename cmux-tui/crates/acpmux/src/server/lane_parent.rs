//! The session a new session reports its turns to (`hub/lane_reports.rs`), from its
//! `session/new`: the session the connection proved it runs in. A run tied to its connection
//! (`ephemeral`), or one that asks for no parent (`_meta.acpmux.parent: null`, `acpmux new
//! --no-parent`), is no lane and has none.

use super::Conn;
use crate::hub::Hub;
use serde_json::Value;
use std::sync::Arc;

/// The parent's exact id, or none.
pub(super) fn lane_parent(hub: &Arc<Hub>, conn: &Conn, params: &Value) -> Option<String> {
    let root = matches!(
        crate::hub::lineage::parent_ask(super::mux_meta(params)),
        Ok(crate::hub::lineage::ParentAsk::Root)
    );
    if root || super::ephemeral::requested(params) {
        return None;
    }
    let caller = conn.caller().filter(|_| !conn.is_person())?;
    // Exactly the proven session: a lookup by name or id prefix could find another session once
    // the caller is gone (one named the caller's former id).
    hub.resolve(caller).ok().filter(|s| s.id == caller).map(|s| s.id.clone())
}

/// Whether `session/new` was started with `--report-to` (`_meta.acpmux.reportTo`): it asked to
/// report, so a person's prompt keeps its link (`hub/lane_reports.rs`).
pub(super) fn asked_to_report(params: &Value) -> bool {
    super::mux_meta(params)
        .and_then(|m| m.get(crate::hub::lineage::successor::REPORT_TO_FIELD))
        .and_then(Value::as_str)
        .is_some_and(|to| !to.is_empty())
}
