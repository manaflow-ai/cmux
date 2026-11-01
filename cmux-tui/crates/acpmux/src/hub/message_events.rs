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
    let Some(provenance) = opts.provenance.as_mut() else { return };
    let Some(object) = provenance.as_object_mut() else { return };
    object.remove(MESSAGE_META);
    let Some(message) = message else { return };
    object.insert(
        MESSAGE_META.to_owned(),
        json!({
            "sender": message.sender.clone(),
            "text": message.text.clone(),
            "messageId": message.message_id.clone(),
            "recordSenderCopy": message.record_sender_copy,
            "at": message.at,
            "receiverId": receiver,
        }),
    );
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
    let mut pending = Vec::new();
    // A fork copies historical `user_message` records before its `forked` marker. Those records
    // describe the parent's delivery and must never recreate a sender-side copy in the child.
    // Stay conservative if a crash left no marker: skip the inherited prefix entirely.
    let mut inherited = session.meta().fork_seq.is_some();
    let _ = hub.store.scan_kinds(
        &session.id,
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
    for message in pending {
        append_or_repair(hub, &session.id, &message, None);
        if message.record_sender_copy && message.sender_session != session.id {
            append_or_repair(hub, &message.sender_session, &message, Some(&session.id));
        }
    }
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
    let sender = if let Some(sender) = opts.message_sender.as_ref() {
        sender.clone()
    } else {
        json!({"name": name, "sessionId": sender_session, "host": host_label()})
    };
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

/// The acceptance `_acpmux/prompt_accepted` carries names the message this journal kept and its
/// sender's session, so a peer forwarding the prompt records its sender's copy only for that
/// message: every send of one prompt id to one chat (a direct send and its `send_queue` retry,
/// or two sessions' sends) hears the one acceptance (`server/peer_forward.rs`).
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

pub(super) fn name_message(accepted: &mut Value, message: &MessageContext) {
    if let Some(fields) = accepted.as_object_mut() {
        fields.insert("messageId".to_owned(), Value::String(message.message_id.clone()));
        fields.insert("messageSenderId".to_owned(), Value::String(message.sender_session.clone()));
    }
}

pub(super) fn ensure_message_provenance(opts: &mut PromptOptions, target_id: &str) {
    if opts.provenance.is_some() {
        return;
    }
    let Some(sender) = opts.message_sender.as_ref().and_then(Value::as_object) else { return };
    let Some(id) = sender.get("sessionId").and_then(Value::as_str) else { return };
    let Some(name) = sender.get("name").and_then(Value::as_str) else { return };
    let mut provenance = crate::prompt_provenance::named_sender(name, target_id);
    provenance.set("sessionId", json!(id));
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

fn append_or_repair(
    hub: &Arc<Hub>,
    session_id: &str,
    message: &MessageContext,
    target_scope: Option<&str>,
) {
    let session = match resolve_exact(hub, session_id) {
        Some(session) => session,
        // The load may have installed it since the lookup: once loaded, a second lookup is the
        // answer.
        None if hub.store_loaded() => match resolve_exact(hub, session_id) {
            Some(session) => session,
            None => return,
        },
        None => {
            append_once_loaded(hub, session_id, message, target_scope);
            return;
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
    }
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
    let (hub, id, message) = (hub.clone(), session_id.to_owned(), message.clone());
    let target_scope = target_scope.map(str::to_owned);
    tokio::spawn(async move {
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
    tokio::spawn(async move {
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
mod message_recovery_tests {
    use super::*;
    use crate::config::{Config, PermissionPolicy, StoreMode};
    use crate::hub::NewRequest;
    use serde_json::json;
    use std::path::Path;

    fn message_count(hub: &Hub, id: &str) -> usize {
        let filter = EventFilter::parse(None).expect("event filter");
        hub.events_page(id, 0, None, 500, None, false, &filter)
            .expect("event page")
            .events
            .into_iter()
            .filter(|record| record.kind == "_acpmux/message")
            .count()
    }

    /// A queued prompt can be durable before its acceptance callback runs. A
    /// later log load reconstructs both projections and remains idempotent.
    #[tokio::test]
    async fn queued_message_recovery_rebuilds_both_journals_once() {
        let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
        let mut config: Config = serde_json::from_value(json!({
            "harnesses": {"fake": {"argv": ["python3", fake]}},
            "defaultHarness": "fake",
            "permissionPolicy": "approve-all"
        }))
        .expect("config");
        config.store.mode = StoreMode::Memory;
        let store = crate::store::open(&config.store, Path::new("/nonexistent")).expect("store");
        let hub = Hub::new(config, store);
        let make = |name: &str| NewRequest {
            harness: Some("fake".into()),
            name: Some(name.into()),
            cwd: Some(std::env::temp_dir()),
            policy: Some(PermissionPolicy::ApproveAll),
            ..NewRequest::default()
        };
        let sender = hub.new_session(make("sender")).await.expect("sender");
        let receiver = hub.new_session(make("receiver")).await.expect("receiver");
        let sender_id = sender.id.clone();
        let receiver_id = receiver.id.clone();
        let provenance = json!({
            "kind": "session_message",
            "from": sender_id,
            "fromName": "sender",
            "to": receiver_id,
            "_acpmuxMessage": {
                "sender": {"name": "sender", "sessionId": sender.id, "host": "local"},
                "text": "queued hello",
                "messageId": "delivery-1",
                "at": 1234,
                "recordSenderCopy": true
            }
        });
        hub.append(
            &receiver,
            "mux",
            "queued",
            json!({"promptId": "p-1", "turnId": "t-1", "text": "queued hello", "_meta": {"provenance": provenance}}),
        );

        let sender_updated = sender.meta().updated_at;
        let receiver_updated = receiver.meta().updated_at;
        recover_message_events(&hub, &receiver);
        recover_message_events(&hub, &receiver);
        assert_eq!(message_count(&hub, &receiver_id), 1);
        assert_eq!(message_count(&hub, &sender_id), 1);
        assert!(sender.meta().updated_at >= sender_updated);
        assert!(receiver.meta().updated_at >= receiver_updated);
    }

    #[tokio::test]
    async fn digest_message_recovery_rebuilds_nested_projection_once() {
        let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
        let mut config: Config = serde_json::from_value(json!({
            "harnesses": {"fake": {"argv": ["python3", fake]}},
            "defaultHarness": "fake",
            "permissionPolicy": "approve-all"
        }))
        .expect("config");
        config.store.mode = StoreMode::Memory;
        let store = crate::store::open(&config.store, Path::new("/nonexistent")).expect("store");
        let hub = Hub::new(config, store);
        let make = |name: &str| NewRequest {
            name: Some(name.into()),
            cwd: Some(std::env::temp_dir()),
            policy: Some(PermissionPolicy::ApproveAll),
            ..NewRequest::default()
        };
        let sender = hub.new_session(make("sender")).await.expect("sender");
        let receiver = hub.new_session(make("receiver")).await.expect("receiver");
        let sender_id = sender.id.clone();
        let receiver_id = receiver.id.clone();
        let original = json!({
            "kind": "session_message",
            "from": sender_id,
            "fromName": "sender",
            "to": receiver_id,
            "_acpmuxMessage": {
                "sender": {"name": "sender", "sessionId": sender.id, "host": "local"},
                "text": "joined hello",
                "messageId": "digest-delivery-1",
                "at": 1234,
                "recordSenderCopy": true
            }
        });
        let digest = json!({
            "kind": "agent_digest",
            "messages": [{"promptId": "joined-prompt", "from": "sender", "provenance": original}]
        });
        // A started digest has no queued record; its user_message is the only durable recovery
        // source when the daemon stops before the acceptance callback writes projections.
        hub.append(
            &receiver,
            "mux",
            "user_message",
            json!({"promptId": "digest-prompt", "_meta": {"provenance": digest}}),
        );

        recover_message_events(&hub, &receiver);
        recover_message_events(&hub, &receiver);
        assert_eq!(message_count(&hub, &receiver_id), 1);
        assert_eq!(message_count(&hub, &sender_id), 1);
    }

    #[tokio::test]
    async fn sender_copies_with_same_prompt_id_keep_distinct_targets_and_peers() {
        let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
        let mut config: Config = serde_json::from_value(json!({
            "harnesses": {"fake": {"argv": ["python3", fake]}},
            "defaultHarness": "fake", "permissionPolicy": "approve-all"
        }))
        .expect("config");
        config.store.mode = StoreMode::Memory;
        let store = crate::store::open(&config.store, Path::new("/nonexistent")).expect("store");
        let hub = Hub::new(config, store);
        let sender = hub
            .new_session(NewRequest {
                name: Some("sender".into()),
                cwd: Some(std::env::temp_dir()),
                ..NewRequest::default()
            })
            .await
            .expect("sender");
        let sender_id = sender.id.clone();
        let sender_meta = json!({"name": "sender", "sessionId": sender_id});
        assert!(hub.append_message_event_scoped(
            &sender,
            sender_meta.clone(),
            "to b".into(),
            "same-prompt".into(),
            1,
            Some("b"),
            None
        ));
        assert!(hub.append_message_event_scoped(
            &sender,
            sender_meta.clone(),
            "to c".into(),
            "same-prompt".into(),
            2,
            Some("c"),
            None
        ));
        assert_eq!(message_count(&hub, &sender.id), 2);
        // A peer's chat keeps the raw id of one here after an export and import: a send to each
        // is its own copy, and each copy is kept once.
        for (at, peer) in [(3, Some("remote")), (4, Some("remote")), (5, Some("other")), (6, None)]
        {
            assert!(hub.append_message_event_scoped(
                &sender,
                sender_meta.clone(),
                "to b".into(),
                "same-prompt".into(),
                at,
                Some("b"),
                peer
            ));
        }
        assert_eq!(message_count(&hub, &sender.id), 4);
        // The index a restart rebuilds from the journal keeps the peer apart too.
        *sender.message_ids.lock().unwrap() = None;
        for peer in [Some("remote"), Some("other"), None] {
            assert!(hub.append_message_event_scoped(
                &sender,
                sender_meta.clone(),
                "to b".into(),
                "same-prompt".into(),
                7,
                Some("b"),
                peer
            ));
        }
        assert_eq!(message_count(&hub, &sender.id), 4);
    }

    #[tokio::test]
    async fn sender_projection_repairs_without_resending_after_a_transient_failure() {
        let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
        let mut config: Config = serde_json::from_value(json!({
            "harnesses": {"fake": {"argv": ["python3", fake]}},
            "defaultHarness": "fake",
            "permissionPolicy": "approve-all"
        }))
        .expect("config");
        config.store.mode = StoreMode::Memory;
        let store = crate::store::open(&config.store, Path::new("/nonexistent")).expect("store");
        let hub = Hub::new(config, store);
        let make = |name: &str| NewRequest {
            name: Some(name.into()),
            cwd: Some(std::env::temp_dir()),
            policy: Some(PermissionPolicy::ApproveAll),
            ..NewRequest::default()
        };
        let sender = hub.new_session(make("sender")).await.expect("sender");
        let receiver = hub.new_session(make("receiver")).await.expect("receiver");
        let sender_id = sender.id.clone();
        let receiver_id = receiver.id.clone();
        let message = MessageContext {
            sender: json!({"name": "sender", "sessionId": sender_id, "host": "local"}),
            sender_session: sender.id.clone(),
            text: "repair me".into(),
            message_id: "repair-delivery-1".into(),
            at: 1234,
            record_sender_copy: true,
        };

        // Inject one sender-store failure. The bounded repair retries the same projection without
        // invoking prompt delivery.
        hub.message_projection_failures.lock().unwrap().insert(sender.id.clone());
        let mut events = hub.subscribe();
        record_message_context(&hub, &receiver_id, &message);
        assert_eq!(message_count(&hub, &receiver_id), 1);
        assert_eq!(message_count(&hub, &sender_id), 0);
        tokio::time::timeout(std::time::Duration::from_secs(4), async {
            loop {
                let event = events.recv().await.expect("hub event");
                if event.session_id == sender_id
                    && event.record.kind == "_acpmux/message"
                    && event.record.msg["messageId"] == "repair-delivery-1"
                    && message_count(&hub, &sender_id) == 1
                {
                    break;
                }
            }
        })
        .await
        .expect("sender projection repair timed out");
        assert_eq!(message_count(&hub, &sender_id), 1);
    }

    #[tokio::test]
    async fn forked_historical_user_messages_do_not_recreate_sender_copies() {
        let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
        let mut config: Config = serde_json::from_value(json!({
            "harnesses": {"fake": {"argv": ["python3", fake]}},
            "defaultHarness": "fake",
            "permissionPolicy": "approve-all"
        }))
        .expect("config");
        config.store.mode = StoreMode::Memory;
        let store = crate::store::open(&config.store, Path::new("/nonexistent")).expect("store");
        let hub = Hub::new(config, store);
        let make = |name: &str| NewRequest {
            name: Some(name.into()),
            cwd: Some(std::env::temp_dir()),
            policy: Some(PermissionPolicy::ApproveAll),
            ..NewRequest::default()
        };
        let sender = hub.new_session(make("sender")).await.expect("sender");
        let child = hub.new_session(make("child")).await.expect("child");
        child.meta.lock().unwrap().parent_id = Some("parent".into());
        child.meta.lock().unwrap().fork_seq = Some(1);
        let provenance = json!({
            "kind": "session_message",
            "from": sender.id,
            "fromName": "sender",
            "to": child.id,
            "_acpmuxMessage": {
                "sender": {"name": "sender", "sessionId": sender.id, "host": "local"},
                "text": "inherited",
                "messageId": "historical-delivery",
                "at": 1234,
                "recordSenderCopy": true
            }
        });
        hub.append(
            &child,
            "mux",
            "user_message",
            json!({"promptId": "historical", "_meta": {"provenance": provenance.clone()}}),
        );
        hub.append(&child, "mux", "forked", json!({"parentId": "parent", "forkSeq": 1}));
        recover_message_events(&hub, &child);
        assert_eq!(message_count(&hub, &child.id), 0);
        assert_eq!(message_count(&hub, &sender.id), 0);

        // New child traffic after the fork marker remains recoverable and gets both projections.
        hub.append(
            &child,
            "mux",
            "user_message",
            json!({"promptId": "current", "_meta": {"provenance": provenance}}),
        );
        recover_message_events(&hub, &child);
        assert_eq!(message_count(&hub, &child.id), 1);
        assert_eq!(message_count(&hub, &sender.id), 1);
    }

    /// The memory store, whose next `fail` appends of a `_acpmux/message` record fail as a
    /// full or unwritable disk would.
    struct RefusingStore {
        inner: Box<dyn crate::store::Store>,
        fail: std::sync::atomic::AtomicUsize,
    }

    impl crate::store::Store for RefusingStore {
        fn list(&self) -> anyhow::Result<Vec<crate::store::SessionMeta>> {
            self.inner.list()
        }
        fn load(&self, id: &str) -> anyhow::Result<Option<crate::store::SessionMeta>> {
            self.inner.load(id)
        }
        fn save(&self, meta: &crate::store::SessionMeta) -> anyhow::Result<()> {
            self.inner.save(meta)
        }
        fn append(&self, id: &str, record: &crate::store::EventRecord) -> anyhow::Result<()> {
            use std::sync::atomic::Ordering::SeqCst;
            if record.kind == "_acpmux/message"
                && self.fail.fetch_update(SeqCst, SeqCst, |n| n.checked_sub(1)).is_ok()
            {
                anyhow::bail!("no space left on device");
            }
            self.inner.append(id, record)
        }
        fn events(
            &self,
            id: &str,
            after: u64,
            limit: usize,
        ) -> anyhow::Result<Vec<crate::store::EventRecord>> {
            self.inner.events(id, after, limit)
        }
        fn delete(&self, id: &str) -> anyhow::Result<()> {
            self.inner.delete(id)
        }
    }

    /// A copy the store refused is not published: the one copy clients and peers hear is the
    /// one the journal holds, under its own seq, after the append is retried.
    #[tokio::test]
    async fn a_message_copy_the_store_refuses_is_never_published() {
        let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
        let mut config: Config = serde_json::from_value(json!({
            "harnesses": {"fake": {"argv": ["python3", fake]}},
            "defaultHarness": "fake",
            "permissionPolicy": "approve-all"
        }))
        .expect("config");
        config.store.mode = StoreMode::Memory;
        let inner = crate::store::open(&config.store, Path::new("/nonexistent")).expect("store");
        let store = RefusingStore { inner, fail: std::sync::atomic::AtomicUsize::new(1) };
        let hub = Hub::new(config, Box::new(store));
        let receiver = hub
            .new_session(NewRequest {
                name: Some("receiver".into()),
                cwd: Some(std::env::temp_dir()),
                policy: Some(PermissionPolicy::ApproveAll),
                ..NewRequest::default()
            })
            .await
            .expect("receiver");
        let mut events = hub.subscribe();
        let sender = json!({"name": "sender", "sessionId": "sender-1", "host": "local"});
        let send = || {
            hub.append_message_event(
                &receiver,
                sender.clone(),
                "once".into(),
                "delivery-1".into(),
                1234,
            )
        };
        assert!(!send(), "the store refused the first copy");
        assert!(send(), "the retry is stored");
        assert!(send(), "a third append finds the stored copy");
        let mut heard = Vec::new();
        while let Ok(event) = events.try_recv() {
            if event.session_id == receiver.id && event.record.kind == "_acpmux/message" {
                heard.push(event.record.seq);
            }
        }
        assert_eq!(message_count(&hub, &receiver.id), 1);
        let stored = hub
            .events_page(
                &receiver.id,
                0,
                None,
                500,
                None,
                false,
                &EventFilter::parse(None).unwrap(),
            )
            .expect("event page")
            .events
            .into_iter()
            .find(|record| record.kind == "_acpmux/message")
            .expect("stored copy")
            .seq;
        assert_eq!(heard, vec![stored], "only the stored copy is published");
    }

    /// A lazy load of the receiver recovers its message before the store's load installs the
    /// sender: the sender's copy is appended once the sender is read, not dropped.
    #[tokio::test]
    async fn recovery_before_the_sender_loads_still_records_its_copy() {
        let dir =
            std::env::temp_dir().join(format!("message-late-sender-{}", uuid::Uuid::now_v7()));
        std::fs::create_dir_all(&dir).unwrap();
        let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
        let mut config: Config = serde_json::from_value(json!({
            "harnesses": {"fake": {"argv": ["python3", fake]}},
            "defaultHarness": "fake",
            "permissionPolicy": "approve-all"
        }))
        .expect("config");
        config.store.mode = StoreMode::Local;
        let original = Hub::new(config.clone(), crate::store::open(&config.store, &dir).unwrap());
        let sender = original
            .new_session(NewRequest {
                name: Some("sender".into()),
                cwd: Some(std::env::temp_dir()),
                policy: Some(PermissionPolicy::ApproveAll),
                ..NewRequest::default()
            })
            .await
            .expect("sender");
        let sender_id = sender.id.clone();
        original.detach_child(&sender).await;
        original.store.flush().unwrap();
        // The restarted daemon has not read its saved sessions yet.
        let restarted = Hub::new_loading(
            config.clone(),
            crate::store::open(&config.store, &dir).unwrap(),
            crate::mailbox::Mailbox::open(dir.join("mailbox")).unwrap(),
        );
        assert!(resolve_exact(&restarted, &sender_id).is_none());
        let message = MessageContext {
            sender: json!({"name": "sender", "sessionId": sender_id, "host": "local"}),
            sender_session: sender_id.clone(),
            text: "late".into(),
            message_id: "late-delivery-1".into(),
            at: 1234,
            record_sender_copy: true,
        };
        let mut events = restarted.subscribe();
        append_or_repair(&restarted, &sender_id, &message, Some("receiver-1"));
        tokio::time::timeout(std::time::Duration::from_secs(10), async {
            loop {
                let event = events.recv().await.expect("hub event");
                if event.session_id == sender_id
                    && event.record.kind == "_acpmux/message"
                    && event.record.msg["messageId"] == "late-delivery-1"
                {
                    break;
                }
            }
        })
        .await
        .expect("the sender's copy is appended once it loads");
        assert_eq!(message_count(&restarted, &sender_id), 1);
        std::fs::remove_dir_all(&dir).ok();
    }

    fn memory_hub() -> Arc<Hub> {
        let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
        let mut config: Config = serde_json::from_value(json!({
            "harnesses": {"fake": {"argv": ["python3", fake]}},
            "defaultHarness": "fake",
            "permissionPolicy": "approve-all"
        }))
        .expect("config");
        config.store.mode = StoreMode::Memory;
        let store = crate::store::open(&config.store, Path::new("/nonexistent")).expect("store");
        Hub::new(config, store)
    }

    async fn session(hub: &Arc<Hub>, name: &str) -> Arc<Session> {
        hub.new_session(NewRequest {
            name: Some(name.into()),
            cwd: Some(std::env::temp_dir()),
            policy: Some(PermissionPolicy::ApproveAll),
            ..NewRequest::default()
        })
        .await
        .expect("session")
    }

    /// A record addressed to another session (a fork's inherited prefix, after an import
    /// dropped its marker) recreates no copy; one addressed to this session does.
    #[tokio::test]
    async fn a_record_addressed_to_another_session_recreates_no_copy() {
        let hub = memory_hub();
        let sender = session(&hub, "sender").await;
        let imported = session(&hub, "imported").await;
        let record = |to: &str, id: &str| {
            json!({"promptId": id, "_meta": {"provenance": {
                "kind": "session_message", "from": sender.id, "fromName": "sender", "to": to,
                "_acpmuxMessage": {
                    "sender": {"name": "sender", "sessionId": sender.id, "host": "local"},
                    "text": "hello", "messageId": id, "at": 1234, "recordSenderCopy": true
                }
            }}})
        };
        let original_receiver = uuid::Uuid::now_v7().to_string();
        hub.append(&imported, "mux", "user_message", record(&original_receiver, "inherited"));
        hub.append(
            &imported,
            "mux",
            "user_message",
            record(&format!("acp:{original_receiver}"), "inherited-2"),
        );
        // Addressed by name, as a local provenance may be: the copy's receiver id says whose.
        let mut named = record("receiver", "inherited-named");
        named["_meta"]["provenance"]["_acpmuxMessage"]["receiverId"] = json!(original_receiver);
        hub.append(&imported, "mux", "user_message", named);
        recover_message_events(&hub, &imported);
        assert_eq!(message_count(&hub, &imported.id), 0);
        assert_eq!(message_count(&hub, &sender.id), 0);
        hub.append(&imported, "mux", "user_message", record(&imported.id, "own"));
        recover_message_events(&hub, &imported);
        assert_eq!(message_count(&hub, &imported.id), 1);
        assert_eq!(message_count(&hub, &sender.id), 1);
    }

    /// A person's or terminal's message (`from: "cli"`, `"term_1234"`) is no session's message;
    /// an agent's (`acp:<id>`) is.
    #[tokio::test]
    async fn only_a_session_sender_makes_a_session_message() {
        let hub = memory_hub();
        let receiver = session(&hub, "receiver").await;
        let agent = session(&hub, "agent").await;
        let context = |from: &str| {
            let opts = PromptOptions {
                provenance: Some(json!({"kind": "agent_message", "from": from,
                    "fromName": "someone", "to": format!("acp:{}", receiver.id),
                    "msgId": "m", "threadId": "t"})),
                ..PromptOptions::default()
            };
            message_context(&hub, &receiver, &[json!({"type": "text", "text": "hi"})], &opts, "p")
        };
        assert!(context("cli").is_none());
        assert!(context("term_1234").is_none());
        let from_agent = context(&format!("acp:{}", agent.id)).expect("an agent's message");
        assert_eq!(from_agent.sender_session, agent.id);
    }
}
