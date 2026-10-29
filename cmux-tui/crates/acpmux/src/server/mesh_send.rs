//! A send to a name nobody here resolves, through the team hub (`mesh_relay.rs`), and its status.
//!
//! `_acpmux/send_queue` for a target that is no session here, on no peer and on no peer that is
//! down posts it to the hub when the relay is on (`Hub::mesh`): text only, `now` when the send
//! steers and `turn-end` when it does not, the prompt id as the idempotency key (the same send
//! again is the same message), and as its sender the session the connection proved (its name and
//! id, never a `fromAgent` the request claims) and this machine's name. `HOST/NAME` names a session on that host. The delivery id it
//! answers is `mesh:<messageId>`; `_acpmux/send_status` of one reads the hub's receipt once, with
//! no wait. The hub's refusals answer as this daemon's: a name it does not know is `no session`,
//! and one several hosts have lists them.

use super::*;
use crate::mesh::{HubError, Kind, MeshHub, Mode, OutMessage, Receipt, Sender, Target};

/// The prefix of a delivery id the hub holds.
pub(super) const PREFIX: &str = "mesh:";

/// The hub's idempotency key for prompt id `id`: itself when the hub takes it
/// (`[A-Za-z0-9._:-]{8,128}`), else a digest of it.
fn idempotency_key(id: &str) -> String {
    let fits = (8..=128).contains(&id.len())
        && id.bytes().all(|b| b.is_ascii_alphanumeric() || b"._:-".contains(&b));
    if fits {
        id.to_owned()
    } else {
        format!("p:{}", &crate::sha256::sha256_hex(id.as_bytes())[..40])
    }
}

/// Whom `target` names: `HOST/NAME`, or a bare name.
fn recipient(target: &str) -> Target {
    if target.starts_with('@') {
        return Target { team_address: Some(target.to_owned()), ..Target::default() };
    }
    match target.split_once('/') {
        Some((host, name)) if !host.is_empty() && !name.is_empty() => {
            Target { name: Some(name.into()), host: Some(host.into()), ..Target::default() }
        }
        _ => Target { name: Some(target.into()), ..Target::default() },
    }
}

pub(super) async fn send(
    hub: &Arc<Hub>,
    conn: &Arc<Conn>,
    mesh: &Arc<dyn MeshHub>,
    request: &Value,
    target: &str,
) -> Result<Value, RpcError> {
    if target.starts_with('@') {
        let enabled =
            hub.config.read().await.mesh_relay.as_ref().is_some_and(|relay| relay.team_messaging);
        if !enabled {
            return Err(RpcError::invalid_params(
                "team messaging is disabled; enable meshTeamMessaging in Labs",
            )
            .with_data(json!({"reason": "team_messaging_disabled", "address": target})));
        }
        if !valid_team_address(target) {
            return Err(RpcError::invalid_params(
                "team address must be @member/agent or @team/role",
            )
            .with_data(json!({"reason": "team.invalid_address", "address": target})));
        }
    }
    let mut texts = Vec::new();
    // These refusals never say "no session": `acpmux send` turns any error with those words into
    // its own not-found error (cli/run/send_async.rs), which would hide what to change.
    for block in request.get("prompt").and_then(Value::as_array).into_iter().flatten() {
        match (block.get("type").and_then(Value::as_str), block.get("text").and_then(Value::as_str))
        {
            (Some("text"), Some(text)) => texts.push(text),
            _ => {
                return Err(RpcError::invalid_params(format!(
                    "{target:?} is reached only through the mesh relay, which carries text only: send it without attachments"
                ))
                .with_data(json!({"reason": "mesh.text_only", "session": target})));
            }
        }
    }
    let mux = request.pointer("/_meta/acpmux");
    let field = |k: &str| mux.and_then(|m| m.get(k));
    // The hub's message carries no supersede key, so the target could not replace the earlier
    // prompt: refused, never dropped (a send that says it replaced nothing it was asked to).
    if field("supersede").is_some_and(|k| !k.is_null()) {
        return Err(RpcError::invalid_params(format!(
            "{target:?} is reached only through the mesh relay, which cannot carry --supersede: send it without one"
        ))
        .with_data(json!({"reason": "mesh.no_supersede", "session": target})));
    }
    let prompt_id = field("promptId")
        .and_then(Value::as_str)
        .filter(|id| !id.is_empty())
        .map_or_else(|| uuid::Uuid::now_v7().to_string(), str::to_owned);
    // The proven caller names the sender; `fromAgent` (anything a client writes) only when no
    // session is proven, as a display name.
    let caller = conn.caller().filter(|_| !conn.is_person());
    let caller_session = caller.and_then(|id| hub.resolve(id).ok());
    let named = field("fromAgent").and_then(Value::as_str).map(str::to_owned);
    let message = OutMessage {
        to: recipient(target),
        from: Sender {
            name: caller.map(|id| hub.session_name(id)).or(named),
            session_id: caller.map(str::to_owned),
            team_address: caller_session.as_ref().and_then(|session| {
                session.meta().tags.get("teamAddress").map(|tag| tag.value.clone())
            }),
            host: Some(crate::pairing::machine_name()),
            ..Sender::default()
        },
        kind: Kind::Prompt,
        body: texts.join("\n\n"),
        mode: if field("steer") == Some(&json!(true)) { Mode::Now } else { Mode::TurnEnd },
        idempotency_key: idempotency_key(&prompt_id),
    };
    let receipt = mesh.send(&message).await.map_err(|e| refusal(target, e))?;
    Ok(status_of(&receipt, target))
}

/// `_acpmux/send_status` of a delivery the hub holds: its receipt, read once.
pub(super) async fn status(mesh: &Arc<dyn MeshHub>, id: &str) -> Result<Value, RpcError> {
    let message = id.strip_prefix(PREFIX).unwrap_or(id);
    let receipt = mesh.receipt(message).await.map_err(|e| {
        if e.refused {
            RpcError::invalid_params(format!("no delivery {id}: {e}"))
                .with_data(json!({"reason": "outbox.unknown", "deliveryId": id}))
        } else {
            // The hub did not answer: the delivery may well be there; ask again later.
            RpcError::internal(format!("the mesh hub did not answer for {id}: {e}")).with_data(
                json!({"reason": "mesh.unavailable", "retryable": true, "deliveryId": id}),
            )
        }
    })?;
    let target = match (&receipt.to.host, &receipt.to.name) {
        (Some(host), Some(name)) => format!("{host}/{name}"),
        (_, name) => name.clone().unwrap_or_default(),
    };
    Ok(status_of(&receipt, &target))
}

/// A receipt in the outbox's status shape (`hub/outbox.rs` `Delivery::status`). Its `promptId`
/// is the one the target runs it with: the hub's message id (`mesh_relay.rs` `deliver`).
fn status_of(receipt: &Receipt, target: &str) -> Value {
    let status = match receipt.state.as_str() {
        "leased" => "delivering",
        "delivered" => "delivered",
        "refused" | "expired" => "failed",
        _ => "queued",
    };
    let accepted = (status == "delivered")
        .then(|| json!({"promptId": receipt.prompt_id, "detail": receipt.detail}));
    let error = (status == "failed")
        .then(|| receipt.detail.clone().unwrap_or_else(|| receipt.state.clone()));
    let updated = receipt.acked_at.or(receipt.leased_until).unwrap_or(receipt.created_at);
    json!({
        "deliveryId": format!("{PREFIX}{}", receipt.message_id),
        "target": target,
        "promptId": receipt.prompt_id.as_deref().unwrap_or(&receipt.message_id),
        "via": "mesh",
        "status": status,
        "attempts": receipt.attempt,
        "error": error,
        "accepted": accepted,
        "resolution": receipt.resolution,
        "startWork": receipt.start_work,
        "createdAt": receipt.created_at,
        "updatedAt": updated.max(receipt.created_at),
    })
}

/// The hub's refusal as this daemon's own.
fn refusal(target: &str, e: HubError) -> RpcError {
    if target.starts_with('@') {
        return RpcError::invalid_params(format!("team message was refused: {e}")).with_data(
            json!({"reason": e.code.as_deref().unwrap_or("team.refused"), "address": target}),
        );
    }
    match e.code.as_deref() {
        Some("mesh.unknown_recipient") => RpcError::invalid_params(format!("no session: {target}"))
            .with_data(json!({"reason": "no_session", "session": target})),
        Some("mesh.ambiguous") => RpcError::invalid_params(format!(
            "{target:?} names sessions on several hosts; send to HOST/{target}"
        ))
        .with_data(
            json!({"reason": "mesh.ambiguous", "session": target, "candidates": e.candidates}),
        ),
        _ if e.refused => RpcError::invalid_params(format!("the mesh hub refused it: {e}"))
            .with_data(json!({"reason": "mesh.refused", "session": target})),
        _ => RpcError::internal(format!("the mesh hub did not take it: {e}"))
            .with_data(json!({"reason": "mesh.unavailable", "retryable": true})),
    }
}

/// Team-scoped addresses are intentionally narrow so they cannot be confused
/// with a host/session key or smuggle URL/path syntax into the hub.
pub(super) fn valid_team_address(address: &str) -> bool {
    let Some(rest) = address.strip_prefix('@') else { return false };
    let Some((scope, name)) = rest.split_once('/') else { return false };
    !scope.is_empty()
        && !name.is_empty()
        && scope.len() <= 128
        && name.len() <= 128
        && scope.bytes().all(|b| b.is_ascii_alphanumeric() || b"._-".contains(&b))
        && name.bytes().all(|b| b.is_ascii_alphanumeric() || b"._-".contains(&b))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_prompt_id_the_hub_would_refuse_as_a_key_is_digested() {
        let id = "0190f2a4-7c1e-7d3a-9f00-0123456789ab";
        assert_eq!(idempotency_key(id), id);
        let short = idempotency_key("abc");
        assert!(short.starts_with("p:") && short.len() == 42, "{short}");
        assert_eq!(idempotency_key("has space in it"), idempotency_key("has space in it"));
        assert_eq!(recipient("huge-blue/dep-land").host.as_deref(), Some("huge-blue"));
        assert_eq!(recipient("dep-land").host, None);
        assert_eq!(
            recipient("@lawrence/coordinator").team_address.as_deref(),
            Some("@lawrence/coordinator")
        );
        assert!(valid_team_address("@team/role"));
        assert!(!valid_team_address("@team"));
    }
}
