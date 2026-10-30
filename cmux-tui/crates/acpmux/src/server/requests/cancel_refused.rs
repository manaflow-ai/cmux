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

/// The Stop of peer `peer`'s chat, which `conn` named `key`, sent on as a request (every acpmux
/// answers one, `{}` once the cancel reaches the agent), on its own task so a slow link holds no
/// notification slot here. A refusal or an unreachable peer: `conn` hears it. An error that names
/// no reason (the link's request limit, a closed link): the notification, as before this, and
/// `conn` hears only if that cannot go either.
pub(super) fn forward(conn: &Arc<Conn>, peer: Arc<crate::peer::Peer>, key: &str, forwarded: Value) {
    let (conn, key) = (conn.clone(), Value::from(key));
    tokio::spawn(async move {
        let Err(e) = peer.request(method::SESSION_CANCEL, forwarded.clone()).await else { return };
        let e = if reason(&e).is_some() {
            e
        } else {
            match peer.notify(method::SESSION_CANCEL, forwarded).await {
                Ok(()) => return,
                Err(e) => e,
            }
        };
        tracing::debug!(conn = %conn.id, peer = %peer.name, "forwarded cancel refused: {e}");
        conn.send(&Message::notification(
            method::MUX_CANCEL_REFUSED,
            notice(key, &e, Some(&peer.name)),
        ));
    });
}
