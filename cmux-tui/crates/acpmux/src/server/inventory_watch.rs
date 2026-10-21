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
    *conn.watch_inventory.lock().unwrap_or_else(std::sync::PoisonError::into_inner) = enabled;
    if enabled { Ok(hub.health.inventory_changes().borrow().wire()) } else { Ok(json!({})) }
}

/// Bounded backpressure without a polling timer. Recheck subscription after
/// reserving queue space, then take the newest snapshot so a disabled or slow
/// connection cannot replay an older buffered observation after re-enabling.
pub(super) async fn send_latest(
    conn: &Conn,
    snapshots: &mut tokio::sync::watch::Receiver<crate::harness_health::inventory_feed::Snapshot>,
) {
    let enabled = *conn.watch_inventory.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
    if enabled && let Ok(permit) = conn.out.reserve().await {
        // Serialize enqueue with disable: every earlier notification is queued
        // before the disable reply, and no notification can pass its false flag.
        let enabled =
            conn.watch_inventory.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        if *enabled {
            let value = snapshots.borrow_and_update().wire();
            // Bounded like `Conn::send`: never more than one frame.
            match Message::notification(method::MUX_HARNESS_INVENTORY, value).bounded_line() {
                Ok(line) => permit.send(line),
                Err(bytes) => tracing::warn!(bytes, "left out an inventory too large to send"),
            }
            return;
        }
    }
    // Do not replay changes that happened while the subscription was off.
    let _ = snapshots.borrow_and_update();
}
