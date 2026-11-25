use super::*;

mod exit_snapshot;
mod hooks;
mod segments;
mod writer_batch;
use base64::Engine;

use crate::resource::WireDecimal;
use crate::workspace_registry::session_journal::{
    JournalAppend, MAX_JOURNAL_SEGMENT_UNCOMPRESSED_BYTES, append_journal_record,
    expand_topology_subjects, query_session_journal_sequences, terminal_topology_subjects_batch,
    unix_epoch_ms,
};
use serde_json::json;
use std::collections::{BTreeSet, HashMap, HashSet};
use std::io::Read;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, Instant};

const MAX_PRODUCER_EVENTS: usize = 64;
const MAX_PRODUCER_MANIFEST_BYTES: usize = 1024 * 1024;
pub(super) const MAX_EVENT_PAYLOAD_BYTES: usize = 1024 * 1024;
const MAX_CAUSATION_DEPTH: u16 = 32;
pub(crate) const JOURNAL_SEGMENT_RECORD_LIMIT: usize = 1_024;
const MAX_CHECKPOINT_CONTENT_UNCOMPRESSED_BYTES: usize = 256 * 1024 * 1024;
/// Result arrays are capped by the embedded resource-operation catalog.
pub(crate) const JOURNAL_LIST_MAX_ITEMS: usize = 4096;
/// The newest checkpoints always kept. The `journal_checkpoints_keep_recent`
/// trigger repeats this number; keep the two equal.
pub(crate) const JOURNAL_CHECKPOINTS_KEPT: usize = 16;
/// The newest checkpoint the prune keeps, counting from 0.
const JOURNAL_CHECKPOINT_OLDEST_KEPT_OFFSET: usize = JOURNAL_CHECKPOINTS_KEPT - 1;
/// The most checkpoints one maintenance tick deletes.
pub(crate) const JOURNAL_CHECKPOINT_PRUNE_BATCH: usize = 64;

fn ensure_journal_deadline(deadline: Option<Instant>) -> anyhow::Result<()> {
    if deadline.is_some_and(|deadline| Instant::now() >= deadline) {
        return Err(crate::JournalContention::COMMIT_DEADLINE.into());
    }
    Ok(())
}

struct JournalDeadlineTransactionGuard<'a> {
    active: Option<&'a AtomicBool>,
}

impl JournalDeadlineTransactionGuard<'_> {
    fn disarm(&self) {
        if let Some(active) = self.active {
            active.store(false, Ordering::Release);
        }
    }
}

impl Drop for JournalDeadlineTransactionGuard<'_> {
    fn drop(&mut self) {
        self.disarm();
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct JournalEventSchema {
    pub kind: String,
    pub schema_version: u32,
    pub class: JournalClass,
    pub replay: JournalReplayPolicy,
    pub sensitivity: JournalSensitivity,
    pub payload_schema: Value,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct JournalProducerManifest {
    pub producer_id: String,
    pub namespace: String,
    pub manifest_version: u32,
    pub max_sensitivity: JournalSensitivity,
    #[serde(default)]
    pub permissions: Vec<String>,
    pub events: Vec<JournalEventSchema>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct JournalIngress {
    pub producer_id: String,
    pub manifest_version: u32,
    pub kind: String,
    pub schema_version: u32,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub occurred_at_ms: Option<WireDecimal>,
    #[serde(default)]
    pub subjects: Vec<JournalSubject>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub sensitivity: Option<JournalSensitivity>,
    pub payload: Value,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub causation_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub correlation_id: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct JournalHookRegex {
    pub pattern: String,
    #[serde(default = "default_hook_regex_field")]
    pub field: String,
    #[serde(default = "default_true")]
    pub case_sensitive: bool,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, Default)]
#[serde(deny_unknown_fields)]
pub struct JournalHookFilter {
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub kinds: Vec<String>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub classes: Vec<JournalClass>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub subject_kinds: Vec<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub max_sensitivity: Option<JournalSensitivity>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub regex: Option<JournalHookRegex>,
    #[serde(default, skip_serializing_if = "is_false")]
    pub include_causal_descendants: bool,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct JournalHookExec {
    pub argv: Vec<String>,
    pub timeout_ms: u64,
    pub max_parallel: u16,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct JournalHookRetry {
    pub max_attempts: u16,
    pub backoff_ms: u64,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct JournalHookDeliveryPolicy {
    pub start: String,
    pub retry: JournalHookRetry,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct JournalHookManifest {
    pub hook_id: String,
    pub manifest_version: u32,
    pub filter: JournalHookFilter,
    pub exec: JournalHookExec,
    pub delivery: JournalHookDeliveryPolicy,
    #[serde(default)]
    pub permissions: Vec<String>,
}

#[derive(Debug, Clone)]
pub(crate) struct JournalHookState {
    pub manifest: JournalHookManifest,
    pub cursor_sequence: u64,
    pub enabled: bool,
}

#[derive(Debug)]
pub(crate) struct JournalHookScan {
    pub hook_id: String,
    pub manifest_version: u32,
    pub expected_cursor: u64,
    pub scanned_to: u64,
    pub matches: Vec<(String, u64)>,
}

#[derive(Debug, Clone)]
pub(crate) struct JournalHookDelivery {
    pub manifest: JournalHookManifest,
    pub event: SessionJournalRecord,
    pub attempt: u16,
}

#[derive(Debug, Clone)]
pub(crate) struct JournalHookAttempt {
    pub attempt: u16,
    pub causation_id: String,
}

#[derive(Debug, Clone)]
pub(crate) struct JournalHookDeliveryResult {
    pub delivery: JournalHookDelivery,
    pub attempt: u16,
    pub exit_code: Option<i32>,
    pub error: Option<String>,
}

#[derive(Debug, Clone, PartialEq)]
pub struct JournalAppendCommit {
    pub sequence: u64,
    pub event_id: String,
    pub replayed: bool,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct JournalContentRef {
    pub content_id: String,
    pub terminal_id: String,
    pub format: String,
    pub codec: String,
    pub sha256: String,
    #[serde(serialize_with = "serialize_decimal", deserialize_with = "deserialize_decimal")]
    pub uncompressed_bytes: u64,
    pub cols: u16,
    pub rows: u16,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct JournalCheckpoint {
    pub checkpoint_id: String,
    #[serde(serialize_with = "serialize_decimal", deserialize_with = "deserialize_decimal")]
    pub source_sequence: u64,
    pub reducer_version: u32,
    pub state: Value,
    pub content_refs: Vec<JournalContentRef>,
    pub sha256: String,
    #[serde(serialize_with = "serialize_decimal", deserialize_with = "deserialize_decimal")]
    pub created_at_ms: u64,
}

#[derive(Debug, Clone, PartialEq)]
pub(crate) struct JournalCheckpointSummary {
    pub checkpoint_id: String,
    pub source_sequence: u64,
    pub reducer_version: u32,
    pub content_refs: Vec<JournalContentRef>,
    pub sha256: String,
    pub created_at_ms: u64,
}

#[derive(Debug, Clone)]
pub(crate) struct JournalContentBlob {
    pub reference: JournalContentRef,
    pub compressed: Vec<u8>,
    digest: [u8; 32],
}

impl JournalContentBlob {
    pub(crate) fn verified(
        reference: JournalContentRef,
        compressed: Vec<u8>,
    ) -> anyhow::Result<Self> {
        let digest = decode_sha256(&reference.sha256)?;
        let blob = Self { reference, compressed, digest };
        verify_journal_content_blob(&blob)?;
        Ok(blob)
    }
}

#[derive(Debug, Clone, PartialEq)]
pub(crate) struct JournalCheckpointCommit {
    pub checkpoint: JournalCheckpoint,
    pub journal: JournalAppendCommit,
}

/// One durable `cmux.vt-replay.v1` snapshot captured when a terminal exited,
/// decoded back to its replay bytes. It is the storage bound for
/// `terminal.output_read`: every `terminal.output` record of `generation`
/// whose `stream_offset_end` is at most `covered_through` is fully covered by
/// this snapshot and is therefore prunable by the journal seal/prune pass;
/// reads answer from the snapshot plus the records after it.
#[derive(Debug, Clone, PartialEq)]
pub(crate) struct TerminalExitSnapshot {
    pub(crate) generation: String,
    pub(crate) covered_through: u64,
    pub(crate) cols: u16,
    pub(crate) rows: u16,
    pub(crate) replay_bytes: Vec<u8>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct JournalSegment {
    pub segment_id: String,
    #[serde(serialize_with = "serialize_decimal", deserialize_with = "deserialize_decimal")]
    pub start_sequence: u64,
    #[serde(serialize_with = "serialize_decimal", deserialize_with = "deserialize_decimal")]
    pub end_sequence: u64,
    #[serde(serialize_with = "serialize_decimal", deserialize_with = "deserialize_decimal")]
    pub record_count: u64,
    pub codec: String,
    #[serde(serialize_with = "serialize_decimal", deserialize_with = "deserialize_decimal")]
    pub uncompressed_bytes: u64,
    pub sha256: String,
    #[serde(serialize_with = "serialize_decimal", deserialize_with = "deserialize_decimal")]
    pub sealed_at_ms: u64,
}

#[derive(Debug, Clone, PartialEq)]
pub(crate) struct JournalSegmentSealCommit {
    pub through_sequence: u64,
    pub segments: Vec<JournalSegment>,
    pub journal: JournalAppendCommit,
}

pub(crate) enum JournalSegmentSealStart {
    Replay(JournalSegmentSealCommit),
    Prepare(JournalSegmentSealPlan),
}

pub(crate) struct JournalSegmentSealPlan {
    requested_through: u64,
    through_sequence: u64,
    archived_end: u64,
    fingerprint: [u8; 32],
}

pub(crate) struct PreparedJournalSegmentSeal {
    plan: JournalSegmentSealPlan,
    segments: Vec<PreparedJournalSegment>,
}

struct PreparedJournalSegment {
    metadata: JournalSegment,
    compressed: Vec<u8>,
    digest: [u8; 32],
    kinds: Vec<String>,
    /// Its records of the kinds a journal reducer folds
    /// (`session_journal::reducer_records`).
    reducer_records: Vec<session_journal::reducer_records::ReducerRecordRow>,
}

pub(super) fn create_journal_extensions_schema(
    transaction: &Transaction<'_>,
) -> anyhow::Result<()> {
    transaction.execute_batch(
        "CREATE TABLE IF NOT EXISTS journal_producers (
           producer_id TEXT PRIMARY KEY NOT NULL,
           namespace TEXT UNIQUE NOT NULL,
           manifest_version INTEGER NOT NULL CHECK(manifest_version > 0),
           manifest_json TEXT NOT NULL CHECK(json_valid(manifest_json)),
           installed_at_ms INTEGER NOT NULL CHECK(installed_at_ms >= 0)
         );
         CREATE TABLE IF NOT EXISTS journal_operation_receipts (
           operation TEXT NOT NULL,
           origin TEXT NOT NULL,
           idempotency_key TEXT NOT NULL,
           fingerprint BLOB NOT NULL CHECK(length(fingerprint) = 32),
           result_json TEXT NOT NULL CHECK(json_valid(result_json)),
           journal_sequence INTEGER NOT NULL UNIQUE,
           PRIMARY KEY(operation, origin, idempotency_key)
         );
         CREATE TABLE IF NOT EXISTS journal_ingress_receipts (
           producer_id TEXT NOT NULL,
           origin TEXT NOT NULL,
           idempotency_key TEXT NOT NULL,
           fingerprint BLOB NOT NULL CHECK(length(fingerprint) = 32),
           event_id TEXT NOT NULL UNIQUE,
           journal_sequence INTEGER NOT NULL UNIQUE,
           result_json TEXT NOT NULL CHECK(json_valid(result_json)),
           PRIMARY KEY(producer_id, origin, idempotency_key),
           FOREIGN KEY(producer_id) REFERENCES journal_producers(producer_id)
         );
         CREATE TABLE IF NOT EXISTS journal_hooks (
           hook_id TEXT NOT NULL,
           manifest_version INTEGER NOT NULL CHECK(manifest_version > 0),
           manifest_json TEXT NOT NULL CHECK(json_valid(manifest_json)),
           enabled INTEGER NOT NULL CHECK(enabled IN (0,1)),
           cursor_sequence INTEGER NOT NULL CHECK(cursor_sequence >= 0),
           installed_at_ms INTEGER NOT NULL CHECK(installed_at_ms >= 0),
           PRIMARY KEY(hook_id, manifest_version)
         );
         CREATE TABLE IF NOT EXISTS journal_hook_deliveries (
           hook_id TEXT NOT NULL,
           manifest_version INTEGER NOT NULL,
           event_id TEXT NOT NULL,
           event_sequence INTEGER NOT NULL,
           attempt INTEGER NOT NULL CHECK(attempt >= 0),
           state TEXT NOT NULL CHECK(state IN ('scheduled','executing','completed','failed','abandoned')),
           next_attempt_at_ms INTEGER NOT NULL CHECK(next_attempt_at_ms >= 0),
           scheduled_at_ms INTEGER NOT NULL,
           started_at_ms INTEGER,
           started_event_id TEXT,
           completed_at_ms INTEGER,
           exit_code INTEGER,
           error TEXT,
           PRIMARY KEY(hook_id, manifest_version, event_id),
           FOREIGN KEY(hook_id, manifest_version)
             REFERENCES journal_hooks(hook_id, manifest_version)
         );
         CREATE INDEX IF NOT EXISTS journal_hook_deliveries_pending
           ON journal_hook_deliveries(state, event_sequence);
         CREATE TABLE IF NOT EXISTS journal_content_blobs (
           content_id TEXT PRIMARY KEY NOT NULL,
           sha256 BLOB UNIQUE NOT NULL CHECK(length(sha256) = 32),
           codec TEXT NOT NULL,
           content BLOB NOT NULL,
           uncompressed_bytes INTEGER NOT NULL CHECK(uncompressed_bytes >= 0),
           created_at_ms INTEGER NOT NULL CHECK(created_at_ms >= 0)
         );
         CREATE TABLE IF NOT EXISTS journal_checkpoints (
           checkpoint_id TEXT PRIMARY KEY NOT NULL,
           source_sequence INTEGER UNIQUE NOT NULL CHECK(source_sequence >= 0),
           reducer_version INTEGER NOT NULL CHECK(reducer_version > 0),
           state_json TEXT NOT NULL CHECK(json_valid(state_json)),
           content_refs_json TEXT NOT NULL CHECK(json_valid(content_refs_json)),
           sha256 BLOB UNIQUE NOT NULL CHECK(length(sha256) = 32),
           created_at_ms INTEGER NOT NULL CHECK(created_at_ms >= 0)
         );
         CREATE TABLE IF NOT EXISTS journal_segments (
           segment_id TEXT PRIMARY KEY NOT NULL,
           start_sequence INTEGER UNIQUE NOT NULL CHECK(start_sequence > 0),
           end_sequence INTEGER UNIQUE NOT NULL CHECK(end_sequence >= start_sequence),
           record_count INTEGER NOT NULL CHECK(record_count > 0),
           codec TEXT NOT NULL,
           content BLOB NOT NULL,
           uncompressed_bytes INTEGER NOT NULL CHECK(uncompressed_bytes > 0),
           sha256 BLOB UNIQUE NOT NULL CHECK(length(sha256) = 32),
           sealed_at_ms INTEGER NOT NULL CHECK(sealed_at_ms >= 0),
           actors_json TEXT
         );
         CREATE TABLE IF NOT EXISTS journal_segment_kinds (
           segment_id TEXT NOT NULL,
           kind TEXT NOT NULL,
           PRIMARY KEY(segment_id, kind),
           FOREIGN KEY(segment_id) REFERENCES journal_segments(segment_id)
         ) WITHOUT ROWID;
         CREATE TRIGGER IF NOT EXISTS journal_segments_reject_update
           BEFORE UPDATE ON journal_segments
         BEGIN
           SELECT RAISE(ABORT, 'journal segments are immutable');
         END;
         CREATE TRIGGER IF NOT EXISTS journal_segments_reject_delete
           BEFORE DELETE ON journal_segments
         BEGIN
           SELECT RAISE(ABORT, 'journal segments are immutable');
         END;
         CREATE TRIGGER IF NOT EXISTS journal_content_blobs_reject_update
           BEFORE UPDATE ON journal_content_blobs
         BEGIN
           SELECT RAISE(ABORT, 'journal content blobs are immutable');
         END;
         CREATE TRIGGER IF NOT EXISTS journal_content_blobs_reject_delete
           BEFORE DELETE ON journal_content_blobs
         BEGIN
           SELECT RAISE(ABORT, 'journal content blobs are immutable');
         END;
         CREATE TRIGGER IF NOT EXISTS journal_checkpoints_reject_update
           BEFORE UPDATE ON journal_checkpoints
         BEGIN
           SELECT RAISE(ABORT, 'journal checkpoints are immutable');
         END;
         DROP TRIGGER IF EXISTS journal_checkpoints_reject_delete;
         CREATE TRIGGER IF NOT EXISTS journal_checkpoints_keep_recent
           BEFORE DELETE ON journal_checkpoints
           WHEN OLD.source_sequence
                  > (SELECT COALESCE(MAX(end_sequence), 0) FROM journal_segments)
             OR (SELECT COUNT(*) FROM journal_checkpoints
                 WHERE source_sequence > OLD.source_sequence) < 16
         BEGIN
           SELECT RAISE(ABORT, 'journal checkpoints keep the newest 16 and every unsealed one');
         END;
         CREATE TABLE IF NOT EXISTS terminal_exit_snapshots (
           terminal_id TEXT PRIMARY KEY NOT NULL,
           generation TEXT NOT NULL,
           content_id TEXT NOT NULL REFERENCES journal_content_blobs(content_id),
           format TEXT NOT NULL,
           cols INTEGER NOT NULL CHECK(cols > 0),
           rows INTEGER NOT NULL CHECK(rows > 0),
           covered_through INTEGER NOT NULL CHECK(covered_through > 0),
           created_at_ms INTEGER NOT NULL CHECK(created_at_ms >= 0)
         );
         CREATE TRIGGER IF NOT EXISTS terminal_exit_snapshots_reject_update
           BEFORE UPDATE ON terminal_exit_snapshots
         BEGIN
           SELECT RAISE(ABORT, 'terminal exit snapshots are immutable');
         END;",
    )?;
    ensure_built_in_agent_producer(transaction)?;
    migrate_journal_receipt_origins(transaction)?;
    let delivery_columns = table_columns(transaction, "journal_hook_deliveries")?;
    if !delivery_columns.contains("started_event_id") {
        transaction
            .execute("ALTER TABLE journal_hook_deliveries ADD COLUMN started_event_id TEXT", [])?;
    }
    // A seal writes it: the owner adds it, not the later ledger pass (cx-0b8z).
    mutation_ledger::add_nullable_column(transaction, "journal_segments", "actors_json")?;
    session_journal::ensure_journal_event_index_schema(transaction)?;
    Ok(())
}

fn ensure_built_in_agent_producer(transaction: &Transaction<'_>) -> anyhow::Result<()> {
    let manifest = crate::agent_hooks::built_in_agent_producer_manifest();
    let manifest_json = canonical_json(&serde_json::to_value(&manifest)?)?;
    transaction.execute(
        "INSERT OR IGNORE INTO journal_producers(
           producer_id, namespace, manifest_version, manifest_json, installed_at_ms
         ) VALUES(?1, ?2, ?3, ?4, ?5)",
        params![
            manifest.producer_id,
            manifest.namespace,
            i64::from(manifest.manifest_version),
            manifest_json,
            i64::try_from(unix_epoch_ms()?)?,
        ],
    )?;
    let (installed_namespace, installed_version, installed_json) = transaction.query_row(
        "SELECT namespace, manifest_version, manifest_json
         FROM journal_producers
         WHERE producer_id = ?1",
        [crate::AGENT_HOOK_PRODUCER_ID],
        |row| Ok((row.get::<_, String>(0)?, row.get::<_, i64>(1)?, row.get::<_, String>(2)?)),
    )?;
    let installed = serde_json::from_str::<JournalProducerManifest>(&installed_json)?;
    let installed_version = u32::try_from(installed_version)
        .context("reserved cmux agent producer manifest version is invalid")?;
    anyhow::ensure!(
        installed.namespace == installed_namespace
            && installed.manifest_version == installed_version,
        "reserved cmux agent producer manifest metadata does not match its row"
    );
    if installed == manifest {
        return Ok(());
    }

    // The reserved producer stayed at manifest version 1 while these two
    // additive changes shipped. Rewrite only those exact historical shapes.
    // Unknown changes still fail closed, so a damaged or incompatible session
    // cannot silently acquire the current producer contract.
    let known_legacy = legacy_built_in_agent_producer_manifests(&manifest);
    anyhow::ensure!(
        known_legacy.iter().any(|legacy| legacy == &installed),
        "reserved cmux agent producer manifest does not match this binary"
    );
    transaction.execute(
        "UPDATE journal_producers
         SET namespace = ?1, manifest_version = ?2, manifest_json = ?3
         WHERE producer_id = ?4",
        params![
            manifest.namespace,
            i64::from(manifest.manifest_version),
            manifest_json,
            manifest.producer_id,
        ],
    )?;
    Ok(())
}

fn legacy_built_in_agent_producer_manifests(
    current: &JournalProducerManifest,
) -> Vec<JournalProducerManifest> {
    // Keep this allowlist tied to the shipped manifest shape. If the current
    // contract changes again, an explicit migration must be added instead of
    // deriving acceptance for an unshipped historical shape.
    const CURRENT_EVENT_KINDS: [&str; 13] = [
        "agent.session.started",
        "agent.turn.started",
        "agent.turn.completed",
        "agent.child.spawned",
        "agent.child.completed",
        "agent.child.failed",
        "agent.approval.requested",
        "agent.question.requested",
        "agent.plan_review.requested",
        "agent.error.reported",
        "agent.state.changed",
        "agent.session.ended",
        "agent.plugin.exited",
    ];
    if current.events.iter().map(|event| event.kind.as_str()).ne(CURRENT_EVENT_KINDS) {
        return Vec::new();
    }

    let mut legacy = current.clone();
    for event in &mut legacy.events {
        let Some(pattern) = event
            .payload_schema
            .get_mut("properties")
            .and_then(|value| value.get_mut("adapter"))
            .and_then(|value| value.get_mut("properties"))
            .and_then(|value| value.get_mut("id"))
            .and_then(|value| value.get_mut("pattern"))
        else {
            return Vec::new();
        };
        *pattern = Value::String("^[a-z0-9_-]+$".into());
    }
    let with_legacy_pattern = legacy.clone();
    legacy.events.retain(|event| event.kind != "agent.plugin.exited");
    vec![legacy, with_legacy_pattern]
}

fn migrate_journal_receipt_origins(transaction: &Transaction<'_>) -> anyhow::Result<()> {
    let operation_columns = table_columns(transaction, "journal_operation_receipts")?;
    if !operation_columns.contains("origin") {
        transaction.execute_batch(
            "ALTER TABLE journal_operation_receipts RENAME TO journal_operation_receipts_v11;
             CREATE TABLE journal_operation_receipts (
               operation TEXT NOT NULL,
               origin TEXT NOT NULL,
               idempotency_key TEXT NOT NULL,
               fingerprint BLOB NOT NULL CHECK(length(fingerprint) = 32),
               result_json TEXT NOT NULL CHECK(json_valid(result_json)),
               journal_sequence INTEGER NOT NULL UNIQUE,
               PRIMARY KEY(operation, origin, idempotency_key)
             );
             INSERT INTO journal_operation_receipts(
               operation, origin, idempotency_key, fingerprint, result_json, journal_sequence
             )
             SELECT receipt.operation,
                    COALESCE(
                      json_extract(journal.authority_json, '$.principal_id'),
                      json_extract(journal.producer_json, '$.id'),
                      'legacy'
                    ),
                    receipt.idempotency_key, receipt.fingerprint, receipt.result_json,
                    receipt.journal_sequence
             FROM journal_operation_receipts_v11 receipt
             LEFT JOIN session_journal journal ON journal.sequence = receipt.journal_sequence;
             DROP TABLE journal_operation_receipts_v11;",
        )?;
    }
    let ingress_columns = table_columns(transaction, "journal_ingress_receipts")?;
    if !ingress_columns.contains("origin") {
        transaction.execute_batch(
            "ALTER TABLE journal_ingress_receipts RENAME TO journal_ingress_receipts_v11;
             CREATE TABLE journal_ingress_receipts (
               producer_id TEXT NOT NULL,
               origin TEXT NOT NULL,
               idempotency_key TEXT NOT NULL,
               fingerprint BLOB NOT NULL CHECK(length(fingerprint) = 32),
               event_id TEXT NOT NULL UNIQUE,
               journal_sequence INTEGER NOT NULL UNIQUE,
               result_json TEXT NOT NULL CHECK(json_valid(result_json)),
               PRIMARY KEY(producer_id, origin, idempotency_key),
               FOREIGN KEY(producer_id) REFERENCES journal_producers(producer_id)
             );
             INSERT INTO journal_ingress_receipts(
               producer_id, origin, idempotency_key, fingerprint, event_id,
               journal_sequence, result_json
             )
             SELECT receipt.producer_id,
                    COALESCE(
                      json_extract(journal.authority_json, '$.principal_id'),
                      'legacy'
                    ),
                    receipt.idempotency_key, receipt.fingerprint, receipt.event_id,
                    receipt.journal_sequence, receipt.result_json
             FROM journal_ingress_receipts_v11 receipt
             LEFT JOIN session_journal journal ON journal.sequence = receipt.journal_sequence;
             DROP TABLE journal_ingress_receipts_v11;",
        )?;
    }
    Ok(())
}

pub(super) fn table_columns(
    transaction: &Transaction<'_>,
    table: &str,
) -> anyhow::Result<HashSet<String>> {
    let mut statement = transaction.prepare(&format!("PRAGMA table_info({table})"))?;
    statement
        .query_map([], |row| row.get::<_, String>(1))?
        .collect::<Result<HashSet<_>, _>>()
        .map_err(Into::into)
}

pub(crate) fn validate_journal_producer_manifest(
    manifest: &JournalProducerManifest,
) -> anyhow::Result<()> {
    validate_plugin_component("producer_id", &manifest.producer_id)?;
    anyhow::ensure!(
        manifest.namespace == format!("plugin.{}", manifest.producer_id),
        "journal producer namespace must be plugin.<producer_id>"
    );
    anyhow::ensure!(manifest.manifest_version > 0, "manifest_version must be positive");
    anyhow::ensure!(
        manifest.max_sensitivity != JournalSensitivity::Secret,
        "secret journal payload storage is unavailable until encrypted retention is implemented"
    );
    anyhow::ensure!(
        manifest
            .permissions
            .iter()
            .any(|permission| permission == &format!("journal.append.{}", manifest.namespace)),
        "journal producer manifest requires journal.append.<namespace> permission"
    );
    anyhow::ensure!(
        !manifest.events.is_empty() && manifest.events.len() <= MAX_PRODUCER_EVENTS,
        "journal producer must declare 1 to {MAX_PRODUCER_EVENTS} events"
    );
    let encoded = serde_json::to_vec(manifest)?;
    anyhow::ensure!(
        encoded.len() <= MAX_PRODUCER_MANIFEST_BYTES,
        "journal producer manifest exceeds {MAX_PRODUCER_MANIFEST_BYTES} bytes"
    );
    let mut identities = BTreeSet::new();
    for event in &manifest.events {
        anyhow::ensure!(
            event.sensitivity != JournalSensitivity::Secret,
            "secret journal payload storage is unavailable until encrypted retention is implemented"
        );
        validate_dotted_kind(&event.kind)?;
        anyhow::ensure!(
            event.kind.starts_with(&format!("{}.", manifest.namespace)),
            "journal event kind must be inside producer namespace"
        );
        anyhow::ensure!(event.schema_version > 0, "journal event schema_version must be positive");
        anyhow::ensure!(
            sensitivity_rank(event.sensitivity) <= sensitivity_rank(manifest.max_sensitivity),
            "journal event sensitivity exceeds producer authority"
        );
        anyhow::ensure!(
            identities.insert((event.kind.as_str(), event.schema_version)),
            "journal producer declares a duplicate event schema"
        );
        jsonschema::validator_for(&event.payload_schema)
            .with_context(|| format!("compile payload schema for {}", event.kind))?;
    }
    Ok(())
}

pub(crate) fn validate_journal_hook_manifest(manifest: &JournalHookManifest) -> anyhow::Result<()> {
    validate_plugin_component("hook_id", &manifest.hook_id)?;
    anyhow::ensure!(manifest.manifest_version > 0, "hook manifest_version must be positive");
    anyhow::ensure!(
        !manifest.exec.argv.is_empty() && manifest.exec.argv.len() <= 64,
        "hook argv must contain 1 to 64 entries"
    );
    anyhow::ensure!(
        Path::new(&manifest.exec.argv[0]).is_absolute(),
        "hook argv[0] must be an absolute executable path"
    );
    anyhow::ensure!(
        manifest.exec.argv.iter().all(|value| value.len() <= 4096 && !value.contains('\0')),
        "hook argv entries must be at most 4096 bytes and contain no NUL"
    );
    anyhow::ensure!(
        (1..=300_000).contains(&manifest.exec.timeout_ms),
        "hook timeout_ms must be between 1 and 300000"
    );
    anyhow::ensure!(
        (1..=64).contains(&manifest.exec.max_parallel),
        "hook max_parallel must be between 1 and 64"
    );
    anyhow::ensure!(
        matches!(manifest.delivery.start.as_str(), "tail" | "beginning"),
        "hook delivery start must be tail or beginning"
    );
    anyhow::ensure!(
        (1..=100).contains(&manifest.delivery.retry.max_attempts),
        "hook retry max_attempts must be between 1 and 100"
    );
    anyhow::ensure!(
        manifest.delivery.retry.backoff_ms <= 86_400_000,
        "hook retry backoff_ms exceeds one day"
    );
    anyhow::ensure!(
        manifest.permissions.iter().any(|permission| permission == "journal.read")
            || manifest.permissions.iter().any(|permission| permission == "journal.read.sensitive"),
        "hook manifest requires journal.read permission"
    );
    let maximum = manifest.filter.max_sensitivity.unwrap_or(JournalSensitivity::Metadata);
    anyhow::ensure!(
        sensitivity_rank(maximum) <= sensitivity_rank(JournalSensitivity::Sensitive),
        "hooks cannot receive secret journal records"
    );
    anyhow::ensure!(
        sensitivity_rank(maximum) <= sensitivity_rank(JournalSensitivity::Metadata)
            || manifest.permissions.iter().any(|permission| permission == "journal.read.sensitive"),
        "sensitive hook filters require journal.read.sensitive permission"
    );
    for kind in &manifest.filter.kinds {
        let base = kind.strip_suffix(".*").unwrap_or(kind);
        validate_dotted_kind(base)?;
        anyhow::ensure!(
            !kind.contains('*') || kind.ends_with(".*"),
            "hook kind wildcards are allowed only as terminal .*"
        );
    }
    for kind in &manifest.filter.subject_kinds {
        validate_plugin_component("hook subject kind", kind)?;
    }
    if let Some(regex) = &manifest.filter.regex {
        anyhow::ensure!(
            !regex.pattern.is_empty() && regex.pattern.len() <= 1024,
            "hook regex must contain 1 to 1024 UTF-8 bytes"
        );
        // A new hook on terminal output would never fire: output is not in
        // the session journal (output_store.rs). Hooks stored before keep
        // matching the output records of older registries.
        anyhow::ensure!(
            regex.field != "terminal_output",
            "hook regex field terminal_output is retired: terminal output is not in the session \
             journal; wait with terminal.wait or read with terminal.output_read"
        );
        anyhow::ensure!(
            matches!(regex.field.as_str(), "kind" | "subjects" | "payload" | "record"),
            "hook regex field is invalid"
        );
        regex::bytes::RegexBuilder::new(&regex.pattern)
            .case_insensitive(!regex.case_sensitive)
            .size_limit(1 << 20)
            .dfa_size_limit(2 << 20)
            .build()
            .context("compile hook regex")?;
    }
    let encoded = serde_json::to_vec(manifest)?;
    anyhow::ensure!(
        encoded.len() <= MAX_PRODUCER_MANIFEST_BYTES,
        "hook manifest exceeds {MAX_PRODUCER_MANIFEST_BYTES} bytes"
    );
    Ok(())
}

impl WorkspaceRegistry {
    /// Look up an exact ingress receipt before the caller validates against the
    /// current producer manifest. A retry can carry an older manifest version
    /// after a producer upgrade, but an ingress that has never committed must
    /// still pass current admission below.
    pub(crate) fn replay_journal_ingress(
        &self,
        ingress: &JournalIngress,
        origin: &str,
        idempotency_key: &str,
    ) -> anyhow::Result<Option<JournalAppendCommit>> {
        validate_journal_ingress_shape(ingress, origin, idempotency_key)?;
        let fingerprint = journal_ingress_fingerprint(ingress)?;
        ingress_receipt(
            &self.connection.get(),
            &ingress.producer_id,
            origin,
            idempotency_key,
            fingerprint.as_slice(),
        )
    }

    #[cfg(test)]
    pub(crate) fn append_journal_ingress_events(
        &mut self,
        events: &[&crate::journal_ingress::JournalIngressEvent],
    ) -> anyhow::Result<Vec<crate::journal_ingress::JournalBatchReceipt>> {
        let shared = self.connection.clone();
        let connection = shared.get();
        shared.append_journal_ingress_events_with_limits(
            &connection,
            events,
            Duration::from_secs(5),
            None,
            || Ok(()),
        )
    }
}

impl WorkspaceRegistry {
    pub(crate) fn journal_producer_manifests(
        &self,
    ) -> anyhow::Result<Vec<JournalProducerManifest>> {
        let db = self.connection.get();
        let mut statement =
            db.prepare("SELECT manifest_json FROM journal_producers ORDER BY producer_id ASC")?;
        statement
            .query_map([], |row| row.get::<_, String>(0))?
            .map(|value| Ok(serde_json::from_str(&value?)?))
            .collect()
    }

    /// Return only manifests that a userland producer can register and use.
    /// The reserved cmux hook manifest remains in the internal table because
    /// the journal kernel and checkpoint code need it, but it uses the legacy
    /// `agent` namespace and is not a userland `plugin.<id>` manifest.
    pub(crate) fn userland_journal_producer_manifests(
        &self,
    ) -> anyhow::Result<Vec<JournalProducerManifest>> {
        self.journal_producer_manifests().map(|manifests| {
            manifests
                .into_iter()
                .filter(|manifest| {
                    manifest.producer_id != crate::AGENT_HOOK_PRODUCER_ID
                        && manifest.producer_id != crate::shell_history::SHELL_PRODUCER_ID
                })
                .collect()
        })
    }

    pub(crate) fn put_journal_producer(
        &mut self,
        manifest: &JournalProducerManifest,
        origin: &str,
        idempotency_key: &str,
    ) -> anyhow::Result<JournalAppendCommit> {
        anyhow::ensure!(
            manifest.producer_id != crate::AGENT_HOOK_PRODUCER_ID,
            "the cmux agent producer is built in"
        );
        anyhow::ensure!(
            manifest.producer_id != crate::shell_history::SHELL_PRODUCER_ID,
            "the cmux shell producer id is reserved"
        );
        validate_journal_producer_manifest(manifest)?;
        validate_identifier("journal producer origin", origin)?;
        validate_identifier("journal producer idempotency key", idempotency_key)?;
        let manifest_value = serde_json::to_value(manifest)?;
        let fingerprint = Sha256::digest(canonical_json(&manifest_value)?.as_bytes());
        let db = self.connection.get();
        let tx = db.unchecked_transaction()?;
        if let Some(commit) = operation_receipt(
            &tx,
            "session.journal.producer.put",
            origin,
            idempotency_key,
            fingerprint.as_slice(),
        )? {
            return Ok(commit);
        }
        let current = tx
            .query_row(
                "SELECT manifest_version, manifest_json FROM journal_producers WHERE producer_id = ?1",
                [&manifest.producer_id],
                |row| Ok((row.get::<_, i64>(0)?, row.get::<_, String>(1)?)),
            )
            .optional()?;
        if let Some((version, stored)) = current {
            let version = u32::try_from(version).context("producer manifest version is invalid")?;
            anyhow::ensure!(
                manifest.manifest_version > version
                    || (manifest.manifest_version == version
                        && canonical_json(&serde_json::from_str(&stored)?)?
                            == canonical_json(&manifest_value)?),
                "journal producer manifest versions must increase"
            );
        }
        let now = unix_epoch_ms()?;
        tx.execute(
            "INSERT INTO journal_producers(
               producer_id, namespace, manifest_version, manifest_json, installed_at_ms
             ) VALUES(?1, ?2, ?3, ?4, ?5)
             ON CONFLICT(producer_id) DO UPDATE SET
               namespace=excluded.namespace,
               manifest_version=excluded.manifest_version,
               manifest_json=excluded.manifest_json,
               installed_at_ms=excluded.installed_at_ms",
            params![
                manifest.producer_id,
                manifest.namespace,
                i64::from(manifest.manifest_version),
                canonical_json(&manifest_value)?,
                i64::try_from(now)?,
            ],
        )?;
        let session_id = transaction_session_id(&tx)?;
        let subjects = vec![
            JournalSubject { kind: "session".into(), id: session_id },
            JournalSubject { kind: "producer".into(), id: manifest.producer_id.clone() },
        ];
        let producer = JournalProducer { kind: "journal_admin".into(), id: origin.into() };
        let event_id = random_event_id("producer");
        let sequence = append_journal_record(
            &tx,
            &JournalAppend {
                event_id: &event_id,
                schema_version: 1,
                kind: "journal.producer.installed",
                class: JournalClass::State,
                replay: JournalReplayPolicy::Required,
                occurred_at_ms: now,
                producer: &producer,
                authority: None,
                causation_id: None,
                correlation_id: Some(idempotency_key),
                causation_depth: 0,
                subjects: &subjects,
                sensitivity: JournalSensitivity::Metadata,
                payload: &manifest_value,
                content: None,
                resource_revision: None,
                previous_resource_revision: None,
                actor: None,
            },
        )?;
        let result = json!({
            "producer_id":manifest.producer_id,
            "manifest_version":manifest.manifest_version,
            "namespace":manifest.namespace,
            "sequence":sequence.to_string(),
            "event_id":event_id,
        });
        insert_operation_receipt(
            &tx,
            "session.journal.producer.put",
            origin,
            idempotency_key,
            fingerprint.as_slice(),
            sequence,
            &result,
        )?;
        tx.commit()?;
        Ok(JournalAppendCommit { sequence, event_id, replayed: false })
    }

    pub(crate) fn append_journal_ingress(
        &mut self,
        ingress: &JournalIngress,
        validated: &crate::journal_kernel::ValidatedJournalIngress,
        origin: &str,
        idempotency_key: &str,
    ) -> anyhow::Result<JournalAppendCommit> {
        let db = self.connection.get();
        let tx = db.unchecked_transaction()?;
        let commit =
            append_journal_ingress_transaction(&tx, ingress, validated, origin, idempotency_key)?;
        tx.commit()?;
        Ok(commit)
    }
}

fn append_journal_ingress_transaction(
    tx: &Transaction<'_>,
    ingress: &JournalIngress,
    validated: &crate::journal_kernel::ValidatedJournalIngress,
    origin: &str,
    idempotency_key: &str,
) -> anyhow::Result<JournalAppendCommit> {
    validate_journal_ingress_shape(ingress, origin, idempotency_key)?;
    let fingerprint = journal_ingress_fingerprint(ingress)?;
    if let Some(commit) =
        ingress_receipt(tx, &ingress.producer_id, origin, idempotency_key, fingerprint.as_slice())?
    {
        if ingress.producer_id == crate::AGENT_HOOK_PRODUCER_ID {
            WorkspaceRegistry::stage_agent_hook_pending(
                tx,
                &ingress.producer_id,
                origin,
                idempotency_key,
                commit.sequence,
                ingress,
            )?;
        }
        return Ok(commit);
    }
    let installed = tx
        .prepare_cached(
            "SELECT 1 FROM journal_producers
             WHERE producer_id = ?1 AND manifest_version = ?2",
        )?
        .query_row(params![ingress.producer_id, i64::from(ingress.manifest_version)], |_| Ok(()))
        .optional()?
        .is_some();
    anyhow::ensure!(installed, "journal producer or manifest version is not installed");
    let causation_depth = match ingress.causation_id.as_deref() {
        Some(causation_id) => {
            let parent_depth = tx
                .prepare_cached(
                    "SELECT causation_depth FROM journal_event_index WHERE event_id = ?1",
                )?
                .query_row([causation_id], |row| row.get::<_, i64>(0))
                .optional()?
                .context("journal causation event does not exist")?;
            u16::try_from(parent_depth)
                .context("journal parent causation depth is invalid")?
                .checked_add(1)
                .context("journal causation depth overflow")?
        }
        None => 0,
    };
    anyhow::ensure!(
        causation_depth <= MAX_CAUSATION_DEPTH,
        "journal causation depth exceeds {MAX_CAUSATION_DEPTH}"
    );
    let session_id = transaction_session_id(tx)?;
    let mut subjects = BTreeSet::from([
        JournalSubject { kind: "session".into(), id: session_id },
        JournalSubject { kind: "producer".into(), id: ingress.producer_id.clone() },
    ]);
    for subject in &ingress.subjects {
        validate_plugin_component("journal subject kind", &subject.kind)?;
        validate_identifier("journal subject id", &subject.id)?;
        subjects.insert(subject.clone());
    }
    expand_topology_subjects(tx, &mut subjects)?;
    let subjects = subjects.into_iter().collect::<Vec<_>>();
    let built_in_agent = ingress.producer_id == crate::AGENT_HOOK_PRODUCER_ID;
    let producer = JournalProducer {
        kind: if built_in_agent { "agent_adapter" } else { "plugin" }.into(),
        id: ingress.producer_id.clone(),
    };
    let authority = JournalAuthority {
        principal_id: origin.into(),
        lease_id: format!("producer:{}", ingress.producer_id),
        generation: ingress.manifest_version.to_string(),
        role: if built_in_agent { "agent.adapter" } else { "journal.producer" }.into(),
    };
    let event_id = random_event_id(if built_in_agent { "agent" } else { "plugin" });
    let occurred_at_ms = ingress.occurred_at_ms.map(WireDecimal::get).unwrap_or(unix_epoch_ms()?);
    let sequence = append_journal_record(
        tx,
        &JournalAppend {
            event_id: &event_id,
            schema_version: ingress.schema_version,
            kind: &ingress.kind,
            class: validated.class,
            replay: validated.replay,
            occurred_at_ms,
            producer: &producer,
            authority: Some(&authority),
            causation_id: ingress.causation_id.as_deref(),
            correlation_id: ingress.correlation_id.as_deref().or(Some(idempotency_key)),
            causation_depth,
            subjects: &subjects,
            sensitivity: validated.sensitivity,
            payload: &ingress.payload,
            content: None,
            resource_revision: None,
            previous_resource_revision: None,
            actor: None,
        },
    )?;
    let result = json!({
        "producer_id":ingress.producer_id,
        "sequence":sequence.to_string(),
        "event_id":event_id,
    });
    tx.prepare_cached(
        "INSERT INTO journal_ingress_receipts(
           producer_id, origin, idempotency_key, fingerprint, event_id,
           journal_sequence, result_json
         ) VALUES(?1, ?2, ?3, ?4, ?5, ?6, ?7)",
    )?
    .execute(params![
        ingress.producer_id,
        origin,
        idempotency_key,
        fingerprint.as_slice(),
        event_id,
        i64::try_from(sequence)?,
        canonical_json(&result)?,
    ])?;
    if built_in_agent {
        WorkspaceRegistry::stage_agent_hook_pending(
            tx,
            &ingress.producer_id,
            origin,
            idempotency_key,
            sequence,
            ingress,
        )?;
    }
    Ok(JournalAppendCommit { sequence, event_id, replayed: false })
}

impl WorkspaceRegistry {
    pub(crate) fn journal_checkpoint_receipt(
        &self,
        origin: &str,
        idempotency_key: &str,
    ) -> anyhow::Result<Option<JournalCheckpointCommit>> {
        validate_identifier("journal checkpoint origin", origin)?;
        validate_identifier("journal checkpoint idempotency key", idempotency_key)?;
        let fingerprint = checkpoint_request_fingerprint();
        let Some(journal) = operation_receipt(
            &self.connection.get(),
            "session.journal.checkpoint.create",
            origin,
            idempotency_key,
            fingerprint.as_slice(),
        )?
        else {
            return Ok(None);
        };
        let checkpoint_id = self.connection.get().query_row(
            "SELECT json_extract(result_json, '$.checkpoint_id')
             FROM journal_operation_receipts
             WHERE operation = 'session.journal.checkpoint.create'
               AND origin = ?1 AND idempotency_key = ?2",
            params![origin, idempotency_key],
            |row| row.get::<_, String>(0),
        )?;
        let checkpoint = query_journal_checkpoint(&self.connection.get(), &checkpoint_id)?
            .context("checkpoint receipt points to a missing checkpoint")?;
        Ok(Some(JournalCheckpointCommit { checkpoint, journal }))
    }

    pub(crate) fn create_journal_checkpoint(
        &mut self,
        source_sequence: u64,
        reducer_version: u32,
        state: &Value,
        blobs: &[JournalContentBlob],
        origin: &str,
        idempotency_key: &str,
    ) -> anyhow::Result<JournalCheckpointCommit> {
        anyhow::ensure!(reducer_version > 0, "checkpoint reducer_version must be positive");
        validate_identifier("journal checkpoint origin", origin)?;
        validate_identifier("journal checkpoint idempotency key", idempotency_key)?;
        let fingerprint = checkpoint_request_fingerprint();
        let db = self.connection.get();
        let tx = db.unchecked_transaction()?;
        if let Some(journal) = operation_receipt(
            &tx,
            "session.journal.checkpoint.create",
            origin,
            idempotency_key,
            fingerprint.as_slice(),
        )? {
            let checkpoint_id = tx.query_row(
                "SELECT json_extract(result_json, '$.checkpoint_id')
                 FROM journal_operation_receipts
                 WHERE operation = 'session.journal.checkpoint.create'
                   AND origin = ?1 AND idempotency_key = ?2",
                params![origin, idempotency_key],
                |row| row.get::<_, String>(0),
            )?;
            let checkpoint = query_journal_checkpoint(&tx, &checkpoint_id)?
                .context("checkpoint receipt points to a missing checkpoint")?;
            return Ok(JournalCheckpointCommit { checkpoint, journal });
        }
        anyhow::ensure!(
            journal_head(&tx)? == source_sequence,
            "session journal changed during checkpoint capture"
        );
        let now = unix_epoch_ms()?;
        for blob in blobs {
            insert_journal_content_blob(&tx, blob, now)?;
        }
        let content_refs = blobs.iter().map(|blob| blob.reference.clone()).collect::<Vec<_>>();
        let digest_input = json!({
            "source_sequence":source_sequence.to_string(),
            "reducer_version":reducer_version,
            "state":state,
            "content_refs":content_refs,
        });
        let digest = Sha256::digest(canonical_json(&digest_input)?.as_bytes());
        let digest_hex = encode_hex(digest.as_slice());
        let checkpoint_id = format!("checkpoint_{digest_hex}");
        tx.execute(
            "INSERT INTO journal_checkpoints(
               checkpoint_id, source_sequence, reducer_version, state_json,
               content_refs_json, sha256, created_at_ms
             ) VALUES(?1, ?2, ?3, ?4, ?5, ?6, ?7)",
            params![
                checkpoint_id,
                i64::try_from(source_sequence)?,
                i64::from(reducer_version),
                canonical_json(state)?,
                canonical_json(&serde_json::to_value(&content_refs)?)?,
                digest.as_slice(),
                i64::try_from(now)?,
            ],
        )?;
        let session_id = transaction_session_id(&tx)?;
        let subjects = vec![JournalSubject { kind: "session".into(), id: session_id }];
        let producer = JournalProducer { kind: "checkpoint".into(), id: origin.into() };
        let event_id = random_event_id("checkpoint");
        let payload = json!({
            "checkpoint_id":checkpoint_id,
            "source_sequence":source_sequence.to_string(),
            "reducer_version":reducer_version,
            "sha256":digest_hex,
            "content_refs":content_refs,
        });
        let sequence = append_journal_record(
            &tx,
            &JournalAppend {
                event_id: &event_id,
                schema_version: 1,
                kind: "journal.checkpoint.created",
                class: JournalClass::Checkpoint,
                replay: JournalReplayPolicy::Required,
                occurred_at_ms: now,
                producer: &producer,
                authority: None,
                causation_id: None,
                correlation_id: Some(idempotency_key),
                causation_depth: 0,
                subjects: &subjects,
                sensitivity: JournalSensitivity::Metadata,
                payload: &payload,
                content: None,
                resource_revision: None,
                previous_resource_revision: None,
                actor: None,
            },
        )?;
        let result = json!({
            "checkpoint_id":checkpoint_id,
            "source_sequence":source_sequence.to_string(),
            "reducer_version":reducer_version,
            "sha256":digest_hex,
            "sequence":sequence.to_string(),
            "event_id":event_id,
        });
        insert_operation_receipt(
            &tx,
            "session.journal.checkpoint.create",
            origin,
            idempotency_key,
            fingerprint.as_slice(),
            sequence,
            &result,
        )?;
        tx.commit()?;
        Ok(JournalCheckpointCommit {
            checkpoint: JournalCheckpoint {
                checkpoint_id,
                source_sequence,
                reducer_version,
                state: state.clone(),
                content_refs,
                sha256: digest_hex,
                created_at_ms: now,
            },
            journal: JournalAppendCommit { sequence, event_id, replayed: false },
        })
    }

    /// Load and verify one terminal's exit snapshot, decoded to replay bytes.
    pub(crate) fn terminal_exit_snapshot(
        &self,
        terminal_id: &str,
    ) -> anyhow::Result<Option<TerminalExitSnapshot>> {
        type SnapshotRow = (String, i64, i64, i64, String, String, Vec<u8>, i64, Vec<u8>);
        let Some(row) = self
            .connection
            .get()
            .query_row(
                "SELECT snapshot.generation, snapshot.covered_through, snapshot.cols,
                        snapshot.rows, snapshot.format, blob.codec, blob.content,
                        blob.uncompressed_bytes, blob.sha256
                 FROM terminal_exit_snapshots AS snapshot
                 JOIN journal_content_blobs AS blob USING(content_id)
                 WHERE snapshot.terminal_id = ?1",
                params![terminal_id],
                |row| {
                    Ok::<SnapshotRow, _>((
                        row.get(0)?,
                        row.get(1)?,
                        row.get(2)?,
                        row.get(3)?,
                        row.get(4)?,
                        row.get(5)?,
                        row.get(6)?,
                        row.get(7)?,
                        row.get(8)?,
                    ))
                },
            )
            .optional()?
        else {
            return Ok(None);
        };
        let (
            generation,
            covered_through,
            cols,
            rows,
            format,
            codec,
            compressed,
            uncompressed_bytes,
            digest,
        ) = row;
        anyhow::ensure!(
            format == "cmux.vt-replay.v1",
            "terminal exit snapshot format {format:?} is unsupported"
        );
        anyhow::ensure!(codec == "gzip", "terminal exit snapshot codec {codec:?} is unsupported");
        let covered_through =
            u64::try_from(covered_through).context("terminal exit snapshot coverage is invalid")?;
        let cols = u16::try_from(cols).context("terminal exit snapshot cols are invalid")?;
        let rows = u16::try_from(rows).context("terminal exit snapshot rows are invalid")?;
        let expected_bytes = usize::try_from(uncompressed_bytes)
            .context("terminal exit snapshot length is invalid")?;
        anyhow::ensure!(
            expected_bytes <= MAX_CHECKPOINT_CONTENT_UNCOMPRESSED_BYTES,
            "terminal exit snapshot exceeds the uncompressed size limit"
        );
        let decoder = flate2::read::GzDecoder::new(compressed.as_slice());
        let mut uncompressed = Vec::with_capacity(expected_bytes);
        decoder
            .take(u64::try_from(expected_bytes)?.saturating_add(1))
            .read_to_end(&mut uncompressed)
            .context("decompress terminal exit snapshot")?;
        anyhow::ensure!(
            uncompressed.len() == expected_bytes,
            "terminal exit snapshot length does not match its blob"
        );
        anyhow::ensure!(
            Sha256::digest(&uncompressed).as_slice() == digest.as_slice(),
            "terminal exit snapshot digest is invalid"
        );
        let replay: Value =
            serde_json::from_slice(&uncompressed).context("decode terminal exit snapshot")?;
        anyhow::ensure!(
            replay["format"].as_str() == Some("cmux.vt-replay.v1"),
            "terminal exit snapshot payload format is invalid"
        );
        let replay_bytes = replay["bytes_base64"]
            .as_str()
            .context("terminal exit snapshot omitted bytes_base64")?;
        let replay_bytes = base64::engine::general_purpose::STANDARD
            .decode(replay_bytes)
            .context("decode terminal exit snapshot bytes")?;
        Ok(Some(TerminalExitSnapshot { generation, covered_through, cols, rows, replay_bytes }))
    }

    pub(crate) fn journal_checkpoints(&self) -> anyhow::Result<Vec<JournalCheckpointSummary>> {
        let db = self.connection.get();
        let mut statement = db.prepare(
            "SELECT checkpoint_id, source_sequence, reducer_version, content_refs_json,
                    sha256, created_at_ms
             FROM journal_checkpoints
             ORDER BY source_sequence DESC, created_at_ms DESC, checkpoint_id DESC
             LIMIT ?1",
        )?;
        let rows = statement
            .query_map([JOURNAL_LIST_MAX_ITEMS as i64], |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    row.get::<_, i64>(1)?,
                    row.get::<_, i64>(2)?,
                    row.get::<_, String>(3)?,
                    row.get::<_, Vec<u8>>(4)?,
                    row.get::<_, i64>(5)?,
                ))
            })?
            .collect::<Result<Vec<_>, _>>()?;
        rows.into_iter()
            .map(
                |(
                    checkpoint_id,
                    source_sequence,
                    reducer_version,
                    content_refs,
                    digest,
                    created_at_ms,
                )| {
                    anyhow::ensure!(digest.len() == 32, "checkpoint digest is invalid");
                    let digest_hex = encode_hex(&digest);
                    anyhow::ensure!(
                        checkpoint_id == format!("checkpoint_{digest_hex}"),
                        "checkpoint id does not match its digest"
                    );
                    Ok(JournalCheckpointSummary {
                        checkpoint_id,
                        source_sequence: u64::try_from(source_sequence)?,
                        reducer_version: u32::try_from(reducer_version)?,
                        content_refs: serde_json::from_str(&content_refs)?,
                        sha256: digest_hex,
                        created_at_ms: u64::try_from(created_at_ms)?,
                    })
                },
            )
            .collect()
    }

    pub(crate) fn journal_checkpoint(
        &self,
        selector: &str,
    ) -> anyhow::Result<Option<JournalCheckpoint>> {
        let checkpoint_id = if selector == "latest" {
            self.connection
                .get()
                .query_row(
                    "SELECT checkpoint_id FROM journal_checkpoints
                     ORDER BY source_sequence DESC, created_at_ms DESC, checkpoint_id DESC LIMIT 1",
                    [],
                    |row| row.get::<_, String>(0),
                )
                .optional()?
        } else {
            Some(selector.to_string())
        };
        checkpoint_id
            .as_deref()
            .map(|id| query_journal_checkpoint(&self.connection.get(), id))
            .transpose()
            .map(Option::flatten)
    }
}

fn query_journal_checkpoint(
    connection: &Connection,
    checkpoint_id: &str,
) -> anyhow::Result<Option<JournalCheckpoint>> {
    let row = connection
        .query_row(
            "SELECT source_sequence, reducer_version, state_json, content_refs_json,
                    sha256, created_at_ms
             FROM journal_checkpoints WHERE checkpoint_id = ?1",
            [checkpoint_id],
            |row| {
                Ok((
                    row.get::<_, i64>(0)?,
                    row.get::<_, i64>(1)?,
                    row.get::<_, String>(2)?,
                    row.get::<_, String>(3)?,
                    row.get::<_, Vec<u8>>(4)?,
                    row.get::<_, i64>(5)?,
                ))
            },
        )
        .optional()?;
    let Some((source_sequence, reducer_version, state, refs, digest, created_at_ms)) = row else {
        return Ok(None);
    };
    anyhow::ensure!(digest.len() == 32, "checkpoint digest is invalid");
    let source_sequence = u64::try_from(source_sequence)?;
    let reducer_version = u32::try_from(reducer_version)?;
    let state = serde_json::from_str::<Value>(&state)?;
    let content_refs = serde_json::from_str::<Vec<JournalContentRef>>(&refs)?;
    let digest_input = json!({
        "source_sequence":source_sequence.to_string(),
        "reducer_version":reducer_version,
        "state":state,
        "content_refs":content_refs,
    });
    let computed_digest = Sha256::digest(canonical_json(&digest_input)?.as_bytes());
    anyhow::ensure!(
        computed_digest.as_slice() == digest.as_slice(),
        "checkpoint digest does not match its state"
    );
    let digest_hex = encode_hex(&digest);
    anyhow::ensure!(
        checkpoint_id == format!("checkpoint_{digest_hex}"),
        "checkpoint id does not match its digest"
    );
    Ok(Some(JournalCheckpoint {
        checkpoint_id: checkpoint_id.into(),
        source_sequence,
        reducer_version,
        state,
        content_refs,
        sha256: digest_hex,
        created_at_ms: u64::try_from(created_at_ms)?,
    }))
}

fn checkpoint_request_fingerprint() -> sha2::digest::Output<Sha256> {
    Sha256::digest(b"cmux.session-journal.checkpoint.create.v1")
}

fn transaction_session_id(transaction: &Transaction<'_>) -> anyhow::Result<String> {
    transaction
        .prepare_cached("SELECT value FROM meta WHERE key = 'session_public_id'")?
        .query_row([], |row| row.get(0))
        .context("read journal session id")
}

fn journal_head(transaction: &Transaction<'_>) -> anyhow::Result<u64> {
    let value = transaction.query_row(
        "SELECT MAX(
           COALESCE((SELECT MAX(sequence) FROM session_journal), 0),
           COALESCE((SELECT MAX(end_sequence) FROM journal_segments), 0)
         )",
        [],
        |row| row.get::<_, i64>(0),
    )?;
    u64::try_from(value).context("journal head sequence is negative")
}

fn default_hook_regex_field() -> String {
    "record".into()
}

const fn default_true() -> bool {
    true
}

const fn is_false(value: &bool) -> bool {
    !*value
}

fn operation_receipt(
    connection: &Connection,
    operation: &str,
    origin: &str,
    idempotency_key: &str,
    fingerprint: &[u8],
) -> anyhow::Result<Option<JournalAppendCommit>> {
    let stored = connection
        .query_row(
            "SELECT fingerprint, result_json, journal_sequence
             FROM journal_operation_receipts
             WHERE operation = ?1 AND origin = ?2 AND idempotency_key = ?3",
            params![operation, origin, idempotency_key],
            |row| Ok((row.get::<_, Vec<u8>>(0)?, row.get::<_, String>(1)?, row.get::<_, i64>(2)?)),
        )
        .optional()?;
    let Some((stored_fingerprint, result, sequence)) = stored else { return Ok(None) };
    anyhow::ensure!(
        stored_fingerprint == fingerprint,
        "journal idempotency key was retried with a different payload"
    );
    let result: Value = serde_json::from_str(&result)?;
    Ok(Some(JournalAppendCommit {
        sequence: u64::try_from(sequence)?,
        event_id: result["event_id"].as_str().context("receipt omitted event_id")?.into(),
        replayed: true,
    }))
}

fn encode_hex(bytes: &[u8]) -> String {
    const HEX: &[u8; 16] = b"0123456789abcdef";
    let mut encoded = String::with_capacity(bytes.len() * 2);
    for byte in bytes {
        encoded.push(char::from(HEX[usize::from(byte >> 4)]));
        encoded.push(char::from(HEX[usize::from(byte & 0x0f)]));
    }
    encoded
}

fn decode_sha256(value: &str) -> anyhow::Result<[u8; 32]> {
    anyhow::ensure!(value.len() == 64, "SHA-256 digest must contain 64 hexadecimal characters");
    let mut decoded = [0_u8; 32];
    for (index, chunk) in value.as_bytes().chunks_exact(2).enumerate() {
        let text = std::str::from_utf8(chunk)?;
        decoded[index] =
            u8::from_str_radix(text, 16).context("SHA-256 digest is not hexadecimal")?;
    }
    Ok(decoded)
}

/// Store one content-addressed blob, tolerating an identical replay and
/// rejecting a content-id collision with different bytes.
fn insert_journal_content_blob(
    tx: &Transaction<'_>,
    blob: &JournalContentBlob,
    now: u64,
) -> anyhow::Result<()> {
    tx.execute(
        "INSERT OR IGNORE INTO journal_content_blobs(
           content_id, sha256, codec, content, uncompressed_bytes, created_at_ms
         ) VALUES(?1, ?2, ?3, ?4, ?5, ?6)",
        params![
            blob.reference.content_id,
            blob.digest.as_slice(),
            blob.reference.codec,
            blob.compressed,
            i64::try_from(blob.reference.uncompressed_bytes)?,
            i64::try_from(now)?,
        ],
    )?;
    let matches = tx.query_row(
        "SELECT EXISTS(
           SELECT 1 FROM journal_content_blobs
           WHERE content_id = ?1 AND sha256 = ?2 AND codec = ?3
             AND content = ?4 AND uncompressed_bytes = ?5
         )",
        params![
            blob.reference.content_id,
            blob.digest.as_slice(),
            blob.reference.codec,
            blob.compressed,
            i64::try_from(blob.reference.uncompressed_bytes)?,
        ],
        |row| row.get::<_, bool>(0),
    )?;
    anyhow::ensure!(matches, "checkpoint content id collided with different content");
    Ok(())
}

fn verify_journal_content_blob(blob: &JournalContentBlob) -> anyhow::Result<()> {
    anyhow::ensure!(
        blob.reference.format == "cmux.vt-replay.v1" && blob.reference.codec == "gzip",
        "checkpoint content format or codec is unsupported"
    );
    anyhow::ensure!(
        blob.reference.sha256 == encode_hex(&blob.digest),
        "checkpoint content digest is not canonical"
    );
    anyhow::ensure!(
        blob.reference.content_id == format!("jcontent_{}", blob.reference.sha256),
        "checkpoint content id does not match its digest"
    );
    let expected_bytes = usize::try_from(blob.reference.uncompressed_bytes)?;
    anyhow::ensure!(
        expected_bytes <= MAX_CHECKPOINT_CONTENT_UNCOMPRESSED_BYTES,
        "checkpoint content exceeds the uncompressed size limit"
    );
    // Preserve the exact unread compressed suffix, as with archived journal
    // segments: read::GzDecoder may consume bytes after the first member.
    let mut decoder = flate2::bufread::GzDecoder::new(blob.compressed.as_slice());
    let mut uncompressed = Vec::new();
    decoder
        .by_ref()
        .take(u64::try_from(expected_bytes)?.saturating_add(1))
        .read_to_end(&mut uncompressed)?;
    anyhow::ensure!(
        uncompressed.len() == expected_bytes,
        "checkpoint content length does not match its reference"
    );
    anyhow::ensure!(
        decoder.into_inner().is_empty(),
        "checkpoint content contains trailing compressed data"
    );
    anyhow::ensure!(
        Sha256::digest(&uncompressed).as_slice() == blob.digest.as_slice(),
        "checkpoint content digest does not match its reference"
    );
    Ok(())
}

fn serialize_decimal<S>(value: &u64, serializer: S) -> Result<S::Ok, S::Error>
where
    S: serde::Serializer,
{
    serializer.serialize_str(&value.to_string())
}

fn deserialize_decimal<'de, D>(deserializer: D) -> Result<u64, D::Error>
where
    D: serde::Deserializer<'de>,
{
    let value = String::deserialize(deserializer)?;
    if value.is_empty()
        || (value.len() > 1 && value.starts_with('0'))
        || !value.bytes().all(|byte| byte.is_ascii_digit())
    {
        return Err(serde::de::Error::custom("decimal must be canonical unsigned digits"));
    }
    value.parse().map_err(serde::de::Error::custom)
}

fn insert_operation_receipt(
    transaction: &Transaction<'_>,
    operation: &str,
    origin: &str,
    idempotency_key: &str,
    fingerprint: &[u8],
    sequence: u64,
    result: &Value,
) -> anyhow::Result<()> {
    transaction.execute(
        "INSERT INTO journal_operation_receipts(
           operation, origin, idempotency_key, fingerprint, result_json, journal_sequence
         ) VALUES(?1, ?2, ?3, ?4, ?5, ?6)",
        params![
            operation,
            origin,
            idempotency_key,
            fingerprint,
            canonical_json(result)?,
            i64::try_from(sequence)?,
        ],
    )?;
    Ok(())
}

fn validate_journal_ingress_shape(
    ingress: &JournalIngress,
    origin: &str,
    idempotency_key: &str,
) -> anyhow::Result<()> {
    validate_identifier("journal ingress origin", origin)?;
    validate_identifier("journal ingress idempotency key", idempotency_key)?;
    validate_plugin_component("producer_id", &ingress.producer_id)?;
    validate_dotted_kind(&ingress.kind)?;
    anyhow::ensure!(ingress.schema_version > 0, "schema_version must be positive");
    anyhow::ensure!(
        serde_json::to_vec(&ingress.payload)?.len() <= MAX_EVENT_PAYLOAD_BYTES,
        "journal event payload exceeds {MAX_EVENT_PAYLOAD_BYTES} bytes"
    );
    Ok(())
}

fn journal_ingress_fingerprint(ingress: &JournalIngress) -> anyhow::Result<[u8; 32]> {
    let ingress_value = serde_json::to_value(ingress)?;
    Ok(Sha256::digest(canonical_json(&ingress_value)?.as_bytes()).into())
}

fn ingress_receipt(
    connection: &Connection,
    producer_id: &str,
    origin: &str,
    idempotency_key: &str,
    fingerprint: &[u8],
) -> anyhow::Result<Option<JournalAppendCommit>> {
    let stored = connection
        .prepare_cached(
            "SELECT fingerprint, event_id, journal_sequence
             FROM journal_ingress_receipts
             WHERE producer_id = ?1 AND origin = ?2 AND idempotency_key = ?3",
        )?
        .query_row(params![producer_id, origin, idempotency_key], |row| {
            Ok((row.get::<_, Vec<u8>>(0)?, row.get::<_, String>(1)?, row.get::<_, i64>(2)?))
        })
        .optional()?;
    let Some((stored_fingerprint, event_id, sequence)) = stored else { return Ok(None) };
    anyhow::ensure!(
        stored_fingerprint == fingerprint,
        "journal ingress idempotency key was retried with a different payload"
    );
    Ok(Some(JournalAppendCommit { sequence: u64::try_from(sequence)?, event_id, replayed: true }))
}

fn validate_plugin_component(label: &str, value: &str) -> anyhow::Result<()> {
    anyhow::ensure!(
        !value.is_empty()
            && value.len() <= 64
            && value.as_bytes().first().is_some_and(|byte| byte.is_ascii_alphanumeric())
            && value.bytes().all(|byte| {
                byte.is_ascii_lowercase() || byte.is_ascii_digit() || byte == b'_' || byte == b'-'
            }),
        "{label} must match [a-z0-9][a-z0-9_-]* and contain at most 64 bytes"
    );
    Ok(())
}

fn validate_dotted_kind(value: &str) -> anyhow::Result<()> {
    anyhow::ensure!(
        !value.is_empty()
            && value.len() <= 128
            && value.split('.').all(|component| {
                !component.is_empty()
                    && component.as_bytes().first().is_some_and(|byte| byte.is_ascii_alphanumeric())
                    && component.bytes().all(|byte| {
                        byte.is_ascii_lowercase()
                            || byte.is_ascii_digit()
                            || byte == b'_'
                            || byte == b'-'
                    })
            }),
        "journal event kind must match dotted [a-z0-9][a-z0-9_-]* components"
    );
    Ok(())
}

fn sensitivity_rank(value: JournalSensitivity) -> u8 {
    match value {
        JournalSensitivity::Public => 0,
        JournalSensitivity::Metadata => 1,
        JournalSensitivity::Sensitive => 2,
        JournalSensitivity::Secret => 3,
    }
}

pub(super) fn random_event_id(category: &str) -> String {
    format!("event_{category}_{}", new_uuid_v4().replace('-', ""))
}

#[cfg(test)]
#[path = "journal_extensions_tests.rs"]
mod tests;
