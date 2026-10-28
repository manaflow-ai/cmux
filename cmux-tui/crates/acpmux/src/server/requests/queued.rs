//! Requests about one queued prompt before its turn: `_acpmux/queue_remove {sessionId,
//! promptId}`, its sender taking it back (`author.rs`), and the owner's answer to a person's prompt
//! that waits for them (`hub/queue_approve.rs`): `_acpmux/queue_approve {sessionId, promptId,
//! turnId, revision}` and `_acpmux/queue_decline {sessionId, promptId}`, and `_acpmux/queue_get
//! {sessionId, promptId}`, which reads it whole before the answer. These are the owner's only:
//! a request that names a person (`_meta.acpmux.author`) is refused `queue.owner_only`. From Web it
//! counts as controlling the chat, as a Web prompt does (`remote_guard.rs`), and a chat in Full
//! access by a machine's setting takes any of them from that machine only (`full_access_hold`).
//! An approved prompt then runs under the approver's rules as well as its sender's: the stricter
//! control, the trust gate and the Full-access machine (`Hub::approve_queued`). A peer's chat gets
//! them forwarded (`peer_forward.rs`).

use super::*;

/// Whether `m` is one of them.
pub(super) fn handles(m: &str) -> bool {
    matches!(
        m,
        method::MUX_QUEUE_REMOVE
            | method::MUX_QUEUE_APPROVE
            | method::MUX_QUEUE_DECLINE
            | method::MUX_QUEUE_GET
    )
}

pub(super) async fn handle(
    hub: &Arc<Hub>,
    conn: &Arc<Conn>,
    m: &str,
    params: &Value,
) -> Result<Value, RpcError> {
    let s = hub.resolve(session_key(params)?)?;
    // The queue a restart rebuilds from the logs.
    hub.session_log(&s).await;
    let prompt_id = str_param(params, "promptId")
        .ok_or_else(|| RpcError::invalid_params("promptId is required"))?;
    // Again after the wait, right before the change (`full_access_hold`).
    let control = super::super::remote_guard::control_of(conn.origin, conn.auth, params);
    let device = super::super::remote_guard::full_access_device(hub, conn, params);
    hub.full_access_hold(&s.meta(), control, device.as_deref())?;
    let mut reply = json!({"sessionId": s.id, "promptId": prompt_id});
    if m == method::MUX_QUEUE_REMOVE {
        // Only its sender takes a prompt back (`author.rs`), checked as it leaves.
        let author = crate::author::author(params)?;
        let editor = crate::author::editor(author.as_ref());
        // `acpmux session queue clear --from-agents`: only while it is another agent's
        // message, checked as it leaves, so an edit meanwhile keeps the person's prompt.
        let agents_only = params.get("fromAgentsOnly").and_then(Value::as_bool) == Some(true);
        let w = hub.withdraw_queued(&s, prompt_id, editor, agents_only)?;
        reply.set("removed", json!(w == crate::hub::Withdrawn::Removed));
        if agents_only {
            reply.set("fromAgentsOnly", json!(true));
            reply.set("notFromAgent", json!(w == crate::hub::Withdrawn::NotFromAgent));
        }
        return Ok(reply);
    }
    crate::author::owner_only(params)?;
    hub.web_control_check(&s, control)?;
    if m == method::MUX_QUEUE_GET {
        return hub.queued_get(&s, prompt_id);
    }
    if m == method::MUX_QUEUE_APPROVE {
        let turn_id = str_param(params, "turnId").filter(|id| !id.is_empty()).ok_or_else(|| {
            RpcError::invalid_params("turnId is required: the queued incarnation the owner saw")
        })?;
        let revision = params.get("revision").and_then(Value::as_u64).ok_or_else(|| {
            RpcError::invalid_params("revision is required: the one the queue listed")
        })?;
        let gated = super::super::trust_gate::gated(conn.origin, params);
        let by = crate::hub::Approver { control, trust_gate: gated, device: device.as_deref() };
        hub.approve_queued(&s, prompt_id, turn_id, revision, &by)?;
        reply.set("turnId", json!(turn_id));
        reply.set("approved", json!(true));
        reply.set("revision", json!(revision));
    } else {
        hub.decline_queued(&s, prompt_id)?;
        reply.set("declined", json!(true));
    }
    Ok(reply)
}
