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

/// A start's `session/new` params, stamped with `answer`, this Mac's answer to cmux's tools: the
/// chat there follows it, never the caller's (`hub/cmux_tools_answer.rs`), as a `session/new`
/// forwarded to a peer does.
fn start_params(params: &Value, answer: &str) -> Result<serde_json::Map<String, Value>, RpcError> {
    let mut start = Value::Object(
        params
            .as_object()
            .cloned()
            .ok_or_else(|| RpcError::invalid_params("start requires params"))?,
    );
    crate::hub::cmux_tools_answer::stamp(&mut start, answer);
    match start {
        Value::Object(params) => Ok(params),
        _ => Err(RpcError::internal("start params are not an object")),
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
        Some("start") => {
            let start = start_params(
                &params["params"],
                crate::hub::cmux_tools_answer::here(crate::user_settings::text().as_deref()),
            )?;
            // The person's start level, or a full-access caller's, as a start through an ssh
            // peer carries it (`hub/full_access_children.rs`): the machine serves the relay as a
            // peer daemon, so without it every such chat started asking there (hq#11835 row 4).
            let mut start = Value::Object(start);
            let person = super::requests::person_start(conn, &start);
            hub.forward_start_policy(person, conn.caller(), &mut start).await;
            let Value::Object(params) = start else {
                return Err(RpcError::invalid_params("start requires params"));
            };
            Command::Start { params }
        }
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

#[cfg(test)]
mod tests {
    use super::*;

    /// A start carries this Mac's answer over whatever its caller put there; its other fields stay.
    #[test]
    fn a_start_carries_this_macs_answer_not_the_callers() {
        let caller =
            json!({"cwd": "/w", "_meta": {"acpmux": {"cmuxTools": "on", "harness": "codex"}}});
        let params = start_params(&caller, "off").unwrap();
        assert_eq!(params["_meta"]["acpmux"]["cmuxTools"], "off");
        assert_eq!(params["_meta"]["acpmux"]["harness"], "codex");
        assert_eq!(params["cwd"], "/w");
        assert_eq!(
            start_params(&json!({"cwd": "/w"}), "on").unwrap()["_meta"]["acpmux"]["cmuxTools"],
            "on"
        );
        assert!(start_params(&json!("x"), "on").is_err());
    }
}
