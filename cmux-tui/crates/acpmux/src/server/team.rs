//! Labs gated team-address messaging over the mesh hub.
//!
//! This keeps the CLI and MCP clients on one daemon path. The hub remains the
//! authority for address resolution and `startWork`; this layer only validates
//! the local request and passes the signed daemon identity to `MeshHub`.
//!
//! While the Labs flag is off, the inbox, read and ack of a chat's own agent read that chat's inbox
//! instead of refusing ([`chat_inbox`], `hub/inbox_team_page.rs`).

use super::*;
use crate::mesh::{Kind, MeshHub, Mode, OutMessage, Sender, Target};

pub(super) async fn handle(
    hub: &Arc<Hub>,
    conn: &Arc<Conn>,
    method: &str,
    params: &Value,
) -> Result<Value, RpcError> {
    if let Some(answer) = chat_inbox(hub, conn, method, params).await {
        return answer;
    }
    authorize(hub, conn).await?;
    let mesh =
        hub.mesh.get().ok_or_else(|| RpcError::internal("the mesh relay is not configured"))?;
    match method {
        crate::rpc::method::MUX_TEAM_SEND => send(hub, conn, mesh, params).await,
        crate::rpc::method::MUX_TEAM_INBOX => inbox(hub, conn, mesh, params).await,
        crate::rpc::method::MUX_TEAM_READ => read(hub, conn, mesh, params).await,
        crate::rpc::method::MUX_TEAM_ACK => ack(hub, conn, mesh, params).await,
        _ => Err(RpcError::method_not_found(method)),
    }
}

/// While team messaging is off, the mailbox's inbox, read and ack of an agent proven to run in a
/// chat here read that chat's own inbox (`hub/inbox_team_page.rs`): an agent started before the
/// inbox has `team_inbox` and not `inbox_read`, and `acpmux inbox` is the name an agent tries.
/// None for every other caller and method, and whenever team messaging is on.
async fn chat_inbox(
    hub: &Arc<Hub>,
    conn: &Arc<Conn>,
    method: &str,
    params: &Value,
) -> Option<Result<Value, RpcError>> {
    let read = matches!(
        method,
        crate::rpc::method::MUX_TEAM_INBOX
            | crate::rpc::method::MUX_TEAM_READ
            | crate::rpc::method::MUX_TEAM_ACK
    );
    if !read
        || conn.origin != Origin::Local
        || conn.is_person()
        || conn.unproven_caller.get().is_some()
    {
        return None;
    }
    let caller = conn.caller()?;
    if hub.config.read().await.mesh_relay.as_ref().is_some_and(|relay| relay.team_messaging) {
        return None;
    }
    let session = match hub.resolve(caller) {
        Ok(session) => session,
        Err(e) => return Some(Err(e)),
    };
    Some(match method {
        crate::rpc::method::MUX_TEAM_INBOX => {
            let unread_only = params.get("unreadOnly").and_then(Value::as_bool).unwrap_or(true);
            Ok(hub.inbox_team_page(&session, unread_only))
        }
        crate::rpc::method::MUX_TEAM_READ => match required(params, "id") {
            Ok(id) => hub.inbox_team_read(&session, &id),
            Err(e) => Err(e),
        },
        _ => match required(params, "id") {
            Ok(id) => hub.inbox_team_ack(&session, &id),
            Err(e) => Err(e),
        },
    })
}

pub(super) async fn authorize(hub: &Arc<Hub>, conn: &Arc<Conn>) -> Result<(), RpcError> {
    // A remote daemon may not borrow this daemon's team identity. Local agents use
    // their proven caller session; an owner at the owner-only socket may browse all
    // addresses the platform grants this daemon. Team membership is checked by the hub.
    if conn.origin != Origin::Local && !conn.is_person() {
        return Err(RpcError::invalid_params(
            "team messaging requires the local socket or the app",
        ));
    }
    if conn.unproven_caller.get().is_some() && !conn.is_person() {
        return Err(forbidden());
    }
    let enabled =
        hub.config.read().await.mesh_relay.as_ref().is_some_and(|relay| relay.team_messaging);
    if !enabled {
        return Err(RpcError::invalid_params(
            "team messaging is disabled; enable meshRelay.teamMessaging in Labs",
        )
        .with_data(json!({"reason": "team_messaging_disabled", "labs": true})));
    }
    Ok(())
}

async fn send(
    hub: &Arc<Hub>,
    conn: &Arc<Conn>,
    mesh: &Arc<dyn MeshHub>,
    params: &Value,
) -> Result<Value, RpcError> {
    let raw = required(params, "to")?;
    let address = raw.strip_prefix('@').unwrap_or(&raw);
    if !super::mesh_send::valid_team_address(&format!("@{address}")) {
        return Err(RpcError::invalid_params("team address must be @member/agent or @team/role"));
    }
    let body = params
        .get("body")
        .and_then(Value::as_str)
        .filter(|body| !body.trim().is_empty())
        .ok_or_else(|| RpcError::invalid_params("body is required"))?
        .to_owned();
    let wire_address = format!("@{address}");
    let id = params
        .get("idempotencyKey")
        .or_else(|| params.get("id"))
        .and_then(Value::as_str)
        .filter(|id| !id.is_empty())
        .map(ToOwned::to_owned)
        .unwrap_or_else(|| uuid::Uuid::now_v7().to_string());
    let caller = conn.caller().filter(|_| !conn.is_person());
    let receipt = mesh
        .send(&OutMessage {
            to: Target { team_address: Some(wire_address.clone()), ..Target::default() },
            from: Sender {
                name: caller.map(|id| hub.session_name(id)),
                session_id: caller.map(str::to_owned),
                host: Some(crate::pairing::machine_name()),
                ..Sender::default()
            },
            kind: Kind::Prompt,
            op: None,
            body,
            // The hub alone decides whether this message may start work.
            mode: Mode::TurnEnd,
            idempotency_key: sender_key(conn, &id)?,
        })
        .await
        .map_err(|e| RpcError::invalid_params(format!("the mesh hub refused team message: {e}")))?;
    remember_sender(hub, conn, &receipt.message_id, &wire_address)?;
    Ok(serde_json::to_value(receipt).unwrap_or(Value::Null))
}

async fn inbox(
    _hub: &Arc<Hub>,
    conn: &Arc<Conn>,
    mesh: &Arc<dyn MeshHub>,
    params: &Value,
) -> Result<Value, RpcError> {
    let unread_only = params.get("unreadOnly").and_then(Value::as_bool).unwrap_or(true);
    let before = params.get("before").and_then(Value::as_u64);
    let mut page = mesh
        .team_messages(unread_only, None, before)
        .await
        .map_err(|e| RpcError::internal(format!("the mesh hub did not answer: {e}")))?;
    page.messages.retain(|message| may_read(conn, &message.to));
    Ok(serde_json::to_value(page).unwrap_or(Value::Null))
}

/// Local session identity, not a mutable address tag, scopes agent access. The hub
/// authorizes this daemon's recipient addresses before returning any page or receipt.
pub(super) fn may_read(conn: &Conn, to: &Target) -> bool {
    conn.is_person() || conn.caller().is_none_or(|id| to.session_id.as_deref() == Some(id))
}

async fn read(
    _hub: &Arc<Hub>,
    conn: &Arc<Conn>,
    mesh: &Arc<dyn MeshHub>,
    params: &Value,
) -> Result<Value, RpcError> {
    let id = required(params, "id")?;
    let mut before = None;
    // Browse all pages to locate the body; this never steals the relay's lease.
    loop {
        let page = mesh
            .team_messages(false, None, before)
            .await
            .map_err(|e| RpcError::internal(format!("the mesh hub did not answer: {e}")))?;
        if let Some(mut message) = page
            .messages
            .into_iter()
            .find(|message| message.message_id == id && may_read(conn, &message.to))
        {
            let receipt = mesh.read(&id).await.map_err(|e| {
                RpcError::internal(format!("the mesh hub did not mark it read: {e}"))
            })?;
            message.state = Some(receipt.state.clone());
            return Ok(json!({"message": message, "receipt": receipt}));
        }
        match page.next {
            Some(next) if before.is_none_or(|previous| next < previous) => before = Some(next),
            _ => return Err(forbidden()),
        }
    }
}

async fn ack(
    _hub: &Arc<Hub>,
    conn: &Arc<Conn>,
    mesh: &Arc<dyn MeshHub>,
    params: &Value,
) -> Result<Value, RpcError> {
    let id = required(params, "id")?;
    let receipt = mesh.receipt(&id).await.map_err(|_| forbidden())?;
    if receipt.to.team_address.is_none() || !may_read(conn, &receipt.to) {
        return Err(forbidden());
    }
    let receipt = mesh.acknowledge(&id).await.map_err(|e| {
        RpcError::internal(format!("the mesh hub did not accept the acknowledgement: {e}"))
    })?;
    Ok(serde_json::to_value(receipt).unwrap_or(Value::Null))
}

pub(super) fn forbidden() -> RpcError {
    RpcError::invalid_params("team message is not addressed to this session")
        .with_data(json!({"reason": "team.forbidden"}))
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

#[cfg(test)]
#[path = "team_tests.rs"]
mod tests;

/// Ownership comes from the proven connection and a local journal entry, never sender hints.
pub(super) fn remember_sender(
    hub: &Hub,
    conn: &Conn,
    id: &str,
    address: &str,
) -> Result<(), RpcError> {
    if !hub.outbox.record_team_receipt(id, address, conn.caller().filter(|_| !conn.is_person())) {
        return Err(RpcError::internal("team message sent, but its origin could not be persisted")
            .with_data(json!({"messageId": id})));
    }
    if let Some(caller) = conn.caller().filter(|_| !conn.is_person()) {
        let session = hub.resolve(caller).map_err(|_| forbidden())?;
        if !hub.record_team_send(&session, id) {
            return Err(RpcError::internal(
                "team message sent, but sender receipt could not be persisted",
            )
            .with_data(json!({"messageId": id})));
        }
    }
    Ok(())
}

/// Namespace caller-selected retry keys so another session cannot recover a sender's receipt.
pub(super) fn sender_key(conn: &Conn, id: &str) -> Result<String, RpcError> {
    let identity = conn.caller().filter(|_| !conn.is_person());
    let seed = serde_json::to_vec(&(identity, id))
        .map_err(|e| RpcError::internal(format!("cannot encode team retry key: {e}")))?;
    Ok(format!("team:{}", crate::sha256::sha256_hex(&seed)))
}
