//! Local cache subscriptions are separate from session/profile watches, whose
//! diagnostics are private. No client-selected controls reach the health path.

use serde_json::{Value, json};

use super::{Conn, Hub, Message, Origin, RpcError};
use crate::protocol::inventory::InventoryWatchParams;
use crate::rpc::method;

pub(super) const FEATURE: &str = "harnessInventoryWatch";

pub(super) fn handle(hub: &Hub, conn: &Conn, params: &Value) -> Result<Value, RpcError> {
    if conn.origin != Origin::Local {
        return Err(RpcError::invalid_params("cached inventory watches require the local socket"));
    }
    let InventoryWatchParams { enabled } = serde_json::from_value(params.clone())
        .map_err(|_| RpcError::invalid_params("expected only a boolean enabled field"))?;
    let _outbound = conn.out.lock();
    *conn.watch_inventory.lock().unwrap_or_else(std::sync::PoisonError::into_inner) = enabled;
    if enabled { Ok(hub.health.inventory_changes().borrow().wire()) } else { Ok(json!({})) }
}

/// The newest snapshot, queued with the subscription read under the queue's lock, so a disabled
/// connection never gets one queued after it turned the watch off. The queue is bounded in bytes
/// (`outbound.rs`): a reader too slow for it is disconnected, never sent a stale snapshot.
pub(super) async fn send_latest(
    conn: &Conn,
    snapshots: &mut tokio::sync::watch::Receiver<crate::harness_health::inventory_feed::Snapshot>,
) {
    let mut queue = conn.out.lock();
    let enabled = *conn.watch_inventory.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
    if enabled {
        let value = snapshots.borrow_and_update().wire();
        match Message::notification(method::MUX_HARNESS_INVENTORY, value).bounded_line() {
            Ok(line) => {
                queue.push(line);
            }
            // `bounded_line` counted it and warned, at most once a minute (`wire_size.rs`).
            Err(bytes) => tracing::debug!(bytes, "left out an inventory too large to send"),
        }
        return;
    }
    // Do not replay changes that happened while the subscription was off.
    let _ = snapshots.borrow_and_update();
}
