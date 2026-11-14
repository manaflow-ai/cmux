//! Signing in enrolls this machine (`cli/cloud_join/enroll.rs`), asked by the local app on its
//! acpmux line: `_acpmux/machine_enroll` on sign-in, `_acpmux/machine_leave_if_auto` on sign-out.
//! The daemon runs the enroll itself so the mesh relay starts live when the machine joins, with
//! no restart (a never-joined daemon started none). The access token arrives in the request's
//! params on the local socket only, and goes only into the hub requests: never a log line.
//!
//! Every change of the join on this daemon (the start's leave and relay, an enroll, a leave,
//! shutdown) holds `Hub::join_transition` throughout, and reads config.json's relay once it
//! holds it: none starts or stops a relay on what it read before another changed the join.

use std::future::Future;
use std::sync::Arc;

use futures::future::BoxFuture;
use serde_json::{Value, json};
use zeroize::Zeroizing;

use super::{Conn, Origin};
use crate::cli::cloud_join::{EnrollOutcome, EnrollRequest, LeaveOutcome};
use crate::hub::Hub;
use crate::mesh_http::MeshRelayConfig;
use crate::no_panic::LockExt;
use crate::rpc::RpcError;

/// The local app's socket only: never a peer, a phone or a web page. And only the person
/// (`hub/person.rs`): a local shell or agent may neither leave this machine's join nor enroll it
/// with a token and user id it chose, so a connection that did not prove the person is refused
/// with the declared `permission.person_required`.
pub(super) fn local(conn: &Conn, method: &str) -> Result<(), RpcError> {
    if conn.origin != Origin::Local || conn.origin.web_class() {
        return Err(RpcError::method_not_found(&format!("{method} (local socket only)")));
    }
    if !conn.is_person() {
        return Err(crate::hub::person::person_required(match method {
            crate::rpc::method::MUX_MACHINE_ENROLL | crate::rpc::method::MUX_MACHINE_SIGNED_IN => {
                "enrolling this machine in cmux Cloud"
            }
            _ => "removing this machine from cmux Cloud",
        }));
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
    let (outcome, relay) =
        enroll_transition(hub, crate::cli::cloud_join::enroll_self(request, access), || {
            relay_on_disk(hub)
        })
        .await;
    Ok(json!({"outcome": outcome, "relay": relay}))
}

/// A sign-in's enroll (`enroll`) with the join transition held, then the relay as config.json
/// says once it is done (`on_disk`).
pub(super) async fn enroll_transition<D: Future<Output = Option<MeshRelayConfig>>>(
    hub: &Arc<Hub>,
    enroll: impl Future<Output = EnrollOutcome>,
    on_disk: impl FnOnce() -> D,
) -> (EnrollOutcome, Option<&'static str>) {
    let _join = hub.join_transition.lock().await;
    let outcome = enroll.await;
    tracing::info!(?outcome, "sign-in enroll");
    let relay = match outcome {
        EnrollOutcome::Joined | EnrollOutcome::AlreadyJoined => {
            // A new join (this enroll may have finished another account's leave first, with no
            // stop of the relay between) never keeps the relay the last join's config started.
            let replaced = outcome == EnrollOutcome::Joined;
            // So does the carrier: one the last join started stops first, with the relay's hub
            // client, so no ticket goes out on the last join's config meanwhile, then runs
            // again on this join's.
            let carrier_ran = replaced && stop_carrier(hub);
            let relay = reconcile_relay(hub, on_disk().await, replaced).await;
            if carrier_ran {
                start_carrier(hub, carrier_websocket(hub)).await;
            }
            Some(relay)
        }
        _ => None,
    };
    (outcome, relay)
}

/// config.json's `meshRelay` now; the one this daemon loaded when config.json cannot be read.
pub(super) async fn relay_on_disk(hub: &Arc<Hub>) -> Option<MeshRelayConfig> {
    match tokio::task::spawn_blocking(crate::config::Config::load).await {
        Ok(Ok(config)) => config.mesh_relay,
        _ => hub.config.read().await.mesh_relay.clone(),
    }
}

/// Makes the running relay what config.json says (`on_disk`), with the join transition held:
/// started when it names one and none runs, stopped (with its hub client) when it names none.
/// A running relay is kept only when it runs on that same config and the join is the same
/// (`replaced` false): otherwise it is stopped and started again, so the control grants, hub and
/// credential it holds are never the last join's.
async fn reconcile_relay(
    hub: &Arc<Hub>,
    on_disk: Option<MeshRelayConfig>,
    replaced: bool,
) -> &'static str {
    let Some(relay) = on_disk else {
        stop_joined(hub).await;
        return "off";
    };
    let mut slot = hub.mesh_relay.lock().await;
    if slot.as_ref().is_some_and(|running| !running.is_finished()) {
        let same = hub.config.read().await.mesh_relay.as_ref() == Some(&relay);
        if same && !replaced {
            return "running";
        }
        if let Some(old) = slot.take() {
            // Its hub client goes first: no send goes out with the last join's credential while
            // the old relay stops, or after, when the new one does not start.
            hub.mesh.clear();
            // timeout: a relay that will not stop is dropped; the new one starts regardless.
            let _ = tokio::time::timeout(std::time::Duration::from_secs(6), old.stop()).await;
        }
    }
    start_relay_with(hub, &mut slot, relay).await
}

/// Starts the mesh relay on `relay`, the join's config, into `slot` (`Hub::mesh_relay`); its
/// client becomes the one sends go through (`Hub::mesh`), replacing a leave's cleared one. One
/// that does not start leaves no client: sends are refused, never sent through an earlier one.
async fn start_relay_with(
    hub: &Arc<Hub>,
    slot: &mut Option<crate::server::mesh_relay::MeshRelay>,
    relay: crate::mesh_http::MeshRelayConfig,
) -> &'static str {
    hub.config.write().await.mesh_relay = Some(relay);
    match crate::server::mesh_relay::start_configured(hub).await {
        Some(relay) => {
            *slot = Some(relay);
            "started"
        }
        None => {
            hub.mesh.clear();
            "off"
        }
    }
}

/// `_acpmux/machine_leave_if_auto {userId?}` -> `{left, kept?, hub?}`: leaves only a join signing
/// in made for `userId`, the account signing out. With no account named, or a join recorded under
/// another or no account, the join stays.
pub(super) async fn leave_if_auto(
    hub: &Arc<Hub>,
    conn: &Conn,
    params: &Value,
) -> Result<Value, RpcError> {
    local(conn, crate::rpc::method::MUX_MACHINE_LEAVE_IF_AUTO)?;
    let account = params.get("userId").and_then(Value::as_str).filter(|v| !v.trim().is_empty());
    let outcome = leave_transition(hub, crate::cli::cloud_join::leave_if_auto(account)).await;
    serde_json::to_value(outcome).map_err(|e| RpcError::internal(e.to_string()))
}

/// A sign-out's leave (`leave`) with the join transition held, then what it stops here.
pub(super) async fn leave_transition(
    hub: &Arc<Hub>,
    leave: impl Future<Output = LeaveOutcome>,
) -> LeaveOutcome {
    let _join = hub.join_transition.lock().await;
    let outcome = leave.await;
    tracing::info!(left = outcome.left, kept = ?outcome.kept, "sign-out leave");
    after_leave(hub, &outcome).await;
    outcome
}

/// What a sign-out's leave stops on this daemon: the hub carrier whenever the join went, and the
/// relay only when the leave removed the join's from config.json. A relay the person set up, or
/// another hub's, which the leave keeps on disk, keeps running here too, and sends keep its hub
/// client. The caller holds the join transition.
async fn after_leave(hub: &Arc<Hub>, outcome: &LeaveOutcome) {
    if !outcome.left {
        return;
    }
    if outcome.relay_removed {
        stop_joined(hub).await;
    } else if stop_carrier(hub) {
        tracing::info!("hub carrier: stopped by the sign-out's leave; the person's relay runs on");
    }
}

/// Stops everything the join started on this daemon: the mesh relay, the hub client sends went
/// through (`Hub::mesh`, so a later enroll's relay sets its own hub's), and the hub carrier's
/// registration on the relay.
async fn stop_joined(hub: &Arc<Hub>) {
    hub.config.write().await.mesh_relay = None;
    let relay = hub.mesh_relay.lock().await.take();
    // Before the stop: no send or carrier ticket goes out with the left join's credential while
    // it stops.
    hub.mesh.clear();
    if stop_carrier(hub) {
        tracing::info!("hub carrier: stopped by the sign-out's leave");
    }
    if let Some(relay) = relay {
        // timeout: a relay that will not stop is dropped; the leave goes on regardless.
        let _ = tokio::time::timeout(std::time::Duration::from_secs(6), relay.stop()).await;
    }
}

/// Stops the hub carrier the daemon's start ran, if it runs; true when one ran.
#[cfg(feature = "hub-carrier")]
pub(crate) fn stop_carrier(hub: &Hub) -> bool {
    crate::hub_carrier::stop_kept(hub)
}

#[cfg(not(feature = "hub-carrier"))]
pub(crate) fn stop_carrier(_hub: &Hub) -> bool {
    false
}

/// The loopback address the start gave the carrier, if it gave one.
#[cfg(feature = "hub-carrier")]
fn carrier_websocket(hub: &Hub) -> Option<std::net::SocketAddr> {
    hub.hub_carrier_websocket.get().copied()
}

#[cfg(not(feature = "hub-carrier"))]
fn carrier_websocket(_hub: &Hub) -> Option<std::net::SocketAddr> {
    None
}

/// Starts the hub carrier on the relay config.json names, with `carrier` (the daemon's loopback
/// WebSocket address; None for a copied home), unless one runs. The caller holds the join
/// transition.
async fn start_carrier(hub: &Arc<Hub>, carrier: Option<std::net::SocketAddr>) {
    #[cfg(feature = "hub-carrier")]
    if let Some(websocket) = carrier {
        let _ = hub.hub_carrier_websocket.set(websocket);
    }
    #[cfg(feature = "hub-carrier")]
    if carrier.is_some() && hub.hub_carrier_serve.lock_or_recover().is_none() {
        crate::hub_carrier::start_kept(hub, carrier).await;
    }
    #[cfg(not(feature = "hub-carrier"))]
    let _ = (hub, carrier);
}

/// The daemon start's mesh relay and hub carrier. A sign-out's leave the last run did not finish
/// (its mark, or its cleanup's `removing` mark) is finished first, off the start's path; then the
/// relay is what config.json says, and the carrier starts only if the machine stayed joined: a
/// revoked machine never registers its carrier again. The join transition is taken before this
/// returns and held until both are settled, so an enroll or leave asked meanwhile waits for it,
/// then acts on what it left; its task is kept on the hub (`Hub::join_start`).
pub(crate) async fn start_joined_at_start(hub: &Arc<Hub>, carrier: Option<std::net::SocketAddr>) {
    let join = Arc::clone(&hub.join_transition).lock_owned().await;
    let pending = crate::cli::cloud_join::leave_pending();
    let hub_for_disk = Arc::clone(hub);
    let task = at_start(
        hub,
        join,
        pending,
        crate::cli::cloud_join::finish_leave_at_start(),
        move || async move { relay_on_disk(&hub_for_disk).await },
        move |hub: Arc<Hub>| -> BoxFuture<'static, ()> {
            Box::pin(async move { start_carrier(&hub, carrier).await })
        },
    )
    .await;
    *hub.join_start.lock_or_recover() = task;
}

/// [`start_joined_at_start`]'s order, holding `join` throughout: with no leave `pending`, the
/// relay config.json names (`on_disk`) and the `carrier` now; with one, `finish` it in a task
/// first, then the relay as config.json says then and the carrier only if the machine stayed
/// joined, or nothing while the leave is not finished.
async fn at_start<D: Future<Output = Option<MeshRelayConfig>> + Send + 'static>(
    hub: &Arc<Hub>,
    join: tokio::sync::OwnedMutexGuard<()>,
    pending: bool,
    finish: impl Future<Output = Option<LeaveOutcome>> + Send + 'static,
    on_disk: impl FnOnce() -> D + Send + 'static,
    carrier: impl FnOnce(Arc<Hub>) -> BoxFuture<'static, ()> + Send + 'static,
) -> Option<tokio::task::JoinHandle<()>> {
    if !pending {
        reconcile_relay(hub, on_disk().await, false).await;
        carrier(Arc::clone(hub)).await;
        drop(join);
        return None;
    }
    let owner = Arc::clone(hub);
    let hub = Arc::clone(hub);
    // task-owner: one leave and maybe the relay and carrier start, holding the join transition.
    // Owned by the hub's scope; its handle is also kept on `Hub::join_start`, which shutdown
    // aborts and joins first. The leave waits at most for the join lock and the hub's bounded
    // answer.
    Some(owner.scope.spawn_named("join-at-start", async move {
        let _join = join;
        match finish.await {
            Some(outcome) if !crate::cli::cloud_join::relay_may_start(&outcome) => {
                tracing::info!(left = outcome.left, kept = ?outcome.kept, "sign-out leave at start");
                // Left with the join's relay: stopped. Not finished: nothing changes now.
                if outcome.left {
                    stop_joined(&hub).await;
                }
            }
            outcome => {
                let joined = outcome.as_ref().is_none_or(|outcome| !outcome.left);
                if let Some(outcome) = outcome {
                    tracing::info!(left = outcome.left, kept = ?outcome.kept, "sign-out leave at start");
                }
                reconcile_relay(&hub, on_disk().await, false).await;
                if joined {
                    carrier(hub).await;
                    // The start's capability statement waited for this leave: it goes now.
                    crate::cli::cloud_join::state_capabilities_after_leave();
                }
            }
        }
    }))
}

/// Shutdown's end of the join: the start's task, if it still runs, is ended, and the relay is
/// stopped with the join transition held, so nothing starts one after. An enroll or leave in
/// flight is waited for a bounded time.
pub(crate) async fn stop_at_shutdown(hub: &Arc<Hub>) {
    let start = hub.join_start.lock_or_recover().take();
    if let Some(start) = start {
        start.abort();
        let _ = start.await;
    }
    // timeout: an enroll's hub calls are bounded, but shutdown does not wait on them for long.
    let _join = tokio::time::timeout(
        // timeout: shutdown waits at most this long for an enroll in progress.
        std::time::Duration::from_secs(10),
        Arc::clone(&hub.join_transition).lock_owned(),
    )
    .await;
    let relay = hub.mesh_relay.lock().await.take();
    hub.mesh.clear();
    stop_carrier(hub);
    if let Some(relay) = relay {
        // timeout: shutdown does not wait on a relay that will not stop.
        let _ = tokio::time::timeout(std::time::Duration::from_secs(6), relay.stop()).await;
    }
}

#[cfg(test)]
mod tests;
