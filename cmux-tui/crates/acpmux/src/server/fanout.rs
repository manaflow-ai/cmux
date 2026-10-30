//! One event-driven fan-out task per connection, cancelled when its request
//! stream ends. Cached inventory has a separate opt-in and sanitized feed.

use super::{
    Conn, Hub, Message, Ordering, broadcast, deliver, harness_admin, inventory_watch, json,
};
use std::sync::Arc;

pub(super) fn start(hub: Arc<Hub>, conn: Arc<Conn>) -> tokio::task::JoinHandle<()> {
    // How many hub events this task has handed on (`hub/event_bus.rs`): a reply waits
    // for it (`Conn::events_handed_on`), so it never overtakes an event sent before it.
    let (mut rx, mut handed_on) = hub.subscribe_counted();
    let (progress, handed_on_rx) = tokio::sync::watch::channel(handed_on);
    conn.watch_fanout(handed_on_rx);
    let mut harnesses = hub.subscribe_harness_changes();
    let mut catalog = hub.catalog.subscribe();
    let mut inventory = hub.health.inventory_changes();
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
            };
            match ev {
                Ok(ev) => {
                    deliver(&hub, &conn, ev);
                    handed_on += 1;
                }
                Err(broadcast::error::RecvError::Lagged(n)) => {
                    conn.send(&Message::notification("_acpmux/lagged", json!({"dropped": n})));
                    handed_on += n;
                }
                Err(broadcast::error::RecvError::Closed) => break,
            }
            progress.send_replace(handed_on);
        }
    })
}

#[cfg(test)]
#[path = "fanout_tests.rs"]
mod tests;
