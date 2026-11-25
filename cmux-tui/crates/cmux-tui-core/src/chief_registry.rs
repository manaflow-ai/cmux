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
//! rows keyed by SHA-256: the ONE avatar store of the daemon, for Chiefs
//! (their record's `avatar`) and people (`participant_avatar`,
//! participant-avatars-v1); the write that drops the last reference of any
//! participant deletes them in the same transaction.
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

/// The tools a Chief may be granted (DESIGN.md section 4). `chiefs`: see,
/// make and edit other Chiefs within its own grant (server/chief_manage.rs).
pub(crate) const TOOLS: [&str; 7] =
    ["browser", "chiefs", "cloud_vms", "memory_import", "spawn", "tell", "workspaces"];
/// A new Chief's tools when the person names none (`chiefs` is on by
/// default, Lawrence 2026-10-14).
pub(crate) const DEFAULT_NEW_TOOLS: [&str; 4] = ["chiefs", "spawn", "tell", "workspaces"];
/// The grant fields of a record (who may hold what), by request field name.
pub(crate) const GRANT_FIELDS: [&str; 7] =
    ["effort", "harness", "harnesses", "locked", "model", "self_edit", "tools"];
/// The meta key of the one-time migration that gives every record that
/// existed before the `chiefs` grant was on by default that grant.
const CHIEFS_GRANT_MIGRATION: &str = "chiefs_grant_v1";
/// The fields a Chief may be allowed to change about itself. `engine` names
/// the three engine fields (`harness`, `model`, `effort`, [`ENGINE_FIELDS`]).
/// Every item is on by default for the default Chief and a new Chief
/// (Lawrence 2026-10-19, u2586: "chiefs can edit their own configuration");
/// the person narrows it, or locks the Chief (`locked`).
pub(crate) const SELF_EDITABLE: [&str; 6] =
    ["avatar", "display_name", "engine", "instructions", "personality", "role"];
/// The record fields the `engine` self_edit item covers.
pub(crate) const ENGINE_FIELDS: [&str; 3] = ["effort", "harness", "model"];
/// The `self_edit` item a request field needs: the field's own name, or
/// `engine` for an engine field.
pub(crate) fn self_edit_item(field: &str) -> &str {
    if ENGINE_FIELDS.contains(&field) { "engine" } else { field }
}
/// The meta key of the one-time migration that gives every record whose
/// `self_edit` is still the old default (`["avatar"]`) the full set.
const SELF_EDIT_MIGRATION: &str = "self_edit_v2";
/// Revisions kept per Chief in `chief_history` (the oldest go first).
pub(crate) const HISTORY_PER_CHIEF: i64 = 100;
/// The avatar types (the alias's media_type values).
pub(crate) const AVATAR_TYPES: [&str; 4] = ["image/gif", "image/jpeg", "image/png", "image/webp"];
/// The fields a page changes only on the person's gesture
/// (`chief-profile-ws-v1`): the person's grant (tools, harnesses, the engine's
/// harness, model and effort, self_edit), and what the Chief is told to do
/// (instructions, personality). Chief messages render in that page, so
/// injected content must not plant behavior a Chief then acts on.
pub(crate) const GESTURE_FIELDS: [&str; 9] = [
    "effort",
    "harness",
    "harnesses",
    "instructions",
    "locked",
    "model",
    "personality",
    "self_edit",
    "tools",
];

/// Whether request fields name a field a page changes only on the person's
/// gesture ([`GESTURE_FIELDS`]).
pub(crate) fn names_gesture_field(fields: &Map<String, Value>) -> bool {
    GESTURE_FIELDS.iter().any(|field| fields.contains_key(*field))
}

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
    /// `chief.profile.adopt`: the participant is already a live Chief record.
    AlreadyChief,
    /// `chief.profile.adopt`: the id is a deleted Chief (its tombstone, and
    /// its memory while kept); an adopt never revives it.
    DeletedChief,
    /// `chief.profile.adopt`: the default Chief is a record already.
    DefaultChief,
    /// `chief.profile.adopt`: no agent participant of a local conversation
    /// has this id (or it is a person).
    NotAgentParticipant,
    /// `chief.profile.adopt`: another Chief (live or deleted) has the same
    /// brain directory (`chief_brains::brain_home`: the id's last 8
    /// characters, lowercased), so adopting it would share or revive that
    /// brain and its memory.
    BrainHomeTaken,
    /// `chief.profile.adopt`: a connection is bound to the participant (its
    /// current agent session); two processes never speak as one participant.
    ParticipantBound,
    /// `chief.profile.undo`: no kept revision to go back to (or `to_rev` is
    /// not one).
    NoRevision,
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
            Self::AlreadyChief => "already_chief",
            Self::DeletedChief => "deleted_chief",
            Self::DefaultChief => "default_chief",
            Self::NotAgentParticipant => "not_an_agent_participant",
            Self::BrainHomeTaken => "brain_home_taken",
            Self::ParticipantBound => "participant_bound",
            Self::NoRevision => "no_revision",
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
    /// The person's lock: while true no Chief (itself included) changes the
    /// record; only the person does, and only the person sets it.
    #[serde(default)]
    pub locked: bool,
    pub is_default: bool,
    pub rev: u64,
    pub created_at: String,
    pub updated_at: String,
    /// The Chief that created this one with its `chiefs` grant (absent: the
    /// person made it); set by the daemon from the verified caller, never
    /// from a request, and not on the wire ([`wire`]).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub created_by: Option<String>,
}

/// A person's avatar write (`participant.avatar.set`), as committed.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub(crate) struct PersonAvatarWrite {
    pub avatar: Option<AvatarRef>,
    pub revision: u64,
    #[serde(default)]
    pub changed: bool,
    #[serde(default)]
    pub replayed: bool,
}

/// One kept revision of a Chief's record (`chief.profile.history`).
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct Revision {
    pub rev: u64,
    pub record: ChiefRecord,
    pub actor: String,
    pub operation: String,
    pub at: String,
}

impl Revision {
    pub(crate) fn wire(&self) -> Value {
        json!({"rev": self.rev, "at": self.at, "actor": self.actor,
               "operation": self.operation, "record": wire(&self.record)})
    }
}

/// The full `self_edit` set ([`SELF_EDITABLE`]), sorted.
pub(crate) fn full_self_edit() -> Vec<String> {
    SELF_EDITABLE.iter().map(|f| (*f).to_owned()).collect()
}

/// The fields of an update that makes `current` equal to `target` (the
/// profile, grant and engine fields that differ; never `locked`, which is the
/// person's alone and never undone by an undo), for `chief.profile.undo`. The
/// picture is apart: compare `avatar` yourself.
pub(crate) fn fields_to_restore(current: &ChiefRecord, target: &ChiefRecord) -> Map<String, Value> {
    let mut fields = Map::new();
    let mut text = |name: &str, now: &str, then: &str| {
        if now != then {
            fields.insert(name.into(), json!(then));
        }
    };
    text("display_name", &current.display_name, &target.display_name);
    text("role", &current.role, &target.role);
    text("personality", &current.personality, &target.personality);
    text("instructions", &current.instructions, &target.instructions);
    let engine = |v: &Option<String>| v.clone().unwrap_or_default();
    text("harness", &engine(&current.engine.harness), &engine(&target.engine.harness));
    text("model", &engine(&current.engine.model), &engine(&target.engine.model));
    text("effort", &engine(&current.engine.effort), &engine(&target.engine.effort));
    for (name, now, then) in [
        ("tools", &current.tools, &target.tools),
        ("harnesses", &current.harnesses, &target.harnesses),
        ("self_edit", &current.self_edit, &target.self_edit),
    ] {
        if now != then {
            fields.insert(name.into(), json!(then));
        }
    }
    fields
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
                crate::workspace_registry::wal_durability::attach_store(&connection, &path);
                connection
            }
            None => Connection::open_in_memory()?,
        };
        Self::initialize(connection)
    }

    fn initialize(mut connection: Connection) -> anyhow::Result<Self> {
        connection.busy_timeout(std::time::Duration::from_secs(5))?;
        connection.execute_batch(
            "PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL; PRAGMA fullfsync=ON;
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
             CREATE TABLE IF NOT EXISTS participant_avatar (
               participant TEXT PRIMARY KEY NOT NULL,
               sha256 TEXT NOT NULL,
               media_type TEXT NOT NULL,
               bytes INTEGER NOT NULL
             );
             CREATE TABLE IF NOT EXISTS chief_history (
               id TEXT NOT NULL,
               rev INTEGER NOT NULL,
               record TEXT NOT NULL,
               actor TEXT NOT NULL,
               operation TEXT NOT NULL,
               at TEXT NOT NULL,
               PRIMARY KEY (id, rev)
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
                self_edit: full_self_edit(),
                locked: false,
                is_default: true,
                rev: 1,
                created_at: now.clone(),
                updated_at: now,
                created_by: None,
            };
            transaction.execute(
                "INSERT INTO chief (id, seq, record) VALUES (?1, 0, ?2)",
                params![DEFAULT_CHIEF, serde_json::to_string(&record)?],
            )?;
        }
        migrate_chiefs_grant(&transaction)?;
        migrate_self_edit(&transaction)?;
        backfill_history(&transaction)?;
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

    /// The ids of deleted Chiefs (their tombstones), in deletion order.
    pub(crate) fn deleted(&self) -> anyhow::Result<Vec<String>> {
        let mut statement = self
            .connection
            .prepare("SELECT id FROM chief WHERE record IS NULL ORDER BY deleted_at ASC, id ASC")?;
        let rows = statement.query_map([], |row| row.get::<_, String>(0))?;
        rows.collect::<Result<_, _>>().map_err(Into::into)
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

    /// A person's avatar (participant-avatars-v1): its reference and bytes.
    pub(crate) fn person_avatar(&self, participant: &str) -> anyhow::Result<AvatarBytes> {
        let row: Option<(String, String, i64, Vec<u8>)> = self
            .connection
            .query_row(
                "SELECT p.sha256, p.media_type, p.bytes, a.data FROM participant_avatar p
                 JOIN avatar a ON a.sha256 = p.sha256 WHERE p.participant = ?1",
                [participant],
                |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?)),
            )
            .optional()?;
        Ok(row.map(|(sha256, media_type, bytes, data)| {
            (AvatarRef { sha256, media_type, bytes: u64::try_from(bytes).unwrap_or(0) }, data)
        }))
    }

    /// Sets or clears a person's avatar in the shared store, once per
    /// (`participant`, `key`): a replay with the same `request` answers the
    /// committed result (`replayed`), another request under the key is
    /// [`Refusal::KeyConflict`]. The bytes no participant references any more
    /// go in the same transaction. `revision` is the people's avatar
    /// revision (it moves on every change); `changed` is whether this write
    /// changed the stored picture.
    pub(crate) fn set_person_avatar(
        &mut self,
        participant: &str,
        key: &str,
        request: &Value,
        change: AvatarChange,
    ) -> anyhow::Result<Outcome<PersonAvatarWrite>> {
        let fingerprint = fingerprint(request)?;
        let transaction =
            self.connection.transaction_with_behavior(TransactionBehavior::Immediate)?;
        let committed: Option<(String, String, String)> = transaction
            .query_row(
                "SELECT fingerprint, result, operation FROM op_ledger WHERE actor = ?1 AND key = ?2",
                params![participant, key],
                |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
            )
            .optional()?;
        if let Some((stored, result, operation)) = committed {
            if stored != fingerprint {
                return Ok(Err(Refusal::KeyConflict(operation)));
            }
            let mut write: PersonAvatarWrite = serde_json::from_str(&result)?;
            write.replayed = true;
            write.changed = false;
            return Ok(Ok(write));
        }
        let before: Option<String> = transaction
            .query_row(
                "SELECT sha256 FROM participant_avatar WHERE participant = ?1",
                [participant],
                |r| r.get(0),
            )
            .optional()?;
        let stored = match change {
            AvatarChange::Set { media_type, bytes } => {
                let avatar = store_avatar_bytes(&transaction, &media_type, &bytes)?;
                transaction.execute(
                    "INSERT INTO participant_avatar (participant, sha256, media_type, bytes)
                     VALUES (?1, ?2, ?3, ?4)
                     ON CONFLICT(participant) DO UPDATE SET sha256 = excluded.sha256,
                       media_type = excluded.media_type, bytes = excluded.bytes",
                    params![participant, avatar.sha256, avatar.media_type, avatar.bytes as i64],
                )?;
                Some(avatar)
            }
            AvatarChange::Clear => {
                transaction.execute(
                    "DELETE FROM participant_avatar WHERE participant = ?1",
                    [participant],
                )?;
                None
            }
        };
        let text: Option<String> = transaction
            .query_row("SELECT value FROM meta WHERE key = 'avatar_rev'", [], |r| r.get(0))
            .optional()?;
        let mut revision: u64 = text.and_then(|t| t.parse().ok()).unwrap_or(0);
        let changed = before.as_deref() != stored.as_ref().map(|a| a.sha256.as_str());
        if changed {
            revision += 1;
            transaction.execute(
                "INSERT INTO meta (key, value) VALUES ('avatar_rev', ?1)
                 ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                [revision.to_string()],
            )?;
        }
        let write = PersonAvatarWrite { avatar: stored, revision, changed, replayed: false };
        transaction.execute(
            "INSERT INTO op_ledger (actor, key, operation, fingerprint, result)
             VALUES (?1, ?2, 'participant.avatar.set', ?3, ?4)",
            params![participant, key, fingerprint, serde_json::to_string(&write)?],
        )?;
        transaction.execute(
            "DELETE FROM op_ledger WHERE actor = ?1 AND seq NOT IN
               (SELECT seq FROM op_ledger WHERE actor = ?1 ORDER BY seq DESC LIMIT ?2)",
            params![participant, LEDGER_KEYS_PER_ACTOR],
        )?;
        collect_avatars(&transaction)?;
        transaction.commit()?;
        Ok(Ok(write))
    }

    /// A Chief's kept revisions, newest first, at most `limit`: every
    /// committed state of its record with the actor and operation that made
    /// it (`chief.profile.history`).
    pub(crate) fn history(&self, id: &str, limit: i64) -> anyhow::Result<Vec<Revision>> {
        let mut statement = self.connection.prepare(
            "SELECT rev, record, actor, operation, at FROM chief_history
             WHERE id = ?1 ORDER BY rev DESC LIMIT ?2",
        )?;
        let rows = statement.query_map(params![id, limit.clamp(1, HISTORY_PER_CHIEF)], |row| {
            Ok((
                row.get::<_, i64>(0)?,
                row.get::<_, String>(1)?,
                row.get::<_, String>(2)?,
                row.get::<_, String>(3)?,
                row.get::<_, String>(4)?,
            ))
        })?;
        let mut revisions = Vec::new();
        for row in rows {
            let (rev, record, actor, operation, at) = row?;
            revisions.push(Revision {
                rev: u64::try_from(rev).unwrap_or(0),
                record: serde_json::from_str(&record)?,
                actor,
                operation,
                at,
            });
        }
        Ok(revisions)
    }

    /// The bytes of a kept picture (an undo restores a picture by its hash).
    pub(crate) fn avatar_bytes(&self, sha256: &str) -> anyhow::Result<Option<Vec<u8>>> {
        Ok(self
            .connection
            .query_row("SELECT data FROM avatar WHERE sha256 = ?1", [sha256], |row| row.get(0))
            .optional()?)
    }

    /// The ledger's actors, oldest first (tests: who a write is recorded as).
    #[cfg(test)]
    pub(crate) fn ledger_actors(&self) -> rusqlite::Result<Vec<String>> {
        let mut statement = self.connection.prepare("SELECT actor FROM op_ledger ORDER BY seq")?;
        statement.query_map([], |row| row.get(0))?.collect()
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
        if operation == "chief.profile.delete" {
            // A deleted Chief has nothing to undo to (an undo never revives
            // it), and its kept revisions would hold its pictures.
            transaction.execute("DELETE FROM chief_history WHERE id = ?1", [&record.id])?;
        } else {
            keep_revision(&transaction, &record, actor, operation)?;
        }
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
    insert_new(tx, &id, now_ms, fields).map(Ok)
}

/// `chief.profile.adopt`'s write: a record for an existing agent participant
/// `id` (already checked to be one, and not `agent_mux`), with `create`'s
/// defaults, `display_name` unless `fields` names one, and only the given
/// fields. A live record or a tombstone of `id` refuses: an adopt never
/// revives a deleted Chief (or the memory kept for it).
pub(crate) fn adopt(
    tx: &rusqlite::Transaction<'_>,
    id: &str,
    display_name: &str,
    fields: &Map<String, Value>,
    claim: impl FnOnce() -> anyhow::Result<bool>,
) -> anyhow::Result<Outcome<ChiefRecord>> {
    if id == DEFAULT_CHIEF {
        return Ok(Err(Refusal::DefaultChief));
    }
    let existing: Option<Option<String>> =
        tx.query_row("SELECT record FROM chief WHERE id = ?1", [id], |r| r.get(0)).optional()?;
    match existing {
        Some(Some(_)) => return Ok(Err(Refusal::AlreadyChief)),
        Some(None) => return Ok(Err(Refusal::DeletedChief)),
        None => {}
    }
    // The brain directory is the id's last 8 characters (chief_brains.rs):
    // a ULID's random bits for a created Chief, but any text for an adopted
    // one. No two records, live or deleted, may share it.
    let tail = |id: &str| id.get(id.len().saturating_sub(8)..).unwrap_or(id).to_ascii_lowercase();
    let mine = tail(id);
    let taken = {
        let mut statement = tx.prepare("SELECT id FROM chief")?;
        let ids = statement.query_map([], |r| r.get::<_, String>(0))?;
        let mut taken = false;
        for other in ids {
            if tail(&other?) == mine {
                taken = true;
            }
        }
        taken
    };
    if taken {
        return Ok(Err(Refusal::BrainHomeTaken));
    }
    let live: i64 =
        tx.query_row("SELECT COUNT(*) FROM chief WHERE record IS NOT NULL", [], |r| r.get(0))?;
    if usize::try_from(live).unwrap_or(usize::MAX) >= MAX_CHIEFS {
        return Ok(Err(Refusal::TooMany));
    }
    // Last, inside this write: the participant must have no bound connection,
    // and every credential issued for it is revoked (`claim`), so the old
    // agent session never speaks as the Chief. The revoke commits in the
    // conversation store; should the insert below then fail, the agent stays
    // without a credential and no Chief is made (fails safe: the person mints
    // a new credential).
    if !claim()? {
        return Ok(Err(Refusal::ParticipantBound));
    }
    let mut fields = fields.clone();
    fields.entry("display_name").or_insert_with(|| Value::String(display_name.to_owned()));
    insert_new(tx, id, now_ms(), &fields).map(Ok)
}

/// A new live record `id` with `create`'s defaults and `fields` applied.
fn insert_new(
    tx: &rusqlite::Transaction<'_>,
    id: &str,
    now_ms: u64,
    fields: &Map<String, Value>,
) -> anyhow::Result<ChiefRecord> {
    let seq: i64 = tx.query_row("SELECT COALESCE(MAX(seq), 0) + 1 FROM chief", [], |r| r.get(0))?;
    let now = cmux_conversation::format_rfc3339_millis(now_ms);
    let mut record = ChiefRecord {
        id: id.to_owned(),
        display_name: String::new(),
        role: String::new(),
        personality: String::new(),
        instructions: String::new(),
        avatar: None,
        tools: DEFAULT_NEW_TOOLS.iter().map(|t| (*t).to_owned()).collect(),
        harnesses: Vec::new(),
        engine: Engine::default(),
        self_edit: full_self_edit(),
        locked: false,
        is_default: false,
        rev: 1,
        created_at: now.clone(),
        updated_at: now,
        created_by: None,
    };
    apply(&mut record, fields);
    tx.execute(
        "INSERT INTO chief (id, seq, record) VALUES (?1, ?2, ?3)",
        params![id, seq, serde_json::to_string(&record)?],
    )?;
    Ok(record)
}

/// `chief.profile.create` by the Chief `creator` (its `chiefs` grant):
/// [`create`], with the record naming its creator.
pub(crate) fn create_by_chief(
    tx: &rusqlite::Transaction<'_>,
    fields: &Map<String, Value>,
    creator: &str,
) -> anyhow::Result<Outcome<ChiefRecord>> {
    let mut record = match create(tx, fields)? {
        Ok(record) => record,
        Err(refusal) => return Ok(Err(refusal)),
    };
    record.created_by = Some(creator.to_owned());
    tx.execute(
        "UPDATE chief SET record = ?2 WHERE id = ?1",
        params![record.id, serde_json::to_string(&record)?],
    )?;
    Ok(Ok(record))
}

/// The record `record` would be after `fields` (already checked): what a
/// grant check compares before the write.
pub(crate) fn preview(record: &ChiefRecord, fields: &Map<String, Value>) -> ChiefRecord {
    let mut next = record.clone();
    apply(&mut next, fields);
    next
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
            record.avatar = Some(store_avatar_bytes(tx, &media_type, &bytes)?);
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
        .or_else(|| {
            fields
                .get("locked")
                .filter(|v| !v.is_boolean())
                .map(|_| Refusal::Invalid("locked", "must be true or false".into()))
        })
}

/// The media type of an avatar image from its first bytes (PNG, JPEG, GIF
/// or WebP), never from what a caller claims; `None` for anything else.
pub(crate) fn sniff_avatar(bytes: &[u8]) -> Option<&'static str> {
    if bytes.starts_with(b"\x89PNG\r\n\x1a\n") {
        Some("image/png")
    } else if bytes.starts_with(&[0xFF, 0xD8, 0xFF]) {
        Some("image/jpeg")
    } else if bytes.starts_with(b"GIF87a") || bytes.starts_with(b"GIF89a") {
        Some("image/gif")
    } else if bytes.len() >= 12 && &bytes[..4] == b"RIFF" && &bytes[8..12] == b"WEBP" {
        Some("image/webp")
    } else {
        None
    }
}

/// Checks an avatar image: 1 to [`MAX_AVATAR_BYTES`] bytes of a PNG, JPEG,
/// GIF or WebP; returns its media type (from the bytes).
pub(crate) fn validate_avatar(bytes: &[u8]) -> Result<&'static str, Refusal> {
    if bytes.is_empty() || bytes.len() > MAX_AVATAR_BYTES {
        return Err(Refusal::Invalid("data", format!("must be 1 to {MAX_AVATAR_BYTES} bytes")));
    }
    sniff_avatar(bytes)
        .ok_or_else(|| Refusal::Invalid("data", "must be a PNG, JPEG, GIF or WebP image".into()))
}

/// Keeps `bytes` once in the shared store; their reference.
fn store_avatar_bytes(
    tx: &rusqlite::Transaction<'_>,
    media_type: &str,
    bytes: &[u8],
) -> anyhow::Result<AvatarRef> {
    let sha256 = hex(&Sha256::digest(bytes));
    tx.execute(
        "INSERT OR IGNORE INTO avatar (sha256, media_type, data) VALUES (?1, ?2, ?3)",
        params![sha256, media_type, bytes],
    )?;
    Ok(AvatarRef { sha256, media_type: media_type.to_owned(), bytes: bytes.len() as u64 })
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
    if let Some(v) = fields.get("locked").and_then(Value::as_bool) {
        record.locked = v;
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

/// A new Chief's tools before `chiefs` was on by default.
const OLD_DEFAULT_NEW_TOOLS: [&str; 3] = ["spawn", "tell", "workspaces"];
/// The ledger actor of the one-time `chiefs` grant migration.
const MIGRATION_ACTOR: &str = "daemon via migration";

/// Gives `chiefs` once to every live record of a registry made before it was
/// on by default whose tools the person never set (they are still the old
/// default set; the documented "a missing grant reads as granted"). A record
/// whose tools the person chose keeps them. Each change is written to the
/// ledger as actor [`MIGRATION_ACTOR`]. From then on `chiefs` is a set member
/// the person can remove.
fn migrate_chiefs_grant(tx: &rusqlite::Transaction<'_>) -> anyhow::Result<()> {
    let done: bool = tx.query_row(
        "SELECT EXISTS(SELECT 1 FROM meta WHERE key = ?1)",
        [CHIEFS_GRANT_MIGRATION],
        |r| r.get(0),
    )?;
    if done {
        return Ok(());
    }
    let rows: Vec<(String, String)> = {
        let mut statement = tx.prepare("SELECT id, record FROM chief WHERE record IS NOT NULL")?;
        let rows = statement.query_map([], |row| Ok((row.get(0)?, row.get(1)?)))?;
        rows.collect::<Result<_, _>>()?
    };
    for (id, text) in rows {
        let mut record: ChiefRecord = serde_json::from_str(&text)?;
        if record.tools != OLD_DEFAULT_NEW_TOOLS {
            continue;
        }
        record.tools.push("chiefs".into());
        record.tools.sort();
        record.rev += 1;
        record.updated_at = now_text();
        let text = serde_json::to_string(&record)?;
        tx.execute("UPDATE chief SET record = ?2 WHERE id = ?1", params![id, text])?;
        let request = json!({"migration": CHIEFS_GRANT_MIGRATION, "chief": id});
        tx.execute(
            "INSERT OR IGNORE INTO op_ledger (actor, key, operation, fingerprint, result)
             VALUES (?1, ?2, 'chief.profile.migrate', ?3, ?4)",
            params![
                MIGRATION_ACTOR,
                format!("{CHIEFS_GRANT_MIGRATION}:{id}"),
                fingerprint(&request)?,
                text
            ],
        )?;
    }
    tx.execute("INSERT INTO meta (key, value) VALUES (?1, '1')", [CHIEFS_GRANT_MIGRATION])?;
    Ok(())
}

/// Gives the full `self_edit` set once to every live record whose set is
/// still the old default `["avatar"]` (the person never chose one), so every
/// Chief may edit its own configuration (u2586); a record whose set the
/// person chose keeps it. Each change is in the ledger as [`MIGRATION_ACTOR`]
/// and in the history.
fn migrate_self_edit(tx: &rusqlite::Transaction<'_>) -> anyhow::Result<()> {
    let done: bool = tx.query_row(
        "SELECT EXISTS(SELECT 1 FROM meta WHERE key = ?1)",
        [SELF_EDIT_MIGRATION],
        |r| r.get(0),
    )?;
    if done {
        return Ok(());
    }
    let rows: Vec<(String, String)> = {
        let mut statement = tx.prepare("SELECT id, record FROM chief WHERE record IS NOT NULL")?;
        let rows = statement.query_map([], |row| Ok((row.get(0)?, row.get(1)?)))?;
        rows.collect::<Result<_, _>>()?
    };
    for (id, text) in rows {
        let mut record: ChiefRecord = serde_json::from_str(&text)?;
        if record.self_edit != ["avatar"] {
            continue;
        }
        record.self_edit = full_self_edit();
        record.rev += 1;
        record.updated_at = now_text();
        let text = serde_json::to_string(&record)?;
        tx.execute("UPDATE chief SET record = ?2 WHERE id = ?1", params![id, text])?;
        let request = json!({"migration": SELF_EDIT_MIGRATION, "chief": id});
        tx.execute(
            "INSERT OR IGNORE INTO op_ledger (actor, key, operation, fingerprint, result)
             VALUES (?1, ?2, 'chief.profile.migrate', ?3, ?4)",
            params![
                MIGRATION_ACTOR,
                format!("{SELF_EDIT_MIGRATION}:{id}"),
                fingerprint(&request)?,
                text
            ],
        )?;
    }
    tx.execute("INSERT INTO meta (key, value) VALUES (?1, '1')", [SELF_EDIT_MIGRATION])?;
    Ok(())
}

/// Keeps every live record's current state as a revision when it has none
/// yet (a registry from before the history, or a migration's change), so the
/// first change after it can be undone.
fn backfill_history(tx: &rusqlite::Transaction<'_>) -> anyhow::Result<()> {
    let rows: Vec<String> = {
        let mut statement = tx.prepare(
            "SELECT c.record FROM chief c WHERE c.record IS NOT NULL AND NOT EXISTS
               (SELECT 1 FROM chief_history h WHERE h.id = c.id)",
        )?;
        let rows = statement.query_map([], |row| row.get(0))?;
        rows.collect::<Result<_, _>>()?
    };
    for text in rows {
        let record: ChiefRecord = serde_json::from_str(&text)?;
        keep_revision(tx, &record, MIGRATION_ACTOR, "chief.profile.backfill")?;
    }
    Ok(())
}

/// Keeps `record`'s state as its revision (once per rev) and drops the
/// oldest past [`HISTORY_PER_CHIEF`].
fn keep_revision(
    tx: &rusqlite::Transaction<'_>,
    record: &ChiefRecord,
    actor: &str,
    operation: &str,
) -> anyhow::Result<()> {
    tx.execute(
        "INSERT OR IGNORE INTO chief_history (id, rev, record, actor, operation, at)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
        params![
            record.id,
            i64::try_from(record.rev).unwrap_or(i64::MAX),
            serde_json::to_string(record)?,
            actor,
            operation,
            record.updated_at
        ],
    )?;
    tx.execute(
        "DELETE FROM chief_history WHERE id = ?1 AND rev NOT IN
           (SELECT rev FROM chief_history WHERE id = ?1 ORDER BY rev DESC LIMIT ?2)",
        params![record.id, HISTORY_PER_CHIEF],
    )?;
    Ok(())
}

fn load(connection: &Connection, id: &str) -> anyhow::Result<Option<ChiefRecord>> {
    let stored: Option<Option<String>> = connection
        .query_row("SELECT record FROM chief WHERE id = ?1", [id], |row| row.get(0))
        .optional()?;
    stored.flatten().map(|text| serde_json::from_str(&text).map_err(Into::into)).transpose()
}

/// Deletes avatar bytes that no live Chief record and no person names.
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
    let mut people = tx.prepare("SELECT sha256 FROM participant_avatar")?;
    for sha in people.query_map([], |row| row.get::<_, String>(0))? {
        used.insert(sha?);
    }
    drop(people);
    // A kept revision's picture stays until the revision goes (an undo
    // restores it).
    let mut kept = tx.prepare("SELECT record FROM chief_history")?;
    for row in kept.query_map([], |row| row.get::<_, String>(0))? {
        if let Some(avatar) = serde_json::from_str::<ChiefRecord>(&row?)?.avatar {
            used.insert(avatar.sha256);
        }
    }
    drop(kept);
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
/// `created_by` stays inside the daemon: the catalog's record has no such
/// field, and the rule it serves is the daemon's (server/chief_manage.rs).
pub(crate) fn wire(record: &ChiefRecord) -> Value {
    let mut value = serde_json::to_value(record).unwrap_or_else(|_| json!({}));
    if let Some(fields) = value.as_object_mut() {
        fields.remove("created_by");
    }
    value
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
