//! One-time, opt-in compaction of the resource records that restate the
//! whole session.
//!
//! Before 38dd47965803 every full topology projection commit (a
//! `tab.update` among them) journaled an upsert of every live resource in
//! its record's `payload.changes`: 5,713 upserts and 2.5 MB per record in a
//! session of 826 workspaces, and one index row per named resource and
//! record. New records carry only the upserts whose value the journal does
//! not already state (`public_fold.rs`), but a sealed segment is immutable,
//! so a registry of that era keeps its history (one was 10 GB, with an empty
//! freelist).
//!
//! The compaction runs through the output cleanup's pipeline (the
//! `output_cleanup` module docs: a new file staged beside the registry,
//! swapped at the next start, the old file kept as `.pre-output-cleanup`
//! until the next good start, a rollback when the new file does not open),
//! as [`CleanupMode::Compact`]. In that mode the pipeline drops no session
//! put, and the pack rewrites each resource record.
//!
//! # The rewrite
//!
//! A resource record is a record with a `resource_revision` and an array at
//! `payload.changes`. The pack reads every record in sequence order (sealed
//! segments, then the live rows, then the records appended since) and folds
//! the changes of the tracked resources ([`TRACKED_RESOURCES`], as
//! `public_fold.rs`): an `upsert` sets the value of its `(resource, id)`, a
//! `delete` removes it. An `upsert` whose value is the one the fold already
//! holds is removed from the record; a replay of the journal reaches the
//! same state at that record with or without it. The remaining changes keep
//! their order, and those that carry a `sequence` field are numbered again
//! from 0, as `prune_stated_topology_deltas` numbers a new record's.
//! Changes of other resources and other kinds are not read.
//!
//! Every record stays, with its sequence, kind, event id, times and
//! resource revisions; a record whose changes all go keeps `"changes": []`
//! (the checkpoint reducer, the resource event page and the session event
//! stream accept an empty array). A record that loses no change keeps its
//! bytes. The fold ([`StatedFold`]) is a hash per live resource, committed
//! in the staging transaction of the segment it covers, so a quit resumes
//! with the fold of exactly the packed journal. A record the pack cannot
//! decode fails the compaction (the registry stays as it is): skipping it
//! would leave the fold wrong for every later record.
//!
//! A registry that already had an output cleanup has gaps in its sealed
//! segments. The staging pass of this mode accepts a gap that one row of the
//! registry's `journal_pruned_ranges` covers (`SegmentGaps::Pruned`) and
//! counts those sequences as removed; the pack writes them as pruned ranges
//! again. The output cleanup still refuses such a segment: for it a gap is
//! damage.
//!
//! # Subjects
//!
//! A rewritten record's subjects are narrowed, and so are its
//! `journal_subject_index` rows (the pack derives them from the subjects).
//! The live path names as subjects the session, the resources of the
//! commit's patch, every public id in the result and the changes, and their
//! ancestors (`session_journal.rs` `append_resource_journal_record_at`); a
//! record that restated 5,713 resources has that many index rows, twice
//! (the table and its by-subject index), which is most of such a registry's
//! file. The patch and the tables of that commit are gone, so the subjects
//! cannot be computed again; instead a subject is removed when its id is a
//! string of a removed change and of nothing the record still holds (its
//! result and its kept changes). The session subject always stays. A
//! subject that came only from the patch or an ancestor lookup stays unless
//! a removed change named it.
//!
//! What reads subjects: a journal stream filtered by subject
//! (`session_journal.rs`, `journal_filter.rs`) no longer returns an old
//! record for a resource it only restated, which is what a new record does
//! since 38dd47965803; the agent roster's salvage of an undecodable range
//! (`session_journal/salvage.rs`) marks fewer terminals; a hook's subject
//! filter (`journal_hooks.rs`) sees the narrower set if a hook is ever
//! dispatched an old record. No reader needs the wider set to be correct.
//!
//! # Bounds
//!
//! The output cleanup refuses a journal it would mostly copy (it exists to
//! drop records). A rewrite copies every record by design, so this mode
//! replaces those bounds: at most [`MAX_KEPT_RECORDS`] records, free space
//! of the registry's own size plus the margin before it stages (the new
//! file and the staged records together stay under the registry's size),
//! and a staging file of at most the registry's size plus the margin.
//!
//! # Opt-in
//!
//! Off by default. The owner runs it only when [`OPT_IN_ENV`] is `1` in the
//! daemon's environment at start, and once per registry
//! ([`DONE_META_KEY`]). It writes no output cleanup marker: that cleanup's
//! state is its own.

use std::collections::HashSet;
use std::ffi::OsStr;
use std::path::Path;

use anyhow::Context as _;
use rusqlite::Connection;
use serde::Deserialize;
use serde_json::Value;

use super::stated_fold::{FoldDelta, StatedFold, StatedKey, value_hash};
use super::{CleanupMode, DISK_MARGIN_BYTES, disk_margin};

/// Registry meta key set once the compaction swapped (or found an empty
/// journal): a registry with this key is never compacted again.
pub(crate) const DONE_META_KEY: &str = "journal_compact_v1";
/// The environment variable that turns the compaction on (`1`).
pub(crate) const OPT_IN_ENV: &str = "CMUX_TUI_JOURNAL_COMPACT";
/// Records past which the compaction does not run: the pack copies each of
/// them (2.4M records of a 10 GB registry staged and packed in minutes).
pub(super) const MAX_KEPT_RECORDS: u64 = 8_000_000;
/// The staging file's size bound whatever the registry's size.
const MAX_STAGED_BYTES: u64 = 64 << 30;
/// The resources the fold tracks, as `public_fold.rs` `TRACKED_RESOURCES`.
const TRACKED_RESOURCES: [&str; 6] = ["workspace", "screen", "pane", "tab", "terminal", "browser"];

/// The compaction's staging state keys and their initial values.
pub(super) const COMPACT_STATE: [(&str, &str); 3] = [
    // The staging file's size bound, set when the file is created.
    ("compact_staged_limit", "0"),
    ("compact_rewritten", "0"),
    ("compact_removed_changes", "0"),
];

/// Whether `value` (of [`OPT_IN_ENV`]) asks for the compaction.
pub(crate) fn requested(value: Option<&OsStr>) -> bool {
    value.is_some_and(|value| value == "1")
}

/// Whether this process was started with the opt-in.
pub(crate) fn requested_by_env() -> bool {
    requested(std::env::var_os(OPT_IN_ENV).as_deref())
}

/// The cleanup the owner schedules at start, if any: the compaction when it
/// is asked for and not done, else the output cleanup when that is not
/// done.
pub(crate) fn scheduled_mode(
    compact_requested: bool,
    compact_done: bool,
    output_done: bool,
) -> Option<CleanupMode> {
    if compact_requested && !compact_done {
        Some(CleanupMode::Compact)
    } else if !output_done {
        Some(CleanupMode::Output)
    } else {
        None
    }
}

/// The registry's size: its pages and its WAL.
pub(super) fn source_bytes(source: &Connection, db_path: &Path) -> anyhow::Result<u64> {
    let (pages, size): (i64, i64) = source.query_row(
        "SELECT (SELECT page_count FROM pragma_page_count()),
                (SELECT page_size FROM pragma_page_size())",
        [],
        |row| Ok((row.get(0)?, row.get(1)?)),
    )?;
    let wal = super::file_len(&super::super::open_guard::sidecar_path(db_path, "-wal"));
    Ok(u64::try_from(pages.max(0).saturating_mul(size)).unwrap_or(u64::MAX).saturating_add(wal))
}

/// The staging file's size bound for a registry of `source_bytes`.
pub(super) fn staged_limit(source_bytes: u64) -> u64 {
    source_bytes.saturating_add(DISK_MARGIN_BYTES).min(MAX_STAGED_BYTES)
}

/// `Err(reason)` when the directory of `db_path` has less free space than a
/// registry of `source_bytes` plus the margin.
pub(super) fn free_space_refusal(
    db_path: &Path,
    source_bytes: u64,
) -> anyhow::Result<Result<(), String>> {
    let dir = db_path.parent().unwrap_or(Path::new("."));
    let available = fs4::available_space(dir)?;
    let needed = source_bytes.saturating_add(disk_margin());
    Ok(if available < needed {
        Err(format!(
            "{} MiB free in {}, {} MiB needed to compact the journal (the registry's {} MiB and \
             a {} MiB margin)",
            available >> 20,
            dir.display(),
            needed >> 20,
            source_bytes >> 20,
            disk_margin() >> 20
        ))
    } else {
        Ok(())
    })
}

/// `Some(reason)` when a compaction would copy more than
/// [`MAX_KEPT_RECORDS`] records.
pub(super) fn kept_refusal(kept: u64, total: u64) -> Option<String> {
    (kept > MAX_KEPT_RECORDS).then(|| {
        format!(
            "{kept} of {total} journal records would be copied, over the compaction's bound of \
             {MAX_KEPT_RECORDS}"
        )
    })
}

/// A rewritten record.
pub(super) struct Rewritten {
    /// The record's JSON without the restated upserts.
    pub(super) json: Vec<u8>,
    /// Its narrowed subjects, a JSON array.
    pub(super) subjects: String,
    /// Changes removed.
    pub(super) removed: u64,
}

/// What one record does to the fold, and its rewrite when it restates.
#[derive(Default)]
pub(super) struct Folded {
    /// `None` when the record keeps its bytes.
    pub(super) rewritten: Option<Rewritten>,
    /// The record's changes to the fold.
    pub(super) delta: FoldDelta,
}

/// The one field that tells a resource record; serde skips the rest.
#[derive(Deserialize)]
struct RecordHead {
    #[serde(default)]
    resource_revision: Option<u64>,
}

fn change_text<'a>(change: &'a Value, field: &str) -> Option<&'a str> {
    change.get(field).and_then(Value::as_str)
}

/// Every string inside `value`, object keys excluded.
fn collect_strings<'a>(value: &'a Value, strings: &mut HashSet<&'a str>) {
    match value {
        Value::String(text) => {
            strings.insert(text.as_str());
        }
        Value::Array(items) => items.iter().for_each(|item| collect_strings(item, strings)),
        Value::Object(fields) => fields.values().for_each(|field| collect_strings(field, strings)),
        Value::Null | Value::Bool(_) | Value::Number(_) => {}
    }
}

/// Folds the archived record `json` over `fold` with `pending` (the earlier
/// records of the open segment) applied, and rewrites it when it restates a
/// value. Neither the fold nor `pending` changes: the caller applies the
/// returned delta once the record is in the segment.
pub(super) fn fold_record(
    json: &[u8],
    fold: &StatedFold,
    pending: &FoldDelta,
) -> anyhow::Result<Folded> {
    let head: RecordHead =
        serde_json::from_slice(json).context("a staged journal record is invalid")?;
    if head.resource_revision.is_none() {
        return Ok(Folded::default());
    }
    let mut record: Value =
        serde_json::from_slice(json).context("a staged resource record is invalid")?;
    let Some(changes) =
        record.get_mut("payload").and_then(|payload| payload.get_mut("changes")).map(Value::take)
    else {
        return Ok(Folded::default());
    };
    let Value::Array(changes) = changes else {
        // Not a change list: the record keeps its bytes (`record` is dropped).
        return Ok(Folded::default());
    };
    // This record's own changes so far, over `pending` and the fold.
    let mut local = FoldDelta::new();
    let mut kept = Vec::with_capacity(changes.len());
    let mut removed = Vec::new();
    for change in changes {
        let (Some(kind), Some(resource), Some(id)) = (
            change_text(&change, "kind"),
            change_text(&change, "resource"),
            change_text(&change, "id"),
        ) else {
            kept.push(change);
            continue;
        };
        if !TRACKED_RESOURCES.contains(&resource) || !matches!(kind, "upsert" | "delete") {
            kept.push(change);
            continue;
        }
        let key: StatedKey = (resource.to_owned(), id.to_owned());
        if kind == "delete" {
            local.insert(key, None);
            kept.push(change);
            continue;
        }
        // An upsert without a value states null, as the public fold reads it.
        let hash = value_hash(change.get("value").unwrap_or(&Value::Null));
        let stated = match local.get(&key) {
            Some(stated) => *stated,
            None => fold.stated(pending, &key),
        };
        if stated == Some(hash) {
            removed.push(change);
        } else {
            local.insert(key, Some(hash));
            kept.push(change);
        }
    }
    if removed.is_empty() {
        return Ok(Folded { rewritten: None, delta: local });
    }
    for (index, change) in kept.iter_mut().enumerate() {
        if let Some(object) = change.as_object_mut()
            && object.contains_key("sequence")
        {
            object.insert("sequence".into(), Value::from(index));
        }
    }
    if let Some(slot) = record.get_mut("payload").and_then(|payload| payload.get_mut("changes")) {
        *slot = Value::Array(kept);
    }
    let subjects = {
        let mut gone = HashSet::new();
        removed.iter().for_each(|change| collect_strings(change, &mut gone));
        let mut held = HashSet::new();
        if let Some(payload) = record.get("payload") {
            collect_strings(payload, &mut held);
        }
        let narrowed = record
            .get("subjects")
            .and_then(Value::as_array)
            .map(|subjects| {
                subjects
                    .iter()
                    .filter(|subject| {
                        let id = change_text(subject, "id").unwrap_or_default();
                        change_text(subject, "kind") == Some("session")
                            || !gone.contains(id)
                            || held.contains(id)
                    })
                    .cloned()
                    .collect::<Vec<_>>()
            })
            .unwrap_or_default();
        Value::Array(narrowed)
    };
    let subjects_json = subjects.to_string();
    if let Some(slot) = record.get_mut("subjects") {
        *slot = subjects;
    }
    Ok(Folded {
        rewritten: Some(Rewritten {
            json: serde_json::to_vec(&record)?,
            subjects: subjects_json,
            removed: removed.len() as u64,
        }),
        delta: local,
    })
}
