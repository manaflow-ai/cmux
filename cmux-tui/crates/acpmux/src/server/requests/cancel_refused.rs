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
//! it is still waiting on, never on a late one for a turn that ended. And it is never dropped as a
//! lossy notification is when the client reads slowly: it waits for room ([`Waiting`]).

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

/// How many refusals (one per chat and turn) wait for room at once on one connection.
const WAITING_KEYS: usize = 16;

/// The refusals that wait for room in a connection's outbound queue, by the chat and turn each
/// answers ([`wait_key`]), sent in turn by one task. A notification is dropped when the client
/// reads too slowly (`enqueue_outbound`); a refusal is not, or the pane would show Stopping for
/// good. The newest refusal for a chat's turn replaces the one waiting, and at most
/// [`WAITING_KEYS`] wait, so a client that sends Stops and never reads holds at most that many
/// lines here.
#[derive(Default)]
pub(in crate::server) struct Waiting {
    inner: StdMutex<WaitingInner>,
}

#[derive(Default)]
struct WaitingInner {
    lines: std::collections::BTreeMap<String, String>,
    draining: bool,
}

impl WaitingInner {
    /// Keeps `line` for `key`; false when it is a new key past [`WAITING_KEYS`].
    fn keep(&mut self, key: String, line: String) -> bool {
        if self.lines.len() >= WAITING_KEYS && !self.lines.contains_key(&key) {
            return false;
        }
        self.lines.insert(key, line);
        true
    }
}

/// What a waiting refusal replaces: the one waiting for the same chat and turn. Two turns' wait
/// side by side, since Stops of one chat may be answered out of order (a forward waits up to
/// [`FORWARD_ANSWER`]) and the pane takes only the one for the turn it stopped.
fn wait_key(params: &Value) -> String {
    let session = params["sessionId"].as_str().unwrap_or_default();
    let turn = params["turnId"].as_str().unwrap_or_default();
    format!("{session}\n{turn}")
}

/// `params` as `_acpmux/cancel_refused` to `conn`, through [`Waiting`].
fn send(conn: &Conn, params: Value) {
    let key = wait_key(&params);
    let msg = Message::notification(method::MUX_CANCEL_REFUSED, params);
    let masked = (!conn.raw_text).then(|| peer_text::masked(&msg)).flatten();
    let line = match masked.as_ref().unwrap_or(&msg).bounded_line() {
        Ok(line) => line,
        // Larger than a frame: what `Conn::send` does with one (counted once, just now).
        Err(bytes) => return conn.left_out_too_large(msg.method(), bytes),
    };
    let mut inner = conn.cancel_refusals.inner.lock().unwrap_or_else(|e| e.into_inner());
    if !inner.keep(key, line) {
        tracing::warn!(conn = %conn.id, "left out a cancel refusal: {WAITING_KEYS} wait already");
        return;
    }
    if std::mem::replace(&mut inner.draining, true) {
        return;
    }
    drop(inner);
    let (out, waiting) = (conn.out.clone(), conn.cancel_refusals.clone());
    tokio::spawn(async move {
        loop {
            let line = {
                let mut inner = waiting.inner.lock().unwrap_or_else(|e| e.into_inner());
                let Some((_, line)) = inner.lines.pop_first() else {
                    inner.draining = false;
                    return;
                };
                line
            };
            // Waits for room; ends with the connection (its reader gone).
            if out.send(line).await.is_err() {
                return;
            }
        }
    });
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

#[cfg(test)]
mod tests {
    use super::{WAITING_KEYS, WaitingInner, wait_key};
    use serde_json::json;

    /// Two Stops of one chat answered out of order (the first a forward that took its 10 s):
    /// the later turn's refusal, still waiting, is not replaced by the earlier turn's, which
    /// the pane ignores, or the later Stop would read as stopping for good.
    #[test]
    fn refusals_for_two_turns_of_a_chat_both_wait() {
        let mut w = WaitingInner::default();
        let later = json!({"sessionId": "a", "turnId": "t2"});
        let earlier = json!({"sessionId": "a", "turnId": "t1"});
        assert!(w.keep(wait_key(&later), "t2".into()));
        assert!(w.keep(wait_key(&earlier), "t1".into()));
        let mut kept: Vec<&str> = w.lines.values().map(String::as_str).collect();
        kept.sort();
        assert_eq!(kept, ["t1", "t2"], "a refusal of an earlier turn replaced the later one's");
        // The same turn's newer refusal still replaces the one waiting.
        assert!(w.keep(wait_key(&later), "t2 again".into()));
        assert_eq!(w.lines.len(), 2);
    }

    #[test]
    fn the_newest_refusal_for_a_key_waits_and_only_so_many_wait() {
        let mut w = WaitingInner::default();
        assert!(w.keep("a".into(), "1".into()));
        assert!(w.keep("a".into(), "2".into()));
        assert_eq!(w.lines.len(), 1);
        assert_eq!(w.lines["a"], "2", "the newest for a key replaces the one waiting");
        for n in 1..WAITING_KEYS {
            assert!(w.keep(format!("k{n}"), "x".into()));
        }
        assert_eq!(w.lines.len(), WAITING_KEYS);
        assert!(!w.keep("one-more".into(), "x".into()), "a key past the cap waits not");
        assert!(w.keep("a".into(), "3".into()), "a key that waits is still replaced");
    }
}
