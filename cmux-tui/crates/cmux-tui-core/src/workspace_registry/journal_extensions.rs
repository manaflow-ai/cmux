use super::*;
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
const MAX_EVENT_PAYLOAD_BYTES: usize = 1024 * 1024;
const MAX_CAUSATION_DEPTH: u16 = 32;
const JOURNAL_SEGMENT_RECORD_LIMIT: usize = 1_024;
const MAX_CHECKPOINT_CONTENT_UNCOMPRESSED_BYTES: usize = 256 * 1024 * 1024;

fn ensure_journal_deadline(deadline: Option<Instant>) -> anyhow::Result<()> {
    anyhow::ensure!(
        deadline.is_none_or(|deadline| Instant::now() < deadline),
        "session journal commit deadline expired"
    );
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
           sealed_at_ms INTEGER NOT NULL CHECK(sealed_at_ms >= 0)
         );
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
         CREATE TRIGGER IF NOT EXISTS journal_checkpoints_reject_delete
           BEFORE DELETE ON journal_checkpoints
         BEGIN
           SELECT RAISE(ABORT, 'journal checkpoints are immutable');
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
    let delivery_columns = {
        let mut statement = transaction.prepare("PRAGMA table_info(journal_hook_deliveries)")?;
        statement
            .query_map([], |row| row.get::<_, String>(1))?
            .collect::<Result<HashSet<_>, _>>()?
    };
    if !delivery_columns.contains("started_event_id") {
        transaction
            .execute("ALTER TABLE journal_hook_deliveries ADD COLUMN started_event_id TEXT", [])?;
    }
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
    let installed = transaction.query_row(
        "SELECT manifest_json FROM journal_producers WHERE producer_id = ?1",
        [crate::AGENT_HOOK_PRODUCER_ID],
        |row| row.get::<_, String>(0),
    )?;
    anyhow::ensure!(
        serde_json::from_str::<JournalProducerManifest>(&installed)? == manifest,
        "reserved cmux agent producer manifest does not match this binary"
    );
    Ok(())
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

fn table_columns(transaction: &Transaction<'_>, table: &str) -> anyhow::Result<HashSet<String>> {
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
        anyhow::ensure!(
            matches!(
                regex.field.as_str(),
                "kind" | "subjects" | "payload" | "record" | "terminal_output"
            ),
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
    #[cfg(test)]
    pub(crate) fn append_journal_ingress_events(
        &mut self,
        events: &[&crate::journal_ingress::JournalIngressEvent],
    ) -> anyhow::Result<Vec<Option<JournalAppendCommit>>> {
        self.append_journal_ingress_events_with_limits(events, Duration::from_secs(5), None, || {
            Ok(())
        })
    }

    pub(crate) fn append_journal_ingress_events_with_deadline<F>(
        &mut self,
        events: &[&crate::journal_ingress::JournalIngressEvent],
        deadline: Instant,
        busy_timeout: Duration,
        admit_commit: F,
    ) -> anyhow::Result<Vec<Option<JournalAppendCommit>>>
    where
        F: FnOnce() -> anyhow::Result<()>,
    {
        self.append_journal_ingress_events_with_limits(
            events,
            busy_timeout,
            Some(deadline),
            admit_commit,
        )
    }

    fn append_journal_ingress_events_with_limits<F>(
        &mut self,
        events: &[&crate::journal_ingress::JournalIngressEvent],
        busy_timeout: Duration,
        deadline: Option<Instant>,
        admit_commit: F,
    ) -> anyhow::Result<Vec<Option<JournalAppendCommit>>>
    where
        F: FnOnce() -> anyhow::Result<()>,
    {
        ensure_journal_deadline(deadline)?;
        self.connection.busy_timeout(busy_timeout)?;
        let deadline_active = deadline.map(|_| Arc::new(AtomicBool::new(true)));
        if let (Some(deadline), Some(active)) = (deadline, deadline_active.as_ref())
            && let Err(error) = self.connection.progress_handler(
                1,
                Some({
                    let active = active.clone();
                    move || active.load(Ordering::Acquire) && Instant::now() >= deadline
                }),
            )
        {
            let error = anyhow::Error::new(error);
            return match self.connection.busy_timeout(Duration::from_secs(5)) {
                Ok(()) => Err(error),
                Err(reset_error) => Err(error.context(format!(
                    "also failed to restore workspace registry busy timeout: {reset_error}"
                ))),
            };
        }
        let result = self.append_journal_ingress_events_with_current_timeout(
            events,
            deadline,
            deadline_active.as_deref(),
            busy_timeout,
            admit_commit,
        );
        let clear_progress = if deadline.is_some() {
            self.connection.progress_handler(0, None::<fn() -> bool>)
        } else {
            Ok(())
        };
        let reset_timeout = self.connection.busy_timeout(Duration::from_secs(5));
        let cleanup = match (clear_progress, reset_timeout) {
            (Ok(()), Ok(())) => Ok(()),
            (Err(error), _) => {
                Err(anyhow::Error::new(error).context("clear workspace registry deadline handler"))
            }
            (Ok(()), Err(error)) => {
                Err(anyhow::Error::new(error).context("restore workspace registry busy timeout"))
            }
        };
        match (result, cleanup) {
            (result, Ok(())) => result,
            (Ok(_), Err(error)) => Err(error),
            (Err(error), Err(cleanup_error)) => Err(error.context(format!(
                "also failed to restore workspace registry limits: {cleanup_error:#}"
            ))),
        }
    }

    fn append_journal_ingress_events_with_current_timeout<F>(
        &mut self,
        events: &[&crate::journal_ingress::JournalIngressEvent],
        deadline: Option<Instant>,
        deadline_active: Option<&AtomicBool>,
        busy_timeout: Duration,
        admit_commit: F,
    ) -> anyhow::Result<Vec<Option<JournalAppendCommit>>>
    where
        F: FnOnce() -> anyhow::Result<()>,
    {
        ensure_journal_deadline(deadline)?;
        if events.is_empty() {
            return Ok(Vec::new());
        }
        #[cfg(test)]
        let before_commit = self.journal_before_commit.take();
        #[cfg(test)]
        let after_commit_admission = self.journal_after_commit_admission.take();
        let tx = self.connection.transaction()?;
        // This guard disables the progress callback before `tx` rolls back on
        // every early return. An expired callback must interrupt forward work,
        // but it must never interrupt the rollback that removes partial rows.
        let deadline_guard = JournalDeadlineTransactionGuard { active: deadline_active };
        let session_id = transaction_session_id(&tx)?;
        let terminal_ids = events
            .iter()
            .filter_map(|event| match *event {
                crate::journal_ingress::JournalIngressEvent::TerminalOutput {
                    terminal_id, ..
                }
                | crate::journal_ingress::JournalIngressEvent::TerminalResize {
                    terminal_id, ..
                }
                | crate::journal_ingress::JournalIngressEvent::TerminalOutputGap {
                    terminal_id,
                    ..
                } => Some(terminal_id.as_str().to_string()),
                crate::journal_ingress::JournalIngressEvent::Frontend { .. }
                | crate::journal_ingress::JournalIngressEvent::Producer { .. }
                | crate::journal_ingress::JournalIngressEvent::TerminalBarrier => None,
            })
            .collect::<HashSet<_>>();
        let mut expanded_by_terminal =
            terminal_topology_subjects_batch(&tx, terminal_ids.iter().cloned())?;
        let mut subjects_by_terminal = HashMap::<String, Vec<JournalSubject>>::new();
        for terminal_id in terminal_ids {
            let mut subjects = BTreeSet::from([
                JournalSubject { kind: "session".into(), id: session_id.clone() },
                JournalSubject { kind: "terminal".into(), id: terminal_id.clone() },
            ]);
            subjects.extend(expanded_by_terminal.remove(&terminal_id).unwrap_or_default());
            subjects_by_terminal.insert(terminal_id, subjects.into_iter().collect::<Vec<_>>());
        }
        let mut terminal_offsets = HashMap::<(&str, &str), u64>::new();
        let mut commits = Vec::with_capacity(events.len());
        for event in events {
            ensure_journal_deadline(deadline)?;
            if matches!(*event, crate::journal_ingress::JournalIngressEvent::TerminalBarrier) {
                commits.push(None);
                continue;
            }
            if let crate::journal_ingress::JournalIngressEvent::Producer {
                ingress,
                validated,
                origin,
                idempotency_key,
            } = *event
            {
                commits.push(Some(append_journal_ingress_transaction(
                    &tx,
                    ingress,
                    validated,
                    origin,
                    idempotency_key,
                )?));
                continue;
            }
            if let crate::journal_ingress::JournalIngressEvent::Frontend {
                principal_id,
                occurred_at_ms,
                event,
            } = *event
            {
                validate_identifier("frontend journal principal", principal_id)?;
                validate_identifier("frontend journal generation", event.generation())?;
                validate_identifier("frontend journal event id", event.event_id())?;
                let mut subjects = BTreeSet::from([
                    JournalSubject { kind: "session".into(), id: session_id.clone() },
                    JournalSubject { kind: "client".into(), id: principal_id.clone() },
                    JournalSubject {
                        kind: "frontend_projection".into(),
                        id: event.frontend_projection_id().to_string(),
                    },
                ]);
                let (kind, payload) = match event {
                    crate::FrontendJournalEvent::Focus {
                        event_id: _,
                        frontend_projection_id,
                        generation,
                        target,
                        workspace_id,
                        screen_id,
                        pane_id,
                        tab_id,
                        content_id,
                    } => {
                        if let Some(id) = workspace_id {
                            subjects.insert(JournalSubject {
                                kind: "workspace".into(),
                                id: id.to_string(),
                            });
                        }
                        if let Some(id) = screen_id {
                            subjects.insert(JournalSubject {
                                kind: "screen".into(),
                                id: id.to_string(),
                            });
                        }
                        if let Some(id) = pane_id {
                            subjects
                                .insert(JournalSubject { kind: "pane".into(), id: id.to_string() });
                        }
                        if let Some(id) = tab_id {
                            subjects
                                .insert(JournalSubject { kind: "tab".into(), id: id.to_string() });
                        }
                        if let Some(id) = content_id {
                            subjects.insert(JournalSubject {
                                kind: match id {
                                    ContentPublicId::Terminal(_) => "terminal",
                                    ContentPublicId::Browser(_) => "browser",
                                }
                                .into(),
                                id: id.as_str().into(),
                            });
                        }
                        (
                            "frontend.focus.changed",
                            json!({
                                "format":"cmux.frontend-focus.v1",
                                "frontend_projection_id":frontend_projection_id,
                                "generation":generation,
                                "target":target,
                                "workspace_id":workspace_id,
                                "screen_id":screen_id,
                                "pane_id":pane_id,
                                "tab_id":tab_id,
                                "content_id":content_id.as_ref().map(ContentPublicId::as_str),
                            }),
                        )
                    }
                    crate::FrontendJournalEvent::Resize {
                        event_id: _,
                        frontend_projection_id,
                        generation,
                        cols,
                        rows,
                        cell_width,
                        cell_height,
                    } => {
                        anyhow::ensure!(
                            *cols > 0 && *rows > 0 && *cell_width > 0 && *cell_height > 0,
                            "frontend journal geometry must be positive"
                        );
                        (
                            "frontend.resized",
                            json!({
                                "format":"cmux.frontend-geometry.v1",
                                "frontend_projection_id":frontend_projection_id,
                                "generation":generation,
                                "cols":cols,
                                "rows":rows,
                                "cell_width":cell_width,
                                "cell_height":cell_height,
                            }),
                        )
                    }
                    crate::FrontendJournalEvent::Viewport {
                        event_id: _,
                        frontend_projection_id,
                        generation,
                        screen_id,
                        offset,
                        target,
                        settled,
                    } => {
                        if let Some(id) = screen_id {
                            subjects.insert(JournalSubject {
                                kind: "screen".into(),
                                id: id.to_string(),
                            });
                        }
                        (
                            "frontend.viewport.changed",
                            json!({
                                "format":"cmux.frontend-viewport.v1",
                                "frontend_projection_id":frontend_projection_id,
                                "generation":generation,
                                "screen_id":screen_id,
                                "offset":offset.to_string(),
                                "target":target.to_string(),
                                "settled":settled,
                            }),
                        )
                    }
                };
                expand_topology_subjects(&tx, &mut subjects)?;
                let subjects = subjects.into_iter().collect::<Vec<_>>();
                let producer = JournalProducer {
                    kind: "frontend".into(),
                    id: event.frontend_projection_id().to_string(),
                };
                let authority = JournalAuthority {
                    principal_id: principal_id.clone(),
                    lease_id: format!("frontend:{}", event.frontend_projection_id()),
                    generation: event.generation().into(),
                    role: "frontend.observer".into(),
                };
                let duplicate_sequence = tx
                    .query_row(
                        "SELECT sequence FROM journal_event_index WHERE event_id = ?1",
                        [event.event_id()],
                        |row| row.get::<_, i64>(0),
                    )
                    .optional()?
                    .map(u64::try_from)
                    .transpose()
                    .context("frontend journal sequence is negative")?;
                if let Some(sequence) = duplicate_sequence {
                    let mut records = query_session_journal_sequences(&tx, &[sequence])?;
                    let stored = records
                        .pop()
                        .context("frontend journal event index points to an absent record")?;
                    anyhow::ensure!(
                        stored.kind == kind
                            && stored.class == JournalClass::Observation
                            && stored.replay == JournalReplayPolicy::Advisory
                            && stored.producer == producer
                            && stored.authority.as_ref() == Some(&authority)
                            && stored.sensitivity == JournalSensitivity::Metadata
                            && stored.payload == payload,
                        "frontend journal event id was reused with different content"
                    );
                    commits.push(None);
                    continue;
                }
                append_journal_record(
                    &tx,
                    &JournalAppend {
                        event_id: event.event_id(),
                        schema_version: 1,
                        kind,
                        class: JournalClass::Observation,
                        replay: JournalReplayPolicy::Advisory,
                        occurred_at_ms: *occurred_at_ms,
                        producer: &producer,
                        authority: Some(&authority),
                        causation_id: None,
                        correlation_id: None,
                        causation_depth: 0,
                        subjects: &subjects,
                        sensitivity: JournalSensitivity::Metadata,
                        payload: &payload,
                        content: None,
                        resource_revision: None,
                        previous_resource_revision: None,
                    },
                )?;
                commits.push(None);
                continue;
            }
            let (terminal_id, generation, occurred_at_ms, kind, class, payload, content) =
                match *event {
                    crate::journal_ingress::JournalIngressEvent::TerminalOutput {
                        terminal_id,
                        generation,
                        occurred_at_ms,
                        bytes,
                    } => {
                        let key = (terminal_id.as_str(), generation.as_ref());
                        let start = match terminal_offsets.get(&key).copied() {
                            Some(offset) => offset,
                            None => {
                                let offset = tx
                                    .query_row(
                                        "SELECT next_offset FROM journal_terminal_streams
                                     WHERE terminal_id = ?1 AND generation = ?2",
                                        params![terminal_id.as_str(), generation.as_ref()],
                                        |row| row.get::<_, i64>(0),
                                    )
                                    .optional()?
                                    .map(u64::try_from)
                                    .transpose()
                                    .context("terminal journal offset is negative")?
                                    .unwrap_or(0);
                                terminal_offsets.insert(key, offset);
                                offset
                            }
                        };
                        let end = start
                            .checked_add(u64::try_from(bytes.len())?)
                            .context("terminal journal offset exhausted")?;
                        terminal_offsets.insert(key, end);
                        let digest = Sha256::digest(bytes);
                        (
                            terminal_id,
                            generation,
                            *occurred_at_ms,
                            "terminal.output",
                            JournalClass::Observation,
                            json!({
                                "format":"cmux.terminal-output.v1",
                                "encoding":"raw",
                                "byte_count":bytes.len().to_string(),
                                "sha256":encode_hex(digest.as_slice()),
                                "stream_offset_start":start.to_string(),
                                "stream_offset_end":end.to_string(),
                            }),
                            Some(bytes.as_slice()),
                        )
                    }
                    crate::journal_ingress::JournalIngressEvent::TerminalResize {
                        terminal_id,
                        generation,
                        occurred_at_ms,
                        cols,
                        rows,
                        cell_width,
                        cell_height,
                    } => (
                        terminal_id,
                        generation,
                        *occurred_at_ms,
                        "terminal.resized",
                        JournalClass::State,
                        json!({
                            "format":"cmux.terminal-geometry.v1",
                            "cols":cols,
                            "rows":rows,
                            "cell_width":cell_width,
                            "cell_height":cell_height,
                        }),
                        None,
                    ),
                    crate::journal_ingress::JournalIngressEvent::TerminalOutputGap {
                        terminal_id,
                        generation,
                        occurred_at_ms,
                        reason,
                    } => (
                        terminal_id,
                        generation,
                        *occurred_at_ms,
                        "terminal.output.gap",
                        JournalClass::State,
                        json!({
                            "format":"cmux.terminal-output-gap.v1",
                            "reason":reason,
                        }),
                        None,
                    ),
                    crate::journal_ingress::JournalIngressEvent::Frontend { .. }
                    | crate::journal_ingress::JournalIngressEvent::Producer { .. }
                    | crate::journal_ingress::JournalIngressEvent::TerminalBarrier => {
                        unreachable!()
                    }
                };
            let subjects = subjects_by_terminal
                .get(terminal_id.as_str())
                .context("terminal journal subjects were not prepared")?;
            let producer = JournalProducer {
                kind: "terminal_runtime".into(),
                id: terminal_id.as_str().into(),
            };
            let authority = JournalAuthority {
                principal_id: "cmux.terminal-runtime".into(),
                lease_id: format!("terminal:{}", terminal_id.as_str()),
                generation: generation.to_string(),
                role: "terminal.runtime".into(),
            };
            let event_id = random_event_id("terminal");
            append_journal_record(
                &tx,
                &JournalAppend {
                    event_id: &event_id,
                    schema_version: 1,
                    kind,
                    class,
                    replay: JournalReplayPolicy::Required,
                    occurred_at_ms,
                    producer: &producer,
                    authority: Some(&authority),
                    causation_id: None,
                    correlation_id: None,
                    causation_depth: 0,
                    subjects,
                    sensitivity: JournalSensitivity::Sensitive,
                    payload: &payload,
                    content,
                    resource_revision: None,
                    previous_resource_revision: None,
                },
            )?;
            commits.push(None);
        }
        ensure_journal_deadline(deadline)?;
        for ((terminal_id, generation), next_offset) in terminal_offsets {
            tx.execute(
                "INSERT INTO journal_terminal_streams(terminal_id, generation, next_offset)
                 VALUES(?1, ?2, ?3)
                 ON CONFLICT(terminal_id, generation) DO UPDATE SET
                   next_offset = excluded.next_offset",
                params![terminal_id, generation, i64::try_from(next_offset)?],
            )?;
        }
        #[cfg(test)]
        if let Some((entered, release)) = before_commit {
            entered.send(()).context("report journal before-commit test hook")?;
            release.recv().context("release journal before-commit test hook")?;
        }
        ensure_journal_deadline(deadline)?;
        if let Some(deadline) = deadline {
            tx.busy_timeout(deadline.saturating_duration_since(Instant::now()).min(busy_timeout))?;
        }
        ensure_journal_deadline(deadline)?;
        admit_commit()?;
        // The caller now owns the authoritative commit result. Disable the
        // transaction deadline so a slow fsync cannot produce a false timeout
        // followed by a durable commit.
        deadline_guard.disarm();
        #[cfg(test)]
        if let Some((entered, release)) = after_commit_admission {
            entered.send(()).context("report journal commit-admission test hook")?;
            release.recv().context("release journal commit-admission test hook")?;
        }
        match tx.execute_batch("COMMIT") {
            Ok(()) => Ok(commits),
            Err(error) => {
                deadline_guard.disarm();
                match tx.rollback() {
                    Ok(()) => Err(error.into()),
                    Err(rollback_error) => Err(anyhow::Error::new(error).context(format!(
                        "also failed to roll back expired journal transaction: {rollback_error}"
                    ))),
                }
            }
        }
    }

    #[cfg(test)]
    pub(crate) fn set_journal_before_commit_for_test(
        &mut self,
        entered: std::sync::mpsc::SyncSender<()>,
        release: std::sync::mpsc::Receiver<()>,
    ) {
        self.journal_before_commit = Some((entered, release));
    }

    #[cfg(test)]
    pub(crate) fn set_journal_after_commit_admission_for_test(
        &mut self,
        entered: std::sync::mpsc::SyncSender<()>,
        release: std::sync::mpsc::Receiver<()>,
    ) {
        self.journal_after_commit_admission = Some((entered, release));
    }

    pub(crate) fn journal_producer_manifests(
        &self,
    ) -> anyhow::Result<Vec<JournalProducerManifest>> {
        let mut statement = self
            .connection
            .prepare("SELECT manifest_json FROM journal_producers ORDER BY producer_id ASC")?;
        statement
            .query_map([], |row| row.get::<_, String>(0))?
            .map(|value| Ok(serde_json::from_str(&value?)?))
            .collect()
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
        validate_journal_producer_manifest(manifest)?;
        validate_identifier("journal producer origin", origin)?;
        validate_identifier("journal producer idempotency key", idempotency_key)?;
        let manifest_value = serde_json::to_value(manifest)?;
        let fingerprint = Sha256::digest(canonical_json(&manifest_value)?.as_bytes());
        let tx = self.connection.transaction()?;
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
        let tx = self.connection.transaction()?;
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
    validate_identifier("journal ingress origin", origin)?;
    validate_identifier("journal ingress idempotency key", idempotency_key)?;
    validate_plugin_component("producer_id", &ingress.producer_id)?;
    validate_dotted_kind(&ingress.kind)?;
    anyhow::ensure!(ingress.schema_version > 0, "schema_version must be positive");
    anyhow::ensure!(
        serde_json::to_vec(&ingress.payload)?.len() <= MAX_EVENT_PAYLOAD_BYTES,
        "journal event payload exceeds {MAX_EVENT_PAYLOAD_BYTES} bytes"
    );
    let ingress_value = serde_json::to_value(ingress)?;
    let fingerprint = Sha256::digest(canonical_json(&ingress_value)?.as_bytes());
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
        .query_row(
            "SELECT 1 FROM journal_producers
             WHERE producer_id = ?1 AND manifest_version = ?2",
            params![ingress.producer_id, i64::from(ingress.manifest_version)],
            |_| Ok(()),
        )
        .optional()?
        .is_some();
    anyhow::ensure!(installed, "journal producer or manifest version is not installed");
    let causation_depth = match ingress.causation_id.as_deref() {
        Some(causation_id) => {
            let parent_depth = tx
                .query_row(
                    "SELECT causation_depth FROM journal_event_index WHERE event_id = ?1",
                    [causation_id],
                    |row| row.get::<_, i64>(0),
                )
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
        },
    )?;
    let result = json!({
        "producer_id":ingress.producer_id,
        "sequence":sequence.to_string(),
        "event_id":event_id,
    });
    tx.execute(
        "INSERT INTO journal_ingress_receipts(
           producer_id, origin, idempotency_key, fingerprint, event_id,
           journal_sequence, result_json
         ) VALUES(?1, ?2, ?3, ?4, ?5, ?6, ?7)",
        params![
            ingress.producer_id,
            origin,
            idempotency_key,
            fingerprint.as_slice(),
            event_id,
            i64::try_from(sequence)?,
            canonical_json(&result)?,
        ],
    )?;
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
    pub(crate) fn journal_hook_states(&self) -> anyhow::Result<Vec<JournalHookState>> {
        let mut statement = self.connection.prepare(
            "SELECT manifest_json, enabled, cursor_sequence
             FROM journal_hooks
             WHERE enabled = 1
             ORDER BY hook_id ASC, manifest_version ASC",
        )?;
        statement
            .query_map([], |row| {
                Ok((row.get::<_, String>(0)?, row.get::<_, i64>(1)?, row.get::<_, i64>(2)?))
            })?
            .map(|row| {
                let (manifest, enabled, cursor) = row?;
                Ok(JournalHookState {
                    manifest: serde_json::from_str(&manifest)?,
                    cursor_sequence: u64::try_from(cursor)
                        .context("hook cursor sequence is negative")?,
                    enabled: enabled != 0,
                })
            })
            .collect()
    }

    pub(crate) fn journal_events_caused_by_hooks(
        &self,
        hook_ids: &[String],
        event_ids: &[String],
    ) -> anyhow::Result<HashSet<(String, String)>> {
        if hook_ids.is_empty() || event_ids.is_empty() {
            return Ok(HashSet::new());
        }
        let hook_ids = canonical_json(&serde_json::to_value(hook_ids)?)?;
        let event_ids = canonical_json(&serde_json::to_value(event_ids)?)?;
        let mut statement = self.connection.prepare(
            "SELECT causal_hook_id, event_id
             FROM journal_event_index
             WHERE causal_hook_id IN (SELECT value FROM json_each(?1))
               AND event_id IN (SELECT value FROM json_each(?2))",
        )?;
        statement
            .query_map(params![hook_ids, event_ids], |row| {
                Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?))
            })?
            .collect::<Result<HashSet<_>, _>>()
            .map_err(Into::into)
    }

    pub(crate) fn put_journal_hook(
        &mut self,
        manifest: &JournalHookManifest,
        origin: &str,
        idempotency_key: &str,
    ) -> anyhow::Result<JournalAppendCommit> {
        validate_journal_hook_manifest(manifest)?;
        validate_identifier("journal hook origin", origin)?;
        validate_identifier("journal hook idempotency key", idempotency_key)?;
        let manifest_value = serde_json::to_value(manifest)?;
        let fingerprint = Sha256::digest(canonical_json(&manifest_value)?.as_bytes());
        let tx = self.connection.transaction()?;
        if let Some(commit) = operation_receipt(
            &tx,
            "session.journal.hook.put",
            origin,
            idempotency_key,
            fingerprint.as_slice(),
        )? {
            return Ok(commit);
        }
        let latest = tx
            .query_row(
                "SELECT manifest_version, manifest_json
                 FROM journal_hooks WHERE hook_id = ?1
                 ORDER BY manifest_version DESC LIMIT 1",
                [&manifest.hook_id],
                |row| Ok((row.get::<_, i64>(0)?, row.get::<_, String>(1)?)),
            )
            .optional()?;
        if let Some((version, stored)) = latest {
            let version = u32::try_from(version).context("hook manifest version is invalid")?;
            anyhow::ensure!(
                manifest.manifest_version > version
                    || (manifest.manifest_version == version
                        && canonical_json(&serde_json::from_str(&stored)?)?
                            == canonical_json(&manifest_value)?),
                "journal hook manifest versions must increase"
            );
        }
        let head = journal_head(&tx)?;
        let cursor = if manifest.delivery.start == "beginning" { 0 } else { head };
        let now = unix_epoch_ms()?;
        tx.execute(
            "INSERT INTO journal_hooks(
               hook_id, manifest_version, manifest_json, enabled, cursor_sequence, installed_at_ms
             ) VALUES(?1, ?2, ?3, 1, ?4, ?5)
             ON CONFLICT(hook_id, manifest_version) DO UPDATE SET
               manifest_json=excluded.manifest_json,
               enabled=1",
            params![
                manifest.hook_id,
                i64::from(manifest.manifest_version),
                canonical_json(&manifest_value)?,
                i64::try_from(cursor)?,
                i64::try_from(now)?,
            ],
        )?;
        tx.execute(
            "UPDATE journal_hooks SET enabled = 0
             WHERE hook_id = ?1 AND manifest_version <> ?2",
            params![manifest.hook_id, i64::from(manifest.manifest_version)],
        )?;
        let session_id = transaction_session_id(&tx)?;
        let subjects = vec![
            JournalSubject { kind: "session".into(), id: session_id },
            JournalSubject { kind: "hook".into(), id: manifest.hook_id.clone() },
        ];
        let producer = JournalProducer { kind: "journal_admin".into(), id: origin.into() };
        let event_id = random_event_id("hook_manifest");
        let sequence = append_journal_record(
            &tx,
            &JournalAppend {
                event_id: &event_id,
                schema_version: 1,
                kind: "hook.manifest.installed",
                class: JournalClass::State,
                replay: JournalReplayPolicy::Required,
                occurred_at_ms: now,
                producer: &producer,
                authority: None,
                causation_id: None,
                correlation_id: Some(idempotency_key),
                causation_depth: 0,
                subjects: &subjects,
                sensitivity: JournalSensitivity::Sensitive,
                payload: &manifest_value,
                content: None,
                resource_revision: None,
                previous_resource_revision: None,
            },
        )?;
        let result = json!({
            "hook_id":manifest.hook_id,
            "manifest_version":manifest.manifest_version,
            "sequence":sequence.to_string(),
            "event_id":event_id,
        });
        insert_operation_receipt(
            &tx,
            "session.journal.hook.put",
            origin,
            idempotency_key,
            fingerprint.as_slice(),
            sequence,
            &result,
        )?;
        tx.commit()?;
        Ok(JournalAppendCommit { sequence, event_id, replayed: false })
    }

    pub(crate) fn schedule_journal_hook_deliveries(
        &mut self,
        scans: &[JournalHookScan],
    ) -> anyhow::Result<Vec<bool>> {
        if scans.is_empty() {
            return Ok(Vec::new());
        }
        let tx = self.connection.transaction()?;
        let now = unix_epoch_ms()?;
        let applied = {
            let mut read_cursor = tx.prepare(
                "SELECT cursor_sequence FROM journal_hooks
                 WHERE hook_id = ?1 AND manifest_version = ?2 AND enabled = 1",
            )?;
            let mut insert_delivery = tx.prepare(
                "INSERT OR IGNORE INTO journal_hook_deliveries(
                   hook_id, manifest_version, event_id, event_sequence, attempt, state,
                   next_attempt_at_ms, scheduled_at_ms
                 ) VALUES(?1, ?2, ?3, ?4, 0, 'scheduled', ?5, ?5)",
            )?;
            let mut advance_cursor = tx.prepare(
                "UPDATE journal_hooks SET cursor_sequence = ?3
                 WHERE hook_id = ?1 AND manifest_version = ?2",
            )?;
            let mut applied = Vec::with_capacity(scans.len());
            for scan in scans {
                anyhow::ensure!(
                    scan.scanned_to > scan.expected_cursor,
                    "journal hook scan must advance its cursor"
                );
                let current = read_cursor
                    .query_row(params![scan.hook_id, i64::from(scan.manifest_version)], |row| {
                        row.get::<_, i64>(0)
                    })
                    .optional()?;
                if current.map(u64::try_from).transpose()? != Some(scan.expected_cursor) {
                    applied.push(false);
                    continue;
                }
                for (event_id, sequence) in &scan.matches {
                    insert_delivery.execute(params![
                        scan.hook_id,
                        i64::from(scan.manifest_version),
                        event_id,
                        i64::try_from(*sequence)?,
                        i64::try_from(now)?,
                    ])?;
                }
                advance_cursor.execute(params![
                    scan.hook_id,
                    i64::from(scan.manifest_version),
                    i64::try_from(scan.scanned_to)?,
                ])?;
                applied.push(true);
            }
            applied
        };
        tx.commit()?;
        Ok(applied)
    }

    pub(crate) fn pending_journal_hook_deliveries(
        &self,
        now_ms: u64,
        limit: usize,
    ) -> anyhow::Result<Vec<JournalHookDelivery>> {
        let mut statement = self.connection.prepare(
            "WITH pending AS (
               SELECT h.manifest_json, d.event_sequence, d.attempt,
                      CAST(json_extract(h.manifest_json, '$.exec.max_parallel') AS INTEGER)
                        AS max_parallel,
                      ROW_NUMBER() OVER (
                        PARTITION BY d.hook_id, d.manifest_version
                        ORDER BY d.event_sequence ASC
                      ) AS hook_slot
               FROM journal_hook_deliveries d
               JOIN journal_hooks h
                 ON h.hook_id = d.hook_id AND h.manifest_version = d.manifest_version
               WHERE h.enabled = 1
                 AND d.state IN ('scheduled','executing')
                 AND d.next_attempt_at_ms <= ?1
             )
             SELECT manifest_json, event_sequence, attempt
             FROM pending
             WHERE hook_slot <= max_parallel
             ORDER BY event_sequence ASC
             LIMIT ?2",
        )?;
        let rows = statement
            .query_map(params![i64::try_from(now_ms)?, i64::try_from(limit)?], |row| {
                Ok((row.get::<_, String>(0)?, row.get::<_, i64>(1)?, row.get::<_, i64>(2)?))
            })?
            .collect::<Result<Vec<_>, _>>()?;
        drop(statement);
        let sequences = rows
            .iter()
            .map(|(_, sequence, _)| u64::try_from(*sequence))
            .collect::<Result<Vec<_>, _>>()?;
        let events = query_session_journal_sequences(&self.connection, &sequences)?
            .into_iter()
            .map(|event| (event.sequence, event))
            .collect::<HashMap<_, _>>();
        rows.into_iter()
            .map(|(manifest, sequence, attempt)| {
                let sequence = u64::try_from(sequence)?;
                let event = events
                    .get(&sequence)
                    .cloned()
                    .context("hook delivery event is absent from the journal")?;
                Ok(JournalHookDelivery {
                    manifest: serde_json::from_str(&manifest)?,
                    event,
                    attempt: u16::try_from(attempt).context("hook attempt is invalid")?,
                })
            })
            .collect()
    }

    pub(crate) fn start_journal_hook_deliveries(
        &mut self,
        deliveries: &[JournalHookDelivery],
    ) -> anyhow::Result<Vec<JournalHookAttempt>> {
        if deliveries.is_empty() {
            return Ok(Vec::new());
        }
        let tx = self.connection.transaction()?;
        let now = unix_epoch_ms()?;
        let mut attempts = Vec::with_capacity(deliveries.len());
        for delivery in deliveries {
            let attempt = delivery.attempt.checked_add(1).context("hook attempt overflow")?;
            let changed = tx.execute(
                "UPDATE journal_hook_deliveries
                 SET state = 'executing', attempt = ?4, started_at_ms = ?5,
                     completed_at_ms = NULL, exit_code = NULL, error = NULL
                 WHERE hook_id = ?1 AND manifest_version = ?2 AND event_id = ?3
                   AND state IN ('scheduled','executing')",
                params![
                    delivery.manifest.hook_id,
                    i64::from(delivery.manifest.manifest_version),
                    delivery.event.event_id,
                    i64::from(attempt),
                    i64::try_from(now)?,
                ],
            )?;
            anyhow::ensure!(changed == 1, "hook delivery is no longer pending");
            let (_, causation_id) = append_hook_delivery_event(
                &tx,
                "hook.delivery.started",
                delivery,
                attempt,
                json!({"attempt":attempt}),
                now,
            )?;
            tx.execute(
                "UPDATE journal_hook_deliveries
                 SET started_event_id = ?4
                 WHERE hook_id = ?1 AND manifest_version = ?2 AND event_id = ?3",
                params![
                    delivery.manifest.hook_id,
                    i64::from(delivery.manifest.manifest_version),
                    delivery.event.event_id,
                    causation_id,
                ],
            )?;
            attempts.push(JournalHookAttempt { attempt, causation_id });
        }
        tx.commit()?;
        Ok(attempts)
    }

    pub(crate) fn finish_journal_hook_deliveries(
        &mut self,
        results: &[JournalHookDeliveryResult],
    ) -> anyhow::Result<()> {
        if results.is_empty() {
            return Ok(());
        }
        let tx = self.connection.transaction()?;
        let now = unix_epoch_ms()?;
        for result in results {
            let delivery = &result.delivery;
            let attempt = result.attempt;
            let exit_code = result.exit_code;
            let error = result.error.as_deref();
            let success = error.is_none() && exit_code == Some(0);
            if success {
                let changed = tx.execute(
                    "UPDATE journal_hook_deliveries
                     SET state = 'completed', completed_at_ms = ?5, exit_code = ?6, error = NULL
                     WHERE hook_id = ?1 AND manifest_version = ?2 AND event_id = ?3
                       AND state = 'executing' AND attempt = ?4",
                    params![
                        delivery.manifest.hook_id,
                        i64::from(delivery.manifest.manifest_version),
                        delivery.event.event_id,
                        i64::from(attempt),
                        i64::try_from(now)?,
                        exit_code,
                    ],
                )?;
                anyhow::ensure!(changed == 1, "hook delivery attempt is no longer executing");
                append_hook_delivery_event(
                    &tx,
                    "hook.delivery.completed",
                    delivery,
                    attempt,
                    json!({"attempt":attempt,"exit_code":exit_code}),
                    now,
                )?;
            } else {
                let exhausted = attempt >= delivery.manifest.delivery.retry.max_attempts;
                let next_attempt_at = now.saturating_add(
                    delivery.manifest.delivery.retry.backoff_ms.saturating_mul(u64::from(attempt)),
                );
                let changed = tx.execute(
                    "UPDATE journal_hook_deliveries
                     SET state = ?5, next_attempt_at_ms = ?6, completed_at_ms = ?7,
                         exit_code = ?8, error = ?9
                     WHERE hook_id = ?1 AND manifest_version = ?2 AND event_id = ?3
                       AND state = 'executing' AND attempt = ?4",
                    params![
                        delivery.manifest.hook_id,
                        i64::from(delivery.manifest.manifest_version),
                        delivery.event.event_id,
                        i64::from(attempt),
                        if exhausted { "abandoned" } else { "scheduled" },
                        i64::try_from(next_attempt_at)?,
                        i64::try_from(now)?,
                        exit_code,
                        error,
                    ],
                )?;
                anyhow::ensure!(changed == 1, "hook delivery attempt is no longer executing");
                append_hook_delivery_event(
                    &tx,
                    "hook.delivery.failed",
                    delivery,
                    attempt,
                    json!({"attempt":attempt,"exit_code":exit_code,"error":error,"retrying":!exhausted}),
                    now,
                )?;
                if exhausted {
                    append_hook_delivery_event(
                        &tx,
                        "hook.delivery.abandoned",
                        delivery,
                        attempt,
                        json!({"attempt":attempt,"exit_code":exit_code,"error":error}),
                        now,
                    )?;
                }
            }
        }
        tx.commit()?;
        Ok(())
    }
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
            &self.connection,
            "session.journal.checkpoint.create",
            origin,
            idempotency_key,
            fingerprint.as_slice(),
        )?
        else {
            return Ok(None);
        };
        let checkpoint_id = self.connection.query_row(
            "SELECT json_extract(result_json, '$.checkpoint_id')
             FROM journal_operation_receipts
             WHERE operation = 'session.journal.checkpoint.create'
               AND origin = ?1 AND idempotency_key = ?2",
            params![origin, idempotency_key],
            |row| row.get::<_, String>(0),
        )?;
        let checkpoint = query_journal_checkpoint(&self.connection, &checkpoint_id)?
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
        let tx = self.connection.transaction()?;
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

    /// Store the exit snapshot for one terminal generation, best-effort and
    /// idempotent. The exit latch is first-writer-wins, so at most one row
    /// exists per terminal; a replayed store is a no-op. Returns whether a
    /// snapshot row was written.
    pub(crate) fn put_terminal_exit_snapshot(
        &mut self,
        terminal_id: &str,
        generation: &str,
        blob: &JournalContentBlob,
    ) -> anyhow::Result<bool> {
        let tx = self.connection.transaction()?;
        let covered_through = tx
            .query_row(
                "SELECT next_offset FROM journal_terminal_streams
                 WHERE terminal_id = ?1 AND generation = ?2",
                params![terminal_id, generation],
                |row| row.get::<_, i64>(0),
            )
            .optional()?
            .map(u64::try_from)
            .transpose()
            .context("terminal journal offset is negative")?
            .unwrap_or(0);
        if covered_through == 0 {
            // The generation journaled no output; there is nothing for the
            // snapshot to cover and record reads stay exact without it.
            return Ok(false);
        }
        let now = unix_epoch_ms()?;
        insert_journal_content_blob(&tx, blob, now)?;
        let inserted = tx.execute(
            "INSERT OR IGNORE INTO terminal_exit_snapshots(
               terminal_id, generation, content_id, format, cols, rows,
               covered_through, created_at_ms
             ) VALUES(?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)",
            params![
                terminal_id,
                generation,
                blob.reference.content_id,
                blob.reference.format,
                i64::from(blob.reference.cols.max(1)),
                i64::from(blob.reference.rows.max(1)),
                i64::try_from(covered_through)?,
                i64::try_from(now)?,
            ],
        )?;
        tx.commit()?;
        Ok(inserted > 0)
    }

    /// Load and verify one terminal's exit snapshot, decoded to replay bytes.
    pub(crate) fn terminal_exit_snapshot(
        &self,
        terminal_id: &str,
    ) -> anyhow::Result<Option<TerminalExitSnapshot>> {
        type SnapshotRow = (String, i64, i64, i64, String, String, Vec<u8>, i64, Vec<u8>);
        let Some(row) = self
            .connection
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
        let mut statement = self.connection.prepare(
            "SELECT checkpoint_id, source_sequence, reducer_version, content_refs_json,
                    sha256, created_at_ms
             FROM journal_checkpoints
             ORDER BY source_sequence DESC, created_at_ms DESC, checkpoint_id DESC",
        )?;
        let rows = statement
            .query_map([], |row| {
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
            .map(|id| query_journal_checkpoint(&self.connection, id))
            .transpose()
            .map(Option::flatten)
    }
}

impl WorkspaceRegistry {
    pub(crate) fn journal_segments(&self) -> anyhow::Result<Vec<JournalSegment>> {
        let mut statement = self.connection.prepare(
            "SELECT segment_id, start_sequence, end_sequence, record_count, codec,
                    uncompressed_bytes, sha256, sealed_at_ms
             FROM journal_segments ORDER BY start_sequence ASC",
        )?;
        statement
            .query_map([], |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    row.get::<_, i64>(1)?,
                    row.get::<_, i64>(2)?,
                    row.get::<_, i64>(3)?,
                    row.get::<_, String>(4)?,
                    row.get::<_, i64>(5)?,
                    row.get::<_, Vec<u8>>(6)?,
                    row.get::<_, i64>(7)?,
                ))
            })?
            .map(|row| {
                let (id, start, end, count, codec, bytes, digest, sealed_at) = row?;
                Ok(JournalSegment {
                    segment_id: id,
                    start_sequence: u64::try_from(start)?,
                    end_sequence: u64::try_from(end)?,
                    record_count: u64::try_from(count)?,
                    codec,
                    uncompressed_bytes: u64::try_from(bytes)?,
                    sha256: encode_hex(&digest),
                    sealed_at_ms: u64::try_from(sealed_at)?,
                })
            })
            .collect()
    }

    pub(crate) fn begin_journal_segment_seal(
        &mut self,
        requested_through: u64,
        origin: &str,
        idempotency_key: &str,
    ) -> anyhow::Result<JournalSegmentSealStart> {
        anyhow::ensure!(requested_through > 0, "segment through sequence must be positive");
        validate_identifier("journal segment origin", origin)?;
        validate_identifier("journal segment idempotency key", idempotency_key)?;
        let fingerprint: [u8; 32] = Sha256::digest(
            canonical_json(&json!({"through_sequence":requested_through.to_string()}))?.as_bytes(),
        )
        .into();
        let tx = self.connection.transaction()?;
        if let Some(journal) = operation_receipt(
            &tx,
            "session.journal.segment.seal",
            origin,
            idempotency_key,
            &fingerprint,
        )? {
            return Ok(JournalSegmentSealStart::Replay(journal_segment_receipt(
                &tx,
                origin,
                idempotency_key,
                journal,
            )?));
        }
        let head = journal_head(&tx)?;
        anyhow::ensure!(
            requested_through <= head,
            "segment through sequence is ahead of the journal"
        );
        let through_sequence = tx
            .query_row(
                "SELECT MAX(source_sequence) FROM journal_checkpoints
                 WHERE source_sequence <= ?1",
                [i64::try_from(requested_through)?],
                |row| row.get::<_, Option<i64>>(0),
            )?
            .map(u64::try_from)
            .transpose()?
            .context("no checkpoint exists at or before the requested segment boundary")?;
        let archived_end = tx.query_row(
            "SELECT COALESCE(MAX(end_sequence), 0) FROM journal_segments",
            [],
            |row| row.get::<_, i64>(0),
        )?;
        let archived_end = u64::try_from(archived_end)?;
        anyhow::ensure!(
            through_sequence > archived_end,
            "requested journal range is already sealed"
        );
        tx.commit()?;
        Ok(JournalSegmentSealStart::Prepare(JournalSegmentSealPlan {
            requested_through,
            through_sequence,
            archived_end,
            fingerprint,
        }))
    }

    pub(crate) fn commit_journal_segment_seal(
        &mut self,
        prepared: PreparedJournalSegmentSeal,
        origin: &str,
        idempotency_key: &str,
    ) -> anyhow::Result<Option<JournalSegmentSealCommit>> {
        let PreparedJournalSegmentSeal { plan, segments: prepared_segments } = prepared;
        let tx = self.connection.transaction()?;
        if let Some(journal) = operation_receipt(
            &tx,
            "session.journal.segment.seal",
            origin,
            idempotency_key,
            &plan.fingerprint,
        )? {
            return Ok(Some(journal_segment_receipt(&tx, origin, idempotency_key, journal)?));
        }
        let through_sequence = tx
            .query_row(
                "SELECT MAX(source_sequence) FROM journal_checkpoints
                 WHERE source_sequence <= ?1",
                [i64::try_from(plan.requested_through)?],
                |row| row.get::<_, Option<i64>>(0),
            )?
            .map(u64::try_from)
            .transpose()?;
        let archived_end = u64::try_from(tx.query_row(
            "SELECT COALESCE(MAX(end_sequence), 0) FROM journal_segments",
            [],
            |row| row.get::<_, i64>(0),
        )?)?;
        if through_sequence != Some(plan.through_sequence) || archived_end != plan.archived_end {
            return Ok(None);
        }
        validate_prepared_journal_segments(&plan, &prepared_segments)?;
        let segments =
            prepared_segments.iter().map(|segment| segment.metadata.clone()).collect::<Vec<_>>();
        for segment in prepared_segments {
            tx.execute(
                "INSERT INTO journal_segments(
                   segment_id, start_sequence, end_sequence, record_count, codec, content,
                   uncompressed_bytes, sha256, sealed_at_ms
                 ) VALUES(?1, ?2, ?3, ?4, 'gzip-json-v1', ?5, ?6, ?7, ?8)",
                params![
                    segment.metadata.segment_id,
                    i64::try_from(segment.metadata.start_sequence)?,
                    i64::try_from(segment.metadata.end_sequence)?,
                    i64::try_from(segment.metadata.record_count)?,
                    segment.compressed,
                    i64::try_from(segment.metadata.uncompressed_bytes)?,
                    segment.digest,
                    i64::try_from(segment.metadata.sealed_at_ms)?,
                ],
            )?;
        }
        tx.execute_batch("DROP TRIGGER IF EXISTS session_journal_reject_delete;")?;
        let deleted = tx.execute(
            "DELETE FROM session_journal WHERE sequence > ?1 AND sequence <= ?2",
            params![i64::try_from(plan.archived_end)?, i64::try_from(plan.through_sequence)?],
        )?;
        anyhow::ensure!(
            deleted == usize::try_from(plan.through_sequence - plan.archived_end)?,
            "journal segment source range changed before commit"
        );
        tx.execute_batch(
            "CREATE TRIGGER IF NOT EXISTS session_journal_reject_delete
             BEFORE DELETE ON session_journal
             BEGIN SELECT RAISE(ABORT, 'session journal is append-only'); END;",
        )?;
        let now = unix_epoch_ms()?;
        let session_id = transaction_session_id(&tx)?;
        let subjects = vec![JournalSubject { kind: "session".into(), id: session_id }];
        let producer = JournalProducer { kind: "retention".into(), id: origin.into() };
        let event_id = random_event_id("segment");
        let payload = json!({
            "through_sequence":plan.through_sequence.to_string(),
            "segments":segments,
        });
        let sequence = append_journal_record(
            &tx,
            &JournalAppend {
                event_id: &event_id,
                schema_version: 1,
                kind: "journal.segment.sealed",
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
            },
        )?;
        let result = json!({
            "through_sequence":plan.through_sequence.to_string(),
            "segments":segments,
            "sequence":sequence.to_string(),
            "event_id":event_id,
        });
        insert_operation_receipt(
            &tx,
            "session.journal.segment.seal",
            origin,
            idempotency_key,
            &plan.fingerprint,
            sequence,
            &result,
        )?;
        tx.commit()?;
        Ok(Some(JournalSegmentSealCommit {
            through_sequence: plan.through_sequence,
            segments,
            journal: JournalAppendCommit { sequence, event_id, replayed: false },
        }))
    }
}

impl JournalSegmentSealPlan {
    pub(crate) fn prepare(
        self,
        reader: &SessionJournalReader,
    ) -> anyhow::Result<PreparedJournalSegmentSeal> {
        let sealed_at_ms = unix_epoch_ms()?;
        let mut cursor = self.archived_end;
        let mut segments = Vec::new();
        while cursor < self.through_sequence {
            let mut uncompressed =
                Vec::with_capacity(MAX_JOURNAL_SEGMENT_UNCOMPRESSED_BYTES.min(1024 * 1024));
            uncompressed.push(b'[');
            let mut start_sequence = None;
            let mut record_count = 0_u64;
            'segment: while cursor < self.through_sequence
                && record_count < u64::try_from(JOURNAL_SEGMENT_RECORD_LIMIT)?
            {
                let page = reader.after(cursor, 1024)?;
                let mut accepted = 0_usize;
                for record in page
                    .records
                    .into_iter()
                    .take_while(|record| record.sequence <= self.through_sequence)
                {
                    anyhow::ensure!(
                        record.sequence == cursor.saturating_add(1),
                        "journal segment range contains a gap before sequence {}",
                        record.sequence
                    );
                    let sequence = record.sequence;
                    let record = session_journal::journal_record_for_archive(&record);
                    let record_bytes = serde_json::to_vec(&record)?;
                    anyhow::ensure!(
                        record_bytes.len().saturating_add(2)
                            <= MAX_JOURNAL_SEGMENT_UNCOMPRESSED_BYTES,
                        "journal record {sequence} is too large to seal"
                    );
                    let separator = usize::from(record_count != 0);
                    if uncompressed
                        .len()
                        .saturating_add(separator)
                        .saturating_add(record_bytes.len())
                        .saturating_add(1)
                        > MAX_JOURNAL_SEGMENT_UNCOMPRESSED_BYTES
                    {
                        break 'segment;
                    }
                    if separator != 0 {
                        uncompressed.push(b',');
                    }
                    uncompressed.extend_from_slice(&record_bytes);
                    start_sequence.get_or_insert(sequence);
                    cursor = sequence;
                    record_count += 1;
                    accepted += 1;
                    if record_count == u64::try_from(JOURNAL_SEGMENT_RECORD_LIMIT)? {
                        break 'segment;
                    }
                }
                anyhow::ensure!(
                    accepted != 0,
                    "journal segment range contains a gap after sequence {cursor}"
                );
            }
            uncompressed.push(b']');
            let start_sequence =
                start_sequence.context("journal segment range contains no records")?;
            let digest: [u8; 32] = Sha256::digest(&uncompressed).into();
            let digest_hex = encode_hex(&digest);
            let mut encoder =
                flate2::GzBuilder::new().mtime(0).write(Vec::new(), flate2::Compression::fast());
            encoder.write_all(&uncompressed)?;
            let compressed = encoder.finish()?;
            let segment_id = format!("segment_{start_sequence}_{cursor}_{digest_hex}");
            segments.push(PreparedJournalSegment {
                metadata: JournalSegment {
                    segment_id,
                    start_sequence,
                    end_sequence: cursor,
                    record_count,
                    codec: "gzip-json-v1".into(),
                    uncompressed_bytes: u64::try_from(uncompressed.len())?,
                    sha256: digest_hex,
                    sealed_at_ms,
                },
                compressed,
                digest,
            });
        }
        validate_prepared_journal_segments(&self, &segments)?;
        Ok(PreparedJournalSegmentSeal { plan: self, segments })
    }
}

fn validate_prepared_journal_segments(
    plan: &JournalSegmentSealPlan,
    segments: &[PreparedJournalSegment],
) -> anyhow::Result<()> {
    anyhow::ensure!(!segments.is_empty(), "journal segment preparation produced no segments");
    let mut expected = plan.archived_end.saturating_add(1);
    for segment in segments {
        let metadata = &segment.metadata;
        anyhow::ensure!(
            metadata.start_sequence == expected && metadata.end_sequence >= expected,
            "prepared journal segments are not contiguous"
        );
        anyhow::ensure!(
            metadata.record_count
                == metadata.end_sequence.saturating_sub(metadata.start_sequence).saturating_add(1),
            "prepared journal segment record count is invalid"
        );
        anyhow::ensure!(
            metadata.codec == "gzip-json-v1"
                && metadata.sha256 == encode_hex(&segment.digest)
                && metadata.uncompressed_bytes
                    <= u64::try_from(MAX_JOURNAL_SEGMENT_UNCOMPRESSED_BYTES)?,
            "prepared journal segment metadata is invalid"
        );
        anyhow::ensure!(!segment.compressed.is_empty(), "prepared journal segment is empty");
        expected = metadata.end_sequence.saturating_add(1);
    }
    anyhow::ensure!(
        expected == plan.through_sequence.saturating_add(1),
        "prepared journal segment range ended early"
    );
    Ok(())
}

fn journal_segment_receipt(
    transaction: &Transaction<'_>,
    origin: &str,
    idempotency_key: &str,
    journal: JournalAppendCommit,
) -> anyhow::Result<JournalSegmentSealCommit> {
    let result = transaction.query_row(
        "SELECT result_json FROM journal_operation_receipts
         WHERE operation = 'session.journal.segment.seal'
           AND origin = ?1 AND idempotency_key = ?2",
        params![origin, idempotency_key],
        |row| row.get::<_, String>(0),
    )?;
    let result: Value = serde_json::from_str(&result)?;
    let through_sequence = result["through_sequence"]
        .as_str()
        .context("segment receipt omitted through_sequence")?
        .parse()?;
    let segments = serde_json::from_value(result["segments"].clone())?;
    Ok(JournalSegmentSealCommit { through_sequence, segments, journal })
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
        .query_row("SELECT value FROM meta WHERE key = 'session_public_id'", [], |row| row.get(0))
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

fn append_hook_delivery_event(
    transaction: &Transaction<'_>,
    kind: &str,
    delivery: &JournalHookDelivery,
    attempt: u16,
    payload: Value,
    occurred_at_ms: u64,
) -> anyhow::Result<(u64, String)> {
    let session_id = transaction_session_id(transaction)?;
    let mut subjects = BTreeSet::from([
        JournalSubject { kind: "session".into(), id: session_id },
        JournalSubject { kind: "hook".into(), id: delivery.manifest.hook_id.clone() },
    ]);
    subjects.extend(delivery.event.subjects.iter().cloned());
    let subjects = subjects.into_iter().collect::<Vec<_>>();
    let producer =
        JournalProducer { kind: "hook_dispatcher".into(), id: delivery.manifest.hook_id.clone() };
    let event_id = random_event_id("hook_delivery");
    let sequence = append_journal_record(
        transaction,
        &JournalAppend {
            event_id: &event_id,
            schema_version: 1,
            kind,
            class: JournalClass::Effect,
            replay: JournalReplayPolicy::Never,
            occurred_at_ms,
            producer: &producer,
            authority: None,
            causation_id: Some(&delivery.event.event_id),
            correlation_id: Some(&format!(
                "{}:{}:{}",
                delivery.manifest.hook_id,
                delivery.manifest.manifest_version,
                delivery.event.event_id
            )),
            causation_depth: delivery.event.causation_depth.saturating_add(1),
            subjects: &subjects,
            sensitivity: JournalSensitivity::Metadata,
            payload: &json!({
                "hook_id":delivery.manifest.hook_id,
                "manifest_version":delivery.manifest.manifest_version,
                "source_event_id":delivery.event.event_id,
                "source_sequence":delivery.event.sequence.to_string(),
                "attempt":attempt,
                "outcome":payload,
            }),
            content: None,
            resource_revision: None,
            previous_resource_revision: None,
        },
    )?;
    Ok((sequence, event_id))
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
    let decoder = flate2::read::GzDecoder::new(blob.compressed.as_slice());
    let mut uncompressed = Vec::new();
    decoder
        .take(u64::try_from(expected_bytes)?.saturating_add(1))
        .read_to_end(&mut uncompressed)?;
    anyhow::ensure!(
        uncompressed.len() == expected_bytes,
        "checkpoint content length does not match its reference"
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

fn ingress_receipt(
    transaction: &Transaction<'_>,
    producer_id: &str,
    origin: &str,
    idempotency_key: &str,
    fingerprint: &[u8],
) -> anyhow::Result<Option<JournalAppendCommit>> {
    let stored = transaction
        .query_row(
            "SELECT fingerprint, event_id, journal_sequence
             FROM journal_ingress_receipts
             WHERE producer_id = ?1 AND origin = ?2 AND idempotency_key = ?3",
            params![producer_id, origin, idempotency_key],
            |row| Ok((row.get::<_, Vec<u8>>(0)?, row.get::<_, String>(1)?, row.get::<_, i64>(2)?)),
        )
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
            && value
                .bytes()
                .all(|byte| { byte.is_ascii_lowercase() || byte.is_ascii_digit() || byte == b'_' }),
        "{label} must contain 1 to 64 lowercase ASCII letters, digits, or underscores"
    );
    Ok(())
}

fn validate_dotted_kind(value: &str) -> anyhow::Result<()> {
    anyhow::ensure!(
        !value.is_empty()
            && value.len() <= 128
            && value.split('.').all(|component| {
                !component.is_empty()
                    && component.bytes().all(|byte| {
                        byte.is_ascii_lowercase() || byte.is_ascii_digit() || byte == b'_'
                    })
            }),
        "journal event kind must be a dotted lowercase ASCII name"
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

fn random_event_id(category: &str) -> String {
    format!("event_{category}_{}", new_uuid_v4().replace('-', ""))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn hook(manifest_version: u32) -> JournalHookManifest {
        JournalHookManifest {
            hook_id: "active_hook".into(),
            manifest_version,
            filter: JournalHookFilter::default(),
            exec: JournalHookExec {
                argv: vec!["/usr/bin/true".into()],
                timeout_ms: 1_000,
                max_parallel: 1,
            },
            delivery: JournalHookDeliveryPolicy {
                start: "tail".into(),
                retry: JournalHookRetry { max_attempts: 1, backoff_ms: 0 },
            },
            permissions: vec!["journal.read".into()],
        }
    }

    #[test]
    fn journal_hook_states_exclude_disabled_manifest_history() {
        let mut registry = WorkspaceRegistry::in_memory("active-hooks").unwrap();
        registry.put_journal_hook(&hook(1), "client_test", "hook_v1").unwrap();
        registry.put_journal_hook(&hook(2), "client_test", "hook_v2").unwrap();

        let states = registry.journal_hook_states().unwrap();
        assert_eq!(states.len(), 1);
        assert_eq!(states[0].manifest.manifest_version, 2);
        assert!(states[0].enabled);
    }

    #[test]
    fn checkpoint_digest_is_verified_when_read() {
        let mut registry = WorkspaceRegistry::in_memory("checkpoint-integrity").unwrap();
        let commit = registry
            .create_journal_checkpoint(
                0,
                1,
                &json!({"session_snapshot":{"cursor":{"revision":"0"}}}),
                &[],
                "client_test",
                "checkpoint_1",
            )
            .unwrap();
        registry
            .connection
            .execute_batch("DROP TRIGGER journal_checkpoints_reject_update;")
            .unwrap();
        registry
            .connection
            .execute(
                "UPDATE journal_checkpoints SET state_json = '{\"tampered\":true}'
                 WHERE checkpoint_id = ?1",
                [&commit.checkpoint.checkpoint_id],
            )
            .unwrap();

        let error = registry.journal_checkpoint(&commit.checkpoint.checkpoint_id).unwrap_err();
        assert!(error.to_string().contains("digest"), "{error:#}");
    }
}
