//! ACP's two ways to open a stored session on a new connection
//! (https://agentclientprotocol.com/protocol/v1/session-setup): `session/load`
//! (`agentCapabilities.loadSession`) replays the conversation as
//! `session/update` notices before it answers; `session/resume`
//! (`sessionCapabilities.resume`) answers once the session is ready and replays
//! nothing. Both attach the connection, so it hears the session's updates from
//! then on.

use super::*;

/// Listed in `initialize`'s `_meta.acpmux.features`: this build's `session/resume` replays no
/// history. A peer link forwards a resume only to a peer that lists it (`peer_forward.rs`).
pub const FEATURE: &str = "sessionResume";

/// `session/load`: replay the history as ACP updates, then answer.
pub(super) fn load(
    hub: &Hub,
    conn: &Conn,
    resolved: Option<&Arc<crate::hub::Session>>,
    params: &Value,
) -> Result<Value, RpcError> {
    let s = resolved_session(hub, resolved, params)?;
    // Before the attach: a message the live stream sends during the replay is not
    // replayed again, nor one replayed sent live (`MessageNotices`).
    conn.message_notices.lock().unwrap_or_else(|e| e.into_inner()).reopen(None, &s.id);
    attach(hub, conn, &s.id);
    // One record at a time, the first 100,000 as before: the log is never held whole.
    let mut left = 100_000usize;
    hub.scan_events(&s.id, 0, &mut |rec| {
        left -= 1;
        if rec.dir == "mux" && rec.kind == "user_message" {
            let text = rec.msg.get("text").and_then(Value::as_str).unwrap_or("");
            conn.send(&Message::notification(
                method::SESSION_UPDATE,
                json!({"sessionId": s.id, "update": {"sessionUpdate": "user_message_chunk", "content": {"type": "text", "text": text}}, "_meta": {"acpmux": {"seq": rec.seq, "at": rec.at, "replay": true}}}),
            ));
        } else if rec.dir == "mux" && rec.kind == "_acpmux/message" {
            // Once, whether the live stream or this replay sends it first.
            let fresh = conn
                .message_notices
                .lock()
                .unwrap_or_else(|e| e.into_inner())
                .replay(None, &s.id, rec.seq);
            // Another daemon's link, served as Peer or added with the dashboard token
            // (`view::a_link`), takes the event envelope, so its hub keeps the sequence
            // and replays it after a reconnect: its hub reads no compact notice.
            // Person/app clients keep the compact notice they already consume.
            if fresh && super::super::view::a_link(conn) {
                conn.send(&Message::notification(
                    method::MUX_EVENT,
                    super::super::event_value(&s.id, &rec),
                ));
            } else if fresh {
                conn.send(&Message::notification(method::MUX_MESSAGE, rec.msg.clone()));
            }
        } else if rec.dir == "in"
            && !rec.kind.ends_with(".replay")
            && rec.msg.get("method").and_then(Value::as_str) == Some(method::SESSION_UPDATE)
        {
            let mut p = rec.msg.get("params").cloned().unwrap_or(json!({}));
            p.set("sessionId", Value::String(s.id.clone()));
            crate::hub::merge_mux_meta(
                &mut p,
                json!({"seq": rec.seq, "at": rec.at, "kind": rec.kind, "replay": true}),
            );
            conn.send(&Message::notification(method::SESSION_UPDATE, p));
        }
        left > 0
    })
    .map_err(|e| RpcError::internal(e.to_string()))?;
    Ok(opened(hub, &s))
}

/// `session/resume`: attach and answer, with no history ("the Agent MUST NOT
/// replay the conversation history"). A client that wants it reads it with
/// `_acpmux/attach` or `session/load`.
pub(super) fn resume(
    hub: &Hub,
    conn: &Conn,
    resolved: Option<&Arc<crate::hub::Session>>,
    params: &Value,
) -> Result<Value, RpcError> {
    let s = resolved_session(hub, resolved, params)?;
    // This connection's own reopen, as for a load: it hears the chat's messages again, live.
    conn.message_notices.lock().unwrap_or_else(|e| e.into_inner()).reopen(None, &s.id);
    attach(hub, conn, &s.id);
    Ok(opened(hub, &s))
}

/// The answer to both: the session's modes and config options, and its summary.
fn opened(hub: &Hub, s: &crate::hub::Session) -> Value {
    let meta = s.meta();
    json!({"modes": meta.modes, "configOptions": meta.config_options, "_meta": {"acpmux": hub.session_summary(s)}})
}
