//! One event-driven fan-out task per connection, cancelled when its request
//! stream ends. Cached inventory has a separate opt-in and sanitized feed.

use super::{
    Conn, Hub, Message, Ordering, broadcast, deliver, durable_gate, harness_admin, inventory_watch,
    json,
};
use std::sync::Arc;
use tokio::sync::{mpsc, oneshot};

/// How long a turn's answer waits for its connection's fan-out to send the updates broadcast
/// before it ([`Flush::sent`]). The fan-out only sends queued lines (it never waits on a client),
/// so this bounds a stalled task, never a slow reader.
const FLUSH_BOUND: std::time::Duration = std::time::Duration::from_secs(2);

/// Asks the connection's fan-out to send every hub event already broadcast. A turn's answer goes
/// on the request's own task, its updates through the fan-out, so under load the answer could
/// overtake the turn's last text: the pane drew the turn ended, then its words, a layout shift
/// (tests/permission_matrix.rs, 2 runs in 50 on a loaded Linux box). Its events are broadcast
/// before the turn's answer resolves, so once the fan-out has drained its queue they are sent.
pub(super) struct Flush(mpsc::UnboundedSender<oneshot::Sender<()>>);

impl Flush {
    pub(super) fn channel() -> (Self, mpsc::UnboundedReceiver<oneshot::Sender<()>>) {
        let (tx, rx) = mpsc::unbounded_channel();
        (Self(tx), rx)
    }

    /// Returns once the fan-out sent what was broadcast before this call, its task ended, or
    /// [`FLUSH_BOUND`] passed.
    pub(super) async fn sent(&self) {
        let (done, sent) = oneshot::channel();
        if self.0.send(done).is_ok() {
            let _ = tokio::time::timeout(FLUSH_BOUND, sent).await;
        }
    }
}

fn send_event(hub: &Arc<Hub>, conn: &Arc<Conn>, ev: crate::hub::HubEvent) {
    // Agent output shows nothing acknowledged: it raises no gate (`durable_gate.rs`).
    let _stream = durable_gate::stream_scope(&ev.record);
    #[cfg(test)]
    tests::panic_if_marked(&ev.session_id);
    deliver(hub, conn, ev);
}

pub(super) fn start(
    hub: Arc<Hub>,
    conn: Arc<Conn>,
    mut flushes: mpsc::UnboundedReceiver<oneshot::Sender<()>>,
) -> tokio::task::JoinHandle<()> {
    let mut rx = hub.subscribe();
    let mut harnesses = hub.subscribe_harness_changes();
    let mut peer_states = hub.peer_states().subscribe();
    let mut catalog = hub.catalog.subscribe();
    let mut inventory = hub.health.inventory_changes();
    let mut presence = hub.presence.subscribe();
    tokio::spawn(async move {
        loop {
            let ev = tokio::select! {
                ev = rx.recv() => ev,
                // A turn's answer waits for the events queued before it (`Flush`).
                Some(done) = flushes.recv() => {
                    loop {
                        match rx.try_recv() {
                            Ok(ev) => send_event(&hub, &conn, ev),
                            Err(broadcast::error::TryRecvError::Lagged(n)) => conn.send(
                                &Message::notification("_acpmux/lagged", json!({"dropped": n})),
                            ),
                            Err(_) => break,
                        }
                    }
                    let _ = done.send(());
                    continue;
                }
                note = harnesses.recv() => {
                    match note {
                        Ok(note) if conn.watch_all.load(Ordering::SeqCst) => {
                            harness_admin::watch_note(&conn, note)
                        }
                        // Lagged: a newer change follows with the full list.
                        Ok(_) | Err(broadcast::error::RecvError::Lagged(_)) => {}
                        Err(broadcast::error::RecvError::Closed) => break,
                    }
                    continue;
                }
                // A peer link's state, to watchers, through the same `watch_note` (`peer_states.rs`).
                // Never to a peer daemon's connection: its handshake watches, and this host's
                // peers, their states and their errors are this machine's, not that peer's.
                note = peer_states.recv() => {
                    let hears = conn.origin != super::Origin::Peer
                        && conn.watch_all.load(Ordering::SeqCst);
                    match note {
                        Ok(note) if hears => harness_admin::watch_note(&conn, note),
                        // Fell behind: a note carries one change, so each peer's last one again.
                        Err(broadcast::error::RecvError::Lagged(_)) if hears => {
                            for note in hub.peer_states().snapshot() {
                                harness_admin::watch_note(&conn, note);
                            }
                        }
                        Ok(_) | Err(broadcast::error::RecvError::Lagged(_)) => {}
                        Err(broadcast::error::RecvError::Closed) => break,
                    }
                    continue;
                }
                // Every connection hears a catalog change: no watch or attach is needed.
                changed = catalog.recv() => {
                    match changed {
                        Ok(summary) => conn.send(&Message::notification(crate::catalog::EVENT_CHANGED, summary)),
                        Err(broadcast::error::RecvError::Lagged(_)) => conn.send(&Message::notification(
                            crate::catalog::EVENT_CHANGED, hub.catalog.summary(),
                        )),
                        Err(broadcast::error::RecvError::Closed) => break,
                    }
                    continue;
                }
                // Who has a chat open (`hub/presence.rs`), to the connections attached to it.
                note = presence.recv() => {
                    match note {
                        Ok(note) => send_presence(&conn, &note),
                        // Fell behind: the chats it holds, as they are now.
                        Err(broadcast::error::RecvError::Lagged(_)) => {
                            for chat in conn.local_attached_ids() {
                                send_presence(&conn, &hub.presence.snapshot(&chat));
                            }
                        }
                        Err(broadcast::error::RecvError::Closed) => break,
                    }
                    continue;
                }
                changed = inventory.changed() => {
                    if changed.is_err() { break; }
                    inventory_watch::send_latest(&conn, &mut inventory).await;
                    continue;
                }
            };
            match ev {
                Ok(ev) => send_event(&hub, &conn, ev),
                Err(broadcast::error::RecvError::Lagged(n)) => {
                    conn.controls.resync(&conn, "lagged");
                    conn.send(&Message::notification("_acpmux/lagged", json!({"dropped": n})));
                }
                Err(broadcast::error::RecvError::Closed) => break,
            }
        }
    })
}

/// `_acpmux/presence` for a chat of this daemon's that `conn` is attached to (not a peer's chat
/// with the same raw id); never to a peer daemon's link, which does not carry presence
/// (`hub/presence.rs`).
fn send_presence(conn: &Conn, note: &serde_json::Value) {
    if conn.origin == super::Origin::Peer {
        return;
    }
    let attached = note
        .get("sessionId")
        .and_then(serde_json::Value::as_str)
        .is_some_and(|chat| conn.sub_opts(chat).is_some_and(|opts| !opts.remote));
    if attached {
        conn.send(&Message::notification(crate::rpc::method::MUX_PRESENCE, note.clone()));
    }
}

/// The fan-out task of `conn` ended while its connection was still open: a panic in a delivery,
/// or the hub's feed closed. The connection ends with it (`serve_connection_from`), never lives on answering
/// requests with no pushes, which left an attached chat standing still with no close.
pub(super) fn ended(conn: &Conn, ended: Result<(), tokio::task::JoinError>) {
    match ended {
        Err(error) if error.is_panic() => {
            tracing::error!(conn = %conn.id, "the connection's fan-out task panicked: it is disconnected");
        }
        _ => {
            tracing::warn!(conn = %conn.id, "the connection's fan-out task ended: it is disconnected")
        }
    }
}

#[cfg(test)]
pub(super) mod tests {
    /// A chat id with this prefix panics the fan-out task at its first delivery: no shared state,
    /// so parallel tests never trip each other (the test-hooks check, cmux#41350).
    pub(in crate::server) const PANIC_PREFIX: &str = "fanout-test-panic-";

    pub(super) fn panic_if_marked(session: &str) {
        if session.starts_with(PANIC_PREFIX) {
            panic!("fan-out test panic for {session}");
        }
    }
}
