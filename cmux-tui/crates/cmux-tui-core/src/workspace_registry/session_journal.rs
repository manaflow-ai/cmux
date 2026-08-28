use super::*;
use base64::Engine;
use flate2::read::GzDecoder;
use rusqlite::Row;
use std::borrow::Cow;
use std::collections::{BTreeMap, BTreeSet, HashMap, HashSet};
use std::io::Read;
use std::sync::Arc;
use std::time::{SystemTime, UNIX_EPOCH};

const JOURNAL_RECORD_SCHEMA_VERSION: u32 = 1;
const MAX_JOURNAL_PAGE_SIZE: usize = 1024;
pub(super) const MAX_JOURNAL_SEGMENT_UNCOMPRESSED_BYTES: usize = 16 * 1024 * 1024;
pub(super) const MAX_JOURNAL_CONTENT_BYTES: usize = 256 * 1024;
const MIGRATION_EVENT_ID: &str = "event_session_journal_v9_migration";
const MIGRATION_EVENT_KIND: &str = "session.journal.migrated";

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum JournalClass {
    State,
    Observation,
    Effect,
    Checkpoint,
}

impl JournalClass {
    pub(super) fn as_str(self) -> &'static str {
        match self {
            Self::State => "state",
            Self::Observation => "observation",
            Self::Effect => "effect",
            Self::Checkpoint => "checkpoint",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum JournalReplayPolicy {
    Required,
    Advisory,
    Never,
}

impl JournalReplayPolicy {
    pub(super) fn as_str(self) -> &'static str {
        match self {
            Self::Required => "required",
            Self::Advisory => "advisory",
            Self::Never => "never",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum JournalSensitivity {
    Public,
    Metadata,
    Sensitive,
    Secret,
}

impl JournalSensitivity {
    pub(super) fn as_str(self) -> &'static str {
        match self {
            Self::Public => "public",
            Self::Metadata => "metadata",
            Self::Sensitive => "sensitive",
            Self::Secret => "secret",
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct JournalProducer {
    pub kind: String,
    pub id: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct JournalAuthority {
    pub principal_id: String,
    pub lease_id: String,
    pub generation: String,
    pub role: String,
}

#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct JournalSubject {
    pub kind: String,
    pub id: String,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct SessionJournalRecord {
    pub sequence: u64,
    pub event_id: String,
    pub schema_version: u32,
    pub kind: String,
    pub class: JournalClass,
    pub replay: JournalReplayPolicy,
    pub occurred_at_ms: u64,
    pub committed_at_ms: u64,
    pub producer: JournalProducer,
    pub authority: Option<JournalAuthority>,
    pub causation_id: Option<String>,
    pub correlation_id: Option<String>,
    pub causation_depth: u16,
    pub subjects: Vec<JournalSubject>,
    pub sensitivity: JournalSensitivity,
    pub payload: Value,
    pub resource_revision: Option<u64>,
    pub previous_resource_revision: Option<u64>,
    /// Exact high-volume content stored on the immutable journal row. It is
    /// omitted from serde so storage segments and public wire envelopes can
    /// choose their own bounded encoding without duplicating it in payload
    /// JSON.
    #[serde(skip)]
    pub(crate) terminal_output: Option<Arc<[u8]>>,
}

#[derive(Debug, Clone, PartialEq)]
pub struct SessionJournalPage {
    pub head_sequence: u64,
    pub records: Vec<SessionJournalRecord>,
}

/// A journal cursor can be unrecoverable because it points beyond the
/// current head or before the retained history. These are the only replay
/// errors that a derived reducer may repair by rebuilding from the head.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum SessionJournalCursorError {
    Ahead { requested: u64, head: u64 },
    Gap { requested: u64, first_retained: u64 },
}

impl std::fmt::Display for SessionJournalCursorError {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Ahead { requested, head } => {
                write!(formatter, "cursor.invalid: journal sequence {requested} is ahead of {head}")
            }
            Self::Gap { requested, first_retained } => write!(
                formatter,
                "cursor.gap: journal history before sequence {first_retained} is no longer retained after {requested}"
            ),
        }
    }
}

impl std::error::Error for SessionJournalCursorError {}

pub(crate) struct SessionJournalSubjectPage {
    pub(crate) head_sequence: u64,
    pub(crate) scanned_through: u64,
    pub(crate) records: Vec<SessionJournalRecord>,
}

/// One retained `terminal.output` record's content and stream coverage.
#[derive(Debug, Clone, PartialEq)]
pub(crate) struct TerminalOutputChunk {
    pub(crate) stream_offset_start: u64,
    pub(crate) stream_offset_end: u64,
    pub(crate) bytes: Arc<[u8]>,
}

/// A record-boundary window over one terminal generation's output stream.
#[derive(Debug, Clone, PartialEq)]
pub(crate) struct TerminalOutputRecordsWindow {
    pub(crate) chunks: Vec<TerminalOutputChunk>,
    /// More retained records follow this window (the byte budget cut it).
    pub(crate) truncated: bool,
}

/// A short-lived WAL reader owned by one subscriber thread. It never shares
/// the registry writer connection or its mutex.
pub(crate) struct SessionJournalReader {
    connection: Connection,
}

impl SessionJournalReader {
    pub(crate) fn open(database_path: &Path) -> anyhow::Result<Self> {
        let connection = open_registry_database_with_flags(
            database_path,
            OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_NO_MUTEX,
        )
        .with_context(|| format!("open session journal reader {}", database_path.display()))?;
        connection.busy_timeout(std::time::Duration::from_secs(5))?;
        connection.execute_batch("PRAGMA query_only=ON; PRAGMA foreign_keys=ON;")?;
        Ok(Self { connection })
    }

    pub(crate) fn after(&self, sequence: u64, limit: usize) -> anyhow::Result<SessionJournalPage> {
        query_session_journal_after(&self.connection, sequence, limit)
    }

    pub(crate) fn after_subjects(
        &self,
        sequence: u64,
        limit: usize,
        subjects: &[JournalSubject],
    ) -> anyhow::Result<SessionJournalSubjectPage> {
        query_session_journal_after_subjects(&self.connection, sequence, limit, subjects)
    }
}

pub(super) struct JournalAppend<'a> {
    pub(super) event_id: &'a str,
    pub(super) schema_version: u32,
    pub(super) kind: &'a str,
    pub(super) class: JournalClass,
    pub(super) replay: JournalReplayPolicy,
    pub(super) occurred_at_ms: u64,
    pub(super) producer: &'a JournalProducer,
    pub(super) authority: Option<&'a JournalAuthority>,
    pub(super) causation_id: Option<&'a str>,
    pub(super) correlation_id: Option<&'a str>,
    pub(super) causation_depth: u16,
    pub(super) subjects: &'a [JournalSubject],
    pub(super) sensitivity: JournalSensitivity,
    pub(super) payload: &'a Value,
    pub(super) content: Option<&'a [u8]>,
    pub(super) resource_revision: Option<u64>,
    pub(super) previous_resource_revision: Option<u64>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) enum ResourceEffectJournalState {
    Succeeded,
    Failed,
    Indeterminate,
}

impl ResourceEffectJournalState {
    fn as_str(self) -> &'static str {
        match self {
            Self::Succeeded => "succeeded",
            Self::Failed => "failed",
            Self::Indeterminate => "indeterminate",
        }
    }
}

pub(super) fn create_session_journal_schema(transaction: &Transaction<'_>) -> anyhow::Result<()> {
    let subject_index_existed = transaction.query_row(
        "SELECT EXISTS(
           SELECT 1 FROM sqlite_master
           WHERE type = 'table' AND name = 'journal_subject_index'
         )",
        [],
        |row| row.get::<_, bool>(0),
    )?;
    transaction.execute_batch(
        "CREATE TABLE IF NOT EXISTS session_journal (
           sequence INTEGER PRIMARY KEY AUTOINCREMENT,
           event_id TEXT UNIQUE NOT NULL,
           schema_version INTEGER NOT NULL CHECK(schema_version > 0),
           kind TEXT NOT NULL,
           class TEXT NOT NULL CHECK(class IN ('state', 'observation', 'effect', 'checkpoint')),
           replay_policy TEXT NOT NULL CHECK(replay_policy IN ('required', 'advisory', 'never')),
           occurred_at_ms INTEGER NOT NULL CHECK(occurred_at_ms >= 0),
           committed_at_ms INTEGER NOT NULL CHECK(committed_at_ms >= 0),
           producer_json TEXT NOT NULL CHECK(json_valid(producer_json)),
           authority_json TEXT CHECK(authority_json IS NULL OR json_valid(authority_json)),
           causation_id TEXT,
           correlation_id TEXT,
           causation_depth INTEGER NOT NULL CHECK(causation_depth >= 0),
           subjects_json TEXT NOT NULL CHECK(json_valid(subjects_json)),
           sensitivity TEXT NOT NULL CHECK(sensitivity IN ('public', 'metadata', 'sensitive', 'secret')),
           payload_json TEXT NOT NULL CHECK(json_valid(payload_json)),
           content BLOB,
           resource_revision INTEGER UNIQUE,
           previous_resource_revision INTEGER,
           CHECK(
             (resource_revision IS NULL AND previous_resource_revision IS NULL)
             OR (
               resource_revision IS NOT NULL
               AND previous_resource_revision IS NOT NULL
               AND resource_revision = previous_resource_revision + 1
             )
           )
         );
         CREATE INDEX IF NOT EXISTS session_journal_by_kind_sequence
           ON session_journal(kind, sequence);
         CREATE INDEX IF NOT EXISTS session_journal_by_correlation_sequence
           ON session_journal(correlation_id, sequence)
           WHERE correlation_id IS NOT NULL;
         CREATE TABLE IF NOT EXISTS journal_subject_index (
           sequence INTEGER NOT NULL CHECK(sequence > 0),
           kind TEXT NOT NULL,
           id TEXT NOT NULL,
           PRIMARY KEY(sequence, kind, id)
         ) WITHOUT ROWID;
         CREATE INDEX IF NOT EXISTS journal_subject_index_by_subject_sequence
           ON journal_subject_index(kind, id, sequence);
         CREATE TABLE IF NOT EXISTS journal_event_index (
           event_id TEXT PRIMARY KEY NOT NULL,
           sequence INTEGER UNIQUE NOT NULL CHECK(sequence > 0),
           causation_depth INTEGER NOT NULL CHECK(causation_depth >= 0),
           causation_id TEXT,
           causal_hook_id TEXT,
           resource_revision INTEGER,
           previous_resource_revision INTEGER,
           CHECK(
             (resource_revision IS NULL AND previous_resource_revision IS NULL)
             OR (
               resource_revision IS NOT NULL
               AND previous_resource_revision IS NOT NULL
               AND resource_revision = previous_resource_revision + 1
             )
           )
         );
         INSERT OR IGNORE INTO journal_event_index(event_id, sequence, causation_depth)
           SELECT event_id, sequence, causation_depth FROM session_journal;
         CREATE TRIGGER IF NOT EXISTS session_journal_reject_update
           BEFORE UPDATE ON session_journal
         BEGIN
           SELECT RAISE(ABORT, 'session journal is append-only');
         END;
         CREATE TRIGGER IF NOT EXISTS session_journal_reject_delete
           BEFORE DELETE ON session_journal
         BEGIN
           SELECT RAISE(ABORT, 'session journal is append-only');
         END;
         CREATE TRIGGER IF NOT EXISTS journal_subject_index_reject_update
           BEFORE UPDATE ON journal_subject_index
         BEGIN
           SELECT RAISE(ABORT, 'journal subject index is append-only');
         END;
         CREATE TRIGGER IF NOT EXISTS journal_subject_index_reject_delete
           BEFORE DELETE ON journal_subject_index
         BEGIN
           SELECT RAISE(ABORT, 'journal subject index is append-only');
         END;",
    )?;
    if !subject_index_existed {
        transaction.execute_batch(
            "INSERT OR IGNORE INTO journal_subject_index(sequence, kind, id)
               SELECT journal.sequence,
                      json_extract(subject.value, '$.kind'),
                      json_extract(subject.value, '$.id')
               FROM session_journal AS journal, json_each(journal.subjects_json) AS subject
               WHERE json_type(subject.value, '$.kind') = 'text'
                 AND json_type(subject.value, '$.id') = 'text';",
        )?;
    }
    ensure_session_journal_content_schema(transaction)?;
    ensure_journal_event_index_schema(transaction)?;
    Ok(())
}

fn ensure_session_journal_content_schema(transaction: &Transaction<'_>) -> anyhow::Result<()> {
    let columns = {
        let mut statement = transaction.prepare("PRAGMA table_info(session_journal)")?;
        statement
            .query_map([], |row| row.get::<_, String>(1))?
            .collect::<Result<HashSet<_>, _>>()?
    };
    if !columns.contains("content") {
        transaction.execute("ALTER TABLE session_journal ADD COLUMN content BLOB", [])?;
    }
    transaction.execute_batch(
        "CREATE TABLE IF NOT EXISTS journal_terminal_streams (
           terminal_id TEXT NOT NULL,
           generation TEXT NOT NULL,
           next_offset INTEGER NOT NULL CHECK(next_offset >= 0),
           PRIMARY KEY(terminal_id, generation)
         );",
    )?;
    Ok(())
}

pub(super) fn ensure_journal_event_index_schema(
    transaction: &Transaction<'_>,
) -> anyhow::Result<()> {
    let columns = {
        let mut statement = transaction.prepare("PRAGMA table_info(journal_event_index)")?;
        statement
            .query_map([], |row| row.get::<_, String>(1))?
            .collect::<Result<HashSet<_>, _>>()?
    };
    let added_causation_id = !columns.contains("causation_id");
    let added_causal_hook_id = !columns.contains("causal_hook_id");
    let added_resource_revision = !columns.contains("resource_revision");
    let added_previous_resource_revision = !columns.contains("previous_resource_revision");
    if added_causation_id {
        transaction.execute("ALTER TABLE journal_event_index ADD COLUMN causation_id TEXT", [])?;
    }
    if added_causal_hook_id {
        transaction
            .execute("ALTER TABLE journal_event_index ADD COLUMN causal_hook_id TEXT", [])?;
    }
    if added_resource_revision {
        transaction
            .execute("ALTER TABLE journal_event_index ADD COLUMN resource_revision INTEGER", [])?;
    }
    if added_previous_resource_revision {
        transaction.execute(
            "ALTER TABLE journal_event_index ADD COLUMN previous_resource_revision INTEGER",
            [],
        )?;
    }
    let backfilled = transaction
        .query_row("SELECT 1 FROM meta WHERE key = 'journal_event_index_causation_v1'", [], |_| {
            Ok(())
        })
        .optional()?
        .is_some();
    if added_causation_id || added_causal_hook_id || !backfilled {
        transaction.execute_batch(
            "UPDATE journal_event_index
           SET causation_id = (
             SELECT causation_id FROM session_journal
             WHERE session_journal.event_id = journal_event_index.event_id
           )
         WHERE causation_id IS NULL
           AND event_id IN (
             SELECT event_id FROM session_journal WHERE causation_id IS NOT NULL
           );
         WITH RECURSIVE hook_descendants(event_id, hook_id) AS (
           SELECT event_id, json_extract(producer_json, '$.id')
           FROM session_journal
           WHERE json_extract(producer_json, '$.kind') = 'hook_dispatcher'
           UNION
           SELECT child.event_id, parent.hook_id
           FROM session_journal child
           JOIN hook_descendants parent ON child.causation_id = parent.event_id
         )
         UPDATE journal_event_index
         SET causal_hook_id = (
           SELECT hook_id FROM hook_descendants
           WHERE hook_descendants.event_id = journal_event_index.event_id
         )
         WHERE event_id IN (SELECT event_id FROM hook_descendants);
         INSERT INTO meta(key, value)
           VALUES('journal_event_index_causation_v1', '1')
         ON CONFLICT(key) DO UPDATE SET value = excluded.value;",
        )?;
    }
    let resource_backfilled = transaction
        .query_row("SELECT 1 FROM meta WHERE key = 'journal_event_index_resource_v1'", [], |_| {
            Ok(())
        })
        .optional()?
        .is_some();
    if added_resource_revision || added_previous_resource_revision || !resource_backfilled {
        transaction.execute_batch(
            "UPDATE journal_event_index
             SET resource_revision = (
                   SELECT resource_revision FROM session_journal
                   WHERE session_journal.event_id = journal_event_index.event_id
                 ),
                 previous_resource_revision = (
                   SELECT previous_resource_revision FROM session_journal
                   WHERE session_journal.event_id = journal_event_index.event_id
                 )
             WHERE resource_revision IS NULL
               AND event_id IN (
                 SELECT event_id FROM session_journal WHERE resource_revision IS NOT NULL
               );
             UPDATE journal_event_index
             SET resource_revision = CAST(
                   substr(event_id, length('event_resource_') + 1) AS INTEGER
                 ),
                 previous_resource_revision = CAST(
                   substr(event_id, length('event_resource_') + 1) AS INTEGER
                 ) - 1
             WHERE resource_revision IS NULL
               AND length(event_id) = length('event_resource_') + 20
               AND substr(event_id, 1, length('event_resource_')) = 'event_resource_'
               AND substr(event_id, length('event_resource_') + 1) NOT GLOB '*[^0-9]*'
               AND event_id BETWEEN 'event_resource_00000000000000000001'
                                AND 'event_resource_09223372036854775807';
             INSERT INTO meta(key, value)
               VALUES('journal_event_index_resource_v1', '1')
             ON CONFLICT(key) DO UPDATE SET value = excluded.value;",
        )?;
    }
    transaction.execute_batch(
        "CREATE INDEX IF NOT EXISTS journal_event_index_by_causal_hook
           ON journal_event_index(causal_hook_id, sequence)
           WHERE causal_hook_id IS NOT NULL;
         CREATE UNIQUE INDEX IF NOT EXISTS journal_event_index_by_resource_revision
           ON journal_event_index(resource_revision)
           WHERE resource_revision IS NOT NULL;",
    )?;
    Ok(())
}

pub(super) fn migrate_resource_events_to_session_journal(
    transaction: &Transaction<'_>,
) -> anyhow::Result<()> {
    create_session_journal_schema(transaction)?;
    let has_resource_events = table_exists(transaction, "resource_events")?;

    let session_id = transaction.query_row(
        "SELECT value FROM meta WHERE key = 'session_public_id'",
        [],
        |row| row.get::<_, String>(0),
    )?;
    let (oldest_revision, newest_revision) = if has_resource_events {
        transaction.query_row(
            "SELECT MIN(revision), MAX(revision) FROM resource_events",
            [],
            |row| Ok((row.get::<_, Option<i64>>(0)?, row.get::<_, Option<i64>>(1)?)),
        )?
    } else {
        (None, None)
    };
    let resource_head_revision = transaction_resource_revision(transaction)?;
    let history_complete = resource_head_revision == 0
        || (oldest_revision == Some(1)
            && newest_revision
                == Some(
                    i64::try_from(resource_head_revision)
                        .context("resource revision exceeds SQLite range")?,
                ));
    let subject = JournalSubject { kind: "session".into(), id: session_id };
    let producer = JournalProducer { kind: "migration".into(), id: "workspace-registry-v8".into() };
    let payload = serde_json::json!({
        "source": if has_resource_events { "resource_events" } else { "projection_only" },
        "oldest_retained_resource_revision": oldest_revision.map(|value| value.to_string()),
        "newest_retained_resource_revision": newest_revision.map(|value| value.to_string()),
        "resource_head_revision": resource_head_revision.to_string(),
        "history_complete": history_complete,
    });
    let existing_migration_kind = transaction
        .query_row(
            "SELECT kind FROM session_journal WHERE event_id = ?1",
            [MIGRATION_EVENT_ID],
            |row| row.get::<_, String>(0),
        )
        .optional()?;
    if let Some(existing_kind) = existing_migration_kind {
        anyhow::ensure!(
            existing_kind == MIGRATION_EVENT_KIND,
            "session journal migration event id has unexpected kind {existing_kind:?}"
        );
    } else {
        append_journal_record(
            transaction,
            &JournalAppend {
                event_id: MIGRATION_EVENT_ID,
                schema_version: JOURNAL_RECORD_SCHEMA_VERSION,
                kind: MIGRATION_EVENT_KIND,
                class: JournalClass::Checkpoint,
                replay: JournalReplayPolicy::Required,
                occurred_at_ms: 0,
                producer: &producer,
                authority: None,
                causation_id: None,
                correlation_id: None,
                causation_depth: 0,
                subjects: &[subject],
                sensitivity: JournalSensitivity::Metadata,
                payload: &payload,
                content: None,
                resource_revision: None,
                previous_resource_revision: None,
            },
        )?;
    }

    let rows = if has_resource_events {
        let mut statement = transaction.prepare(
            "SELECT event.revision, event.previous_revision, event.origin,
                    event.idempotency_key, event.deltas_json,
                    mutation.operation, mutation.result_json
             FROM resource_events AS event
             LEFT JOIN resource_mutations AS mutation
               ON mutation.idempotency_key = event.idempotency_key
             ORDER BY event.revision ASC",
        )?;
        statement
            .query_map([], |row| {
                Ok((
                    row.get::<_, i64>(0)?,
                    row.get::<_, i64>(1)?,
                    row.get::<_, String>(2)?,
                    row.get::<_, String>(3)?,
                    row.get::<_, String>(4)?,
                    row.get::<_, Option<String>>(5)?,
                    row.get::<_, Option<String>>(6)?,
                ))
            })?
            .collect::<Result<Vec<_>, _>>()?
    } else {
        Vec::new()
    };
    for (revision, previous_revision, origin, idempotency_key, changes, operation, result) in rows {
        let revision = u64::try_from(revision).context("stored resource revision is negative")?;
        let previous_revision = u64::try_from(previous_revision)
            .context("stored previous resource revision is negative")?;
        let changes = serde_json::from_str::<Value>(&changes)?;
        let result = result
            .as_deref()
            .map(serde_json::from_str::<Value>)
            .transpose()?
            .unwrap_or(Value::Null);
        append_resource_journal_record_at(
            transaction,
            revision,
            previous_revision,
            &origin,
            &idempotency_key,
            operation.as_deref().unwrap_or("resource.legacy"),
            None,
            &result,
            &changes,
            0,
        )?;
    }
    if has_resource_events {
        transaction.execute_batch("DROP TABLE resource_events;")?;
    }
    Ok(())
}

#[allow(clippy::too_many_arguments)]
pub(super) fn append_resource_journal_record(
    transaction: &Transaction<'_>,
    revision: u64,
    previous_revision: u64,
    origin: &str,
    idempotency_key: &str,
    operation: &str,
    patch: Option<&ResourcePatch>,
    result: &Value,
    changes: &Value,
) -> anyhow::Result<()> {
    append_resource_journal_record_at(
        transaction,
        revision,
        previous_revision,
        origin,
        idempotency_key,
        operation,
        patch,
        result,
        changes,
        unix_epoch_ms()?,
    )
}

pub(super) fn append_resource_effect_journal_record(
    transaction: &Transaction<'_>,
    idempotency_key: &str,
    operation: &str,
    intent: &Value,
    outcome: Option<&Value>,
    state: ResourceEffectJournalState,
) -> anyhow::Result<()> {
    validate_identifier("journal operation", operation)?;
    let session_id = transaction.query_row(
        "SELECT value FROM meta WHERE key = 'session_public_id'",
        [],
        |row| row.get::<_, String>(0),
    )?;
    let creation = transaction
        .query_row(
            "SELECT correlation_key, attempt
             FROM resource_creation_receipts
             WHERE idempotency_key = ?1
             ORDER BY correlation_key
             LIMIT 1",
            [idempotency_key],
            |row| Ok((row.get::<_, String>(0)?, row.get::<_, i64>(1)?)),
        )
        .optional()?;
    let correlation_id = creation
        .as_ref()
        .map(|(correlation_key, _)| correlation_key.as_str())
        .unwrap_or(idempotency_key);
    let attempt = creation
        .as_ref()
        .map(|(_, attempt)| u64::try_from(*attempt).context("effect attempt is negative"))
        .transpose()?;

    let mut subjects =
        BTreeSet::from([JournalSubject { kind: "session".into(), id: session_id.clone() }]);
    collect_subjects(intent, &mut subjects);
    if let Some(outcome) = outcome {
        collect_subjects(outcome, &mut subjects);
    }
    expand_topology_subjects(transaction, &mut subjects)?;
    let subjects = subjects.into_iter().collect::<Vec<_>>();

    let mut event_digest = Sha256::new();
    event_digest.update(b"cmux.resource-effect.v1\0");
    event_digest.update(session_id.as_bytes());
    event_digest.update(b"\0");
    event_digest.update(idempotency_key.as_bytes());
    let event_id = format!("event_effect_{}", encode_bytes_hex(&event_digest.finalize()));
    let state_name = state.as_str();
    let kind = format!("{operation}.effect.{state_name}");
    let producer = JournalProducer { kind: "resource_operation".into(), id: "resource-api".into() };
    let payload = serde_json::json!({
        "format":"cmux.resource-effect.v1",
        "operation":operation,
        "idempotency_key":idempotency_key,
        "correlation_key":creation.as_ref().map(|(correlation_key, _)| correlation_key),
        "attempt":attempt.map(|attempt| attempt.to_string()),
        "state":state_name,
        "intent":intent,
        "outcome":outcome,
    });
    append_journal_record(
        transaction,
        &JournalAppend {
            event_id: &event_id,
            schema_version: JOURNAL_RECORD_SCHEMA_VERSION,
            kind: &kind,
            class: JournalClass::Effect,
            replay: JournalReplayPolicy::Never,
            occurred_at_ms: unix_epoch_ms()?,
            producer: &producer,
            authority: None,
            causation_id: None,
            correlation_id: Some(correlation_id),
            causation_depth: 0,
            subjects: &subjects,
            sensitivity: JournalSensitivity::Sensitive,
            payload: &payload,
            content: None,
            resource_revision: None,
            previous_resource_revision: None,
        },
    )?;
    Ok(())
}

#[allow(clippy::too_many_arguments)]
fn append_resource_journal_record_at(
    transaction: &Transaction<'_>,
    revision: u64,
    previous_revision: u64,
    origin: &str,
    idempotency_key: &str,
    operation: &str,
    patch: Option<&ResourcePatch>,
    result: &Value,
    changes: &Value,
    occurred_at_ms: u64,
) -> anyhow::Result<()> {
    validate_identifier("journal operation", operation)?;
    let kind = semantic_journal_kind(operation);
    let session_id = transaction.query_row(
        "SELECT value FROM meta WHERE key = 'session_public_id'",
        [],
        |row| row.get::<_, String>(0),
    )?;
    let mut subjects = BTreeSet::from([JournalSubject { kind: "session".into(), id: session_id }]);
    if let Some(patch) = patch {
        collect_patch_subjects(patch, &mut subjects);
    }
    collect_subjects(result, &mut subjects);
    collect_subjects(changes, &mut subjects);
    expand_topology_subjects(transaction, &mut subjects)?;
    let subjects = subjects.into_iter().collect::<Vec<_>>();
    let producer = JournalProducer { kind: "resource_operation".into(), id: origin.into() };
    let payload = serde_json::json!({
        "idempotency_key": idempotency_key,
        "result": result,
        "changes": changes,
    });
    let event_id = format!("event_resource_{revision:020}");
    append_journal_record(
        transaction,
        &JournalAppend {
            event_id: &event_id,
            schema_version: JOURNAL_RECORD_SCHEMA_VERSION,
            kind: &kind,
            class: JournalClass::State,
            replay: JournalReplayPolicy::Required,
            occurred_at_ms,
            producer: &producer,
            authority: None,
            causation_id: None,
            correlation_id: Some(idempotency_key),
            causation_depth: 0,
            subjects: &subjects,
            sensitivity: JournalSensitivity::Sensitive,
            payload: &payload,
            content: None,
            resource_revision: Some(revision),
            previous_resource_revision: Some(previous_revision),
        },
    )?;
    Ok(())
}

pub(super) fn append_journal_record(
    transaction: &Transaction<'_>,
    append: &JournalAppend<'_>,
) -> anyhow::Result<u64> {
    validate_identifier("journal event id", append.event_id)?;
    validate_identifier("journal event kind", append.kind)?;
    anyhow::ensure!(
        append.content.is_none_or(|content| !content.is_empty()),
        "journal content must not be empty"
    );
    anyhow::ensure!(
        append.content.is_none_or(|content| content.len() <= MAX_JOURNAL_CONTENT_BYTES),
        "journal content exceeds {MAX_JOURNAL_CONTENT_BYTES} bytes"
    );
    anyhow::ensure!(
        append.kind == "terminal.output" || append.content.is_none(),
        "journal content is not supported for kind {}",
        append.kind
    );
    let committed_at_ms = unix_epoch_ms()?;
    let subjects_json = canonical_json(&serde_json::to_value(append.subjects)?)?;
    transaction.execute(
        "INSERT INTO session_journal(
           event_id, schema_version, kind, class, replay_policy,
           occurred_at_ms, committed_at_ms, producer_json, authority_json,
           causation_id, correlation_id, causation_depth, subjects_json,
           sensitivity, payload_json, content, resource_revision, previous_resource_revision
         ) VALUES(?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16, ?17, ?18)",
        params![
            append.event_id,
            i64::from(append.schema_version),
            append.kind,
            append.class.as_str(),
            append.replay.as_str(),
            i64::try_from(append.occurred_at_ms).context("journal occurrence time is too large")?,
            i64::try_from(committed_at_ms).context("journal commit time is too large")?,
            canonical_json(&serde_json::to_value(append.producer)?)?,
            append
                .authority
                .map(serde_json::to_value)
                .transpose()?
                .as_ref()
                .map(canonical_json)
                .transpose()?,
            append.causation_id,
            append.correlation_id,
            i64::from(append.causation_depth),
            &subjects_json,
            append.sensitivity.as_str(),
            canonical_json(append.payload)?,
            append.content,
            append
                .resource_revision
                .map(i64::try_from)
                .transpose()
                .context("resource revision exceeds SQLite range")?,
            append
                .previous_resource_revision
                .map(i64::try_from)
                .transpose()
                .context("previous resource revision exceeds SQLite range")?,
        ],
    )?;
    let sequence = transaction.last_insert_rowid();
    let causal_hook_id = if append.producer.kind == "hook_dispatcher" {
        Some(append.producer.id.clone())
    } else if let Some(causation_id) = append.causation_id {
        transaction.query_row(
            "SELECT causal_hook_id FROM journal_event_index WHERE event_id = ?1",
            [causation_id],
            |row| row.get::<_, Option<String>>(0),
        )?
    } else {
        None
    };
    transaction.execute(
        "INSERT INTO journal_event_index(
           event_id, sequence, causation_depth, causation_id, causal_hook_id,
           resource_revision, previous_resource_revision
         ) VALUES(?1, ?2, ?3, ?4, ?5, ?6, ?7)",
        params![
            append.event_id,
            sequence,
            i64::from(append.causation_depth),
            append.causation_id,
            causal_hook_id,
            append
                .resource_revision
                .map(i64::try_from)
                .transpose()
                .context("resource revision exceeds SQLite range")?,
            append
                .previous_resource_revision
                .map(i64::try_from)
                .transpose()
                .context("previous resource revision exceeds SQLite range")?,
        ],
    )?;
    transaction.execute(
        "INSERT OR IGNORE INTO journal_subject_index(sequence, kind, id)
         SELECT ?1, json_extract(value, '$.kind'), json_extract(value, '$.id')
         FROM json_each(?2)",
        params![sequence, subjects_json],
    )?;
    u64::try_from(sequence).context("journal sequence is negative")
}

impl WorkspaceRegistry {
    pub fn session_journal_after(
        &self,
        sequence: u64,
        limit: usize,
    ) -> anyhow::Result<SessionJournalPage> {
        query_session_journal_after(&self.connection, sequence, limit)
    }

    /// Persisted fold position of one journal reducer: (version, cursor,
    /// snapshot). A version mismatch on load discards the snapshot so the
    /// reducer re-folds from the journal head.
    pub(crate) fn journal_reducer_state(
        &self,
        reducer_id: &str,
    ) -> anyhow::Result<Option<(u32, u64, String)>> {
        let raw = self
            .connection
            .query_row(
                "SELECT value FROM meta WHERE key = ?1",
                [format!("journal_reducer.{reducer_id}")],
                |row| row.get::<_, String>(0),
            )
            .optional()?;
        let Some(raw) = raw else { return Ok(None) };
        let value: Value = serde_json::from_str(&raw)
            .with_context(|| format!("journal reducer state for {reducer_id} is not JSON"))?;
        let version = value.get("version").and_then(Value::as_u64).unwrap_or(0) as u32;
        let cursor = value
            .get("cursor")
            .and_then(Value::as_str)
            .and_then(|cursor| cursor.parse::<u64>().ok())
            .unwrap_or(0);
        let snapshot =
            value.get("snapshot").and_then(Value::as_str).map(str::to_string).unwrap_or_default();
        Ok(Some((version, cursor, snapshot)))
    }

    /// Durably record a reducer's fold position and state snapshot. Cursor
    /// values are stored as strings so 64-bit sequences survive JSON.
    pub(crate) fn put_journal_reducer_state(
        &self,
        reducer_id: &str,
        version: u32,
        cursor: u64,
        snapshot: &str,
    ) -> anyhow::Result<()> {
        let value = serde_json::json!({
            "version": version,
            "cursor": cursor.to_string(),
            "snapshot": snapshot,
        });
        self.connection.execute(
            "INSERT INTO meta(key, value) VALUES(?1, ?2)
             ON CONFLICT(key) DO UPDATE SET value = excluded.value",
            params![format!("journal_reducer.{reducer_id}"), value.to_string()],
        )?;
        Ok(())
    }

    /// The most recently started journal output stream for one terminal:
    /// its generation and the exclusive end offset of its journaled bytes.
    pub(crate) fn terminal_stream_latest(
        &self,
        terminal_id: &str,
    ) -> anyhow::Result<Option<(String, u64)>> {
        let Some((generation, next_offset)) = self
            .connection
            .query_row(
                "SELECT generation, next_offset FROM journal_terminal_streams
                 WHERE terminal_id = ?1
                 ORDER BY rowid DESC LIMIT 1",
                params![terminal_id],
                |row| Ok((row.get::<_, String>(0)?, row.get::<_, i64>(1)?)),
            )
            .optional()?
        else {
            return Ok(None);
        };
        let next_offset =
            u64::try_from(next_offset).context("terminal journal offset is negative")?;
        Ok(Some((generation, next_offset)))
    }

    /// Retained live `terminal.output` records of one generation with bytes
    /// after `after`, in stream order, honoring record boundaries: the first
    /// matching record is always included whole, later records only while the
    /// accumulated content stays within `max_bytes`.
    ///
    /// Records archived into sealed journal segments are not served here:
    /// sealing is checkpoint-aligned, so archived output is covered by a
    /// retained vt-replay snapshot (a checkpoint blob for live terminals, the
    /// terminal exit snapshot for exited ones) and readers see the coverage
    /// clamp through the window's start offset.
    pub(crate) fn terminal_output_records_after(
        &self,
        terminal_id: &str,
        generation: &str,
        after: u64,
        max_bytes: u64,
    ) -> anyhow::Result<TerminalOutputRecordsWindow> {
        let mut statement = self.connection.prepare(
            "SELECT sequence, event_id, schema_version, kind, class, replay_policy,
                    occurred_at_ms, committed_at_ms, producer_json, authority_json,
                    causation_id, correlation_id, causation_depth, subjects_json,
                    sensitivity, payload_json, content, resource_revision,
                    previous_resource_revision
             FROM session_journal
             WHERE kind = 'terminal.output'
               AND EXISTS (
                 SELECT 1 FROM journal_subject_index AS subject
                 WHERE subject.sequence = session_journal.sequence
                   AND subject.kind = 'terminal' AND subject.id = ?1
               )
               AND json_extract(authority_json, '$.generation') = ?2
               AND CAST(json_extract(payload_json, '$.stream_offset_end') AS INTEGER) > ?3
             ORDER BY sequence ASC",
        )?;
        let rows = statement.query_map(
            params![
                terminal_id,
                generation,
                i64::try_from(after).context("terminal stream offset exceeds SQLite range")?,
            ],
            stored_record_row,
        )?;
        let mut chunks: Vec<TerminalOutputChunk> = Vec::new();
        let mut total_bytes = 0_u64;
        let mut truncated = false;
        for row in rows {
            let record = decode_record(row?)?;
            let bytes = record
                .terminal_output
                .clone()
                .context("terminal output record omitted its content")?;
            let stream_offset_start = decimal_payload_u64(&record.payload, "stream_offset_start")?;
            let stream_offset_end = decimal_payload_u64(&record.payload, "stream_offset_end")?;
            if let Some(previous) = chunks.last() {
                anyhow::ensure!(
                    stream_offset_start == previous.stream_offset_end,
                    "terminal output stream window contains an offset gap"
                );
            }
            let byte_count = u64::try_from(bytes.len())?;
            if !chunks.is_empty()
                && total_bytes.checked_add(byte_count).is_none_or(|total| total > max_bytes)
            {
                truncated = true;
                break;
            }
            total_bytes = total_bytes.saturating_add(byte_count);
            chunks.push(TerminalOutputChunk { stream_offset_start, stream_offset_end, bytes });
        }
        Ok(TerminalOutputRecordsWindow { chunks, truncated })
    }
}

pub(super) fn query_session_journal_after(
    connection: &Connection,
    sequence: u64,
    limit: usize,
) -> anyhow::Result<SessionJournalPage> {
    anyhow::ensure!(limit > 0, "journal page limit must be positive");
    anyhow::ensure!(
        limit <= MAX_JOURNAL_PAGE_SIZE,
        "journal page limit exceeds {MAX_JOURNAL_PAGE_SIZE}"
    );
    let head_sequence = connection.query_row(
        "SELECT MAX(
           COALESCE((SELECT MAX(sequence) FROM session_journal), 0),
           COALESCE((SELECT MAX(end_sequence) FROM journal_segments), 0)
         )",
        [],
        |row| row.get::<_, i64>(0),
    )?;
    let head_sequence =
        u64::try_from(head_sequence).context("journal head sequence is negative")?;
    if sequence > head_sequence {
        return Err(anyhow::Error::new(SessionJournalCursorError::Ahead {
            requested: sequence,
            head: head_sequence,
        }));
    }
    if let Some(first_retained) = first_retained_journal_sequence(connection)?
        && sequence.saturating_add(1) < first_retained
    {
        return Err(anyhow::Error::new(SessionJournalCursorError::Gap {
            requested: sequence,
            first_retained,
        }));
    }
    let mut records = archived_records_after(connection, sequence, limit)?;
    if records.len() >= limit {
        records.truncate(limit);
        return Ok(SessionJournalPage { head_sequence, records });
    }
    let active_after = records.last().map_or(sequence, |record| record.sequence);
    let mut statement = connection.prepare(
        "SELECT sequence, event_id, schema_version, kind, class, replay_policy,
                    occurred_at_ms, committed_at_ms, producer_json, authority_json,
                    causation_id, correlation_id, causation_depth, subjects_json,
                    sensitivity, payload_json, content, resource_revision,
                    previous_resource_revision
             FROM session_journal
             WHERE sequence > ?1
             ORDER BY sequence ASC
             LIMIT ?2",
    )?;
    let active = statement
        .query_map(
            params![
                i64::try_from(active_after).context("journal sequence exceeds SQLite range")?,
                i64::try_from(limit - records.len())
                    .context("journal page limit exceeds SQLite range")?,
            ],
            stored_record_row,
        )?
        .map(|row| decode_record(row?))
        .collect::<anyhow::Result<Vec<_>>>()?;
    records.extend(active);
    let mut expected_sequence = sequence.saturating_add(1);
    for record in &records {
        anyhow::ensure!(
            record.sequence == expected_sequence,
            "session journal contains a gap before sequence {}",
            record.sequence
        );
        expected_sequence = expected_sequence.saturating_add(1);
    }
    anyhow::ensure!(
        sequence == head_sequence || !records.is_empty(),
        "session journal contains a gap after sequence {sequence}"
    );
    Ok(SessionJournalPage { head_sequence, records })
}

fn first_retained_journal_sequence(connection: &Connection) -> anyhow::Result<Option<u64>> {
    // Keep each MIN over its indexed column. Wrapping both tables in one
    // UNION makes SQLite materialize the full history for every page read.
    let active = connection.query_row(
        "SELECT MIN(sequence) FROM session_journal",
        [],
        |row| row.get::<_, Option<i64>>(0),
    )?;
    let archived = connection.query_row(
        "SELECT MIN(start_sequence) FROM journal_segments",
        [],
        |row| row.get::<_, Option<i64>>(0),
    )?;
    active
        .into_iter()
        .chain(archived)
        .min()
        .map(|value| u64::try_from(value).context("first retained journal sequence is negative"))
        .transpose()
}

pub(super) fn query_session_journal_sequences(
    connection: &Connection,
    sequences: &[u64],
) -> anyhow::Result<Vec<SessionJournalRecord>> {
    if sequences.is_empty() {
        return Ok(Vec::new());
    }
    anyhow::ensure!(
        sequences.len() <= MAX_JOURNAL_PAGE_SIZE,
        "journal sequence batch exceeds {MAX_JOURNAL_PAGE_SIZE}"
    );
    let requested = sequences.iter().copied().map(i64::try_from).collect::<Result<Vec<_>, _>>()?;
    let requested_json = serde_json::to_string(&requested)?;
    let requested_set = sequences.iter().copied().collect::<HashSet<_>>();
    let mut records = BTreeMap::new();

    let mut segment_statement = connection.prepare(
        "SELECT segment_id, start_sequence, end_sequence, record_count, codec,
                content, uncompressed_bytes, sha256
         FROM journal_segments
         WHERE EXISTS (
           SELECT 1 FROM json_each(?1) requested
           WHERE CAST(requested.value AS INTEGER) BETWEEN start_sequence AND end_sequence
         )
         ORDER BY start_sequence ASC",
    )?;
    let segments = segment_statement
        .query_map([&requested_json], journal_segment_row)?
        .collect::<Result<Vec<_>, _>>()?;
    drop(segment_statement);
    for segment in segments {
        for record in decode_journal_segment(segment)?.records {
            if requested_set.contains(&record.sequence) {
                records.insert(record.sequence, record);
            }
        }
    }

    let mut active_statement = connection.prepare(
        "SELECT sequence, event_id, schema_version, kind, class, replay_policy,
                occurred_at_ms, committed_at_ms, producer_json, authority_json,
                causation_id, correlation_id, causation_depth, subjects_json,
                sensitivity, payload_json, content, resource_revision,
                previous_resource_revision
         FROM session_journal
         WHERE sequence IN (SELECT CAST(value AS INTEGER) FROM json_each(?1))
         ORDER BY sequence ASC",
    )?;
    let active = active_statement
        .query_map([&requested_json], stored_record_row)?
        .map(|row| decode_record(row?))
        .collect::<anyhow::Result<Vec<_>>>()?;
    drop(active_statement);
    for record in active {
        records.insert(record.sequence, record);
    }
    anyhow::ensure!(
        records.len() == requested_set.len(),
        "one or more requested journal records are absent"
    );
    Ok(records.into_values().collect())
}

fn query_session_journal_after_subjects(
    connection: &Connection,
    sequence: u64,
    limit: usize,
    subjects: &[JournalSubject],
) -> anyhow::Result<SessionJournalSubjectPage> {
    anyhow::ensure!(limit > 0, "journal page limit must be positive");
    anyhow::ensure!(
        limit <= MAX_JOURNAL_PAGE_SIZE,
        "journal page limit exceeds {MAX_JOURNAL_PAGE_SIZE}"
    );
    anyhow::ensure!(!subjects.is_empty(), "journal subject filter must not be empty");
    let head_sequence = connection.query_row(
        "SELECT MAX(
           COALESCE((SELECT MAX(sequence) FROM session_journal), 0),
           COALESCE((SELECT MAX(end_sequence) FROM journal_segments), 0)
         )",
        [],
        |row| row.get::<_, i64>(0),
    )?;
    let head_sequence =
        u64::try_from(head_sequence).context("journal head sequence is negative")?;
    anyhow::ensure!(
        sequence <= head_sequence,
        "cursor.invalid: journal sequence {sequence} is ahead of {head_sequence}"
    );
    let requested_json = canonical_json(&serde_json::to_value(subjects)?)?;
    let mut statement = connection.prepare(
        "SELECT DISTINCT indexed.sequence
         FROM json_each(?1) AS requested
         JOIN journal_subject_index AS indexed
           INDEXED BY journal_subject_index_by_subject_sequence
           ON indexed.kind = json_extract(requested.value, '$.kind')
          AND indexed.id = json_extract(requested.value, '$.id')
         WHERE indexed.sequence > ?2
         ORDER BY indexed.sequence ASC
         LIMIT ?3",
    )?;
    let sequences = statement
        .query_map(
            params![
                requested_json,
                i64::try_from(sequence).context("journal sequence exceeds SQLite range")?,
                i64::try_from(limit).context("journal page limit exceeds SQLite range")?,
            ],
            |row| row.get::<_, i64>(0),
        )?
        .map(|row| {
            u64::try_from(row?).map_err(|error| {
                rusqlite::Error::FromSqlConversionFailure(
                    0,
                    rusqlite::types::Type::Integer,
                    Box::new(error),
                )
            })
        })
        .collect::<Result<Vec<_>, _>>()?;
    drop(statement);
    let records = query_session_journal_sequences(connection, &sequences)?;
    let scanned_through = if sequences.len() == limit {
        sequences.last().copied().unwrap_or(sequence)
    } else {
        head_sequence
    };
    Ok(SessionJournalSubjectPage { head_sequence, scanned_through, records })
}

type JournalSegmentRow = (String, i64, i64, i64, String, Vec<u8>, i64, Vec<u8>);

fn journal_segment_row(row: &Row<'_>) -> rusqlite::Result<JournalSegmentRow> {
    Ok((
        row.get(0)?,
        row.get(1)?,
        row.get(2)?,
        row.get(3)?,
        row.get(4)?,
        row.get(5)?,
        row.get(6)?,
        row.get(7)?,
    ))
}

struct DecodedJournalSegment {
    start_sequence: u64,
    end_sequence: u64,
    records: Vec<SessionJournalRecord>,
}

fn decode_journal_segment(row: JournalSegmentRow) -> anyhow::Result<DecodedJournalSegment> {
    let (
        segment_id,
        start_sequence,
        end_sequence,
        record_count,
        codec,
        compressed,
        expected_bytes,
        expected_digest,
    ) = row;
    let start_sequence = u64::try_from(start_sequence)?;
    let end_sequence = u64::try_from(end_sequence)?;
    let record_count = usize::try_from(record_count)?;
    anyhow::ensure!(codec == "gzip-json-v1", "journal segment {segment_id} codec is invalid");
    anyhow::ensure!(record_count > 0, "journal segment {segment_id} record count is invalid");
    anyhow::ensure!(
        start_sequence <= end_sequence,
        "journal segment {segment_id} sequence range is invalid"
    );
    let expected_bytes = usize::try_from(expected_bytes)?;
    anyhow::ensure!(
        expected_bytes <= MAX_JOURNAL_SEGMENT_UNCOMPRESSED_BYTES,
        "journal segment {segment_id} exceeds the uncompressed size limit"
    );
    let decoder = GzDecoder::new(compressed.as_slice());
    // The segment header already carries a validated byte count. Reserve it
    // once, so decompression does not repeatedly grow and copy the buffer.
    let mut uncompressed = Vec::with_capacity(expected_bytes);
    decoder
        .take(u64::try_from(expected_bytes)?.saturating_add(1))
        .read_to_end(&mut uncompressed)
        .with_context(|| format!("decompress journal segment {segment_id}"))?;
    anyhow::ensure!(
        expected_bytes == uncompressed.len(),
        "journal segment {segment_id} length is invalid"
    );
    anyhow::ensure!(
        Sha256::digest(&uncompressed).as_slice() == expected_digest.as_slice(),
        "journal segment {segment_id} digest is invalid"
    );
    let mut records: Vec<SessionJournalRecord> = serde_json::from_slice(&uncompressed)
        .with_context(|| format!("decode journal segment {segment_id}"))?;
    for record in &mut records {
        normalize_terminal_output(record, None)
            .with_context(|| format!("validate journal segment {segment_id}"))?;
    }
    anyhow::ensure!(
        records.len() == record_count,
        "journal segment {segment_id} record count is invalid"
    );
    anyhow::ensure!(
        records.first().map(|record| record.sequence) == Some(start_sequence)
            && records.last().map(|record| record.sequence) == Some(end_sequence),
        "journal segment {segment_id} sequence range is invalid"
    );
    for pair in records.windows(2) {
        anyhow::ensure!(
            pair[1].sequence == pair[0].sequence.saturating_add(1),
            "journal segment {segment_id} contains a sequence gap"
        );
    }
    Ok(DecodedJournalSegment { start_sequence, end_sequence, records })
}

fn archived_records_after(
    connection: &Connection,
    sequence: u64,
    limit: usize,
) -> anyhow::Result<Vec<SessionJournalRecord>> {
    let mut statement = connection.prepare(
        "SELECT segment_id, start_sequence, end_sequence, record_count, codec,
                content, uncompressed_bytes, sha256
         FROM journal_segments
         WHERE end_sequence > ?1
         ORDER BY start_sequence ASC
         LIMIT ?2",
    )?;
    let mut segments = statement
        .query_map(params![i64::try_from(sequence)?, i64::try_from(limit)?], journal_segment_row)?;
    let mut records = Vec::new();
    let mut previous_end = None;
    for segment in &mut segments {
        let decoded = decode_journal_segment(segment?)?;
        let start_sequence = decoded.start_sequence;
        let end_sequence = decoded.end_sequence;
        if let Some(previous_end) = previous_end {
            anyhow::ensure!(
                start_sequence == previous_end + 1,
                "journal segments contain a gap before sequence {start_sequence}"
            );
        } else {
            anyhow::ensure!(
                start_sequence <= sequence.saturating_add(1),
                "journal segments contain a gap before sequence {start_sequence}"
            );
        }
        previous_end = Some(end_sequence);
        for record in decoded.records.into_iter().filter(|record| record.sequence > sequence) {
            records.push(record);
            if records.len() == limit {
                return Ok(records);
            }
        }
    }
    Ok(records)
}

type StoredRecordRow = (
    i64,
    String,
    i64,
    String,
    String,
    String,
    i64,
    i64,
    String,
    Option<String>,
    Option<String>,
    Option<String>,
    i64,
    String,
    String,
    String,
    Option<Vec<u8>>,
    Option<i64>,
    Option<i64>,
);

fn stored_record_row(row: &Row<'_>) -> rusqlite::Result<StoredRecordRow> {
    Ok((
        row.get(0)?,
        row.get(1)?,
        row.get(2)?,
        row.get(3)?,
        row.get(4)?,
        row.get(5)?,
        row.get(6)?,
        row.get(7)?,
        row.get(8)?,
        row.get(9)?,
        row.get(10)?,
        row.get(11)?,
        row.get(12)?,
        row.get(13)?,
        row.get(14)?,
        row.get(15)?,
        row.get(16)?,
        row.get(17)?,
        row.get(18)?,
    ))
}

fn decode_record(row: StoredRecordRow) -> anyhow::Result<SessionJournalRecord> {
    let (
        sequence,
        event_id,
        schema_version,
        kind,
        class,
        replay,
        occurred_at_ms,
        committed_at_ms,
        producer,
        authority,
        causation_id,
        correlation_id,
        causation_depth,
        subjects,
        sensitivity,
        payload,
        content,
        resource_revision,
        previous_resource_revision,
    ) = row;
    let mut record = SessionJournalRecord {
        sequence: u64::try_from(sequence).context("journal sequence is negative")?,
        event_id,
        schema_version: u32::try_from(schema_version)
            .context("journal schema version is invalid")?,
        kind,
        class: match class.as_str() {
            "state" => JournalClass::State,
            "observation" => JournalClass::Observation,
            "effect" => JournalClass::Effect,
            "checkpoint" => JournalClass::Checkpoint,
            _ => anyhow::bail!("unknown journal class {class:?}"),
        },
        replay: match replay.as_str() {
            "required" => JournalReplayPolicy::Required,
            "advisory" => JournalReplayPolicy::Advisory,
            "never" => JournalReplayPolicy::Never,
            _ => anyhow::bail!("unknown journal replay policy {replay:?}"),
        },
        occurred_at_ms: u64::try_from(occurred_at_ms)
            .context("journal occurrence time is negative")?,
        committed_at_ms: u64::try_from(committed_at_ms)
            .context("journal commit time is negative")?,
        producer: serde_json::from_str(&producer)?,
        authority: authority.as_deref().map(serde_json::from_str).transpose()?,
        causation_id,
        correlation_id,
        causation_depth: u16::try_from(causation_depth)
            .context("journal causation depth is invalid")?,
        subjects: serde_json::from_str(&subjects)?,
        sensitivity: match sensitivity.as_str() {
            "public" => JournalSensitivity::Public,
            "metadata" => JournalSensitivity::Metadata,
            "sensitive" => JournalSensitivity::Sensitive,
            "secret" => JournalSensitivity::Secret,
            _ => anyhow::bail!("unknown journal sensitivity {sensitivity:?}"),
        },
        payload: serde_json::from_str(&payload)?,
        resource_revision: resource_revision
            .map(u64::try_from)
            .transpose()
            .context("journal resource revision is negative")?,
        previous_resource_revision: previous_resource_revision
            .map(u64::try_from)
            .transpose()
            .context("journal previous resource revision is negative")?,
        terminal_output: None,
    };
    normalize_terminal_output(&mut record, content)?;
    Ok(record)
}

fn normalize_terminal_output(
    record: &mut SessionJournalRecord,
    stored_content: Option<Vec<u8>>,
) -> anyhow::Result<()> {
    if record.kind != "terminal.output" {
        anyhow::ensure!(stored_content.is_none(), "non-terminal journal record contains content");
        return Ok(());
    }
    anyhow::ensure!(
        record.payload["format"].as_str() == Some("cmux.terminal-output.v1"),
        "terminal output record has an invalid format"
    );
    let bytes = if let Some(bytes) = stored_content {
        anyhow::ensure!(
            record.payload["encoding"].as_str() == Some("raw"),
            "stored terminal output record has an invalid encoding"
        );
        anyhow::ensure!(
            record.payload.get("data").is_none(),
            "stored terminal output record duplicates inline content"
        );
        bytes
    } else {
        anyhow::ensure!(
            record.payload["encoding"].as_str() == Some("base64"),
            "archived terminal output record has an invalid encoding"
        );
        let data = record
            .payload
            .as_object_mut()
            .and_then(|payload| payload.remove("data"))
            .and_then(|data| data.as_str().map(str::to_owned))
            .context("archived terminal output record omitted data")?;
        let bytes = base64::engine::general_purpose::STANDARD
            .decode(data)
            .context("decode archived terminal output")?;
        record.payload["encoding"] = Value::String("raw".into());
        bytes
    };
    anyhow::ensure!(!bytes.is_empty(), "terminal output record is empty");
    anyhow::ensure!(
        bytes.len() <= MAX_JOURNAL_CONTENT_BYTES,
        "terminal output record exceeds the content limit"
    );
    let byte_count = decimal_payload_u64(&record.payload, "byte_count")?;
    anyhow::ensure!(
        byte_count == u64::try_from(bytes.len())?,
        "terminal output byte_count does not match its content"
    );
    let start = decimal_payload_u64(&record.payload, "stream_offset_start")?;
    let end = decimal_payload_u64(&record.payload, "stream_offset_end")?;
    anyhow::ensure!(
        end.checked_sub(start) == Some(byte_count),
        "terminal output stream offsets do not match its content"
    );
    let expected_digest =
        record.payload["sha256"].as_str().context("terminal output record omitted sha256")?;
    anyhow::ensure!(
        expected_digest == encode_bytes_hex(Sha256::digest(&bytes).as_slice()),
        "terminal output content digest is invalid"
    );
    record.terminal_output = Some(Arc::from(bytes));
    Ok(())
}

fn decimal_payload_u64(payload: &Value, field: &str) -> anyhow::Result<u64> {
    payload[field]
        .as_str()
        .with_context(|| format!("terminal output record omitted {field}"))?
        .parse()
        .with_context(|| format!("terminal output record has an invalid {field}"))
}

fn encode_bytes_hex(bytes: &[u8]) -> String {
    const HEX: &[u8; 16] = b"0123456789abcdef";
    let mut encoded = String::with_capacity(bytes.len() * 2);
    for byte in bytes {
        encoded.push(char::from(HEX[usize::from(byte >> 4)]));
        encoded.push(char::from(HEX[usize::from(byte & 0x0f)]));
    }
    encoded
}

pub(super) fn journal_record_for_archive(record: &SessionJournalRecord) -> SessionJournalRecord {
    let mut archived = record.clone();
    if let Some(bytes) = record.terminal_output.as_deref()
        && let Some(payload) = archived.payload.as_object_mut()
    {
        payload.insert("encoding".into(), Value::String("base64".into()));
        payload.insert(
            "data".into(),
            Value::String(base64::engine::general_purpose::STANDARD.encode(bytes)),
        );
        archived.terminal_output = None;
    }
    archived
}

fn collect_patch_subjects(patch: &ResourcePatch, subjects: &mut BTreeSet<JournalSubject>) {
    for change in &patch.changes {
        match change {
            ResourceChange::UpsertWorkspace { workspace, active_screen, .. } => {
                insert_subject(subjects, "workspace", workspace.public_id.as_str());
                if let Some(screen) = active_screen {
                    insert_subject(subjects, "screen", screen.as_str());
                }
            }
            ResourceChange::TombstoneWorkspace { workspace_id } => {
                insert_subject(subjects, "workspace", workspace_id.as_str());
            }
            ResourceChange::SetWorkspaceOrder { workspace_ids } => {
                for workspace in workspace_ids {
                    insert_subject(subjects, "workspace", workspace.as_str());
                }
            }
            ResourceChange::SetActiveWorkspace { workspace_id } => {
                if let Some(workspace) = workspace_id {
                    insert_subject(subjects, "workspace", workspace.as_str());
                }
            }
            ResourceChange::UpsertScreen(screen) => {
                insert_subject(subjects, "screen", screen.public_id.as_str());
                insert_subject(subjects, "workspace", screen.workspace_id.as_str());
                insert_subject(subjects, "pane", screen.active_pane.as_str());
                if let Some(pane) = &screen.zoomed_pane {
                    insert_subject(subjects, "pane", pane.as_str());
                }
                if let Some(panes) = &screen.auto_layout {
                    for pane in panes {
                        insert_subject(subjects, "pane", pane.as_str());
                    }
                }
                collect_layout_subjects(&screen.layout, subjects);
                for column in &screen.viewport.columns {
                    insert_subject(subjects, "split", column.id.as_str());
                    collect_layout_subjects(&column.layout, subjects);
                    if let Some(panes) = &column.auto_layout {
                        for pane in panes {
                            insert_subject(subjects, "pane", pane.as_str());
                        }
                    }
                }
            }
            ResourceChange::TombstoneScreen { screen_id } => {
                insert_subject(subjects, "screen", screen_id.as_str());
            }
            ResourceChange::SetScreenOrder { workspace_id, screen_ids } => {
                insert_subject(subjects, "workspace", workspace_id.as_str());
                for screen in screen_ids {
                    insert_subject(subjects, "screen", screen.as_str());
                }
            }
            ResourceChange::UpsertPane(pane) => {
                insert_subject(subjects, "pane", pane.public_id.as_str());
                insert_subject(subjects, "screen", pane.screen_id.as_str());
                if let Some(tab) = &pane.active_tab {
                    insert_subject(subjects, "tab", tab.as_str());
                }
            }
            ResourceChange::TombstonePane { pane_id } => {
                insert_subject(subjects, "pane", pane_id.as_str());
            }
            ResourceChange::UpsertTab(tab) => {
                insert_subject(subjects, "tab", tab.public_id.as_str());
                insert_subject(subjects, "pane", tab.pane_id.as_str());
                match &tab.content_id {
                    ContentPublicId::Terminal(terminal) => {
                        insert_subject(subjects, "terminal", terminal.as_str());
                    }
                    ContentPublicId::Browser(browser) => {
                        insert_subject(subjects, "browser", browser.as_str());
                    }
                }
            }
            ResourceChange::TombstoneTab { tab_id, .. } => {
                insert_subject(subjects, "tab", tab_id.as_str());
            }
            ResourceChange::SetTabOrder { pane_id, tab_ids } => {
                insert_subject(subjects, "pane", pane_id.as_str());
                for tab in tab_ids {
                    insert_subject(subjects, "tab", tab.as_str());
                }
            }
            ResourceChange::UpsertTerminal { public_id, .. }
            | ResourceChange::TombstoneTerminal { public_id, .. } => {
                insert_subject(subjects, "terminal", public_id.as_str());
            }
            ResourceChange::UpsertBrowser(browser) => {
                insert_subject(subjects, "browser", browser.public_id.as_str());
            }
            ResourceChange::TombstoneBrowser { public_id } => {
                insert_subject(subjects, "browser", public_id.as_str());
            }
        }
    }
}

fn collect_layout_subjects(layout: &RegistryLayoutNode, subjects: &mut BTreeSet<JournalSubject>) {
    match layout {
        RegistryLayoutNode::Leaf { pane } => insert_subject(subjects, "pane", pane.as_str()),
        RegistryLayoutNode::Split { split, first, second, .. } => {
            insert_subject(subjects, "split", split.as_str());
            collect_layout_subjects(first, subjects);
            collect_layout_subjects(second, subjects);
        }
        RegistryLayoutNode::Stack { panes, expanded } => {
            for pane in panes {
                insert_subject(subjects, "pane", pane.as_str());
            }
            insert_subject(subjects, "pane", expanded.as_str());
        }
    }
}

fn insert_subject(subjects: &mut BTreeSet<JournalSubject>, kind: &str, id: &str) {
    subjects.insert(JournalSubject { kind: kind.into(), id: id.into() });
}

fn collect_subjects(value: &Value, subjects: &mut BTreeSet<JournalSubject>) {
    match value {
        Value::Array(values) => {
            for value in values {
                collect_subjects(value, subjects);
            }
        }
        Value::Object(values) => {
            for value in values.values() {
                collect_subjects(value, subjects);
            }
        }
        Value::String(value) => {
            if let Some(kind) = public_id_kind(value) {
                subjects.insert(JournalSubject { kind: kind.into(), id: value.clone() });
            }
        }
        Value::Null | Value::Bool(_) | Value::Number(_) => {}
    }
}

pub(super) fn expand_topology_subjects(
    transaction: &Transaction<'_>,
    subjects: &mut BTreeSet<JournalSubject>,
) -> anyhow::Result<()> {
    if !subjects.iter().any(|subject| {
        matches!(subject.kind.as_str(), "screen" | "pane" | "tab" | "terminal" | "browser")
    }) {
        return Ok(());
    }
    let ids = subjects.iter().map(|subject| &subject.id).collect::<Vec<_>>();
    let ids_json = canonical_json(&serde_json::to_value(ids)?)?;
    let mut statement = transaction.prepare(
        "WITH seeds(id) AS (
           SELECT value FROM json_each(?1)
         ),
         tab_paths(tab_id, pane_id, screen_id, workspace_id) AS (
           SELECT tab.public_id, tab.pane_id, pane.screen_id, screen.workspace_id
           FROM resource_tabs AS tab
           JOIN resource_panes AS pane ON pane.public_id = tab.pane_id
           JOIN resource_screens AS screen ON screen.public_id = pane.screen_id
           WHERE tab.public_id IN (SELECT id FROM seeds)
              OR tab.content_id IN (SELECT id FROM seeds)
         ),
         pane_paths(pane_id, screen_id, workspace_id) AS (
           SELECT pane.public_id, pane.screen_id, screen.workspace_id
           FROM resource_panes AS pane
           JOIN resource_screens AS screen ON screen.public_id = pane.screen_id
           WHERE pane.public_id IN (SELECT id FROM seeds)
         ),
         screen_paths(screen_id, workspace_id) AS (
           SELECT screen.public_id, screen.workspace_id
           FROM resource_screens AS screen
           WHERE screen.public_id IN (SELECT id FROM seeds)
         )
         SELECT 'tab', tab_id FROM tab_paths
         UNION SELECT 'pane', pane_id FROM tab_paths
         UNION SELECT 'screen', screen_id FROM tab_paths
         UNION SELECT 'workspace', workspace_id FROM tab_paths
         UNION SELECT 'pane', pane_id FROM pane_paths
         UNION SELECT 'screen', screen_id FROM pane_paths
         UNION SELECT 'workspace', workspace_id FROM pane_paths
         UNION SELECT 'screen', screen_id FROM screen_paths
         UNION SELECT 'workspace', workspace_id FROM screen_paths",
    )?;
    let expanded = statement
        .query_map([ids_json], |row| Ok(JournalSubject { kind: row.get(0)?, id: row.get(1)? }))?
        .collect::<Result<Vec<_>, _>>()?;
    subjects.extend(expanded);
    Ok(())
}

pub(super) fn terminal_topology_subjects_batch(
    transaction: &Transaction<'_>,
    terminal_ids: impl IntoIterator<Item = String>,
) -> anyhow::Result<HashMap<String, Vec<JournalSubject>>> {
    let terminal_ids = terminal_ids.into_iter().collect::<BTreeSet<_>>();
    if terminal_ids.is_empty() {
        return Ok(HashMap::new());
    }
    let ids_json = canonical_json(&serde_json::to_value(&terminal_ids)?)?;
    let mut statement = transaction.prepare(
        "WITH seeds(terminal_id) AS (
           SELECT value FROM json_each(?1)
         ),
         paths(terminal_id, tab_id, pane_id, screen_id, workspace_id) AS (
           SELECT seed.terminal_id, tab.public_id, tab.pane_id,
                  pane.screen_id, screen.workspace_id
           FROM seeds AS seed
           JOIN resource_tabs AS tab ON tab.content_id = seed.terminal_id
           JOIN resource_panes AS pane ON pane.public_id = tab.pane_id
           JOIN resource_screens AS screen ON screen.public_id = pane.screen_id
         )
         SELECT terminal_id, 'tab', tab_id FROM paths
         UNION SELECT terminal_id, 'pane', pane_id FROM paths
         UNION SELECT terminal_id, 'screen', screen_id FROM paths
         UNION SELECT terminal_id, 'workspace', workspace_id FROM paths",
    )?;
    let expanded = statement
        .query_map([ids_json], |row| {
            Ok((row.get::<_, String>(0)?, JournalSubject { kind: row.get(1)?, id: row.get(2)? }))
        })?
        .collect::<Result<Vec<_>, _>>()?;
    let mut by_terminal = HashMap::<String, BTreeSet<JournalSubject>>::new();
    for (terminal_id, subject) in expanded {
        by_terminal.entry(terminal_id).or_default().insert(subject);
    }
    Ok(by_terminal
        .into_iter()
        .map(|(terminal_id, subjects)| (terminal_id, subjects.into_iter().collect()))
        .collect())
}

fn public_id_kind(value: &str) -> Option<&'static str> {
    const PREFIXES: [(&str, &str); 17] = [
        ("frontend_projection", "projection"),
        ("pairing_request", "pairing"),
        ("sidebar_plugin", "sidebar_plugin"),
        ("sidebar_view", "sidebar_view"),
        ("notification", "notification"),
        ("workspace", "ws"),
        ("terminal", "term"),
        ("session", "session"),
        ("machine", "machine"),
        ("screen", "screen"),
        ("browser", "browser"),
        ("client", "client"),
        ("pane", "pane"),
        ("split", "split"),
        ("agent", "agent"),
        ("stream", "stream"),
        ("tab", "tab"),
    ];
    for (kind, prefix) in PREFIXES {
        let Some(payload) = value.strip_prefix(prefix).and_then(|value| value.strip_prefix('_'))
        else {
            continue;
        };
        if payload.len() == 32
            && payload.bytes().all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
        {
            return Some(kind);
        }
    }
    None
}

fn semantic_journal_kind(operation: &str) -> Cow<'_, str> {
    if operation.contains('-') && !operation.contains('.') {
        Cow::Owned(operation.replace('-', "."))
    } else {
        Cow::Borrowed(operation)
    }
}

fn table_exists(transaction: &Transaction<'_>, table: &str) -> anyhow::Result<bool> {
    Ok(transaction
        .query_row(
            "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?1",
            [table],
            |_| Ok(()),
        )
        .optional()?
        .is_some())
}

pub(crate) fn unix_epoch_ms() -> anyhow::Result<u64> {
    let duration = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .context("system clock is before the Unix epoch")?;
    u64::try_from(duration.as_millis()).context("system clock exceeds journal range")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn resource_record_is_typed_scoped_and_append_only() {
        let mut registry = WorkspaceRegistry::in_memory("journal").unwrap();
        let workspace_id = format!("ws_{}", "1".repeat(32));
        let pane_id = format!("pane_{}", "2".repeat(32));
        let result = serde_json::json!({"workspace_id":workspace_id});
        let changes = serde_json::json!([{
            "kind":"upsert",
            "resource":"pane",
            "id":pane_id,
            "value":{"workspace_id":workspace_id,"pane_id":pane_id}
        }]);
        let tx = registry.connection.transaction().unwrap();
        tx.execute("UPDATE meta SET value = '1' WHERE key = 'resource_revision'", []).unwrap();
        append_resource_journal_record(
            &tx,
            1,
            0,
            "test-client",
            "focus-one",
            "pane.focus",
            None,
            &result,
            &changes,
        )
        .unwrap();
        tx.commit().unwrap();

        let page = registry.session_journal_after(0, 10).unwrap();
        assert_eq!(page.head_sequence, 1);
        assert_eq!(page.records.len(), 1);
        let record = &page.records[0];
        assert_eq!(record.kind, "pane.focus");
        assert_eq!(record.class, JournalClass::State);
        assert_eq!(record.replay, JournalReplayPolicy::Required);
        assert_eq!(record.correlation_id.as_deref(), Some("focus-one"));
        assert_eq!(record.resource_revision, Some(1));
        assert_eq!(record.previous_resource_revision, Some(0));
        assert!(
            record
                .subjects
                .iter()
                .any(|subject| { subject.kind == "workspace" && subject.id == workspace_id })
        );
        assert!(
            record.subjects.iter().any(|subject| subject.kind == "pane" && subject.id == pane_id)
        );
        let indexed = registry
            .connection
            .query_row(
                "SELECT COUNT(*) FROM journal_subject_index
                 WHERE kind = 'pane' AND id = ?1 AND sequence = 1",
                [&pane_id],
                |row| row.get::<_, i64>(0),
            )
            .unwrap();
        assert_eq!(indexed, 1);

        let update = registry
            .connection
            .execute("UPDATE session_journal SET kind = 'pane.changed' WHERE sequence = 1", []);
        assert!(update.unwrap_err().to_string().contains("append-only"));
        let delete = registry.connection.execute("DELETE FROM session_journal", []);
        assert!(delete.unwrap_err().to_string().contains("append-only"));
        let delete_index = registry.connection.execute("DELETE FROM journal_subject_index", []);
        assert!(delete_index.unwrap_err().to_string().contains("append-only"));
    }

    #[test]
    fn migration_marks_incomplete_history_and_preserves_retained_events() {
        let mut registry = WorkspaceRegistry::in_memory("migration").unwrap();
        let tx = registry.connection.transaction().unwrap();
        tx.execute_batch(
            "DROP TABLE session_journal;
             CREATE TABLE resource_events (
               revision INTEGER PRIMARY KEY NOT NULL,
               previous_revision INTEGER NOT NULL,
               origin TEXT NOT NULL,
               idempotency_key TEXT NOT NULL,
               deltas_json TEXT NOT NULL
             );
             UPDATE meta SET value = '4' WHERE key = 'resource_revision';",
        )
        .unwrap();
        let result = serde_json::json!({"focused":true});
        tx.execute(
            "INSERT INTO resource_mutations(
               origin, idempotency_key, operation, fingerprint, result_json, committed_revision
             ) VALUES('test', 'focus-four', 'pane.focus', '{}', ?1, 4)",
            [canonical_json(&result).unwrap()],
        )
        .unwrap();
        tx.execute(
            "INSERT INTO resource_events(
               revision, previous_revision, origin, idempotency_key, deltas_json
             ) VALUES(4, 3, 'test', 'focus-four', '[]')",
            [],
        )
        .unwrap();
        migrate_resource_events_to_session_journal(&tx).unwrap();
        tx.commit().unwrap();

        let page = registry.session_journal_after(0, 10).unwrap();
        assert_eq!(page.records.len(), 2);
        assert_eq!(page.records[0].kind, "session.journal.migrated");
        assert_eq!(page.records[0].payload["history_complete"], false);
        assert_eq!(page.records[1].kind, "pane.focus");
        assert_eq!(page.records[1].resource_revision, Some(4));
        assert_eq!(registry.resource_events_after(3).unwrap().batches.len(), 1);
    }

    #[test]
    fn migration_marks_projection_only_legacy_history_incomplete() {
        let mut registry = WorkspaceRegistry::in_memory("projection-only-migration").unwrap();
        let tx = registry.connection.transaction().unwrap();
        tx.execute_batch(
            "DROP TABLE session_journal;
             UPDATE meta SET value = '7' WHERE key = 'resource_revision';",
        )
        .unwrap();
        migrate_resource_events_to_session_journal(&tx).unwrap();
        tx.commit().unwrap();

        let page = registry.session_journal_after(0, 10).unwrap();
        assert_eq!(page.records.len(), 1);
        assert_eq!(page.records[0].kind, "session.journal.migrated");
        assert_eq!(page.records[0].payload["source"], "projection_only");
        assert_eq!(page.records[0].payload["resource_head_revision"], "7");
        assert_eq!(page.records[0].payload["history_complete"], false);
    }

    #[test]
    fn journal_cursor_and_page_limits_fail_closed() {
        let registry = WorkspaceRegistry::in_memory("limits").unwrap();
        let ahead = registry.session_journal_after(1, 1).unwrap_err();
        assert!(ahead.to_string().contains("ahead"));
        assert_eq!(
            ahead.downcast_ref::<SessionJournalCursorError>(),
            Some(&SessionJournalCursorError::Ahead { requested: 1, head: 0 })
        );
        assert!(registry.session_journal_after(0, 0).unwrap_err().to_string().contains("positive"));
        assert!(
            registry
                .session_journal_after(0, MAX_JOURNAL_PAGE_SIZE + 1)
                .unwrap_err()
                .to_string()
                .contains("exceeds")
        );
    }

    #[test]
    fn retained_history_gap_is_a_typed_cursor_error() {
        let registry = WorkspaceRegistry::in_memory("cursor-gap").unwrap();
        registry
            .connection
            .execute(
                "INSERT INTO journal_segments(
                   segment_id, start_sequence, end_sequence, record_count, codec, content,
                   uncompressed_bytes, sha256, sealed_at_ms
                 ) VALUES(?1, 3, 3, 1, 'test', ?2, 1, ?3, 1)",
                rusqlite::params!["gap-segment", vec![0_u8], vec![0_u8; 32]],
            )
            .unwrap();

        let error = registry.session_journal_after(0, 1).unwrap_err();
        assert_eq!(
            error.downcast_ref::<SessionJournalCursorError>(),
            Some(&SessionJournalCursorError::Gap { requested: 0, first_retained: 3 })
        );
    }

    #[test]
    fn malformed_retained_segment_is_not_classified_as_cursor_repairable() {
        let registry = WorkspaceRegistry::in_memory("cursor-corrupt").unwrap();
        registry
            .connection
            .execute(
                "INSERT INTO journal_segments(
                   segment_id, start_sequence, end_sequence, record_count, codec, content,
                   uncompressed_bytes, sha256, sealed_at_ms
                 ) VALUES(?1, 1, 1, 1, 'test', ?2, 1, ?3, 1)",
                rusqlite::params!["corrupt-segment", vec![0_u8], vec![0_u8; 32]],
            )
            .unwrap();

        let error = registry.session_journal_after(0, 1).unwrap_err();
        assert!(
            error.downcast_ref::<SessionJournalCursorError>().is_none(),
            "segment corruption must propagate instead of triggering a cursor reset"
        );
    }

    #[test]
    fn persistent_reader_observes_commits_on_an_independent_connection() {
        let root = std::env::temp_dir().join(format!("cmux-journal-reader-{}", new_uuid_v4()));
        let mut registry = WorkspaceRegistry::open(&root, "reader").unwrap();
        let database_path = registry.session_journal_database_path().unwrap();
        let reader = SessionJournalReader::open(&database_path).unwrap();
        assert_eq!(reader.after(0, 1).unwrap().head_sequence, 0);

        let workspace_id = format!("ws_{}", "1".repeat(32));
        let result = serde_json::json!({"workspace_id":workspace_id});
        let tx = registry.connection.transaction().unwrap();
        tx.execute("UPDATE meta SET value = '1' WHERE key = 'resource_revision'", []).unwrap();
        append_resource_journal_record(
            &tx,
            1,
            0,
            "reader-test",
            "reader-commit",
            "workspace.focus",
            None,
            &result,
            &serde_json::json!([]),
        )
        .unwrap();
        tx.commit().unwrap();

        let page = reader.after(0, 1).unwrap();
        assert_eq!(page.head_sequence, 1);
        assert_eq!(page.records[0].kind, "workspace.focus");
        let matching = reader
            .after_subjects(0, 1, &[JournalSubject { kind: "workspace".into(), id: workspace_id }])
            .unwrap();
        assert_eq!(matching.scanned_through, 1);
        assert_eq!(matching.records.len(), 1);
        let absent = reader
            .after_subjects(
                0,
                1,
                &[JournalSubject { kind: "agent_tree".into(), id: "agenttree_absent".into() }],
            )
            .unwrap();
        assert_eq!(absent.scanned_through, 1);
        assert!(absent.records.is_empty());
        drop(reader);
        drop(registry);
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn archived_segment_metadata_is_verified_before_replay() {
        let mut registry = WorkspaceRegistry::in_memory("segment-integrity").unwrap();
        let result = serde_json::json!({"focused":true});
        let tx = registry.connection.transaction().unwrap();
        tx.execute("UPDATE meta SET value = '1' WHERE key = 'resource_revision'", []).unwrap();
        append_resource_journal_record(
            &tx,
            1,
            0,
            "segment-test",
            "segment-record-1",
            "pane.focus",
            None,
            &result,
            &serde_json::json!([]),
        )
        .unwrap();
        tx.commit().unwrap();

        let records = registry.session_journal_after(0, 10).unwrap().records;
        let uncompressed = serde_json::to_vec(&records).unwrap();
        let digest = Sha256::digest(&uncompressed);
        let mut encoder =
            flate2::GzBuilder::new().mtime(0).write(Vec::new(), flate2::Compression::fast());
        encoder.write_all(&uncompressed).unwrap();
        let compressed = encoder.finish().unwrap();
        registry
            .connection
            .execute(
                "INSERT INTO journal_segments(
                   segment_id, start_sequence, end_sequence, record_count, codec, content,
                   uncompressed_bytes, sha256, sealed_at_ms
                 ) VALUES('segment_bad_metadata', 1, 1, 2, 'gzip-json-v1', ?1, ?2, ?3, 1)",
                params![compressed, i64::try_from(uncompressed.len()).unwrap(), digest.as_slice()],
            )
            .unwrap();
        registry
            .connection
            .execute_batch(
                "DROP TRIGGER session_journal_reject_delete;
                 DELETE FROM session_journal;
                 CREATE TRIGGER session_journal_reject_delete
                   BEFORE DELETE ON session_journal
                 BEGIN SELECT RAISE(ABORT, 'session journal is append-only'); END;",
            )
            .unwrap();

        let error = registry.session_journal_after(0, 10).unwrap_err();
        assert!(error.to_string().contains("record count"), "{error:#}");
    }
}
