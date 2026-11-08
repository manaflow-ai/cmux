//! Signing in enrolls this machine (`cli/cloud_join/enroll.rs`), asked by the local app on its
//! acpmux line: `_acpmux/machine_enroll` on sign-in, `_acpmux/machine_leave_if_auto` on sign-out.
//! The daemon runs the enroll itself so the mesh relay starts live when the machine joins, with
//! no restart (a never-joined daemon started none). The access token arrives in the request's
//! params on the local socket only, and goes only into the hub requests: never a log line.

use std::sync::Arc;

use serde_json::{Value, json};
use zeroize::Zeroizing;

use super::{Conn, Origin};
use crate::cli::cloud_join::{EnrollOutcome, EnrollRequest};
use crate::hub::Hub;
use crate::rpc::RpcError;

/// The capability id the app checks before it asks.
pub(crate) const CAPABILITY: &str = "machine-enroll-v1";

/// The local app's socket only: never a peer, a phone or a web page.
fn local(conn: &Conn, method: &str) -> Result<(), RpcError> {
    if conn.origin != Origin::Local || conn.origin.web_class() {
        return Err(RpcError::method_not_found(&format!("{method} (local socket only)")));
    }
    Ok(())
}

/// `_acpmux/machine_enroll {accessToken, hub?, userId?, buildTag?}` -> `{outcome, relay?}`.
pub(super) async fn enroll(hub: &Arc<Hub>, conn: &Conn, params: &Value) -> Result<Value, RpcError> {
    local(conn, crate::rpc::method::MUX_MACHINE_ENROLL)?;
    let access = params
        .get("accessToken")
        .and_then(Value::as_str)
        .filter(|token| !token.trim().is_empty())
        .map(|token| Zeroizing::new(token.trim().to_owned()))
        .ok_or_else(|| RpcError::invalid_params("accessToken is required"))?;
    let text = |key: &str| {
        params.get(key).and_then(Value::as_str).filter(|v| !v.trim().is_empty()).map(str::to_owned)
    };
    let request =
        EnrollRequest { hub: text("hub"), user_id: text("userId"), build_tag: text("buildTag") };
    let outcome = crate::cli::cloud_join::enroll_self(request, access).await;
    tracing::info!(?outcome, "sign-in enroll");
    let relay = match outcome {
        EnrollOutcome::Joined | EnrollOutcome::AlreadyJoined => Some(start_relay(hub).await),
        _ => None,
    };
    Ok(json!({"outcome": outcome, "relay": relay}))
}

/// Starts the mesh relay the join wrote into config.json, unless one is running.
async fn start_relay(hub: &Arc<Hub>) -> &'static str {
    let mut slot = hub.mesh_relay.lock().await;
    if slot.as_ref().is_some_and(|relay| !relay.is_finished()) {
        return "running";
    }
    let Ok(Ok(config)) = tokio::task::spawn_blocking(crate::config::Config::load).await else {
        return "off";
    };
    let Some(relay) = config.mesh_relay else { return "off" };
    hub.config.write().await.mesh_relay = Some(relay);
    match crate::server::mesh_relay::start_configured(hub).await {
        Some(relay) => {
            *slot = Some(relay);
            "started"
        }
        None => "off",
    }
}

/// `_acpmux/machine_leave_if_auto {}` -> `{left, kept?, hub?}`: leaves only a join signing in made.
pub(super) async fn leave_if_auto(hub: &Arc<Hub>, conn: &Conn) -> Result<Value, RpcError> {
    local(conn, crate::rpc::method::MUX_MACHINE_LEAVE_IF_AUTO)?;
    let outcome = crate::cli::cloud_join::leave_if_auto().await;
    tracing::info!(left = outcome.left, kept = ?outcome.kept, "sign-out leave");
    if outcome.left {
        stop_relay(hub).await;
    }
    serde_json::to_value(outcome).map_err(|e| RpcError::internal(e.to_string()))
}

async fn stop_relay(hub: &Arc<Hub>) {
    hub.config.write().await.mesh_relay = None;
    let relay = hub.mesh_relay.lock().await.take();
    if let Some(relay) = relay {
        let _ = tokio::time::timeout(std::time::Duration::from_secs(6), relay.stop()).await;
    }
}

/// The daemon start's mesh relay. A sign-out's leave the last run did not finish is finished
/// first, off the start's path, and the relay starts only if the machine stayed joined.
pub(crate) async fn start_relay_at_start(hub: &Arc<Hub>) {
    if !crate::cli::cloud_join::leave_pending() {
        *hub.mesh_relay.lock().await = crate::server::mesh_relay::start_configured(hub).await;
        return;
    }
    let hub = Arc::clone(hub);
    // task-owner: one leave and maybe the relay start; ends with them (the leave waits at most
    // for the join lock and the hub's bounded answer).
    tokio::spawn(async move {
        let Some(outcome) = crate::cli::cloud_join::finish_leave_at_start().await else {
            *hub.mesh_relay.lock().await = crate::server::mesh_relay::start_configured(&hub).await;
            return;
        };
        tracing::info!(left = outcome.left, kept = ?outcome.kept, "sign-out leave at start");
        if crate::cli::cloud_join::relay_may_start(&outcome) {
            let relay = crate::server::mesh_relay::start_configured(&hub).await;
            *hub.mesh_relay.lock().await = relay;
        } else if outcome.left {
            stop_relay(&hub).await;
        }
    });
}
