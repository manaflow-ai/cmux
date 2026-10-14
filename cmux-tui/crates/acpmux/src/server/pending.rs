//! The `_acpmux/permission_pending` notifications a connection gets: a
//! prompt of this daemon's session, or a peer's (`hub/person.rs` (c)).

use super::*;
use crate::store::EventRecord;

/// A record that asks a client to answer a prompt: a new one, or one the
/// next daemon adopted with a new decision nonce (`hub/hosts.rs`).
pub(super) fn is_permission_ask(kind: &str) -> bool {
    matches!(kind, "permission_request" | "permission_reissued")
}

/// The `_acpmux/permission_pending` notification. The record's
/// `decisionNonce` and `personInstance` (the daemon run that asks, also for a
/// peer's session) are what a relayed allow's decision proof covers
/// (`hub/person.rs`, cx-0q7o).
pub(super) fn permission_pending(session_id: &str, rec: &EventRecord, via: &str) -> Value {
    let mut p = rec.msg.clone();
    p["sessionId"] = Value::String(session_id.to_owned());
    p["seq"] = json!(rec.seq);
    p["via"] = Value::String(via.to_owned());
    p
}

/// A peer's `_acpmux/permission_pending` for a watcher of this daemon that
/// did not attach the session (`hub/person.rs` (c)): the peer's own
/// notification (its `decisionNonce` and `personInstance` included), for the
/// session it was checked for (`hub/peers.rs`), with which peer asks.
pub(super) fn peer_permission_pending(session_id: &str, rec: &EventRecord, peer: &str) -> Value {
    let mut p = rec.msg.clone();
    p["sessionId"] = Value::String(session_id.to_owned());
    p["peer"] = Value::String(peer.to_owned());
    p["via"] = Value::String("peer".into());
    p
}

/// A record as `_acpmux/event` sends it.
pub fn event_value(session_id: &str, rec: &EventRecord) -> Value {
    json!({
        "sessionId": session_id,
        "seq": rec.seq,
        "at": rec.at,
        "dir": rec.dir,
        "kind": rec.kind,
        "msg": rec.msg,
    })
}
