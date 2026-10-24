//! `participant.avatar.set` / `participant.avatar.get` (capability
//! `participant-avatars-v1`): one picture per conversation participant, a
//! person or a Chief, in the daemon's ONE avatar store (chief_registry.rs:
//! bytes kept once by SHA-256, deleted when no participant references them).
//! The media type comes from the bytes (PNG, JPEG, GIF or WebP, at most 1 MiB).
//!
//! Who may set:
//! - a person their own picture (the connection's principal is that person:
//!   `user_local` on the owner's connections, or another person bound with a
//!   person credential, conversation-person-credentials-v1);
//! - the owner any Chief's, and a Chief only its own when its record lists
//!   `avatar` in `self_edit`: exactly the `chief.profile.avatar.set` write
//!   (chief_registry_resource.rs), brain supervisor notice included;
//! - nobody another person's. An agent caller of the CLI is refused by the
//!   CLI (`cmux avatar`, the Chief registry's agent-caller rule).
//!
//! Who may read: any of the person's own clients of the local conversations
//! (a Unix connection or an authenticated WebSocket, the Channels page too).
//! A committed change publishes `participant-avatar-changed` on `subscribe`
//! to the connections that echoed `participant-avatars-v1`.

use crate::panic_free::JsonFields;
use std::sync::Arc;

use base64::Engine as _;
use base64::engine::general_purpose::STANDARD;
use serde_json::{Map, Value, json};

use super::resource_trust::conversation_resource_client;
use super::{MessageWriter, chief_registry_resource};
use super::{Mux, MuxEvent, ResourceError, ResourceOperation, send_resource_response};
use crate::chief_registry::{AvatarBytes, AvatarRef};
use crate::conversation_store::ConversationEvent;
use crate::resource_router::ParsedResourceRequest;

use ResourceOperation as Op;

/// The capability: the two operations, the shared store, the event.
pub const PARTICIPANT_AVATARS_CAPABILITY: &str = "participant-avatars-v1";

pub(super) const fn handles(operation: ResourceOperation) -> bool {
    matches!(operation, Op::ParticipantAvatarSet | Op::ParticipantAvatarGet)
}

pub(super) fn handle(
    mux: &Arc<Mux>,
    client: u64,
    request: ParsedResourceRequest,
    writer: &MessageWriter,
) -> bool {
    let id = request.envelope.id.clone();
    let operation = request.envelope.operation;
    let result = answer(mux, client, &request);
    send_resource_response(writer, id, operation, result)
}

fn answer(mux: &Mux, client: u64, request: &ParsedResourceRequest) -> Result<Value, ResourceError> {
    let operation = request.envelope.operation;
    let fields = &request.fields;
    let participant = fields.get("participant_id").and_then(Value::as_str).unwrap_or("");
    let chief = participant.starts_with("agent_");
    if !chief && !participant.starts_with("user_") {
        return Err(ResourceError::validation_invalid(
            Some("participant_id"),
            "participant_id must be a person (user_...) or a Chief (agent_...)",
        ));
    }
    if operation == Op::ParticipantAvatarGet {
        reader(mux, client, operation)?;
        let found = if chief {
            chief_registry_resource::chief_avatar(mux, operation, participant)?
        } else {
            chief_registry_resource::person_avatar(mux, operation, participant)?
        };
        return Ok(json!({"participant_id": participant, "avatar": with_data(found)}));
    }
    let key = request.envelope.idempotency_key.clone().unwrap_or_default();
    if chief {
        // The Chief write: its callers, its self_edit rule, its ledger.
        let mut chief_fields = Map::new();
        chief_fields.insert("chief".into(), json!(participant));
        for name in ["data", "clear"] {
            if let Some(value) = fields.get(name) {
                chief_fields.insert(name.into(), value.clone());
            }
        }
        if let Some(bytes) = fields.get("bytes") {
            chief_fields.insert("data".into(), bytes.clone());
            // The alias wants a media_type: the bytes' own (a bad picture fails on data).
            let sniffed = bytes
                .as_str()
                .and_then(|b| STANDARD.decode(b).ok())
                .and_then(|b| crate::chief_registry::sniff_avatar(&b));
            if let Some(media_type) = sniffed {
                chief_fields.insert("media_type".into(), json!(media_type));
            }
        }
        let mut written =
            chief_registry_resource::set_chief_avatar(
                mux,
                client,
                &chief_fields,
                key,
                request.envelope.origin.as_ref().is_some_and(|origin| {
                    origin.claim == crate::request_origin::RequestOrigin::Agent
                }),
            )?;
        let avatar = written.pointer("/value/avatar").cloned().unwrap_or(Value::Null);
        written.insert("value", json!({"participant_id": participant, "avatar": avatar}));
        return Ok(written);
    }
    reader(mux, client, operation)?;
    if mux.conversation_principal(client) != participant {
        return Err(ResourceError::operation_failed(
            operation.wire_name(),
            "avatar_not_yours",
            json!({"message": "a person sets only their own picture; nobody sets another person's"}),
        ));
    }
    let mut change_fields = Map::new();
    if let Some(bytes) = fields.get("bytes").or_else(|| fields.get("data")) {
        change_fields.insert("data".into(), bytes.clone());
    }
    if let Some(clear) = fields.get("clear") {
        change_fields.insert("clear".into(), clear.clone());
    }
    let change = chief_registry_resource::avatar_change(operation, &change_fields)?;
    if key.is_empty() {
        return Err(ResourceError::validation_invalid(
            Some("idempotency_key"),
            "a mutation needs an idempotency key",
        ));
    }
    let request_json =
        json!({"operation": operation.wire_name(), "fields": Value::Object(fields.clone())});
    let write = chief_registry_resource::set_person_avatar(
        mux,
        operation,
        participant,
        &key,
        &request_json,
        change,
    )?;
    if write.changed {
        publish(mux, participant, write.avatar.as_ref());
    }
    let (_, generation) = mux.registry_identity();
    Ok(json!({"value": {"participant_id": participant, "avatar": write.avatar},
              "generation": generation, "revision": write.revision.to_string(),
              "replayed": write.replayed}))
}

/// The person's own clients of the local conversations, never a remote or
/// relayed connection.
fn reader(mux: &Mux, client: u64, operation: Op) -> Result<(), ResourceError> {
    if mux.is_remote_client(client) {
        return Err(crate::request_origin::forbidden(
            "avatars are for the person's own connections",
            json!({"reason": "avatar_remote_client"}),
        ));
    }
    conversation_resource_client(mux, client, operation)
}

fn with_data(found: AvatarBytes) -> Value {
    match found {
        None => Value::Null,
        Some((avatar, data)) => json!({"sha256": avatar.sha256, "media_type": avatar.media_type,
                                       "bytes": avatar.bytes, "data": STANDARD.encode(data)}),
    }
}

/// `participant-avatar-changed` for every subscriber that asked for it.
pub(super) fn publish(mux: &Mux, participant: &str, avatar: Option<&AvatarRef>) {
    mux.emit(MuxEvent::Conversation(Arc::new(ConversationEvent::Avatar {
        participant: participant.to_owned(),
        avatar: avatar.and_then(|a| serde_json::to_value(a).ok()),
    })));
}
