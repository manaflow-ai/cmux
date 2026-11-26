//! `HomeChiefDirectMessages` (CmuxNextHomeEngine/HomeChiefDirectMessages.swift): the person's direct
//! message with each of this Mac's Chiefs. The app makes the owner calls (`chief.profile.list`,
//! `conversation-create`); these rules read the list and build each request.

use serde::Serialize;
use serde_json::{Value, json};

/// The default Chief's participant id (`HomeChiefName.muxID`): Home keeps its conversation.
pub const MUX_ID: &str = "agent_mux";

/// The one idempotency key of the person's direct message with `chief`.
pub fn key(chief: &str) -> String {
    format!("home-chief-dm-{chief}")
}

/// The `conversation-create` request (wire JSON) of the person's direct message with `chief`,
/// titled `name`; `me` is the local user's participant as the app encodes it.
pub fn request(me: &Value, chief: &str, name: &str) -> Value {
    json!({
        "idempotency_key": key(chief),
        "title": name,
        "participants": [
            me,
            {"id": chief, "kind": "agent", "display_name": name, "agent_class": "mux"},
        ],
    })
}

/// One Chief record of `chief.profile.list`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct Record {
    pub id: String,
    pub name: String,
}

/// Each Chief record's id and display name, in the owner's order (`records(_:)`): the result's
/// `chiefs`, under `value` when the reply wraps it; a record with no id is skipped, one with no
/// display name is named by its id.
pub fn records(listed: &Value) -> Vec<Record> {
    let Some(reply) = listed.as_object() else { return Vec::new() };
    let object = reply.get("value").and_then(Value::as_object).unwrap_or(reply);
    let Some(chiefs) = object.get("chiefs").and_then(Value::as_array) else { return Vec::new() };
    chiefs
        .iter()
        .filter_map(|chief| {
            let record = chief.as_object()?;
            let id = record.get("id")?.as_str().filter(|id| !id.is_empty())?;
            let name = record
                .get("display_name")
                .and_then(Value::as_str)
                .filter(|name| !name.is_empty())
                .unwrap_or(id);
            Some(Record { id: id.to_owned(), name: name.to_owned() })
        })
        .collect()
}

/// The Chiefs whose direct message `open(missingFrom:)` opens: every record but the default Chief
/// and those in `listed` (the Chiefs that already have a conversation here), in the owner's order.
pub fn missing(all: &Value, listed: &[String]) -> Vec<Record> {
    records(all)
        .into_iter()
        .filter(|record| record.id != MUX_ID && !listed.contains(&record.id))
        .collect()
}
