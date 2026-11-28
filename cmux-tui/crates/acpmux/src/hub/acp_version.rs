//! ACP protocol version negotiation for the `initialize` acpmux sends a harness it runs
//! (`lifecycle.rs` for a session's own, `pool/start.rs` for a pooled one).
//!
//! ACP (agentclientprotocol.com/protocol/initialization): the client offers the latest version
//! it supports; an agent that supports it answers the same, else the latest it supports. Zed
//! offers 2 and retries at 1 when the answer does not decode (zed#67357: Antigravity 1.5.2
//! answered a v2 offer with `protocolVersion: 2` and v1 fields).
//!
//! acpmux offers [`OFFER_V2`] only when `ACPMUX_ACP_OFFER_V2=1` (default off): no public v2
//! schema exists to read a v2 answer by, so acpmux keeps reading the v1 fields
//! (`agentCapabilities`, `agentInfo`) of whatever version is agreed. With the offer on:
//! - an answer at 2 is a v2 handshake;
//! - an answer at 1 is the agent's own downgrade, kept (no second request);
//! - an error answer, or an answer at any other version, retries once at 1 on the same process;
//! - a process that closed (`agent::AGENT_CLOSED`) is not retried: it answers nothing.
//!
//! With the offer off, the one request is the v1 one acpmux always sent.

use crate::rpc::RpcError;
use serde_json::{Value, json};
use std::future::Future;

/// The version acpmux has always offered.
pub(crate) const V1: u64 = 1;
/// The version offered with `ACPMUX_ACP_OFFER_V2=1`.
pub(crate) const OFFER_V2: u64 = 2;

/// Whether this daemon offers [`OFFER_V2`] (`ACPMUX_ACP_OFFER_V2=1`).
pub(crate) fn offer_v2() -> bool {
    std::env::var("ACPMUX_ACP_OFFER_V2").is_ok_and(|v| v.trim() == "1")
}

/// What a negotiation agreed on.
#[derive(Debug, Clone, PartialEq)]
pub(crate) struct Negotiated {
    /// The agent's `initialize` result.
    pub result: Value,
    /// The version the agent answered (`None`: it named none, which a v1 start keeps).
    pub version: Option<u64>,
    /// Whether the v2 offer failed and the v1 retry answered.
    pub fell_back: bool,
}

/// `params` with `protocolVersion` set to `version`.
fn at(params: &Value, version: u64) -> Value {
    let mut p = params.clone();
    if let Some(map) = p.as_object_mut() {
        map.insert("protocolVersion".to_owned(), json!(version));
    }
    p
}

fn answered(result: &Value) -> Option<u64> {
    result.get("protocolVersion").and_then(Value::as_u64)
}

/// Run `initialize` through `call` (one request to the agent each time), offering 2 when
/// `offer_v2`, with the module's fallback rules.
pub(crate) async fn negotiate<F, Fut>(
    params: Value,
    offer_v2: bool,
    mut call: F,
) -> Result<Negotiated, RpcError>
where
    F: FnMut(Value) -> Fut,
    Fut: Future<Output = Result<Value, RpcError>>,
{
    if !offer_v2 {
        let result = call(at(&params, V1)).await?;
        return Ok(Negotiated { version: answered(&result), result, fell_back: false });
    }
    let first = call(at(&params, OFFER_V2)).await;
    let why = match first {
        Ok(result) => match answered(&result) {
            Some(v) if v == OFFER_V2 || v == V1 => {
                return Ok(Negotiated { version: Some(v), result, fell_back: false });
            }
            other => format!("answered protocolVersion {other:?}"),
        },
        Err(e) if e.message.starts_with(crate::agent::AGENT_CLOSED) => return Err(e),
        Err(e) => format!("error {}: {}", e.code, e.message),
    };
    tracing::info!(why = %why, "acp initialize: the v2 offer failed; retrying at v1");
    let result = call(at(&params, V1)).await?;
    Ok(Negotiated { version: answered(&result), result, fell_back: true })
}

/// [`negotiate`] against a running harness, with this daemon's offer.
pub(super) async fn initialize(
    child: &crate::agent::ChildAgent,
    params: Value,
) -> Result<Value, RpcError> {
    let negotiated = negotiate(params, offer_v2(), |p| async move {
        child.request(crate::rpc::method::INITIALIZE, p).await
    })
    .await?;
    tracing::debug!(
        version = ?negotiated.version,
        fell_back = negotiated.fell_back,
        "acp initialize agreed"
    );
    Ok(negotiated.result)
}

#[cfg(test)]
#[path = "acp_version_tests.rs"]
mod tests;
