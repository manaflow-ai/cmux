//! A browser is its own enrolled device on the mesh hub (RFD 0005). Leo, 2026-11-17: "if we
//! literally had it... on the web... wouldn't that be interesting!?"
//!
//! A web connection (`Origin::Web`, the listener token proven at the upgrade) never borrows this
//! daemon's own hub identity: `mesh_read.rs` `may_read` refuses it, unchanged. To read and prompt
//! a chat the hub lists for the person's other machines, the browser enrolls as a device of its
//! own, through the same join a new machine makes, and presents that credential on its
//! connection:
//!
//! - `_acpmux/device_enroll {accessToken, publicKey}` mints a single-use join token with the
//!   person's access token (`cli/cloud_join/enroll.rs` `mint_join_token`) and redeems it as a
//!   `web` machine with the browser's public key, as `cli/cloud_join/recovery.rs` redeems a
//!   machine's. It writes nothing to disk, and answers `{credential, machineId, userId}` to that
//!   connection only. The hub records the device under the person who minted it.
//! - `_acpmux/device_hello {credential}` sets the connection's device client
//!   (`Conn::device_mesh`), once per connection. The connection is still served as Web: every
//!   `remote_guard.rs` rule (known folders, asking modes, no command-bearing params) holds.
//!
//! Then the hub stamps the device's reads and prompts with the device's identity and person, the
//! target daemon checks that person against its own `controlFrom` `sameUser`
//! (`mesh_relay.rs` `MeshControlHook::control`), and the hub's 401 (`machine.revoked`) cuts the
//! device off: the connection drops it and answers `device.revoked`, and no later call reaches the
//! hub (`mesh_read.rs` `read_hub`).
//!
//! Neither credential is logged, persisted or echoed: each lives in a `Zeroizing` in this
//! process's memory, and the device's only in its connection's client.

use std::sync::Arc;

use base64::Engine;
use serde_json::{Value, json};
use zeroize::Zeroizing;

use super::{Conn, ConnAuth, Origin};
use crate::hub::Hub;
use crate::mesh_http::HttpHub;
use crate::rpc::{RpcError, method};

/// A connection's device on the hub.
pub(crate) enum Slot {
    /// None presented yet.
    Empty,
    /// The browser's own device client (`_acpmux/device_hello`).
    Device(Arc<HttpHub>),
    /// The hub revoked it: dropped, and no other may be presented on this connection.
    Revoked,
}

/// The longest credential or access token taken.
const MAX_TOKEN_BYTES: usize = 16 << 10;

/// The device methods; None for every other method.
pub(super) async fn dispatch(
    hub: &Arc<Hub>,
    conn: &Arc<Conn>,
    m: &str,
    params: &Value,
) -> Option<Result<Value, RpcError>> {
    match m {
        method::MUX_DEVICE_HELLO => Some(hello(hub, conn, params).await),
        method::MUX_DEVICE_ENROLL => Some(enroll(hub, conn, params).await),
        _ => None,
    }
}

/// Only a browser on the web listener, proven by the listener token alone: the unix socket and
/// the app's pane read with this daemon's identity and need no device; a paired machine, a
/// teammate through the carrier and a peer daemon have their own proofs.
fn web_only(conn: &Conn, m: &str) -> Result<(), RpcError> {
    if conn.origin != Origin::Web || conn.auth != ConnAuth::ListenerToken {
        return Err(RpcError::method_not_found(&format!("{m} (a web connection only)")));
    }
    Ok(())
}

/// The hub this daemon is on (config.json `meshRelay`): a device is enrolled at, and reads
/// through, the same hub whose address book this daemon lists.
async fn hub_origin(hub: &Hub) -> Result<String, RpcError> {
    let relay = hub.config.read().await.mesh_relay.clone();
    relay.and_then(|relay| relay.origin().ok()).ok_or_else(|| {
        RpcError::new(-32000, "this machine is on no mesh hub")
            .with_data(json!({"reason": "device.no_hub"}))
    })
}

/// A bearer token from `params[key]`: printable ASCII, at most 16 KiB. The refusal never
/// repeats it.
fn token_param(params: &Value, key: &str) -> Result<Zeroizing<String>, RpcError> {
    params
        .get(key)
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|t| !t.is_empty() && t.len() <= MAX_TOKEN_BYTES)
        .filter(|t| t.bytes().all(|b| b.is_ascii_graphic()))
        .map(|t| Zeroizing::new(t.to_owned()))
        .ok_or_else(|| RpcError::invalid_params(format!("{key} is required")))
}

/// The refusal a connection whose device the hub revoked gets for every hub call.
pub(super) fn revoked() -> RpcError {
    RpcError::new(-32003, "this device was revoked on the mesh hub: enroll it again")
        .with_data(json!({"reason": "device.revoked"}))
}

/// `_acpmux/device_hello {credential}` -> `{auth: "webDevice"}`.
async fn hello(hub: &Hub, conn: &Conn, params: &Value) -> Result<Value, RpcError> {
    web_only(conn, method::MUX_DEVICE_HELLO)?;
    let credential = token_param(params, "credential")?;
    let origin = hub_origin(hub).await?;
    let client = HttpHub::with_credential(origin, credential)
        .map_err(|_| RpcError::internal("the hub client could not be built"))?;
    {
        let mut slot = conn.device_mesh.lock().unwrap_or_else(|e| e.into_inner());
        match *slot {
            Slot::Empty => *slot = Slot::Device(Arc::new(client)),
            Slot::Device(_) => {
                return Err(RpcError::invalid_params("this connection already presented a device")
                    .with_data(json!({"reason": "device.already_presented"})));
            }
            Slot::Revoked => return Err(revoked()),
        }
    }
    Ok(json!({"auth": conn.proof().as_str()}))
}

/// `_acpmux/device_enroll {accessToken, publicKey}` -> `{credential, machineId, userId}`.
async fn enroll(hub: &Hub, conn: &Conn, params: &Value) -> Result<Value, RpcError> {
    web_only(conn, method::MUX_DEVICE_ENROLL)?;
    let access = token_param(params, "accessToken")?;
    // A WireGuard public key in standard base64, as every machine's join sends.
    let key = params
        .get("publicKey")
        .and_then(Value::as_str)
        .filter(|key| {
            base64::engine::general_purpose::STANDARD.decode(key).is_ok_and(|raw| raw.len() == 32)
        })
        .ok_or_else(|| {
            RpcError::invalid_params("publicKey must be a 32-byte key in standard base64")
        })?;
    let origin = hub_origin(hub).await?;
    let token = crate::cli::cloud_join::mint_join_token(&origin, &access, "web")
        .await
        .map_err(|_| refused("the hub refused to mint a join token for this device"))?;
    // The credential is proposed here, as a machine's join proposes its own (`recovery.rs`).
    let mut random = Zeroizing::new([0u8; 32]);
    getrandom::fill(&mut *random).map_err(|_| RpcError::internal("no randomness"))?;
    let proposed = Zeroizing::new(format!(
        "cmm_{}",
        base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(*random)
    ));
    let id = uuid::Uuid::now_v7().simple().to_string();
    let name = format!("web-{}", id.get(id.len() - 8..).unwrap_or_default());
    let body: cmux_cloud_client::types::JoinRedeem = serde_json::from_value(json!({
        "token": token.as_str(),
        "proposedCredential": proposed.as_str(),
        "name": name,
        "hostname": "web",
        "platform": "web",
        "wgPublicKey": key,
        "capabilities": [],
    }))
    .map_err(|_| RpcError::internal("the join request is not the hub's shape"))?;
    let client = crate::cli::cloud_join::hub_client(&origin, None)
        .map_err(|_| RpcError::internal("the hub client could not be built"))?;
    let redeemed = match client.machine_redeem_redeem(&body).await {
        Ok(answer) => serde_json::to_value(answer.into_inner()).unwrap_or_default(),
        Err(_) => return Err(refused("the hub refused this device's join")),
    };
    let text = |key: &str| redeemed.get(key).and_then(Value::as_str).map(str::to_owned);
    // The hub's credential when it names one, else the one this join proposed.
    let credential = Zeroizing::new(text("credential").unwrap_or_else(|| proposed.to_string()));
    let machine = text("machineId").ok_or_else(|| refused("the hub named no machine"))?;
    Ok(json!({
        "credential": credential.as_str(),
        "machineId": machine,
        "userId": text("userId"),
    }))
}

fn refused(why: &str) -> RpcError {
    RpcError::new(-32000, why).with_data(json!({"reason": "device.enroll_refused"}))
}
