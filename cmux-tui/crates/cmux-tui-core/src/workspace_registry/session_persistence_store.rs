use super::*;

use serde_json::{Value, json};
use std::collections::BTreeMap;

const SESSION_LIFECYCLE_FORMAT: &str = "cmux.session-lifecycle-state.v1";
const RUNTIME_ATTACHMENT_FORMAT: &str = "cmux.runtime-attachment-state.v1";
const HIBERNATION_POLICY_FORMAT: &str = "cmux.hibernation-policy-state.v1";

#[derive(Debug, Clone, PartialEq, Eq)]
struct SessionLifecycleRow {
    session_id: String,
    state: String,
    reason: Option<String>,
    updated_at_ms: u64,
    committed_sequence: u64,
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct RuntimeAttachmentRow {
    session_id: String,
    terminal_id: TerminalPublicId,
    runtime_id: String,
    state: String,
    host_epoch: String,
    lease_generation: String,
    updated_at_ms: u64,
    committed_sequence: u64,
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct HibernationPolicyRow {
    session_id: String,
    enabled: bool,
    updated_by: Option<String>,
    updated_at_ms: u64,
    committed_sequence: u64,
}

struct DerivedSessionPersistence {
    lifecycle: BTreeMap<String, SessionLifecycleRow>,
    runtime_attachments: BTreeMap<String, RuntimeAttachmentRow>,
    hibernation_policy: BTreeMap<String, HibernationPolicyRow>,
}

pub(super) fn create_session_persistence_schema(
    transaction: &Transaction<'_>,
) -> anyhow::Result<()> {
    transaction.execute_batch(
        "CREATE TABLE IF NOT EXISTS journal_session_lifecycle_state (
           session_id TEXT PRIMARY KEY NOT NULL,
           state TEXT NOT NULL CHECK(state IN (
             'active', 'restoring', 'interrupted', 'closed'
           )),
           reason TEXT,
           updated_at_ms INTEGER NOT NULL CHECK(updated_at_ms >= 0),
           result_json TEXT NOT NULL,
           committed_sequence INTEGER NOT NULL CHECK(committed_sequence >= 0),
           CHECK (
             json_valid(result_json)
             AND COALESCE(
               json_extract(result_json, '$.format') = 'cmux.session-lifecycle-state.v1',
               0
             )
             AND COALESCE(json_extract(result_json, '$.session_id') = session_id, 0)
             AND COALESCE(json_extract(result_json, '$.state') = state, 0)
           )
         );
         CREATE TABLE IF NOT EXISTS journal_runtime_attachment_states (
           terminal_id TEXT PRIMARY KEY NOT NULL,
           session_id TEXT NOT NULL,
           runtime_id TEXT NOT NULL,
           state TEXT NOT NULL CHECK(state IN (
             'attached', 'detached', 'lost', 'interrupted'
           )),
           host_epoch TEXT NOT NULL,
           lease_generation TEXT NOT NULL,
           updated_at_ms INTEGER NOT NULL CHECK(updated_at_ms >= 0),
           result_json TEXT NOT NULL,
           committed_sequence INTEGER NOT NULL CHECK(committed_sequence >= 0),
           CHECK (
             json_valid(result_json)
             AND COALESCE(
               json_extract(result_json, '$.format') = 'cmux.runtime-attachment-state.v1',
               0
             )
             AND COALESCE(json_extract(result_json, '$.session_id') = session_id, 0)
             AND COALESCE(json_extract(result_json, '$.terminal_id') = terminal_id, 0)
             AND COALESCE(json_extract(result_json, '$.runtime_id') = runtime_id, 0)
             AND COALESCE(json_extract(result_json, '$.state') = state, 0)
           )
         );
         CREATE INDEX IF NOT EXISTS journal_runtime_attachment_states_by_session
           ON journal_runtime_attachment_states(session_id, committed_sequence DESC);
         CREATE TABLE IF NOT EXISTS journal_session_hibernation_policy (
           session_id TEXT PRIMARY KEY NOT NULL,
           enabled INTEGER NOT NULL CHECK(enabled IN (0, 1)),
           updated_by TEXT,
           updated_at_ms INTEGER NOT NULL CHECK(updated_at_ms >= 0),
           result_json TEXT NOT NULL,
           committed_sequence INTEGER NOT NULL CHECK(committed_sequence >= 0),
           CHECK (
             json_valid(result_json)
             AND COALESCE(
               json_extract(result_json, '$.format') = 'cmux.hibernation-policy-state.v1',
               0
             )
             AND COALESCE(json_extract(result_json, '$.session_id') = session_id, 0)
             AND COALESCE(json_extract(result_json, '$.enabled') = (enabled != 0), 0)
           )
         );",
    )?;
    Ok(())
}

pub(super) fn apply_session_persistence_journal_record(
    transaction: &Transaction<'_>,
    sequence: u64,
    kind: &str,
    occurred_at_ms: u64,
    producer: &JournalProducer,
    authority: Option<&JournalAuthority>,
    subjects: &[JournalSubject],
    payload: &Value,
) -> anyhow::Result<()> {
    if let Some(row) = session_lifecycle_from_record(
        sequence,
        kind,
        occurred_at_ms,
        producer,
        authority,
        subjects,
        payload,
    )? {
        upsert_session_lifecycle(transaction, &row)?;
    }
    if let Some(row) = runtime_attachment_from_record(
        sequence,
        kind,
        occurred_at_ms,
        producer,
        authority,
        subjects,
        payload,
    )? {
        upsert_runtime_attachment(transaction, &row)?;
    }
    if let Some(row) = hibernation_policy_from_record(
        sequence,
        kind,
        occurred_at_ms,
        producer,
        authority,
        subjects,
        payload,
    )? {
        upsert_hibernation_policy(transaction, &row)?;
    }
    Ok(())
}

pub(super) fn rebuild_session_persistence_from_journal(
    connection: &Connection,
) -> anyhow::Result<()> {
    let session_id = required_meta(connection, "session_public_id")?;
    let derived = derive_session_persistence_from_journal(connection)?;
    let tx = connection.unchecked_transaction()?;
    tx.execute("DELETE FROM journal_session_lifecycle_state", [])?;
    tx.execute("DELETE FROM journal_runtime_attachment_states", [])?;
    tx.execute("DELETE FROM journal_session_hibernation_policy", [])?;
    for row in derived.lifecycle.into_values() {
        upsert_session_lifecycle(&tx, &row)?;
    }
    for row in derived.runtime_attachments.into_values() {
        upsert_runtime_attachment(&tx, &row)?;
    }
    let has_current_hibernation_policy = derived.hibernation_policy.contains_key(&session_id);
    for row in derived.hibernation_policy.into_values() {
        upsert_hibernation_policy(&tx, &row)?;
    }
    if !has_current_hibernation_policy {
        upsert_hibernation_policy(&tx, &default_hibernation_policy(session_id))?;
    }
    tx.commit()?;
    Ok(())
}

fn derive_session_persistence_from_journal(
    connection: &Connection,
) -> anyhow::Result<DerivedSessionPersistence> {
    let mut lifecycle = BTreeMap::new();
    let mut runtime_attachments = BTreeMap::new();
    let mut hibernation_policy = BTreeMap::new();
    let mut sequence = 0;
    loop {
        let page = session_journal::query_session_journal_after(connection, sequence, 1024)?;
        let empty = page.records.is_empty();
        for record in page.records {
            sequence = record.sequence;
            let authority = record.authority.as_ref();
            if let Some(row) = session_lifecycle_from_record(
                record.sequence,
                &record.kind,
                record.occurred_at_ms,
                &record.producer,
                authority,
                &record.subjects,
                &record.payload,
            )? {
                lifecycle.insert(row.session_id.clone(), row);
            }
            if let Some(row) = runtime_attachment_from_record(
                record.sequence,
                &record.kind,
                record.occurred_at_ms,
                &record.producer,
                authority,
                &record.subjects,
                &record.payload,
            )? {
                runtime_attachments.insert(row.terminal_id.to_string(), row);
            }
            if let Some(row) = hibernation_policy_from_record(
                record.sequence,
                &record.kind,
                record.occurred_at_ms,
                &record.producer,
                authority,
                &record.subjects,
                &record.payload,
            )? {
                hibernation_policy.insert(row.session_id.clone(), row);
            }
        }
        if empty || sequence >= page.head_sequence {
            break;
        }
    }
    Ok(DerivedSessionPersistence { lifecycle, runtime_attachments, hibernation_policy })
}

fn session_lifecycle_from_record(
    sequence: u64,
    kind: &str,
    occurred_at_ms: u64,
    producer: &JournalProducer,
    authority: Option<&JournalAuthority>,
    subjects: &[JournalSubject],
    payload: &Value,
) -> anyhow::Result<Option<SessionLifecycleRow>> {
    if kind != "session.lifecycle.updated"
        || !is_trusted_session_persistence_record(producer, authority)
        || payload.get("format").and_then(Value::as_str) != Some("cmux.session-lifecycle.v1")
    {
        return Ok(None);
    }
    let Some(session_id) = subject_id(subjects, "session") else {
        return Ok(None);
    };
    let Some(state) = payload
        .get("state")
        .and_then(Value::as_str)
        .filter(|state| matches!(*state, "active" | "restoring" | "interrupted" | "closed"))
    else {
        return Ok(None);
    };
    let reason = payload
        .get("reason")
        .and_then(Value::as_str)
        .filter(|value| !value.is_empty())
        .map(str::to_string);
    Ok(Some(SessionLifecycleRow {
        session_id: session_id.to_string(),
        state: state.to_string(),
        reason,
        updated_at_ms: occurred_at_ms,
        committed_sequence: sequence,
    }))
}

fn runtime_attachment_from_record(
    sequence: u64,
    kind: &str,
    occurred_at_ms: u64,
    producer: &JournalProducer,
    authority: Option<&JournalAuthority>,
    subjects: &[JournalSubject],
    payload: &Value,
) -> anyhow::Result<Option<RuntimeAttachmentRow>> {
    if kind != "runtime.attachment.updated"
        || !is_trusted_session_persistence_record(producer, authority)
        || payload.get("format").and_then(Value::as_str) != Some("cmux.runtime-attachment.v1")
    {
        return Ok(None);
    }
    let Some(session_id) = subject_id(subjects, "session") else {
        return Ok(None);
    };
    let Some(terminal_subject) = subject_id(subjects, "terminal") else {
        return Ok(None);
    };
    let terminal_id = TerminalPublicId::parse(terminal_subject)?;
    if payload.get("terminal_id").and_then(Value::as_str) != Some(terminal_id.as_str()) {
        return Ok(None);
    }
    let Some(runtime_id) = non_empty_payload_text(payload, "runtime_id") else {
        return Ok(None);
    };
    let Some(state) = payload
        .get("state")
        .and_then(Value::as_str)
        .filter(|state| matches!(*state, "attached" | "detached" | "lost" | "interrupted"))
    else {
        return Ok(None);
    };
    let Some(host_epoch) = non_empty_payload_text(payload, "host_epoch") else {
        return Ok(None);
    };
    let Some(lease_generation) = non_empty_payload_text(payload, "lease_generation") else {
        return Ok(None);
    };
    Ok(Some(RuntimeAttachmentRow {
        session_id: session_id.to_string(),
        terminal_id,
        runtime_id: runtime_id.to_string(),
        state: state.to_string(),
        host_epoch: host_epoch.to_string(),
        lease_generation: lease_generation.to_string(),
        updated_at_ms: occurred_at_ms,
        committed_sequence: sequence,
    }))
}

fn hibernation_policy_from_record(
    sequence: u64,
    kind: &str,
    occurred_at_ms: u64,
    producer: &JournalProducer,
    authority: Option<&JournalAuthority>,
    subjects: &[JournalSubject],
    payload: &Value,
) -> anyhow::Result<Option<HibernationPolicyRow>> {
    if kind != "session.hibernation_policy.updated"
        || !is_trusted_session_persistence_record(producer, authority)
        || payload.get("format").and_then(Value::as_str) != Some("cmux.hibernation-policy.v1")
    {
        return Ok(None);
    }
    let Some(session_id) = subject_id(subjects, "session") else {
        return Ok(None);
    };
    let Some(enabled) = payload.get("enabled").and_then(Value::as_bool) else {
        return Ok(None);
    };
    let updated_by = payload
        .get("updated_by")
        .and_then(Value::as_str)
        .filter(|value| !value.is_empty())
        .map(str::to_string);
    Ok(Some(HibernationPolicyRow {
        session_id: session_id.to_string(),
        enabled,
        updated_by,
        updated_at_ms: occurred_at_ms,
        committed_sequence: sequence,
    }))
}

fn default_hibernation_policy(session_id: String) -> HibernationPolicyRow {
    HibernationPolicyRow {
        session_id,
        enabled: false,
        updated_by: Some("default".into()),
        updated_at_ms: 0,
        committed_sequence: 0,
    }
}

fn is_trusted_session_persistence_record(
    producer: &JournalProducer,
    authority: Option<&JournalAuthority>,
) -> bool {
    producer.kind == "trusted_local_authority"
        && producer.id == "cmux_tui"
        && authority.is_some_and(|authority| authority.role == "session.persistence")
}

fn subject_id<'a>(subjects: &'a [JournalSubject], kind: &str) -> Option<&'a str> {
    subjects.iter().find(|subject| subject.kind == kind).map(|subject| subject.id.as_str())
}

fn non_empty_payload_text<'a>(payload: &'a Value, field: &str) -> Option<&'a str> {
    payload.get(field).and_then(Value::as_str).filter(|value| !value.is_empty())
}

fn upsert_session_lifecycle(
    transaction: &Transaction<'_>,
    row: &SessionLifecycleRow,
) -> anyhow::Result<()> {
    let value = json!({
        "format":SESSION_LIFECYCLE_FORMAT,
        "session_id":row.session_id,
        "state":row.state,
        "reason":row.reason,
        "updated_at_ms":row.updated_at_ms.to_string(),
    });
    transaction.execute(
        "INSERT INTO journal_session_lifecycle_state(
           session_id, state, reason, updated_at_ms, result_json, committed_sequence
         ) VALUES(?1, ?2, ?3, ?4, ?5, ?6)
         ON CONFLICT(session_id) DO UPDATE SET
           state = excluded.state,
           reason = excluded.reason,
           updated_at_ms = excluded.updated_at_ms,
           result_json = excluded.result_json,
           committed_sequence = excluded.committed_sequence",
        params![
            row.session_id.as_str(),
            row.state.as_str(),
            row.reason.as_deref(),
            i64::try_from(row.updated_at_ms)
                .context("session lifecycle timestamp exceeds SQLite range")?,
            canonical_json(&value)?,
            i64::try_from(row.committed_sequence)
                .context("session lifecycle sequence exceeds SQLite range")?,
        ],
    )?;
    Ok(())
}

fn upsert_runtime_attachment(
    transaction: &Transaction<'_>,
    row: &RuntimeAttachmentRow,
) -> anyhow::Result<()> {
    let value = json!({
        "format":RUNTIME_ATTACHMENT_FORMAT,
        "session_id":row.session_id,
        "terminal_id":row.terminal_id,
        "runtime_id":row.runtime_id,
        "state":row.state,
        "host_epoch":row.host_epoch,
        "lease_generation":row.lease_generation,
        "updated_at_ms":row.updated_at_ms.to_string(),
    });
    transaction.execute(
        "INSERT INTO journal_runtime_attachment_states(
           terminal_id, session_id, runtime_id, state, host_epoch, lease_generation,
           updated_at_ms, result_json, committed_sequence
         ) VALUES(?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)
         ON CONFLICT(terminal_id) DO UPDATE SET
           session_id = excluded.session_id,
           runtime_id = excluded.runtime_id,
           state = excluded.state,
           host_epoch = excluded.host_epoch,
           lease_generation = excluded.lease_generation,
           updated_at_ms = excluded.updated_at_ms,
           result_json = excluded.result_json,
           committed_sequence = excluded.committed_sequence",
        params![
            row.terminal_id.as_str(),
            row.session_id.as_str(),
            row.runtime_id.as_str(),
            row.state.as_str(),
            row.host_epoch.as_str(),
            row.lease_generation.as_str(),
            i64::try_from(row.updated_at_ms)
                .context("runtime attachment timestamp exceeds SQLite range")?,
            canonical_json(&value)?,
            i64::try_from(row.committed_sequence)
                .context("runtime attachment sequence exceeds SQLite range")?,
        ],
    )?;
    Ok(())
}

fn upsert_hibernation_policy(
    transaction: &Transaction<'_>,
    row: &HibernationPolicyRow,
) -> anyhow::Result<()> {
    let value = json!({
        "format":HIBERNATION_POLICY_FORMAT,
        "session_id":row.session_id,
        "enabled":row.enabled,
        "updated_by":row.updated_by,
        "updated_at_ms":row.updated_at_ms.to_string(),
    });
    transaction.execute(
        "INSERT INTO journal_session_hibernation_policy(
           session_id, enabled, updated_by, updated_at_ms, result_json, committed_sequence
         ) VALUES(?1, ?2, ?3, ?4, ?5, ?6)
         ON CONFLICT(session_id) DO UPDATE SET
           enabled = excluded.enabled,
           updated_by = excluded.updated_by,
           updated_at_ms = excluded.updated_at_ms,
           result_json = excluded.result_json,
           committed_sequence = excluded.committed_sequence",
        params![
            row.session_id.as_str(),
            if row.enabled { 1_i64 } else { 0_i64 },
            row.updated_by.as_deref(),
            i64::try_from(row.updated_at_ms)
                .context("hibernation policy timestamp exceeds SQLite range")?,
            canonical_json(&value)?,
            i64::try_from(row.committed_sequence)
                .context("hibernation policy sequence exceeds SQLite range")?,
        ],
    )?;
    Ok(())
}
