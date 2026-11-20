//! A refused Stop is heard. ACP's `session/cancel` is a notification, which has no answer to carry
//! an error, so a refusal used to reach only the debug log: Leo pressed Stop on a lane running on a
//! peer, the peer refused it, and the pane went on showing the turn as stopping (2026-10-29: "i
//! literally can't stop you i clicked the stop button and it didnt do anything"). The connection
//! that sent the notification now gets `_acpmux/cancel_refused {sessionId, message, reason?,
//! peer?}`, and a Stop this daemon forwards to a peer goes there as a request, so the peer's
//! refusal comes back and is passed on under the name the client used.
//!
//! A refusal names the turn it was stopping (`turnId`: the chat's running turn here, or the turn
//! the peer's row showed when the Stop went on), so the pane acts only on the answer to the Stop
//! it is still waiting on, never on a late one for a turn that ended. A refusal is queued in order
//! with every other line (`outbound.rs`), counted against the connection's byte bound.

use super::*;

/// Tells `conn` its `session/cancel` notification for `key` (the `sessionId` it sent) was refused.
pub(super) fn tell(hub: &Hub, conn: &Conn, key: &Value, e: &RpcError) {
    tracing::debug!(conn = %conn.id, "cancel refused: {e}");
    let turn = key.as_str().and_then(|k| turn_of(hub, k));
    send(conn, notice(key.clone(), e, None, turn.as_deref()));
}

/// The turn the chat `key` names runs now: this daemon's own, or the one a peer's row shows.
fn turn_of(hub: &Hub, key: &str) -> Option<String> {
    match hub.resolve(key) {
        Ok(s) => s.turn().map(|t| t.turn_id),
        Err(_) => hub.resolve_remote(key).and_then(|(_, _, row)| row_turn(&row)),
    }
}

/// The running turn a peer's session row shows (`TurnSummary::turn_id`).
pub(super) fn row_turn(row: &Value) -> Option<String> {
    row.pointer("/turn/turnId").and_then(Value::as_str).map(str::to_owned)
}

fn notice(session_id: Value, e: &RpcError, peer: Option<&str>, turn: Option<&str>) -> Value {
    let mut v = serde_json::Map::new();
    v.insert("sessionId".into(), session_id);
    v.insert("message".into(), Value::from(e.message.as_str()));
    let optional = [("reason", reason(e)), ("peer", peer), ("turnId", turn)];
    for (field, value) in optional {
        if let Some(value) = value {
            v.insert(field.into(), Value::from(value));
        }
    }
    Value::Object(v)
}

/// `params` as `_acpmux/cancel_refused` to `conn`, queued in order with every other line in its
/// byte-bounded queue (`outbound.rs`), which drops nothing and waits for nothing: a reader too
/// slow for it is disconnected, and reads the refusal's turn from its cursor when it is back.
fn send(conn: &Conn, params: Value) {
    let msg = Message::notification(method::MUX_CANCEL_REFUSED, params);
    let masked = (!conn.raw_text).then(|| peer_text::masked(&msg)).flatten();
    match masked.as_ref().unwrap_or(&msg).bounded_line() {
        Ok(line) => {
            conn.out.push(line);
        }
        // Larger than a frame: what `Conn::send` does with one (counted once, just now).
        Err(bytes) => conn.left_out_too_large(msg.method(), bytes),
    }
}

fn reason(e: &RpcError) -> Option<&str> {
    e.data.as_ref().and_then(|d| d.get("reason")).and_then(Value::as_str)
}

/// How long a Stop forwarded to a peer waits for the peer's answer: the cancel grace of the peer's
/// own forced end (`hub/cancel.rs`). It waits on the connection's notification worker, so a peer
/// that never answers holds no slot past this.
const FORWARD_ANSWER: std::time::Duration = std::time::Duration::from_secs(10);

/// The Stop of peer `peer`'s chat, which `conn` named `key`, sent on as a request (every acpmux
/// answers one, `{}` once the cancel reaches the agent), awaited on the connection's own
/// notification worker (`NOTIFICATION_WORK_LIMIT`) for at most [`FORWARD_ANSWER`]. Any error, its
/// `connection.busy` and a missing answer included, is told to `conn` and never followed by a
/// second cancel: the request may have reached the peer and stopped this turn before its answer
/// was lost, and a second cancel would stop the next one. The person presses Stop again.
pub(super) async fn forward(
    conn: &Conn,
    peer: Arc<crate::peer::Peer>,
    key: &str,
    turn: Option<String>,
    forwarded: Value,
) {
    let answer =
        tokio::time::timeout(FORWARD_ANSWER, peer.request(method::SESSION_CANCEL, forwarded)).await;
    let e = match answer {
        Ok(Ok(_)) => return,
        Ok(Err(e)) => e,
        Err(_) => RpcError::internal(format!(
            "{} did not answer the Stop within {}s; it may still stop",
            peer.name,
            FORWARD_ANSWER.as_secs()
        ))
        .with_data(json!({"reason": "peer.cancel_unanswered"})),
    };
    tracing::debug!(conn = %conn.id, peer = %peer.name, "forwarded cancel refused: {e}");
    send(conn, notice(Value::from(key), &e, Some(&peer.name), turn.as_deref()));
}
