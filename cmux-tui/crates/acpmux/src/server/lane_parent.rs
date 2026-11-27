//! The session a new session reports its turns to (`hub/lane_reports.rs`), from its
//! `session/new`: the session the connection proved it runs in. A run tied to its connection
//! (`ephemeral`), or one that asks for no parent (`_meta.acpmux.parent: null`, `acpmux new
//! --no-parent`), is no lane and has none.

use super::Conn;
use crate::hub::{Hub, Session};
use crate::rpc::RpcError;
use serde_json::Value;
use std::sync::Arc;

pub(super) fn mark_forwarded_boundary(
    hub: &Hub,
    conn: &Conn,
    original: &Value,
    peer: &crate::peer::Peer,
    forwarded: &mut Value,
) {
    if let Some(meta) = forwarded.pointer_mut("/_meta/acpmux").and_then(Value::as_object_mut) {
        meta.remove(crate::hub::vm_boundary::FIELD);
    }
    let owner = crate::hub::vm_boundary::owner(
        conn.auth,
        super::remote_guard::control_of(conn.origin, conn.auth, original),
        original,
    );
    if owner
        && (peer.vm_boundary() || crate::hub::agent_vm::registry_agent_vm(&peer.name, &peer.url))
    {
        crate::hub::merge_mux_meta(
            forwarded,
            serde_json::json!({crate::hub::vm_boundary::FIELD: true}),
        );
    } else if hub.is_leased(&peer.name) {
        crate::hub::merge_mux_meta(
            forwarded,
            serde_json::json!({crate::hub::vm_boundary::FIELD: false}),
        );
    }
}

pub(super) fn mark_control_boundary(params: &mut Value, same_person: bool) {
    if !same_person {
        crate::hub::merge_mux_meta(
            params,
            serde_json::json!({"via": crate::hub::vm_boundary::VIA_DEVICE, crate::hub::vm_boundary::FIELD: false}),
        );
    }
}

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

/// Keep the report on the starter's daemon: a refused tool in the child must not
/// also prevent it from reporting the refusal. The existing durable watch/outbox
/// owns delivery, including reconnects and daemon restarts.
pub(super) fn remote_report_target(
    hub: &Arc<Hub>,
    conn: &Conn,
    params: &Value,
) -> Result<Option<String>, RpcError> {
    // A forwarded caller cannot borrow this daemon's sender authority.
    if !matches!(conn.origin, super::Origin::Local | super::Origin::LocalApp) {
        return Ok(None);
    }
    let explicit = super::mux_meta(params)
        .and_then(|m| m.get(crate::hub::lineage::successor::REPORT_TO_FIELD))
        .and_then(Value::as_str)
        .filter(|to| !to.is_empty());
    let parent = lane_parent(hub, conn, params);
    explicit.or(parent.as_deref()).map(|to| crate::hub::watches::resolve(hub, to)).transpose()
}

pub(super) fn report_remote_created(
    hub: &Arc<Hub>,
    conn: &Conn,
    to: Option<String>,
    peer: &str,
    id: &str,
) -> Result<(), RpcError> {
    use crate::hub::watches::Watch;
    let Some(to) = to else { return Ok(()) };
    let key = format!("{peer}/{id}");
    hub.watches.add(
        hub,
        Watch {
            // Session ids are scoped to their owning daemon, not globally unique.
            id: format!("remote-start-{}", uuid::Uuid::now_v7()),
            to,
            sessions: vec![key.clone()],
            // Normal turns and permission prompts must not consume the failure report.
            until: vec!["closed".into(), "blocked".into()],
            match_text: None,
            once: true,
            caller: conn.caller().filter(|_| !conn.is_person()).map(str::to_owned),
            active: true,
            // No initial ready verdict: the new chat has not received its prompt.
            // Read its journal from the start so a fast spawn refusal is not lost.
            cursors: [(key, Default::default())].into_iter().collect(),
            offline: Default::default(),
            ..Default::default()
        },
    )?;
    Ok(())
}

/// The person wrote to `s`: a lane is theirs now, and its turns stop showing in its parent's chat
/// (`hub/lane_detach.rs`).
pub(super) fn person_wrote(hub: &Hub, s: &Session) {
    s.person_wrote();
    hub.lane_person_prompted(s);
}

/// `_acpmux/detach_parent {sessionId}`: ends the session's link to its parent and removes its
/// tag `lane.reportsTo`.
pub(super) fn detach(hub: &Hub, params: &Value) -> Result<Value, RpcError> {
    let s = hub.resolve(super::session_key(params)?)?;
    let detached = hub.lane_detach(&s)?;
    Ok(serde_json::json!({"sessionId": s.id, "detached": detached}))
}
