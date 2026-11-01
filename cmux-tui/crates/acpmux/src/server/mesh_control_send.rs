//! The local socket's mesh lifecycle enqueue/receipt endpoint. A remote connection may not
//! borrow this daemon's allowlisted identity to control a third daemon.

use super::*;
use crate::mesh::{HubError, Sender};
use crate::mesh_control::{Command, ControlRequest, MeshControlRelay, Recipient};

fn recipient(value: &Value) -> Result<Recipient, RpcError> {
    let object =
        value.as_object().ok_or_else(|| RpcError::invalid_params("to must be an object"))?;
    let field = |name| object.get(name).and_then(Value::as_str).map(str::to_owned);
    match (field("sessionId"), field("name"), field("host"), field("daemonId"), object.len()) {
        (Some(session_id), None, None, None, 1) => Ok(Recipient::Session { session_id }),
        (None, Some(name), None, None, 1) => Ok(Recipient::Name { name, host: None }),
        (None, Some(name), Some(host), None, 2) => Ok(Recipient::Name { name, host: Some(host) }),
        (None, None, Some(host), None, 1) => Ok(Recipient::Host { host }),
        (None, None, None, Some(daemon_id), 1) => Ok(Recipient::Daemon { daemon_id }),
        _ => Err(RpcError::invalid_params("to must name one exact mesh recipient")),
    }
}

fn error(error: HubError) -> RpcError {
    let code = error.code.as_deref().unwrap_or("mesh.unavailable");
    RpcError::new(-32000, error.message.clone()).with_data(json!({
        "reason": code, "candidates": error.candidates, "retryable": !error.refused,
    }))
}

pub(super) async fn handle(
    hub: &Arc<Hub>,
    conn: &Arc<Conn>,
    params: &Value,
) -> Result<Value, RpcError> {
    if conn.origin != Origin::Local || conn.auth != ConnAuth::LocalSocket {
        return Err(RpcError::new(-32003, "mesh controls require this daemon's local socket")
            .with_data(json!({"reason": "mesh.local_only"})));
    }
    if let Some(caller) = conn.caller() {
        let caller = hub.resolve(caller)?;
        // This existing check detects both the current and last remote-controlled turn.
        if hub.subsession_attach_check(&caller).is_err() {
            return Err(RpcError::new(
                -32003,
                "a remote-controlled session cannot forward mesh controls",
            )
            .with_data(json!({"reason": "mesh.local_only"})));
        }
    }
    let mesh =
        hub.mesh.get().ok_or_else(|| RpcError::new(-32000, "mesh relay is not configured"))?;
    if let Some(id) = params.get("receipt").and_then(Value::as_str) {
        if !crate::mesh::is_message_id(id) {
            return Err(RpcError::invalid_params("invalid mesh receipt id"));
        }
        return serde_json::to_value(mesh.receipt(id).await.map_err(error)?)
            .map_err(|e| RpcError::internal(e.to_string()));
    }
    let to = recipient(&params["to"])?;
    let command = match params["op"].as_str() {
        Some("start") => Command::Start {
            params: params["params"]
                .as_object()
                .cloned()
                .ok_or_else(|| RpcError::invalid_params("start requires params"))?,
        },
        Some("resume") => Command::Resume,
        Some("stop") => Command::Stop,
        _ => return Err(RpcError::invalid_params("op must be start, resume or stop")),
    };
    let key = params["idempotencyKey"]
        .as_str()
        .ok_or_else(|| RpcError::invalid_params("idempotencyKey is required"))?;
    let request = ControlRequest::new(to, command, key.to_owned())
        .map_err(|e| RpcError::invalid_params(e.to_string()))?;
    let sender = Sender {
        name: conn.caller().map(|id| hub.session_name(id)),
        session_id: conn.caller().map(str::to_owned),
        host: Some(crate::pairing::machine_name()),
        ..Sender::default()
    };
    let relay = MeshControlRelay::new(mesh.clone(), sender);
    let receipt = crate::mesh_control::submit(&relay, &request).await.map_err(error)?;
    let mut reply = serde_json::to_value(receipt).map_err(|e| RpcError::internal(e.to_string()))?;
    reply["idempotencyKey"] = json!(key);
    Ok(reply)
}
