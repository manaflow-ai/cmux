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

/// Whom `target` names at the hub, as [`recipient`] says, but a chat the hub lists by its
/// handle (`HOST/Mango`, `Mango`) by its machine and id: the hub matches names only, and a
/// handle is no name there (`Hub::mesh_book_handle`).
fn recipient_in(hub: &Hub, target: &str) -> Target {
    if !target.starts_with('@')
        && let Some((host, id)) = hub.mesh_book_handle(target)
    {
        return Target { session_id: Some(id), host: Some(host), ..Target::default() };
    }
    recipient(target)
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
            // A peer that is down, or a machine only the hub reaches (a chat that moved there
            // over the hub, followed to `HOST/ID`: `Hub::mesh_only_host`).
            let to = down_peer_recipient(hub, &delivery.target).or_else(|| {
                hub.mesh_only_host(&delivery.target).then(|| recipient_in(hub, &delivery.target))
            })?;
            let carried = carried(&delivery.request, &delivery.target).ok()?;
            // A class or supersede key goes to the peer itself once it is back, where the
            // receiver reads it as one, rather than as a line of the text (or dropped) now.
            if carried.inline.is_some() || carried.dropped_supersede {
                return None;
            }
            // Not asked while its gate is shut: nothing is posted, so the peer's link may still
            // take it (`relay_attempt`).
            if !hub.mesh.gate().may_try() {
                return Some(Err(backing_off(true)));
            }
            let message = OutMessage {
                to,
                // The outbox takes only this machine's unix socket (`outbox::handle`), so a
                // delivery with no caller is a relay's there, as `relay_of` reads it.
                from: sender(
                    hub,
                    delivery.caller.as_deref(),
                    carried.named,
                    carried.claim,
                    delivery.caller.is_none().then(|| relay_of(&delivery.request)).flatten(),
                ),
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
    // No post of it at the hub so far (a first post, or every earlier one failed before it left):
    // saved as maybe posted before this one goes, so a crash mid-post never leaves a record that
    // lets a direct copy go too (`Delivery::relay_unreached`). Marked unreached again only when
    // this post provably never left either.
    let saved_unreached = hub.outbox.get(&delivery.id).is_some_and(|d| d.relay_unreached);
    let unreached_so_far = delivery.relay_post.is_none() || saved_unreached;
    if saved_unreached && !hub.outbox.update_saved(&delivery.id, |d| d.relay_unreached = false) {
        return Some(Err(HubError::local("the outbox could not be saved; not posted")));
    }
    let posted = tokio::time::timeout(RELAY_WAIT, mesh.send(&message)).await.unwrap_or_else(|_| {
        Err(HubError::unavailable(format!("no answer within {}s", RELAY_WAIT.as_secs())))
    });
    note(hub, &posted);
    if unreached_so_far && matches!(&posted, Err(e) if e.never_reached()) {
        hub.outbox.update(&delivery.id, |d| d.relay_unreached = true);
    }
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
    // Not asked: this attempt sent nothing (an earlier one may have: `Delivery::relay_unreached`).
    e.unsent = true;
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
#[allow(clippy::large_enum_variant)] // built once per send and matched at once; boxing buys nothing
pub(super) enum Posted {
    /// The hub took it, or refused it: the answer as it is.
    Answered(Result<Value, RpcError>),
    /// The hub did not take it in a way that passes (a 5xx, a 429, no answer within
    /// [`INLINE_WAIT`], no connection), or its gate is shut: kept in the outbox with this post,
    /// which its retry sends again under the same key, and why it waits. `unreached`: the hub
    /// provably holds no copy (its gate kept it from asking, or no connection was made), so a
    /// direct copy may go to its machine (`Delivery::relay_unreached`, `mesh_direct.rs`).
    Queue { post: OutMessage, why: String, unreached: bool },
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
    let (message, (inline, dropped), caller) = match message(hub, conn, request, target) {
        Ok(made) => made,
        Err(e) => return Posted::Answered(Err(e)),
    };
    if !hub.mesh.gate().may_try() {
        let why = "hub failing, retrying (backing off before it is asked again)".to_owned();
        return Posted::Queue { post: message, why, unreached: true };
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
            class_note(&mut row, inline, dropped);
            Posted::Answered(Ok(row))
        }
        Err(e) if crate::mesh_retry::transient(&e, true) => {
            Posted::Queue { why: waiting_reason(&e), post: message, unreached: e.never_reached() }
        }
        Err(e) => Posted::Answered(Err(refusal(target, e))),
    }
}

/// The hub's message for a send to `target` (not a team address), the class it carries in its
/// text and whether it dropped a supersede key, and the session that sent it.
fn message(
    hub: &Arc<Hub>,
    conn: &Arc<Conn>,
    request: &Value,
    target: &str,
) -> Result<(OutMessage, (Option<PromptClass>, bool), Option<String>), RpcError> {
    let carried = carried(request, target)?;
    let caller = conn.caller().filter(|_| !conn.is_person());
    let message = OutMessage {
        to: recipient_in(hub, target),
        from: sender(hub, caller, carried.named, carried.claim, local_relay(conn, request)),
        kind: Kind::Prompt,
        op: None,
        body: carried.body,
        mode: carried.mode,
        idempotency_key: idempotency_key(&carried.prompt_id),
    };
    let said = (carried.inline, carried.dropped_supersede);
    Ok((message, said, caller.map(str::to_owned)))
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
    /// The request named a `supersede` key, which the hub's message cannot carry: sent without it.
    dropped_supersede: bool,
    mode: Mode,
    prompt_id: String,
    named: Option<String>,
    claim: Option<Value>,
}

/// `request` as the relay carries it, or the refusal for what it cannot carry: an attachment. A
/// class other than result goes as the text's first line, and a `--supersede` key is dropped.
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
    // The hub's message carries no supersede key, so the target cannot replace the earlier
    // prompt. The message goes without it and the sender's row says so (`class_note`): a
    // refusal here bounced every such send, and the sender's next move was always to send it
    // again without the key (cmuxterm-hq docs/findings/2026-11-23-mcp-tool-error-census.md).
    let dropped_supersede = field("supersede").is_some_and(|k| !k.is_null());
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
        dropped_supersede,
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
pub(super) fn class_line(class: PromptClass) -> &'static str {
    match class {
        PromptClass::Block => "[block]",
        PromptClass::Question => "[question]",
        PromptClass::Result => "[result]",
        PromptClass::Fyi => "[fyi]",
    }
}

/// What a sender's row says of a class the relay carried in the text, and of a supersede key it
/// dropped (`carried`).
fn class_note(row: &mut Value, inline: Option<PromptClass>, dropped_supersede: bool) {
    let Some(row) = row.as_object_mut() else { return };
    let mut notes = Vec::new();
    if let Some(class) = inline {
        row.insert("classInline".into(), json!(class.as_str()));
        notes.push(format!(
            "the mesh relay carries no class field: sent with {} as the text's first line, which the receiving daemon files it by",
            class_line(class)
        ));
    }
    if dropped_supersede {
        row.insert("supersedeDropped".into(), json!(true));
        notes.push(
            "the mesh relay carries no supersede key: sent without it, so an earlier message it would have replaced stays"
                .to_owned(),
        );
    }
    if !notes.is_empty() {
        row.insert("note".into(), json!(notes.join("; ")));
    }
}

/// The proven caller names the sender; `fromAgent` (anything a client writes) only when no
/// session is proven, as a display name. `claim` is provenance only, never the sender. `relay` is
/// the relay record of a send no session made, which goes only when no caller is proven.
fn sender(
    hub: &Hub,
    caller: Option<&str>,
    named: Option<String>,
    claim: Option<Value>,
    relay: Option<Value>,
) -> Sender {
    // A program outside any session (`ACPMUX_FROM=glaeda-land`) with no relay of its own is its
    // own relay: the record names it, so a receiver reads "glaeda-land on HOST", not the machine.
    let relay = match caller {
        Some(_) => None,
        None => relay.or_else(|| program_relay(named.as_deref())),
    };
    Sender {
        name: caller.map(|id| hub.session_name(id)).or(named),
        session_id: caller.map(str::to_owned),
        host: Some(crate::pairing::mesh_host()),
        claim,
        relay,
        ..Sender::default()
    }
}

/// The relay record naming a program outside any session by its declared name on this machine,
/// or None when the name is no one relay name ([`RelaySender::of`] decides).
fn program_relay(named: Option<&str>) -> Option<Value> {
    let by = named?.trim();
    let machine = crate::pairing::mesh_host();
    crate::prompt_provenance::RelaySender::of(&json!({"by": by, "machine": machine}))
        .map(|r| r.to_value())
}

/// The relay record (`prompt_provenance::FROM_RELAY`) of a send a relay on this machine's unix
/// socket made outside any session (the lane-gh broker's `acpmux send`), read as the peer link
/// reads it (`peer_forward::name_sender`): only well-formed fields, from no proven caller.
fn local_relay(conn: &Conn, request: &Value) -> Option<Value> {
    (conn.origin == super::Origin::Local && conn.caller().is_none())
        .then(|| relay_of(request))
        .flatten()
}

/// `request`'s relay record, well formed, as the hub's message carries it (`Sender::relay`).
fn relay_of(request: &Value) -> Option<Value> {
    crate::prompt_provenance::relay_sender(request)?.relay.map(|r| r.to_value())
}

pub(super) async fn send(
    hub: &Arc<Hub>,
    conn: &Arc<Conn>,
    mesh: Option<&Arc<dyn MeshHub>>,
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
    let (inline, dropped) = (carried.inline, carried.dropped_supersede);
    let caller = conn.caller().filter(|_| !conn.is_person());
    let message = OutMessage {
        to: recipient_in(hub, target),
        from: sender(hub, caller, carried.named, carried.claim, local_relay(conn, request)),
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
    let receipt = if target.starts_with('@') {
        super::team::submit(hub, conn, mesh, message, target).await?
    } else {
        let mesh = mesh.ok_or_else(|| RpcError::internal("the mesh relay is not configured"))?;
        let receipt = crate::mesh_retry::retry_send(|| mesh.send(&message))
            .await
            .map_err(|e| refusal(target, e))?;
        hub.outbox.record_mesh_origin(&receipt.message_id, target, caller, false);
        receipt
    };
    let mut row = status_of(&receipt, target);
    class_note(&mut row, inline, dropped);
    Ok(row)
}

/// `_acpmux/send_status` of a delivery the hub holds: its receipt, read once.
pub(super) async fn status(
    hub: &Arc<Hub>,
    conn: &Arc<Conn>,
    mesh: &Arc<dyn MeshHub>,
    id: &str,
) -> Result<Value, RpcError> {
    // A queued team send has a local durable id until the hub accepts it. Once replayed, the
    // queue keeps an alias from that id to the hub's message id so callers can keep polling the
    // receipt they already received, including after a daemon restart.
    if let Some((queued, target, caller)) = hub.team_send_queue.lookup(id).await {
        super::team::authorize(hub, conn).await?;
        if !conn.is_person()
            && let Some(sender) = conn.caller()
            && Some(sender) != caller.as_deref()
        {
            return Err(super::team::forbidden());
        }
        if queued.message_id.starts_with("teamq:") {
            return Ok(status_of(&queued, &target));
        }
        match mesh.receipt(&queued.message_id).await {
            Ok(receipt) => {
                return Ok(status_of(
                    &receipt,
                    receipt.to.team_address.as_deref().unwrap_or(&target),
                ));
            }
            Err(error) if error.refused => return Ok(status_of(&queued, &target)),
            Err(error) => {
                return Err(RpcError::internal(format!(
                    "the mesh hub did not answer for {id}: {error}"
                ))
                .with_data(
                    json!({"reason": "mesh.unavailable", "retryable": true, "deliveryId": id}),
                ));
            }
        }
    }
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

/// Status for a queued id when reconnect has not supplied a mesh client yet.
pub(super) async fn queued_status(
    hub: &Arc<Hub>,
    conn: &Arc<Conn>,
    id: &str,
) -> Result<Value, RpcError> {
    let Some((receipt, target, caller)) = hub.team_send_queue.lookup(id).await else {
        return Err(RpcError::invalid_params(format!("no delivery {id}"))
            .with_data(json!({"reason": "outbox.unknown", "deliveryId": id})));
    };
    super::team::authorize(hub, conn).await?;
    if !conn.is_person()
        && let Some(sender) = conn.caller()
        && Some(sender) != caller.as_deref()
    {
        return Err(super::team::forbidden());
    }
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
#[path = "mesh_send_tests.rs"]
mod tests;
