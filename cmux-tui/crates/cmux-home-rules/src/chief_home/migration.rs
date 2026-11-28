//! Merging the old per-tag Chiefs into the shared home (CmuxNextHomeEngine `ChiefMigration.swift`,
//! `ChiefMigration+Read.swift`, `ChiefMigrationPlan.swift`): which old Chiefs there are, the merged
//! history's order, the memory lines and the records. The locks, SQLite reads, file copies and the
//! daemon import stay in Swift.

use super::{build, path, time};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::collections::{BTreeMap, BTreeSet};

/// `ChiefMigration.recordName`.
pub const RECORD_NAME: &str = "migration.json";

/// `ChiefMigration.sessionComponent`: a readable prefix (48 bytes at most, others as `_`) and the
/// session's FNV-1a 64.
pub fn session_component(session: &str) -> String {
    let readable: String = session
        .bytes()
        .take(48)
        .map(|byte| {
            if byte.is_ascii_alphanumeric() || byte == b'-' || byte == b'_' {
                byte as char
            } else {
                '_'
            }
        })
        .collect();
    let readable = if readable.is_empty() { "session".to_owned() } else { readable };
    format!("{readable}-{:016x}", build::fnv1a64(session.as_bytes()))
}

/// One old Chief (`ChiefMigration.Old`).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Old {
    pub tag: String,
    pub mux_home: String,
    pub store: String,
}

/// `ChiefMigration.oldChiefs`: `tags` are `~/.cmux/mux/tags`' names; `existing` the stores under
/// `cmux-next/` that are there (else the store is the one under `cmux/`).
pub fn old_chiefs(
    user_home: &str,
    application_support: &str,
    tags: &[String],
    existing: &[String],
) -> Vec<Old> {
    let tags_dir = path::join(&path::standardized(user_home), ".cmux/mux/tags");
    let support = path::standardized(application_support);
    let mut sorted: Vec<&String> = tags.iter().collect();
    sorted.sort();
    sorted
        .into_iter()
        .map(|tag| {
            let session = format!("cmux-app-{tag}");
            let relative =
                format!("tags/{tag}/tui/{}/conversations.sqlite3", session_component(&session));
            let moved = path::join(&support, &format!("cmux-next/{relative}"));
            let store = if existing.contains(&moved) {
                moved
            } else {
                path::join(&support, &format!("cmux/{relative}"))
            };
            Old { tag: tag.clone(), mux_home: path::join(&tags_dir, tag), store }
        })
        .collect()
}

/// `ChiefMigration.run`'s first decision: `nothingToDo` for an isolated home or one with a record,
/// `blocked` while an old Chief's host holds its lock, else `go`.
pub fn run_step(isolated: bool, record_exists: bool, blocking: &[String]) -> &'static str {
    if isolated || record_exists {
        "nothingToDo"
    } else if !blocking.is_empty() {
        "blocked"
    } else {
        "go"
    }
}

/// One stored message (`ChiefMigrationSource.Message`).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Message {
    pub id: String,
    #[serde(default)]
    pub seq: u64,
    #[serde(default)]
    pub author: String,
    #[serde(default, rename = "clientMsgID")]
    pub client_msg_id: String,
    #[serde(default)]
    pub created_at: String,
    #[serde(default)]
    pub parts: Vec<Value>,
}

impl Message {
    pub fn is_human(&self) -> bool {
        self.author.starts_with("user_")
    }

    pub fn is_reply(&self) -> bool {
        self.client_msg_id.starts_with("turn:")
    }

    /// The text parts, one per line.
    pub fn text(&self) -> String {
        self.parts
            .iter()
            .filter_map(|part| {
                let fields = part.as_object()?;
                (fields.get("type")?.as_str()? == "text").then_some(())?;
                fields.get("text")?.as_str()
            })
            .collect::<Vec<_>>()
            .join("\n")
    }
}

/// One memory log line (`ChiefMigrationSource.LogEntry`).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct LogEntry {
    pub i: i64,
    pub kind: String,
    pub text: String,
    pub date: String,
}

/// One old Chief as read (`ChiefMigrationSource`).
#[derive(Debug, Clone, Default, PartialEq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Source {
    #[serde(default)]
    pub name: String,
    #[serde(default, rename = "conversationID")]
    pub conversation_id: Option<String>,
    #[serde(default)]
    pub messages: Vec<Message>,
    #[serde(default)]
    pub log: Vec<LogEntry>,
    #[serde(default)]
    pub logged_seq: u64,
    #[serde(default)]
    pub host_conversation: Option<String>,
}

impl Source {
    /// `isLogged(_:)`: a human message the old host already wrote to its memory.
    pub fn is_logged(&self, message: &Message) -> bool {
        message.is_human()
            && self.host_conversation.is_some()
            && self.host_conversation == self.conversation_id
            && message.seq <= self.logged_seq
    }
}

/// Where the merged memory comes from (`ChiefMigrationPlan.Memory`).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum Memory {
    None,
    Copy { source: usize },
    Interleave,
}

/// One merged message and the old Chief it came from.
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct Item {
    pub source: usize,
    pub message: Message,
}

/// `ChiefMigrationPlan`.
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct Plan {
    pub items: Vec<Item>,
    pub duplicates: usize,
    pub memory: Memory,
    pub unlogged: Vec<Item>,
    pub moved: usize,
}

fn logged(sources: &[Source], item: &Item) -> bool {
    sources.get(item.source).is_some_and(|source| source.is_logged(&item.message))
}

fn in_memory(memory: Memory, sources: &[Source], item: &Item) -> bool {
    match memory {
        Memory::None => false,
        Memory::Copy { source } => item.source == source && logged(sources, item),
        Memory::Interleave => logged(sources, item),
    }
}

/// `ChiefMigrationPlan.make`.
pub fn plan(sources: &[Source]) -> Plan {
    let mut ordered: Vec<Item> = sources
        .iter()
        .enumerate()
        .flat_map(|(index, source)| {
            source.messages.iter().map(move |m| Item { source: index, message: m.clone() })
        })
        .collect();
    ordered.sort_by(|a, b| {
        let key =
            |item: &Item| (time::time(&item.message.created_at), item.source, item.message.seq);
        key(a).partial_cmp(&key(b)).unwrap_or(std::cmp::Ordering::Equal)
    });
    let mut seen_ids = BTreeSet::new();
    let mut seen_keys = BTreeSet::new();
    let mut duplicates = 0;
    let mut items = Vec::new();
    for item in ordered {
        let key = format!("{}\0{}", item.message.author, item.message.client_msg_id);
        if seen_ids.contains(&item.message.id) || seen_keys.contains(&key) {
            duplicates += 1;
            continue;
        }
        seen_ids.insert(item.message.id.clone());
        seen_keys.insert(key);
        items.push(item);
    }
    let with_memory: Vec<usize> = sources
        .iter()
        .enumerate()
        .filter(|(_, source)| !source.log.is_empty())
        .map(|(index, _)| index)
        .collect();
    let memory = match with_memory.as_slice() {
        [] => Memory::None,
        [source] => Memory::Copy { source: *source },
        _ => Memory::Interleave,
    };
    let mut moved = 0;
    if let Memory::Copy { source: base } = memory {
        // Memory order wins: an unlogged human message dated before the memory's last message moves
        // after it (keeping its own order).
        let last = items
            .iter()
            .filter(|item| {
                item.source == base
                    && ((item.message.is_human() && in_memory(memory, sources, item))
                        || item.message.is_reply())
            })
            .map(|item| time::time(&item.message.created_at))
            .reduce(f64::max);
        if let Some(last) = last {
            let late: BTreeSet<String> = items
                .iter()
                .filter(|item| {
                    item.message.is_human()
                        && !in_memory(memory, sources, item)
                        && time::time(&item.message.created_at) < last
                })
                .map(|item| item.message.id.clone())
                .collect();
            moved = late.len();
            if moved > 0 {
                let (late_items, kept): (Vec<Item>, Vec<Item>) =
                    items.into_iter().partition(|item| late.contains(&item.message.id));
                let cut = kept
                    .iter()
                    .rposition(|item| time::time(&item.message.created_at) <= last)
                    .map_or(0, |i| i + 1);
                let mut kept = kept;
                let tail = kept.split_off(cut);
                items = kept.into_iter().chain(late_items).chain(tail).collect();
            }
        }
    }
    let unlogged = items
        .iter()
        .filter(|item| item.message.is_human() && !in_memory(memory, sources, item))
        .cloned()
        .collect();
    Plan { items, duplicates, memory, unlogged, moved }
}

/// `ChiefMigrationPlan.imports`: the messages the daemon imports, in order.
pub fn imports(plan: &Plan) -> Vec<Value> {
    plan.items
        .iter()
        .map(|item| {
            json!({
                "id": item.message.id,
                "clientMsgID": item.message.client_msg_id,
                "author": item.message.author,
                "parts": item.message.parts,
                "createdAt": item.message.created_at,
            })
        })
        .collect()
}

/// `ChiefMigrationPlan.logLine`: sorted keys, slashes as they are, one line.
pub fn log_line(i: i64, kind: &str, text: &str, date: &str) -> String {
    let size = kind.len() + 2 + text.len();
    format!(
        "{{\"date\":{},\"i\":{i},\"kind\":{},\"size\":{size},\"text\":{}}}\n",
        time::string(date, false),
        time::string(kind, false),
        time::string(text, false),
    )
}

/// `ChiefMigrationPlan.localDate`: `text`'s instant in the zone `utc_offset` seconds east.
pub fn local_date(text: &str, utc_offset: i64) -> String {
    time::fractional_local(time::time(text), utc_offset)
}

/// One line `writeMemory` appends, to `main/<day>.jsonl`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct Append {
    pub file: String,
    pub line: String,
}

/// `writeMemory`'s lines for a fresh memory.
#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct MemoryLines {
    pub memory: Memory,
    /// For `copy`: copy this old Chief's `main` and `tree`, `AGENTS.md` and `engine.json`.
    pub copy_from: Option<String>,
    pub appends: Vec<Append>,
    /// What `writeMemory` returns.
    pub entries: usize,
}

fn day_file(date: &str) -> String {
    let day: String = date.chars().take(10).collect();
    format!("{day}.jsonl")
}

/// `writeMemory` past its "memory is already there" check: the interleaved old logs (or the copied
/// one) and then each unlogged human message as a `user` line.
pub fn memory_lines(sources: &[Source], utc_offset: i64) -> MemoryLines {
    memory_lines_dated(sources, utc_offset, &[])
}

/// ``memory_lines`` with each unlogged message dated at its own UTC offset
/// (`unlogged_offsets[i]`, the zone's offset at that message's time, so a
/// move across a daylight-saving change dates each line as the clock did);
/// a message past the list takes `utc_offset`.
pub fn memory_lines_dated(
    sources: &[Source],
    utc_offset: i64,
    unlogged_offsets: &[i64],
) -> MemoryLines {
    let plan = plan(sources);
    let mut appends = Vec::new();
    let mut copy_from = None;
    let count = match plan.memory {
        Memory::None => 0,
        Memory::Copy { source } => {
            let source = sources.get(source);
            copy_from = source.map(|source| source.name.clone());
            source.map_or(0, |source| source.log.len())
        }
        Memory::Interleave => {
            let mut all: Vec<&LogEntry> = sources.iter().flat_map(|source| &source.log).collect();
            all.sort_by(|a, b| {
                time::time(&a.date)
                    .partial_cmp(&time::time(&b.date))
                    .unwrap_or(std::cmp::Ordering::Equal)
            });
            for (index, entry) in all.iter().enumerate() {
                appends.push(Append {
                    file: day_file(&entry.date),
                    line: log_line(index as i64, &entry.kind, &entry.text, &entry.date),
                });
            }
            all.len()
        }
    };
    for (offset, item) in plan.unlogged.iter().enumerate() {
        let item_offset = unlogged_offsets.get(offset).copied().unwrap_or(utc_offset);
        let date = local_date(&item.message.created_at, item_offset);
        appends.push(Append {
            file: day_file(&date),
            line: log_line((count + offset) as i64, "user", &item.message.text(), &date),
        });
    }
    MemoryLines { memory: plan.memory, copy_from, appends, entries: count + plan.unlogged.len() }
}

/// `writeMemory`'s first check: a memory from an interrupted move is kept.
pub fn has_memory(database_exists: bool, main_names: &[String]) -> bool {
    database_exists || main_names.iter().any(|name| name.ends_with(".jsonl"))
}

/// `writeHostState`'s `host.json`: every imported message is logged.
pub fn host_state(conversation: &str, logged_seq: u64) -> String {
    json!({
        "children": {},
        "conversation": conversation,
        "logged_seq": logged_seq,
        "orphans": [],
        "outbox": [],
        "turn": null,
    })
    .to_string()
}

/// `writeRecord`'s `migration.json`.
pub fn record(status: &str, now: f64, olds: &[Old]) -> String {
    let sources: Vec<Value> = olds
        .iter()
        .map(|old| json!({ "tag": old.tag, "mux_home": old.mux_home, "store": old.store }))
        .collect();
    time::pretty_sorted(&json!({ "status": status, "at": time::internet(now), "sources": sources }))
}

/// `copyRegularFiles`' skips: the old host's locks and temporary files.
pub fn copy_skips(name: &str) -> bool {
    name == "lock" || name == "takeover.flock" || name.contains(".tmp")
}

/// `message(fromJSON:)`: a stored `message_json` row.
pub fn message_from_json(text: &str) -> Option<Message> {
    let value: Value = serde_json::from_str(text).ok()?;
    let fields = value.as_object()?;
    let seq = fields.get("seq")?.as_f64()?;
    Some(Message {
        id: fields.get("id")?.as_str()?.to_owned(),
        seq: seq as u64,
        author: fields.get("author")?.as_str()?.to_owned(),
        client_msg_id: fields.get("client_msg_id")?.as_str()?.to_owned(),
        created_at: fields.get("created_at")?.as_str()?.to_owned(),
        parts: fields.get("parts")?.as_array()?.clone(),
    })
}

/// `readLog`: every `.jsonl` file's lines with `i`, `kind`, `text` and `date`, ordered by `i`.
pub fn read_log(files: &[String]) -> Vec<LogEntry> {
    let mut entries: Vec<LogEntry> = files
        .iter()
        .flat_map(|text| text.split('\n'))
        .filter(|line| !line.is_empty())
        .filter_map(|line| {
            let value: Value = serde_json::from_str(line).ok()?;
            let object = value.as_object()?;
            let i = object.get("i")?;
            let i = i.as_i64().or_else(|| i.as_f64().map(|n| n as i64))?;
            Some(LogEntry {
                i,
                kind: object.get("kind")?.as_str()?.to_owned(),
                text: object.get("text")?.as_str()?.to_owned(),
                date: object.get("date")?.as_str()?.to_owned(),
            })
        })
        .collect();
    entries.sort_by_key(|entry| entry.i);
    entries
}

/// An old host's cursor: which conversation its memory logged, and how far.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Cursor {
    pub host_conversation: Option<String>,
    pub logged_seq: u64,
}

/// `readSource`'s cursor from `memory.sqlite3`'s `host/%` state rows (values as stored).
pub fn cursor_from_state(state: &BTreeMap<String, String>) -> Cursor {
    Cursor {
        host_conversation: state
            .get("host/conversation")
            .and_then(|raw| serde_json::from_str::<Value>(raw).ok())
            .and_then(|value| value.as_str().map(str::to_owned)),
        logged_seq: state.get("host/logged_seq").and_then(|raw| raw.parse().ok()).unwrap_or(0),
    }
}

/// `readSource`'s cursor from an old `host.json`.
pub fn cursor_from_host_json(text: &str) -> Cursor {
    let Ok(Value::Object(state)) = serde_json::from_str::<Value>(text) else {
        return Cursor::default();
    };
    Cursor {
        host_conversation: state.get("conversation").and_then(Value::as_str).map(str::to_owned),
        logged_seq: state
            .get("logged_seq")
            .and_then(|n| n.as_u64().or_else(|| n.as_f64().filter(|f| *f >= 0.0).map(|f| f as u64)))
            .unwrap_or(0),
    }
}

/// One `conversation` row: `id`, `participants_json`, `created_at`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Conversation {
    pub id: String,
    #[serde(default)]
    pub participants_json: String,
    #[serde(default)]
    pub created_at: String,
}

/// `readChief`'s pick: the oldest conversation with the mux in it (ties by id).
pub fn pick_chief(conversations: &[Conversation]) -> Option<&Conversation> {
    conversations
        .iter()
        .filter(|row| row.participants_json.contains("\"agent_mux\""))
        .min_by(|a, b| (&a.created_at, &a.id).cmp(&(&b.created_at, &b.id)))
}
