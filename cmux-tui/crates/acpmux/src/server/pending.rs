//! The `_acpmux/permission_pending` notifications a connection gets: a
//! prompt of this daemon's session, or a peer's (`hub/person.rs` (c)).

use super::*;
use crate::no_panic::JsonExt;
use crate::store::EventRecord;

/// A peer may receive message records, but never the sender host attached by the owning daemon.
/// This is shared by live notifications, replay and event-page responses.
pub fn redact_message_hosts(v: &mut Value) -> bool {
    let mut changed = false;
    match v {
        Value::Array(items) => {
            for item in items {
                changed |= redact_message_hosts(item);
            }
        }
        Value::Object(map) => {
            if map.get("kind").and_then(Value::as_str) == Some("_acpmux/message")
                && let Some(sender) = map
                    .get_mut("msg")
                    .and_then(|msg| msg.get_mut("sender"))
                    .and_then(Value::as_object_mut)
            {
                changed |= sender.remove("host").is_some();
            }
            if map.get("messageId").is_some()
                && map.get("sender").is_some()
                && let Some(sender) = map.get_mut("sender").and_then(Value::as_object_mut)
            {
                changed |= sender.remove("host").is_some();
            }
            for child in map.values_mut() {
                changed |= redact_message_hosts(child);
            }
        }
        _ => {}
    }
    changed
}

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

#[cfg(test)]
mod tests {
    use super::redact_message_hosts;
    use serde_json::json;

    #[test]
    fn peer_message_projection_redacts_sender_host_everywhere() {
        let mut value = json!({
            "method": "_acpmux/message",
            "params": {"sessionId": "s", "sender": {"name": "lane", "sessionId": "src", "host": "gcp-1"}, "text": "hello", "messageId": "m"},
            "event": {"kind": "_acpmux/message", "msg": {"sender": {"name": "lane", "sessionId": "src", "host": "gcp-1"}}},
            "events": [{"kind": "_acpmux/message", "msg": {"sender": {"host": "gcp-1"}}}]
        });
        assert!(redact_message_hosts(&mut value));
        assert!(value.pointer("/params/sender/host").is_none());
        assert!(value.pointer("/event/msg/sender/host").is_none());
        assert!(value.pointer("/events/0/msg/sender/host").is_none());
    }
}
