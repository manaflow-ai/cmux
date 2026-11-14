//! Parked snapshots trim as they age (plans/cmux-next/sidebar-recents-and-freeing-DESIGN.md, "What is kept on disk
//! for a freed terminal"). A terminal whose shell ended but whose tab stays (a freed or parked tab, an ended
//! shell) keeps its snapshot so a show draws its old screen; the older it is, the fewer lines it keeps:
//!
//! | Since its last write | Lines kept |
//! | --- | --- |
//! | under 1 day | all (about [`super::SNAPSHOT_HISTORY_LINES`]) |
//! | 1 to 7 days | [`WEEK_LINES`] |
//! | 7 to 30 days | [`MONTH_LINES`] |
//! | over 30 days | none: the file goes (the tab's relaunch record stays) |
//!
//! Over `terminal.persistence.parkedMaxTotalBytes` (default [`DEFAULT_PARKED_MAX_TOTAL_BYTES`]) the oldest parked
//! snapshots step down a tier first, then go. Under `terminal.persistence.minFreeDiskBytes` (default
//! [`DEFAULT_MIN_FREE_DISK_BYTES`]) or 5% of the disk free, no trim rewrites a file: a snapshot that is due to trim
//! goes instead, so a full disk only ever loses bytes. A trim rewrites a file only when it changes tier (the header
//! records `kept_lines`) and keeps its `written_at_ms`, so a file is rewritten at most twice in its life. A running
//! terminal's snapshot, or one the daemon has not placed yet, is never touched.
//!
//! The pass runs with the store's prune (daemon start, a mode change) and once a day from the writer, busy or idle.
//! A terminal is parked when the workspace store keeps a tab of it and no shell of it runs (`Mux::parked_terminal_ids`),
//! so a file parked before a daemon restart still trims.

use std::collections::HashSet;
use std::fs;
use std::io::Write;
use std::path::Path;
use std::time::Duration;

use flate2::Compression;
use flate2::write::GzEncoder;

use crate::resource::TerminalPublicId;

/// Lines a parked snapshot keeps from 1 to 7 days.
pub(crate) const WEEK_LINES: usize = 500;
/// Lines a parked snapshot keeps from 7 to 30 days (about one screen).
pub(crate) const MONTH_LINES: usize = 100;
const DAY_MS: u64 = 24 * 60 * 60 * 1000;
/// The parked snapshots' disk budget.
pub(crate) const DEFAULT_PARKED_MAX_TOTAL_BYTES: u64 = 256 * 1024 * 1024;
/// Free disk under which no trim rewrites a file.
pub(crate) const DEFAULT_MIN_FREE_DISK_BYTES: u64 = 5 * 1024 * 1024 * 1024;
pub(crate) const PARKED_MAX_TOTAL_SETTING: &str = "terminal.persistence.parkedMaxTotalBytes";
pub(crate) const MIN_FREE_DISK_SETTING: &str = "terminal.persistence.minFreeDiskBytes";
/// The most files one pass rewrites (removals are not capped: they only free disk).
const MAX_REWRITES_PER_PASS: usize = 16;
/// How often the writer runs the pass, busy or idle.
pub(crate) const PASS_EVERY: Duration = Duration::from_secs(24 * 60 * 60);

/// What a parked snapshot keeps.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub(crate) enum Keep {
    /// The file goes; the record alone stays.
    RecordOnly,
    /// The newest `n` lines and the screen.
    Lines(usize),
    /// Everything it has.
    All,
}

impl Keep {
    /// The tier of a snapshot last written `age_ms` ago.
    pub(crate) fn for_age(age_ms: u64) -> Self {
        match age_ms / DAY_MS {
            0 => Self::All,
            1..7 => Self::Lines(WEEK_LINES),
            7..30 => Self::Lines(MONTH_LINES),
            _ => Self::RecordOnly,
        }
    }

    /// One tier down (the budget's step).
    fn lower(self) -> Self {
        match self {
            Self::All => Self::Lines(WEEK_LINES),
            Self::Lines(lines) if lines > MONTH_LINES => Self::Lines(MONTH_LINES),
            _ => Self::RecordOnly,
        }
    }
}

/// One parked snapshot as the pass sees it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct Parked {
    pub(crate) terminal_id: TerminalPublicId,
    pub(crate) written_at_ms: u64,
    /// The lines a past trim kept (`None`: never trimmed).
    pub(crate) kept_lines: Option<usize>,
    pub(crate) bytes: u64,
}

impl Parked {
    /// What it keeps now (before this pass).
    fn current(&self) -> Keep {
        self.kept_lines.map_or(Keep::All, Keep::Lines)
    }
}

/// What the pass does to the parked snapshots: each change is a trim to fewer lines or a removal.
pub(crate) fn plan(
    parked: &[Parked],
    now_ms: u64,
    max_total_bytes: u64,
    disk_low: bool,
) -> Vec<(TerminalPublicId, Keep)> {
    let mut wants: Vec<(usize, &Parked, Keep)> = parked
        .iter()
        .enumerate()
        .map(|(index, file)| {
            (
                index,
                file,
                Keep::for_age(now_ms.saturating_sub(file.written_at_ms)).min(file.current()),
            )
        })
        .collect();
    // Over the budget: the oldest step down first, one tier a round, until it fits. A trimmed file's size is not
    // known before it is written, so a step counts half its bytes (the 500-line tier of a 2,000-line file is
    // smaller still): the next pass corrects an estimate that was short.
    let estimate = |file: &Parked, keep: Keep| match keep {
        Keep::RecordOnly => 0,
        _ if keep == file.current() => file.bytes,
        Keep::Lines(lines) if lines <= MONTH_LINES => file.bytes / 8,
        _ => file.bytes / 2,
    };
    let mut total: u64 = wants.iter().map(|(_, file, keep)| estimate(file, *keep)).sum();
    wants.sort_by_key(|(index, file, _)| (file.written_at_ms, *index));
    while total > max_total_bytes {
        let mut stepped = false;
        for (_, file, keep) in &mut wants {
            if total <= max_total_bytes {
                break;
            }
            if *keep == Keep::RecordOnly {
                continue;
            }
            let before = estimate(file, *keep);
            *keep = keep.lower();
            total = total - before + estimate(file, *keep);
            stepped = true;
        }
        if !stepped {
            break;
        }
    }
    wants
        .into_iter()
        .filter_map(|(_, file, keep)| {
            if keep == file.current() {
                return None;
            }
            // A low disk never gets a rewrite: what is due to trim goes instead.
            let keep = if disk_low { Keep::RecordOnly } else { keep };
            Some((file.terminal_id.clone(), keep))
        })
        .collect()
}

/// Whether `available` of `capacity` bytes free is under the guard: `min_free` or 5% of the disk.
pub(crate) fn disk_low(available: u64, capacity: u64, min_free: u64) -> bool {
    available < min_free || available < capacity / 20
}

/// Runs the pass over the snapshots of `parked`: terminals whose shell ended while their tab stays. A terminal the
/// daemon has not placed yet (it starts) is not in it: its file stays whole.
pub(super) fn run(
    directory: &Path,
    parked: &HashSet<TerminalPublicId>,
    now_ms: u64,
    max_total_bytes: u64,
    min_free: u64,
) {
    let low = fs4::available_space(directory)
        .ok()
        .zip(fs4::total_space(directory).ok())
        .is_some_and(|(available, capacity)| disk_low(available, capacity, min_free));
    run_with(directory, parked, now_ms, max_total_bytes, low);
}

/// [`run`] with the free-disk guard already read (`disk_low`).
pub(super) fn run_with(
    directory: &Path,
    parked_ids: &HashSet<TerminalPublicId>,
    now_ms: u64,
    max_total_bytes: u64,
    low: bool,
) {
    let Ok(entries) = fs::read_dir(directory) else { return };
    let parked: Vec<Parked> = entries
        .flatten()
        .filter_map(|entry| {
            let path = entry.path();
            (path.extension()? == super::snapshot::SUFFIX).then_some(())?;
            let terminal_id = TerminalPublicId::parse(path.file_stem()?.to_str()?).ok()?;
            // A tail continues the snapshot's screen; a trim keeps that screen, so the tail still replays over it.
            if !parked_ids.contains(&terminal_id) {
                return None;
            }
            let header = super::snapshot::read_header(&path)?;
            Some(Parked {
                terminal_id,
                written_at_ms: header.get("written_at_ms")?.as_u64()?,
                kept_lines: header
                    .get("kept_lines")
                    .and_then(serde_json::Value::as_u64)
                    .and_then(|lines| usize::try_from(lines).ok()),
                bytes: entry.metadata().ok()?.len(),
            })
        })
        .collect();
    if parked.is_empty() {
        return;
    }
    let (mut trimmed, mut removed, mut rewrites) = (0_usize, 0_usize, 0_usize);
    for (terminal_id, keep) in plan(&parked, now_ms, max_total_bytes, low) {
        let ok = match keep {
            Keep::RecordOnly => {
                fs::remove_file(super::snapshot::path(directory, &terminal_id)).is_ok()
            }
            // Each rewrite replays its file a dozen times under the store's pass lock: a backlog spreads over passes.
            Keep::Lines(_) if rewrites == MAX_REWRITES_PER_PASS => false,
            Keep::Lines(lines) => {
                rewrites += 1;
                trim(directory, &terminal_id, lines).is_ok_and(|done| done)
            }
            Keep::All => false,
        };
        match (ok, keep) {
            (true, Keep::RecordOnly) => removed += 1,
            (true, _) => trimmed += 1,
            // A trim that failed leaves the file as it was; the next pass tries again.
            _ => {}
        }
    }
    if trimmed + removed > 0 {
        eprintln!(
            "cmux-tui: terminal output store: {trimmed} parked snapshot(s) trimmed, {removed} removed \
             (age, budget {max_total_bytes} bytes{})",
            if low { ", low disk" } else { "" }
        );
    }
}

/// Rewrites `terminal_id`'s snapshot with its newest `lines` lines, keeping its header (`written_at_ms` included)
/// and recording `kept_lines`. False when there was nothing to read.
fn trim(directory: &Path, terminal_id: &TerminalPublicId, lines: usize) -> anyhow::Result<bool> {
    let file = super::snapshot::path(directory, terminal_id);
    let Some(mut header) = super::snapshot::read_header(&file) else { return Ok(false) };
    let Some((replay, _, _)) = super::snapshot::read(directory, terminal_id) else {
        return Ok(false);
    };
    let bytes = trimmed_replay(&replay.bytes, replay.cols, replay.rows, lines)
        .ok_or_else(|| anyhow::anyhow!("the snapshot does not replay"))?;
    header
        .as_object_mut()
        .ok_or_else(|| anyhow::anyhow!("the snapshot header is not an object"))?
        .insert("kept_lines".to_owned(), serde_json::json!(lines));
    let mut encoder = GzEncoder::new(Vec::new(), Compression::fast());
    encoder.write_all(&bytes)?;
    let compressed = encoder.finish()?;
    let staged = file.with_extension(format!("{}.tmp", super::snapshot::SUFFIX));
    {
        let mut out = fs::File::create(&staged)?;
        out.write_all(super::snapshot::MAGIC)?;
        serde_json::to_writer(&mut out, &header)?;
        out.write_all(b"\n")?;
        out.write_all(&compressed)?;
        out.sync_all()?;
    }
    fs::rename(&staged, &file)?;
    fs::File::open(directory)?.sync_all()?;
    Ok(true)
}

/// `replay` with at most `lines` lines of history above its screen (the newest ones), styles and modes kept.
/// A VT replay is bounded in bytes and keeps the newest rows that fit, so the bound is searched for: the largest
/// whose replay holds no more than `lines` history rows (about a dozen replays, once per tier change).
/// `None` when `replay` does not replay.
pub(crate) fn trimmed_replay(replay: &[u8], cols: u16, rows: u16, lines: usize) -> Option<Vec<u8>> {
    let (cols, rows) = (cols.max(1), rows.max(1));
    let parse = |bytes: &[u8]| {
        let mut terminal = ghostty_vt::Terminal::new(
            cols,
            rows,
            64 * 1024 * 1024,
            ghostty_vt::Callbacks::default(),
        )
        .ok()?;
        terminal.vt_write(bytes);
        Some(terminal)
    };
    let mut source = parse(replay)?;
    if source.scrollback_rows() <= lines {
        return Some(replay.to_vec());
    }
    let (mut low, mut high) = (1_usize, replay.len().max(2));
    let mut best = None;
    while low < high {
        let mid = low + (high - low) / 2;
        let Ok(bounded) = source.vt_replay_bounded(mid) else {
            // Too small to hold the screen: a larger bound.
            low = mid + 1;
            continue;
        };
        let bytes = bounded.into_self_contained_bytes();
        if parse(&bytes)?.scrollback_rows() <= lines {
            best = Some(bytes);
            low = mid + 1;
        } else {
            high = mid;
        }
    }
    best
}

#[cfg(test)]
#[path = "parked_trim_tests.rs"]
mod tests;
