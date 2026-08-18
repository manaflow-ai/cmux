use super::*;

use crate::resource::AgentPublicId;
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::collections::HashSet;

const RECOVERY_FORMAT: &str = "cmux.agent-recovery.v1";
const RECOVERY_PRODUCER_ID: &str = "agent-recovery-v1";
const PREJOURNAL_MIGRATION_FORMAT: &str = "cmux.agent-projection-migration.v1";
const PREJOURNAL_MIGRATION_PRODUCER_ID: &str = "agent-projection-v1";
const AGENT_PROJECTION_JOURNAL_CURSOR_KEY: &str = "agent_projection_journal_sequence_v1";
const AGENT_PROJECTION_JOURNAL_CANDIDATE_KEY: &str =
    "agent_projection_journal_candidate_sequence_v1";
const AGENT_PROJECTION_JOURNAL_REBUILD_TARGET_KEY: &str =
    "agent_projection_journal_rebuild_target_sequence_v1";
const AGENT_PROJECTION_JOURNAL_LIVE_SEQUENCE_KEY: &str =
    "agent_projection_journal_live_sequence_v1";
const AGENT_PROJECTION_PREJOURNAL_MIGRATION_CURSOR_KEY: &str =
    "agent_projection_prejournal_migration_terminal_v1";
const UNKNOWN_AGENT_PROVIDER_GENERATION_KEY: &str = "";
const AGENT_PROJECTION_PREJOURNAL_MIGRATION_PAGE_SIZE: usize = 64;
const AGENT_PROJECTION_JOURNAL_REBUILD_PAGE_SIZE: usize = 1_024;
const AGENT_SESSION_GENERATION_RETENTION: usize = 64;
// SQLite's default bind-variable limit is 999. Leave room for future fixed
// parameters while keeping reduced-state terminal validation set-based.
const REDUCED_AGENT_TERMINAL_VALIDATION_BATCH_SIZE: usize = 900;

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

pub(super) struct AgentProjectionJournalInput<'a> {
    pub(super) sequence: u64,
    pub(super) kind: &'a str,
    pub(super) occurred_at_ms: u64,
    pub(super) producer: &'a JournalProducer,
    pub(super) subjects: &'a [JournalSubject],
    pub(super) payload: &'a Value,
    pub(super) resource_revision: Option<u64>,
    pub(super) rebuilding_generation_history: bool,
    pub(super) replaying_projection_journal: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct AgentProjectionRebuildStep {
    pub(crate) checkpoint_ready: bool,
    pub(crate) pending: bool,
    pub(crate) refresh_required: bool,
}

pub(crate) struct AgentProjectionRebuildChangePage {
    pub(crate) projections: Vec<RegistryAgentProjection>,
    pub(crate) last_terminal_id: Option<TerminalPublicId>,
    pub(crate) complete: bool,
}

pub(super) fn apply_agent_projection_journal_record(
    transaction: &Transaction<'_>,
    input: AgentProjectionJournalInput<'_>,
) -> anyhow::Result<Option<TerminalPublicId>> {
    let AgentProjectionJournalInput {
        sequence,
        kind,
        occurred_at_ms,
        producer,
        subjects,
        payload,
        resource_revision,
        rebuilding_generation_history,
        replaying_projection_journal,
    } = input;
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
        return Ok(None);
    };
    if !terminal_is_live(transaction, &next.terminal_id)? {
        if advances_cursor {
            advance_agent_projection_journal_cursor(transaction, sequence)?;
        }
        return Ok(None);
    }
    let current = stored_projection(transaction, &next.terminal_id)?;
    if replaying_projection_journal
        && !rebuilding_generation_history
        && deferred_live_agent_session_is_superseded(transaction, &next)?
    {
        if advances_cursor {
            advance_agent_projection_journal_cursor(transaction, sequence)?;
        }
        return Ok(None);
    }
    // Pre-journal and generation migration use the stored projections as their
    // baseline, so live events must keep those projections current. Ordered
    // journal replay instead owns a fixed historical prefix. Validate new
    // structured identities before commit, then leave their projection work
    // after the fixed prefix and remember where permissive history ends.
    if !replaying_projection_journal
        && !rebuilding_generation_history
        && agent_projection_journal_rebuild_target(transaction)?.is_some()
    {
        validate_deferred_projection_transition(transaction, current.as_ref(), &next)?;
        validate_deferred_agent_session_generation(transaction, current.as_ref(), &next)?;
        record_agent_session_generation(transaction, current.as_ref(), &next, false)?;
        note_agent_projection_journal_live_sequence(transaction, sequence)?;
        return Ok(None);
    }
    validate_projection_transition(current.as_ref(), &next)?;
    // A public/raw agent.report is the authoritative mutation path. Its
    // returned value is already committed to the resource journal, so a newer
    // hook report must not be discarded by the lifecycle merge rules used for
    // asynchronous hook events. Socket reports still pass the identity guard
    // above before reaching this branch.
    let selected = select_projection(current.clone(), next.clone());
    if replaying_projection_journal || agent_projection_rebuild_changes_pending(transaction)? {
        record_agent_projection_rebuild_change(transaction, &next.terminal_id)?;
    }
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
    Ok(Some(next.terminal_id))
}

fn select_projection(
    current: Option<AgentProjectionRow>,
    next: AgentProjectionRow,
) -> AgentProjectionRow {
    if next.source == "hook"
        && next.result.is_some()
        && current
            .as_ref()
            .is_none_or(|current| next.committed_sequence >= current.committed_sequence)
    {
        next
    } else {
        merge_projection(current, next)
    }
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
    anyhow::ensure!(
        !current_is_active
            || !matches!(current.source.as_str(), "hook" | "socket")
            || current.source_session.is_none()
            || next.source_session.is_some(),
        "agent socket report omits active {} session {:?}",
        current.source,
        current.source_session
    );
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

fn validate_deferred_projection_transition(
    transaction: &Transaction<'_>,
    current: Option<&AgentProjectionRow>,
    next: &AgentProjectionRow,
) -> anyhow::Result<()> {
    if next.source != "socket" {
        return Ok(());
    }
    let active = transaction
        .query_row(
            "SELECT provider, source_session
             FROM resource_agent_session_generations
             WHERE terminal_id = ?1 AND superseded = 0",
            [next.terminal_id.as_str()],
            |row| Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?)),
        )
        .optional()?;
    let Some((active_provider, active_session)) = active else {
        return validate_projection_transition(current, next);
    };
    let Some(next_session) = next.source_session.as_deref() else {
        anyhow::bail!("agent socket report omits active agent session {active_session:?}");
    };
    let next_provider = agent_generation_provider(next.provider.as_deref());
    anyhow::ensure!(
        active_provider == next_provider && active_session == next_session,
        "agent socket report session {:?} conflicts with active agent session {:?}",
        next.source_session,
        active_session,
    );
    Ok(())
}

fn validate_deferred_agent_session_generation(
    transaction: &Transaction<'_>,
    current: Option<&AgentProjectionRow>,
    next: &AgentProjectionRow,
) -> anyhow::Result<()> {
    let Some(source_session) = next.source_session.as_deref() else {
        return Ok(());
    };
    let provider = agent_generation_provider(next.provider.as_deref());
    let existing = transaction
        .query_row(
            "SELECT generation, superseded
             FROM resource_agent_session_generations
             WHERE terminal_id = ?1 AND provider = ?2 AND source_session = ?3",
            params![next.terminal_id.as_str(), provider, source_session],
            |row| Ok((row.get::<_, i64>(0)?, row.get::<_, bool>(1)?)),
        )
        .optional()?;
    if let Some((generation, superseded)) = existing {
        anyhow::ensure!(generation > 0, "agent session generation is not positive");
        if superseded {
            anyhow::bail!(
                "agent {} report session {:?} conflicts with active agent session {:?}: session belongs to superseded generation {generation}",
                next.source,
                next.source_session,
                current.and_then(|projection| projection.source_session.as_deref()),
            );
        }
        let active_matches = transaction.query_row(
            "SELECT EXISTS(
               SELECT 1 FROM resource_agent_session_generations
               WHERE terminal_id = ?1 AND provider = ?2 AND source_session = ?3
                 AND generation = ?4 AND superseded = 0
             )",
            params![next.terminal_id.as_str(), provider, source_session, generation],
            |row| row.get::<_, bool>(0),
        )?;
        anyhow::ensure!(active_matches, "current agent session generation is inconsistent");
        return Ok(());
    }

    let journal_identity =
        ensure_agent_session_journal_identity(transaction, next, provider, source_session)?;
    anyhow::ensure!(
        !agent_session_identity_precedes_deferred_live_boundary(
            transaction,
            &journal_identity,
            next.committed_sequence,
        )?,
        "agent {} report session {:?} belongs to a compacted superseded generation",
        next.source,
        next.source_session,
    );
    Ok(())
}

fn agent_session_identity_precedes_deferred_live_boundary(
    transaction: &Transaction<'_>,
    journal_identity: &str,
    committed_sequence: u64,
) -> anyhow::Result<bool> {
    // The first event accepted after the fixed replay prefix records this
    // boundary. Later events for that same live session are valid, while an
    // identity that existed before the boundary belongs to older history.
    let boundary =
        agent_projection_journal_live_sequence(transaction)?.unwrap_or(committed_sequence);
    agent_session_identity_precedes_record(transaction, journal_identity, boundary)
}

fn deferred_live_agent_session_is_superseded(
    transaction: &Transaction<'_>,
    next: &AgentProjectionRow,
) -> anyhow::Result<bool> {
    let Some(source_session) = next.source_session.as_deref() else {
        return Ok(false);
    };
    let Some(live_sequence) = agent_projection_journal_live_sequence(transaction)? else {
        return Ok(false);
    };
    let provider = agent_generation_provider(next.provider.as_deref());
    let superseded = transaction
        .query_row(
            "SELECT superseded
             FROM resource_agent_session_generations
             WHERE terminal_id = ?1 AND provider = ?2 AND source_session = ?3",
            params![next.terminal_id.as_str(), provider, source_session],
            |row| row.get::<_, bool>(0),
        )
        .optional()?
        .unwrap_or(false);
    if !superseded {
        return Ok(false);
    }
    let journal_identity = crate::agent_hooks::agent_session_subject(
        next.terminal_id.as_str(),
        provider,
        source_session,
    )
    .id;
    Ok(!agent_session_identity_precedes_record(transaction, &journal_identity, live_sequence)?)
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
    let preserve_deferred_live_active = rebuilding_generation_history
        && active_agent_session_started_in_deferred_live_tail(transaction, &next.terminal_id)?;
    if let Some((generation, superseded)) = existing {
        transaction.execute(
            "UPDATE resource_agent_session_generations
             SET journal_identity = COALESCE(journal_identity, ?4)
             WHERE terminal_id = ?1 AND provider = ?2 AND source_session = ?3",
            params![next.terminal_id.as_str(), provider, source_session, journal_identity],
        )?;
        anyhow::ensure!(generation > 0, "agent session generation is not positive");
        if superseded {
            if preserve_deferred_live_active {
                return Ok(());
            }
            let stored_current_matches = current.is_some_and(|projection| {
                agent_generation_provider(projection.provider.as_deref()) == provider
                    && projection.source_session.as_deref() == Some(source_session)
            });
            let restore_stored_current_during_backfill = !rebuilding_generation_history
                && stored_current_matches
                && resource_store::resource_agent_generation_backfill_pending(transaction)?;
            if rebuilding_generation_history || restore_stored_current_during_backfill {
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

    if preserve_deferred_live_active {
        return record_superseded_agent_session_generation(transaction, next);
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

fn active_agent_session_started_in_deferred_live_tail(
    transaction: &Transaction<'_>,
    terminal_id: &TerminalPublicId,
) -> anyhow::Result<bool> {
    let Some(live_sequence) = agent_projection_journal_live_sequence(transaction)? else {
        return Ok(false);
    };
    let live_sequence = i64::try_from(live_sequence)
        .context("agent projection live sequence exceeds SQLite range")?;
    transaction
        .query_row(
            "SELECT EXISTS(
               SELECT 1
               FROM resource_agent_session_generations AS generation
               WHERE generation.terminal_id = ?1
                 AND generation.superseded = 0
                 AND generation.journal_identity IS NOT NULL
                 AND EXISTS(
                   SELECT 1 FROM journal_subject_index AS live_subject
                   WHERE live_subject.kind = 'agent_session'
                     AND live_subject.id = generation.journal_identity
                     AND live_subject.sequence >= ?2
                 )
                 AND NOT EXISTS(
                   SELECT 1 FROM journal_subject_index AS historical_subject
                   WHERE historical_subject.kind = 'agent_session'
                     AND historical_subject.id = generation.journal_identity
                     AND historical_subject.sequence < ?2
                 )
             )",
            params![terminal_id.as_str(), live_sequence],
            |row| row.get::<_, bool>(0),
        )
        .map_err(Into::into)
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
) -> anyhow::Result<(bool, bool)> {
    let tx = connection.unchecked_transaction()?;
    if !resource_store::backfill_resource_agent_session_generations_page(&tx)? {
        tx.commit()?;
        return Ok((false, false));
    }
    let mut sequence = agent_projection_journal_cursor(&tx)?;
    if sequence.is_none() && prejournal_projection_migration_cursor(&tx)?.is_none() {
        initialize_prejournal_projection_migration(&tx)?;
    }
    if prejournal_projection_migration_cursor(&tx)?.is_some() {
        if !migrate_prejournal_projections_page(&tx)? {
            tx.commit()?;
            return Ok((false, false));
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
    let (checkpoint_ready, refresh_required) = if candidate <= sequence {
        store_agent_projection_journal_cursor(&tx, head_sequence)?;
        clear_agent_projection_journal_rebuild_target(&tx)?;
        if agent_projection_rebuild_changes_pending(&tx)? {
            (true, true)
        } else {
            clear_agent_projection_rebuild_changes(&tx)?;
            (true, false)
        }
    } else {
        let target = match agent_projection_journal_rebuild_target(&tx)? {
            Some(target) => target,
            None => {
                clear_agent_projection_rebuild_changes(&tx)?;
                store_agent_projection_journal_rebuild_target(&tx, candidate)?;
                candidate
            }
        };
        anyhow::ensure!(
            sequence < target && target <= head_sequence,
            "agent projection journal rebuild range {sequence}..={target} is invalid for head {head_sequence}"
        );
        replay_agent_projection_journal_page(&tx, sequence, target, allow_archived_kind_backfill)?
    };
    if !agent_projection_rebuild_active(&tx)? {
        compact_agent_session_generations(&tx, None)?;
        clear_agent_projection_journal_live_sequence(&tx)?;
    }
    tx.commit()?;
    Ok((checkpoint_ready, refresh_required))
}

impl WorkspaceRegistry {
    pub(crate) fn agent_projection_rebuild_pending(&self) -> anyhow::Result<bool> {
        agent_projection_rebuild_active(&self.connection)
    }

    #[cfg(test)]
    pub(crate) fn mark_agent_projection_rebuild_pending_for_test(&self) -> anyhow::Result<()> {
        self.connection.execute(
            "INSERT INTO meta(key, value) VALUES(?1, '1')
             ON CONFLICT(key) DO UPDATE SET value = excluded.value",
            [AGENT_PROJECTION_JOURNAL_REBUILD_TARGET_KEY],
        )?;
        Ok(())
    }

    /// Returns only derived projection progress. Journal rows are never
    /// changed by this inspection path.
    pub(crate) fn agent_projection_restore_status(&self) -> anyhow::Result<Value> {
        let cursor = agent_projection_journal_cursor(&self.connection)?;
        let candidate = agent_projection_journal_candidate(&self.connection)?;
        let target = agent_projection_journal_rebuild_target(&self.connection)?;
        let head = session_journal::session_journal_head(&self.connection)?;
        Ok(json!({
            "head_sequence": head.to_string(),
            "cursor_sequence": cursor.map(|value| value.to_string()),
            "candidate_sequence": candidate.map(|value| value.to_string()),
            "target_sequence": target.map(|value| value.to_string()),
            "pending": agent_projection_rebuild_active(&self.connection)?,
        }))
    }

    pub(super) fn agent_projection_restore_status_for_transaction(
        transaction: &Transaction<'_>,
    ) -> anyhow::Result<Value> {
        let cursor = agent_projection_journal_cursor(transaction)?;
        let candidate = agent_projection_journal_candidate(transaction)?;
        let target = agent_projection_journal_rebuild_target(transaction)?;
        let head = session_journal::session_journal_head(transaction)?;
        Ok(json!({
            "head_sequence": head.to_string(),
            "cursor_sequence": cursor.map(|value| value.to_string()),
            "candidate_sequence": candidate.map(|value| value.to_string()),
            "target_sequence": target.map(|value| value.to_string()),
            "pending": agent_projection_rebuild_active(transaction)?,
        }))
    }

    /// Validates the agent collection in a reduced journal state without
    /// changing any durable projection. Restore uses the reducer's public
    /// state, rather than replaying the live journal a second time, so this
    /// validation is part of the same checkpoint-specific plan as preview.
    pub(crate) fn validate_reduced_agent_state(
        &self,
        state: &Value,
        committed_revision: u64,
    ) -> anyhow::Result<Vec<RegistryAgentProjection>> {
        let values = reduced_agent_values(state, &self.session_id, committed_revision)?;
        validate_reduced_agent_terminals(&self.connection, &values)?;
        Ok(values.into_iter().map(|(_, _, projection)| projection).collect())
    }

    pub(crate) fn continue_agent_projection_rebuild_page(
        &self,
    ) -> anyhow::Result<AgentProjectionRebuildStep> {
        let (checkpoint_ready, refresh_required) =
            rebuild_agent_projections_from_journal(&self.connection, true)?;
        Ok(AgentProjectionRebuildStep {
            checkpoint_ready,
            pending: self.agent_projection_rebuild_pending()?,
            refresh_required,
        })
    }

    pub(crate) fn agent_projection_rebuild_change_page(
        &self,
        after_terminal_id: Option<&TerminalPublicId>,
    ) -> anyhow::Result<AgentProjectionRebuildChangePage> {
        let mut statement = self.connection.prepare(
            "SELECT projection.terminal_id,
                    projection.result_json,
                    projection.committed_revision
             FROM resource_agent_projection_rebuild_changes AS changed
             JOIN resource_agent_projections AS projection
               ON projection.terminal_id = changed.terminal_id
             JOIN resource_terminals AS terminal
               ON terminal.public_id = projection.terminal_id
             WHERE terminal.deleted_revision IS NULL
               AND (?1 IS NULL OR projection.terminal_id > ?1)
             ORDER BY projection.terminal_id ASC
             LIMIT ?2",
        )?;
        let mut rows = statement.query(params![
            after_terminal_id.map(TerminalPublicId::as_str),
            i64::try_from(AGENT_PROJECTION_JOURNAL_REBUILD_PAGE_SIZE)
                .context("agent projection refresh page exceeds SQLite")?,
        ])?;
        let mut projections = Vec::with_capacity(AGENT_PROJECTION_JOURNAL_REBUILD_PAGE_SIZE);
        while let Some(row) = rows.next()? {
            let terminal_id = TerminalPublicId::parse(row.get::<_, String>(0)?)?;
            let result_json = row.get::<_, String>(1)?;
            let committed_revision = row.get::<_, i64>(2)?;
            projections.push(public_projection_store::decode_agent_projection(
                &result_json,
                &terminal_id,
                &self.session_id,
                committed_revision,
            )?);
        }
        let complete = projections.len() < AGENT_PROJECTION_JOURNAL_REBUILD_PAGE_SIZE;
        let last_terminal_id = projections.last().map(|projection| projection.terminal_id.clone());
        Ok(AgentProjectionRebuildChangePage { projections, last_terminal_id, complete })
    }

    pub(crate) fn agent_projection_for_cache_refresh(
        &self,
        terminal_id: &TerminalPublicId,
    ) -> anyhow::Result<Option<RegistryAgentProjection>> {
        let stored = self
            .connection
            .query_row(
                "SELECT result_json, committed_revision
                 FROM resource_agent_projections
                 WHERE terminal_id = ?1",
                [terminal_id.as_str()],
                |row| Ok((row.get::<_, String>(0)?, row.get::<_, i64>(1)?)),
            )
            .optional()?;
        stored
            .map(|(result_json, committed_revision)| {
                public_projection_store::decode_agent_projection(
                    &result_json,
                    terminal_id,
                    &self.session_id,
                    committed_revision,
                )
            })
            .transpose()
    }

    pub(crate) fn clear_agent_projection_rebuild_changes(&self) -> anyhow::Result<()> {
        clear_agent_projection_rebuild_changes(&self.connection)
    }
}

/// Replaces the terminal-current compatibility projection with the agent
/// collection produced by a checkpoint reducer. The caller owns the SQLite
/// transaction and must have fenced the journal head and idempotency receipt
/// before invoking this function.
pub(super) fn replace_agent_projections_from_reduced_state(
    transaction: &Transaction<'_>,
    state: &Value,
    committed_revision: u64,
) -> anyhow::Result<Vec<RegistryAgentProjection>> {
    let session_id = SessionPublicId::parse(transaction.query_row(
        "SELECT value FROM meta WHERE key = 'session_public_id'",
        [],
        |row| row.get::<_, String>(0),
    )?)?;
    let values = reduced_agent_values(state, &session_id, committed_revision)?;
    let committed_revision =
        i64::try_from(committed_revision).context("agent projection revision exceeds SQLite")?;

    anyhow::ensure!(
        prejournal_projection_migration_cursor(transaction)?.is_none(),
        "agent projection migration is still pending"
    );
    if let Some(cursor) = agent_projection_journal_cursor(transaction)? {
        anyhow::ensure!(
            cursor <= u64::try_from(committed_revision)?,
            "agent projection cursor {cursor} is ahead of restore revision {committed_revision}"
        );
    }
    if let Some(candidate) = agent_projection_journal_candidate(transaction)? {
        anyhow::ensure!(
            candidate <= u64::try_from(committed_revision)?,
            "agent projection candidate {candidate} is ahead of restore revision {committed_revision}"
        );
    }
    validate_reduced_agent_terminals(transaction, &values)?;

    transaction.execute("DELETE FROM resource_agent_projection_rebuild_changes", [])?;
    transaction.execute("DELETE FROM resource_agent_projections", [])?;
    for (terminal_id, result_json, _) in &values {
        transaction.execute(
            "INSERT INTO resource_agent_projections(
               terminal_id, result_json, committed_revision
             ) VALUES(?1, ?2, ?3)",
            params![terminal_id.as_str(), result_json, committed_revision],
        )?;
    }
    store_agent_projection_journal_cursor(
        transaction,
        u64::try_from(committed_revision).context("agent projection revision is negative")?,
    )?;
    note_agent_projection_journal_candidate(
        transaction,
        u64::try_from(committed_revision).context("agent projection revision is negative")?,
    )?;
    clear_agent_projection_journal_rebuild_target(transaction)?;
    clear_agent_projection_journal_live_sequence(transaction)?;
    Ok(values.into_iter().map(|(_, _, projection)| projection).collect())
}

fn validate_reduced_agent_terminals(
    connection: &Connection,
    values: &[(TerminalPublicId, String, RegistryAgentProjection)],
) -> anyhow::Result<()> {
    let mut live_terminal_ids = HashSet::with_capacity(values.len());
    for batch in values.chunks(REDUCED_AGENT_TERMINAL_VALIDATION_BATCH_SIZE) {
        let placeholders = (0..batch.len()).map(|_| "?").collect::<Vec<_>>().join(", ");
        let query = format!(
            "SELECT public_id
             FROM resource_terminals
             WHERE deleted_revision IS NULL AND public_id IN ({placeholders})"
        );
        let mut statement = connection.prepare(&query)?;
        let terminal_ids = statement
            .query_map(
                rusqlite::params_from_iter(
                    batch.iter().map(|(terminal_id, _, _)| terminal_id.as_str()),
                ),
                |row| row.get::<_, String>(0),
            )?
            .collect::<Result<Vec<_>, _>>()?;
        live_terminal_ids.extend(terminal_ids);
    }
    for (terminal_id, _, _) in values {
        anyhow::ensure!(
            live_terminal_ids.contains(terminal_id.as_str()),
            "reduced journal state references unknown or deleted terminal {terminal_id}"
        );
    }
    Ok(())
}

fn reduced_agent_values(
    state: &Value,
    session_id: &SessionPublicId,
    committed_revision: u64,
) -> anyhow::Result<Vec<(TerminalPublicId, String, RegistryAgentProjection)>> {
    let values = state
        .get("session_snapshot")
        .and_then(Value::as_object)
        .and_then(|snapshot| snapshot.get("agents"))
        .and_then(Value::as_array)
        .context("reduced journal state omitted session_snapshot.agents")?;
    let committed_revision =
        i64::try_from(committed_revision).context("agent projection revision exceeds SQLite")?;
    let mut terminals = HashSet::with_capacity(values.len());
    values
        .iter()
        .map(|value| {
            let terminal_id = value
                .get("terminal_id")
                .and_then(Value::as_str)
                .context("reduced agent projection omitted terminal_id")
                .and_then(|value| TerminalPublicId::parse(value).map_err(Into::into))?;
            anyhow::ensure!(
                terminals.insert(terminal_id.clone()),
                "reduced journal state contains duplicate agent terminal {terminal_id}"
            );
            let result_json = canonical_json(value)?;
            let projection = public_projection_store::decode_agent_projection(
                &result_json,
                &terminal_id,
                session_id,
                committed_revision,
            )?;
            Ok((terminal_id, result_json, projection))
        })
        .collect()
}

fn agent_projection_rebuild_active(connection: &Connection) -> anyhow::Result<bool> {
    Ok(resource_store::resource_agent_generation_backfill_pending(connection)?
        || prejournal_projection_migration_cursor(connection)?.is_some()
        || agent_projection_journal_rebuild_target(connection)?.is_some()
        || agent_projection_rebuild_changes_pending(connection)?)
}

fn agent_projection_rebuild_changes_pending(connection: &Connection) -> anyhow::Result<bool> {
    let pending = connection.query_row(
        "SELECT EXISTS(SELECT 1 FROM resource_agent_projection_rebuild_changes LIMIT 1)",
        [],
        |row| row.get::<_, bool>(0),
    )?;
    Ok(pending)
}

fn record_agent_projection_rebuild_change(
    transaction: &Transaction<'_>,
    terminal_id: &TerminalPublicId,
) -> anyhow::Result<()> {
    transaction.execute(
        "INSERT OR IGNORE INTO resource_agent_projection_rebuild_changes(
           terminal_id, previous_result_json, previous_committed_revision
         ) VALUES(
           ?1,
           (SELECT result_json FROM resource_agent_projections WHERE terminal_id = ?1),
           (SELECT committed_revision FROM resource_agent_projections WHERE terminal_id = ?1)
         )",
        [terminal_id.as_str()],
    )?;
    Ok(())
}

fn replay_agent_projection_journal_page(
    transaction: &Transaction<'_>,
    sequence: u64,
    target_sequence: u64,
    allow_archived_kind_backfill: bool,
) -> anyhow::Result<(bool, bool)> {
    if !session_journal::backfill_journal_event_index_kinds_page(
        transaction,
        AGENT_PROJECTION_JOURNAL_REBUILD_PAGE_SIZE,
        allow_archived_kind_backfill,
    )? {
        return Ok((false, false));
    }
    let projection_sequences = {
        let mut statement = transaction.prepare(
            "SELECT sequence
             FROM journal_agent_event_index
             WHERE sequence > ?1 AND sequence <= ?2
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
    let live_sequence = agent_projection_journal_live_sequence(transaction)?;
    for record in
        session_journal::query_session_journal_sequences(transaction, &projection_sequences)?
    {
        if !record.kind.starts_with("agent.") {
            continue;
        }
        let changed_terminal = apply_agent_projection_journal_record(
            transaction,
            AgentProjectionJournalInput {
                sequence: record.sequence,
                kind: &record.kind,
                occurred_at_ms: record.occurred_at_ms,
                producer: &record.producer,
                subjects: &record.subjects,
                payload: &record.payload,
                resource_revision: record.resource_revision,
                rebuilding_generation_history: live_sequence
                    .is_none_or(|live_sequence| record.sequence < live_sequence),
                replaying_projection_journal: true,
            },
        )?;
        if let Some(terminal_id) = changed_terminal {
            transaction.execute(
                "INSERT OR IGNORE INTO resource_agent_projection_rebuild_changes(terminal_id)
                 VALUES(?1)",
                [terminal_id.as_str()],
            )?;
        }
    }
    let (checkpoint_ready, refresh_required) = match last_sequence {
        Some(last_sequence) if page_is_full && last_sequence < target_sequence => {
            store_agent_projection_journal_cursor(transaction, last_sequence)?;
            (false, false)
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
            (true, true)
        }
    };
    Ok((checkpoint_ready, refresh_required))
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

fn agent_projection_journal_live_sequence(connection: &Connection) -> anyhow::Result<Option<u64>> {
    connection
        .query_row(
            "SELECT value FROM meta WHERE key = ?1",
            [AGENT_PROJECTION_JOURNAL_LIVE_SEQUENCE_KEY],
            |row| row.get::<_, String>(0),
        )
        .optional()?
        .map(|value| value.parse::<u64>().context("agent projection live sequence is invalid"))
        .transpose()
}

fn note_agent_projection_journal_live_sequence(
    transaction: &Transaction<'_>,
    sequence: u64,
) -> anyhow::Result<()> {
    if let Some(existing) = agent_projection_journal_live_sequence(transaction)? {
        anyhow::ensure!(
            sequence >= existing,
            "agent projection live sequence cannot move backwards from {existing} to {sequence}"
        );
        return Ok(());
    }
    transaction.execute(
        "INSERT INTO meta(key, value) VALUES(?1, ?2)",
        params![AGENT_PROJECTION_JOURNAL_LIVE_SEQUENCE_KEY, sequence.to_string()],
    )?;
    Ok(())
}

fn clear_agent_projection_journal_live_sequence(
    transaction: &Transaction<'_>,
) -> anyhow::Result<()> {
    transaction
        .execute("DELETE FROM meta WHERE key = ?1", [AGENT_PROJECTION_JOURNAL_LIVE_SEQUENCE_KEY])?;
    Ok(())
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

fn clear_agent_projection_rebuild_changes(connection: &Connection) -> anyhow::Result<()> {
    connection.execute("DELETE FROM resource_agent_projection_rebuild_changes", [])?;
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
    let begins_new_structured_session_with_turn = next.begins_turn
        && next.source_session.is_some()
        && (current.source_session != next.source_session || current.provider != next.provider);
    if begins_new_structured_session_with_turn {
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
    let same_structured_session = current.source_session.is_some()
        && current.source_session == next.source_session
        && current.provider == next.provider;
    let same_structured_turn = current.source_session.is_none()
        && next.source_session.is_none()
        && current.turn_id.is_some()
        && current.turn_id == next.turn_id
        && current.provider == next.provider;
    if same_structured_session || same_structured_turn {
        let different_structured_turn = current.source_session.is_some()
            && current.turn_id.is_some()
            && next.turn_id.is_some()
            && current.turn_id != next.turn_id;
        if different_structured_turn && !next.begins_turn {
            return current;
        }
        let begins_new_structured_turn =
            current.source_session.is_some() && next.begins_turn && different_structured_turn;
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
        return if next.source_session.is_some() { next } else { current };
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

#[cfg(test)]
mod tests {
    use super::*;

    fn hook_projection(sequence: u64, state: &str) -> AgentProjectionRow {
        AgentProjectionRow {
            terminal_id: TerminalPublicId::parse("term_00000000000000000000000000000001").unwrap(),
            state: state.into(),
            source: "hook".into(),
            updated_at_ms: sequence,
            source_session: Some("session".into()),
            provider: Some("provider".into()),
            turn_id: Some("turn".into()),
            committed_sequence: sequence,
            result: Some(json!({"state":state})),
            begins_session: false,
            begins_turn: false,
        }
    }

    #[test]
    fn older_authoritative_hook_report_does_not_replace_newer_projection() {
        let current = hook_projection(20, "done");
        let older = hook_projection(10, "working");
        let selected = select_projection(Some(current.clone()), older);

        assert_eq!(selected.committed_sequence, current.committed_sequence);
        assert_eq!(selected.state, current.state);
    }

    #[test]
    fn validates_many_reduced_agent_terminals_with_bounded_queries() {
        use rusqlite::hooks::{AuthAction, AuthContext, Authorization};
        use std::sync::Arc;
        use std::sync::atomic::{AtomicUsize, Ordering};

        let connection = Connection::open_in_memory().unwrap();
        connection
            .execute_batch(
                "CREATE TABLE resource_terminals(
                   public_id TEXT PRIMARY KEY,
                   deleted_revision INTEGER
                 )",
            )
            .unwrap();
        let values = (0..1_000)
            .map(|index| {
                let terminal_id = TerminalPublicId::parse(format!("term_{index:032x}")).unwrap();
                connection
                    .execute(
                        "INSERT INTO resource_terminals(public_id, deleted_revision)
                         VALUES(?1, NULL)",
                        [terminal_id.as_str()],
                    )
                    .unwrap();
                (
                    terminal_id.clone(),
                    String::new(),
                    RegistryAgentProjection {
                        id: AgentPublicId::parse(format!("agent_{index:032x}")).unwrap(),
                        terminal_id,
                        state: "working".into(),
                        source: "hook".into(),
                        updated_at_ms: 0,
                        source_session: None,
                    },
                )
            })
            .collect::<Vec<_>>();

        let select_count = Arc::new(AtomicUsize::new(0));
        let observed_select_count = Arc::clone(&select_count);
        connection
            .authorizer(Some(move |context: AuthContext<'_>| {
                if matches!(context.action, AuthAction::Select) {
                    let count = observed_select_count.fetch_add(1, Ordering::Relaxed) + 1;
                    if count > 2 {
                        return Authorization::Deny;
                    }
                }
                Authorization::Allow
            }))
            .unwrap();

        validate_reduced_agent_terminals(&connection, &values).unwrap();
        assert!(select_count.load(Ordering::Relaxed) <= 2);
    }
}
