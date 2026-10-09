//! The local conversation owner on `cmux.protocol/2`: `conversation.list`,
//! `get`, `history`, `search`, `send`, `typing`, `draft` and the stream
//! `conversation.events` (spec/resource-operations-v2.json). Every operation
//! calls the same owner as the raw `conversation-*` commands, as the
//! connection's conversation principal (`user_local`, or the agent the
//! connection bound with `conversation-bind`); the v2 path adds no authority.
//!
//! Stricter than the raw commands: every read names only conversations the
//! principal takes part in (`list` filters, the others refuse with
//! `not_participant`). Trusted local (Unix) connections only; the remote
//! relay refuses every resource-protocol frame before dispatch
//! (remote_relay/gate.rs), so a paired device never reaches these.

use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::Instant;

use cmux_conversation::{Op, PartRef, Reject};
use serde_json::{Value, json};

use super::conversations::commit_op;
use super::{
    MessageWriter, Mux, MuxEvent, OutboundStream, ResourceError, ResourceOperation,
    ResourceWorkerPermit, StreamPublicId, send_resource_response, session_stream,
    trusted_local_resource_client,
};
use crate::conversation_store::{ConversationEvent, ConversationRejected};
use crate::resource_router::ParsedResourceRequest;

#[path = "conversation_events.rs"]
mod events;

use ResourceOperation as Operation;

pub(super) const fn handles(operation: ResourceOperation) -> bool {
    matches!(
        operation,
        Operation::ConversationList
            | Operation::ConversationGet
            | Operation::ConversationHistory
            | Operation::ConversationSearch
            | Operation::ConversationSend
            | Operation::ConversationTyping
            | Operation::ConversationDraft
            | Operation::ConversationEvents
    )
}

/// Answers one admitted conversation request.
pub(super) fn handle(
    mux: &Arc<Mux>,
    client: u64,
    request: ParsedResourceRequest,
    writer: &MessageWriter,
) -> bool {
    let id = request.envelope.id.clone();
    let operation = request.envelope.operation;
    if operation == Operation::ConversationEvents {
        let prepared = trusted_local_resource_client(mux, client, operation)
            .and_then(|()| events::prepare(mux, client, writer, &request));
        return match prepared {
            Ok((result, start)) => {
                if !send_resource_response(writer, id, operation, Ok(result)) {
                    let _ = mux.control_clients.take_resource_stream(client, &start.stream_id);
                    return false;
                }
                events::start(mux.clone(), client, writer.clone(), start);
                true
            }
            Err(error) => send_resource_response(writer, id, operation, Err(error)),
        };
    }
    let result = trusted_local_resource_client(mux, client, operation)
        .and_then(|()| answer(mux, client, operation, &request));
    send_resource_response(writer, id, operation, result)
}

fn answer(
    mux: &Mux,
    client: u64,
    operation: ResourceOperation,
    request: &ParsedResourceRequest,
) -> Result<Value, ResourceError> {
    let principal = mux.conversation_principal(client);
    let fields = &Value::Object(request.fields.clone());
    let conversation = fields["conversation"].as_str().unwrap_or_default();
    let owner = |error| owner_error(operation, conversation, "", error);
    match operation {
        Operation::ConversationList => {
            let all = mux.with_conversations(|store| store.list()).map_err(owner)?;
            let mine = all
                .into_iter()
                .filter(|summary| summary.participants.iter().any(|p| p.id == principal))
                .collect::<Vec<_>>();
            Ok(json!(mine))
        }
        Operation::ConversationGet => {
            let tail = u32_field(fields, "tail", 50);
            let (summary, messages) = mux
                .with_conversations(|store| {
                    store.check_typing(conversation, &principal)?;
                    store.snapshot(conversation, tail.max(1))
                })
                .map_err(owner)?;
            let messages = if tail == 0 { Vec::new() } else { messages };
            Ok(json!({"conversation": summary, "messages": messages}))
        }
        Operation::ConversationHistory => {
            let before = u64::from(u32_field(fields, "before_seq", 1));
            let limit = u32_field(fields, "limit", 1);
            let messages = mux
                .with_conversations(|store| {
                    store.check_typing(conversation, &principal)?;
                    store.history(conversation, before, limit)
                })
                .map_err(owner)?;
            Ok(json!(messages))
        }
        Operation::ConversationSearch => {
            let input = cmux_conversation::SearchInput {
                query: fields["query"].as_str().unwrap_or_default().to_owned(),
                limit: u32_field(fields, "limit", 20),
            };
            // The owner stamps the actor: only the principal's conversations.
            let hits = mux.with_conversations(|store| store.search(&principal, &input));
            Ok(json!(hits.map_err(owner)?))
        }
        Operation::ConversationSend => send(mux, request, conversation, &principal),
        Operation::ConversationTyping => {
            let on = fields["on"].as_bool().unwrap_or(false);
            super::conversations::publish_typing(mux, conversation, &principal, on)
                .map_err(owner)?;
            Ok(publish_result(conversation, mux, true))
        }
        Operation::ConversationDraft => draft(mux, request, conversation, &principal),
        // `handles` names every operation above; anything else is refused.
        _ => Err(refused(operation, "not_a_conversation_operation", "not a conversation")),
    }
}

fn u32_field(fields: &Value, name: &str, default: u32) -> u32 {
    fields[name].as_u64().and_then(|v| u32::try_from(v).ok()).unwrap_or(default)
}

fn send(
    mux: &Mux,
    request: &ParsedResourceRequest,
    conversation: &str,
    principal: &str,
) -> Result<Value, ResourceError> {
    let operation = Operation::ConversationSend;
    let fields = &Value::Object(request.fields.clone());
    let key = request.envelope.idempotency_key.clone().unwrap_or_default();
    if !cmux_conversation::valid_token(&key) {
        return Err(ResourceError::validation_invalid(
            Some("idempotency_key"),
            "conversation.send keys are 1 to 128 printable ASCII characters (the message's client_msg_id)",
        ));
    }
    let parts = match (fields.get("text").and_then(Value::as_str), fields.get("parts")) {
        (Some(text), None) => json!([{"type": "text", "text": text}]),
        (None, Some(parts)) => parts.clone(),
        _ => {
            return Err(ResourceError::validation_invalid(
                Some("text"),
                "give exactly one of text and parts",
            ));
        }
    };
    let parts = serde_json::from_value(parts).map_err(|error| {
        ResourceError::validation_invalid(Some("parts"), format!("not conversation parts: {error}"))
    })?;
    let reply_to: Option<PartRef> = match fields.get("reply_to") {
        Some(value) => Some(serde_json::from_value(value.clone()).map_err(|error| {
            ResourceError::validation_invalid(Some("reply_to"), error.to_string())
        })?),
        None => None,
    };
    let op = Op::MessageSend { client_msg_id: key.clone(), parts, reply_to };
    let outcome = commit_op(mux, conversation, &key, principal, &op, &None)
        .map_err(|error| owner_error(operation, conversation, &key, error))?;
    let message = outcome.result.change.get("message").cloned().unwrap_or(Value::Null);
    Ok(json!({
        "value": {"message": message, "rev": outcome.result.rev},
        "generation": conversation,
        "revision": outcome.result.rev.to_string(),
        "replayed": outcome.replayed,
    }))
}

fn draft(
    mux: &Mux,
    request: &ParsedResourceRequest,
    conversation: &str,
    principal: &str,
) -> Result<Value, ResourceError> {
    let operation = Operation::ConversationDraft;
    if !principal.starts_with("agent_") {
        return Err(refused(
            operation,
            "not_agent",
            "only a bound agent participant publishes drafts",
        ));
    }
    let fields = &Value::Object(request.fields.clone());
    mux.with_conversations(|store| store.check_typing(conversation, principal))
        .map_err(|error| owner_error(operation, conversation, "", error))?;
    let turn = fields["turn"].as_str().unwrap_or_default();
    let seq = fields["seq"].as_u64().unwrap_or(0);
    let fresh = fields["fresh"].as_bool().unwrap_or(false);
    let text = fields["text"].as_str().unwrap_or_default();
    let draft = crate::conversation_drafts::DraftAdmission {
        conversation,
        participant: principal,
        turn,
        seq,
        fresh,
        text_bytes: text.len(),
    };
    let admitted = mux.admit_conversation_draft(draft, Instant::now());
    let published = match admitted {
        Ok(published) => published,
        Err(refusal) => return Err(refused(operation, refusal.reason(), refusal.reason())),
    };
    if published {
        let mut item = json!({
            "type": "draft",
            "conversation": conversation,
            "participant": principal,
            "turn": turn,
            "segment": fields["segment"],
            "seq": seq,
            "kind": fields["kind"],
            "text": text,
            "fresh": fresh,
            "done": fields["done"].as_bool().unwrap_or(false),
        });
        for optional in ["truncated", "harness"] {
            if let Some(value) = fields.get(optional) {
                item[optional] = value.clone();
            }
        }
        mux.emit(MuxEvent::Conversation(Arc::new(ConversationEvent::Draft {
            conversation: conversation.to_owned(),
            participant: principal.to_owned(),
            item,
        })));
    }
    Ok(publish_result(conversation, mux, published))
}

/// The mutation result of an ephemeral publish: the conversation's rev is
/// unchanged, and `published` false means a replay.
fn publish_result(conversation: &str, mux: &Mux, published: bool) -> Value {
    let rev = mux
        .with_conversations(|store| store.snapshot(conversation, 1))
        .map(|(summary, _)| summary.rev)
        .unwrap_or(0);
    json!({
        "value": {"published": published},
        "generation": conversation,
        "revision": rev.to_string(),
        "replayed": !published,
    })
}

fn refused(operation: ResourceOperation, reason: &str, message: &str) -> ResourceError {
    ResourceError::operation_failed(operation.wire_name(), reason, json!({"message": message}))
}

/// The v2 error of an owner refusal.
fn owner_error(
    operation: ResourceOperation,
    conversation: &str,
    key: &str,
    error: anyhow::Error,
) -> ResourceError {
    if let Some(ConversationRejected(reject)) = error.downcast_ref::<ConversationRejected>() {
        return match reject {
            Reject::UnknownConversation => ResourceError::new(
                "resource.not_found",
                format!("no conversation {conversation:?}"),
                json!({"scope": "conversation", "id": conversation}),
                false,
            ),
            Reject::IdempotencyConflict => {
                ResourceError::idempotency_conflict(key, operation.wire_name())
            }
            other => refused(operation, other.code(), other.code()),
        };
    }
    let reason =
        super::conversations::error_reason(&error).unwrap_or_else(|| "owner_failed".into());
    ResourceError::operation_failed(
        operation.wire_name(),
        reason,
        json!({"message": error.to_string()}),
    )
}

/// What `events::prepare` hands the stream worker.
pub(super) struct EventsStart {
    pub(super) stream_id: StreamPublicId,
    outbound: OutboundStream,
    canceled: Arc<AtomicBool>,
    _worker_permit: ResourceWorkerPermit,
    conversation: String,
    /// The principal that opened the stream; the stream ends when the
    /// connection's principal changes or loses the conversation.
    principal: String,
    events: crate::MuxEventReceiver,
    initial: Option<Value>,
    rev: u64,
}

impl EventsStart {
    fn stopped(&self, writer: &MessageWriter) -> bool {
        session_stream::stopped(&self.canceled, writer, &self.outbound)
    }

    fn cancelled(&self) -> bool {
        self.canceled.load(Ordering::Acquire)
    }
}

#[cfg(test)]
#[path = "conversation_resource_tests.rs"]
mod tests;
