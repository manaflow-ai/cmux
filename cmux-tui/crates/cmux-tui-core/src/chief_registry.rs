//! The Chief registry: every Chief of this daemon's Chief home, with its
//! profile (name, role, avatar, personality, instructions), the tools and
//! harnesses the person granted it, its engine, and which of its own fields
//! the Chief may change without asking (`self_edit`). Design:
//! hq .cmux-scratch/hq6d-multi-chief/DESIGN.md (bead cx-ebm.60).
//!
//! Its own owner with its own file `chiefs.sqlite3` in the session state
//! directory, next to `conversations.sqlite3` (in memory for an in-memory
//! session). A Chief's id is its conversation participant id: the default
//! Chief is `agent_mux` (the participant every install already has), a new
//! one `agent_` + 26 Crockford base32. The default record is written on the
//! first open, so an install keeps its one Chief with no migration. A
//! deleted id stays as a tombstone and is never reused. Avatar bytes are
//! rows keyed by SHA-256; the write that drops the last reference deletes
//! them in the same transaction.
//!
//! The owner rules (who may write what) are the caller's
//! (server/chief_registry_resource.rs); this module checks values, keeps one
//! default, the revision and the idempotency ledger.

use std::path::Path;
use std::sync::Mutex;

use anyhow::Context;
use rusqlite::{Connection, OptionalExtension, TransactionBehavior, params};
use serde::{Deserialize, Serialize};
use serde_json::{Map, Value, json};
use sha2::{Digest, Sha256};

/// The registry's file inside the session state directory.
pub(crate) const CHIEFS_FILE: &str = "chiefs.sqlite3";
/// The default Chief's id: the participant `agent_mux` of every install.
pub(crate) const DEFAULT_CHIEF: &str = "agent_mux";
/// Idempotency keys kept per caller (the oldest go first).
const LEDGER_KEYS_PER_ACTOR: i64 = 256;
/// The largest avatar image (decoded bytes).
pub(crate) const MAX_AVATAR_BYTES: usize = 1024 * 1024;
/// Chiefs one home may have (tombstones not counted).
pub(crate) const MAX_CHIEFS: usize = 64;
const SCHEMA_VERSION: i64 = 1;

/// The tools a Chief may be granted (DESIGN.md section 4).
pub(crate) const TOOLS: [&str; 7] =
    ["browser", "chiefs", "cloud_vms", "memory_import", "spawn", "tell", "workspaces"];
/// A new Chief's tools when the person names none.
const DEFAULT_NEW_TOOLS: [&str; 3] = ["spawn", "tell", "workspaces"];
/// The fields a Chief may be allowed to change about itself.
pub(crate) const SELF_EDITABLE: [&str; 5] =
    ["avatar", "display_name", "instructions", "personality", "role"];
const AVATAR_TYPES: [&str; 4] = ["image/gif", "image/jpeg", "image/png", "image/webp"];

/// A refusal; the resource layer maps it to `operation.failed` with
/// `details.reason` [`Refusal::reason`] (or `validation.invalid` for a field).
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum Refusal {
    /// A field value is out of range: the field and why.
    Invalid(&'static str, String),
    NotFound,
    /// The default Chief cannot be deleted.
    IsDefault,
    /// `expected_rev` is not the record's revision (the current one).
    RevMismatch(u64),
    /// The idempotency key was used for another request: the operation it
    /// committed.
    KeyConflict(String),
    TooMany,
}

impl Refusal {
    pub(crate) fn reason(&self) -> &'static str {
        match self {
            Self::Invalid(..) => "invalid",
            Self::NotFound => "chief_not_found",
            Self::IsDefault => "chief_is_default",
            Self::RevMismatch(_) => "rev_mismatch",
            Self::KeyConflict(_) => "idempotency_conflict",
            Self::TooMany => "too_many_chiefs",
        }
    }
}

pub(crate) type Outcome<T> = Result<T, Refusal>;
/// A Chief's picture: its reference and its bytes.
pub(crate) type AvatarBytes = Option<(AvatarRef, Vec<u8>)>;

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub(crate) struct AvatarRef {
    pub sha256: String,
    pub media_type: String,
    pub bytes: u64,
}

#[derive(Debug, Clone, PartialEq, Eq, Default, Serialize, Deserialize)]
pub(crate) struct Engine {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub harness: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub model: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub effort: Option<String>,
}

/// One Chief (DESIGN.md section 1); the wire form is this JSON.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub(crate) struct ChiefRecord {
    pub id: String,
    pub display_name: String,
    pub role: String,
    pub personality: String,
    pub instructions: String,
    pub avatar: Option<AvatarRef>,
    pub tools: Vec<String>,
    pub harnesses: Vec<String>,
    pub engine: Engine,
    pub self_edit: Vec<String>,
    pub is_default: bool,
    pub rev: u64,
    pub created_at: String,
    pub updated_at: String,
}

/// An avatar change: new bytes, or none.
pub(crate) enum AvatarChange {
    Set { media_type: String, bytes: Vec<u8> },
    Clear,
}

/// The daemon's registry, opened on first use.
#[derive(Default)]
pub(crate) struct ChiefHost {
    pub(crate) store: Mutex<Option<ChiefStore>>,
    /// The brain supervisor's inbox (chief_brains.rs), when it runs.
    pub(crate) brains: crate::chief_brains::Slot,
}

pub(crate) struct ChiefStore {
    connection: Connection,
}

impl ChiefStore {
    pub(crate) fn open(directory: Option<&Path>) -> anyhow::Result<Self> {
        let connection = match directory {
            Some(directory) => {
                let path = directory.join(CHIEFS_FILE);
                let connection = crate::workspace_registry::open_registry_database(&path)
                    .with_context(|| format!("open chief registry {}", path.display()))?;
                crate::platform::restrict_file(&path)
                    .with_context(|| format!("restrict chief registry {}", path.display()))?;
                connection
            }
            None => Connection::open_in_memory()?,
        };
        Self::initialize(connection)
    }

    fn initialize(mut connection: Connection) -> anyhow::Result<Self> {
        connection.busy_timeout(std::time::Duration::from_secs(5))?;
        connection.execute_batch(
            "PRAGMA journal_mode=WAL;
             PRAGMA synchronous=FULL;
             PRAGMA fullfsync=ON;
             CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY NOT NULL, value TEXT NOT NULL);
             CREATE TABLE IF NOT EXISTS chief (
               id TEXT PRIMARY KEY NOT NULL,
               seq INTEGER NOT NULL,
               record TEXT,
               deleted_at TEXT
             );
             CREATE TABLE IF NOT EXISTS avatar (
               sha256 TEXT PRIMARY KEY NOT NULL,
               media_type TEXT NOT NULL,
               data BLOB NOT NULL
             );
             CREATE TABLE IF NOT EXISTS op_ledger (
               seq INTEGER PRIMARY KEY AUTOINCREMENT,
               actor TEXT NOT NULL,
               key TEXT NOT NULL,
               operation TEXT NOT NULL,
               fingerprint TEXT NOT NULL,
               result TEXT NOT NULL,
               UNIQUE (actor, key)
             );",
        )?;
        let transaction = connection.transaction_with_behavior(TransactionBehavior::Immediate)?;
        let stored: Option<String> = transaction
            .query_row("SELECT value FROM meta WHERE key = 'schema_version'", [], |row| row.get(0))
            .optional()?;
        match stored.as_deref().map(str::parse::<i64>) {
            None => {
                transaction.execute(
                    "INSERT INTO meta (key, value) VALUES ('schema_version', ?1)",
                    params![SCHEMA_VERSION.to_string()],
                )?;
            }
            Some(Ok(SCHEMA_VERSION)) => {}
            Some(_) => anyhow::bail!("chief registry has an unknown schema version"),
        }
        let has_default: bool = transaction.query_row(
            "SELECT EXISTS(SELECT 1 FROM chief WHERE id = ?1)",
            [DEFAULT_CHIEF],
            |r| r.get(0),
        )?;
        if !has_default {
            let now = now_text();
            let record = ChiefRecord {
                id: DEFAULT_CHIEF.into(),
                display_name: "Chief".into(),
                role: String::new(),
                personality: String::new(),
                instructions: String::new(),
                avatar: None,
                tools: TOOLS.iter().map(|t| (*t).to_owned()).collect(),
                harnesses: Vec::new(),
                engine: Engine::default(),
                self_edit: vec!["avatar".into()],
                is_default: true,
                rev: 1,
                created_at: now.clone(),
                updated_at: now,
            };
            transaction.execute(
                "INSERT INTO chief (id, seq, record) VALUES (?1, 0, ?2)",
                params![DEFAULT_CHIEF, serde_json::to_string(&record)?],
            )?;
        }
        transaction.commit()?;
        Ok(Self { connection })
    }

    /// Every live Chief, the default first, then in creation order.
    pub(crate) fn list(&self) -> anyhow::Result<Vec<ChiefRecord>> {
        let mut statement = self.connection.prepare(
            "SELECT record FROM chief WHERE record IS NOT NULL ORDER BY seq ASC, id ASC",
        )?;
        let rows = statement.query_map([], |row| row.get::<_, String>(0))?;
        let mut records = Vec::new();
        for row in rows {
            records.push(serde_json::from_str::<ChiefRecord>(&row?)?);
        }
        records.sort_by_key(|r| !r.is_default);
        Ok(records)
    }

    pub(crate) fn get(&self, id: &str) -> anyhow::Result<Option<ChiefRecord>> {
        load(&self.connection, id)
    }

    /// The avatar bytes of a live Chief: its reference and the bytes.
    pub(crate) fn avatar(&self, id: &str) -> anyhow::Result<Outcome<AvatarBytes>> {
        let Some(record) = load(&self.connection, id)? else { return Ok(Err(Refusal::NotFound)) };
        let Some(avatar) = record.avatar else { return Ok(Ok(None)) };
        let data: Vec<u8> = self.connection.query_row(
            "SELECT data FROM avatar WHERE sha256 = ?1",
            [&avatar.sha256],
            |row| row.get(0),
        )?;
        Ok(Ok(Some((avatar, data))))
    }

    /// Runs `write` once per (`actor`, `key`): a replay with the same
    /// `request` answers the committed result with `replayed` true; another
    /// request under the key is [`Refusal::KeyConflict`]. The newest
    /// [`LEDGER_KEYS_PER_ACTOR`] keys of each actor are kept.
    pub(crate) fn mutate(
        &mut self,
        actor: &str,
        key: &str,
        operation: &str,
        request: &Value,
        write: impl FnOnce(&rusqlite::Transaction<'_>) -> anyhow::Result<Outcome<ChiefRecord>>,
    ) -> anyhow::Result<Outcome<(ChiefRecord, bool)>> {
        let fingerprint = fingerprint(request)?;
        let transaction =
            self.connection.transaction_with_behavior(TransactionBehavior::Immediate)?;
        let committed: Option<(String, String, String)> = transaction
            .query_row(
                "SELECT fingerprint, result, operation FROM op_ledger WHERE actor = ?1 AND key = ?2",
                params![actor, key],
                |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
            )
            .optional()?;
        if let Some((stored, result, committed_operation)) = committed {
            if stored != fingerprint {
                return Ok(Err(Refusal::KeyConflict(committed_operation)));
            }
            return Ok(Ok((serde_json::from_str(&result)?, true)));
        }
        let record = match write(&transaction)? {
            Ok(record) => record,
            Err(refusal) => return Ok(Err(refusal)),
        };
        transaction.execute(
            "INSERT INTO op_ledger (actor, key, operation, fingerprint, result)
             VALUES (?1, ?2, ?3, ?4, ?5)",
            params![actor, key, operation, fingerprint, serde_json::to_string(&record)?],
        )?;
        transaction.execute(
            "DELETE FROM op_ledger WHERE actor = ?1 AND seq NOT IN
               (SELECT seq FROM op_ledger WHERE actor = ?1 ORDER BY seq DESC LIMIT ?2)",
            params![actor, LEDGER_KEYS_PER_ACTOR],
        )?;
        collect_avatars(&transaction)?;
        transaction.commit()?;
        Ok(Ok((record, false)))
    }
}

/// `chief.profile.create`'s write: a new record from `fields` (already checked by
/// [`validate_fields`]).
pub(crate) fn create(
    tx: &rusqlite::Transaction<'_>,
    fields: &Map<String, Value>,
) -> anyhow::Result<Outcome<ChiefRecord>> {
    let live: i64 =
        tx.query_row("SELECT COUNT(*) FROM chief WHERE record IS NOT NULL", [], |r| r.get(0))?;
    if usize::try_from(live).unwrap_or(usize::MAX) >= MAX_CHIEFS {
        return Ok(Err(Refusal::TooMany));
    }
    let now_ms = now_ms();
    let mut random = [0_u8; 10];
    getrandom::fill(&mut random).map_err(|_| anyhow::anyhow!("chief id randomness"))?;
    let id = cmux_conversation::encode_id("agent_", now_ms, random);
    let seq: i64 = tx.query_row("SELECT COALESCE(MAX(seq), 0) + 1 FROM chief", [], |r| r.get(0))?;
    let now = cmux_conversation::format_rfc3339_millis(now_ms);
    let mut record = ChiefRecord {
        id: id.clone(),
        display_name: String::new(),
        role: String::new(),
        personality: String::new(),
        instructions: String::new(),
        avatar: None,
        tools: DEFAULT_NEW_TOOLS.iter().map(|t| (*t).to_owned()).collect(),
        harnesses: Vec::new(),
        engine: Engine::default(),
        self_edit: vec!["avatar".into()],
        is_default: false,
        rev: 1,
        created_at: now.clone(),
        updated_at: now,
    };
    apply(&mut record, fields);
    tx.execute(
        "INSERT INTO chief (id, seq, record) VALUES (?1, ?2, ?3)",
        params![id, seq, serde_json::to_string(&record)?],
    )?;
    Ok(Ok(record))
}

/// `chief.profile.update`'s write: `fields` (already checked) on `id`, guarded by
/// `expected_rev` when given; `avatar` sets or clears the image.
pub(crate) fn update(
    tx: &rusqlite::Transaction<'_>,
    id: &str,
    expected_rev: Option<u64>,
    fields: &Map<String, Value>,
    avatar: Option<AvatarChange>,
) -> anyhow::Result<Outcome<ChiefRecord>> {
    let Some(mut record) = load(tx, id)? else { return Ok(Err(Refusal::NotFound)) };
    if expected_rev.is_some_and(|e| e != record.rev) {
        return Ok(Err(Refusal::RevMismatch(record.rev)));
    }
    let before = record.clone();
    apply(&mut record, fields);
    match avatar {
        Some(AvatarChange::Set { media_type, bytes }) => {
            let sha256 = hex(&Sha256::digest(&bytes));
            tx.execute(
                "INSERT OR IGNORE INTO avatar (sha256, media_type, data) VALUES (?1, ?2, ?3)",
                params![sha256, media_type, bytes],
            )?;
            record.avatar = Some(AvatarRef { sha256, media_type, bytes: bytes.len() as u64 });
        }
        Some(AvatarChange::Clear) => record.avatar = None,
        None => {}
    }
    if record != before {
        record.rev += 1;
        record.updated_at = now_text();
        tx.execute(
            "UPDATE chief SET record = ?2 WHERE id = ?1",
            params![id, serde_json::to_string(&record)?],
        )?;
    }
    Ok(Ok(record))
}

/// `chief.profile.delete`'s write: the record becomes a tombstone (the id is never
/// reused); the answer is the record as it was.
pub(crate) fn delete(
    tx: &rusqlite::Transaction<'_>,
    id: &str,
    expected_rev: Option<u64>,
) -> anyhow::Result<Outcome<ChiefRecord>> {
    let Some(record) = load(tx, id)? else { return Ok(Err(Refusal::NotFound)) };
    if record.is_default {
        return Ok(Err(Refusal::IsDefault));
    }
    if expected_rev.is_some_and(|e| e != record.rev) {
        return Ok(Err(Refusal::RevMismatch(record.rev)));
    }
    tx.execute(
        "UPDATE chief SET record = NULL, deleted_at = ?2 WHERE id = ?1",
        params![id, now_text()],
    )?;
    Ok(Ok(record))
}

/// Checks the profile fields of a create or update; `None` when all fit.
pub(crate) fn validate_fields(fields: &Map<String, Value>) -> Option<Refusal> {
    let text = |name: &'static str, min: usize, max: usize| -> Option<Refusal> {
        let value = fields.get(name)?;
        let Some(text) = value.as_str() else {
            return Some(Refusal::Invalid(name, "must be a string".into()));
        };
        let count = text.chars().count();
        if count < min || count > max {
            return Some(Refusal::Invalid(name, format!("must be {min} to {max} characters")));
        }
        let single_line = matches!(name, "display_name" | "role" | "harness" | "model" | "effort");
        if text.chars().any(|c| c.is_control() && (single_line || !matches!(c, '\n' | '\t'))) {
            return Some(Refusal::Invalid(name, "has a control character".into()));
        }
        None
    };
    let set = |name: &'static str, allowed: Option<&[&str]>| -> Option<Refusal> {
        let value = fields.get(name)?;
        let Some(items) = value.as_array() else {
            return Some(Refusal::Invalid(name, "must be a list".into()));
        };
        for item in items {
            let Some(item) = item.as_str() else {
                return Some(Refusal::Invalid(name, "must be a list of names".into()));
            };
            let known = allowed.is_none_or(|allowed| allowed.contains(&item));
            let shaped = !item.is_empty()
                && item.len() <= 64
                && item
                    .bytes()
                    .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'_' | b'-' | b'.'));
            if !known || !shaped {
                return Some(Refusal::Invalid(name, format!("unknown name {item:?}")));
            }
        }
        None
    };
    text("display_name", 1, 100)
        .or_else(|| text("role", 0, 200))
        .or_else(|| text("personality", 0, 4000))
        .or_else(|| text("instructions", 0, 32000))
        .or_else(|| text("harness", 0, 128))
        .or_else(|| text("model", 0, 128))
        .or_else(|| text("effort", 0, 128))
        .or_else(|| set("tools", Some(&TOOLS)))
        .or_else(|| set("harnesses", None))
        .or_else(|| set("self_edit", Some(&SELF_EDITABLE)))
}

/// Checks an avatar image: a known type, at most [`MAX_AVATAR_BYTES`], and
/// bytes that are that type.
pub(crate) fn validate_avatar(media_type: &str, bytes: &[u8]) -> Option<Refusal> {
    if !AVATAR_TYPES.contains(&media_type) {
        return Some(Refusal::Invalid(
            "media_type",
            "must be image/png, image/jpeg, image/gif or image/webp".into(),
        ));
    }
    if bytes.is_empty() || bytes.len() > MAX_AVATAR_BYTES {
        return Some(Refusal::Invalid("data", format!("must be 1 to {MAX_AVATAR_BYTES} bytes")));
    }
    let matches = match media_type {
        "image/png" => bytes.starts_with(b"\x89PNG\r\n\x1a\n"),
        "image/jpeg" => bytes.starts_with(&[0xFF, 0xD8, 0xFF]),
        "image/gif" => bytes.starts_with(b"GIF87a") || bytes.starts_with(b"GIF89a"),
        _ => bytes.len() >= 12 && &bytes[..4] == b"RIFF" && &bytes[8..12] == b"WEBP",
    };
    (!matches).then(|| Refusal::Invalid("data", format!("is not a {media_type} image")))
}

/// Writes the checked `fields` into `record`. Sets are stored sorted and
/// unique; an empty engine text clears that choice.
fn apply(record: &mut ChiefRecord, fields: &Map<String, Value>) {
    let text = |name: &str| fields.get(name).and_then(Value::as_str).map(str::to_owned);
    let set = |name: &str| {
        fields.get(name).and_then(Value::as_array).map(|items| {
            let mut out: Vec<String> =
                items.iter().filter_map(Value::as_str).map(str::to_owned).collect();
            out.sort();
            out.dedup();
            out
        })
    };
    if let Some(v) = text("display_name") {
        record.display_name = v;
    }
    if let Some(v) = text("role") {
        record.role = v;
    }
    if let Some(v) = text("personality") {
        record.personality = v;
    }
    if let Some(v) = text("instructions") {
        record.instructions = v;
    }
    if let Some(v) = set("tools") {
        record.tools = v;
    }
    if let Some(v) = set("harnesses") {
        record.harnesses = v;
    }
    if let Some(v) = set("self_edit") {
        record.self_edit = v;
    }
    let engine = |v: Option<String>| v.filter(|v| !v.is_empty() && v != "default");
    if fields.contains_key("harness") {
        record.engine.harness = engine(text("harness"));
    }
    if fields.contains_key("model") {
        record.engine.model = engine(text("model"));
    }
    if fields.contains_key("effort") {
        record.engine.effort = engine(text("effort"));
    }
}

fn load(connection: &Connection, id: &str) -> anyhow::Result<Option<ChiefRecord>> {
    let stored: Option<Option<String>> = connection
        .query_row("SELECT record FROM chief WHERE id = ?1", [id], |row| row.get(0))
        .optional()?;
    stored.flatten().map(|text| serde_json::from_str(&text).map_err(Into::into)).transpose()
}

/// Deletes avatar bytes no live record names.
fn collect_avatars(tx: &rusqlite::Transaction<'_>) -> anyhow::Result<()> {
    let mut statement = tx.prepare("SELECT record FROM chief WHERE record IS NOT NULL")?;
    let rows = statement.query_map([], |row| row.get::<_, String>(0))?;
    let mut used = std::collections::BTreeSet::new();
    for row in rows {
        if let Some(avatar) = serde_json::from_str::<ChiefRecord>(&row?)?.avatar {
            used.insert(avatar.sha256);
        }
    }
    drop(statement);
    let stored: Vec<String> = {
        let mut statement = tx.prepare("SELECT sha256 FROM avatar")?;
        let rows = statement.query_map([], |row| row.get::<_, String>(0))?;
        rows.collect::<Result<_, _>>()?
    };
    for sha in stored.into_iter().filter(|sha| !used.contains(sha)) {
        tx.execute("DELETE FROM avatar WHERE sha256 = ?1", [sha])?;
    }
    Ok(())
}

/// The record as the wire shows it.
pub(crate) fn wire(record: &ChiefRecord) -> Value {
    serde_json::to_value(record).unwrap_or_else(|_| json!({}))
}

fn fingerprint(request: &Value) -> anyhow::Result<String> {
    Ok(hex(&Sha256::digest(serde_json::to_vec(request)?)))
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

fn now_ms() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |d| u64::try_from(d.as_millis()).unwrap_or(u64::MAX))
}

fn now_text() -> String {
    cmux_conversation::format_rfc3339_millis(now_ms())
}
