//! The resource event page reader (moved out of resource_store.rs).

use super::*;

impl WorkspaceRegistry {
    #[track_caller]
    pub fn resource_events_after(&self, revision: u64) -> anyhow::Result<ResourceEventPage> {
        query_resource_events_after(&self.connection.get(), &self.generation, revision)
    }
}

/// The resource events after `revision` (one page), read on `connection`.
///
/// Shared by the registry (its own connection, under the registry lock) and
/// by `SessionJournalReader` (a stream's read-only connection, no registry
/// lock), so a `session.events` stream that wakes on every journal commit
/// never holds the registry lock while it reads.
pub(crate) fn query_resource_events_after(
    connection: &Connection,
    generation: &str,
    revision: u64,
) -> anyhow::Result<ResourceEventPage> {
    let head_revision = current_resource_revision(connection)?;
    if revision > head_revision {
        anyhow::bail!(
            "cursor.invalid: revision {revision} is ahead of current revision {head_revision}"
        );
    }
    let oldest_revision = connection
        .query_row(
            "SELECT MIN(resource_revision) FROM journal_event_index
             WHERE resource_revision IS NOT NULL",
            [],
            |row| row.get::<_, Option<i64>>(0),
        )?
        .map(|revision| {
            u64::try_from(revision).context("stored resource event revision is negative")
        })
        .transpose()?;
    if oldest_revision.is_some_and(|oldest| revision < oldest.saturating_sub(1))
        || (oldest_revision.is_none() && revision < head_revision)
    {
        anyhow::bail!(
            "cursor.gap: revision {revision} is older than retained history at {oldest_revision:?}"
        );
    }
    // A wake for a commit with no resource event (terminal output) reads
    // nothing more.
    let indexed = if revision == head_revision {
        Vec::new()
    } else {
        let mut statement = connection.prepare(
            "SELECT resource_revision, sequence FROM journal_event_index
             WHERE resource_revision > ?1
             ORDER BY resource_revision ASC
             LIMIT ?2",
        )?;
        statement
            .query_map(
                params![
                    i64::try_from(revision).context("resource revision exceeds SQLite range")?,
                    i64::try_from(RESOURCE_EVENT_PAGE_SIZE)?,
                ],
                |row| Ok((row.get::<_, i64>(0)?, row.get::<_, i64>(1)?)),
            )?
            .map(|row| {
                let (resource_revision, sequence) = row?;
                Ok((
                    u64::try_from(resource_revision)
                        .context("resource event revision is negative")?,
                    u64::try_from(sequence).context("resource event sequence is negative")?,
                ))
            })
            .collect::<anyhow::Result<Vec<_>>>()?
    };
    let sequences = indexed.iter().map(|(_, sequence)| *sequence).collect::<Vec<_>>();
    let mut records = session_journal::query_session_journal_sequences(connection, &sequences)?
        .into_iter()
        .map(|record| (record.sequence, record))
        .collect::<HashMap<_, _>>();
    let mut expected_revision = revision.saturating_add(1);
    let mut batches = Vec::with_capacity(indexed.len());
    for (indexed_revision, sequence) in indexed {
        anyhow::ensure!(
            indexed_revision == expected_revision,
            "resource event history contains a gap before revision {indexed_revision}"
        );
        let record = records
            .remove(&sequence)
            .context("indexed resource event is absent from the journal")?;
        anyhow::ensure!(
            record.resource_revision == Some(indexed_revision)
                && record.previous_resource_revision == Some(indexed_revision - 1),
            "indexed resource event revision does not match its journal record"
        );
        batches.push(ResourceEventBatch {
            previous_revision: indexed_revision - 1,
            revision: indexed_revision,
            changes: record
                .payload
                .get("changes")
                .cloned()
                .context("resource journal record omitted changes")?,
            placement_shift: record
                .payload
                .get(crate::state::placement_shift::PAYLOAD_KEY)
                .cloned(),
        });
        expected_revision = expected_revision.saturating_add(1);
    }
    Ok(ResourceEventPage {
        generation: generation.to_owned(),
        head_revision,
        oldest_revision,
        batches,
    })
}
