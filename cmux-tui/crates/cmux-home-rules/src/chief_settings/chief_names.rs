//! Chief names: the renames Home shows before the owner saves them (`HomeChiefNames.swift`), the Chief
//! records' names, the rename requests and their failures (`HomeChiefRenameFailure.swift`), and the chief
//! conversation's name and pick (`HomeChiefName.swift`).

use super::{Strings, strings, trim};
use crate::ops::{self, OpError};
use serde::{Deserialize, Serialize};
use serde_json::{Map, Value, json};
use std::collections::{BTreeMap, BTreeSet};

/// The local mux participant's id.
pub const MUX_ID: &str = "agent_mux";
/// The key of the chief conversation's one-time rename.
pub const RENAME_KEY: &str = "home-chief-title-v1";

fn trimmed(name: &str) -> Option<String> {
    let name = trim(name);
    if name.is_empty() { None } else { Some(name.to_owned()) }
}

/// One rename being saved: the name, and the record names it replaces.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(default)]
pub struct Pending {
    pub name: String,
    pub replaces: BTreeSet<String>,
}

/// The renames being saved, by conversation id.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(default)]
pub struct Names {
    pub pending: BTreeMap<String, Pending>,
}

/// One change to [`Names`].
#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum NamesEvent {
    /// The person renamed `conversation` to `name` while its record says `record`.
    Rename { conversation: String, name: String, record: Option<String> },
    /// The record now says `record`: a pending name that no longer replaces it is saved (or superseded).
    Settle { conversation: String, record: Option<String> },
    /// The save of `name` failed: drop it unless a later rename replaced it.
    RollBack { conversation: String, name: String },
}

impl Names {
    /// The name to show for `conversation`: the pending one while the record still says a name it
    /// replaces, else the record's.
    pub fn name_of(&self, conversation: &str, record: Option<&str>) -> Option<String> {
        let record = record.and_then(trimmed);
        if let Some(pending) = self.pending.get(conversation)
            && pending.replaces.contains(record.as_deref().unwrap_or(""))
        {
            return Some(pending.name.clone());
        }
        record
    }

    /// Every conversation's name: `records` (trimmed) with the pending names over them.
    pub fn all(&self, records: &BTreeMap<String, String>) -> BTreeMap<String, String> {
        let mut names: BTreeMap<String, String> = records
            .iter()
            .filter_map(|(id, name)| trimmed(name).map(|name| (id.clone(), name)))
            .collect();
        for id in self.pending.keys() {
            match self.name_of(id, records.get(id).map(String::as_str)) {
                Some(name) => names.insert(id.clone(), name),
                None => names.remove(id),
            };
        }
        names
    }

    /// The names after `event`.
    pub fn step(mut self, event: &NamesEvent) -> Names {
        match event {
            NamesEvent::Rename { conversation, name, record } => {
                let Some(name) = trimmed(name) else { return self };
                let mut replaces: BTreeSet<String> =
                    [record.as_deref().and_then(trimmed).unwrap_or_default()].into();
                if let Some(earlier) = self.pending.get(conversation) {
                    replaces.extend(earlier.replaces.iter().cloned());
                    replaces.insert(earlier.name.clone());
                }
                replaces.remove(&name);
                self.pending.insert(conversation.clone(), Pending { name, replaces });
            }
            NamesEvent::Settle { conversation, record } => {
                let record = record.as_deref().and_then(trimmed).unwrap_or_default();
                if self
                    .pending
                    .get(conversation)
                    .is_some_and(|entry| !entry.replaces.contains(&record))
                {
                    self.pending.remove(conversation);
                }
            }
            NamesEvent::RollBack { conversation, name } => {
                if self.pending.get(conversation).map(|entry| Some(entry.name.clone()))
                    == Some(trimmed(name))
                {
                    self.pending.remove(conversation);
                }
            }
        }
        self
    }
}

/// Whether `text` is an internal Home id (`addr_…`, `agent_…`, `conv_…`, …), never a name.
pub fn is_home_internal_id(text: &str) -> bool {
    const PREFIXES: &[&str] =
        &["addr", "user", "agent", "conv", "inv", "msg", "team", "inst", "grant", "task", "vm"];
    let Some((prefix, rest)) = text.split_once('_') else { return false };
    PREFIXES.contains(&prefix)
        && !rest.is_empty()
        && rest.chars().all(|c| c.is_ascii_alphanumeric() || c == '_' || c == '-')
}

/// One inbox row (`HomeInboxRequest.Row`, the fields the names read).
#[derive(Debug, Clone, Default, Deserialize)]
#[serde(default)]
pub struct Row {
    pub id: String,
    pub kind: String,
    pub name: String,
}

/// Each Chief row's record name by conversation id: a chief row's trimmed name that is no internal id;
/// the first row of an id wins.
pub fn local_records(rows: &[Row]) -> BTreeMap<String, String> {
    let mut records = BTreeMap::new();
    for row in rows {
        if row.kind != "chief" {
            continue;
        }
        let Some(name) = trimmed(&row.name) else { continue };
        if is_home_internal_id(&name) {
            continue;
        }
        records.entry(row.id.clone()).or_insert(name);
    }
    records
}

/// The `chief.profile.update` request that renames a Chief of this Mac.
pub fn local_rename(chief: &str, name: &str, unique: &str) -> Value {
    json!({
        "operation": "chief.profile.update",
        "params": {"chief": chief, "display_name": trim(name), "machine": "current", "session": "current"},
        "idempotencyKey": format!("home-chief-rename-{chief}-{unique}"),
    })
}

/// A daemon error as the rename op sees it: absent (`commandError` false) when it was no command error.
#[derive(Debug, Clone, Default, Deserialize)]
#[serde(default, rename_all = "camelCase")]
pub struct CommandError {
    pub command_error: bool,
    pub message: String,
    pub code: Option<String>,
    pub details: Option<Value>,
}

/// Why a rename did not save (`HomeChiefRenameFailure`).
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum RenameFailure {
    NoConnection,
    SignedOut,
    ChangedElsewhere,
    InvalidName,
    NotFound,
    Refused { message: String },
}

/// The failure of a Chief record rename (`HomeLocalChiefRename.failure`).
pub fn rename_failure(error: &CommandError) -> RenameFailure {
    if !error.command_error {
        return RenameFailure::NoConnection;
    }
    let reason =
        error.details.as_ref().and_then(|details| details.get("reason")).and_then(Value::as_str);
    if error.code.as_deref() == Some("validation.invalid") {
        return RenameFailure::InvalidName;
    }
    match reason {
        Some("chief_not_found" | "deleted_chief") => return RenameFailure::NotFound,
        Some("rev_mismatch") => return RenameFailure::ChangedElsewhere,
        _ => {}
    }
    let message = if error.message.is_empty() {
        reason.map(str::to_owned).or_else(|| error.code.clone()).unwrap_or_default()
    } else {
        error.message.clone()
    };
    RenameFailure::Refused { message }
}

/// The failure of a conversation title rename (`HomeConversationRename.send`).
pub fn conversation_rename_failure(error: &CommandError) -> RenameFailure {
    if !error.command_error {
        return RenameFailure::NoConnection;
    }
    if error.code.as_deref() == Some("invalid_title") {
        return RenameFailure::InvalidName;
    }
    let message = if error.message.is_empty() {
        error.code.clone().unwrap_or_default()
    } else {
        error.message.clone()
    };
    RenameFailure::Refused { message }
}

/// Another Chief's name: the Chief's own name while no Chief has it, else the first free "Chief 2", …
pub fn next_name(taken: &[String], strings: &Strings) -> String {
    let base = &strings.chief_name;
    if !taken.contains(base) {
        return base.clone();
    }
    let mut number = 2;
    while taken.contains(&format!("{base} {number}")) {
        number += 1;
    }
    format!("{base} {number}")
}

/// One conversation summary (the fields the chief rules read).
#[derive(Debug, Clone, Default, PartialEq, Deserialize, Serialize)]
#[serde(default, rename_all = "camelCase")]
pub struct Summary {
    pub id: String,
    pub title: String,
    /// Participant ids (or objects with an `id`).
    pub participants: Vec<Value>,
    pub created_at: Option<Value>,
}

impl Summary {
    fn has_mux(&self) -> bool {
        self.participants.iter().any(|participant| match participant {
            Value::String(id) => id == MUX_ID,
            other => other.get("id").and_then(Value::as_str) == Some(MUX_ID),
        })
    }
}

/// The one-time rename of `summary` to the chief name, or nil: only the old default titles ("Home",
/// localized or not, or none) are renamed.
pub fn title_migration(summary: &Summary, strings: &Strings) -> Option<Value> {
    let name = &strings.chief_name;
    let defaults = [strings.home_title.as_str(), "Home", ""];
    if !summary.has_mux() || &summary.title == name || !defaults.contains(&summary.title.as_str()) {
        return None;
    }
    Some(json!({
        "conversation": summary.id,
        "idempotencyKey": RENAME_KEY,
        "op": {"setTitle": name},
    }))
}

fn days_from_civil(year: i64, month: i64, day: i64) -> i64 {
    let year = if month <= 2 { year - 1 } else { year };
    let era = year.div_euclid(400);
    let yoe = year - era * 400;
    let doy = (153 * (month + if month > 2 { -3 } else { 9 }) + 2) / 5 + day - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    era * 146_097 + doe - 719_468
}

/// `created_at` in milliseconds since 1970, as the app's ISO 8601 reader takes it: internet date-time
/// with fractional seconds (`2026-11-25T10:00:00.123Z`, or an offset); a number is milliseconds already.
pub fn created_millis(value: Option<&Value>) -> Option<i64> {
    match value? {
        Value::Number(number) => number.as_f64().map(|ms| ms as i64),
        Value::String(text) => parse_iso(text),
        _ => None,
    }
}

fn parse_iso(text: &str) -> Option<i64> {
    let bytes = text.as_bytes();
    let digits = |from: usize, len: usize| -> Option<i64> {
        let part = text.get(from..from + len)?;
        if part.bytes().all(|b| b.is_ascii_digit()) { part.parse().ok() } else { None }
    };
    if bytes.len() < 20 || bytes[4] != b'-' || bytes[7] != b'-' || !matches!(bytes[10], b'T' | b't')
    {
        return None;
    }
    if bytes[13] != b':' || bytes[16] != b':' || bytes[19] != b'.' {
        return None;
    }
    let (year, month, day) = (digits(0, 4)?, digits(5, 2)?, digits(8, 2)?);
    let (hour, minute, second) = (digits(11, 2)?, digits(14, 2)?, digits(17, 2)?);
    if !(1..=12).contains(&month)
        || !(1..=31).contains(&day)
        || hour > 23
        || minute > 59
        || second > 60
    {
        return None;
    }
    let mut index = 20;
    let start = index;
    while index < bytes.len() && bytes[index].is_ascii_digit() {
        index += 1;
    }
    if index == start {
        return None;
    }
    let fraction = &text[start..index];
    let millis: i64 = format!("{fraction:0<3}")[..3].parse().ok()?;
    let offset = match text.get(index..)? {
        "Z" | "z" => 0,
        zone if zone.len() == 6
            && matches!(zone.as_bytes()[0], b'+' | b'-')
            && zone.as_bytes()[3] == b':' =>
        {
            let hours = digits(index + 1, 2)?;
            let minutes = digits(index + 4, 2)?;
            let sign = if zone.starts_with('-') { -1 } else { 1 };
            sign * (hours * 60 + minutes) * 60
        }
        _ => return None,
    };
    let seconds =
        days_from_civil(year, month, day) * 86_400 + hour * 3600 + minute * 60 + second - offset;
    Some(seconds * 1000 + millis)
}

/// The chief conversation: the oldest conversation with agent_mux, by created_at (unreadable: last), then
/// id. List order never decides it.
pub fn select_chief(conversations: &[Summary]) -> Option<&Summary> {
    conversations.iter().filter(|summary| summary.has_mux()).min_by(|a, b| {
        let key =
            |summary: &Summary| created_millis(summary.created_at.as_ref()).unwrap_or(i64::MAX);
        key(a).cmp(&key(b)).then_with(|| a.id.cmp(&b.id))
    })
}

// MARK: Ops

#[derive(Deserialize, Default)]
#[serde(default)]
struct StepRequest {
    state: Names,
    event: Option<NamesEvent>,
}

#[derive(Deserialize, Default)]
#[serde(default)]
struct OfRequest {
    state: Names,
    conversation: String,
    record: Option<String>,
}

#[derive(Deserialize, Default)]
#[serde(default)]
struct AllRequest {
    state: Names,
    records: BTreeMap<String, String>,
}

#[derive(Deserialize, Default)]
#[serde(default)]
struct RowsRequest {
    rows: Vec<Row>,
}

#[derive(Deserialize, Default)]
#[serde(default)]
struct LocalRenameRequest {
    chief: String,
    name: String,
    unique: String,
}

#[derive(Deserialize, Default)]
#[serde(default)]
struct FailureRequest {
    error: CommandError,
}

#[derive(Deserialize, Default)]
#[serde(default)]
struct TakenRequest {
    taken: Vec<String>,
}

#[derive(Deserialize, Default)]
#[serde(default)]
struct SummaryRequest {
    summary: Summary,
}

#[derive(Deserialize, Default)]
#[serde(default)]
struct ConversationsRequest {
    conversations: Vec<Summary>,
}

fn object(request: &Value) -> Value {
    if request.is_null() { Value::Object(Map::new()) } else { request.clone() }
}

pub(super) fn call(name: &str, request: &Value) -> Result<Value, OpError> {
    let words = strings(request);
    let request = &object(request);
    match name {
        "namesStep" => {
            let request: StepRequest = ops::parse(request)?;
            let state = match &request.event {
                Some(event) => request.state.step(event),
                None => request.state,
            };
            ops::reply(&state)
        }
        "namesOf" => {
            let request: OfRequest = ops::parse(request)?;
            ops::reply(&request.state.name_of(&request.conversation, request.record.as_deref()))
        }
        "namesAll" => {
            let request: AllRequest = ops::parse(request)?;
            ops::reply(&request.state.all(&request.records))
        }
        "localRecords" => ops::reply(&local_records(&ops::parse::<RowsRequest>(request)?.rows)),
        "localRename" => {
            let request: LocalRenameRequest = ops::parse(request)?;
            ops::reply(&local_rename(&request.chief, &request.name, &request.unique))
        }
        "renameFailure" => {
            ops::reply(&rename_failure(&ops::parse::<FailureRequest>(request)?.error))
        }
        "conversationRenameFailure" => {
            ops::reply(&conversation_rename_failure(&ops::parse::<FailureRequest>(request)?.error))
        }
        "nextName" => ops::reply(&next_name(&ops::parse::<TakenRequest>(request)?.taken, &words)),
        "titleMigration" => {
            ops::reply(&title_migration(&ops::parse::<SummaryRequest>(request)?.summary, &words))
        }
        "selectChief" => {
            let request: ConversationsRequest = ops::parse(request)?;
            ops::reply(&select_chief(&request.conversations).map(|summary| summary.id.clone()))
        }
        _ => Err(OpError::Unknown),
    }
}
