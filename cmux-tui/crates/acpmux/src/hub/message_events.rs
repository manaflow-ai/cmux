//! Durable message projections, repaired from accepted prompt records after a restart.

use super::*;
use cmux_json::JsonSet as _;

#[derive(Clone)]
pub(super) struct MessageContext {
    sender: Value,
    sender_session: String,
    text: String,
    message_id: String,
    at: u64,
    /// A peer daemon owns the sender-side journal copy. Its forwarded metadata
    /// is for the receiver projection only, even if the ids happen to resolve
    /// locally after a move.
    record_sender_copy: bool,
}

// Internal durable copy of a message projection. A prompt's in-memory provenance carries it;
// its queued/user_message records keep it beside their provenance (`prompt_provenance::marked`),
// so a daemon restart can recover a projection even if it crashed after writing the prompt
// record but before the acceptance callback ran.
use crate::prompt_provenance::MESSAGE_META;

/// `receiver` is the session the copy is for: a fork inherits the record, and recovery there
/// must not take it for the fork's own delivery (`addressed_elsewhere`).
pub(super) fn embed_message_context(
    opts: &mut PromptOptions,
    message: Option<&MessageContext>,
    receiver: &str,
) {
    let forwarder =
        opts.provenance.as_ref().and_then(|p| crate::prompt_provenance::sender_of(Some(p)).0);
    let Some(provenance) = opts.provenance.as_mut() else { return };
    let Some(object) = provenance.as_object_mut() else { return };
    object.remove(MESSAGE_META);
    let Some(message) = message else { return };
    let mut context = json!({
        "sender": message.sender.clone(),
        "text": message.text.clone(),
        "messageId": message.message_id.clone(),
        "recordSenderCopy": message.record_sender_copy,
        "at": message.at,
        "receiverId": receiver,
    });
    if let Some(forwarder) = forwarder.filter(|id| id != &message.sender_session) {
        context.set("forwardedBy", json!({"session": forwarder}));
    }
    object.insert(MESSAGE_META.to_owned(), context);
}

fn resolve_exact(hub: &Hub, id: &str) -> Option<Arc<Session>> {
    hub.sessions.lock().unwrap_or_else(|e| e.into_inner()).get(id).cloned()
}

pub(super) fn message_context_from_provenance(provenance: &Value) -> Option<MessageContext> {
    let object = provenance.get(MESSAGE_META)?.as_object()?;
    let sender = object.get("sender")?.clone();
    let sender_object = sender.as_object()?;
    let sender_session = sender_object.get("sessionId")?.as_str()?.to_owned();
    let text = object.get("text")?.as_str()?.to_owned();
    let message_id = object.get("messageId")?.as_str()?.to_owned();
    let at = object.get("at").and_then(Value::as_u64).unwrap_or_else(crate::store::now_ms);
    Some(MessageContext {
        sender,
        sender_session,
        text,
        message_id,
        at,
        record_sender_copy: object
            .get("recordSenderCopy")
            .and_then(Value::as_bool)
            .unwrap_or(false),
    })
}

/// Restore delivery metadata from a durable queued or held prompt.
///
/// Callers pass either provenance already normalized by `message_context` before queueing, or a
/// persisted prompt record. Raw RPC metadata must go through `message_context`, which validates
/// the sender and chooses the current id.
pub(super) fn restore_message_options(opts: &mut PromptOptions, provenance: Option<&Value>) {
    let Some(message) = provenance.and_then(message_context_from_provenance) else { return };
    if opts.message_id.is_none() {
        opts.message_id = Some(message.message_id);
    }
    if !message.record_sender_copy && opts.message_sender.is_none() {
        opts.message_sender = Some(message.sender);
    }
}

/// Rebuild message projections that were not appended before a daemon stopped
/// after persisting a prompt or queue record. The append path deduplicates by
/// `messageId` and the outgoing target scope, so this is safe on every log load.
pub(super) fn recover_message_events(hub: &Arc<Hub>, session: &Arc<Session>) {
    recover_message_events_after(hub, session, 0);
}

/// [`recover_message_events`] of the records past `after`, a restore point's seq: every copy of
/// a message before it was written (`restore_point.rs`). Returns whether every copy is written
/// now, none left for a later repair.
pub(super) fn recover_message_events_after(
    hub: &Arc<Hub>,
    session: &Arc<Session>,
    after: u64,
) -> bool {
    let mut pending = Vec::new();
    // A fork copies historical `user_message` records before its `forked` marker. Those records
    // describe the parent's delivery and must never recreate a sender-side copy in the child.
    // Stay conservative if a crash left no marker: skip the inherited prefix entirely.
    let mut inherited = session.meta().fork_seq.is_some();
    let scanned = hub.store.scan_kinds_after(
        &session.id,
        after,
        &["queued", "user_message", "inbox", "forked"],
        &mut |record| {
            if inherited {
                if record.kind == "forked" {
                    inherited = false;
                }
                return true;
            }
            // An inbox message (`inbox.rs`) is accepted as a queued one is, under its own kind.
            if !matches!(record.kind.as_str(), "queued" | "user_message" | "inbox") {
                return true;
            }
            let Some(provenance) = crate::prompt_provenance::recorded(&record.msg) else {
                return true;
            };
            collect_message_contexts(&provenance, &session.id, &mut pending);
            true
        },
    );
    let mut written = scanned.is_ok();
    for message in pending {
        written &= append_or_repair(hub, &session.id, &message, None);
        if message.record_sender_copy && message.sender_session != session.id {
            written &= append_or_repair(hub, &message.sender_session, &message, Some(&session.id));
        }
    }
    written
}

/// A digest user message carries each joined prompt's original provenance one level down. Keep
/// recovery aligned with the live acceptance path, which records every joined message separately.
/// A record addressed to another session (`to`) is inherited, by a fork that lost its marker
/// (an import drops `forkSeq`): it was that session's delivery, never this one's.
fn collect_message_contexts(
    provenance: &Value,
    session_id: &str,
    pending: &mut Vec<MessageContext>,
) {
    if addressed_elsewhere(provenance, session_id) {
        return;
    }
    if let Some(message) = message_context_from_provenance(provenance) {
        pending.push(message);
    }
    if let Some(messages) = provenance.get("messages").and_then(Value::as_array) {
        for message in messages {
            if let Some(nested) = message.get("provenance") {
                collect_message_contexts(nested, session_id, pending);
            }
        }
    }
}

/// The record was another session's delivery: its message copy names another receiver, or its
/// provenance's `to` names another session by id (a name is not checked: names change).
fn addressed_elsewhere(provenance: &Value, session_id: &str) -> bool {
    if let Some(receiver) =
        provenance.pointer(&format!("/{MESSAGE_META}/receiverId")).and_then(Value::as_str)
    {
        return receiver != session_id;
    }
    let Some(to) = provenance.get("to").and_then(Value::as_str) else { return false };
    let to = to.strip_prefix("acp:").unwrap_or(to);
    to != session_id && uuid::Uuid::parse_str(to).is_ok()
}

/// A locally derived sender names a session: `acp:<id>`, a session id, or a session here. A
/// person's or terminal's `from` (`cli`, `term_1234`) names none.
fn names_a_session(hub: &Hub, from: &str) -> bool {
    from.starts_with("acp:")
        || uuid::Uuid::parse_str(from).is_ok()
        || resolve_exact(hub, from).is_some()
}

pub(super) fn message_context(
    hub: &Hub,
    _session: &Session,
    blocks: &[Value],
    opts: &PromptOptions,
    prompt_id: &str,
) -> Option<MessageContext> {
    // A person's multiplayer author also carries from/fromName. It is not a
    // session sender and must never gain a session-to-session journal copy.
    if crate::author::of_provenance(opts.provenance.as_ref()).is_some() {
        return None;
    }
    let raw = opts.message_sender.as_ref().or(opts.provenance.as_ref())?;
    let object = raw.as_object()?;
    if opts.message_sender.is_none()
        && object.get("sessionId").is_none()
        && !object
            .get("from")
            .and_then(Value::as_str)
            .is_some_and(|from| names_a_session(hub, from))
    {
        return None;
    }
    let mut sender_session = object.get("sessionId").and_then(Value::as_str).map(str::to_owned);
    let name = object
        .get("name")
        .and_then(Value::as_str)
        .or_else(|| object.get("fromName").and_then(Value::as_str))
        .or(opts.agent.as_deref())
        .map(str::to_owned)
        .or_else(|| {
            let from = object.get("from").and_then(Value::as_str)?;
            let id = from.strip_prefix("acp:").unwrap_or(from);
            sender_session = Some(id.to_owned());
            Some(hub.session_name(id))
        })?;
    let sender_session = sender_session.or_else(|| {
        object
            .get("from")
            .and_then(Value::as_str)
            .map(|id| id.strip_prefix("acp:").unwrap_or(id).to_owned())
    })?;
    // A display-only --from name has no session identity. Its ordinary prompt
    // provenance remains visible, but it cannot name a session journal copy.
    if sender_session == crate::prompt_provenance::NAMED_SENDER
        || sender_session.is_empty()
        || name.is_empty()
    {
        return None;
    }
    let mut sender = if let Some(sender) = opts.message_sender.as_ref() {
        sender.clone()
    } else {
        json!({"name": name, "sessionId": sender_session, "host": host_label()})
    };
    if let Some(label) = crate::prompt_provenance::declared_label(opts.provenance.as_ref()) {
        sender.set("label", json!(label));
    }
    let message_id = opts
        .message_id
        .clone()
        .or_else(|| object.get("msgId").and_then(Value::as_str).map(str::to_owned))
        .unwrap_or_else(|| prompt_id.to_owned());
    Some(MessageContext {
        sender,
        sender_session,
        text: prompt_text(blocks),
        message_id,
        at: crate::store::now_ms(),
        record_sender_copy: opts.message_sender.is_none(),
    })
}

/// Remembers which message `prompt_id`'s acceptance named on `session` (`Session::kept_messages`).
pub(super) fn keep_message(session: &Session, prompt_id: &str, message: &MessageContext) {
    let mut kept = session.kept_messages.lock().unwrap_or_else(|e| e.into_inner());
    kept.retain(|(id, _, _)| id != prompt_id);
    kept.push_back((
        prompt_id.to_owned(),
        message.message_id.clone(),
        message.sender_session.clone(),
    ));
    while kept.len() > super::session::KEPT_MESSAGES {
        kept.pop_front();
    }
}

/// Names on a duplicate's acceptance the message `prompt_id`'s first acceptance named, when the
/// session still remembers it: a direct send that came after its `send_queue` copy was accepted
/// hears the kept message, as the first send did (`server/peer_forward.rs` `kept_another`).
pub(super) fn name_kept_message(accepted: &mut Value, session: &Session, prompt_id: &str) {
    let kept = session.kept_messages.lock().unwrap_or_else(|e| e.into_inner());
    let Some((_, message_id, sender)) = kept.iter().rev().find(|(id, _, _)| id == prompt_id) else {
        return;
    };
    if let Some(fields) = accepted.as_object_mut() {
        fields.insert("messageId".to_owned(), Value::String(message_id.clone()));
        fields.insert("messageSenderId".to_owned(), Value::String(sender.clone()));
    }
}

/// The acceptance `_acpmux/prompt_accepted` carries names the message this journal kept and its
/// sender's session, so a peer forwarding the prompt records its sender's copy only for that
/// message: every send of one prompt id to one chat (a direct send and its `send_queue` retry,
/// or two sessions' sends) hears the one acceptance (`server/peer_forward.rs`).
pub(super) fn name_message(accepted: &mut Value, message: &MessageContext) {
    if let Some(fields) = accepted.as_object_mut() {
        fields.insert("messageId".to_owned(), Value::String(message.message_id.clone()));
        fields.insert("messageSenderId".to_owned(), Value::String(message.sender_session.clone()));
    }
}

pub(super) fn ensure_message_provenance(opts: &mut PromptOptions, target_id: &str) {
    // A peer's message names its sender here: it takes the place of an `unverified` mark.
    if opts.provenance.is_some()
        && !crate::prompt_provenance::is_unverified(opts.provenance.as_ref())
    {
        return;
    }
    let Some(sender) = opts.message_sender.as_ref().and_then(Value::as_object) else { return };
    let Some(id) = sender.get("sessionId").and_then(Value::as_str) else { return };
    let Some(name) = sender.get("name").and_then(Value::as_str) else { return };
    let mut provenance = crate::prompt_provenance::named_sender(name, target_id);
    provenance.set("sessionId", json!(id));
    // It keeps how it came and who passed it on, as the daemon saw them.
    for key in [crate::prompt_provenance::TRANSPORT, crate::prompt_provenance::FORWARDED_BY] {
        if let Some(value) = opts.provenance.as_ref().and_then(|p| p.get(key)) {
            provenance.set(key, value.clone());
        }
    }
    if let Some(label) = sender.get("label").and_then(Value::as_str) {
        provenance = crate::prompt_provenance::stamp_declared(provenance, Some(label));
    }
    opts.provenance = Some(provenance);
}

pub(super) fn record_message_context(
    hub: &Arc<Hub>,
    target_session: &str,
    message: &MessageContext,
) {
    append_or_repair(hub, target_session, message, None);
    if message.record_sender_copy && message.sender_session != target_session {
        append_or_repair(hub, &message.sender_session, message, Some(target_session));
    }
}

/// Whether the copy is written now (or has no chat to go to); false while a repair or the
/// store's load still holds it.
fn append_or_repair(
    hub: &Arc<Hub>,
    session_id: &str,
    message: &MessageContext,
    target_scope: Option<&str>,
) -> bool {
    let session = match resolve_exact(hub, session_id) {
        Some(session) => session,
        // The load may have installed it since the lookup: once loaded, a second lookup is the
        // answer.
        None if hub.store_loaded() => match resolve_exact(hub, session_id) {
            Some(session) => session,
            None => return true,
        },
        None => {
            append_once_loaded(hub, session_id, message, target_scope);
            return false;
        }
    };
    if !hub.append_message_event_scoped(
        &session,
        message.sender.clone(),
        message.text.clone(),
        message.message_id.clone(),
        message.at,
        target_scope,
        None,
    ) {
        schedule_projection_repair(hub, session_id, message, target_scope);
        return false;
    }
    true
}

/// A session not installed yet while the saved sessions still load (a lazy `session/load` of
/// the receiver recovers its messages before the load reaches their sender): its copy is
/// appended once it is read on demand, or once the load ends. A session still unknown then is
/// gone, and keeps no copy.
fn append_once_loaded(
    hub: &Arc<Hub>,
    session_id: &str,
    message: &MessageContext,
    target_scope: Option<&str>,
) {
    if tokio::runtime::Handle::try_current().is_err() {
        return;
    }
    let owner = hub.clone();
    let (hub, id, message) = (hub.clone(), session_id.to_owned(), message.clone());
    let target_scope = target_scope.map(str::to_owned);
    owner.scope.spawn_until_cancelled("message-projection", async move {
        hub.session_meta(&id).await;
        if resolve_exact(&hub, &id).is_some() {
            append_or_repair(&hub, &id, &message, target_scope.as_deref());
        }
    });
}

fn schedule_projection_repair(
    hub: &Arc<Hub>,
    session_id: &str,
    message: &MessageContext,
    target_scope: Option<&str>,
) {
    if tokio::runtime::Handle::try_current().is_err() {
        return;
    }
    let key =
        (session_id.to_owned(), format!("{}\0{}", target_scope.unwrap_or(""), message.message_id));
    let inserted =
        hub.message_repairs.lock().unwrap_or_else(|e| e.into_inner()).insert(key.clone());
    if !inserted {
        return;
    }
    let sender = message.sender.clone();
    let text = message.text.clone();
    let message_id = message.message_id.clone();
    let at = message.at;
    let hub = hub.clone();
    let target_scope = target_scope.map(str::to_owned);
    let guard = ProjectionRepairGuard { hub: hub.clone(), key: key.clone() };
    let owner = hub.clone();
    owner.scope.spawn_until_cancelled("message-projection-repair", async move {
        // Constructed before spawning so cancellation before the future is first polled still
        // removes the in-flight key.
        let _guard = guard;
        for delay in super::outbox::RETRY_DELAYS_SECS {
            tokio::time::sleep(std::time::Duration::from_secs(*delay)).await;
            let Some(session) = resolve_exact(&hub, &key.0) else { return };
            if hub.append_message_event_scoped(
                &session,
                sender.clone(),
                text.clone(),
                message_id.clone(),
                at,
                target_scope.as_deref(),
                None,
            ) {
                return;
            }
        }
    });
}

struct ProjectionRepairGuard {
    hub: Arc<Hub>,
    key: (String, String),
}

impl Drop for ProjectionRepairGuard {
    fn drop(&mut self) {
        self.hub
            .message_repairs
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .remove(&(self.key.0.clone(), self.key.1.clone()));
    }
}

#[cfg(test)]
mod message_recovery_tests;
