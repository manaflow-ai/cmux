use super::*;

use crate::resource::AgentPublicId;
use crate::workspace_registry::session_journal::{JournalAppend, append_journal_record};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::collections::BTreeMap;

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

pub(super) fn apply_agent_projection_journal_record(
    transaction: &Transaction<'_>,
    sequence: u64,
    kind: &str,
    occurred_at_ms: u64,
    producer: &JournalProducer,
    subjects: &[JournalSubject],
    payload: &Value,
) -> anyhow::Result<()> {
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
    let mut projections = derive_agent_projections_from_journal(connection)?;
    let tx = connection.unchecked_transaction()?;
    classify_interrupted_pi_sessions(&tx, &mut projections)?;
    tx.execute("DELETE FROM resource_agent_projections", [])?;
    for projection in projections.into_values() {
        if terminal_is_live(&tx, &projection.terminal_id)? {
            upsert_projection(&tx, &projection)?;
        }
    }
    tx.commit()?;
    Ok(())
}

fn derive_agent_projections_from_journal(
    connection: &Connection,
) -> anyhow::Result<BTreeMap<String, AgentProjectionRow>> {
    let mut projections = BTreeMap::new();
    let mut sequence = 0;
    loop {
        let page = session_journal::query_session_journal_after(connection, sequence, 1024)?;
        let empty = page.records.is_empty();
        for record in page.records {
            sequence = record.sequence;
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
            let current = projections.remove(&key);
            projections.insert(key, merge_projection(current, next));
        }
        if empty || sequence >= page.head_sequence {
            break;
        }
    }
    Ok(projections)
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

fn classify_interrupted_pi_sessions(
    transaction: &Transaction<'_>,
    projections: &mut BTreeMap<String, AgentProjectionRow>,
) -> anyhow::Result<()> {
    let candidates = projections
        .values()
        .filter(|projection| {
            projection.provider.as_deref() == Some("pi")
                && projection.source_session.is_some()
                && !matches!(projection.state.as_str(), "done" | "interrupted")
        })
        .cloned()
        .collect::<Vec<_>>();
    for projection in candidates {
        if !terminal_is_live(transaction, &projection.terminal_id)? {
            continue;
        }
        let source_session = projection.source_session.as_deref().unwrap_or_default();
        let event_id = recovery_event_id(&projection.terminal_id, source_session);
        if journal_event_exists(transaction, &event_id)? {
            continue;
        }
        let now = unix_epoch_ms()?;
        let session_id = transaction.query_row(
            "SELECT value FROM meta WHERE key = 'session_public_id'",
            [],
            |row| row.get::<_, String>(0),
        )?;
        let producer = JournalProducer { kind: "recovery_policy".into(), id: "cmux-tui".into() };
        let subjects = vec![
            JournalSubject { kind: "session".into(), id: session_id },
            JournalSubject { kind: "terminal".into(), id: projection.terminal_id.to_string() },
            JournalSubject { kind: "agent_provider".into(), id: "pi".into() },
        ];
        let payload = json!({
            "format":RECOVERY_FORMAT,
            "provider":"pi",
            "source_session":source_session,
            "policy":"classify_only",
            "intent":"mark_interrupted_after_host_reopen",
            "outcome":"classified_interrupted",
        });
        let sequence = append_journal_record(
            transaction,
            &JournalAppend {
                event_id: &event_id,
                schema_version: 1,
                kind: "agent.session.interrupted",
                class: JournalClass::State,
                replay: JournalReplayPolicy::Required,
                occurred_at_ms: now,
                producer: &producer,
                authority: None,
                causation_id: None,
                correlation_id: Some(&event_id),
                causation_depth: 0,
                subjects: &subjects,
                sensitivity: JournalSensitivity::Metadata,
                payload: &payload,
                content: None,
                resource_revision: None,
                previous_resource_revision: None,
            },
        )?;
        let key = projection.terminal_id.to_string();
        projections.insert(
            key,
            AgentProjectionRow {
                terminal_id: projection.terminal_id,
                state: "interrupted".into(),
                source: "hook".into(),
                updated_at_ms: now,
                source_session: projection.source_session,
                provider: Some("pi".into()),
                committed_sequence: sequence,
            },
        );
    }
    Ok(())
}

fn recovery_event_id(terminal_id: &TerminalPublicId, source_session: &str) -> String {
    let mut digest = Sha256::new();
    digest.update(b"cmux.agent-recovery.interrupted.v1\0");
    digest.update(terminal_id.as_str().as_bytes());
    digest.update(b"\0");
    digest.update(source_session.as_bytes());
    format!("event_agent_interrupted_{}", encode_bytes_hex(&digest.finalize()))
}

fn encode_bytes_hex(bytes: &[u8]) -> String {
    bytes.iter().map(|byte| format!("{byte:02x}")).collect()
}

fn journal_event_exists(transaction: &Transaction<'_>, event_id: &str) -> anyhow::Result<bool> {
    Ok(transaction
        .query_row("SELECT 1 FROM journal_event_index WHERE event_id = ?1", [event_id], |_| Ok(()))
        .optional()?
        .is_some())
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
