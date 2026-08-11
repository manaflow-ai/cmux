use super::*;

use crate::resource::AgentPublicId;
use serde_json::{Value, json};
use sha2::{Digest, Sha256};

const RECOVERY_FORMAT: &str = "cmux.agent-recovery.v1";
const RECOVERY_PRODUCER_ID: &str = "agent-recovery-v1";
const PREJOURNAL_MIGRATION_FORMAT: &str = "cmux.agent-projection-migration.v1";
const PREJOURNAL_MIGRATION_PRODUCER_ID: &str = "agent-projection-v1";
const AGENT_PROJECTION_JOURNAL_CURSOR_KEY: &str = "agent_projection_journal_sequence_v1";
const AGENT_PROJECTION_JOURNAL_CANDIDATE_KEY: &str =
    "agent_projection_journal_candidate_sequence_v1";
const AGENT_PROJECTION_JOURNAL_REBUILD_TARGET_KEY: &str =
    "agent_projection_journal_rebuild_target_sequence_v1";
const AGENT_PROJECTION_PREJOURNAL_MIGRATION_CURSOR_KEY: &str =
    "agent_projection_prejournal_migration_terminal_v1";
const UNKNOWN_AGENT_PROVIDER_GENERATION_KEY: &str = "";
const AGENT_PROJECTION_PREJOURNAL_MIGRATION_PAGE_SIZE: usize = 64;
const AGENT_PROJECTION_JOURNAL_REBUILD_PAGE_SIZE: usize = 1_024;
const AGENT_SESSION_GENERATION_RETENTION: usize = 64;

#[derive(Debug, Clone, PartialEq, Eq)]
struct AgentProjectionRow {
    terminal_id: TerminalPublicId,
    state: String,
    source: String,
    updated_at_ms: u64,
    source_session: Option<String>,
    provider: Option<String>,
    turn_id: Option<String>,
    committed_sequence: u64,
    result: Option<Value>,
    begins_session: bool,
    begins_turn: bool,
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
    rebuilding_generation_history: bool,
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
    // The append and candidate are already durable. Leave projection work for
    // ordered replay instead of rejecting a live event during a bounded rebuild.
    if !rebuilding_generation_history && agent_projection_rebuild_active(transaction)? {
        return Ok(());
    }
    let current = stored_projection(transaction, &next.terminal_id)?;
    validate_projection_transition(current.as_ref(), &next)?;
    let selected = merge_projection(current.clone(), next.clone());
    upsert_projection(transaction, &selected)?;
    if selected.committed_sequence == next.committed_sequence {
        record_agent_session_generation(
            transaction,
            current.as_ref(),
            &next,
            rebuilding_generation_history,
        )?;
    } else if rebuilding_generation_history {
        record_superseded_agent_session_generation(transaction, &next)?;
    }
    if advances_cursor {
        advance_agent_projection_journal_cursor(transaction, sequence)?;
    }
    Ok(())
}

fn validate_projection_transition(
    current: Option<&AgentProjectionRow>,
    next: &AgentProjectionRow,
) -> anyhow::Result<()> {
    if next.source != "socket" {
        return Ok(());
    }
    let Some(current) = current else {
        return Ok(());
    };
    if next.committed_sequence < current.committed_sequence {
        return Ok(());
    }
    let current_is_active = matches!(current.state.as_str(), "working" | "blocked" | "idle");
    let conflicting_structured_identity = current.source_session.is_some()
        && next.source_session.is_some()
        && (current.source_session != next.source_session
            || current.provider.is_some()
                && next.provider.is_some()
                && current.provider != next.provider);
    anyhow::ensure!(
        current.source != "hook"
            || next.source != "socket"
            || !current_is_active
            || !conflicting_structured_identity,
        "agent socket report session {:?} conflicts with active hook session {:?}",
        next.source_session,
        current.source_session
    );
    anyhow::ensure!(
        current.source != "socket"
            || next.source != "socket"
            || !current_is_active
            || !conflicting_structured_identity,
        "agent socket report session {:?} conflicts with active socket session {:?}",
        next.source_session,
        current.source_session
    );
    Ok(())
}

/// Keep accepted structured sessions in the same transaction as their journal
/// projection. A retired identity must stay retired after the current session
/// becomes final and after the registry reopens.
fn record_agent_session_generation(
    transaction: &Transaction<'_>,
    current: Option<&AgentProjectionRow>,
    next: &AgentProjectionRow,
    rebuilding_generation_history: bool,
) -> anyhow::Result<()> {
    let Some(source_session) = next.source_session.as_deref() else {
        return Ok(());
    };
    let provider = agent_generation_provider(next.provider.as_deref());
    let journal_identity =
        ensure_agent_session_journal_identity(transaction, next, provider, source_session)?;
    let existing = transaction
        .query_row(
            "SELECT generation, superseded
             FROM resource_agent_session_generations
             WHERE terminal_id = ?1 AND provider = ?2 AND source_session = ?3",
            params![next.terminal_id.as_str(), provider, source_session],
            |row| Ok((row.get::<_, i64>(0)?, row.get::<_, bool>(1)?)),
        )
        .optional()?;
    let active = transaction
        .query_row(
            "SELECT provider, source_session, generation
             FROM resource_agent_session_generations
             WHERE terminal_id = ?1 AND superseded = 0",
            [next.terminal_id.as_str()],
            |row| Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?, row.get::<_, i64>(2)?)),
        )
        .optional()?;
    if let Some((generation, superseded)) = existing {
        transaction.execute(
            "UPDATE resource_agent_session_generations
             SET journal_identity = COALESCE(journal_identity, ?4)
             WHERE terminal_id = ?1 AND provider = ?2 AND source_session = ?3",
            params![next.terminal_id.as_str(), provider, source_session, journal_identity],
        )?;
        anyhow::ensure!(generation > 0, "agent session generation is not positive");
        if superseded {
            if rebuilding_generation_history {
                if let Some((active_provider, active_session, active_generation)) = &active {
                    anyhow::ensure!(
                        *active_generation > 0,
                        "active agent session generation is not positive"
                    );
                    transaction.execute(
                        "UPDATE resource_agent_session_generations
                         SET superseded = 1
                         WHERE terminal_id = ?1 AND provider = ?2
                           AND source_session = ?3 AND superseded = 0",
                        params![next.terminal_id.as_str(), active_provider, active_session],
                    )?;
                }
                let reactivated = transaction.execute(
                    "UPDATE resource_agent_session_generations
                     SET superseded = 0
                     WHERE terminal_id = ?1 AND provider = ?2
                       AND source_session = ?3 AND superseded = 1",
                    params![next.terminal_id.as_str(), provider, source_session],
                )?;
                anyhow::ensure!(reactivated == 1, "replayed agent generation disappeared");
                return Ok(());
            }
            let active_source = current
                .filter(|projection| {
                    active.as_ref().is_some_and(|(provider, session, _)| {
                        agent_generation_provider(projection.provider.as_deref())
                            == provider.as_str()
                            && projection.source_session.as_deref() == Some(session.as_str())
                    })
                })
                .map(|projection| projection.source.as_str())
                .unwrap_or("agent");
            anyhow::bail!(
                "agent {} report session {:?} conflicts with active {} session {:?}: session belongs to superseded generation {generation}",
                next.source,
                next.source_session,
                active_source,
                active.as_ref().map(|(_, session, _)| session),
            );
        }
        anyhow::ensure!(
            active.as_ref().is_some_and(|(active_provider, session, active_generation)| {
                active_provider.as_str() == provider
                    && session == source_session
                    && *active_generation == generation
            }),
            "current agent session generation is inconsistent"
        );
        return Ok(());
    }

    if !rebuilding_generation_history
        && agent_session_identity_precedes_record(
            transaction,
            &journal_identity,
            next.committed_sequence,
        )?
    {
        anyhow::bail!(
            "agent {} report session {:?} belongs to a compacted superseded generation",
            next.source,
            next.source_session,
        );
    }

    if let Some((active_provider, active_session, active_generation)) = active {
        anyhow::ensure!(active_generation > 0, "active agent session generation is not positive");
        transaction.execute(
            "UPDATE resource_agent_session_generations
                 SET superseded = 1
                 WHERE terminal_id = ?1 AND provider = ?2
                   AND source_session = ?3 AND superseded = 0",
            params![next.terminal_id.as_str(), active_provider, active_session],
        )?;
    }
    let generation = next_agent_session_generation(transaction, &next.terminal_id)?;
    transaction.execute(
        "INSERT INTO resource_agent_session_generations(
           terminal_id, provider, source_session, generation, superseded, journal_identity
         ) VALUES(?1, ?2, ?3, ?4, 0, ?5)",
        params![next.terminal_id.as_str(), provider, source_session, generation, journal_identity,],
    )?;
    if !rebuilding_generation_history {
        compact_agent_session_generations(transaction, Some(&next.terminal_id))?;
    }
    Ok(())
}

/// A missing provider is one explicit legacy namespace. It never aliases a
/// named provider, but missing-provider reports still fence each other.
fn agent_generation_provider(provider: Option<&str>) -> &str {
    provider.unwrap_or(UNKNOWN_AGENT_PROVIDER_GENERATION_KEY)
}

fn next_agent_session_generation(
    transaction: &Transaction<'_>,
    terminal_id: &TerminalPublicId,
) -> anyhow::Result<i64> {
    let maximum = transaction.query_row(
        "SELECT COALESCE(MAX(generation), 0)
         FROM resource_agent_session_generations
         WHERE terminal_id = ?1",
        [terminal_id.as_str()],
        |row| row.get::<_, i64>(0),
    )?;
    maximum.checked_add(1).context("agent session generation exhausted")
}

fn agent_session_identity_precedes_record(
    transaction: &Transaction<'_>,
    journal_identity: &str,
    committed_sequence: u64,
) -> anyhow::Result<bool> {
    let committed_sequence =
        i64::try_from(committed_sequence).context("agent journal sequence exceeds SQLite range")?;
    transaction
        .query_row(
            "SELECT EXISTS(
               SELECT 1 FROM journal_subject_index
               WHERE kind = 'agent_session' AND id = ?1 AND sequence < ?2
             )",
            params![journal_identity, committed_sequence],
            |row| row.get::<_, bool>(0),
        )
        .map_err(Into::into)
}

fn ensure_agent_session_journal_identity(
    transaction: &Transaction<'_>,
    next: &AgentProjectionRow,
    provider: &str,
    source_session: &str,
) -> anyhow::Result<String> {
    let subject = crate::agent_hooks::agent_session_subject(
        next.terminal_id.as_str(),
        provider,
        source_session,
    );
    let sequence = i64::try_from(next.committed_sequence)
        .context("agent journal sequence exceeds SQLite range")?;
    transaction.execute(
        "INSERT OR IGNORE INTO journal_subject_index(sequence, kind, id)
         VALUES(?1, ?2, ?3)",
        params![sequence, subject.kind.as_str(), subject.id.as_str()],
    )?;
    Ok(subject.id)
}

fn compact_agent_session_generations(
    transaction: &Transaction<'_>,
    terminal_id: Option<&TerminalPublicId>,
) -> anyhow::Result<()> {
    let retention = i64::try_from(AGENT_SESSION_GENERATION_RETENTION)?;
    if let Some(terminal_id) = terminal_id {
        transaction.execute(
            "DELETE FROM resource_agent_session_generations
             WHERE terminal_id = ?1
               AND superseded = 1
               AND journal_identity IS NOT NULL
               AND generation <= COALESCE((
                 SELECT generation
                 FROM resource_agent_session_generations
                 WHERE terminal_id = ?1
                   AND superseded = 1
                   AND journal_identity IS NOT NULL
                 ORDER BY generation DESC
                 LIMIT 1 OFFSET ?2
               ), 0)",
            params![terminal_id.as_str(), retention],
        )?;
    } else {
        transaction.execute(
            "DELETE FROM resource_agent_session_generations
             WHERE rowid IN (
               SELECT rowid FROM (
                 SELECT rowid,
                        ROW_NUMBER() OVER (
                          PARTITION BY terminal_id ORDER BY generation DESC
                        ) AS retained_rank
                 FROM resource_agent_session_generations
                 WHERE superseded = 1 AND journal_identity IS NOT NULL
               )
               WHERE retained_rank > ?1
             )",
            [retention],
        )?;
    }
    Ok(())
}

fn record_superseded_agent_session_generation(
    transaction: &Transaction<'_>,
    next: &AgentProjectionRow,
) -> anyhow::Result<()> {
    let Some(source_session) = next.source_session.as_deref() else {
        return Ok(());
    };
    let provider = agent_generation_provider(next.provider.as_deref());
    let journal_identity =
        ensure_agent_session_journal_identity(transaction, next, provider, source_session)?;
    let exists = transaction.query_row(
        "SELECT EXISTS(
           SELECT 1 FROM resource_agent_session_generations
           WHERE terminal_id = ?1 AND provider = ?2 AND source_session = ?3
         )",
        params![next.terminal_id.as_str(), provider, source_session],
        |row| row.get::<_, bool>(0),
    )?;
    if exists {
        transaction.execute(
            "UPDATE resource_agent_session_generations
             SET journal_identity = COALESCE(journal_identity, ?4)
             WHERE terminal_id = ?1 AND provider = ?2 AND source_session = ?3",
            params![next.terminal_id.as_str(), provider, source_session, journal_identity],
        )?;
        return Ok(());
    }
    let generation = next_agent_session_generation(transaction, &next.terminal_id)?;
    transaction.execute(
        "INSERT INTO resource_agent_session_generations(
           terminal_id, provider, source_session, generation, superseded, journal_identity
         ) VALUES(?1, ?2, ?3, ?4, 1, ?5)",
        params![next.terminal_id.as_str(), provider, source_session, generation, journal_identity,],
    )?;
    Ok(())
}

pub(super) fn rebuild_agent_projections_from_journal(
    connection: &Connection,
    allow_archived_kind_backfill: bool,
) -> anyhow::Result<()> {
    let tx = connection.unchecked_transaction()?;
    let mut sequence = agent_projection_journal_cursor(&tx)?;
    if sequence.is_none() && prejournal_projection_migration_cursor(&tx)?.is_none() {
        initialize_prejournal_projection_migration(&tx)?;
    }
    if prejournal_projection_migration_cursor(&tx)?.is_some() {
        if !migrate_prejournal_projections_page(&tx)? {
            tx.commit()?;
            return Ok(());
        }
        store_agent_projection_journal_cursor(&tx, 0)?;
        sequence = Some(0);
    }

    let sequence = sequence.context("agent projection journal cursor was not initialized")?;
    let head_sequence = session_journal::session_journal_head(&tx)?;
    let candidate = match agent_projection_journal_candidate(&tx)? {
        Some(candidate) => candidate,
        None => {
            note_agent_projection_journal_candidate(&tx, head_sequence)?;
            head_sequence
        }
    };
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
        clear_agent_projection_journal_rebuild_target(&tx)?;
    } else {
        let target = match agent_projection_journal_rebuild_target(&tx)? {
            Some(target) => target,
            None => {
                store_agent_projection_journal_rebuild_target(&tx, candidate)?;
                candidate
            }
        };
        anyhow::ensure!(
            sequence < target && target <= head_sequence,
            "agent projection journal rebuild range {sequence}..={target} is invalid for head {head_sequence}"
        );
        replay_agent_projection_journal_page(&tx, sequence, target, allow_archived_kind_backfill)?;
    }
    if !agent_projection_rebuild_active(&tx)? {
        compact_agent_session_generations(&tx, None)?;
    }
    tx.commit()?;
    Ok(())
}

impl WorkspaceRegistry {
    pub(crate) fn agent_projection_rebuild_pending(&self) -> anyhow::Result<bool> {
        agent_projection_rebuild_active(&self.connection)
    }

    pub(crate) fn continue_agent_projection_rebuild(&self) -> anyhow::Result<bool> {
        rebuild_agent_projections_from_journal(&self.connection, true)?;
        Ok(!self.agent_projection_rebuild_pending()?)
    }

    #[cfg(test)]
    pub(crate) fn hold_agent_projection_rebuild_for_test(&mut self) -> anyhow::Result<()> {
        let transaction = self.connection.transaction()?;
        let head = session_journal::session_journal_head(&transaction)?;
        store_agent_projection_journal_rebuild_target(&transaction, head)?;
        transaction.commit()?;
        Ok(())
    }
}

fn agent_projection_rebuild_active(connection: &Connection) -> anyhow::Result<bool> {
    Ok(prejournal_projection_migration_cursor(connection)?.is_some()
        || agent_projection_journal_rebuild_target(connection)?.is_some())
}

fn replay_agent_projection_journal_page(
    transaction: &Transaction<'_>,
    sequence: u64,
    target_sequence: u64,
    allow_archived_kind_backfill: bool,
) -> anyhow::Result<()> {
    if !session_journal::backfill_journal_event_index_kinds_page(
        transaction,
        AGENT_PROJECTION_JOURNAL_REBUILD_PAGE_SIZE,
        allow_archived_kind_backfill,
    )? {
        return Ok(());
    }
    let projection_sequences = {
        let mut statement = transaction.prepare(
            "SELECT sequence
             FROM journal_event_index INDEXED BY journal_event_index_by_agent_sequence
             WHERE kind >= 'agent.' AND kind < 'agent/'
               AND sequence > ?1 AND sequence <= ?2
             ORDER BY sequence ASC
             LIMIT ?3",
        )?;
        let rows = statement.query_map(
            params![
                i64::try_from(sequence).context("agent rebuild cursor exceeds SQLite range")?,
                i64::try_from(target_sequence)
                    .context("agent rebuild target exceeds SQLite range")?,
                i64::try_from(AGENT_PROJECTION_JOURNAL_REBUILD_PAGE_SIZE)
                    .context("agent rebuild page size exceeds SQLite range")?,
            ],
            |row| row.get::<_, i64>(0),
        )?;
        rows.map(|row| u64::try_from(row?).context("agent rebuild sequence is negative"))
            .collect::<anyhow::Result<Vec<_>>>()?
    };
    let last_sequence = projection_sequences.last().copied();
    let page_is_full = projection_sequences.len() == AGENT_PROJECTION_JOURNAL_REBUILD_PAGE_SIZE;
    for record in
        session_journal::query_session_journal_sequences(transaction, &projection_sequences)?
    {
        if !record.kind.starts_with("agent.") {
            continue;
        }
        apply_agent_projection_journal_record(
            transaction,
            record.sequence,
            &record.kind,
            record.occurred_at_ms,
            &record.producer,
            &record.subjects,
            &record.payload,
            record.resource_revision,
            true,
        )?;
    }
    match last_sequence {
        Some(last_sequence) if page_is_full && last_sequence < target_sequence => {
            store_agent_projection_journal_cursor(transaction, last_sequence)?;
        }
        _ => {
            store_agent_projection_journal_cursor(transaction, target_sequence)?;
            // A live append can extend the candidate while this target is in
            // progress. Keep rebuild ownership until that newer prefix replays.
            if let Some(candidate) = agent_projection_journal_candidate(transaction)?
                && candidate > target_sequence
            {
                store_agent_projection_journal_rebuild_target(transaction, candidate)?;
            } else {
                clear_agent_projection_journal_rebuild_target(transaction)?;
            }
        }
    }
    Ok(())
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

fn agent_projection_journal_rebuild_target(connection: &Connection) -> anyhow::Result<Option<u64>> {
    connection
        .query_row(
            "SELECT value FROM meta WHERE key = ?1",
            [AGENT_PROJECTION_JOURNAL_REBUILD_TARGET_KEY],
            |row| row.get::<_, String>(0),
        )
        .optional()?
        .map(|value| {
            value.parse::<u64>().context("agent projection journal rebuild target is invalid")
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

fn store_agent_projection_journal_rebuild_target(
    transaction: &Transaction<'_>,
    sequence: u64,
) -> anyhow::Result<()> {
    transaction.execute(
        "INSERT INTO meta(key, value) VALUES(?1, ?2)
         ON CONFLICT(key) DO UPDATE SET value = excluded.value",
        params![AGENT_PROJECTION_JOURNAL_REBUILD_TARGET_KEY, sequence.to_string()],
    )?;
    Ok(())
}

fn clear_agent_projection_journal_rebuild_target(
    transaction: &Transaction<'_>,
) -> anyhow::Result<()> {
    transaction.execute(
        "DELETE FROM meta WHERE key = ?1",
        [AGENT_PROJECTION_JOURNAL_REBUILD_TARGET_KEY],
    )?;
    Ok(())
}

fn initialize_prejournal_projection_migration(transaction: &Transaction<'_>) -> anyhow::Result<()> {
    transaction.execute(
        "INSERT INTO meta(key, value) VALUES(?1, '')
         ON CONFLICT(key) DO NOTHING",
        [AGENT_PROJECTION_PREJOURNAL_MIGRATION_CURSOR_KEY],
    )?;
    Ok(())
}

fn prejournal_projection_migration_cursor(
    connection: &Connection,
) -> anyhow::Result<Option<String>> {
    let cursor = connection
        .query_row(
            "SELECT value FROM meta WHERE key = ?1",
            [AGENT_PROJECTION_PREJOURNAL_MIGRATION_CURSOR_KEY],
            |row| row.get::<_, String>(0),
        )
        .optional()?;
    cursor
        .map(|cursor| {
            if !cursor.is_empty() {
                TerminalPublicId::parse(cursor.clone())
                    .context("pre-journal projection migration cursor is invalid")?;
            }
            Ok(cursor)
        })
        .transpose()
}

fn migrate_prejournal_projections_page(transaction: &Transaction<'_>) -> anyhow::Result<bool> {
    let Some(after_terminal_id) = prejournal_projection_migration_cursor(transaction)? else {
        return Ok(true);
    };
    let original_head_sequence = session_journal::session_journal_head(transaction)?;
    let mut stored = stored_live_projections_after(
        transaction,
        &after_terminal_id,
        AGENT_PROJECTION_PREJOURNAL_MIGRATION_PAGE_SIZE.saturating_add(1),
    )?;
    let has_more = stored.len() > AGENT_PROJECTION_PREJOURNAL_MIGRATION_PAGE_SIZE;
    if has_more {
        stored.truncate(AGENT_PROJECTION_PREJOURNAL_MIGRATION_PAGE_SIZE);
    }
    for projection in &mut stored {
        projection.committed_sequence = match stored_projection_journal_sequence(
            transaction,
            projection,
            original_head_sequence,
        )? {
            Some(sequence) => sequence,
            None => append_prejournal_projection_migration(transaction, projection)?,
        };
        upsert_projection(transaction, projection)?;
    }
    if has_more {
        let terminal_id = stored
            .last()
            .context("pre-journal projection migration page was unexpectedly empty")?
            .terminal_id
            .as_str();
        transaction.execute(
            "UPDATE meta SET value = ?1 WHERE key = ?2",
            params![terminal_id, AGENT_PROJECTION_PREJOURNAL_MIGRATION_CURSOR_KEY],
        )?;
        return Ok(false);
    }
    transaction.execute(
        "DELETE FROM meta WHERE key = ?1",
        [AGENT_PROJECTION_PREJOURNAL_MIGRATION_CURSOR_KEY],
    )?;
    Ok(true)
}

pub(super) fn advance_agent_projection_journal_cursor(
    transaction: &Transaction<'_>,
    sequence: u64,
) -> anyhow::Result<()> {
    let Some(applied_sequence) = agent_projection_journal_cursor(transaction)? else {
        return Ok(());
    };
    if agent_projection_journal_rebuild_target(transaction)?
        .is_some_and(|target| applied_sequence < target && sequence > target)
    {
        return Ok(());
    }
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
    let mut subjects = vec![
        JournalSubject { kind: "session".into(), id: session_id },
        JournalSubject { kind: "terminal".into(), id: projection.terminal_id.to_string() },
    ];
    if let Some(source_session) = projection.source_session.as_deref() {
        subjects.push(crate::agent_hooks::agent_session_subject(
            projection.terminal_id.as_str(),
            agent_generation_provider(projection.provider.as_deref()),
            source_session,
        ));
    }
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
    let turn_id = normalized
        .and_then(|fields| fields.get("turn_id"))
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
        turn_id,
        committed_sequence: sequence,
        result: None,
        begins_session: kind == "agent.session.started",
        begins_turn: kind == "agent.turn.started",
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
    let extra = result.get("extra");
    let provider = extra
        .and_then(|extra| extra.get("provider"))
        .and_then(Value::as_str)
        .filter(|value| !value.is_empty())
        .map(str::to_string);
    let turn_id = extra
        .and_then(|extra| extra.get("turn_id"))
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
        turn_id,
        committed_sequence: sequence,
        result: Some(Value::Object(result.clone())),
        begins_session,
        begins_turn: false,
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
        turn_id: None,
        committed_sequence: sequence,
        result: None,
        begins_session: false,
        begins_turn: false,
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
    crate::agent_hooks::normalized_agent_is_nested(normalized)
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
    if next.committed_sequence < current.committed_sequence {
        return current;
    }
    if next.begins_session {
        if current.source_session.is_some() && next.source_session.is_none() {
            return current;
        }
        return next;
    }
    let different_structured_socket_session = current.source == "socket"
        && next.source == "socket"
        && current.source_session.is_some()
        && next.source_session.is_some()
        && current.source_session != next.source_session;
    if different_structured_socket_session {
        let current_is_final = matches!(current.state.as_str(), "done" | "interrupted");
        let next_is_active = matches!(next.state.as_str(), "working" | "blocked" | "idle");
        return if current_is_final && next_is_active { next } else { current };
    }
    let current_is_active = matches!(current.state.as_str(), "working" | "blocked" | "idle");
    if current_is_active && current.source != "hook" && next.source == "hook" {
        return next;
    }
    let same_session_identity = current.source_session.is_some()
        && current.source_session == next.source_session
        && current.provider == next.provider;
    if same_session_identity {
        let begins_new_structured_turn = next.begins_turn
            && current.turn_id.is_some()
            && next.turn_id.is_some()
            && current.turn_id != next.turn_id;
        if matches!(current.state.as_str(), "done" | "interrupted") && begins_new_structured_turn {
            return next;
        }
        if current.source == "hook" && next.source == "socket" {
            if matches!(next.state.as_str(), "done" | "interrupted") {
                return if next.updated_at_ms >= current.updated_at_ms { next } else { current };
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
    if current_is_final && next_is_active {
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
    public_projection_store::decode_agent_projection(
        &result_json,
        terminal_id,
        &session_id,
        committed_sequence,
    )?;
    let committed_sequence =
        u64::try_from(committed_sequence).context("agent projection revision is negative")?;
    projection_from_resource_report(committed_sequence, &json!({"result":result}))
}

fn stored_live_projections_after(
    transaction: &Transaction<'_>,
    after_terminal_id: &str,
    limit: usize,
) -> anyhow::Result<Vec<AgentProjectionRow>> {
    let terminal_ids = {
        let mut statement = transaction.prepare(
            "SELECT projection.terminal_id
             FROM resource_agent_projections projection
             JOIN resource_terminals terminal
               ON terminal.public_id = projection.terminal_id
             WHERE terminal.deleted_revision IS NULL
               AND projection.terminal_id > ?1
             ORDER BY projection.terminal_id ASC
             LIMIT ?2",
        )?;
        statement
            .query_map(
                params![
                    after_terminal_id,
                    i64::try_from(limit)
                        .context("agent projection migration limit exceeds SQLite")?,
                ],
                |row| row.get::<_, String>(0),
            )?
            .collect::<Result<Vec<_>, _>>()?
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
    let mut extra = json!({"provider":projection.provider});
    if let Some(turn_id) = &projection.turn_id {
        extra["turn_id"] = json!(turn_id);
    }
    Ok(json!({
        "id":agent_id,
        "session_id":session_id,
        "terminal_id":projection.terminal_id,
        "state":projection.state,
        "source":projection.source,
        "updated_at_ms":projection.updated_at_ms.to_string(),
        "source_session":projection.source_session,
        "extra":extra,
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
