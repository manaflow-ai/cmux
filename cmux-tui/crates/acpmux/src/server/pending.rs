//! The `_acpmux/permission_pending` notifications a connection gets: a
//! prompt of this daemon's session, or a peer's (`hub/person.rs` (c)).

use super::*;
use crate::no_panic::JsonExt;
use crate::store::EventRecord;

/// The `_acpmux/permission_pending` notification. The record's
/// `decisionNonce` and `personInstance` (the daemon run that asks, also for a
/// peer's session) are what a relayed allow's decision proof covers
/// (`hub/person.rs`, cx-0q7o).
pub(super) fn permission_pending(session_id: &str, rec: &EventRecord, via: &str) -> Value {
    let mut p = rec.msg.clone();
    p.set("sessionId", Value::String(session_id.to_owned()));
    p.set("seq", json!(rec.seq));
    p.set("via", Value::String(via.to_owned()));
    p
}

/// A peer's `_acpmux/permission_pending` for a watcher of this daemon that
/// did not attach the session (`hub/person.rs` (c)): the peer's own
/// notification (its `decisionNonce` and `personInstance` included), for the
/// session it was checked for (`hub/peers.rs`), with which peer asks.
pub(super) fn peer_permission_pending(session_id: &str, rec: &EventRecord, peer: &str) -> Value {
    let mut p = rec.msg.clone();
    p.set("sessionId", Value::String(session_id.to_owned()));
    p.set("peer", Value::String(peer.to_owned()));
    p.set("via", Value::String("peer".into()));
    p
}

/// A record as `_acpmux/event` sends it.
pub fn event_value(session_id: &str, rec: &EventRecord) -> Value {
    let event = crate::protocol::events::SessionEvent {
        session_id: session_id.to_owned(),
        seq: rec.seq,
        at: rec.at,
        dir: rec.dir.clone(),
        kind: rec.kind.clone(),
        msg: rec.msg.clone(),
    };
    serde_json::to_value(event).unwrap_or(Value::Null)
}

/// [`event_value`] that takes the record, so its message moves instead of being copied.
pub fn into_event_value(session_id: &str, rec: EventRecord) -> Value {
    json!({
        "sessionId": session_id,
        "seq": rec.seq,
        "at": rec.at,
        "dir": rec.dir,
        "kind": rec.kind,
        "msg": rec.msg,
    })
}
