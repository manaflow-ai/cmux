//! A Chief that makes and edits other Chiefs (Lawrence
//! 2026-10-14: "ensure that chiefs ... have tools (via cli/mcp) to make and
//! edit other chiefs"). hq .cmux-scratch/hqec-slack/CHIEF-TOOLS.md.
//!
//! The caller is a Chief only by the daemon's own proof: a Unix connection
//! bound to a live record with that Chief's minted participant token
//! (chief_registry_resource.rs `caller`); no env and no client claim counts.
//! With the `chiefs` tool in its record a Chief may create a Chief and change
//! another Chief's profile and picture, never beyond its own grant:
//!
//! - a new or edited record's grant is within the caller's: `tools` and
//!   `self_edit` are subsets; `harnesses` is any when the caller's is empty
//!   (every harness), else a non-empty subset; each engine field (harness,
//!   model, effort) equals the caller's (unset only when the caller's is);
//! - a Chief another Chief made (`created_by`) may be edited fully; a Chief
//!   the person made (no `created_by`, every older record) only in its
//!   name, role and picture (lead decision 2026-10-14); an edit needs the
//!   target's CURRENT grant within the caller's too;
//! - a Chief never edits itself here (the self_edit path takes `chief == me`);
//! - the default Chief's grant is never a Chief's to change;
//! - no Chief deletes a Chief;
//! - a create fills the grant fields it omits from the caller (the default
//!   tools the caller holds, its harnesses and engine fields, the default
//!   self_edit it holds), so a plain create succeeds inside the ceiling;
//!
//! A Chief changing itself keeps the person's `self_edit` rule
//! (chief_registry_resource.rs); `chiefs` does not widen it.

use serde_json::{Map, Value, json};

use super::{ResourceError, ResourceOperation};
use crate::chief_registry::{
    self, ChiefRecord, ChiefStore, DEFAULT_CHIEF, DEFAULT_NEW_TOOLS, GRANT_FIELDS, Refusal,
};

use ResourceOperation as Op;

/// The tool name in a record's `tools` that carries the right.
const GRANT: &str = "chiefs";

/// What a Chief may change on a Chief the person made (and the picture).
const PERSON_MADE_FIELDS: [&str; 2] = ["display_name", "role"];

/// Checks a write the Chief `me` makes on another Chief (or a create), and
/// for a create fills the omitted grant fields of `profile` from the caller.
/// `Err` is the typed refusal; nothing is written then.
pub(super) fn check(
    store: &ChiefStore,
    operation: Op,
    me: &str,
    chief: &str,
    profile: &mut Map<String, Value>,
) -> Result<(), ResourceError> {
    let caller = load(store, operation, me)?;
    if !matches!(
        operation,
        Op::ChiefProfileCreate | Op::ChiefProfileUpdate | Op::ChiefProfileAvatarSet
    ) {
        return Err(deny(operation, "chief_delete_denied", "only the person deletes a Chief", &[]));
    }
    if !caller.tools.iter().any(|t| t == GRANT) {
        return Err(deny(
            operation,
            "chief_manage_denied",
            "this Chief has no chiefs tool; the person grants it",
            &[],
        ));
    }
    if operation == Op::ChiefProfileCreate {
        fill_create_defaults(&caller, profile);
        let draft = ChiefRecord {
            id: String::new(),
            display_name: String::new(),
            role: String::new(),
            personality: String::new(),
            instructions: String::new(),
            avatar: None,
            tools: Vec::new(),
            harnesses: Vec::new(),
            engine: chief_registry::Engine::default(),
            self_edit: Vec::new(),
            is_default: false,
            rev: 0,
            created_at: String::new(),
            updated_at: String::new(),
            created_by: None,
        };
        let wanted = chief_registry::preview(&draft, profile);
        return within(operation, "grant_exceeds_caller", &caller, &wanted);
    }
    let target = load(store, operation, chief)?;
    if target.id == DEFAULT_CHIEF {
        let named: Vec<&str> =
            GRANT_FIELDS.iter().copied().filter(|f| profile.contains_key(*f)).collect();
        if !named.is_empty() {
            return Err(deny(
                operation,
                "chief_default_grant",
                "the default Chief's grant is the person's",
                &named,
            ));
        }
    }
    // A Chief the person made (no `created_by`, every record from before):
    // only its name, role and picture. Its instructions, personality, grant
    // and engine stay the person's, so no Chief plants instructions in a
    // Chief that may read conversations the caller cannot, and no twin
    // rewrites a person-made creator's text past its self_edit.
    if target.created_by.is_none() {
        let named: Vec<&str> = profile
            .keys()
            .map(String::as_str)
            .filter(|f| !PERSON_MADE_FIELDS.contains(f))
            .collect();
        if !named.is_empty() {
            return Err(deny(
                operation,
                "chief_person_made_fields",
                "a Chief changes only the name, role and picture of a Chief the person made",
                &named,
            ));
        }
    }
    within(operation, "target_exceeds_caller", &caller, &target)?;
    let next = chief_registry::preview(&target, profile);
    within(operation, "grant_exceeds_caller", &caller, &next)
}

/// The ledger actor of a Chief's write on another Chief or a create.
pub(super) fn actor(me: &str) -> String {
    format!("{me} via chief")
}

/// Omitted grant fields of a Chief's create, from the caller's grant.
fn fill_create_defaults(caller: &ChiefRecord, profile: &mut Map<String, Value>) {
    let holds = |set: &[String], item: &str| set.iter().any(|s| s == item);
    if !profile.contains_key("tools") {
        let tools: Vec<&str> =
            DEFAULT_NEW_TOOLS.iter().copied().filter(|t| holds(&caller.tools, t)).collect();
        profile.insert("tools".into(), json!(tools));
    }
    if !profile.contains_key("harnesses") {
        profile.insert("harnesses".into(), json!(caller.harnesses));
    }
    if !profile.contains_key("self_edit") {
        let mine: Vec<&str> =
            ["avatar"].into_iter().filter(|f| holds(&caller.self_edit, f)).collect();
        profile.insert("self_edit".into(), json!(mine));
    }
    for (field, value) in [
        ("harness", &caller.engine.harness),
        ("model", &caller.engine.model),
        ("effort", &caller.engine.effort),
    ] {
        if let Some(value) = value
            && !profile.contains_key(field)
        {
            profile.insert(field.into(), json!(value));
        }
    }
}

/// `Ok` when `record`'s grant is within `caller`'s, else the fields that are
/// not, under `reason`.
fn within(
    operation: Op,
    reason: &str,
    caller: &ChiefRecord,
    record: &ChiefRecord,
) -> Result<(), ResourceError> {
    let subset = |of: &[String], items: &[String]| items.iter().all(|i| of.contains(i));
    let mut over = Vec::new();
    if !subset(&caller.tools, &record.tools) {
        over.push("tools");
    }
    if !caller.harnesses.is_empty()
        && (record.harnesses.is_empty() || !subset(&caller.harnesses, &record.harnesses))
    {
        over.push("harnesses");
    }
    // Each engine field equals the caller's (unset = the brain default, so
    // an unset caller field allows only unset), and the engine harness is one
    // of the caller's harnesses when it has a list.
    for (field, mine, theirs) in [
        ("harness", &caller.engine.harness, &record.engine.harness),
        ("model", &caller.engine.model, &record.engine.model),
        ("effort", &caller.engine.effort, &record.engine.effort),
    ] {
        if mine != theirs {
            over.push(field);
        }
    }
    if let Some(harness) = &record.engine.harness
        && !caller.harnesses.is_empty()
        && !caller.harnesses.contains(harness)
        && !over.contains(&"harness")
    {
        over.push("harness");
    }
    if !subset(&caller.self_edit, &record.self_edit) {
        over.push("self_edit");
    }
    if over.is_empty() {
        return Ok(());
    }
    let why = if reason == "target_exceeds_caller" {
        "that Chief holds more than this Chief; only the person changes it"
    } else {
        "a Chief gives another Chief only what it holds itself"
    };
    Err(deny(operation, reason, why, &over))
}

fn load(store: &ChiefStore, operation: Op, id: &str) -> Result<ChiefRecord, ResourceError> {
    match store.get(id) {
        Ok(Some(record)) => Ok(record),
        Ok(None) => Err(ResourceError::operation_failed(
            operation.wire_name(),
            Refusal::NotFound.reason(),
            json!({}),
        )),
        Err(e) => Err(ResourceError::operation_failed(
            operation.wire_name(),
            "internal",
            json!({"message": format!("{e:#}")}),
        )),
    }
}

fn deny(operation: Op, reason: &str, why: &str, fields: &[&str]) -> ResourceError {
    ResourceError::operation_failed(
        operation.wire_name(),
        reason,
        json!({"message": why, "fields": fields}),
    )
}
