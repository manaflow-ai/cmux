use super::*;

use crate::resource::AgentPublicId;
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::collections::BTreeMap;

const AGENT_STATE_FORMAT: &str = "cmux.journal-agent-state.v1";
const RECOVERY_FORMAT: &str = "cmux.agent-recovery.v1";

#[derive(Debug, Clone, PartialEq, Eq)]
struct AgentProjectionRow {
    terminal_id: TerminalPublicId,
    state: String,
    source: String,
    updated_at_ms: u64,
    source_session: Option<String>,
    provider: Option<String>,
    committed_sequence: u64,
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct CanonicalAgentStateRow {
    agent_tree_id: String,
    agent_node_id: String,
    terminal_id: TerminalPublicId,
    state: String,
    updated_at_ms: u64,
    source_session: Option<String>,
    provider: String,
    parent_agent_node_id: Option<String>,
    agent_relation: String,
    agent_identity_quality: String,
    committed_sequence: u64,
}

struct DerivedAgentProjections {
    terminal_current: BTreeMap<String, AgentProjectionRow>,
    canonical_states: BTreeMap<String, CanonicalAgentStateRow>,
}

pub(super) fn apply_agent_projection_journal_record(
    transaction: &Transaction<'_>,
    sequence: u64,
    kind: &str,
    occurred_at_ms: u64,
    producer: &JournalProducer,
    subjects: &[JournalSubject],
    payload: &Value,
) -> anyhow::Result<()> {
    if let Some(canonical_state) = canonical_agent_state_from_journal_record(
        sequence,
        kind,
        occurred_at_ms,
        producer,
        subjects,
        payload,
    )? {
        upsert_agent_state(transaction, &canonical_state)?;
    }

    let Some(next) = projection_from_journal_record(
        sequence,
        kind,
        occurred_at_ms,
        producer,
        subjects,
        payload,
    )?
    else {
        return Ok(());
    };
    if !terminal_is_live(transaction, &next.terminal_id)? {
        return Ok(());
    }
    let current = stored_projection(transaction, &next.terminal_id)?;
    let selected = merge_projection(current, next);
    upsert_projection(transaction, &selected)?;
    Ok(())
}

pub(super) fn rebuild_agent_projections_from_journal(
    connection: &Connection,
) -> anyhow::Result<()> {
    let projections = derive_agent_projections_from_journal(connection)?;
    let tx = connection.unchecked_transaction()?;
    tx.execute("DELETE FROM resource_agent_projections", [])?;
    tx.execute("DELETE FROM journal_agent_states", [])?;
    for state in projections.canonical_states.into_values() {
        upsert_agent_state(&tx, &state)?;
    }
    for projection in projections.terminal_current.into_values() {
        if terminal_is_live(&tx, &projection.terminal_id)? {
            upsert_projection(&tx, &projection)?;
        }
    }
    tx.commit()?;
    Ok(())
}

fn derive_agent_projections_from_journal(
    connection: &Connection,
) -> anyhow::Result<DerivedAgentProjections> {
    let mut terminal_current = BTreeMap::new();
    let mut canonical_states = BTreeMap::new();
    let mut sequence = 0;
    loop {
        let page = session_journal::query_session_journal_after(connection, sequence, 1024)?;
        let empty = page.records.is_empty();
        for record in page.records {
            sequence = record.sequence;
            if let Some(next) = canonical_agent_state_from_journal_record(
                record.sequence,
                &record.kind,
                record.occurred_at_ms,
                &record.producer,
                &record.subjects,
                &record.payload,
            )? {
                canonical_states.insert(next.agent_node_id.clone(), next);
            }
            let Some(next) = projection_from_journal_record(
                record.sequence,
                &record.kind,
                record.occurred_at_ms,
                &record.producer,
                &record.subjects,
                &record.payload,
            )?
            else {
                continue;
            };
            let key = next.terminal_id.to_string();
            let current = terminal_current.remove(&key);
            terminal_current.insert(key, merge_projection(current, next));
        }
        if empty || sequence >= page.head_sequence {
            break;
        }
    }
    Ok(DerivedAgentProjections { terminal_current, canonical_states })
}

fn projection_from_journal_record(
    sequence: u64,
    kind: &str,
    occurred_at_ms: u64,
    producer: &JournalProducer,
    subjects: &[JournalSubject],
    payload: &Value,
) -> anyhow::Result<Option<AgentProjectionRow>> {
    if kind == "agent.report" {
        return projection_from_resource_report(sequence, payload);
    }
    if kind == "agent.session.interrupted" && producer.kind == "recovery_policy" {
        return projection_from_recovery_event(sequence, occurred_at_ms, subjects, payload);
    }
    if producer.kind != "agent_adapter" || producer.id != crate::AGENT_HOOK_PRODUCER_ID {
        return Ok(None);
    }
    let Some(state) = hook_projection_state(kind, payload) else {
        return Ok(None);
    };
    let Some(terminal_id) = terminal_subject(subjects)? else {
        return Ok(None);
    };
    let normalized = payload.get("normalized").and_then(Value::as_object);
    let source_session = normalized
        .and_then(|fields| fields.get("agent_session_id"))
        .and_then(Value::as_str)
        .filter(|value| !value.is_empty())
        .map(str::to_string);
    let provider = payload
        .get("adapter")
        .and_then(|adapter| adapter.get("id"))
        .and_then(Value::as_str)
        .filter(|value| !value.is_empty())
        .map(str::to_string);
    Ok(Some(AgentProjectionRow {
        terminal_id,
        state: state.into(),
        source: "hook".into(),
        updated_at_ms: occurred_at_ms,
        source_session,
        provider,
        committed_sequence: sequence,
    }))
}

fn canonical_agent_state_from_journal_record(
    sequence: u64,
    kind: &str,
    occurred_at_ms: u64,
    producer: &JournalProducer,
    subjects: &[JournalSubject],
    payload: &Value,
) -> anyhow::Result<Option<CanonicalAgentStateRow>> {
    if producer.kind != "agent_adapter" || producer.id != crate::AGENT_HOOK_PRODUCER_ID {
        return Ok(None);
    }
    let Some(state) = hook_projection_state(kind, payload) else {
        return Ok(None);
    };
    let Some(terminal_id) = terminal_subject(subjects)? else {
        return Ok(None);
    };
    let Some(normalized) = payload.get("normalized").and_then(Value::as_object) else {
        return Ok(None);
    };
    let Some(agent_tree_id) = required_normalized_text(normalized, "agent_tree_id") else {
        return Ok(None);
    };
    let Some(agent_node_id) = required_normalized_text(normalized, "agent_node_id") else {
        return Ok(None);
    };
    let Some(provider) =
        payload.get("adapter").and_then(|adapter| adapter.get("id")).and_then(Value::as_str)
    else {
        return Ok(None);
    };
    if provider.is_empty() {
        return Ok(None);
    }
    let Some(agent_relation) = required_normalized_text(normalized, "agent_relation") else {
        return Ok(None);
    };
    let Some(agent_identity_quality) =
        required_normalized_text(normalized, "agent_identity_quality")
    else {
        return Ok(None);
    };
    let source_session =
        optional_normalized_text(normalized, "agent_session_id").map(str::to_string);
    let parent_agent_node_id =
        optional_normalized_text(normalized, "parent_agent_node_id").map(str::to_string);
    Ok(Some(CanonicalAgentStateRow {
        agent_tree_id: agent_tree_id.to_string(),
        agent_node_id: agent_node_id.to_string(),
        terminal_id,
        state: state.into(),
        updated_at_ms: occurred_at_ms,
        source_session,
        provider: provider.to_string(),
        parent_agent_node_id,
        agent_relation: agent_relation.to_string(),
        agent_identity_quality: agent_identity_quality.to_string(),
        committed_sequence: sequence,
    }))
}

fn projection_from_resource_report(
    sequence: u64,
    payload: &Value,
) -> anyhow::Result<Option<AgentProjectionRow>> {
    let Some(result) = payload.get("result").and_then(Value::as_object) else {
        return Ok(None);
    };
    let Some(terminal_id) = result.get("terminal_id").and_then(Value::as_str) else {
        return Ok(None);
    };
    let terminal_id = TerminalPublicId::parse(terminal_id)?;
    let state = result
        .get("state")
        .and_then(Value::as_str)
        .filter(|state| {
            matches!(*state, "working" | "blocked" | "idle" | "done" | "interrupted" | "unknown")
        })
        .unwrap_or("unknown")
        .to_string();
    let source = result
        .get("source")
        .and_then(Value::as_str)
        .filter(|source| matches!(*source, "hook" | "socket" | "detected"))
        .unwrap_or("detected")
        .to_string();
    let updated_at_ms = result
        .get("updated_at_ms")
        .and_then(|value| value.as_str().and_then(|value| value.parse::<u64>().ok()))
        .or_else(|| result.get("updated_at_ms").and_then(Value::as_u64))
        .unwrap_or(0);
    let source_session = result
        .get("source_session")
        .and_then(Value::as_str)
        .filter(|value| !value.is_empty())
        .map(str::to_string);
    let provider = result
        .get("extra")
        .and_then(|extra| extra.get("provider"))
        .and_then(Value::as_str)
        .filter(|value| !value.is_empty())
        .map(str::to_string);
    Ok(Some(AgentProjectionRow {
        terminal_id,
        state,
        source,
        updated_at_ms,
        source_session,
        provider,
        committed_sequence: sequence,
    }))
}

fn required_normalized_text<'a>(
    normalized: &'a serde_json::Map<String, Value>,
    field: &str,
) -> Option<&'a str> {
    optional_normalized_text(normalized, field)
}

fn optional_normalized_text<'a>(
    normalized: &'a serde_json::Map<String, Value>,
    field: &str,
) -> Option<&'a str> {
    normalized.get(field).and_then(Value::as_str).filter(|value| !value.is_empty())
}

fn projection_from_recovery_event(
    sequence: u64,
    occurred_at_ms: u64,
    subjects: &[JournalSubject],
    payload: &Value,
) -> anyhow::Result<Option<AgentProjectionRow>> {
    if payload.get("format").and_then(Value::as_str) != Some(RECOVERY_FORMAT) {
        return Ok(None);
    }
    if payload.get("outcome").and_then(Value::as_str) != Some("classified_interrupted") {
        return Ok(None);
    }
    let Some(terminal_id) = terminal_subject(subjects)? else {
        return Ok(None);
    };
    let source_session = payload
        .get("source_session")
        .and_then(Value::as_str)
        .filter(|value| !value.is_empty())
        .map(str::to_string);
    let provider = payload
        .get("provider")
        .and_then(Value::as_str)
        .filter(|value| !value.is_empty())
        .map(str::to_string);
    Ok(Some(AgentProjectionRow {
        terminal_id,
        state: "interrupted".into(),
        source: "hook".into(),
        updated_at_ms: occurred_at_ms,
        source_session,
        provider,
        committed_sequence: sequence,
    }))
}

fn hook_projection_state(kind: &str, payload: &Value) -> Option<&'static str> {
    let native_event =
        payload.get("native_event").and_then(Value::as_str).map(lifecycle_key).unwrap_or_default();
    match native_event.as_str() {
        "sessionshutdown" | "agentsettled" | "agentend" => return Some("done"),
        "sessionstart" => return Some("idle"),
        "beforeagentstart" | "agentstart" | "turnstart" => return Some("working"),
        _ => {}
    }
    match kind {
        "agent.session.started" => Some("idle"),
        "agent.turn.started" => Some("working"),
        "agent.approval.requested"
        | "agent.question.requested"
        | "agent.plan_review.requested"
        | "agent.error.reported" => Some("blocked"),
        "agent.turn.completed" => Some("idle"),
        "agent.session.ended" => Some("done"),
        "agent.child.spawned" => Some("working"),
        "agent.child.completed" => Some("done"),
        "agent.child.failed" => Some("blocked"),
        _ => None,
    }
}

fn lifecycle_key(value: &str) -> String {
    value.chars().filter(|ch| ch.is_ascii_alphanumeric()).flat_map(char::to_lowercase).collect()
}

fn terminal_subject(subjects: &[JournalSubject]) -> anyhow::Result<Option<TerminalPublicId>> {
    subjects
        .iter()
        .find(|subject| subject.kind == "terminal")
        .map(|subject| TerminalPublicId::parse(subject.id.clone()))
        .transpose()
        .map_err(Into::into)
}

fn merge_projection(
    current: Option<AgentProjectionRow>,
    next: AgentProjectionRow,
) -> AgentProjectionRow {
    match current {
        Some(current) if current.source == "hook" && next.source == "socket" => current,
        _ => next,
    }
}

fn stored_projection(
    transaction: &Transaction<'_>,
    terminal_id: &TerminalPublicId,
) -> anyhow::Result<Option<AgentProjectionRow>> {
    let stored = transaction
        .query_row(
            "SELECT result_json, committed_revision
             FROM resource_agent_projections
             WHERE terminal_id = ?1",
            [terminal_id.as_str()],
            |row| Ok((row.get::<_, String>(0)?, row.get::<_, i64>(1)?)),
        )
        .optional()?;
    let Some((result_json, committed_sequence)) = stored else {
        return Ok(None);
    };
    let result: Value = serde_json::from_str(&result_json)?;
    let committed_sequence =
        u64::try_from(committed_sequence).context("agent projection revision is negative")?;
    projection_from_resource_report(committed_sequence, &json!({"result":result}))
}

fn upsert_agent_state(
    transaction: &Transaction<'_>,
    state: &CanonicalAgentStateRow,
) -> anyhow::Result<()> {
    let value = json!({
        "format":AGENT_STATE_FORMAT,
        "agent_tree_id":state.agent_tree_id,
        "agent_node_id":state.agent_node_id,
        "terminal_id":state.terminal_id,
        "state":state.state,
        "source":"hook",
        "updated_at_ms":state.updated_at_ms.to_string(),
        "source_session":state.source_session,
        "provider":state.provider,
        "parent_agent_node_id":state.parent_agent_node_id,
        "agent_relation":state.agent_relation,
        "agent_identity_quality":state.agent_identity_quality,
    });
    transaction.execute(
        "INSERT INTO journal_agent_states(
           agent_node_id, agent_tree_id, terminal_id, provider, state,
           source_session, parent_agent_node_id, agent_relation,
           agent_identity_quality, updated_at_ms, result_json, committed_sequence
         ) VALUES(?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12)
         ON CONFLICT(agent_node_id) DO UPDATE SET
           agent_tree_id = excluded.agent_tree_id,
           terminal_id = excluded.terminal_id,
           provider = excluded.provider,
           state = excluded.state,
           source_session = excluded.source_session,
           parent_agent_node_id = excluded.parent_agent_node_id,
           agent_relation = excluded.agent_relation,
           agent_identity_quality = excluded.agent_identity_quality,
           updated_at_ms = excluded.updated_at_ms,
           result_json = excluded.result_json,
           committed_sequence = excluded.committed_sequence",
        params![
            state.agent_node_id.as_str(),
            state.agent_tree_id.as_str(),
            state.terminal_id.as_str(),
            state.provider.as_str(),
            state.state.as_str(),
            state.source_session.as_deref(),
            state.parent_agent_node_id.as_deref(),
            state.agent_relation.as_str(),
            state.agent_identity_quality.as_str(),
            i64::try_from(state.updated_at_ms)
                .context("agent state timestamp exceeds SQLite range")?,
            canonical_json(&value)?,
            i64::try_from(state.committed_sequence)
                .context("agent state sequence exceeds SQLite range")?,
        ],
    )?;
    Ok(())
}

fn upsert_projection(
    transaction: &Transaction<'_>,
    projection: &AgentProjectionRow,
) -> anyhow::Result<()> {
    let session_id = transaction.query_row(
        "SELECT value FROM meta WHERE key = 'session_public_id'",
        [],
        |row| row.get::<_, String>(0),
    )?;
    let agent_id = agent_id(&projection.terminal_id)?;
    let value = json!({
        "id":agent_id,
        "session_id":session_id,
        "terminal_id":projection.terminal_id,
        "state":projection.state,
        "source":projection.source,
        "updated_at_ms":projection.updated_at_ms.to_string(),
        "source_session":projection.source_session,
        "extra":{
            "provider":projection.provider,
        },
    });
    transaction.execute(
        "INSERT INTO resource_agent_projections(
           terminal_id, result_json, committed_revision
         ) VALUES(?1, ?2, ?3)
         ON CONFLICT(terminal_id) DO UPDATE SET
           result_json = excluded.result_json,
           committed_revision = excluded.committed_revision",
        params![
            projection.terminal_id.as_str(),
            canonical_json(&value)?,
            i64::try_from(projection.committed_sequence)
                .context("agent projection sequence exceeds SQLite range")?,
        ],
    )?;
    Ok(())
}

fn terminal_is_live(
    transaction: &Transaction<'_>,
    terminal_id: &TerminalPublicId,
) -> anyhow::Result<bool> {
    Ok(transaction
        .query_row(
            "SELECT 1 FROM resource_terminals
             WHERE public_id = ?1 AND deleted_revision IS NULL",
            [terminal_id.as_str()],
            |_| Ok(()),
        )
        .optional()?
        .is_some())
}

fn agent_id(terminal_id: &TerminalPublicId) -> anyhow::Result<AgentPublicId> {
    let digest = Sha256::digest(format!("cmux.protocol/2/agent/{terminal_id}").as_bytes());
    let payload = digest[..16].iter().map(|byte| format!("{byte:02x}")).collect::<String>();
    AgentPublicId::parse(format!("agent_{payload}")).map_err(Into::into)
}
