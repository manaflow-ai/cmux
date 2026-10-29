//! Durable message projections, repaired from accepted prompt records after a restart.

use super::*;

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

/// Internal durable copy of a message projection. It lives beside the existing
/// provenance on queued/user_message records so a daemon restart can recover a
/// projection even if it crashed after writing the prompt record but before the
/// acceptance callback ran.
const MESSAGE_META: &str = "_acpmuxMessage";

pub(super) fn embed_message_context(opts: &mut PromptOptions, message: Option<&MessageContext>) {
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
    let _ =
        hub.store.scan_kinds(&session.id, &["queued", "user_message", "forked"], &mut |record| {
            if inherited {
                if record.kind == "forked" {
                    inherited = false;
                }
                return true;
            }
            if !matches!(record.kind.as_str(), "queued" | "user_message") {
                return true;
            }
            let Some(provenance) = record.msg.pointer("/_meta/provenance") else { return true };
            collect_message_contexts(provenance, &mut pending);
            true
        });
    for message in pending {
        append_or_repair(hub, &session.id, &message, None);
        if message.record_sender_copy && message.sender_session != session.id {
            append_or_repair(hub, &message.sender_session, &message, Some(&session.id));
        }
    }
}

/// A digest user message carries each joined prompt's original provenance one level down. Keep
/// recovery aligned with the live acceptance path, which records every joined message separately.
fn collect_message_contexts(provenance: &Value, pending: &mut Vec<MessageContext>) {
    if let Some(message) = message_context_from_provenance(provenance) {
        pending.push(message);
    }
    if let Some(messages) = provenance.get("messages").and_then(Value::as_array) {
        for message in messages {
            if let Some(nested) = message.get("provenance") {
                collect_message_contexts(nested, pending);
            }
        }
    }
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

pub(super) fn ensure_message_provenance(opts: &mut PromptOptions, target_id: &str) {
    if opts.provenance.is_some() {
        return;
    }
    let Some(sender) = opts.message_sender.as_ref().and_then(Value::as_object) else { return };
    let Some(id) = sender.get("sessionId").and_then(Value::as_str) else { return };
    let Some(name) = sender.get("name").and_then(Value::as_str) else { return };
    let mut provenance = crate::prompt_provenance::named_sender(name, target_id);
    provenance["sessionId"] = json!(id);
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
    let Some(session) = resolve_exact(hub, session_id) else { return };
    if !hub.append_message_event_scoped(
        &session,
        message.sender.clone(),
        message.text.clone(),
        message.message_id.clone(),
        message.at,
        target_scope,
    ) {
        schedule_projection_repair(hub, session_id, message, target_scope);
    }
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
    async fn sender_copies_with_same_prompt_id_keep_distinct_targets() {
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
            Some("b")
        ));
        assert!(hub.append_message_event_scoped(
            &sender,
            sender_meta,
            "to c".into(),
            "same-prompt".into(),
            2,
            Some("c")
        ));
        assert_eq!(message_count(&hub, &sender.id), 2);
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
}
