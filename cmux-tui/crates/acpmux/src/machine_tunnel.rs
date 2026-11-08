//! This Mac's Cloud tunnel: its place in its team's WireGuard peer map and its WireGuard key,
//! on cmux-platform (`openapi.json`, `/v1/mesh/nodes` and `/v1/machines/credentials`):
//!
//! - `_acpmux/machine.tunnel.attach` and `.detach`: `POST /v1/mesh/nodes/{machineId}/attach`
//!   and `/detach`. One Mac is one peer, keyed by its `machine_` id. A detach sticks: this
//!   daemon's own registration is refused until the next attach.
//! - `_acpmux/machine.tunnel.rekey`: a new WireGuard key, only in the process that holds this
//!   machine's key lock (`cmux_link::key_holder`). The new key is written to a pending key file,
//!   the platform takes its public half first (`POST
//!   /v1/machines/credentials/{machineId}/wg-key`), then the pending key file is renamed over the
//!   key file, and the holder starts its mesh again with it. A refused or failed platform call
//!   leaves the key here as it was; one whose answer was lost keeps its candidate in the pending
//!   key file and is refused `indeterminate`, and the next rekey or attach sends that candidate
//!   again (never the old key). A second rekey while one runs is refused `busy`; a key lock
//!   another process holds (the cmux link) is refused `key_held` with its pid.
//!
//! The person's cmux access token comes in the app's call (`server/machine_tunnel.rs`: the unix
//! socket with the person proof only). It is the bearer of that one request, never stored,
//! logged or put in a reply.

use std::path::Path;
use std::sync::Arc;

use base64::Engine;
use cmux_link::key_holder::{KeyFile, KeyHolder, KeyHolderError};
use serde_json::{Value, json};
use x25519_dalek::{PublicKey, StaticSecret};
use zeroize::Zeroizing;

use crate::rpc::RpcError;
use crate::wireguard::Transport;

/// The longest token the app may send (a Stack access token is far shorter).
const MAX_TOKEN_BYTES: usize = 16 * 1024;
/// The longest platform answer read.
const MAX_REPLY_BYTES: usize = 64 * 1024;

/// The one rekey this daemon runs at a time.
pub(crate) static REKEYS: tokio::sync::Mutex<()> = tokio::sync::Mutex::const_new(());

/// This Mac as the platform knows it: its `machine_` id, its team and the platform origin it
/// joined through.
#[derive(Clone, Debug)]
pub(crate) struct Machine {
    pub(crate) id: String,
    pub(crate) team: String,
    pub(crate) origin: String,
}

impl Machine {
    /// This box's join record; refused `not_joined` when there is none (or it is another box's
    /// copy, or revoked).
    pub(crate) fn joined() -> Result<Self, RpcError> {
        let record = crate::cli::cloud_join::machine_credential()
            .map_err(|_| RpcError::internal("this Mac's join record could not be read"))?
            .filter(|record| !record.revoked && record.machine_id.starts_with("machine_"))
            .ok_or_else(|| {
                refusal("not_joined", "this Mac is not joined to a cmux team; add it first")
            })?;
        let origin = crate::cli::cloud_join::hub_origin(&record.hub_origin).map_err(|_| {
            refusal("not_joined", "this Mac's join record names no usable platform origin")
        })?;
        Ok(Self { id: record.machine_id, team: record.team_id, origin })
    }
}

/// The person's token from the call's `token`.
pub(crate) fn token(params: &Value) -> Result<Zeroizing<String>, RpcError> {
    let token = params.get("token").and_then(Value::as_str).unwrap_or_default();
    if token.is_empty()
        || token.len() > MAX_TOKEN_BYTES
        || !token.bytes().all(|b| b.is_ascii_graphic())
    {
        return Err(refusal("token_required", "sign in to cmux: the call carries no usable token"));
    }
    Ok(Zeroizing::new(token.to_owned()))
}

/// Attach (or with `detach`, detach) this Mac in its team's peer map. A `networkId` in `params`
/// must name the Mac's own team: the peer map is the team's.
pub(crate) async fn attach(
    machine: &Machine,
    params: &Value,
    token: &str,
    detach: bool,
) -> Result<Value, RpcError> {
    if let Some(network) = params.get("networkId").and_then(Value::as_str)
        && !network.is_empty()
        && network != machine.team
    {
        return Err(refusal(
            "network_mismatch",
            "this Mac's tunnel is in its own team's network; pass that team's id or none",
        ));
    }
    let path = if detach {
        format!("/v1/mesh/nodes/{}/detach", machine.id)
    } else {
        format!("/v1/mesh/nodes/{}/attach", machine.id)
    };
    post(machine, &path, token, None).await
}

/// Who holds this machine's WireGuard key for a rekey.
pub(crate) enum Holder {
    /// This daemon's WireGuard transport, which starts its mesh again with the new key.
    Transport(Arc<Transport>),
    /// The key lock, taken for this rekey: no mesh runs with the key.
    Lock(KeyHolder),
}

impl Holder {
    /// This daemon's transport while it holds the key, else the key lock in `state_dir` taken
    /// now. A lock another process holds (the cmux link) is refused `key_held`, with its pid
    /// when it wrote one, and the key file is never touched. Forwarding the rekey to the link
    /// comes when the link is this machine's key holder.
    pub(crate) fn take(
        transport: Option<&Arc<Transport>>,
        state_dir: &Path,
    ) -> Result<Self, RpcError> {
        if let Some(transport) = transport
            && transport.with_key(|_| ()).is_some()
        {
            return Ok(Self::Transport(transport.clone()));
        }
        match KeyHolder::acquire(state_dir) {
            Ok(lock) => Ok(Self::Lock(lock)),
            Err(KeyHolderError::KeyHeld { pid }) => {
                Err(refusal("key_held", "the link holds the key; it rekeys in a later version")
                    .with_data(json!({"reason": "key_held", "holderPid": pid})))
            }
            Err(KeyHolderError::Io(_)) => {
                Err(RpcError::internal("this Mac's WireGuard key lock could not be taken"))
            }
        }
    }

    /// `act` with the key lock this holder has.
    fn with_lock<T>(&self, act: impl FnOnce(&KeyHolder) -> anyhow::Result<T>) -> anyhow::Result<T> {
        match self {
            Self::Transport(transport) => transport
                .with_key(act)
                .unwrap_or_else(|| Err(anyhow::anyhow!("the WireGuard transport stopped"))),
            Self::Lock(lock) => act(lock),
        }
    }
}

/// One rekey: refused `busy` while `rekeys` is held, then [`rekey`] with the holder
/// [`Holder::take`] finds.
pub(crate) async fn rekey_once(
    rekeys: &tokio::sync::Mutex<()>,
    machine: &Machine,
    state_dir: &Path,
    transport: Option<&Arc<Transport>>,
    token: &str,
    record: impl FnOnce(&str) -> anyhow::Result<()>,
) -> Result<Value, RpcError> {
    let Ok(_running) = rekeys.try_lock() else {
        return Err(refusal("busy", "a rekey of this Mac's WireGuard key is already running"));
    };
    let holder = Holder::take(transport, state_dir)?;
    rekey(machine, state_dir, holder, token, record).await
}

/// A new WireGuard key, in this order: a candidate in the pending key file (the one an earlier
/// rekey left, else a new one made now), its public half to the platform, then the pending file
/// renamed over the key file (`record` then notes the public half in the join record) and the
/// holder's mesh started again. Answers `{machineId, wgPublicKey, restarted}`.
///
/// The pending file is what makes a lost answer safe: the platform may have taken the key even
/// when its answer never came, and it never takes a key the team had before (this machine's
/// old one included). So a transport failure or a 500, 502 or 504 keeps the candidate and is
/// refused `indeterminate`, and the next rekey or attach sends that same candidate again (the
/// platform answers its current key with the same record). Only a definite no to that key
/// (`machine.wg_key_in_use`, `machine.wg_key_invalid`, or an answer naming another key) drops it.
pub(crate) async fn rekey(
    machine: &Machine,
    state_dir: &Path,
    holder: Holder,
    token: &str,
    record: impl FnOnce(&str) -> anyhow::Result<()>,
) -> Result<Value, RpcError> {
    let unwritten = || {
        refusal("key_write_failed", "this Mac could not write a new WireGuard key; its key is unchanged")
    };
    let private = match holder
        .with_lock(|lock| crate::cli::mesh_node_key::read_pending_held(state_dir, lock))
        .map_err(|_| unwritten())?
    {
        Some(pending) => pending,
        None => {
            let mut private = Zeroizing::new([0u8; 32]);
            getrandom::fill(&mut *private)
                .map_err(|_| RpcError::internal("no randomness for a new WireGuard key"))?;
            holder
                .with_lock(|lock| {
                    crate::cli::mesh_node_key::write_pending_held(state_dir, lock, &private)
                })
                .map_err(|_| unwritten())?;
            private
        }
    };
    let public = base64::engine::general_purpose::STANDARD
        .encode(PublicKey::from(&StaticSecret::from(*private)).to_bytes());
    let drop_pending = || {
        let _ = holder
            .with_lock(|lock| crate::cli::mesh_node_key::drop_pending_held(state_dir, lock));
    };
    let path = format!("/v1/machines/credentials/{}/wg-key", machine.id);
    let answer = match post(machine, &path, token, Some(json!({"wgPublicKey": public}))).await {
        Ok(answer) => answer,
        Err(error) if ambiguous(&error) => {
            return Err(refusal(
                "indeterminate",
                "the platform may have taken the new WireGuard key but its answer was lost; rekey again to finish",
            )
            .with_data(json!({"reason": "indeterminate", "retryable": true})));
        }
        Err(error) => {
            if matches!(
                error.data.as_ref().and_then(|data| data["code"].as_str()),
                Some("machine.wg_key_in_use" | "machine.wg_key_invalid")
            ) {
                drop_pending();
            }
            return Err(error);
        }
    };
    if answer.get("wgPublicKey").and_then(Value::as_str) != Some(public.as_str()) {
        drop_pending();
        return Err(refusal(
            "platform",
            "the platform answered another WireGuard key; the key on this Mac is unchanged",
        ));
    }
    if holder
        .with_lock(|lock| crate::cli::mesh_node_key::promote_pending_held(state_dir, lock))
        .is_err()
    {
        return Err(refusal(
            "key_write_failed",
            "the platform took the new WireGuard key but this Mac could not put it in place; rekey again",
        ));
    }
    if let Err(error) = record(&public) {
        tracing::warn!(error = %error, "the join record keeps its old WireGuard public key");
    }
    let restarted = match &holder {
        Holder::Transport(transport) => {
            transport.restart(private).await.map_err(|_| {
                refusal(
                    "restart_failed",
                    "the new WireGuard key is in place but the tunnel did not start again; restart cmux",
                )
            })?;
            true
        }
        Holder::Lock(_) => false,
    };
    Ok(json!({"machineId": machine.id, "wgPublicKey": public, "restarted": restarted}))
}

/// Whether a refused platform call may still have happened there: no answer at all, or a 500,
/// 502 or 504 (a gateway or the platform failing after its write).
fn ambiguous(error: &RpcError) -> bool {
    let data = error.data.as_ref();
    data.and_then(|data| data["reason"].as_str()) == Some("platform_unreachable")
        || matches!(data.and_then(|data| data["status"].as_u64()), Some(500 | 502 | 504))
}

/// A rekey an earlier one left unsettled, finished before an attach: the pending key goes to
/// the platform again and, when it takes it, into place. Nothing when there is no pending key,
/// a rekey runs, or another process holds the key. Answers the rekey's answer, or its refusal.
pub(crate) async fn finish_pending_rekey(
    rekeys: &tokio::sync::Mutex<()>,
    machine: &Machine,
    state_dir: &Path,
    transport: Option<&Arc<Transport>>,
    token: &str,
    record: impl FnOnce(&str) -> anyhow::Result<()>,
) -> Option<Result<Value, RpcError>> {
    if std::fs::symlink_metadata(KeyFile::NodePending.path_in(state_dir)).is_err() {
        return None;
    }
    let _running = rekeys.try_lock().ok()?;
    let holder = Holder::take(transport, state_dir).ok()?;
    Some(rekey(machine, state_dir, holder, token, record).await)
}

/// What an attach says about the pending rekey it finished first: `{finished, wgPublicKey}`, or
/// `{finished: false, reason, message}`.
pub(crate) fn pending_outcome(outcome: Result<Value, RpcError>) -> Value {
    match outcome {
        Ok(answer) => json!({"finished": true, "wgPublicKey": answer["wgPublicKey"]}),
        Err(error) => json!({
            "finished": false,
            "reason": error.data.as_ref().and_then(|data| data["reason"].as_str()),
            "message": error.message,
        }),
    }
}

/// `POST {origin}{path}` as the person, in the machine's team. A refusal names the platform's
/// code (`machine.wg_key_in_use`, `machine.revoked`, `mesh.node.not_found`, ...) and status.
async fn post(
    machine: &Machine,
    path: &str,
    token: &str,
    body: Option<Value>,
) -> Result<Value, RpcError> {
    let client = crate::cli::cloud_join::http_client()
        .map_err(|_| RpcError::internal("the platform client could not be built"))?;
    let mut request = client.post(format!("{}{path}", machine.origin)).bearer_auth(token);
    if !machine.team.is_empty() {
        request = request.header("x-cmux-team", &machine.team);
    }
    if let Some(body) = body {
        request = request.json(&body);
    }
    let unreachable = || {
        refusal("platform_unreachable", "the cmux platform did not answer; try again")
            .with_data(json!({"reason": "platform_unreachable", "retryable": true}))
    };
    let response = request.send().await.map_err(|_| unreachable())?;
    let status = response.status().as_u16();
    let bytes = response.bytes().await.map_err(|_| unreachable())?;
    let answer: Value = if bytes.len() <= MAX_REPLY_BYTES {
        serde_json::from_slice(&bytes).unwrap_or(Value::Null)
    } else {
        Value::Null
    };
    if (200..300).contains(&status) {
        return Ok(answer);
    }
    let code = answer
        .get("code")
        .and_then(Value::as_str)
        .filter(|code| {
            code.len() <= 64
                && code.bytes().all(|b| b.is_ascii_alphanumeric() || b"._-".contains(&b))
        })
        .unwrap_or_default();
    Err(RpcError::new(-32000, refused_words(status, code)).with_data(json!({
        "reason": "platform",
        "code": code,
        "status": status,
        "retryable": status == 503,
    })))
}

fn refused_words(status: u16, code: &str) -> String {
    match code {
        "machine.wg_key_in_use" => {
            "another machine of the team holds that WireGuard key; rekey again".into()
        }
        "machine.wg_key_invalid" => {
            "the platform refused the new WireGuard key as malformed".into()
        }
        "machine.revoked" => "this Mac's join was revoked; add it again".into(),
        "mesh.node.not_found" | "machine.not_found" => {
            "the platform has no such machine for this account; sign in as the person who added it"
                .into()
        }
        _ if status == 401 => "sign in to cmux again".into(),
        _ if status == 503 => "the cmux mesh hub is busy or unreachable; try again".into(),
        "" => format!("the cmux platform refused (HTTP {status})"),
        code => format!("the cmux platform refused: {code} (HTTP {status})"),
    }
}

fn refusal(reason: &'static str, message: &str) -> RpcError {
    RpcError::new(-32000, message).with_data(json!({"reason": reason}))
}

#[cfg(test)]
#[path = "machine_tunnel_tests.rs"]
mod tests;
