//! A refused Stop is heard. ACP's `session/cancel` is a notification, which has no answer to carry
//! an error, so a refusal used to reach only the debug log: Leo pressed Stop on a lane running on a
//! peer, the peer refused it, and the pane went on showing the turn as stopping (2026-10-29: "i
//! literally can't stop you i clicked the stop button and it didnt do anything"). The connection
//! that sent the notification now gets `_acpmux/cancel_refused {sessionId, message, reason?,
//! peer?}`, and a Stop this daemon forwards to a peer goes there as a request, so the peer's
//! refusal comes back and is passed on under the name the client used.

use super::*;

/// Tells `conn` its `session/cancel` notification for `key` (the `sessionId` it sent) was refused.
pub(super) fn tell(conn: &Conn, key: &Value, e: &RpcError) {
    tracing::debug!(conn = %conn.id, "cancel refused: {e}");
    conn.send(&Message::notification(method::MUX_CANCEL_REFUSED, notice(key.clone(), e, None)));
}

fn notice(session_id: Value, e: &RpcError, peer: Option<&str>) -> Value {
    let mut v = json!({"sessionId": session_id, "message": e.message});
    if let Some(reason) = reason(e) {
        v["reason"] = Value::from(reason);
    }
    if let Some(peer) = peer {
        v["peer"] = Value::from(peer);
    }
    v
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
    conn.send(&Message::notification(
        method::MUX_CANCEL_REFUSED,
        notice(Value::from(key), &e, Some(&peer.name)),
    ));
}
