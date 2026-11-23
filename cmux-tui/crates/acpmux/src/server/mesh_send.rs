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
//!
//! [`relay`] is the outbox's other transport (`outbox.rs`): a delivery for a peer whose link is
//! down, which no attempt has sent, goes to the hub for the session id the peer's last list
//! named, so the hub never picks a session by a name an id was typed as.

use super::*;
use crate::mesh::{HubError, Kind, MeshHub, Mode, OutMessage, Receipt, Sender, Target};
use crate::prompt_class::PromptClass;
use std::time::Duration;

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
        let digest = crate::sha256::sha256_hex(id.as_bytes());
        format!("p:{}", digest.get(..40).unwrap_or(&digest))
    }
}

/// Whom `target` names: `HOST/ID`, `HOST/NAME`, or a bare name.
fn recipient(target: &str) -> Target {
    if target.starts_with('@') {
        return Target { team_address: Some(target.to_owned()), ..Target::default() };
    }
    match target.split_once('/') {
        // `HOST/ID` names that session by its id (session ids are UUIDs), as a read does
        // (`mesh_read.rs`): the hub matches a name only against names.
        Some((host, id)) if !host.is_empty() && uuid::Uuid::try_parse(id).is_ok() => {
            Target { session_id: Some(id.into()), host: Some(host.into()), ..Target::default() }
        }
        Some((host, name)) if !host.is_empty() && !name.is_empty() => {
            Target { name: Some(name.into()), host: Some(host.into()), ..Target::default() }
        }
        _ => Target { name: Some(target.into()), ..Target::default() },
    }
}

/// Whom the relay reaches for `target` while its peer's link is down: the session the peer's
/// last list named, by its id alone (the hub matches every field it is given, and the host the
/// hub knows is the peer's own machine name, which need not be the name this daemon gives it). A
/// `PEER/KEY` the peer never listed goes by KEY: as that id when it is one (session ids are
/// UUIDs), else as a name on host PEER, as `HOST/NAME` goes (`recipient`). None when nothing
/// names a peer that is down, or `target` is a session here.
fn down_peer_recipient(hub: &Hub, target: &str) -> Option<Target> {
    if hub.resolve(target).is_ok() {
        return None;
    }
    if let Some((peer, id, _)) = hub.resolve_remote(target) {
        let down = !peer.connected.load(std::sync::atomic::Ordering::SeqCst);
        return down.then(|| Target { session_id: Some(id), ..Target::default() });
    }
    hub.peer_down_for(target)?;
    let (host, key) = target.split_once('/')?;
    if uuid::Uuid::try_parse(key).is_ok() {
        return Some(Target { session_id: Some(key.to_owned()), ..Target::default() });
    }
    Some(Target { name: Some(key.into()), host: Some(host.into()), ..Target::default() })
}

/// The outbox's delivery through the hub while its peer is down (`outbox.rs`): the hub's
/// acceptance, in the shape the outbox keeps (`relayDeliveryId` names the hub's message), or the
/// hub's error. None when the relay is off, the peer is not down, or the delivery carries what
/// the relay cannot: the outbox keeps it and tries the peer again. A delivery posted before is
/// posted again as the same message (`Delivery::relay_post`), down peer or not; a first post is
/// recorded before it goes, so a restart or a lost answer never leaves the outbox thinking
/// nothing was sent.
pub(super) async fn relay(
    hub: &Arc<Hub>,
    delivery: &crate::hub::outbox::Delivery,
) -> Option<Result<Value, HubError>> {
    let mesh = hub.mesh.get()?;
    let message = match &delivery.relay_post {
        // A hub that is failing is probed once per window, not by every delivery (`mesh_gate.rs`).
        Some(_) if !hub.mesh.gate().may_try() => return Some(Err(backing_off(false))),
        Some(post) => post.clone(),
        None => {
            let to = down_peer_recipient(hub, &delivery.target)?;
            let carried = carried(&delivery.request, &delivery.target).ok()?;
            // A class goes to the peer itself once it is back, where the receiver reads it as
            // one, rather than as a line of the text now.
            if carried.inline.is_some() {
                return None;
            }
            // Not asked while its gate is shut: nothing is posted, so the peer's link may still
            // take it (`relay_attempt`).
            if !hub.mesh.gate().may_try() {
                return Some(Err(backing_off(true)));
            }
            let message = OutMessage {
                to,
                from: sender(hub, delivery.caller.as_deref(), carried.named, carried.claim),
                kind: Kind::Prompt,
                op: None,
                body: carried.body,
                mode: carried.mode,
                idempotency_key: idempotency_key(&carried.prompt_id),
            };
            hub.outbox.update(&delivery.id, |d| d.relay_post = Some(message.clone()));
            message
        }
    };
    let posted = tokio::time::timeout(RELAY_WAIT, mesh.send(&message)).await.unwrap_or_else(|_| {
        Err(HubError::unavailable(format!("no answer within {}s", RELAY_WAIT.as_secs())))
    });
    note(hub, &posted);
    Some(posted.map(|receipt| relay_row(hub, delivery, &message, &receipt)))
}

/// The code of a relay attempt the hub's gate kept from asking (`mesh_gate.rs`).
pub(super) const BACKING_OFF: &str = "acpmux.hub_backing_off";

/// A relay attempt the hub's gate kept from asking. `unposted`: no post of it may be at the hub,
/// so the outbox may still send it on the peer's link.
fn backing_off(unposted: bool) -> HubError {
    let mut e = if unposted {
        HubError::refused("the hub is backing off after failing; not posted")
    } else {
        HubError::unavailable("the hub is backing off after failing; retrying")
    };
    e.code = Some(BACKING_OFF.to_owned());
    e
}

/// How long one relay attempt waits for the hub. Its key makes the next attempt the same message,
/// so a hub that took it and did not answer in time never gets it twice.
const RELAY_WAIT: Duration = Duration::from_secs(30);

/// How long `_acpmux/send_queue` waits for the hub before it queues the message (RFD 0049 R1:
/// the call returns well under 500 ms whatever the hub does).
pub(super) const INLINE_WAIT: Duration = Duration::from_millis(300);

/// What a post's outcome tells the hub's gate.
fn note<T>(hub: &Hub, posted: &Result<T, HubError>) {
    match posted {
        Err(e) if crate::mesh_retry::transient(e, true) => hub.mesh.gate().failed(e.retry_after),
        _ => hub.mesh.gate().answered(),
    }
}

/// Why a queued send waits, as `send --status` shows it: `hub 503, retrying`.
pub(super) fn waiting_reason(e: &HubError) -> String {
    match (e.status, e.code.as_deref()) {
        (Some(status), Some(code)) => format!("hub {status} {code}, retrying"),
        (Some(status), None) => format!("hub {status}, retrying"),
        _ => format!("hub did not answer ({e}), retrying"),
    }
}

/// What `_acpmux/send_queue` does with a target only the hub routes.
pub(super) enum Posted {
    /// The hub took it, or refused it: the answer as it is.
    Answered(Result<Value, RpcError>),
    /// The hub did not take it in a way that passes (a 5xx, a 429, no answer within
    /// [`INLINE_WAIT`], no connection), or its gate is shut: kept in the outbox with this post,
    /// which its retry sends again under the same key, and why it waits.
    Queue { post: OutMessage, why: String },
}

/// `_acpmux/send_queue` to `target`, which nothing here resolves and the hub may (RFD 0049 R1): a
/// remote failure never fails a send the outbox can keep. Team addresses keep [`send`].
pub(super) async fn post_or_queue(
    hub: &Arc<Hub>,
    conn: &Arc<Conn>,
    mesh: &Arc<dyn MeshHub>,
    request: &Value,
    target: &str,
) -> Posted {
    let (message, inline, caller) = match message(hub, conn, request, target) {
        Ok(made) => made,
        Err(e) => return Posted::Answered(Err(e)),
    };
    if !hub.mesh.gate().may_try() {
        let why = "hub failing, retrying (backing off before it is asked again)".to_owned();
        return Posted::Queue { post: message, why };
    }
    let posted =
        tokio::time::timeout(INLINE_WAIT, mesh.send(&message)).await.unwrap_or_else(|_| {
            Err(HubError::unavailable(format!("no answer within {} ms", INLINE_WAIT.as_millis())))
        });
    note(hub, &posted);
    match posted {
        Ok(receipt) => {
            hub.outbox.record_mesh_origin(&receipt.message_id, target, caller.as_deref(), false);
            let mut row = status_of(&receipt, target);
            class_note(&mut row, inline);
            Posted::Answered(Ok(row))
        }
        Err(e) if crate::mesh_retry::transient(&e, true) => {
            Posted::Queue { why: waiting_reason(&e), post: message }
        }
        Err(e) => Posted::Answered(Err(refusal(target, e))),
    }
}

/// The hub's message for a send to `target` (not a team address), the class it carries in its
/// text, and the session that sent it.
fn message(
    hub: &Arc<Hub>,
    conn: &Arc<Conn>,
    request: &Value,
    target: &str,
) -> Result<(OutMessage, Option<PromptClass>, Option<String>), RpcError> {
    let carried = carried(request, target)?;
    let caller = conn.caller().filter(|_| !conn.is_person());
    let message = OutMessage {
        to: recipient(target),
        from: sender(hub, caller, carried.named, carried.claim),
        kind: Kind::Prompt,
        op: None,
        body: carried.body,
        mode: carried.mode,
        idempotency_key: idempotency_key(&carried.prompt_id),
    };
    Ok((message, carried.inline, caller.map(str::to_owned)))
}

/// The outbox's record of a delivery the hub took for a peer that is down (`relay`).
fn relay_row(
    hub: &Arc<Hub>,
    delivery: &crate::hub::outbox::Delivery,
    message: &OutMessage,
    receipt: &Receipt,
) -> Value {
    // Its sender reads the hub's status of it, as a direct send's (`status`).
    let caller = delivery.caller.as_deref();
    hub.outbox.record_mesh_origin(&receipt.message_id, &delivery.target, caller, false);
    json!({
        "via": "mesh",
        "relayDeliveryId": format!("{PREFIX}{}", receipt.message_id),
        "promptId": receipt.prompt_id.as_deref().unwrap_or(&receipt.message_id),
        "sessionId": receipt.to.session_id.clone().or_else(|| message.to.session_id.clone()),
        "steer": message.mode == Mode::Now,
    })
}

/// What the relay carries of a `session/prompt` request: its text, its mode, its prompt id, the
/// display name it claims and the harness it says it came from.
struct Carried {
    body: String,
    /// The class written into `body`'s first line, which the hub's message cannot carry.
    inline: Option<PromptClass>,
    mode: Mode,
    prompt_id: String,
    named: Option<String>,
    claim: Option<Value>,
}

/// `request` as the relay carries it, or the refusal for what it cannot carry: an attachment or
/// `--supersede`. A class other than result goes as the text's first line.
fn carried(request: &Value, target: &str) -> Result<Carried, RpcError> {
    let mut texts: Vec<&str> = Vec::new();
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
    // Nor a class (`prompt_class.rs`): the hub's message has no field for it, so a block, a
    // question or an FYI goes with its class as the first line of the text the receiver reads
    // (`[question]`), and the sender's row says so (`classInline`). Before, it was refused, and
    // 0 of 9 sends of one batch went (cmuxterm-hq#17418).
    let inline = crate::prompt_class::declared(request)?.filter(|c| *c != PromptClass::Result);
    if let Some(class) = inline {
        texts.insert(0, class_line(class));
    }
    Ok(Carried {
        body: texts.join("\n\n"),
        inline,
        mode: if field("steer") == Some(&json!(true)) { Mode::Now } else { Mode::TurnEnd },
        prompt_id: field("promptId")
            .and_then(Value::as_str)
            .filter(|id| !id.is_empty())
            .map_or_else(|| uuid::Uuid::now_v7().to_string(), str::to_owned),
        named: field("fromAgent").and_then(Value::as_str).map(str::to_owned),
        // Sanitized, without what this daemon checked: the receiver keeps it as the sender's word.
        claim: field(crate::sender_harness::META_KEY).and_then(crate::sender_harness::sanitized),
    })
}

/// The first line a relayed message carries its class in: `[question]`.
fn class_line(class: PromptClass) -> &'static str {
    match class {
        PromptClass::Block => "[block]",
        PromptClass::Question => "[question]",
        PromptClass::Result => "[result]",
        PromptClass::Fyi => "[fyi]",
    }
}

/// What a sender's row says of a class the relay carried in the text (`carried`).
fn class_note(row: &mut Value, inline: Option<PromptClass>) {
    if let (Some(class), Some(row)) = (inline, row.as_object_mut()) {
        row.insert("classInline".into(), json!(class.as_str()));
        row.insert(
            "note".into(),
            json!(format!(
                "the mesh relay carries no class field: sent with {} as the text's first line",
                class_line(class)
            )),
        );
    }
}

/// The proven caller names the sender; `fromAgent` (anything a client writes) only when no
/// session is proven, as a display name. `claim` is provenance only, never the sender.
fn sender(hub: &Hub, caller: Option<&str>, named: Option<String>, claim: Option<Value>) -> Sender {
    Sender {
        name: caller.map(|id| hub.session_name(id)).or(named),
        session_id: caller.map(str::to_owned),
        host: Some(crate::pairing::mesh_host()),
        claim,
        ..Sender::default()
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
        super::team::authorize(hub, conn).await?;
        if !valid_team_address(target) {
            return Err(RpcError::invalid_params(
                "team address must be @member/agent or @team/role",
            )
            .with_data(json!({"reason": "team.invalid_address", "address": target})));
        }
    }
    let carried = carried(request, target)?;
    let inline = carried.inline;
    let caller = conn.caller().filter(|_| !conn.is_person());
    let message = OutMessage {
        to: recipient(target),
        from: sender(hub, caller, carried.named, carried.claim),
        kind: Kind::Prompt,
        op: None,
        body: carried.body,
        mode: carried.mode,
        idempotency_key: if target.starts_with('@') {
            super::team::sender_key(conn, &carried.prompt_id)?
        } else {
            idempotency_key(&carried.prompt_id)
        },
    };
    // The idempotency key makes a second post the same message, so a full rate window is waited
    // out (the hub's `retryAfterSeconds`) rather than failing the send.
    let receipt = crate::mesh_retry::retry_send(|| mesh.send(&message))
        .await
        .map_err(|e| refusal(target, e))?;
    if target.starts_with('@') {
        super::team::remember_sender(hub, conn, &receipt.message_id, target)?;
    } else {
        // Sent either way; unrecorded, its status is gated as a team message's (`status`).
        hub.outbox.record_mesh_origin(&receipt.message_id, target, caller, false);
    }
    let mut row = status_of(&receipt, target);
    class_note(&mut row, inline);
    Ok(row)
}

/// `_acpmux/send_status` of a delivery the hub holds: its receipt, read once.
pub(super) async fn status(
    hub: &Arc<Hub>,
    conn: &Arc<Conn>,
    mesh: &Arc<dyn MeshHub>,
    id: &str,
) -> Result<Value, RpcError> {
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
    let origin = hub.outbox.mesh_origin(message);
    let direct = origin.as_ref().filter(|d| !d.team_origin());
    if let Some(sent) = direct {
        // A direct `HOST/NAME` send's, which the hub stamps with `startWork` as it does every
        // message: its proven sender's, or the person's when no session sent it.
        if let Some(sender) = sent.caller.as_deref()
            && !conn.is_person()
            && conn.caller() != Some(sender)
        {
            return Err(RpcError::invalid_params(format!("{id} was sent by another session"))
                .with_data(json!({"reason": "mesh.not_sender", "deliveryId": id})));
        }
    } else if origin.is_some() || receipt.to.team_address.is_some() || receipt.start_work.is_some()
    {
        // Stored origin is authoritative even when resolution strips teamAddress/startWork.
        // Hub markers also protect receipts created before this daemon recorded their origin.
        super::team::authorize(hub, conn).await?;
        if !conn.is_person()
            && let Some(caller) = conn.caller()
        {
            let sent_here = origin.as_ref().is_some_and(|d| d.caller.as_deref() == Some(caller))
                || hub.sent_team_message(caller, message);
            // A resolved recipient session id is routing data, not sender authority.
            if !sent_here {
                return Err(super::team::forbidden());
            }
        }
    }
    let target =
        receipt.to.team_address.clone().or_else(|| origin.map(|d| d.target)).unwrap_or_else(|| {
            match (&receipt.to.host, &receipt.to.name) {
                (Some(host), Some(name)) => format!("{host}/{name}"),
                (_, name) => name.clone().unwrap_or_default(),
            }
        });
    Ok(status_of(&receipt, &target))
}

/// A receipt in the outbox's status shape (`hub/outbox.rs` `Delivery::status`). Its `promptId`
/// is the one the target runs it with: the hub's message id (`mesh_relay.rs` `deliver`).
fn status_of(receipt: &Receipt, target: &str) -> Value {
    let status = match receipt.state.as_str() {
        "leased" => "delivering",
        "delivered" => "delivered",
        "read" => "read",
        "acked" => "acked",
        "refused" | "expired" => "failed",
        _ => "queued",
    };
    let accepted = matches!(status, "delivered" | "read" | "acked")
        .then(|| json!({"promptId": receipt.prompt_id, "detail": receipt.detail}));
    let error = (status == "failed")
        .then(|| receipt.detail.clone().unwrap_or_else(|| receipt.state.clone()));
    let updated = receipt
        .acked_at
        .or(receipt.read_at)
        .or(receipt.delivered_at)
        .or(receipt.leased_until)
        .unwrap_or(receipt.created_at);
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
        _ => {
            let after = e.retry_after.map(|d| d.as_secs());
            let hint = after.map(|s| format!("; retry after {s}s")).unwrap_or_default();
            RpcError::internal(format!("the mesh hub did not take it: {e}{hint}")).with_data(
                json!({"reason": "mesh.unavailable", "retryable": true, "retryAfterSeconds": after}),
            )
        }
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
        && name.bytes().all(|b| b.is_ascii_alphanumeric() || b"._:-".contains(&b))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn host_and_a_session_id_name_that_session_by_id() {
        let id = "01a1acb2-5bb4-75a3-b5eb-a0eeea1d59d5";
        let to = recipient(&format!("machine-b/{id}"));
        assert_eq!(
            (to.session_id.as_deref(), to.name, to.host.as_deref()),
            (Some(id), None, Some("machine-b"))
        );
        let to = recipient("machine-b/own-e2e");
        assert_eq!((to.name.as_deref(), to.session_id), (Some("own-e2e"), None));
    }

    /// cmuxterm-hq#17418: `class: question` to 9 sessions reached only through the relay sent 0
    /// of 9 ("cannot carry --class"). The class now goes as the text's first line, the sender's
    /// row says so, and a send with no class (or result) is the text it always was.
    #[test]
    fn a_class_the_relay_cannot_carry_goes_as_the_first_line() {
        let request = |class: Option<&str>| {
            json!({"sessionId": "host-b/lane-a", "prompt": [{"type": "text", "text": "ship it?"}],
                "_meta": {"acpmux": {"class": class, "promptId": "0190f2a4-7c1e-7d3a-9f00-0123456789ab"}}})
        };
        let sent = carried(&request(Some("question")), "host-b/lane-a").unwrap();
        assert_eq!(sent.body, "[question]\n\nship it?");
        assert_eq!(sent.inline, Some(PromptClass::Question));
        let sent = carried(&request(Some("blocker")), "host-b/lane-a").unwrap();
        assert!(sent.body.starts_with("[block]\n\n"), "{}", sent.body);
        for class in [None, Some("result"), Some("action")] {
            let sent = carried(&request(class), "host-b/lane-a").unwrap();
            assert_eq!((sent.body.as_str(), sent.inline), ("ship it?", None), "{class:?}");
        }
        let mut row = json!({"status": "queued"});
        class_note(&mut row, Some(PromptClass::Question));
        assert_eq!(row["classInline"], "question");
        assert!(row["note"].as_str().unwrap().contains("[question]"), "{row}");
        // What it still cannot carry is still refused, by name.
        let mut attach = request(None);
        attach["prompt"] = json!([{"type": "image", "data": "x"}]);
        assert!(carried(&attach, "host-b/lane-a").is_err());
    }

    /// The census of 2026-11-23 (cmuxterm-hq docs/findings/2026-11-23-mcp-tool-error-census.md)
    /// replayed: its sends refused by the relay, 29 with a class and 3 with a supersede key.
    /// Prints how many still bounce; the same test on the code before gives the before number.
    #[test]
    fn census_replay_mesh_relay() {
        let request = |key: &str, value: &str| {
            json!({"sessionId": "host-b/lane-a", "prompt": [{"type": "text", "text": "t"}],
                "_meta": {"acpmux": {key: value}}})
        };
        let (mut n, mut bad) = (0, 0);
        for (sent, weight) in [(request("class", "question"), 29), (request("supersede", "s"), 3)] {
            n += weight;
            bad += if carried(&sent, "host-b/lane-a").is_err() { weight } else { 0 };
        }
        eprintln!("census replay: send (mesh relay): {bad} of {n} bounce");
    }

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
        assert!(valid_team_address("@member/reviewer:backend"));
        assert!(!valid_team_address("@team"));
    }
}
