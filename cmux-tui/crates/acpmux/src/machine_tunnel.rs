//! This Mac's Cloud tunnel: its place in its team's WireGuard peer map on cmux-platform
//! (`openapi.json`, `/v1/mesh/nodes`):
//!
//! - `_acpmux/machine.tunnel.attach` and `.detach`: `POST /v1/mesh/nodes/{machineId}/attach`
//!   and `/detach`. One Mac is one peer, keyed by its `machine_` id. A detach sticks: this
//!   daemon's own registration is refused until the next attach.
//!
//! The person's cmux access token comes in the app's call (`server/machine_tunnel.rs`: the unix
//! socket with the person proof only). It is the bearer of that one request, never stored,
//! logged or put in a reply.

use serde_json::{Value, json};
use zeroize::Zeroizing;

use crate::rpc::RpcError;

/// The longest token the app may send (a Stack access token is far shorter).
const MAX_TOKEN_BYTES: usize = 16 * 1024;
/// The longest platform answer read.
const MAX_REPLY_BYTES: usize = 64 * 1024;

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
        .filter(|code| code.len() <= 64 && code.bytes().all(|b| b.is_ascii_alphanumeric() || b"._-".contains(&b)))
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
