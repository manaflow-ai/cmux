//! One event-driven fan-out task per connection, cancelled when its request
//! stream ends. Cached inventory has a separate opt-in and sanitized feed.

use super::{
    Conn, Hub, Message, Ordering, broadcast, deliver, harness_admin, inventory_watch, json,
};
use crate::rpc::method;
use std::sync::Arc;

/// A watching client reads `_acpmux/status` again on `_acpmux/status_changed`; a peer
/// daemon's link has no use for it (its own hub tracks its peers).
fn wants_status_changes(conn: &Conn) -> bool {
    conn.watch_all.load(Ordering::SeqCst) && conn.origin != super::Origin::Peer
}

pub(super) fn start(hub: Arc<Hub>, conn: Arc<Conn>) -> tokio::task::JoinHandle<()> {
    let mut rx = hub.subscribe();
    let mut harnesses = hub.subscribe_harness_changes();
    let mut catalog = hub.catalog.subscribe();
    let mut inventory = hub.health.inventory_changes();
    let mut status = hub.subscribe_status_changes();
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
                changed = inventory.changed() => {
                    if changed.is_err() { break; }
                    inventory_watch::send_latest(&conn, &mut inventory).await;
                    continue;
                }
                // Marks made since the last read fold into this one notification.
                changed = status.changed() => {
                    if changed.is_err() { break; }
                    if wants_status_changes(&conn) {
                        conn.send(&Message::notification(method::MUX_STATUS_CHANGED, json!({})));
                    }
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
