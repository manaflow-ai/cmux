use super::*;

use crate::resource::AgentPublicId;
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::collections::BTreeMap;

const RECOVERY_FORMAT: &str = "cmux.agent-recovery.v1";
const RECOVERY_PRODUCER_ID: &str = "agent-recovery-v1";
const PREJOURNAL_MIGRATION_FORMAT: &str = "cmux.agent-projection-migration.v1";
const PREJOURNAL_MIGRATION_PRODUCER_ID: &str = "agent-projection-v1";
const AGENT_PROJECTION_JOURNAL_CURSOR_KEY: &str = "agent_projection_journal_sequence_v1";
const AGENT_PROJECTION_JOURNAL_CANDIDATE_KEY: &str =
    "agent_projection_journal_candidate_sequence_v1";
const LEGACY_AGENT_EVENT_ID_LOWER_BOUND: &str = "event_agent_";
const LEGACY_AGENT_EVENT_ID_UPPER_BOUND: &str = "event_agent`";

#[derive(Debug, Clone, PartialEq, Eq)]
struct AgentProjectionRow {
    terminal_id: TerminalPublicId,
    state: String,
    source: String,
    updated_at_ms: u64,
    source_session: Option<String>,
    provider: Option<String>,
    committed_sequence: u64,
    result: Option<Value>,
    begins_session: bool,
}

pub(super) fn apply_agent_projection_journal_record(
    transaction: &Transaction<'_>,
    sequence: u64,
    kind: &str,
    occurred_at_ms: u64,
    producer: &JournalProducer,
    subjects: &[JournalSubject],
    payload: &Value,
    resource_revision: Option<u64>,
) -> anyhow::Result<()> {
    let advances_cursor = kind.starts_with("agent.");
    let Some(next) = projection_from_journal_record(
        sequence,
        kind,
        occurred_at_ms,
        producer,
        subjects,
        payload,
        resource_revision,
    )?
    else {
        if advances_cursor {
            advance_agent_projection_journal_cursor(transaction, sequence)?;
        }
        return Ok(());
    };
    if !terminal_is_live(transaction, &next.terminal_id)? {
        if advances_cursor {
            advance_agent_projection_journal_cursor(transaction, sequence)?;
        }
        return Ok(());
    }
    let current = stored_projection(transaction, &next.terminal_id)?;
    let selected = merge_projection(current, next);
    upsert_projection(transaction, &selected)?;
    if advances_cursor {
        advance_agent_projection_journal_cursor(transaction, sequence)?;
    }
    Ok(())
}

pub(super) fn rebuild_agent_projections_from_journal(
    connection: &Connection,
) -> anyhow::Result<()> {
    let tx = connection.unchecked_transaction()?;
    if let Some(sequence) = agent_projection_journal_cursor(&tx)? {
        let candidate = agent_projection_journal_candidate(&tx)?.unwrap_or(0);
        let head_sequence = session_journal::session_journal_head(&tx)?;
        anyhow::ensure!(
            sequence <= head_sequence,
            "agent projection journal cursor {sequence} is ahead of journal head {head_sequence}"
        );
        anyhow::ensure!(
            candidate <= head_sequence,
            "agent projection journal candidate {candidate} is ahead of journal head {head_sequence}"
        );
        if candidate <= sequence {
            store_agent_projection_journal_cursor(&tx, head_sequence)?;
        } else {
            replay_agent_projection_journal_suffix(&tx, sequence)?;
        }
        tx.commit()?;
        return Ok(());
    }

    let original_head_sequence = session_journal::session_journal_head(&tx)?;
    let mut head_sequence = original_head_sequence;
    let mut stored_by_sequence = BTreeMap::<u64, Vec<AgentProjectionRow>>::new();
    for mut stored in stored_live_projections(&tx)? {
        stored.committed_sequence =
            match stored_projection_journal_sequence(&tx, &stored, original_head_sequence)? {
                Some(sequence) => sequence,
                None => append_prejournal_projection_migration(&tx, &stored)?,
            };
        head_sequence = head_sequence.max(stored.committed_sequence);
        stored_by_sequence.entry(stored.committed_sequence).or_default().push(stored);
    }
    let projections = agent_projections_from_legacy_agent_index(&tx, stored_by_sequence)?;
    tx.execute("DELETE FROM resource_agent_projections", [])?;
    for projection in projections.into_values() {
        if terminal_is_live(&tx, &projection.terminal_id)? {
            upsert_projection(&tx, &projection)?;
        }
    }
    store_agent_projection_journal_cursor(&tx, head_sequence)?;
    tx.commit()?;
    Ok(())
}

fn replay_agent_projection_journal_suffix(
    transaction: &Transaction<'_>,
    mut sequence: u64,
) -> anyhow::Result<()> {
    loop {
        let page = session_journal::query_session_journal_after(transaction, sequence, 1024)?;
        let empty = page.records.is_empty();
        for record in page.records {
            sequence = record.sequence;
            apply_agent_projection_journal_record(
                transaction,
                record.sequence,
                &record.kind,
                record.occurred_at_ms,
                &record.producer,
                &record.subjects,
                &record.payload,
                record.resource_revision,
            )?;
        }
        if empty || sequence >= page.head_sequence {
            store_agent_projection_journal_cursor(transaction, page.head_sequence)?;
            return Ok(());
        }
    }
}

fn agent_projection_journal_cursor(connection: &Connection) -> anyhow::Result<Option<u64>> {
    connection
        .query_row(
            "SELECT value FROM meta WHERE key = ?1",
            [AGENT_PROJECTION_JOURNAL_CURSOR_KEY],
            |row| row.get::<_, String>(0),
        )
        .optional()?
        .map(|value| value.parse::<u64>().context("agent projection journal cursor is invalid"))
        .transpose()
}

fn agent_projection_journal_candidate(connection: &Connection) -> anyhow::Result<Option<u64>> {
    connection
        .query_row(
            "SELECT value FROM meta WHERE key = ?1",
            [AGENT_PROJECTION_JOURNAL_CANDIDATE_KEY],
            |row| row.get::<_, String>(0),
        )
        .optional()?
        .map(|value| {
            value.parse::<u64>().context("agent projection journal candidate sequence is invalid")
        })
        .transpose()
}

fn store_agent_projection_journal_cursor(
    transaction: &Transaction<'_>,
    sequence: u64,
) -> anyhow::Result<()> {
    transaction.execute(
        "INSERT INTO meta(key, value) VALUES(?1, ?2)
         ON CONFLICT(key) DO UPDATE SET value = excluded.value",
        params![AGENT_PROJECTION_JOURNAL_CURSOR_KEY, sequence.to_string()],
    )?;
    Ok(())
}

pub(super) fn advance_agent_projection_journal_cursor(
    transaction: &Transaction<'_>,
    sequence: u64,
) -> anyhow::Result<()> {
    let Some(applied_sequence) = agent_projection_journal_cursor(transaction)? else {
        return Ok(());
    };
    anyhow::ensure!(
        sequence >= applied_sequence,
        "agent projection journal cursor cannot move backwards from {applied_sequence} to {sequence}"
    );
    store_agent_projection_journal_cursor(transaction, sequence)
}

pub(super) fn note_agent_projection_journal_candidate(
    transaction: &Transaction<'_>,
    sequence: u64,
) -> anyhow::Result<()> {
    let current = agent_projection_journal_candidate(transaction)?.unwrap_or(0);
    anyhow::ensure!(
        sequence >= current,
        "agent projection journal candidate sequence cannot move backwards from {current} to {sequence}"
    );
    transaction.execute(
        "INSERT INTO meta(key, value) VALUES(?1, ?2)
         ON CONFLICT(key) DO UPDATE SET value = excluded.value",
        params![AGENT_PROJECTION_JOURNAL_CANDIDATE_KEY, sequence.to_string()],
    )?;
    Ok(())
}

fn append_prejournal_projection_migration(
    transaction: &Transaction<'_>,
    projection: &AgentProjectionRow,
) -> anyhow::Result<u64> {
    let session_id = transaction.query_row(
        "SELECT value FROM meta WHERE key = 'session_public_id'",
        [],
        |row| row.get::<_, String>(0),
    )?;
    let digest = Sha256::digest(
        format!("{PREJOURNAL_MIGRATION_FORMAT}/{session_id}/{}", projection.terminal_id).as_bytes(),
    );
    let event_id = format!("event_agent_projection_migration_{}", encode_lower_hex(&digest));
    let producer =
        JournalProducer { kind: "migration".into(), id: PREJOURNAL_MIGRATION_PRODUCER_ID.into() };
    let subjects = vec![
        JournalSubject { kind: "session".into(), id: session_id },
        JournalSubject { kind: "terminal".into(), id: projection.terminal_id.to_string() },
    ];
    let result = projection
        .result
        .clone()
        .context("pre-journal agent projection omitted its exact public result")?;
    let payload = json!({
        "format":PREJOURNAL_MIGRATION_FORMAT,
        "result":result,
    });
    session_journal::append_journal_record(
        transaction,
        &session_journal::JournalAppend {
            event_id: &event_id,
            schema_version: 1,
            kind: "agent.report",
            class: JournalClass::State,
            replay: JournalReplayPolicy::Required,
            occurred_at_ms: projection.updated_at_ms,
            producer: &producer,
            authority: None,
            causation_id: None,
            correlation_id: Some(&event_id),
            causation_depth: 0,
            subjects: &subjects,
            sensitivity: JournalSensitivity::Sensitive,
            payload: &payload,
            content: None,
            resource_revision: None,
            previous_resource_revision: None,
        },
    )
}

fn agent_projections_from_legacy_agent_index(
    connection: &Connection,
    stored_by_sequence: BTreeMap<u64, Vec<AgentProjectionRow>>,
) -> anyhow::Result<BTreeMap<String, AgentProjectionRow>> {
    let mut statement = connection.prepare(
        "SELECT sequence
         FROM journal_event_index
         WHERE sequence > ?1
           AND event_id >= ?2 AND event_id < ?3
         ORDER BY sequence ASC
         LIMIT 1024",
    )?;
    let mut projections = BTreeMap::new();
    let mut stored_by_sequence = stored_by_sequence;
    let mut sequence = 0_u64;
    loop {
        let sequences = statement
            .query_map(
                params![
                    i64::try_from(sequence).context("legacy agent cursor exceeds SQLite range")?,
                    LEGACY_AGENT_EVENT_ID_LOWER_BOUND,
                    LEGACY_AGENT_EVENT_ID_UPPER_BOUND,
                ],
                |row| row.get::<_, i64>(0),
            )?
            .map(|sequence| {
                u64::try_from(sequence?).context("legacy agent journal sequence is negative")
            })
            .collect::<anyhow::Result<Vec<_>>>()?;
        let Some(last_sequence) = sequences.last().copied() else {
            break;
        };
        sequence = last_sequence;
        for record in session_journal::query_session_journal_sequences(connection, &sequences)? {
            while stored_by_sequence
                .first_key_value()
                .is_some_and(|(stored_sequence, _)| *stored_sequence < record.sequence)
            {
                let (_, stored) = stored_by_sequence.pop_first().context(
                    "stored agent projection sequence disappeared during legacy migration",
                )?;
                for projection in stored {
                    merge_projection_candidate(&mut projections, projection);
                }
            }
            if let Some(next) = projection_from_journal_record(
                record.sequence,
                &record.kind,
                record.occurred_at_ms,
                &record.producer,
                &record.subjects,
                &record.payload,
                record.resource_revision,
            )? {
                merge_projection_candidate(&mut projections, next);
            }
            if let Some(stored) = stored_by_sequence.remove(&record.sequence) {
                for projection in stored {
                    merge_projection_candidate(&mut projections, projection);
                }
            }
        }
    }
    for (_, stored) in stored_by_sequence {
        for projection in stored {
            merge_projection_candidate(&mut projections, projection);
        }
    }
    Ok(projections)
}

fn merge_projection_candidate(
    projections: &mut BTreeMap<String, AgentProjectionRow>,
    next: AgentProjectionRow,
) {
    let key = next.terminal_id.to_string();
    let current = projections.remove(&key);
    projections.insert(key, merge_projection(current, next));
}

fn stored_projection_journal_sequence(
    connection: &Connection,
    stored: &AgentProjectionRow,
    head_sequence: u64,
) -> anyhow::Result<Option<u64>> {
    let resource_revision = i64::try_from(stored.committed_sequence)
        .context("stored agent projection revision exceeds SQLite range")?;
    let resource_sequence = connection
        .query_row(
            "SELECT sequence FROM journal_event_index WHERE resource_revision = ?1",
            [resource_revision],
            |row| row.get::<_, i64>(0),
        )
        .optional()?
        .map(u64::try_from)
        .transpose()
        .context("stored agent projection journal sequence is negative")?;
    let mut candidates = resource_sequence.into_iter().collect::<Vec<_>>();
    if stored.committed_sequence <= head_sequence
        && !candidates.contains(&stored.committed_sequence)
    {
        candidates.push(stored.committed_sequence);
    }
    for sequence in candidates {
        let record = session_journal::query_session_journal_sequences(connection, &[sequence])?
            .pop()
            .context("stored agent projection journal record disappeared")?;
        let Some(projected) = projection_from_journal_record(
            record.sequence,
            &record.kind,
            record.occurred_at_ms,
            &record.producer,
            &record.subjects,
            &record.payload,
            record.resource_revision,
        )?
        else {
            continue;
        };
        if projected.terminal_id == stored.terminal_id && projected.result == stored.result {
            return Ok(Some(sequence));
        }
    }
    Ok(None)
}

fn projection_from_journal_record(
    sequence: u64,
    kind: &str,
    occurred_at_ms: u64,
    producer: &JournalProducer,
    subjects: &[JournalSubject],
    payload: &Value,
    resource_revision: Option<u64>,
) -> anyhow::Result<Option<AgentProjectionRow>> {
    if kind == "agent.report" {
        let trusted_resource_operation =
            producer.kind == "resource_operation" && resource_revision.is_some();
        let trusted_migration = producer.kind == "migration"
            && producer.id == PREJOURNAL_MIGRATION_PRODUCER_ID
            && resource_revision.is_none()
            && payload.get("format").and_then(Value::as_str) == Some(PREJOURNAL_MIGRATION_FORMAT);
        if !trusted_resource_operation && !trusted_migration {
            return Ok(None);
        }
        return projection_from_resource_report(sequence, payload);
    }
    if kind == "agent.session.interrupted"
        && producer.kind == "recovery_policy"
        && producer.id == RECOVERY_PRODUCER_ID
        && resource_revision.is_none()
    {
        return projection_from_recovery_event(sequence, occurred_at_ms, subjects, payload);
    }
    if producer.kind != "agent_adapter" || producer.id != crate::AGENT_HOOK_PRODUCER_ID {
        return Ok(None);
    }
    if hook_projection_is_nested_agent(payload) {
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
        result: None,
        begins_session: kind == "agent.session.started",
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
    let begins_session = false;
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
        result: Some(Value::Object(result.clone())),
        begins_session,
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
        result: None,
        begins_session: false,
    }))
}

fn hook_projection_state(kind: &str, payload: &Value) -> Option<&'static str> {
    let native_event =
        payload.get("native_event").and_then(Value::as_str).map(lifecycle_key).unwrap_or_default();
    match native_event.as_str() {
        "sessionshutdown" | "agentsettled" | "agentend" => return Some("done"),
        "sessionstart" => return Some("idle"),
        "beforeagentstart"
        | "agentstart"
        | "turnstart"
        | "pretooluse"
        | "beforetool"
        | "beforeshellexecution"
        | "beforemcpexecution"
        | "beforereadfile"
        | "posttooluse"
        | "aftertool"
        | "aftershellexecution"
        | "aftermcpexecution"
        | "afterfileedit" => return Some("working"),
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

fn hook_projection_is_nested_agent(payload: &Value) -> bool {
    let Some(normalized) = payload.get("normalized").and_then(Value::as_object) else {
        return false;
    };
    normalized.get("agent_depth").and_then(Value::as_u64).is_some_and(|depth| depth > 0)
        || normalized.get("parent_agent_node_id").is_some()
        || normalized
            .get("agent_relation")
            .and_then(Value::as_str)
            .is_some_and(|relation| relation != "root")
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
    let Some(current) = current else {
        return next;
    };
    let same_verified_identity = current.source_session.is_some()
        && current.source_session == next.source_session
        && current.provider.is_some()
        && current.provider == next.provider;
    if same_verified_identity {
        if current.source == "hook" && next.source == "socket" {
            if matches!(next.state.as_str(), "done" | "interrupted") {
                return next;
            }
            return current;
        }
        if matches!(current.state.as_str(), "done" | "interrupted") {
            return current;
        }
        return next;
    }
    let current_is_final = matches!(current.state.as_str(), "done" | "interrupted");
    let next_is_active = matches!(next.state.as_str(), "working" | "blocked" | "idle");
    let newer_socket_activity =
        next.source == "socket" && next_is_active && next.updated_at_ms > current.updated_at_ms;
    if next.begins_session
        || (current_is_final && next_is_active)
        || newer_socket_activity
        || current.source_session.is_none()
    {
        return next;
    }
    current
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
    let session_id = SessionPublicId::parse(transaction.query_row(
        "SELECT value FROM meta WHERE key = 'session_public_id'",
        [],
        |row| row.get::<_, String>(0),
    )?)?;
    super::public_projection_store::decode_agent_projection(
        &result_json,
        terminal_id,
        &session_id,
        committed_sequence,
    )?;
    let committed_sequence =
        u64::try_from(committed_sequence).context("agent projection revision is negative")?;
    projection_from_resource_report(committed_sequence, &json!({"result":result}))
}

fn stored_live_projections(
    transaction: &Transaction<'_>,
) -> anyhow::Result<Vec<AgentProjectionRow>> {
    let terminal_ids = {
        let mut statement = transaction.prepare(
            "SELECT projection.terminal_id
             FROM resource_agent_projections projection
             JOIN resource_terminals terminal
               ON terminal.public_id = projection.terminal_id
             WHERE terminal.deleted_revision IS NULL
             ORDER BY projection.terminal_id ASC",
        )?;
        statement.query_map([], |row| row.get::<_, String>(0))?.collect::<Result<Vec<_>, _>>()?
    };
    terminal_ids
        .into_iter()
        .map(|terminal_id| {
            let terminal_id = TerminalPublicId::parse(terminal_id)?;
            stored_projection(transaction, &terminal_id)?.with_context(|| {
                format!("agent projection for live terminal {terminal_id} disappeared")
            })
        })
        .collect()
}

fn upsert_projection(
    transaction: &Transaction<'_>,
    projection: &AgentProjectionRow,
) -> anyhow::Result<()> {
    let value = match &projection.result {
        Some(result) => result.clone(),
        None => projection_result_value(transaction, projection)?,
    };
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

fn projection_result_value(
    transaction: &Transaction<'_>,
    projection: &AgentProjectionRow,
) -> anyhow::Result<Value> {
    let session_id = transaction.query_row(
        "SELECT value FROM meta WHERE key = 'session_public_id'",
        [],
        |row| row.get::<_, String>(0),
    )?;
    let agent_id = agent_id(&projection.terminal_id)?;
    Ok(json!({
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
    }))
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
    let payload = encode_lower_hex(&digest[..16]);
    AgentPublicId::parse(format!("agent_{payload}")).map_err(Into::into)
}

fn encode_lower_hex(bytes: &[u8]) -> String {
    const DIGITS: &[u8; 16] = b"0123456789abcdef";
    let mut encoded = String::with_capacity(bytes.len() * 2);
    for &byte in bytes {
        encoded.push(char::from(DIGITS[usize::from(byte >> 4)]));
        encoded.push(char::from(DIGITS[usize::from(byte & 0x0f)]));
    }
    encoded
}
