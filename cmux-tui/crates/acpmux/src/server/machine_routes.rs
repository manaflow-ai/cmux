//! `_acpmux/machine_routes` and `_acpmux/machine_route_probe` (`machine_routes.rs`): the app's
//! read of the person's other machines it can open a workspace on, and New Workspace's first
//! ask. This machine's own socket only (the app, or the person's own CLI): a route is a way into
//! another machine's session, so no paired device, web page or peer gets one.

use std::sync::Arc;

use serde_json::{Value, json};

use super::{Conn, Origin};
use crate::hub::Hub;
use crate::rpc::{RpcError, method};

/// The route methods: `None` for every other method.
pub(super) async fn dispatch(
    hub: &Arc<Hub>,
    conn: &Conn,
    m: &str,
    params: &Value,
) -> Option<Result<Value, RpcError>> {
    if !matches!(m, method::MUX_MACHINE_ROUTES | method::MUX_MACHINE_ROUTE_PROBE) {
        return None;
    }
    if conn.origin != Origin::Local || conn.origin.web_class() {
        return Some(Err(RpcError::method_not_found(&format!("{m} (local socket only)"))));
    }
    Some(match m {
        method::MUX_MACHINE_ROUTES => Ok(routes(hub).await),
        _ => probe(hub, params).await,
    })
}

async fn routes(hub: &Arc<Hub>) -> Value {
    let machines = hub.mesh_book_route_machines();
    let daemon_socket = crate::config::socket_path();
    let listed = hub.machine_routes.reconcile(hub, &daemon_socket, &machines).await;
    let carrier = hub.hub_carrier.get();
    // Why this machine is unreachable through the carrier while it cannot heal on its own
    // (`credential-unavailable`), and the action; null while it registers or is registered.
    let reason = carrier.as_ref().and_then(|c| c.serve_reason());
    json!({
        "machines": listed,
        "carrier": carrier.is_some(),
        "carrierReason": reason,
        "carrierAction": reason.map(crate::protocol::peer_state::OfflineReason::action),
    })
}

async fn probe(hub: &Arc<Hub>, params: &Value) -> Result<Value, RpcError> {
    let key = params
        .get("daemonId")
        .and_then(Value::as_str)
        .filter(|k| !k.is_empty())
        .ok_or_else(|| RpcError::invalid_params("daemonId is required"))?;
    match crate::machine_routes::dial(hub, key).await {
        Ok(circuit) => {
            drop(circuit);
            hub.machine_routes.record(key, None);
            Ok(json!({"ok": true}))
        }
        Err(refusal) => {
            hub.machine_routes.record(key, Some(refusal.clone()));
            let message =
                refusal.get("error").and_then(Value::as_str).unwrap_or("refused").to_owned();
            Err(RpcError::new(-32000, message).with_data(refusal))
        }
    }
}
