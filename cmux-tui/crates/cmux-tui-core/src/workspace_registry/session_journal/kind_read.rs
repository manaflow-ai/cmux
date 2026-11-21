//! Kind-scoped journal reads: a reducer that folds a few kinds of record
//! reads those records, not the history around them.
//!
//! The agent roster's replay after a reducer version change read every
//! record other than terminal output.
//! On Leo's registry (2026-11-08) that was about 12M rows, 96.6% of them
//! `personal.session.put`, which the roster discards, and the daemon took
//! 26 min to start. This read seeks the `(kind, sequence)` index once per
//! kind the reducer folds, and inflates a sealed segment only when its kind
//! map names one of them.

use super::*;

/// Which journal kinds a kind-scoped read returns. It is asked once per
/// distinct kind (of the active journal, or of a sealed segment's kind map),
/// never per record.
pub(crate) type JournalKinds = fn(&str) -> bool;

impl WorkspaceRegistry {
    /// Records in `(sequence, through]` whose kind `kinds` accepts, oldest
    /// first, and the sequence the read covered through. A page holds at
    /// most `limit` active records; a sealed segment is consumed whole, so a
    /// page that decodes one can exceed `limit` by that segment's matches.
    pub(crate) fn session_journal_kinds_after(
        &self,
        sequence: u64,
        through: u64,
        kinds: JournalKinds,
        limit: usize,
    ) -> anyhow::Result<(Vec<SessionJournalRecord>, u64)> {
        query_session_journal_kinds_after(&self.connection.get(), sequence, through, kinds, limit)
    }
}

impl SessionJournalReader {
    /// [`WorkspaceRegistry::session_journal_kinds_after`] on this reader's
    /// own read-only connection (no registry lock). The page reads in one
    /// read transaction: the archive head and the active rows come from one
    /// snapshot, so a seal that commits between the two reads cannot hide
    /// the records it moved.
    pub(crate) fn kinds_after(
        &self,
        sequence: u64,
        through: u64,
        kinds: JournalKinds,
        limit: usize,
    ) -> anyhow::Result<(Vec<SessionJournalRecord>, u64)> {
        let snapshot = self.connection.unchecked_transaction()?;
        query_session_journal_kinds_after(&snapshot, sequence, through, kinds, limit)
    }
}

pub(crate) fn query_session_journal_kinds_after(
    connection: &Connection,
    sequence: u64,
    through: u64,
    kinds: JournalKinds,
    limit: usize,
) -> anyhow::Result<(Vec<SessionJournalRecord>, u64)> {
    anyhow::ensure!(limit > 0, "journal page limit must be positive");
    anyhow::ensure!(
        limit <= MAX_JOURNAL_PAGE_SIZE,
        "journal page limit exceeds {MAX_JOURNAL_PAGE_SIZE}"
    );
    if sequence >= through {
        return Ok((Vec::new(), through));
    }
    let archive_end = query_archived_journal_head(connection)?;
    let archive_through = through.min(archive_end);
    let mut records = Vec::new();
    let mut reached = sequence;
    if sequence < archive_through {
        (records, reached) =
            archived_kinds_after(connection, sequence, archive_through, kinds, limit)?;
        // A page that stopped inside the archive ends there: the active rows
        // all come after it.
        if records.len() >= limit || reached >= through || reached < archive_through {
            return Ok((records, reached));
        }
    }
    let (active, reached) = active_kinds_after(
        connection,
        reached,
        through,
        kinds,
        limit.saturating_sub(records.len()),
    )?;
    records.extend(active);
    Ok((records, reached))
}

/// The active rows in `(sequence, through]` of the accepted kinds, at most
/// `limit`. The distinct kinds come from the kind index by a skip scan (a
/// seek per kind); each accepted kind is one range seek on
/// `(kind, sequence)` that reads at most `limit` sequences from the index
/// alone. The sequences are merged in order and only the first `limit`
/// records are read and decoded. A rejected kind costs one seek, however
/// many rows it has.
fn active_kinds_after(
    connection: &Connection,
    sequence: u64,
    through: u64,
    kinds: JournalKinds,
    limit: usize,
) -> anyhow::Result<(Vec<SessionJournalRecord>, u64)> {
    let mut distinct = connection.prepare_cached(
        "WITH RECURSIVE kinds(kind) AS (
           SELECT (SELECT MIN(kind) FROM session_journal
                   INDEXED BY session_journal_by_kind_sequence)
           UNION ALL
           SELECT (SELECT MIN(kind) FROM session_journal
                   INDEXED BY session_journal_by_kind_sequence
                   WHERE kind > kinds.kind)
           FROM kinds WHERE kinds.kind IS NOT NULL
         )
         SELECT kind FROM kinds WHERE kind IS NOT NULL",
    )?;
    let mut accepted =
        distinct.query_map([], |row| row.get::<_, String>(0))?.collect::<Result<Vec<_>, _>>()?;
    accepted.retain(|kind| kinds(kind));
    let mut range = connection.prepare_cached(
        "SELECT sequence FROM session_journal
         INDEXED BY session_journal_by_kind_sequence
         WHERE kind = ?1 AND sequence > ?2 AND sequence <= ?3
         ORDER BY sequence ASC
         LIMIT ?4",
    )?;
    let after = i64::try_from(sequence).context("journal sequence exceeds SQLite range")?;
    let until = i64::try_from(through).context("journal sequence exceeds SQLite range")?;
    let page = i64::try_from(limit).context("journal page limit exceeds SQLite range")?;
    let mut sequences = Vec::new();
    // Once `limit` matches are in hand, a later kind reads only below the
    // last of them: a page reads about `limit` index entries, not `limit`
    // per kind.
    let mut until = until;
    for kind in &accepted {
        let rows =
            range.query_map(params![kind, after, until, page], |row| row.get::<_, i64>(0))?;
        for row in rows {
            sequences.push(row?);
        }
        if sequences.len() >= limit {
            sequences.sort_unstable();
            sequences.truncate(limit);
            if let Some(&last) = sequences.last() {
                until = last;
            }
        }
    }
    sequences.sort_unstable();
    // Each kind read its first `limit` matches up to its bound, which is at
    // or after the last match kept, so the first `limit` of the merge are
    // the first `limit` of all: no kind has an unread match at or before the
    // last one kept. Fewer than `limit` in all means every match through
    // `through` was read.
    sequences.truncate(limit);
    let reached = match sequences.last() {
        Some(&last) if sequences.len() == limit => {
            u64::try_from(last).context("journal sequence is negative")?
        }
        _ => through,
    };
    let mut row = connection.prepare_cached(
        "SELECT sequence, event_id, schema_version, kind, class, replay_policy,
                occurred_at_ms, committed_at_ms, producer_json, authority_json,
                causation_id, correlation_id, causation_depth, subjects_json,
                sensitivity, payload_json, content, resource_revision,
                previous_resource_revision
         FROM session_journal
         WHERE sequence = ?1",
    )?;
    let records = sequences
        .into_iter()
        .map(|sequence| decode_record(row.query_row([sequence], stored_record_row)?))
        .collect::<anyhow::Result<Vec<_>>>()?;
    Ok((records, reached))
}

/// The sealed records in `(sequence, through]` of the accepted kinds, and
/// the sequence the page covered through. A segment whose kind map names no
/// accepted kind is skipped without loading its content; one that does is
/// read from its kept reducer records when they cover those kinds, and
/// decoded whole otherwise. Either way it is consumed whole, so the next
/// page never reads it again. Up to [`segment_decode_workers`] segments
/// decode at once (`consume_batch`).
///
/// A page reads for one slice ([`kind_slice`]): it ends after the batch
/// that reaches `limit` records or the end of the slice, so a read over many
/// sparse segments returns to the replay's deadline check between pages.
/// A segment with no kind map yet (an older segment the backfill above has
/// not reached), or one whose map the backfill has not proven whole, is
/// decoded whole, kept to the accepted kinds, and ends the page: a page
/// decodes at most one of them. Before, the read fell back to
/// the legacy read of `limit` records of every kind, which over sparse
/// segments decoded up to `limit` whole segments in one call.
fn archived_kinds_after(
    connection: &Connection,
    sequence: u64,
    through: u64,
    kinds: JournalKinds,
    limit: usize,
) -> anyhow::Result<(Vec<SessionJournalRecord>, u64)> {
    let deadline = std::time::Instant::now() + kind_slice();
    backfill_legacy_journal_segment_kinds(connection)?;
    let mut statement = connection.prepare_cached(
        "SELECT segment_id, start_sequence, end_sequence
         FROM journal_segments
         WHERE end_sequence > ?1 AND start_sequence <= ?2
         ORDER BY end_sequence ASC",
    )?;
    let segments = statement
        .query_map(params![i64::try_from(sequence)?, i64::try_from(through)?], |row| {
            Ok((row.get::<_, String>(0)?, row.get::<_, i64>(1)?, row.get::<_, i64>(2)?))
        })?
        .collect::<Result<Vec<_>, _>>()?;
    // The archive head is the last segment's end, so a range below it has a
    // segment; none covers nothing, as the legacy read returned.
    let Some(first) = segments.first() else { return Ok((Vec::new(), through)) };
    anyhow::ensure!(
        first.1 <= i64::try_from(sequence.saturating_add(1))?,
        "journal segments contain a gap before sequence {}",
        first.1
    );
    let mut previous_end = first.1.saturating_sub(1);
    for (_, start, end) in &segments {
        anyhow::ensure!(
            *start == previous_end.saturating_add(1),
            "journal segments contain a gap before sequence {start}"
        );
        previous_end = *end;
    }
    let mut segment_kinds = connection
        .prepare_cached("SELECT kind FROM journal_segment_kinds WHERE segment_id = ?1")?;
    // A map the backfill has not proven whole can lack a kind: an older
    // build (a downgrade) maps a segment one kind at a time, and a read-only
    // reader cannot run the backfill that would finish it. Such a segment is
    // read as an unmapped one.
    let unproven = unproven_kind_maps(connection)?;
    let mut page = Page { sequence, through, kinds, records: Vec::new(), reached: sequence };
    let workers = segment_decode_workers();
    // Segments in order, each with how its accepted records are read.
    let mut batch: Vec<(u64, PageSegment)> = Vec::new();
    let (mut batch_decodes, mut batch_kept) = (0, 0);
    for (segment_id, start, end) in segments {
        let mapped = segment_kinds
            .query_map([&segment_id], |row| row.get::<_, String>(0))?
            .collect::<Result<Vec<_>, _>>()?;
        let (start, end) = (u64::try_from(start)?, u64::try_from(end)?);
        let proven = !unproven.is_some_and(|(after, through)| {
            start > after && through.is_none_or(|through| start <= through)
        });
        if mapped.is_empty() || !proven {
            batch.push((end.min(through), PageSegment::Decode(segment_id)));
            page.consume_batch(connection, batch)?;
            return Ok((page.records, page.reached));
        }
        let accepted =
            mapped.iter().map(String::as_str).filter(|kind| kinds(kind)).collect::<Vec<_>>();
        let segment = if accepted.is_empty() {
            PageSegment::Skip
        } else {
            // The segment's records of these kinds as sealing kept them, or
            // the segment itself when they were not kept (sealed by an older
            // build, not yet backfilled).
            match reducer_records::sealed_reducer_records(
                connection,
                &segment_id,
                start,
                end,
                &accepted,
                kinds,
            )? {
                Some(kept) => {
                    batch_kept += kept.len();
                    PageSegment::Kept(kept)
                }
                None => {
                    batch_decodes += 1;
                    PageSegment::Decode(segment_id)
                }
            }
        };
        batch.push((end.min(through), segment));
        if batch_decodes < workers && page.records.len() + batch_kept < limit {
            continue;
        }
        (batch_decodes, batch_kept) = (0, 0);
        if !page.consume_batch(connection, std::mem::take(&mut batch))?
            || page.records.len() >= limit
            || std::time::Instant::now() >= deadline
        {
            return Ok((page.records, page.reached));
        }
    }
    page.consume_batch(connection, batch)?;
    Ok((page.records, page.reached))
}

/// One segment of a sealed page: how its accepted records are read.
enum PageSegment {
    /// It holds no accepted kind.
    Skip,
    /// Its accepted records, from the kept reducer records.
    Kept(Vec<SessionJournalRecord>),
    /// It is decoded whole: its id.
    Decode(String),
}

/// A sealed page being read: its range, its kinds, what it holds so far.
struct Page {
    sequence: u64,
    through: u64,
    kinds: JournalKinds,
    records: Vec<SessionJournalRecord>,
    reached: u64,
}

impl Page {
    /// Inflates the batch's segments on parallel threads, then checks their
    /// gaps and adds their records in sequence order. A segment that fails
    /// ends the page before it: what the page already covers still counts,
    /// and the next page meets the error at its start (and the roster's
    /// salvaging read skips it), as a read one segment at a time would.
    /// Returns whether the whole batch was consumed; the error itself when
    /// the page covers nothing yet.
    fn consume_batch(
        &mut self,
        connection: &Connection,
        batch: Vec<(u64, PageSegment)>,
    ) -> anyhow::Result<bool> {
        let mut rows = Vec::new();
        for (_, segment) in &batch {
            if let PageSegment::Decode(segment_id) = segment {
                rows.push(load_journal_segment(connection, segment_id));
            }
        }
        let mut inflated = inflate_segments(rows, self.kinds).into_iter();
        for (end, segment) in batch {
            let (sequence, through, kinds) = (self.sequence, self.through, self.kinds);
            let in_page = |record: &SessionJournalRecord| {
                record.sequence > sequence && record.sequence <= through && kinds(&record.kind)
            };
            match segment {
                PageSegment::Skip => {}
                PageSegment::Kept(kept) => self.records.extend(kept.into_iter().filter(in_page)),
                PageSegment::Decode(_) => {
                    let decoded = inflated
                        .next()
                        .context("a segment batch lost a segment")?
                        .and_then(|segment| check_segment_gaps(connection, segment));
                    match decoded {
                        Ok(decoded) => {
                            self.records.extend(decoded.records.into_iter().filter(in_page));
                        }
                        Err(error) if self.reached == self.sequence => return Err(error),
                        Err(_) => return Ok(false),
                    }
                }
            }
            self.reached = self.reached.max(end);
        }
        Ok(true)
    }
}

/// How many sealed segments a kind-scoped read inflates at once: half the
/// cores, at most 8, so the person's own work keeps the rest. Each one in
/// flight holds one segment's JSON (at most
/// MAX_JOURNAL_SEGMENT_UNCOMPRESSED_BYTES) and its kept records.
fn segment_decode_workers() -> usize {
    #[cfg(test)]
    if let Some(workers) = SEGMENT_DECODE_WORKERS.with(Cell::get) {
        return workers;
    }
    std::thread::available_parallelism().map_or(1, std::num::NonZeroUsize::get).div_ceil(2).min(8)
}

#[cfg(test)]
thread_local! {
    /// Overrides [`segment_decode_workers`] on this thread, so a test can
    /// time the same read one segment at a time.
    pub(crate) static SEGMENT_DECODE_WORKERS: Cell<Option<usize>> =
        const { Cell::new(None) };
}

/// Inflates each loaded row on a scoped thread of its own (inline when
/// there is one), keeping only `kinds`; results come back in row order.
fn inflate_segments(
    rows: Vec<anyhow::Result<JournalSegmentRow>>,
    kinds: JournalKinds,
) -> Vec<anyhow::Result<InflatedJournalSegment>> {
    let inflate = move |row: anyhow::Result<JournalSegmentRow>| {
        row.and_then(|row| inflate_journal_segment(row, Some(kinds)))
    };
    if rows.len() <= 1 {
        return rows.into_iter().map(inflate).collect();
    }
    std::thread::scope(|scope| {
        let handles = rows
            .into_iter()
            .map(|row| {
                std::thread::Builder::new()
                    .name("cmux-journal-inflate".into())
                    .spawn_scoped(scope, move || inflate(row))
            })
            .collect::<Vec<_>>();
        handles
            .into_iter()
            .map(|handle| {
                handle.map_err(anyhow::Error::from).and_then(|handle| {
                    handle.join().unwrap_or_else(|_| {
                        Err(anyhow::anyhow!("a journal segment inflate panicked"))
                    })
                })
            })
            .collect()
    })
}
