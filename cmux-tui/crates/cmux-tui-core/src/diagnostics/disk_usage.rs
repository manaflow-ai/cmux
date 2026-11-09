//! The `server-stats` `disk` section: what the session's registry keeps on
//! disk, and which journal kinds write it (Leo, 2026-11-09: "put the same
//! kinda scrutiny we do on RAM as we do for disk usage").
//!
//! Cost per request, bounded and independent of history size:
//! - one listing of the registry's directory, at most [`MAX_DIRECTORY_ENTRIES`]
//!   `stat` calls across it and its subdirectories;
//! - on its own read-only connection (no registry lock): three header
//!   pragmas, the first and last journal sequence (two rowid seeks), and the
//!   newest [`JOURNAL_TAIL_SAMPLE_ROWS`] journal rows, never a scan of the
//!   live journal;
//! - sealed segments are summed once per daemon, then only the segments
//!   sealed since the last request (a range of the `start_sequence` index;
//!   `length(content)` reads no overflow page). An output cleanup that
//!   rewrites the registry file sums them again once.

use std::collections::BTreeMap;
use std::path::Path;

use rusqlite::{Connection, OptionalExtension, params};
use serde::Serialize;

/// Journal bytes each kind may write per day, the disk budget table.
///
/// A kind's bytes are the bytes of its live `session_journal` rows (every
/// text and blob column plus [`JOURNAL_ROW_FIXED_BYTES`]) before sealing
/// compresses them. A kind not listed gets [`DEFAULT_JOURNAL_KIND_BUDGET`].
/// `disk_budget_guard` (mux/tests/disk_budget.rs) runs a scripted day of
/// Leo's 2026-11-09 load on a real on-disk registry and fails when a kind
/// writes more than its entry; `server-stats` `disk` flags a kind whose
/// newest rows write faster than it (`over_budget`).
///
/// To raise a budget: measure first (the guard prints every kind's
/// bytes/day with `--nocapture`), say in the PR which change makes the kind
/// bigger and why its bytes cannot leave the journal (a row keyed by hash,
/// a content blob, the output store), then raise only that entry. A budget
/// that rises with no measured reason is the regression this table exists
/// to catch: one 6 KB `personal.session.put` fact at 12 a second wrote
/// 7 GB a day and 59 GB in a week (2026-11-09).
pub const JOURNAL_KIND_BUDGETS: &[(&str, u64)] = &[
    // A flapping session put at 12/s: under 1 KB a fact since #39116
    // (about 7 GB/day before, with the capability list in every fact).
    ("personal.session.put", 1_536 * MIB),
    ("workspace.create", 16 * MIB),
    ("workspace.rename", 16 * MIB),
    ("workspace.close", 16 * MIB),
    ("journal.checkpoint.created", 64 * MIB),
    ("journal.segment.sealed", 16 * MIB),
];

/// The budget of a journal kind [`JOURNAL_KIND_BUDGETS`] does not list.
pub const DEFAULT_JOURNAL_KIND_BUDGET: u64 = 64 * MIB;

/// A day of the guard's load may grow the registry file (pages in use) by
/// at most this much per recorded machine session: journal rows, their
/// indexes, and every other table a write touches.
pub const REGISTRY_BYTES_PER_SESSION_PER_DAY: u64 = 512 * MIB;

const MIB: u64 = 1024 * 1024;

/// The budget of `kind` in bytes per day.
pub fn journal_kind_budget(kind: &str) -> u64 {
    JOURNAL_KIND_BUDGETS
        .iter()
        .find(|(name, _)| *name == kind)
        .map_or(DEFAULT_JOURNAL_KIND_BUDGET, |(_, budget)| *budget)
}

/// Newest journal rows the per-kind sample reads: about 7 MB when every
/// row is a 7 KB fact.
pub const JOURNAL_TAIL_SAMPLE_ROWS: u64 = 1_024;
/// Directory entries the file listing visits, subdirectories included.
pub const MAX_DIRECTORY_ENTRIES: u64 = 20_000;
/// Entries of the registry's directory the section lists, largest first.
const LISTED_FILES: usize = 32;
/// Journal kinds and segment kinds the section lists.
const LISTED_KINDS: usize = 16;
/// Bytes a journal row stores beyond its text and blob columns: the integer
/// columns, `class`, `replay_policy`, `sensitivity` and the record header.
pub const JOURNAL_ROW_FIXED_BYTES: u64 = 64;

/// The bytes one `session_journal` row stores, as SQL over its columns.
/// `CAST(.. AS BLOB)` makes `length` count bytes, not characters.
pub(crate) const JOURNAL_ROW_BYTES_SQL: &str = "(64
    + length(CAST(event_id AS BLOB)) + length(CAST(kind AS BLOB))
    + length(CAST(producer_json AS BLOB)) + ifnull(length(CAST(authority_json AS BLOB)), 0)
    + ifnull(length(CAST(causation_id AS BLOB)), 0)
    + ifnull(length(CAST(correlation_id AS BLOB)), 0)
    + length(CAST(subjects_json AS BLOB)) + length(CAST(payload_json AS BLOB))
    + ifnull(length(content), 0) + ifnull(length(CAST(actor AS BLOB)), 0))";

/// The `server-stats` `disk` section.
#[derive(Clone, Debug, Default, Serialize)]
pub struct DiskUsageSnapshot {
    /// Size of the registry file, of its `-wal` and of its `-shm`.
    pub registry_bytes: u64,
    pub wal_bytes: u64,
    pub shm_bytes: u64,
    /// The registry's pages: `page_count * page_size` is its committed
    /// size, `freelist_pages` the pages free for reuse.
    pub page_size: u64,
    pub page_count: u64,
    pub freelist_pages: u64,
    /// Entries beside the registry (the registry itself, its sidecars such
    /// as `.output-cleanup`, `conversations.sqlite3`, `terminal-output/`),
    /// largest first, at most 32. A directory counts every file under it.
    pub files: Vec<DiskFileSnapshot>,
    /// Entries of the directory not listed in `files`.
    pub files_unlisted: u64,
    /// The listing stopped at [`MAX_DIRECTORY_ENTRIES`]; sizes are lower bounds.
    pub files_truncated: bool,
    /// `null` when the registry could not be read (see `error`).
    pub journal: Option<JournalDiskSnapshot>,
    pub segments: Option<SegmentDiskSnapshot>,
    pub error: Option<String>,
}

#[derive(Clone, Debug, Default, Serialize)]
pub struct DiskFileSnapshot {
    pub name: String,
    pub bytes: u64,
    /// Files counted: 1 for a file.
    pub files: u64,
}

/// The live (not yet sealed) journal.
#[derive(Clone, Debug, Default, Serialize)]
pub struct JournalDiskSnapshot {
    pub first_sequence: u64,
    pub head_sequence: u64,
    /// Rows from `first_sequence` through `head_sequence` (the journal has
    /// no gaps between its sealed prefix and its head).
    pub live_rows: u64,
    /// The newest rows read for the per-kind numbers, their bytes, and the
    /// time between the first and the last of them.
    pub sample_rows: u64,
    pub sample_bytes: u64,
    pub sample_span_ms: u64,
    /// `live_rows` times the sample's mean row size.
    pub estimated_live_bytes: u64,
    /// Kinds of the sample by bytes, at most 16.
    pub kinds: Vec<JournalKindDiskSnapshot>,
}

#[derive(Clone, Debug, Default, Serialize)]
pub struct JournalKindDiskSnapshot {
    pub kind: String,
    pub sample_rows: u64,
    pub sample_bytes: u64,
    /// The rate the sample wrote this kind at; `null` when the sample spans
    /// under a second.
    pub bytes_per_day: Option<u64>,
    /// [`journal_kind_budget`], and whether `bytes_per_day` is over it.
    pub budget_bytes_per_day: u64,
    pub over_budget: bool,
}

/// Sealed journal segments.
#[derive(Clone, Debug, Default, Serialize)]
pub struct SegmentDiskSnapshot {
    pub segments: u64,
    pub records: u64,
    pub compressed_bytes: u64,
    pub uncompressed_bytes: u64,
    pub by_codec: Vec<SegmentCodecSnapshot>,
    /// Kinds by the number of segments that hold them, at most 16.
    pub kinds: Vec<SegmentKindSnapshot>,
}

#[derive(Clone, Debug, Default, Serialize)]
pub struct SegmentCodecSnapshot {
    pub codec: String,
    pub segments: u64,
    pub records: u64,
    pub compressed_bytes: u64,
    pub uncompressed_bytes: u64,
}

#[derive(Clone, Debug, Default, Serialize)]
pub struct SegmentKindSnapshot {
    pub kind: String,
    pub segments: u64,
}

/// Segment sums kept between requests, so a request sums only the segments
/// sealed since the last one.
#[derive(Default)]
pub struct DiskUsageCache {
    segments: Option<SegmentTotals>,
}

struct SegmentTotals {
    /// The registry file these sums are of (an output cleanup swaps it).
    file: Option<(u64, u64)>,
    /// Segments counted, and the largest `start_sequence` among them.
    counted: u64,
    through_start: i64,
    by_codec: BTreeMap<String, SegmentCodecSnapshot>,
    kinds: BTreeMap<String, u64>,
}

/// Reads the `disk` section of the registry at `database_path`.
pub fn read_disk_usage(database_path: &Path, cache: &mut DiskUsageCache) -> DiskUsageSnapshot {
    let mut snapshot = DiskUsageSnapshot::default();
    let file_len = |suffix: &str| {
        let mut path = database_path.as_os_str().to_owned();
        path.push(suffix);
        std::fs::metadata(path).map_or(0, |metadata| metadata.len())
    };
    snapshot.registry_bytes = file_len("");
    snapshot.wal_bytes = file_len("-wal");
    snapshot.shm_bytes = file_len("-shm");
    if let Some(directory) = database_path.parent() {
        list_directory(directory, &mut snapshot);
    }
    let file = file_identity(database_path);
    let read = crate::workspace_registry::open_registry_database_read_only(database_path).and_then(
        |connection| -> anyhow::Result<(JournalDiskSnapshot, SegmentDiskSnapshot)> {
            connection.busy_timeout(std::time::Duration::from_millis(250))?;
            connection.execute_batch("PRAGMA query_only=ON;")?;
            let pragma = |name: &str| -> rusqlite::Result<u64> {
                connection.query_row(&format!("PRAGMA {name}"), [], |row| {
                    row.get::<_, i64>(0).map(|value| u64::try_from(value).unwrap_or(0))
                })
            };
            snapshot.page_size = pragma("page_size")?;
            snapshot.page_count = pragma("page_count")?;
            snapshot.freelist_pages = pragma("freelist_count")?;
            let journal = read_journal_tail(&connection)?;
            let segments = read_segments(&connection, file, cache)?;
            Ok((journal, segments))
        },
    );
    match read {
        Ok((journal, segments)) => {
            snapshot.journal = Some(journal);
            snapshot.segments = Some(segments);
        }
        Err(error) => snapshot.error = Some(format!("{error:#}")),
    }
    snapshot
}

fn read_journal_tail(connection: &Connection) -> anyhow::Result<JournalDiskSnapshot> {
    let sequence = |order: &str| -> rusqlite::Result<u64> {
        let value: Option<i64> = connection
            .query_row(
                &format!("SELECT sequence FROM session_journal ORDER BY sequence {order} LIMIT 1"),
                [],
                |row| row.get(0),
            )
            .optional()?;
        Ok(value.and_then(|value| u64::try_from(value).ok()).unwrap_or(0))
    };
    let first_sequence = sequence("ASC")?;
    let head_sequence = sequence("DESC")?;
    let live_rows =
        if head_sequence == 0 { 0 } else { head_sequence.saturating_sub(first_sequence) + 1 };
    let mut statement = connection.prepare(&format!(
        "SELECT kind, COUNT(*), SUM(bytes), MIN(committed_at_ms), MAX(committed_at_ms)
         FROM (SELECT kind, committed_at_ms, {JOURNAL_ROW_BYTES_SQL} AS bytes
               FROM session_journal ORDER BY sequence DESC LIMIT ?1)
         GROUP BY kind"
    ))?;
    let rows = statement
        .query_map(params![i64::try_from(JOURNAL_TAIL_SAMPLE_ROWS)?], |row| {
            Ok((
                row.get::<_, String>(0)?,
                row.get::<_, i64>(1)?,
                row.get::<_, i64>(2)?,
                row.get::<_, i64>(3)?,
                row.get::<_, i64>(4)?,
            ))
        })?
        .collect::<rusqlite::Result<Vec<_>>>()?;
    let to_u64 = |value: i64| u64::try_from(value).unwrap_or(0);
    let first_ms = rows.iter().map(|row| row.3).min().unwrap_or(0);
    let last_ms = rows.iter().map(|row| row.4).max().unwrap_or(0);
    let sample_span_ms = to_u64(last_ms.saturating_sub(first_ms));
    let mut kinds: Vec<JournalKindDiskSnapshot> = rows
        .into_iter()
        .map(|(kind, count, bytes, _, _)| {
            let bytes = to_u64(bytes);
            let bytes_per_day = bytes_per_day(bytes, sample_span_ms);
            let budget = journal_kind_budget(&kind);
            JournalKindDiskSnapshot {
                over_budget: bytes_per_day.is_some_and(|rate| rate > budget),
                kind,
                sample_rows: to_u64(count),
                sample_bytes: bytes,
                bytes_per_day,
                budget_bytes_per_day: budget,
            }
        })
        .collect();
    let sample_rows = kinds.iter().map(|kind| kind.sample_rows).sum::<u64>();
    let sample_bytes = kinds.iter().map(|kind| kind.sample_bytes).sum::<u64>();
    kinds.sort_by(|a, b| b.sample_bytes.cmp(&a.sample_bytes).then(a.kind.cmp(&b.kind)));
    kinds.truncate(LISTED_KINDS);
    let estimated_live_bytes = if sample_rows == 0 {
        0
    } else {
        u64::try_from(u128::from(sample_bytes) * u128::from(live_rows) / u128::from(sample_rows))
            .unwrap_or(u64::MAX)
    };
    Ok(JournalDiskSnapshot {
        first_sequence,
        head_sequence,
        live_rows,
        sample_rows,
        sample_bytes,
        sample_span_ms,
        estimated_live_bytes,
        kinds,
    })
}

/// `bytes` written over `span_ms`, per day; `None` under a second.
pub fn bytes_per_day(bytes: u64, span_ms: u64) -> Option<u64> {
    (span_ms >= 1_000).then(|| {
        u64::try_from(u128::from(bytes) * 86_400_000 / u128::from(span_ms)).unwrap_or(u64::MAX)
    })
}

fn read_segments(
    connection: &Connection,
    file: Option<(u64, u64)>,
    cache: &mut DiskUsageCache,
) -> anyhow::Result<SegmentDiskSnapshot> {
    // One read transaction: the count check and the sums see one snapshot.
    let snapshot = connection.unchecked_transaction()?;
    let totals = match cache.segments.take() {
        Some(totals) if totals.file == file => {
            let counted: i64 = snapshot.query_row(
                "SELECT COUNT(*) FROM journal_segments WHERE start_sequence <= ?1",
                [totals.through_start],
                |row| row.get(0),
            )?;
            // Segments are only ever appended past the last one; a count that
            // moved means the file was rewritten (output cleanup), so sum again.
            if u64::try_from(counted).ok() == Some(totals.counted) { Some(totals) } else { None }
        }
        _ => None,
    };
    let mut totals = totals.unwrap_or(SegmentTotals {
        file,
        counted: 0,
        through_start: 0,
        by_codec: BTreeMap::new(),
        kinds: BTreeMap::new(),
    });
    let to_u64 = |value: i64| u64::try_from(value).unwrap_or(0);
    let mut through = totals.through_start;
    {
        let mut statement = snapshot.prepare(
            "SELECT codec, COUNT(*), SUM(record_count), SUM(length(content)),
                    SUM(uncompressed_bytes), MAX(start_sequence)
             FROM journal_segments WHERE start_sequence > ?1 GROUP BY codec",
        )?;
        let mut rows = statement.query([totals.through_start])?;
        while let Some(row) = rows.next()? {
            let codec: String = row.get(0)?;
            let entry = totals.by_codec.entry(codec.clone()).or_insert_with(|| {
                SegmentCodecSnapshot { codec, ..SegmentCodecSnapshot::default() }
            });
            let segments = to_u64(row.get(1)?);
            entry.segments += segments;
            entry.records += to_u64(row.get(2)?);
            entry.compressed_bytes += to_u64(row.get(3)?);
            entry.uncompressed_bytes += to_u64(row.get(4)?);
            totals.counted += segments;
            through = through.max(row.get::<_, i64>(5)?);
        }
    }
    {
        let mut statement = snapshot.prepare(
            "SELECT kinds.kind, COUNT(*)
             FROM journal_segments AS segments
             JOIN journal_segment_kinds AS kinds ON kinds.segment_id = segments.segment_id
             WHERE segments.start_sequence > ?1 AND segments.start_sequence <= ?2
             GROUP BY kinds.kind",
        )?;
        let mut rows = statement.query(params![totals.through_start, through])?;
        while let Some(row) = rows.next()? {
            *totals.kinds.entry(row.get(0)?).or_default() += to_u64(row.get(1)?);
        }
    }
    snapshot.commit()?;
    totals.through_start = through;
    let by_codec: Vec<SegmentCodecSnapshot> = totals.by_codec.values().cloned().collect();
    let mut kinds: Vec<SegmentKindSnapshot> = totals
        .kinds
        .iter()
        .map(|(kind, segments)| SegmentKindSnapshot { kind: kind.clone(), segments: *segments })
        .collect();
    kinds.sort_by(|a, b| b.segments.cmp(&a.segments).then(a.kind.cmp(&b.kind)));
    kinds.truncate(LISTED_KINDS);
    let section = SegmentDiskSnapshot {
        segments: by_codec.iter().map(|codec| codec.segments).sum(),
        records: by_codec.iter().map(|codec| codec.records).sum(),
        compressed_bytes: by_codec.iter().map(|codec| codec.compressed_bytes).sum(),
        uncompressed_bytes: by_codec.iter().map(|codec| codec.uncompressed_bytes).sum(),
        by_codec,
        kinds,
    };
    cache.segments = Some(totals);
    Ok(section)
}

#[cfg(unix)]
fn file_identity(path: &Path) -> Option<(u64, u64)> {
    use std::os::unix::fs::MetadataExt;
    std::fs::metadata(path).ok().map(|metadata| (metadata.dev(), metadata.ino()))
}

#[cfg(not(unix))]
fn file_identity(path: &Path) -> Option<(u64, u64)> {
    // No inode here: the creation time stands in for the file's identity
    // (an output cleanup renames a new file into place).
    let metadata = std::fs::metadata(path).ok()?;
    let modified = metadata
        .created()
        .ok()
        .and_then(|time| time.duration_since(std::time::UNIX_EPOCH).ok())
        .map_or(0, |since| u64::try_from(since.as_nanos()).unwrap_or(u64::MAX));
    Some((modified, 0))
}

/// Lists `directory` into `snapshot.files`, visiting at most
/// [`MAX_DIRECTORY_ENTRIES`] entries. Symbolic links count as themselves.
fn list_directory(directory: &Path, snapshot: &mut DiskUsageSnapshot) {
    let Ok(entries) = std::fs::read_dir(directory) else { return };
    let mut budget = MAX_DIRECTORY_ENTRIES;
    let mut files = Vec::new();
    for entry in entries.flatten() {
        if budget == 0 {
            snapshot.files_truncated = true;
            break;
        }
        budget -= 1;
        let Ok(metadata) = entry.path().symlink_metadata() else { continue };
        let name = entry.file_name().to_string_lossy().into_owned();
        let (bytes, count) = if metadata.is_dir() {
            let (bytes, count, truncated) = directory_size(&entry.path(), &mut budget);
            snapshot.files_truncated |= truncated;
            (bytes, count)
        } else {
            (metadata.len(), 1)
        };
        files.push(DiskFileSnapshot { name, bytes, files: count });
    }
    files.sort_by(|a, b| b.bytes.cmp(&a.bytes).then(a.name.cmp(&b.name)));
    snapshot.files_unlisted = files.len().saturating_sub(LISTED_FILES) as u64;
    files.truncate(LISTED_FILES);
    snapshot.files = files;
}

/// Bytes and files under `directory`, taking entries from `budget`; true
/// when the budget ran out first.
fn directory_size(directory: &Path, budget: &mut u64) -> (u64, u64, bool) {
    let mut pending = vec![directory.to_path_buf()];
    let (mut bytes, mut files) = (0u64, 0u64);
    while let Some(next) = pending.pop() {
        let Ok(entries) = std::fs::read_dir(&next) else { continue };
        for entry in entries.flatten() {
            if *budget == 0 {
                return (bytes, files, true);
            }
            *budget -= 1;
            let Ok(metadata) = entry.path().symlink_metadata() else { continue };
            if metadata.is_dir() {
                pending.push(entry.path());
            } else {
                bytes = bytes.saturating_add(metadata.len());
                files += 1;
            }
        }
    }
    (bytes, files, false)
}

/// Every live journal kind's rows and bytes, by a full scan: for tests and
/// offline tools only, never a request.
#[cfg(test)]
pub(crate) fn journal_bytes_by_kind(
    connection: &Connection,
) -> anyhow::Result<BTreeMap<String, (u64, u64)>> {
    let mut statement = connection.prepare(&format!(
        "SELECT kind, COUNT(*), SUM({JOURNAL_ROW_BYTES_SQL}) FROM session_journal GROUP BY kind"
    ))?;
    let rows = statement.query_map([], |row| {
        Ok((row.get::<_, String>(0)?, row.get::<_, i64>(1)?, row.get::<_, i64>(2)?))
    })?;
    let mut kinds = BTreeMap::new();
    for row in rows {
        let (kind, count, bytes) = row?;
        kinds.insert(kind, (u64::try_from(count)?, u64::try_from(bytes)?));
    }
    Ok(kinds)
}
