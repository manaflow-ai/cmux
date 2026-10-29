//! Labs gated team-address messaging over the mesh hub.
//!
//! This keeps the CLI and MCP clients on one daemon path. The hub remains the
//! authority for address resolution and `startWork`; this layer only validates
//! the local request and passes the signed daemon identity to `MeshHub`.

use super::*;
use crate::mesh::{Ack, Kind, MeshHub, Mode, OutMessage, Sender, Target};

pub(super) async fn handle(
    hub: &Arc<Hub>,
    conn: &Arc<Conn>,
    method: &str,
    params: &Value,
) -> Result<Value, RpcError> {
    let enabled =
        hub.config.read().await.mesh_relay.as_ref().is_some_and(|relay| relay.team_messaging);
    if !enabled {
        return Err(RpcError::invalid_params(
            "team messaging is disabled; enable meshRelay.teamMessaging in Labs",
        )
        .with_data(json!({"reason": "team_messaging_disabled", "labs": true})));
    }
    let mesh =
        hub.mesh.get().ok_or_else(|| RpcError::internal("the mesh relay is not configured"))?;
    match method {
        crate::rpc::method::MUX_TEAM_SEND => send(hub, conn, mesh, params).await,
        crate::rpc::method::MUX_TEAM_INBOX => inbox(hub, conn, mesh, params).await,
        crate::rpc::method::MUX_TEAM_READ => read(mesh, params).await,
        crate::rpc::method::MUX_TEAM_ACK => ack(mesh, params).await,
        _ => Err(RpcError::method_not_found(method)),
    }
}

async fn send(
    hub: &Arc<Hub>,
    conn: &Arc<Conn>,
    mesh: &Arc<dyn MeshHub>,
    params: &Value,
) -> Result<Value, RpcError> {
    let raw = required(params, "to")?;
    let address = raw.strip_prefix('@').unwrap_or(&raw);
    if !valid_address(address) {
        return Err(RpcError::invalid_params("team address must be @member/agent or @team/role"));
    }
    let body = required(params, "body")?;
    let wire_address = format!("@{address}");
    let id = params
        .get("idempotencyKey")
        .or_else(|| params.get("id"))
        .and_then(Value::as_str)
        .filter(|id| !id.is_empty())
        .map(ToOwned::to_owned)
        .unwrap_or_else(|| uuid::Uuid::now_v7().to_string());
    let caller = conn.caller().filter(|_| !conn.is_person());
    let caller_session = caller.and_then(|id| hub.resolve(id).ok());
    let receipt = mesh
        .send(&OutMessage {
            to: Target { team_address: Some(wire_address), ..Target::default() },
            from: Sender {
                name: caller.map(|id| hub.session_name(id)),
                session_id: caller.map(str::to_owned),
                team_address: caller_session
                    .as_ref()
                    .and_then(|session| session.meta().tags.get("teamAddress"))
                    .map(|tag| tag.value.clone()),
                host: Some(crate::pairing::machine_name()),
                ..Sender::default()
            },
            kind: Kind::Prompt,
            body,
            // The hub alone decides whether this message may start work.
            mode: Mode::TurnEnd,
            idempotency_key: id,
        })
        .await
        .map_err(|e| RpcError::invalid_params(format!("the mesh hub refused team message: {e}")))?;
    Ok(serde_json::to_value(receipt).unwrap_or(Value::Null))
}

async fn inbox(
    hub: &Arc<Hub>,
    conn: &Arc<Conn>,
    mesh: &Arc<dyn MeshHub>,
    params: &Value,
) -> Result<Value, RpcError> {
    let unread_only = params.get("unreadOnly").and_then(Value::as_bool).unwrap_or(true);
    let team_address = conn
        .caller()
        .and_then(|id| hub.resolve(id).ok())
        .and_then(|session| session.meta().tags.get("teamAddress").map(|tag| tag.value.clone()));
    let team_address = team_address
        .or_else(|| params.get("teamAddress").and_then(Value::as_str).map(str::to_owned));
    let rows = mesh
        .team_inbox_for(unread_only, team_address.as_deref())
        .await
        .map_err(|e| RpcError::internal(format!("the mesh hub did not answer: {e}")))?
        .into_iter()
        .map(|m| serde_json::to_value(m).unwrap_or(Value::Null))
        .collect::<Vec<_>>();
    Ok(json!({"messages": rows}))
}

async fn read(mesh: &Arc<dyn MeshHub>, params: &Value) -> Result<Value, RpcError> {
    let id = required(params, "id")?;
    mesh.read(&id)
        .await
        .map_err(|e| RpcError::internal(format!("the mesh hub did not mark it read: {e}")))?;
    Ok(json!({"messageId": id, "state": "read"}))
}

async fn ack(mesh: &Arc<dyn MeshHub>, params: &Value) -> Result<Value, RpcError> {
    let id = required(params, "id")?;
    mesh.ack(&id, &Ack::delivered(&id, None))
        .await
        .map_err(|e| RpcError::internal(format!("the mesh hub did not accept the ack: {e}")))?;
    Ok(json!({"id": id, "state": "acked"}))
}

fn required(params: &Value, name: &str) -> Result<String, RpcError> {
    params
        .get(name)
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .map(ToOwned::to_owned)
        .ok_or_else(|| RpcError::invalid_params(format!("{name} is required")))
}

fn valid_address(address: &str) -> bool {
    let Some((scope, role)) = address.split_once('/') else { return false };
    !scope.is_empty()
        && !role.is_empty()
        && scope.chars().all(|c| c.is_ascii_alphanumeric() || c == '_' || c == '-')
        && role.chars().all(|c| c.is_ascii_alphanumeric() || c == '_' || c == '-')
}

#[cfg(test)]
mod tests {
    use super::valid_address;

    #[test]
    fn team_address_requires_a_scope_and_role() {
        assert!(valid_address("lawrence/coordinator"));
        assert!(valid_address("team/release"));
        assert!(!valid_address("@team/release"));
        assert!(!valid_address("team"));
        assert!(!valid_address("team/release/extra"));
    }
}
