//! The consent grant methods (`cli/consent_grant.rs`, `consent_grant_service.rs`), on the person's
//! own local connection only, as `_acpmux/machine_consent_set`:
//! - `_acpmux/consent_remote_status {daemonId}`: another machine's switches, through the carrier,
//!   with `self` (this machine's account, its app's approver id and the words of its key).
//! - `_acpmux/consent_remote_set {daemonId, grant}`: a grant the app signed, carried there.
//! - `_acpmux/consent_grantor_trust {id, trusted}`: pins the pending ask's key here, or unpins.
//! - `_acpmux/consent_account_set {grant}`: an account-wide grant this Mac's own app key signed,
//!   applied here, then handed to every listed machine of the account.
//! - `_acpmux/consent_trust_refresh {}`: opens the enrollment window and collects the keys.
//! - `_acpmux/consent_screen_auto {surface, viewerId, viewerName?, hubUser?}`: whether the app may
//!   skip its per-connect prompt for a device hub viewer (`consent_grant::screen_auto`).

use std::sync::Arc;

use serde_json::{Value, json};

use super::{Conn, Origin};
use crate::hub::Hub;
use crate::rpc::{RpcError, method};

/// The consent grant methods: `None` for every other method.
pub(super) async fn dispatch(
    hub: &Arc<Hub>,
    conn: &Conn,
    m: &str,
    params: &Value,
) -> Option<Result<Value, RpcError>> {
    if !matches!(
        m,
        method::MUX_CONSENT_REMOTE_STATUS
            | method::MUX_CONSENT_REMOTE_SET
            | method::MUX_CONSENT_GRANTOR_TRUST
            | method::MUX_CONSENT_ACCOUNT_SET
            | method::MUX_CONSENT_TRUST_REFRESH
            | method::MUX_CONSENT_SCREEN_AUTO
    ) {
        return None;
    }
    if let Err(refused) = person_local(conn.is_person(), conn.origin) {
        return Some(Err(refused));
    }
    Some(match m {
        method::MUX_CONSENT_GRANTOR_TRUST => trust(params).await,
        method::MUX_CONSENT_REMOTE_STATUS => remote_status(hub, params).await,
        method::MUX_CONSENT_ACCOUNT_SET => account_set(hub, params).await,
        method::MUX_CONSENT_TRUST_REFRESH => trust_refresh(hub).await,
        method::MUX_CONSENT_SCREEN_AUTO => screen_auto(params).await,
        _ => remote_set(hub, params).await,
    })
}

/// Only the app's person-proven connection on this machine's own socket: never a shell, an
/// agent, a web page or a peer.
fn person_local(person: bool, origin: Origin) -> Result<(), RpcError> {
    if person && origin == Origin::Local && !origin.web_class() {
        Ok(())
    } else {
        Err(crate::hub::person::person_required(
            "changing or reading consent from your other machines; use the local cmux app",
        ))
    }
}

async fn trust(params: &Value) -> Result<Value, RpcError> {
    use crate::cli::consent_grant::TrustError;
    let id = params
        .get("id")
        .and_then(Value::as_str)
        .filter(|id| !id.is_empty() && id.len() <= 128)
        .ok_or_else(|| RpcError::invalid_params("id is required"))?
        .to_owned();
    let trusted = params
        .get("trusted")
        .and_then(Value::as_bool)
        .ok_or_else(|| RpcError::invalid_params("trusted must be true or false"))?;
    let changed = tokio::task::spawn_blocking(move || {
        let authority = crate::cli::cloud_join::authority().map_err(|_| TrustError::Store)?;
        let account = crate::cli::cloud_join::machine_user_id();
        let now = crate::store::now_ms();
        crate::cli::consent_grant::trust(&authority, &id, trusted, account.as_deref(), now)
    })
    .await
    .map_err(|_| RpcError::internal("consent store unavailable"))?;
    changed.map_err(|error| match error {
        TrustError::Invalid(message) => RpcError::invalid_params(message),
        TrustError::Store => RpcError::internal("consent store unavailable"),
    })
}

/// `_acpmux/consent_screen_auto`: a device hub viewer's ask, decided by the store here.
async fn screen_auto(params: &Value) -> Result<Value, RpcError> {
    let text = |field: &str| {
        params
            .get(field)
            .and_then(Value::as_str)
            .filter(|text| !text.is_empty() && text.len() <= 256)
            .map(str::to_owned)
    };
    let surface = text("surface")
        .filter(|surface| matches!(surface.as_str(), "screen" | "control"))
        .ok_or_else(|| RpcError::invalid_params("surface must be screen or control"))?;
    let viewer = crate::cli::consent_grant::Viewer {
        id: text("viewerId").ok_or_else(|| RpcError::invalid_params("viewerId is required"))?,
        name: text("viewerName"),
        hub_user: text("hubUser"),
    };
    tokio::task::spawn_blocking(move || {
        let account = crate::cli::cloud_join::machine_user_id();
        let now = crate::store::now_ms();
        match crate::cli::cloud_join::authority() {
            Ok(authority) => crate::cli::consent_grant::screen_auto(
                &authority,
                account.as_deref(),
                &surface,
                &viewer,
                now,
            ),
            Err(_) => json!({"allowed": false, "source": "none", "reason": "store"}),
        }
    })
    .await
    .map_err(|_| RpcError::internal("consent store unavailable"))
}

fn daemon_id(params: &Value) -> Result<String, RpcError> {
    params
        .get("daemonId")
        .and_then(Value::as_str)
        .filter(|key| !key.is_empty())
        .map(str::to_owned)
        .ok_or_else(|| RpcError::invalid_params("daemonId is required"))
}

#[cfg(feature = "hub-carrier")]
async fn remote_status(hub: &Arc<Hub>, params: &Value) -> Result<Value, RpcError> {
    let daemon = daemon_id(params)?;
    let own = hub.person.macs.view(&json!({}));
    let this_mac = own.get("thisMac").filter(|mac| !mac.is_null());
    let grantor = this_mac.and_then(|mac| mac.get("id")).and_then(Value::as_str);
    let words = this_mac
        .and_then(|mac| mac.get("publicKey"))
        .and_then(Value::as_str)
        .and_then(crate::cli::consent_grant::unhex)
        .map(|key| crate::cli::consent_grant::words(&key));
    let request = json!({"op": "status", "grantor": grantor});
    let mut answer = crate::consent_grant_service::remote(hub, &daemon, &request).await;
    let account =
        tokio::task::spawn_blocking(crate::cli::cloud_join::machine_user_id).await.ok().flatten();
    if let Some(fields) = answer.as_object_mut() {
        fields
            .insert("self".into(), json!({"account": account, "grantor": grantor, "words": words}));
    }
    Ok(answer)
}

#[cfg(feature = "hub-carrier")]
async fn remote_set(hub: &Arc<Hub>, params: &Value) -> Result<Value, RpcError> {
    let daemon = daemon_id(params)?;
    let grant = params
        .get("grant")
        .filter(|grant| grant.is_object())
        .ok_or_else(|| RpcError::invalid_params("grant is required"))?;
    let request = json!({"op": "set", "grant": grant});
    Ok(crate::consent_grant_service::remote(hub, &daemon, &request).await)
}

#[cfg(feature = "hub-carrier")]
async fn account_set(hub: &Arc<Hub>, params: &Value) -> Result<Value, RpcError> {
    let grant = params
        .get("grant")
        .filter(|grant| grant.is_object())
        .ok_or_else(|| RpcError::invalid_params("grant is required"))?;
    Ok(crate::consent_grant_service::account_set(hub, grant).await)
}

#[cfg(feature = "hub-carrier")]
async fn trust_refresh(hub: &Arc<Hub>) -> Result<Value, RpcError> {
    Ok(crate::consent_grant_service::trust_refresh(hub).await)
}

#[cfg(not(feature = "hub-carrier"))]
async fn account_set(_hub: &Arc<Hub>, params: &Value) -> Result<Value, RpcError> {
    params
        .get("grant")
        .filter(|grant| grant.is_object())
        .ok_or_else(|| RpcError::invalid_params("grant is required"))?;
    Ok(no_carrier())
}

#[cfg(not(feature = "hub-carrier"))]
async fn trust_refresh(_hub: &Arc<Hub>) -> Result<Value, RpcError> {
    Ok(no_carrier())
}

#[cfg(not(feature = "hub-carrier"))]
async fn remote_status(_hub: &Arc<Hub>, params: &Value) -> Result<Value, RpcError> {
    daemon_id(params)?;
    Ok(no_carrier())
}

#[cfg(not(feature = "hub-carrier"))]
async fn remote_set(_hub: &Arc<Hub>, params: &Value) -> Result<Value, RpcError> {
    daemon_id(params)?;
    Ok(no_carrier())
}

#[cfg(not(feature = "hub-carrier"))]
fn no_carrier() -> Value {
    json!({"ok": false, "reason": "machine.unreachable",
        "error": "this acpmux was built without the hub carrier"})
}

#[cfg(test)]
#[path = "consent_grant_tests.rs"]
mod tests;
