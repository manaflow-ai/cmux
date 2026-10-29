//! Labs-gated team messaging over the configured mesh hub.

use super::*;
use crate::mesh::{Ack, MeshHub, Mode, OutMessage, Sender, Target};
use serde_json::{Value, json};
use std::sync::Arc;

const MAX_BODY: usize = 64 * 1024;

fn enabled(hub: &Arc<Hub>) -> bool {
    hub.config.try_read().map(|cfg| cfg.mesh_team_messaging).unwrap_or(false)
}

fn address(value: &Value) -> Result<&str, RpcError> {
    let value = value
        .as_str()
        .map(str::trim)
        .filter(|v| !v.is_empty())
        .ok_or_else(|| RpcError::invalid_params("team address is required"))?;
    if !crate::server::mesh_send::valid_team_address(value) {
        return Err(RpcError::invalid_params("team address must be @member/agent or @team/role"));
    }
    Ok(value)
}

fn hub_client(hub: &Arc<Hub>) -> Result<Arc<dyn MeshHub>, RpcError> {
    if !enabled(hub) {
        return Err(RpcError::invalid_params(
            "team messaging is disabled; enable meshTeamMessaging in Labs",
        )
        .with_data(json!({"reason": "team_messaging_disabled"})));
    }
    hub.mesh
        .get()
        .cloned()
        .ok_or_else(|| RpcError::internal("team messaging requires a configured mesh relay"))
}

fn caller_sender(hub: &Arc<Hub>, conn: &Arc<Conn>) -> Sender {
    let caller = conn.caller().filter(|_| !conn.is_person());
    let (name, team_address) = caller
        .and_then(|id| hub.resolve(id).ok())
        .map(|s| {
            let meta = s.meta();
            let address = meta.tags.get("teamAddress").map(|t| t.value.clone());
            (Some(meta.name), address)
        })
        .unwrap_or_else(|| (None, None));
    Sender {
        name,
        team_address,
        session_id: caller.map(str::to_owned),
        host: Some(crate::pairing::machine_name()),
        ..Sender::default()
    }
}

pub(super) async fn dispatch(
    hub: &Arc<Hub>,
    conn: &Arc<Conn>,
    method: &str,
    params: &Value,
) -> Result<Value, RpcError> {
    if conn.origin != Origin::Local {
        return Err(crate::hub::outbox::local_only());
    }
    let mesh = hub_client(hub)?;
    match method {
        method::MUX_TEAM_SEND => {
            let to = address(params.get("to").unwrap_or(&Value::Null))?;
            let body = params
                .get("body")
                .and_then(Value::as_str)
                .filter(|b| !b.trim().is_empty())
                .ok_or_else(|| RpcError::invalid_params("body is required"))?;
            if body.len() > MAX_BODY {
                return Err(RpcError::invalid_params("team message body is too large"));
            }
            let key = params
                .get("idempotencyKey")
                .and_then(Value::as_str)
                .filter(|v| !v.is_empty())
                .map(str::to_owned)
                .unwrap_or_else(|| uuid::Uuid::now_v7().to_string());
            let receipt = mesh
                .send(&OutMessage {
                    to: Target { team_address: Some(to.to_owned()), ..Target::default() },
                    from: caller_sender(hub, conn),
                    kind: crate::mesh::Kind::Prompt,
                    body: body.to_owned(),
                    mode: if params.get("startWork") == Some(&Value::Bool(true)) {
                        Mode::Now
                    } else {
                        Mode::TurnEnd
                    },
                    idempotency_key: key,
                })
                .await
                .map_err(|e| RpcError::invalid_params(format!("team message refused: {e}")))?;
            Ok(serde_json::to_value(receipt).unwrap_or_else(|_| json!({})))
        }
        method::MUX_TEAM_INBOX => {
            let unread = params.get("unreadOnly").and_then(Value::as_bool).unwrap_or(true);
            let messages = mesh
                .team_inbox(unread)
                .await
                .map_err(|e| RpcError::internal(format!("team inbox unavailable: {e}")))?;
            Ok(json!({"messages": messages}))
        }
        method::MUX_TEAM_READ => {
            let id = params
                .get("id")
                .and_then(Value::as_str)
                .filter(|v| crate::mesh::is_message_id(v))
                .ok_or_else(|| RpcError::invalid_params("id is required"))?;
            mesh.read(id)
                .await
                .map_err(|e| RpcError::internal(format!("team message read failed: {e}")))?;
            Ok(json!({"messageId": id, "state": "read"}))
        }
        method::MUX_TEAM_ACK => {
            let id = params
                .get("id")
                .and_then(Value::as_str)
                .filter(|v| crate::mesh::is_message_id(v))
                .ok_or_else(|| RpcError::invalid_params("id is required"))?;
            mesh.ack(id, &Ack::delivered(id, None))
                .await
                .map_err(|e| RpcError::internal(format!("team message ack failed: {e}")))?;
            Ok(json!({"messageId": id, "state": "acked"}))
        }
        _ => Err(RpcError::method_not_found(method)),
    }
}
