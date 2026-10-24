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
//! agent that is not a Chief) is refused with `origin.forbidden`; the trusted
//! owner connection used by a person-authorized CLI or app action remains the
//! owner and records an ACP session actor when one is verified.
//! The owner may do everything except delete the default Chief. A Chief
//! may read every record, and may change only its own fields that its
//! record lists in `self_edit` (the person's rule): never its own tools,
//! harnesses, engine or `self_edit`. Such a request is refused with
//! `operation.failed` reason `chief_self_edit_denied` before anything is
//! written. A Chief whose record holds the `chiefs` tool may also create
//! Chiefs and change other Chiefs within its own grant, never delete one
//! (chief_manage.rs); without it every write on another
//! Chief is `chief_manage_denied`.
//!
//! `chief.profile.history` lists a Chief's kept revisions (every committed
//! state, with who made it); `chief.profile.undo` makes the record equal to
//! one of them again as a new revision, through the same rules as
//! `chief.profile.update` with the fields that differ (capability
//! `chief-profile-history-v1`). A record the person `locked` refuses every
//! Chief's write (`chief_locked`); only the person sets `locked`, which is a
//! gesture field for the page. A Chief's `engine` self_edit item covers its
//! `harness`, `model` and `effort`, with the harness one of its own
//! `harnesses`. A committed change of a record's engine is written into that
//! Chief's brain engine file (chief_engine_mirror.rs).
//!
//! `chief.profile.avatar.set` / `.get` are thin aliases of
//! `participant.avatar.*` for a Chief (participant_avatars.rs): the same
//! store, the same rules, the result shapes of before. The picture's type
//! comes from its bytes; a `media_type` the alias's caller sends must match
//! them (else validation.invalid, as before).

use std::sync::Arc;

use base64::Engine as _;
use base64::engine::general_purpose::STANDARD;
use serde_json::{Map, Value, json};

use super::{
    ClientTransport, MessageWriter, Mux, MuxEvent, ResourceError, ResourceOperation,
    send_resource_response,
};
use crate::chief_registry::{self, AvatarChange, ChiefStore, Refusal};
use crate::conversation_store::{ConversationEvent, LOCAL_USER};
use crate::resource_router::ParsedResourceRequest;
use crate::workspace_registry::Actor;

use ResourceOperation as Op;

pub(super) const fn handles(operation: ResourceOperation) -> bool {
    matches!(
        operation,
        Op::ChiefProfileList
            | Op::ChiefProfileGet
            | Op::ChiefProfileCreate
            | Op::ChiefProfileAdopt
            | Op::ChiefProfileUpdate
            | Op::ChiefProfileDelete
            | Op::ChiefProfileAvatarSet
            | Op::ChiefProfileAvatarGet
            | Op::ChiefProfileHistory
            | Op::ChiefProfileUndo
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

/// The `chief-changed` event on `subscribe` (cx-ebm.60.4): Home and the
/// Channels page redraw their Chiefs on it instead of polling.
pub const CHIEF_EVENTS_CAPABILITY: &str = "chief-events-v1";

/// `chief.profile.adopt`: the owner makes an existing agent participant a
/// Chief record under its own id.
pub const CHIEF_PROFILE_ADOPT_CAPABILITY: &str = "chief-profile-adopt-v1";

/// `chief.profile.history`, `chief.profile.undo`, the record's `locked` and
/// the `engine` self_edit item (u2586).
pub const CHIEF_PROFILE_HISTORY_CAPABILITY: &str = "chief-profile-history-v1";

/// Revisions `chief.profile.history` answers when the caller names no limit.
const HISTORY_DEFAULT_LIMIT: i64 = 20;

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

thread_local! {
    /// A new Chief's brain outcome from `mutate`, waited for by `answer`
    /// after the registry lock is released (the supervisor reads the
    /// registry to start the brain).
    static PENDING_BRAIN: std::cell::RefCell<Option<crate::chief_brains::BrainPending>> =
        const { std::cell::RefCell::new(None) };
    /// A renamed Chief (id, new name, rev) from `mutate`, whose own
    /// conversation `answer` retitles once the registry lock is released.
    static PENDING_RETITLE: std::cell::RefCell<Option<(String, String, u64)>> =
        const { std::cell::RefCell::new(None) };
}

/// The answer, with a new Chief's `brain` (what happened to its brain, from
/// the supervisor's real state) in the created record.
fn answer(mux: &Mux, client: u64, request: &ParsedResourceRequest) -> Result<Value, ResourceError> {
    PENDING_BRAIN.with(|slot| slot.borrow_mut().take());
    PENDING_RETITLE.with(|slot| slot.borrow_mut().take());
    let result = answer_locked(mux, client, request);
    if let Some((chief, name, rev)) = PENDING_RETITLE.with(|slot| slot.borrow_mut().take())
        && result.is_ok()
    {
        retitle_own_conversation(mux, &chief, &name, rev);
    }
    let pending = PENDING_BRAIN.with(|slot| slot.borrow_mut().take());
    match (result, pending) {
        (Ok(mut value), Some(pending)) => {
            if let Some(record) = value.get_mut("value").and_then(Value::as_object_mut) {
                record.insert("brain".into(), pending.resolve().wire());
            }
            Ok(value)
        }
        (result, _) => result,
    }
}

fn answer_locked(
    mux: &Mux,
    client: u64,
    request: &ParsedResourceRequest,
) -> Result<Value, ResourceError> {
    let operation = request.envelope.operation;
    let fields = &request.fields;
    // The participant an adopt names, read before the registry lock (the
    // conversation store has its own lock; never both at once).
    let adoptee = match operation {
        Op::ChiefProfileAdopt => Some(adoptee(mux, operation, fields)?),
        _ => None,
    };
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
                let deleted = store.deleted().map_err(|e| internal(operation, &e))?;
                Ok(json!({"chiefs": chiefs, "deleted": deleted}))
            }
            Op::ChiefProfileGet => {
                let chief = chief_field(fields);
                match store.get(chief).map_err(|e| internal(operation, &e))? {
                    Some(record) => Ok(chief_registry::wire(&record)),
                    None => Err(refused(operation, &Refusal::NotFound)),
                }
            }
            Op::ChiefProfileHistory => {
                let chief = chief_field(fields);
                if store.get(chief).map_err(|e| internal(operation, &e))?.is_none() {
                    return Err(refused(operation, &Refusal::NotFound));
                }
                let limit =
                    fields.get("limit").and_then(Value::as_i64).unwrap_or(HISTORY_DEFAULT_LIMIT);
                let revisions: Vec<Value> = store
                    .history(chief, limit)
                    .map_err(|e| internal(operation, &e))?
                    .iter()
                    .map(chief_registry::Revision::wire)
                    .collect();
                Ok(json!({"chief": chief, "revisions": revisions}))
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
            _ => {
                let key = request.envelope.idempotency_key.clone().unwrap_or_default();
                mutate(
                    mux,
                    client,
                    store,
                    &caller,
                    &request.actor,
                    request.envelope.origin.as_ref().is_some_and(|origin| {
                        origin.claim == crate::request_origin::RequestOrigin::Agent
                    }),
                    RegistryWrite { operation, fields, key, adoptee: adoptee.as_ref() },
                )
            }
        }
    })
}

/// `participant.avatar.set` for a Chief: the `chief.profile.avatar.set`
/// write (its callers, its self_edit rule, its ledger and the brain
/// supervisor's `chief_written`), with the fields `chief` and `data` or
/// `clear`. The committed write's result (`value` is the Chief record).
pub(super) fn set_chief_avatar(
    mux: &Mux,
    client: u64,
    fields: &Map<String, Value>,
    key: String,
    agent_claim: bool,
) -> Result<Value, ResourceError> {
    let operation = Op::ChiefProfileAvatarSet;
    with_store(mux, operation, |store| {
        let caller = caller(mux, client, store)?;
        let request_actor = super::origin_gate::connection_actor(mux, client);
        mutate(
            mux,
            client,
            store,
            &caller,
            &request_actor,
            agent_claim,
            RegistryWrite { operation, fields, key, adoptee: None },
        )
    })
}

/// A Chief's avatar and bytes for any reader (`participant.avatar.get`):
/// `None` for no picture, or no live Chief of that id.
pub(super) fn chief_avatar(
    mux: &Mux,
    operation: Op,
    chief: &str,
) -> Result<chief_registry::AvatarBytes, ResourceError> {
    with_store(mux, operation, |store| match store.avatar(chief) {
        Ok(Ok(found)) => Ok(found),
        Ok(Err(_)) => Ok(None),
        Err(e) => Err(internal(operation, &e)),
    })
}

/// A person's avatar and bytes from the shared store.
pub(super) fn person_avatar(
    mux: &Mux,
    operation: Op,
    participant: &str,
) -> Result<chief_registry::AvatarBytes, ResourceError> {
    with_store(mux, operation, |store| {
        store.person_avatar(participant).map_err(|e| internal(operation, &e))
    })
}

/// Sets or clears a person's avatar in the shared store, once per key (the
/// caller's rule is participant_avatars.rs's).
pub(super) fn set_person_avatar(
    mux: &Mux,
    operation: Op,
    participant: &str,
    key: &str,
    request: &Value,
    change: AvatarChange,
) -> Result<chief_registry::PersonAvatarWrite, ResourceError> {
    with_store(mux, operation, |store| {
        match store.set_person_avatar(participant, key, request, change) {
            Ok(Ok(write)) => Ok(write),
            Ok(Err(Refusal::KeyConflict(committed))) => {
                Err(ResourceError::idempotency_conflict(key, &committed))
            }
            Ok(Err(refusal)) => Err(refused(operation, &refusal)),
            Err(e) => Err(internal(operation, &e)),
        }
    })
}

/// One registry write: the operation, its fields, its idempotency key and,
/// for `chief.profile.adopt`, the participant it names.
struct RegistryWrite<'a> {
    operation: Op,
    fields: &'a Map<String, Value>,
    key: String,
    adoptee: Option<&'a Adoptee>,
}

fn mutate(
    mux: &Mux,
    client: u64,
    store: &mut ChiefStore,
    caller: &Caller,
    request_actor: &Actor,
    agent_claim: bool,
    write: RegistryWrite<'_>,
) -> Result<Value, ResourceError> {
    let RegistryWrite { operation, fields, key, adoptee } = write;
    // Owner only, from a terminal, before anything else is checked: no page
    // (a WebSocket or the host's page relay, with or without a page id), no
    // Chief, no paired or remote device (caller() refuses those).
    if operation == Op::ChiefProfileAdopt
        && (*caller != Caller::Owner
            || super::origin_gate::connection_page(mux, client).is_some()
            || super::origin_gate::is_page(mux, client))
    {
        return Err(forbidden_adopt());
    }
    if key.is_empty() {
        return Err(ResourceError::validation_invalid(
            Some("idempotency_key"),
            "a mutation needs an idempotency key",
        ));
    }
    let mut profile: Map<String, Value> = fields
        .iter()
        .filter(|(k, _)| {
            !matches!(
                k.as_str(),
                "chief"
                    | "expected_rev"
                    | "media_type"
                    | "data"
                    | "clear"
                    | "participant_id"
                    | "to_rev"
            )
        })
        .map(|(k, v)| (k.clone(), v.clone()))
        .collect();
    if let Some(refusal) = chief_registry::validate_fields(&profile) {
        return Err(refused(operation, &refusal));
    }
    if agent_claim && profile.contains_key("locked") {
        return Err(ResourceError::operation_failed(
            operation.wire_name(),
            "chief_lock_person_only",
            json!({"message": "only the person can lock or unlock a Chief", "fields": ["locked"]}),
        ));
    }
    let chief = chief_field(fields).to_owned();
    let expected_rev = fields.get("expected_rev").and_then(Value::as_u64);
    // The record before an edit: an edit that changes nothing keeps the rev
    // (no chief-changed for it); only a changed name retitles (cx-di8pd);
    // only a changed picture publishes; only a changed engine is mirrored.
    let before = match operation {
        Op::ChiefProfileUpdate
        | Op::ChiefProfileAvatarSet
        | Op::ChiefProfileUndo
        | Op::ChiefProfileDelete => store.get(&chief).map_err(|e| internal(operation, &e))?,
        _ => None,
    };
    if agent_claim
        && before.as_ref().is_some_and(|record| record.locked)
        && !matches!(operation, Op::ChiefProfileCreate)
    {
        return Err(ResourceError::operation_failed(
            operation.wire_name(),
            "chief_locked",
            json!({"message": "the person locked this Chief; only they change it", "fields": []}),
        ));
    }
    let mut avatar = match operation {
        Op::ChiefProfileAvatarSet => Some(avatar_change(operation, fields)?),
        _ => None,
    };
    // An undo is an update to a kept revision's fields: the same checks.
    if operation == Op::ChiefProfileUndo {
        let Some(current) = before.as_ref() else {
            return Err(refused(operation, &Refusal::NotFound));
        };
        let (fields_back, picture_back) = undo_fields(store, operation, current, fields)?;
        profile = fields_back;
        avatar = picture_back;
    }
    let check_operation =
        if operation == Op::ChiefProfileUndo { Op::ChiefProfileUpdate } else { operation };
    // The rule checks see a picture change as the field `avatar`.
    let mut checked = profile.clone();
    if operation == Op::ChiefProfileUndo && avatar.is_some() {
        checked.insert("avatar".into(), Value::Bool(true));
    }
    // A Chief on itself keeps the person's self_edit rule; on another Chief
    // or a create, its `chiefs` grant and ceiling (chief_manage.rs).
    let manages = match caller {
        Caller::Chief(me)
            if matches!(check_operation, Op::ChiefProfileUpdate | Op::ChiefProfileAvatarSet)
                && chief == *me =>
        {
            self_edit_allowed(store, check_operation, me, &chief, &checked)?;
            false
        }
        Caller::Chief(me) => {
            super::chief_manage::check(store, check_operation, me, &chief, &mut checked)?;
            // A create's grant defaults filled from the caller are written.
            if operation == Op::ChiefProfileCreate {
                profile = checked.clone();
            }
            true
        }
        _ => false,
    };
    let rev_before = before.as_ref().map(|record| record.rev);
    let name_before = before.as_ref().map(|record| record.display_name.clone());
    let picture_before =
        before.as_ref().and_then(|record| record.avatar.as_ref()).map(|a| a.sha256.clone());
    let engine_before = before.as_ref().map(|record| record.engine.clone());
    if *caller == Caller::Page
        && (matches!(operation, Op::ChiefProfileCreate | Op::ChiefProfileDelete)
            || chief_registry::names_gesture_field(&checked))
    {
        return Err(crate::request_origin::forbidden(
            "creating or deleting a Chief, or changing its instructions, personality, tools, harnesses, engine or self-edit rights, needs the person's gesture in the cmux app",
            json!({"derived": "agent", "required": "user", "reason": "gesture_required"}),
        ));
    }
    let actor = match caller {
        Caller::Chief(me) if manages => super::chief_manage::actor(me),
        _ => audit_actor(mux, client, caller, request_actor, agent_claim),
    };
    let body = json!({"operation": operation.wire_name(), "fields": Value::Object(fields.clone())});
    let outcome = store
        .mutate(&actor, &key, operation.wire_name(), &body, |tx| match operation {
            Op::ChiefProfileCreate => match caller {
                Caller::Chief(me) if manages => chief_registry::create_by_chief(tx, &profile, me),
                _ => chief_registry::create(tx, &profile),
            },
            Op::ChiefProfileAdopt => match adoptee {
                Some(Adoptee { id, display_name: Some(name) }) => {
                    chief_registry::adopt(tx, id, name, &profile, || {
                        mux.claim_unbound_participant(id)
                    })
                }
                Some(Adoptee { id, .. }) if id == chief_registry::DEFAULT_CHIEF => {
                    Ok(Err(Refusal::DefaultChief))
                }
                _ => Ok(Err(Refusal::NotAgentParticipant)),
            },
            Op::ChiefProfileUpdate => {
                chief_registry::update(tx, &chief, expected_rev, &profile, None)
            }
            Op::ChiefProfileAvatarSet => {
                chief_registry::update(tx, &chief, expected_rev, &Map::new(), avatar)
            }
            Op::ChiefProfileUndo => {
                chief_registry::update(tx, &chief, expected_rev, &profile, avatar)
            }
            _ => chief_registry::delete(tx, &chief, expected_rev),
        })
        .map_err(|e| internal(operation, &e))?;
    match outcome {
        Ok((record, replayed)) => {
            if !replayed
                && matches!(operation, Op::ChiefProfileAvatarSet | Op::ChiefProfileUndo)
                && picture_before.as_deref() != record.avatar.as_ref().map(|a| a.sha256.as_str())
            {
                super::participant_avatars::publish(mux, &record.id, record.avatar.as_ref());
            }
            // A delete answers the record as it was (same rev): it is still a change.
            if !replayed && (operation == Op::ChiefProfileDelete || rev_before != Some(record.rev))
            {
                let change = match operation {
                    Op::ChiefProfileCreate | Op::ChiefProfileAdopt => "created",
                    Op::ChiefProfileDelete => "deleted",
                    _ => "updated",
                };
                mux.emit(MuxEvent::Conversation(Arc::new(ConversationEvent::Chief {
                    chief: record.id.clone(),
                    change,
                })));
                if matches!(operation, Op::ChiefProfileUpdate | Op::ChiefProfileUndo)
                    && name_before.as_deref() != Some(record.display_name.as_str())
                {
                    PENDING_RETITLE.with(|slot| {
                        *slot.borrow_mut() =
                            Some((record.id.clone(), record.display_name.clone(), record.rev));
                    });
                }
            }
            let created = matches!(operation, Op::ChiefProfileCreate | Op::ChiefProfileAdopt);
            let engine_changed = match &engine_before {
                Some(engine) => *engine != record.engine,
                None => created && record.engine != chief_registry::Engine::default(),
            };
            if !replayed && operation != Op::ChiefProfileDelete && engine_changed {
                super::chief_engine_mirror::mirror(&record);
            }
            if !replayed
                && let Some(pending) = mux.chiefs().brains.chief_written(
                    &record,
                    matches!(operation, Op::ChiefProfileCreate | Op::ChiefProfileAdopt),
                    operation == Op::ChiefProfileDelete,
                )
            {
                // Resolved by `answer` once the registry lock is released.
                PENDING_BRAIN.with(|slot| *slot.borrow_mut() = Some(pending));
            }
            let (_, generation) = mux.registry_identity();
            Ok(json!({"value": chief_registry::wire(&record), "generation": generation,
                      "revision": record.rev.to_string(), "replayed": replayed}))
        }
        Err(Refusal::KeyConflict(committed)) => {
            Err(ResourceError::idempotency_conflict(&key, &committed))
        }
        Err(Refusal::ParticipantBound) => Err(ResourceError::operation_failed(
            operation.wire_name(),
            Refusal::ParticipantBound.reason(),
            json!({"message": "stop its current agent session first",
                   "hint": "stop its current agent session first"}),
        )),
        Err(refusal) => Err(refused(operation, &refusal)),
    }
}

/// The actor the ledger records for a write: a page's write (a page
/// WebSocket, or the host's page relay) is told apart from a terminal's,
/// `user_local via page:<page>` (`user_local via websocket` for a page with no
/// page id); a Chief is its own id.
fn audit_actor(
    mux: &Mux,
    client: u64,
    caller: &Caller,
    request_actor: &Actor,
    agent_claim: bool,
) -> String {
    // The daemon's verified request actor carries the ACP session identity for
    // agent-originated writes. Keep the exact wire prefix in history so a
    // person can distinguish an agent change from a person change without
    // trusting a caller-supplied profile field.
    if agent_claim {
        return "agent".to_owned();
    }
    if let Actor::AcpSession { .. } = request_actor {
        return request_actor.wire();
    }
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
    if record.locked {
        return Err(ResourceError::operation_failed(
            operation.wire_name(),
            "chief_locked",
            json!({"message": "the person locked this Chief; only they change it", "fields": []}),
        ));
    }
    let wanted: Vec<String> = match operation {
        Op::ChiefProfileAvatarSet => vec!["avatar".to_owned()],
        _ => profile.keys().cloned().collect(),
    };
    let denied: Vec<String> = wanted
        .into_iter()
        .filter(|field| {
            !record.self_edit.iter().any(|item| item == chief_registry::self_edit_item(field))
        })
        .collect();
    if !denied.is_empty() {
        return deny(
            denied,
            "the person has not allowed this Chief to change these fields; ask them",
        );
    }
    // Its own engine: a harness among its own (an empty list is every one).
    if let Some(harness) = profile.get("harness").and_then(Value::as_str)
        && !harness.is_empty()
        && harness != "default"
        && !record.harnesses.is_empty()
        && !record.harnesses.iter().any(|h| h == harness)
    {
        return deny(
            vec!["harness".to_owned()],
            "that harness is not one this Chief may use; the person grants harnesses",
        );
    }
    Ok(())
}

/// `chief.profile.undo`'s fields: those that make `current` equal to kept
/// revision `to_rev` (default: the one before the current), and the picture
/// change when the pictures differ.
fn undo_fields(
    store: &ChiefStore,
    operation: Op,
    current: &chief_registry::ChiefRecord,
    fields: &Map<String, Value>,
) -> Result<(Map<String, Value>, Option<AvatarChange>), ResourceError> {
    let revisions = store
        .history(&current.id, chief_registry::HISTORY_PER_CHIEF)
        .map_err(|e| internal(operation, &e))?;
    let target = match fields.get("to_rev") {
        Some(rev) => {
            let rev = rev.as_u64().ok_or_else(|| {
                ResourceError::validation_invalid(Some("to_rev"), "to_rev must be a revision")
            })?;
            revisions.iter().find(|r| r.rev == rev)
        }
        None => revisions.iter().find(|r| r.rev < current.rev),
    };
    let Some(target) = target else {
        return Err(refused(operation, &Refusal::NoRevision));
    };
    let restored = chief_registry::fields_to_restore(current, &target.record);
    let then = target.record.avatar.as_ref();
    let picture = if current.avatar.as_ref().map(|a| &a.sha256) == then.map(|a| &a.sha256) {
        None
    } else {
        match then {
            None => Some(AvatarChange::Clear),
            Some(avatar) => {
                let bytes = store
                    .avatar_bytes(&avatar.sha256)
                    .map_err(|e| internal(operation, &e))?
                    .ok_or_else(|| refused(operation, &Refusal::NoRevision))?;
                Some(AvatarChange::Set { media_type: avatar.media_type.clone(), bytes })
            }
        }
    };
    Ok((restored, picture))
}

/// The avatar change of a request: `data` (base64; the type comes from the
/// bytes), or `clear: true`.
pub(super) fn avatar_change(
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
            // The alias takes media_type as before: one of the four types, and the
            // bytes' own. participant.avatar.set takes the type from the bytes only.
            let claimed = fields.get("media_type").and_then(Value::as_str);
            if operation == Op::ChiefProfileAvatarSet
                && !claimed.is_some_and(|t| chief_registry::AVATAR_TYPES.contains(&t))
            {
                return Err(refused(
                    operation,
                    &Refusal::Invalid(
                        "media_type",
                        "must be image/png, image/jpeg, image/gif or image/webp".into(),
                    ),
                ));
            }
            let media_type =
                chief_registry::validate_avatar(&bytes).map_err(|r| refused(operation, &r))?;
            if let Some(claimed) = claimed
                && claimed != media_type
            {
                return Err(refused(
                    operation,
                    &Refusal::Invalid("data", format!("is not a {claimed} image")),
                ));
            }
            Ok(AvatarChange::Set { media_type: media_type.to_owned(), bytes })
        }
        _ => Err(ResourceError::validation_invalid(
            Some("data"),
            "give data (a PNG, JPEG, GIF or WebP picture), or clear: true",
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

/// cx-di8pd: a renamed Chief's own conversation takes its new name as its
/// title, so every reader of the title (Home's header and list, the CLI, a
/// page) follows the registry; the brain titled it with the old name when it
/// made it. Its own conversation is the brain's rule (optchat-chief
/// `select_chief_of`): the default Chief's oldest conversation, another
/// Chief's oldest DM with the person (paired devices of the person count as
/// the person). A later conversation with the Chief (a channel, a group)
/// keeps its title. One `title.set` by the person, keyed by the record's
/// rev, published like any op. Best effort: a failure is logged and the
/// rename stands.
fn retitle_own_conversation(mux: &Mux, chief: &str, name: &str, rev: u64) {
    let listed = mux.with_conversations(|store| store.list());
    let own = match listed {
        Ok(listed) => own_conversation(listed, chief),
        Err(error) => {
            eprintln!("cmux-tui: Chief {chief} renamed; listing its conversations: {error:#}");
            return;
        }
    };
    let Some(own) = own.filter(|own| own.title != name) else { return };
    let op = cmux_conversation::Op::TitleSet { title: name.to_owned() };
    let key = format!("chief-rename-{chief}-{rev}");
    if let Err(error) = super::conversations::commit_op(mux, &own.id, &key, LOCAL_USER, &op, &None)
    {
        eprintln!("cmux-tui: Chief {chief} renamed; retitling {}: {error:#}", own.id);
    }
}

/// The conversation `chief` answers in (see [`retitle_own_conversation`]).
fn own_conversation(
    listed: Vec<cmux_conversation::Summary>,
    chief: &str,
) -> Option<cmux_conversation::Summary> {
    let person = |p: &cmux_conversation::Participant| {
        p.id == LOCAL_USER || p.person.as_deref() == Some(LOCAL_USER)
    };
    listed
        .into_iter()
        .filter(|c| c.participants.iter().any(|p| p.id == chief))
        .filter(|c| {
            chief == chief_registry::DEFAULT_CHIEF
                || (c.participants.iter().any(|p| p.id == LOCAL_USER)
                    && c.participants.iter().all(|p| p.id == chief || person(p)))
        })
        .min_by(|a, b| (&a.created_at, &a.id).cmp(&(&b.created_at, &b.id)))
}

/// `chief.engine.set` on a Chief's brain committed `choice` (its engine.json):
/// the record takes the same harness, model and effort, so the record stays
/// the backend's one source (the brain already has the file, so nothing is
/// mirrored back). The person's write (actor `user_local via chief.engine.set`),
/// kept in the history. Best effort: a failure is logged.
pub(super) fn record_brain_engine(mux: &Mux, chief: &str, choice: &Value) {
    let text = |key: &str| choice.get(key).and_then(Value::as_str).unwrap_or("").to_owned();
    let mut fields = Map::new();
    for key in ["harness", "model", "effort"] {
        fields.insert(key.into(), json!(text(key)));
    }
    if chief_registry::validate_fields(&fields).is_some() {
        return;
    }
    let operation = Op::ChiefProfileUpdate;
    let outcome = with_store(mux, operation, |store| {
        let Some(before) = store.get(chief).map_err(|e| internal(operation, &e))? else {
            return Ok(None);
        };
        let nanos = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map_or(0, |d| d.as_nanos());
        let key = format!("chief-engine-set-{chief}-{nanos}");
        let body =
            json!({"operation": "chief.engine.set", "fields": Value::Object(fields.clone())});
        let actor = format!("{LOCAL_USER} via chief.engine.set");
        let written = store
            .mutate(&actor, &key, operation.wire_name(), &body, |tx| {
                chief_registry::update(tx, chief, None, &fields, None)
            })
            .map_err(|e| internal(operation, &e))?;
        Ok(match written {
            Ok((record, _)) if record.rev != before.rev => Some(record),
            _ => None,
        })
    });
    match outcome {
        Ok(Some(record)) => {
            mux.emit(MuxEvent::Conversation(Arc::new(ConversationEvent::Chief {
                chief: record.id.clone(),
                change: "updated",
            })));
            mux.chiefs().brains.chief_written(&record, false, false);
        }
        Ok(None) => {}
        Err(error) => eprintln!("cmux-tui: Chief {chief} engine into its record: {error:?}"),
    }
}

/// Every Chief's current name by participant id, for the Home rows
/// (`home-inbox`). Best effort: a registry that cannot open gives none, and
/// the rows fall back to the conversations' titles.
pub(super) fn chief_names(mux: &Mux) -> std::collections::BTreeMap<String, String> {
    with_store(mux, Op::ChiefProfileList, |store| {
        store.list().map_err(|error| internal(Op::ChiefProfileList, &error))
    })
    .map(|records| records.into_iter().map(|record| (record.id, record.display_name)).collect())
    .unwrap_or_default()
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
    match store.as_mut() {
        Some(store) => run(store),
        None => Err(internal(operation, &anyhow::anyhow!("chief registry is not open"))),
    }
}

/// `conversation-agent-token`'s mint, under the registry lock (lock order:
/// registry, then the conversation store, as `chief.profile.adopt`): for a
/// live Chief record other than the default Chief, refused while a brain
/// supervisor runs (its brain holds the credential) and refused unless
/// `terminal` (the person's own terminal: no page, no paired or remote
/// device); any other participant mints as before. An unreadable registry
/// refuses the mint (fail closed).
pub(super) fn mint_credential(
    mux: &Mux,
    participant: &str,
    terminal: bool,
) -> anyhow::Result<String> {
    let operation = Op::ChiefProfileGet;
    let minted = with_store(mux, operation, |store| {
        let chief = participant != chief_registry::DEFAULT_CHIEF
            && participant.starts_with("agent_")
            && store.get(participant).map_err(|e| internal(operation, &e))?.is_some();
        if chief && crate::chief_brains::taken().is_some() {
            return Ok(Err(format!("{participant} is a Chief: its brain holds its credential")));
        }
        if chief && !terminal {
            return Ok(Err(
                "only the person, from a terminal on this machine, mints a Chief's credential"
                    .to_owned(),
            ));
        }
        mux.with_conversations(|conversations| conversations.mint_agent_token(participant))
            .map(Ok)
            .map_err(|e| internal(operation, &e))
    })
    .map_err(|e| anyhow::anyhow!("{e}"))?;
    minted.map_err(|refusal| anyhow::anyhow!(refusal))
}

/// The participant `chief.profile.adopt` names: its id, and its display name
/// when it is an agent participant of a local conversation.
struct Adoptee {
    id: String,
    display_name: Option<String>,
}

fn adoptee(
    mux: &Mux,
    operation: Op,
    fields: &Map<String, Value>,
) -> Result<Adoptee, ResourceError> {
    let id = fields.get("participant_id").and_then(Value::as_str).unwrap_or("").to_owned();
    let shaped = id.strip_prefix("agent_").is_some_and(|rest| {
        (1..=64).contains(&rest.len())
            && rest.bytes().all(|b| b.is_ascii_alphanumeric() || b"_.-".contains(&b))
    });
    if !shaped {
        // A person, or no participant id at all: never a Chief.
        return Ok(Adoptee { id, display_name: None });
    }
    let summaries =
        mux.with_conversations(|store| store.list()).map_err(|e| internal(operation, &e))?;
    let display_name = summaries
        .iter()
        .flat_map(|summary| summary.participants.iter())
        .find(|p| p.id == id && p.kind == cmux_conversation::ParticipantKind::Agent)
        .map(|p| p.display_name.clone())
        .filter(|name| !name.trim().is_empty());
    Ok(Adoptee { id, display_name })
}

fn forbidden_adopt() -> ResourceError {
    crate::request_origin::forbidden(
        "only the person, from a terminal on this machine, adopts an agent as a Chief",
        json!({"derived": "agent", "required": "user", "reason": "chief_adopt_owner_only"}),
    )
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

#[cfg(test)]
#[path = "chief_adopt_tests.rs"]
mod adopt_tests;
