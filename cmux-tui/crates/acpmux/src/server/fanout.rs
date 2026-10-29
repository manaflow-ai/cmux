//! One event-driven fan-out task per connection, cancelled when its request
//! stream ends. Cached inventory has a separate opt-in and sanitized feed.

use super::{
    Conn, Hub, Message, Ordering, broadcast, deliver, harness_admin, inventory_watch, json,
};
use std::sync::Arc;

pub(super) fn start(hub: Arc<Hub>, conn: Arc<Conn>) -> tokio::task::JoinHandle<()> {
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
                Ok(ev) => deliver(&hub, &conn, ev),
                Err(broadcast::error::RecvError::Lagged(n)) => {
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
