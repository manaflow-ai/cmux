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

/// The most records one `session/load` replays, the newest ones, so a long chat's transcript
/// ends where the chat is now. The log is never held whole: a replay reads its records one at a
/// time from where the newest `REPLAY_LIMIT` start (`Hub::newest_window`). It replayed the
/// oldest 100,000 and stopped with no word of it, so a chat past them showed a transcript that
/// ended days back (8 of 175 chats on one lane, 22 of 557 on a Mac's daemon, 2026-11-18).
pub(crate) const REPLAY_LIMIT: u64 = 100_000;

/// `session/load`: replay the history as ACP updates, then answer. A chat past
/// [`REPLAY_LIMIT`] records replays its newest ones, and the answer says what it left out
/// (`_meta.acpmux.replayTruncated`).
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
    let window =
        hub.newest_window(&s.id, REPLAY_LIMIT).map_err(|e| RpcError::internal(e.to_string()))?;
    if window.after > 0 {
        tracing::warn!(
            session = %s.id,
            skipped = window.after,
            total = window.newest,
            limit = REPLAY_LIMIT,
            "session/load replays the newest {REPLAY_LIMIT} records; {} older of {} not replayed",
            window.after,
            window.newest,
        );
    }
    // The replay reads the log from disk: off the runtime's workers (`qos::off_worker`).
    crate::qos::off_worker(|| hub.scan_events(&s.id, window.after, &mut |rec| {
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
        true
    }))
    .map_err(|e| RpcError::internal(e.to_string()))?;
    let mut answer = opened(hub, &s);
    if window.after > 0
        && let Some(meta) = answer.pointer_mut("/_meta/acpmux").and_then(Value::as_object_mut)
    {
        meta.insert("replayTruncated".to_owned(), truncated(window));
    }
    Ok(answer)
}

/// The answer's word that the replay left out the chat's older records: `skipped` of `total`
/// (the chat's records are numbered from 1: the records through seq `skipped`), for a client to
/// show as one line above the transcript ("Older messages not loaded: N of M"). Seqs count every
/// record the chat logged, some of which log retention may have since dropped (`store/compact.rs`).
fn truncated(window: crate::store::NewestWindow) -> Value {
    json!({"skipped": window.after, "total": window.newest, "limit": REPLAY_LIMIT})
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
    json!({"modes": crate::hub::permission_modes::of_session(&meta), "configOptions": meta.config_options, "_meta": {"acpmux": hub.session_summary(s)}})
}
