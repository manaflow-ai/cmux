//! ACP's two ways to open a stored session on a new connection
//! (https://agentclientprotocol.com/protocol/v1/session-setup): `session/load`
//! (`agentCapabilities.loadSession`) replays the conversation as
//! `session/update` notices before it answers; `session/resume`
//! (`sessionCapabilities.resume`) answers once the session is ready and replays
//! nothing. Both attach the connection, so it hears the session's updates from
//! then on.

use super::*;

/// `session/load`: replay the history as ACP updates, then answer.
pub(super) fn load(
    hub: &Hub,
    conn: &Conn,
    resolved: Option<&Arc<crate::hub::Session>>,
    params: &Value,
) -> Result<Value, RpcError> {
    let s = resolved_session(hub, resolved, params)?;
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
    attach(hub, conn, &s.id);
    Ok(opened(hub, &s))
}

/// The answer to both: the session's modes and config options, and its summary.
fn opened(hub: &Hub, s: &crate::hub::Session) -> Value {
    let meta = s.meta();
    json!({"modes": meta.modes, "configOptions": meta.config_options, "_meta": {"acpmux": hub.session_summary(s)}})
}
