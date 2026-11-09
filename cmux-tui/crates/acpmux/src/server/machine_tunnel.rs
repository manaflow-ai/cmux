//! `_acpmux/machine.tunnel.attach`, `.detach` and `.rekey` (`crate::machine_tunnel`): only from
//! the app's own connection, the unix socket with the person proof, since each carries the
//! person's cmux access token (`token`) and changes this Mac's place on the team's mesh. A
//! shell, an agent, a page or a peer is refused before the token is read.

use std::sync::Arc;

use serde_json::Value;

use super::{Conn, Origin};
use crate::hub::Hub;
use crate::machine_tunnel::{self, Machine};
use crate::rpc::{RpcError, method};

pub(super) async fn dispatch(
    hub: &Arc<Hub>,
    conn: &Conn,
    m: &str,
    params: &Value,
) -> Option<Result<Value, RpcError>> {
    if !matches!(
        m,
        method::MUX_MACHINE_TUNNEL_ATTACH
            | method::MUX_MACHINE_TUNNEL_DETACH
            | method::MUX_MACHINE_TUNNEL_REKEY
    ) {
        return None;
    }
    if conn.origin != Origin::Local || !conn.is_person() {
        return Some(Err(crate::hub::person::person_required("changing this Mac's Cloud tunnel")));
    }
    Some(run(hub, m, params).await)
}

async fn run(hub: &Arc<Hub>, m: &str, params: &Value) -> Result<Value, RpcError> {
    let token = machine_tunnel::token(params)?;
    let machine = Machine::joined(params)?;
    let home = crate::config::home();
    let record = |key: &str| crate::cli::cloud_join::record_wg_public_key(&machine.id, key);
    match m {
        method::MUX_MACHINE_TUNNEL_ATTACH => {
            // Another team's network is refused before anything changes here; then a rekey
            // whose answer was lost goes first, so the peer map gets the key in use.
            machine_tunnel::same_network(&machine, params)?;
            let pending = machine_tunnel::finish_pending_rekey(
                &machine_tunnel::REKEYS,
                &machine,
                &home,
                hub.wireguard.as_ref(),
                &token,
                record,
            )
            .await;
            // A pending rekey that did not finish fails the attach: nothing reads as attached
            // while the platform and this Mac may hold different keys.
            let pending = pending.transpose()?;
            let mut attached = machine_tunnel::attach(&machine, params, &token, false).await?;
            if let (Some(pending), Some(object)) = (pending, attached.as_object_mut()) {
                object.insert("pendingRekey".into(), machine_tunnel::pending_outcome(&pending));
            }
            Ok(attached)
        }
        method::MUX_MACHINE_TUNNEL_DETACH => {
            machine_tunnel::attach(&machine, params, &token, true).await
        }
        _ => {
            machine_tunnel::rotate(
                &machine_tunnel::REKEYS,
                &machine,
                &home,
                hub.wireguard.as_ref(),
                &token,
                &stranded_peers(hub).await,
                record,
            )
            .await
        }
    }
}

/// The peers a rotation of this machine's node key would cut off: each configured WireGuard
/// peer (it dials the key in its config), and each machine the running hub carrier's
/// registration lets in (it pins the key the platform named).
async fn stranded_peers(hub: &Arc<Hub>) -> Vec<String> {
    let config = hub.config.read().await;
    #[allow(unused_mut)]
    let mut peers: Vec<String> = config
        .peers
        .iter()
        .filter(|(_, peer)| peer.wireguard.is_some())
        .map(|(name, _)| format!("{name} (WireGuard)"))
        .collect();
    drop(config);
    #[cfg(feature = "hub-carrier")]
    if let Some(carrier) = hub.hub_carrier.get() {
        peers.extend(carrier.registered_peers().into_iter().map(|key| format!("hub peer {key}")));
    }
    peers
}
