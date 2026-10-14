//! The Chief registry on `cmux.protocol/2`: `chief.profile.list`, `chief.profile.get`,
//! `chief.profile.create`, `chief.profile.update`, `chief.profile.delete`, `chief.profile.avatar.set` and
//! `chief.profile.avatar.get` (chief_registry.rs; hq .cmux-scratch/hq6d-multi-chief
//! DESIGN.md, bead cx-ebm.60).
//!
//! Callers. The owner: a registered Unix client with no link peer record
//! acting as `user_local` (the rule of chief.engine.*). A Chief: a Unix
//! connection bound with `conversation-bind` to the participant id of a live
//! record. The person's page (`chief-profile-ws-v1`): an authenticated
//! WebSocket acting as `user_local` that is no remote client and no bound
//! agent, and is either page `home-channels` admitted with a credential
//! bound to that page (`page-credential {page}`, the app's Channels page on
//! its Chief owner) or no page with the daemon's own credential (a
//! pairing-store credential is refused: a paired device can send any Origin);
//! it lists and reads Chiefs and changes display_name, role and the avatar;
//! create, delete, instructions, personality and the grant (tools,
//! harnesses, engine, self_edit) need the person's gesture, which a WebSocket
//! never carries (`gesture_required`; the host's page relay brings it,
//! request_origin.rs). Every other
//! connection (another page, a relayed or remote client, a paired device, an
//! agent that is not a Chief) is refused with `origin.forbidden`.
//! The owner may do everything except delete the default Chief. A Chief
//! may read every record, and may change only its own fields that its
//! record lists in `self_edit` (the person's rule): never its tools,
//! harnesses, engine or `self_edit`, never another Chief, never create or
//! delete. Such a request is refused with `operation.failed` reason
//! `chief_self_edit_denied` before anything is written.

use std::sync::Arc;

use base64::Engine as _;
use base64::engine::general_purpose::STANDARD;
use serde_json::{Map, Value, json};

use super::{
    ClientTransport, MessageWriter, Mux, ResourceError, ResourceOperation, send_resource_response,
};
use crate::chief_registry::{self, AvatarChange, ChiefStore, Refusal};
use crate::conversation_store::LOCAL_USER;
use crate::resource_router::ParsedResourceRequest;

use ResourceOperation as Op;

pub(super) const fn handles(operation: ResourceOperation) -> bool {
    matches!(
        operation,
        Op::ChiefProfileList
            | Op::ChiefProfileGet
            | Op::ChiefProfileCreate
            | Op::ChiefProfileUpdate
            | Op::ChiefProfileDelete
            | Op::ChiefProfileAvatarSet
            | Op::ChiefProfileAvatarGet
    )
}

/// Who calls.
#[derive(Debug, Clone, PartialEq, Eq)]
enum Caller {
    Owner,
    /// The Chief with this id (its bound participant).
    Chief(String),
    /// The person's page on an authenticated WebSocket: the owner's rights
    /// without the grant fields and delete (no gesture on a WebSocket).
    Page,
}

/// The capability that names the person's page as a caller.
pub const CHIEF_PROFILE_WS_CAPABILITY: &str = "chief-profile-ws-v1";

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
    with_store(mux, operation, |store| {
        let caller = caller(mux, client, store)?;
        match operation {
            Op::ChiefProfileList => {
                let chiefs: Vec<Value> = store
                    .list()
                    .map_err(|e| internal(operation, &e))?
                    .iter()
                    .map(chief_registry::wire)
                    .collect();
                Ok(json!({"chiefs": chiefs}))
            }
            Op::ChiefProfileGet => {
                let chief = chief_field(fields);
                match store.get(chief).map_err(|e| internal(operation, &e))? {
                    Some(record) => Ok(chief_registry::wire(&record)),
                    None => Err(refused(operation, &Refusal::NotFound)),
                }
            }
            Op::ChiefProfileAvatarGet => {
                let chief = chief_field(fields);
                match store.avatar(chief).map_err(|e| internal(operation, &e))? {
                    Err(refusal) => Err(refused(operation, &refusal)),
                    Ok(None) => Ok(json!({"chief": chief, "avatar": null})),
                    Ok(Some((avatar, data))) => Ok(json!({"chief": chief, "avatar": {
                        "sha256": avatar.sha256, "media_type": avatar.media_type,
                        "bytes": avatar.bytes, "data": STANDARD.encode(data)}})),
                }
            }
            _ => mutate(mux, client, store, &caller, request),
        }
    })
}

fn mutate(
    mux: &Mux,
    client: u64,
    store: &mut ChiefStore,
    caller: &Caller,
    request: &ParsedResourceRequest,
) -> Result<Value, ResourceError> {
    let operation = request.envelope.operation;
    let fields = &request.fields;
    let key = request.envelope.idempotency_key.clone().unwrap_or_default();
    if key.is_empty() {
        return Err(ResourceError::validation_invalid(
            Some("idempotency_key"),
            "a mutation needs an idempotency key",
        ));
    }
    let profile: Map<String, Value> = fields
        .iter()
        .filter(|(k, _)| {
            !matches!(k.as_str(), "chief" | "expected_rev" | "media_type" | "data" | "clear")
        })
        .map(|(k, v)| (k.clone(), v.clone()))
        .collect();
    if let Some(refusal) = chief_registry::validate_fields(&profile) {
        return Err(refused(operation, &refusal));
    }
    let chief = chief_field(fields).to_owned();
    let expected_rev = fields.get("expected_rev").and_then(Value::as_u64);
    let avatar = match operation {
        Op::ChiefProfileAvatarSet => Some(avatar_change(operation, fields)?),
        _ => None,
    };
    if let Caller::Chief(me) = caller {
        self_edit_allowed(store, operation, me, &chief, &profile)?;
    }
    if *caller == Caller::Page
        && (matches!(operation, Op::ChiefProfileCreate | Op::ChiefProfileDelete)
            || chief_registry::names_gesture_field(&profile))
    {
        return Err(crate::request_origin::forbidden(
            "creating or deleting a Chief, or changing its instructions, personality, tools, harnesses, engine or self-edit rights, needs the person's gesture in the cmux app",
            json!({"derived": "agent", "required": "user", "reason": "gesture_required"}),
        ));
    }
    let actor = audit_actor(mux, client, caller);
    let body = json!({"operation": operation.wire_name(), "fields": Value::Object(fields.clone())});
    let outcome = store
        .mutate(&actor, &key, operation.wire_name(), &body, |tx| match operation {
            Op::ChiefProfileCreate => chief_registry::create(tx, &profile),
            Op::ChiefProfileUpdate => {
                chief_registry::update(tx, &chief, expected_rev, &profile, None)
            }
            Op::ChiefProfileAvatarSet => {
                chief_registry::update(tx, &chief, expected_rev, &Map::new(), avatar)
            }
            _ => chief_registry::delete(tx, &chief, expected_rev),
        })
        .map_err(|e| internal(operation, &e))?;
    match outcome {
        Ok((record, replayed)) => {
            if !replayed {
                mux.chiefs().brains.chief_written(
                    &record,
                    operation == Op::ChiefProfileCreate,
                    operation == Op::ChiefProfileDelete,
                );
            }
            let (_, generation) = mux.registry_identity();
            Ok(json!({"value": chief_registry::wire(&record), "generation": generation,
                      "revision": record.rev.to_string(), "replayed": replayed}))
        }
        Err(Refusal::KeyConflict(committed)) => {
            Err(ResourceError::idempotency_conflict(&key, &committed))
        }
        Err(refusal) => Err(refused(operation, &refusal)),
    }
}

/// The actor the ledger records for a write: a page's write (a page
/// WebSocket, or the host's page relay) is told apart from a terminal's,
/// `user_local via page:<page>` (`user_local via websocket` for a page with no
/// page id); a Chief is its own id.
fn audit_actor(mux: &Mux, client: u64, caller: &Caller) -> String {
    match caller {
        Caller::Chief(me) => me.clone(),
        Caller::Owner | Caller::Page => match super::origin_gate::connection_page(mux, client) {
            Some(page) => format!("{LOCAL_USER} via page:{page}"),
            None if *caller == Caller::Page => format!("{LOCAL_USER} via websocket"),
            None => LOCAL_USER.to_owned(),
        },
    }
}

/// The person's rule for a Chief changing itself.
fn self_edit_allowed(
    store: &ChiefStore,
    operation: Op,
    me: &str,
    chief: &str,
    profile: &Map<String, Value>,
) -> Result<(), ResourceError> {
    let deny = |fields: Vec<String>, why: &str| {
        Err(ResourceError::operation_failed(
            operation.wire_name(),
            "chief_self_edit_denied",
            json!({"message": why, "fields": fields}),
        ))
    };
    if !matches!(operation, Op::ChiefProfileUpdate | Op::ChiefProfileAvatarSet) {
        return deny(Vec::new(), "only the person creates or deletes Chiefs");
    }
    if chief != me {
        return deny(Vec::new(), "a Chief changes only its own profile");
    }
    let record = store
        .get(me)
        .map_err(|e| internal(operation, &e))?
        .ok_or_else(|| refused(operation, &Refusal::NotFound))?;
    let wanted: Vec<String> = match operation {
        Op::ChiefProfileAvatarSet => vec!["avatar".to_owned()],
        _ => profile.keys().cloned().collect(),
    };
    let denied: Vec<String> =
        wanted.into_iter().filter(|field| !record.self_edit.contains(field)).collect();
    if denied.is_empty() {
        Ok(())
    } else {
        deny(denied, "the person has not allowed this Chief to change these fields; ask them")
    }
}

fn avatar_change(
    operation: Op,
    fields: &Map<String, Value>,
) -> Result<AvatarChange, ResourceError> {
    let clear = fields.get("clear").and_then(Value::as_bool).unwrap_or(false);
    let data = fields.get("data").and_then(Value::as_str);
    match (clear, data) {
        (true, None) => Ok(AvatarChange::Clear),
        (false, Some(data)) => {
            let bytes = STANDARD.decode(data).map_err(|_| {
                ResourceError::validation_invalid(Some("data"), "data must be base64")
            })?;
            let media_type = fields.get("media_type").and_then(Value::as_str).unwrap_or("");
            if let Some(refusal) = chief_registry::validate_avatar(media_type, &bytes) {
                return Err(refused(operation, &refusal));
            }
            Ok(AvatarChange::Set { media_type: media_type.to_owned(), bytes })
        }
        _ => Err(ResourceError::validation_invalid(
            Some("data"),
            "give data and media_type, or clear: true",
        )),
    }
}

fn caller(mux: &Mux, client: u64, store: &ChiefStore) -> Result<Caller, ResourceError> {
    let unix = matches!(mux.control_clients.transport_of(client), Some(ClientTransport::Unix));
    let principal = mux.conversation_principal(client);
    let forbidden = || {
        crate::request_origin::forbidden(
            "the Chief registry is for the person's trusted connection and its Chiefs only",
            json!({"derived": "agent", "required": "user", "reason": "chief_registry_caller"}),
        )
    };
    if mux.is_remote_client(client) {
        return Err(forbidden());
    }
    if !unix {
        // The person's page (chief-profile-ws-v1): an authenticated WebSocket
        // as `user_local`, no bound agent, and either no page with the
        // daemon's own credential, or page home-channels admitted with a
        // credential bound to that page. A pairing-store credential (an
        // approved pairing; the app's person credential shares the store) is
        // refused with or without a page Origin: a native client can send any
        // Origin. Every lock read fails closed.
        let admitted = super::origin_gate::websocket_admission(mux, client).is_some_and(|ws| {
            match ws.page.as_deref() {
                None => !ws.person,
                Some(page) => page == "home-channels" && ws.scoped_page && !ws.person,
            }
        });
        let unbound = matches!(mux.bound_conversation_participant(client), Ok(None));
        let person_page = admitted && unbound && principal == LOCAL_USER;
        return if person_page { Ok(Caller::Page) } else { Err(forbidden()) };
    }
    if principal == LOCAL_USER {
        return Ok(Caller::Owner);
    }
    let bound = mux.bound_conversation_participant(client).ok().flatten();
    match bound {
        Some(id) if id == principal && store.get(&id).ok().flatten().is_some() => {
            Ok(Caller::Chief(id))
        }
        _ => Err(forbidden()),
    }
}

fn with_store<T>(
    mux: &Mux,
    operation: Op,
    run: impl FnOnce(&mut ChiefStore) -> Result<T, ResourceError>,
) -> Result<T, ResourceError> {
    let mut store = mux.chiefs().store.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
    if store.is_none() {
        let directory = mux.session_state_directory();
        *store = Some(ChiefStore::open(directory.as_deref()).map_err(|e| internal(operation, &e))?);
    }
    run(store.as_mut().expect("chief registry opened above"))
}

fn chief_field(fields: &Map<String, Value>) -> &str {
    fields.get("chief").and_then(Value::as_str).unwrap_or("")
}

fn refused(operation: Op, refusal: &Refusal) -> ResourceError {
    match refusal {
        Refusal::Invalid(field, why) => {
            ResourceError::validation_invalid(Some(field), format!("{field} {why}"))
        }
        Refusal::RevMismatch(rev) => ResourceError::operation_failed(
            operation.wire_name(),
            refusal.reason(),
            json!({"message": "the Chief changed since you read it", "rev": rev}),
        ),
        other => ResourceError::operation_failed(operation.wire_name(), other.reason(), json!({})),
    }
}

fn internal(operation: Op, error: &anyhow::Error) -> ResourceError {
    ResourceError::operation_failed(
        operation.wire_name(),
        "internal",
        json!({"message": format!("{error:#}")}),
    )
}
