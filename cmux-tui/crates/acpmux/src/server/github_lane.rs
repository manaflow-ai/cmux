//! The lane's side of the GitHub broker (`github_broker.rs`): an agent session's GitHub action,
//! asked over this machine's unix socket, goes to the Mac that lends GitHub here. Moved from
//! `github_broker.rs` (`github_broker::handle`): it reads the hub and the connection, which that
//! lower module does not reach.

use std::sync::Arc;

use serde_json::{Value, json};

use super::Conn;
use crate::github_broker::{
    GithubActionParams, LANE_WAIT, audit_payload, deadline_from, denied, invalid, source_of,
    validate,
};
use crate::hub::Hub;
use crate::rpc::RpcError;

/// The lane's side: an agent session asked over the unix socket (`remote_guard.rs` refuses
/// every other origin).
pub async fn handle(hub: &Arc<Hub>, conn: &Arc<Conn>, params: Value) -> Result<Value, RpcError> {
    if conn.origin != crate::conn_origin::Origin::Local {
        return Err(denied("GitHub actions are asked over this machine's unix socket only"));
    }
    let mut request: GithubActionParams = serde_json::from_value(params)
        .map_err(|e| invalid(format!("invalid GitHub action: {e}")))?;
    let session = conn
        .caller()
        .ok_or_else(|| {
            denied("GitHub actions are for an acpmux session's agent (run it inside one)")
        })?
        .to_owned();
    request.session_id = Some(session.clone());
    validate(&request)?;
    let session = hub.resolve(&session)?;
    let record = |status: &str, error: Option<&RpcError>, source: Option<&str>| {
        hub.append_github_audit(&session, audit_payload(&request, status, error, source));
    };
    let Some(owner) = hub.github_owner_link() else {
        let error = RpcError::new(
            -32042,
            "no Mac that lends GitHub to this machine is connected (add this machine from the Mac with Add Machine)",
        )
        .with_data(json!({"reason": "github.no_owner"}));
        record("unavailable", Some(&error), None);
        return Err(error);
    };
    // The Mac starts nothing it could not finish before this machine stops waiting.
    let mut wire = request.clone();
    wire.deadline_ms = Some(deadline_from(crate::store::now_ms()));
    let wire = serde_json::to_value(&wire).map_err(|e| RpcError::internal(e.to_string()))?;
    let budget = LANE_WAIT;
    let reply = owner.request_client(crate::rpc::method::MUX_GITHUB_ACTION, wire, budget).await;
    let source = source_of(&reply);
    match &reply {
        Ok(_) => record("allowed", None, source),
        Err(e) if e.code == -32040 => record("denied", Some(e), source),
        Err(e) => record("failed", Some(e), source),
    }
    reply
}
