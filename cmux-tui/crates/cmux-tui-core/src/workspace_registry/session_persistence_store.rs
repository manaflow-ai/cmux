use super::*;

use serde_json::{Value, json};
use std::collections::BTreeMap;

const SESSION_LIFECYCLE_FORMAT: &str = "cmux.session-lifecycle-state.v1";
const RUNTIME_ATTACHMENT_FORMAT: &str = "cmux.runtime-attachment-state.v1";
const HIBERNATION_POLICY_FORMAT: &str = "cmux.hibernation-policy-state.v1";
const SESSION_EFFECT_WORKFLOW_FORMAT: &str = "cmux.session-effect-workflow-state.v1";

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

#[derive(Debug, Clone, PartialEq, Eq)]
struct SessionEffectWorkflowRow {
    workflow_id: String,
    session_id: String,
    operation: String,
    state: String,
    attempt_generation: u64,
    target_session_id: String,
    terminal_id: Option<TerminalPublicId>,
    agent_tree_id: Option<String>,
    agent_node_id: Option<String>,
    requires_complete_history: bool,
    outcome: Option<String>,
    updated_at_ms: u64,
    intent_sequence: u64,
    outcome_sequence: Option<u64>,
}

struct DerivedSessionPersistence {
    lifecycle: BTreeMap<String, SessionLifecycleRow>,
    runtime_attachments: BTreeMap<String, RuntimeAttachmentRow>,
    hibernation_policy: BTreeMap<String, HibernationPolicyRow>,
    effect_workflows: BTreeMap<String, SessionEffectWorkflowRow>,
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
         );
         CREATE TABLE IF NOT EXISTS journal_session_effect_workflows (
           workflow_id TEXT PRIMARY KEY NOT NULL,
           session_id TEXT NOT NULL,
           operation TEXT NOT NULL CHECK(operation IN (
             'session.hibernate', 'session.recover', 'session.restore', 'session.fork'
           )),
           state TEXT NOT NULL CHECK(state IN (
             'intent_recorded', 'succeeded', 'failed', 'indeterminate'
           )),
           attempt_generation TEXT NOT NULL CHECK(
             attempt_generation <> ''
             AND attempt_generation NOT GLOB '*[^0-9]*'
             AND (attempt_generation = '0' OR attempt_generation NOT GLOB '0*')
           ),
           target_session_id TEXT NOT NULL,
           terminal_id TEXT,
           agent_tree_id TEXT,
           agent_node_id TEXT,
           requires_complete_history INTEGER NOT NULL CHECK(requires_complete_history IN (0, 1)),
           outcome TEXT CHECK(outcome IS NULL OR outcome IN (
             'succeeded', 'failed', 'indeterminate'
           )),
           updated_at_ms INTEGER NOT NULL CHECK(updated_at_ms >= 0),
           result_json TEXT NOT NULL,
           intent_sequence INTEGER NOT NULL CHECK(intent_sequence >= 0),
           outcome_sequence INTEGER CHECK(outcome_sequence IS NULL OR outcome_sequence >= 0),
           committed_sequence INTEGER NOT NULL CHECK(committed_sequence >= 0),
           CHECK (
             json_valid(result_json)
             AND COALESCE(
               json_extract(result_json, '$.format') = 'cmux.session-effect-workflow-state.v1',
               0
             )
             AND COALESCE(json_extract(result_json, '$.workflow_id') = workflow_id, 0)
             AND COALESCE(json_extract(result_json, '$.session_id') = session_id, 0)
             AND COALESCE(json_extract(result_json, '$.operation') = operation, 0)
             AND COALESCE(json_extract(result_json, '$.state') = state, 0)
             AND COALESCE(
               json_extract(result_json, '$.attempt_generation') = attempt_generation,
               0
             )
             AND COALESCE(json_extract(result_json, '$.target_session_id') = target_session_id, 0)
             AND COALESCE(
               json_extract(result_json, '$.requires_complete_history')
                 = (requires_complete_history != 0),
               0
             )
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
    if let Some(row) = session_effect_workflow_from_record(
        transaction,
        sequence,
        kind,
        occurred_at_ms,
        producer,
        authority,
        subjects,
        payload,
    )? {
        upsert_session_effect_workflow(transaction, &row)?;
    }
    if let Some((runtime, lifecycle)) = runtime_host_loss_from_record(
        transaction,
        sequence,
        kind,
        occurred_at_ms,
        producer,
        authority,
        subjects,
        payload,
    )? {
        upsert_runtime_attachment(transaction, &runtime)?;
        upsert_session_lifecycle(transaction, &lifecycle)?;
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
    tx.execute("DELETE FROM journal_session_effect_workflows", [])?;
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
    for row in derived.effect_workflows.into_values() {
        upsert_session_effect_workflow(&tx, &row)?;
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
    let mut effect_workflows = BTreeMap::new();
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
            if let Some(row) = session_effect_workflow_from_record_map(
                &effect_workflows,
                record.sequence,
                &record.kind,
                record.occurred_at_ms,
                &record.producer,
                authority,
                &record.subjects,
                &record.payload,
            )? {
                effect_workflows.insert(row.workflow_id.clone(), row);
            }
            if let Some((runtime, lifecycle_row)) = runtime_host_loss_from_record_map(
                &runtime_attachments,
                record.sequence,
                &record.kind,
                record.occurred_at_ms,
                &record.producer,
                authority,
                &record.subjects,
                &record.payload,
            )? {
                runtime_attachments.insert(runtime.terminal_id.to_string(), runtime);
                lifecycle.insert(lifecycle_row.session_id.clone(), lifecycle_row);
            }
        }
        if empty || sequence >= page.head_sequence {
            break;
        }
    }
    Ok(DerivedSessionPersistence {
        lifecycle,
        runtime_attachments,
        hibernation_policy,
        effect_workflows,
    })
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
        || !payload_keys_are_subset(
            payload,
            &["format", "terminal_id", "runtime_id", "state", "host_epoch", "lease_generation"],
        )
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
        .filter(|state| matches!(*state, "attached" | "detached" | "lost"))
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

fn runtime_host_loss_from_record(
    transaction: &Transaction<'_>,
    sequence: u64,
    kind: &str,
    occurred_at_ms: u64,
    producer: &JournalProducer,
    authority: Option<&JournalAuthority>,
    subjects: &[JournalSubject],
    payload: &Value,
) -> anyhow::Result<Option<(RuntimeAttachmentRow, SessionLifecycleRow)>> {
    let Some(terminal_id) = payload.get("terminal_id").and_then(Value::as_str) else {
        return Ok(None);
    };
    let current = read_runtime_attachment(transaction, terminal_id)?;
    runtime_host_loss_from_current(
        current.as_ref(),
        sequence,
        kind,
        occurred_at_ms,
        producer,
        authority,
        subjects,
        payload,
    )
}

fn runtime_host_loss_from_record_map(
    current: &BTreeMap<String, RuntimeAttachmentRow>,
    sequence: u64,
    kind: &str,
    occurred_at_ms: u64,
    producer: &JournalProducer,
    authority: Option<&JournalAuthority>,
    subjects: &[JournalSubject],
    payload: &Value,
) -> anyhow::Result<Option<(RuntimeAttachmentRow, SessionLifecycleRow)>> {
    let Some(terminal_id) = payload.get("terminal_id").and_then(Value::as_str) else {
        return Ok(None);
    };
    runtime_host_loss_from_current(
        current.get(terminal_id),
        sequence,
        kind,
        occurred_at_ms,
        producer,
        authority,
        subjects,
        payload,
    )
}

fn runtime_host_loss_from_current(
    current: Option<&RuntimeAttachmentRow>,
    sequence: u64,
    kind: &str,
    occurred_at_ms: u64,
    producer: &JournalProducer,
    authority: Option<&JournalAuthority>,
    subjects: &[JournalSubject],
    payload: &Value,
) -> anyhow::Result<Option<(RuntimeAttachmentRow, SessionLifecycleRow)>> {
    if kind != "runtime.host_loss.proven"
        || !is_trusted_session_persistence_record(producer, authority)
        || payload.get("format").and_then(Value::as_str) != Some("cmux.runtime-host-loss.v1")
        || !payload_keys_are_subset(
            payload,
            &["format", "terminal_id", "runtime_id", "host_epoch", "lease_generation", "proof"],
        )
    {
        return Ok(None);
    }
    let Some(session_id) = subject_id(subjects, "session") else {
        return Ok(None);
    };
    let Some(terminal_subject) = subject_id(subjects, "terminal") else {
        return Ok(None);
    };
    let Ok(terminal_id) = TerminalPublicId::parse(terminal_subject.to_string()) else {
        return Ok(None);
    };
    if payload.get("terminal_id").and_then(Value::as_str) != Some(terminal_id.as_str()) {
        return Ok(None);
    }
    let Some(runtime_id) = non_empty_payload_text(payload, "runtime_id") else {
        return Ok(None);
    };
    let Some(host_epoch) = non_empty_payload_text(payload, "host_epoch") else {
        return Ok(None);
    };
    let Some(lease_generation) = non_empty_payload_text(payload, "lease_generation") else {
        return Ok(None);
    };
    let Some(proof) = payload
        .get("proof")
        .and_then(Value::as_str)
        .filter(|value| matches!(*value, "host_liveness_dead" | "machine_epoch_advanced"))
    else {
        return Ok(None);
    };
    let Some(current) = current else {
        return Ok(None);
    };
    if current.session_id != session_id
        || current.terminal_id != terminal_id
        || current.runtime_id != runtime_id
        || current.host_epoch != host_epoch
        || current.lease_generation != lease_generation
        || current.state == "interrupted"
    {
        return Ok(None);
    }
    if !matches!(current.state.as_str(), "attached" | "detached" | "lost") {
        return Ok(None);
    }
    let runtime = RuntimeAttachmentRow {
        session_id: current.session_id.clone(),
        terminal_id: current.terminal_id.clone(),
        runtime_id: current.runtime_id.clone(),
        state: "interrupted".into(),
        host_epoch: current.host_epoch.clone(),
        lease_generation: current.lease_generation.clone(),
        updated_at_ms: occurred_at_ms,
        committed_sequence: sequence,
    };
    let lifecycle = SessionLifecycleRow {
        session_id: current.session_id.clone(),
        state: "interrupted".into(),
        reason: Some(format!("runtime_host_loss:{proof}")),
        updated_at_ms: occurred_at_ms,
        committed_sequence: sequence,
    };
    Ok(Some((runtime, lifecycle)))
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

fn session_effect_workflow_from_record(
    transaction: &Transaction<'_>,
    sequence: u64,
    kind: &str,
    occurred_at_ms: u64,
    producer: &JournalProducer,
    authority: Option<&JournalAuthority>,
    subjects: &[JournalSubject],
    payload: &Value,
) -> anyhow::Result<Option<SessionEffectWorkflowRow>> {
    let Some(workflow_id) = payload.get("workflow_id").and_then(Value::as_str) else {
        return Ok(None);
    };
    let current = read_session_effect_workflow(transaction, workflow_id)?;
    session_effect_workflow_from_current(
        current.as_ref(),
        sequence,
        kind,
        occurred_at_ms,
        producer,
        authority,
        subjects,
        payload,
    )
}

fn session_effect_workflow_from_record_map(
    current: &BTreeMap<String, SessionEffectWorkflowRow>,
    sequence: u64,
    kind: &str,
    occurred_at_ms: u64,
    producer: &JournalProducer,
    authority: Option<&JournalAuthority>,
    subjects: &[JournalSubject],
    payload: &Value,
) -> anyhow::Result<Option<SessionEffectWorkflowRow>> {
    let Some(workflow_id) = payload.get("workflow_id").and_then(Value::as_str) else {
        return Ok(None);
    };
    session_effect_workflow_from_current(
        current.get(workflow_id),
        sequence,
        kind,
        occurred_at_ms,
        producer,
        authority,
        subjects,
        payload,
    )
}

fn session_effect_workflow_from_current(
    current: Option<&SessionEffectWorkflowRow>,
    sequence: u64,
    kind: &str,
    occurred_at_ms: u64,
    producer: &JournalProducer,
    authority: Option<&JournalAuthority>,
    subjects: &[JournalSubject],
    payload: &Value,
) -> anyhow::Result<Option<SessionEffectWorkflowRow>> {
    if !is_trusted_session_persistence_record(producer, authority) {
        return Ok(None);
    }
    match kind {
        "session.effect.intent.recorded" => {
            session_effect_intent_from_record(current, sequence, occurred_at_ms, subjects, payload)
        }
        "session.effect.outcome.recorded" => {
            session_effect_outcome_from_record(current, sequence, occurred_at_ms, payload)
        }
        _ => Ok(None),
    }
}

fn session_effect_intent_from_record(
    current: Option<&SessionEffectWorkflowRow>,
    sequence: u64,
    occurred_at_ms: u64,
    subjects: &[JournalSubject],
    payload: &Value,
) -> anyhow::Result<Option<SessionEffectWorkflowRow>> {
    if payload.get("format").and_then(Value::as_str) != Some("cmux.session-effect-intent.v1")
        || !payload_keys_are_subset(
            payload,
            &[
                "format",
                "workflow_id",
                "operation",
                "attempt_generation",
                "target_session_id",
                "terminal_id",
                "agent_tree_id",
                "agent_node_id",
                "requires_complete_history",
            ],
        )
    {
        return Ok(None);
    }
    let Some(session_id) = subject_id(subjects, "session") else {
        return Ok(None);
    };
    let Some(workflow_id) = non_empty_payload_text(payload, "workflow_id") else {
        return Ok(None);
    };
    let Some(workflow_subject) = subject_id(subjects, "effect_workflow") else {
        return Ok(None);
    };
    if workflow_subject != workflow_id {
        return Ok(None);
    }
    let Some(operation) = non_empty_payload_text(payload, "operation") else {
        return Ok(None);
    };
    if !session_effect_operation_is_supported(operation) {
        return Ok(None);
    }
    let Some(attempt_generation) =
        non_empty_payload_text(payload, "attempt_generation").and_then(parse_attempt_generation)
    else {
        return Ok(None);
    };
    if attempt_generation == 0 {
        return Ok(None);
    }
    if current.is_some_and(|current| current.attempt_generation >= attempt_generation) {
        return Ok(None);
    }
    let Some(target_session_id) = non_empty_payload_text(payload, "target_session_id") else {
        return Ok(None);
    };
    if SessionPublicId::parse(target_session_id.to_string()).is_err() {
        return Ok(None);
    }
    let Some(requires_complete_history) =
        payload.get("requires_complete_history").and_then(Value::as_bool)
    else {
        return Ok(None);
    };
    if !requires_complete_history {
        return Ok(None);
    }
    let terminal_id = match payload.get("terminal_id").and_then(Value::as_str) {
        Some(value) => {
            let parsed = TerminalPublicId::parse(value.to_string());
            let Ok(parsed) = parsed else {
                return Ok(None);
            };
            if subject_id(subjects, "terminal").is_some_and(|subject| subject != value) {
                return Ok(None);
            }
            Some(parsed)
        }
        None => None,
    };
    let Some(agent_tree_id) = optional_valid_identifier(payload, "agent_tree_id") else {
        return Ok(None);
    };
    let Some(agent_node_id) = optional_valid_identifier(payload, "agent_node_id") else {
        return Ok(None);
    };
    Ok(Some(SessionEffectWorkflowRow {
        workflow_id: workflow_id.to_string(),
        session_id: session_id.to_string(),
        operation: operation.to_string(),
        state: "intent_recorded".into(),
        attempt_generation,
        target_session_id: target_session_id.to_string(),
        terminal_id,
        agent_tree_id,
        agent_node_id,
        requires_complete_history,
        outcome: None,
        updated_at_ms: occurred_at_ms,
        intent_sequence: sequence,
        outcome_sequence: None,
    }))
}

fn session_effect_outcome_from_record(
    current: Option<&SessionEffectWorkflowRow>,
    sequence: u64,
    occurred_at_ms: u64,
    payload: &Value,
) -> anyhow::Result<Option<SessionEffectWorkflowRow>> {
    if payload.get("format").and_then(Value::as_str) != Some("cmux.session-effect-outcome.v1")
        || !payload_keys_are_subset(
            payload,
            &["format", "workflow_id", "attempt_generation", "outcome"],
        )
    {
        return Ok(None);
    }
    let Some(workflow_id) = non_empty_payload_text(payload, "workflow_id") else {
        return Ok(None);
    };
    let Some(attempt_generation) =
        non_empty_payload_text(payload, "attempt_generation").and_then(parse_attempt_generation)
    else {
        return Ok(None);
    };
    let Some(outcome) = payload
        .get("outcome")
        .and_then(Value::as_str)
        .filter(|value| matches!(*value, "succeeded" | "failed" | "indeterminate"))
    else {
        return Ok(None);
    };
    let Some(current) = current else {
        return Ok(None);
    };
    if current.workflow_id != workflow_id || current.attempt_generation != attempt_generation {
        return Ok(None);
    }
    if current.state != "intent_recorded" {
        return Ok(None);
    }
    let mut row = current.clone();
    row.state = outcome.to_string();
    row.outcome = Some(outcome.to_string());
    row.updated_at_ms = occurred_at_ms;
    row.outcome_sequence = Some(sequence);
    Ok(Some(row))
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

fn payload_keys_are_subset(payload: &Value, allowed: &[&str]) -> bool {
    let Some(object) = payload.as_object() else {
        return false;
    };
    object.keys().all(|key| allowed.contains(&key.as_str()))
}

fn session_effect_operation_is_supported(operation: &str) -> bool {
    matches!(
        operation,
        "session.hibernate" | "session.recover" | "session.restore" | "session.fork"
    )
}

fn parse_attempt_generation(value: &str) -> Option<u64> {
    if value.is_empty()
        || (value.len() > 1 && value.starts_with('0'))
        || !value.bytes().all(|byte| byte.is_ascii_digit())
    {
        return None;
    }
    value.parse().ok()
}

fn optional_valid_identifier(payload: &Value, field: &str) -> Option<Option<String>> {
    let Some(value) = payload.get(field) else {
        return Some(None);
    };
    let Some(value) = value.as_str().filter(|value| !value.is_empty()) else {
        return None;
    };
    if validate_identifier(field, value).is_err() {
        return None;
    }
    Some(Some(value.to_string()))
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

fn read_runtime_attachment(
    transaction: &Transaction<'_>,
    terminal_id: &str,
) -> anyhow::Result<Option<RuntimeAttachmentRow>> {
    let stored = transaction
        .query_row(
            "SELECT session_id, runtime_id, state, host_epoch, lease_generation,
                    updated_at_ms, committed_sequence
             FROM journal_runtime_attachment_states
             WHERE terminal_id = ?1",
            [terminal_id],
            |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    row.get::<_, String>(1)?,
                    row.get::<_, String>(2)?,
                    row.get::<_, String>(3)?,
                    row.get::<_, String>(4)?,
                    row.get::<_, i64>(5)?,
                    row.get::<_, i64>(6)?,
                ))
            },
        )
        .optional()?;
    let Some((
        session_id,
        runtime_id,
        state,
        host_epoch,
        lease_generation,
        updated_at_ms,
        committed_sequence,
    )) = stored
    else {
        return Ok(None);
    };
    Ok(Some(RuntimeAttachmentRow {
        session_id,
        terminal_id: TerminalPublicId::parse(terminal_id.to_string())?,
        runtime_id,
        state,
        host_epoch,
        lease_generation,
        updated_at_ms: u64::try_from(updated_at_ms)
            .context("stored runtime attachment timestamp is negative")?,
        committed_sequence: u64::try_from(committed_sequence)
            .context("stored runtime attachment sequence is negative")?,
    }))
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

fn read_session_effect_workflow(
    transaction: &Transaction<'_>,
    workflow_id: &str,
) -> anyhow::Result<Option<SessionEffectWorkflowRow>> {
    let stored = transaction
        .query_row(
            "SELECT session_id, operation, state, attempt_generation, target_session_id,
                    terminal_id, agent_tree_id, agent_node_id, requires_complete_history,
                    outcome, updated_at_ms, intent_sequence, outcome_sequence
             FROM journal_session_effect_workflows
             WHERE workflow_id = ?1",
            [workflow_id],
            |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    row.get::<_, String>(1)?,
                    row.get::<_, String>(2)?,
                    row.get::<_, String>(3)?,
                    row.get::<_, String>(4)?,
                    row.get::<_, Option<String>>(5)?,
                    row.get::<_, Option<String>>(6)?,
                    row.get::<_, Option<String>>(7)?,
                    row.get::<_, i64>(8)?,
                    row.get::<_, Option<String>>(9)?,
                    row.get::<_, i64>(10)?,
                    row.get::<_, i64>(11)?,
                    row.get::<_, Option<i64>>(12)?,
                ))
            },
        )
        .optional()?;
    let Some((
        session_id,
        operation,
        state,
        attempt_generation,
        target_session_id,
        terminal_id,
        agent_tree_id,
        agent_node_id,
        requires_complete_history,
        outcome,
        updated_at_ms,
        intent_sequence,
        outcome_sequence,
    )) = stored
    else {
        return Ok(None);
    };
    let terminal_id = terminal_id.map(TerminalPublicId::parse).transpose()?;
    Ok(Some(SessionEffectWorkflowRow {
        workflow_id: workflow_id.to_string(),
        session_id,
        operation,
        state,
        attempt_generation: parse_attempt_generation(&attempt_generation)
            .context("stored effect workflow attempt generation is invalid")?,
        target_session_id,
        terminal_id,
        agent_tree_id,
        agent_node_id,
        requires_complete_history: requires_complete_history != 0,
        outcome,
        updated_at_ms: u64::try_from(updated_at_ms)
            .context("stored effect workflow timestamp is negative")?,
        intent_sequence: u64::try_from(intent_sequence)
            .context("stored effect workflow intent sequence is negative")?,
        outcome_sequence: outcome_sequence
            .map(u64::try_from)
            .transpose()
            .context("stored effect workflow outcome sequence is negative")?,
    }))
}

fn upsert_session_effect_workflow(
    transaction: &Transaction<'_>,
    row: &SessionEffectWorkflowRow,
) -> anyhow::Result<()> {
    let terminal_id = row.terminal_id.as_ref().map(TerminalPublicId::as_str);
    let value = json!({
        "format":SESSION_EFFECT_WORKFLOW_FORMAT,
        "workflow_id":row.workflow_id,
        "session_id":row.session_id,
        "operation":row.operation,
        "state":row.state,
        "attempt_generation":row.attempt_generation.to_string(),
        "target_session_id":row.target_session_id,
        "terminal_id":terminal_id,
        "agent_tree_id":row.agent_tree_id,
        "agent_node_id":row.agent_node_id,
        "requires_complete_history":row.requires_complete_history,
        "outcome":row.outcome,
        "updated_at_ms":row.updated_at_ms.to_string(),
        "intent_sequence":row.intent_sequence.to_string(),
        "outcome_sequence":row.outcome_sequence.map(|sequence| sequence.to_string()),
    });
    let committed_sequence = row.outcome_sequence.unwrap_or(row.intent_sequence);
    transaction.execute(
        "INSERT INTO journal_session_effect_workflows(
           workflow_id, session_id, operation, state, attempt_generation, target_session_id,
           terminal_id, agent_tree_id, agent_node_id, requires_complete_history, outcome,
           updated_at_ms, result_json, intent_sequence, outcome_sequence, committed_sequence
         ) VALUES(?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16)
         ON CONFLICT(workflow_id) DO UPDATE SET
           session_id = excluded.session_id,
           operation = excluded.operation,
           state = excluded.state,
           attempt_generation = excluded.attempt_generation,
           target_session_id = excluded.target_session_id,
           terminal_id = excluded.terminal_id,
           agent_tree_id = excluded.agent_tree_id,
           agent_node_id = excluded.agent_node_id,
           requires_complete_history = excluded.requires_complete_history,
           outcome = excluded.outcome,
           updated_at_ms = excluded.updated_at_ms,
           result_json = excluded.result_json,
           intent_sequence = excluded.intent_sequence,
           outcome_sequence = excluded.outcome_sequence,
           committed_sequence = excluded.committed_sequence",
        params![
            row.workflow_id.as_str(),
            row.session_id.as_str(),
            row.operation.as_str(),
            row.state.as_str(),
            row.attempt_generation.to_string(),
            row.target_session_id.as_str(),
            terminal_id,
            row.agent_tree_id.as_deref(),
            row.agent_node_id.as_deref(),
            if row.requires_complete_history { 1_i64 } else { 0_i64 },
            row.outcome.as_deref(),
            i64::try_from(row.updated_at_ms)
                .context("effect workflow timestamp exceeds SQLite range")?,
            canonical_json(&value)?,
            i64::try_from(row.intent_sequence)
                .context("effect workflow intent sequence exceeds SQLite range")?,
            row.outcome_sequence
                .map(i64::try_from)
                .transpose()
                .context("effect workflow outcome sequence exceeds SQLite range")?,
            i64::try_from(committed_sequence)
                .context("effect workflow committed sequence exceeds SQLite range")?,
        ],
    )?;
    Ok(())
}

impl WorkspaceRegistry {
    pub(crate) fn runtime_attachment_state(
        &self,
        terminal_id: &TerminalPublicId,
    ) -> anyhow::Result<Option<String>> {
        self.connection
            .query_row(
                "SELECT state FROM journal_runtime_attachment_states
                 WHERE terminal_id = ?1",
                [terminal_id.as_str()],
                |row| row.get(0),
            )
            .optional()
            .map_err(Into::into)
    }
}
