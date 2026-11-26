//! Per-session store budget: what one chat keeps in acpmux's own store, its event log
//! (`sessions/<id>/`: the `events/` segments, their indexes, `session.json`) and its background
//! tasks' output (`bg/<id>/`). Leo, 2026-11-24: "we can design out hosts becoming overloaded by
//! building and using our designs and gradually migrating and testing and creating experiments
//! and trialing as we go in order to fan out, and to be solving more and more and finding better
//! and better tradeoffs".
//!
//! Measured on a lane VM (2026-11-24, 361 chats, 1.84 GB): the median chat keeps 1.7 MB; the
//! largest 113.5 MB over 76 h and 386 turns (1.4 MB/h, 0.28 MB a turn); the fastest per turn 2.2
//! MB a turn (32 turns, 74 MB). The log only grows while a chat is open
//! (`hub/cold_segments.rs`), and nothing in the store bounds it.
//!
//! The budget, `ACPMUX_SESSION_STORE_MB` in the daemon's env (0 turns it off), defaults to an
//! eighth of the session's disk budget (`session_budget::disk_default`) between [`FLOOR`] and
//! [`CEILING`]: 1 GiB on an 8 GiB-per-lane host, 9x the largest chat measured. Every [`TICK`]
//! `hub/session_budget_watch.rs` measures each loaded chat's store, bounded ([`MAX_SESSIONS`],
//! [`MAX_FILES`]); a chat past its budget
//! - is told once in its chat, and again each time it doubles from there ([`Watch::apply`]);
//! - has its sealed log segments compressed, losslessly, through the cold segment move
//!   (`store/cold_segments.rs`: every byte kept, checked before the segment goes, read back in
//!   place), whatever `agents.chats.coldSegments` says (`ACPMUX_SESSION_STORE_COMPRESS=0` turns
//!   that part off). Nothing a person reads is deleted: the transcript stays whole.
//!
//! `daemon.log` is capped already (`daemon/log_cap.rs`), and so is a background task's output.
#![cfg_attr(not(target_os = "linux"), allow(dead_code))]

use serde_json::{Value, json};
use std::collections::BTreeMap;
use std::path::Path;
use std::sync::{Mutex, OnceLock};
use std::time::Duration;

/// How often the store is measured: a chat's log grows megabytes an hour, not a second.
pub(crate) const TICK: Duration = Duration::from_secs(300);
/// The most chats one pass measures.
pub(crate) const MAX_SESSIONS: usize = 4096;
/// The most files one chat's measure visits; past it the reading is partial (a floor).
pub(crate) const MAX_FILES: usize = 8192;
/// The default budget's least and most.
pub(crate) const FLOOR: u64 = 256 << 20;
pub(crate) const CEILING: u64 = 8 << 30;
/// The default with no disk budget to size it from.
pub(crate) const UNSIZED: u64 = 1 << 30;
/// How many chats `daemon status` lists (the largest, and every one over).
pub(crate) const LISTED: usize = 8;
const MIB: u64 = 1 << 20;

/// The default store budget for a session whose disk budget is `disk` bytes.
pub(crate) fn store_default(disk: u64) -> u64 {
    if disk == 0 {
        return UNSIZED;
    }
    (disk / 8).clamp(FLOOR, CEILING)
}

/// The store budget from `get` (a knob reader) and the session's disk budget; 0 is off.
pub(crate) fn budget_from(get: &dyn Fn(&str) -> Option<String>, disk: u64) -> u64 {
    get("ACPMUX_SESSION_STORE_MB")
        .and_then(|v| v.trim().parse::<u64>().ok())
        .map_or_else(|| store_default(disk), |mb| mb.saturating_mul(MIB))
}

/// Whether a chat over its budget has its sealed segments compressed (on unless set to 0).
pub(crate) fn compress_from(get: &dyn Fn(&str) -> Option<String>) -> bool {
    get("ACPMUX_SESSION_STORE_COMPRESS").is_none_or(|v| v.trim() != "0")
}

/// Bytes of the files under `dir` (symlinks not followed), visiting at most `*left` entries:
/// `(bytes, partial)`. A missing folder is 0 bytes.
pub(crate) fn dir_bytes(dir: &Path, left: &mut usize) -> (u64, bool) {
    let mut bytes = 0u64;
    let mut stack = vec![dir.to_path_buf()];
    while let Some(next) = stack.pop() {
        let Ok(entries) = std::fs::read_dir(&next) else { continue };
        for entry in entries.flatten() {
            if *left == 0 {
                return (bytes, true);
            }
            *left -= 1;
            let Ok(meta) = entry.path().symlink_metadata() else { continue };
            if meta.is_dir() {
                stack.push(entry.path());
            } else if meta.is_file() {
                bytes = bytes.saturating_add(meta.len());
            }
        }
    }
    (bytes, false)
}

/// One chat's store, `(bytes, partial)`: its folder and its background tasks' output.
pub(crate) fn measure(session_dir: Option<&Path>, bg_dir: &Path) -> (u64, bool) {
    let mut left = MAX_FILES;
    let (log, a) = session_dir.map_or((0, false), |d| dir_bytes(d, &mut left));
    let (bg, b) = dir_bytes(bg_dir, &mut left);
    (log.saturating_add(bg), a || b)
}

/// What the watcher does for one chat.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Action {
    /// Tell the chat it passed its budget, at `bytes`.
    Warn { bytes: u64 },
    /// Compress its sealed segments (lossless).
    Compress,
}

/// One chat's last reading.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub(crate) struct Entry {
    pub bytes: u64,
    pub partial: bool,
    /// The reading it was last told at (0: not told, or back under the budget since).
    pub warned: u64,
    /// Bytes the compression saved it so far (raw minus compressed).
    pub saved: u64,
}

/// The watcher's state: the budget and each chat's reading.
#[derive(Debug, Default)]
pub(crate) struct Watch {
    pub budget: u64,
    pub compress: bool,
    pub sessions: BTreeMap<String, Entry>,
    /// Whether the last pass met more than [`MAX_SESSIONS`] chats.
    pub truncated: bool,
    pub passes: u64,
}

impl Watch {
    /// Takes one pass's `readings` (`(chat, bytes, partial)`) and answers what to do. A chat is
    /// compressed each pass it is over, told when it first passes the budget and each time it
    /// doubles from the reading it was told at, and told again only after it fell under nine
    /// tenths of the budget. Chats not in `readings` are forgotten.
    pub(crate) fn apply(&mut self, readings: Vec<(String, u64, bool)>) -> Vec<(String, Action)> {
        let mut kept = BTreeMap::new();
        let mut out = Vec::new();
        for (id, bytes, partial) in readings {
            let mut entry = self.sessions.remove(&id).unwrap_or_default();
            (entry.bytes, entry.partial) = (bytes, partial);
            if self.budget > 0 && bytes >= self.budget {
                if self.compress {
                    out.push((id.clone(), Action::Compress));
                }
                if entry.warned == 0 || bytes >= entry.warned.saturating_mul(2) {
                    entry.warned = bytes;
                    out.push((id.clone(), Action::Warn { bytes }));
                }
            } else if bytes < self.budget / 10 * 9 {
                entry.warned = 0;
            }
            kept.insert(id, entry);
        }
        self.sessions = kept;
        self.passes += 1;
        out
    }

    /// `daemon status`'s `sessionBudgets.store`: the budget, the totals, and the largest chats
    /// with every one over.
    pub(crate) fn json(&self, on: bool) -> Value {
        let mut rows: Vec<(&String, &Entry)> = self.sessions.iter().collect();
        rows.sort_by(|a, b| b.1.bytes.cmp(&a.1.bytes).then(a.0.cmp(b.0)));
        let over = |e: &Entry| self.budget > 0 && e.bytes >= self.budget;
        let listed: Vec<Value> = rows
            .iter()
            .enumerate()
            .filter(|(i, (_, e))| *i < LISTED || over(e))
            .map(|(_, (id, e))| {
                json!({
                    "session": id,
                    "bytes": e.bytes,
                    "partial": e.partial,
                    "state": if over(e) { "over" } else { "ok" },
                    "savedBytes": e.saved,
                })
            })
            .collect();
        json!({
            "on": on && self.budget > 0,
            "budgetBytes": self.budget,
            "compress": self.compress,
            "tickSeconds": TICK.as_secs(),
            "passes": self.passes,
            "truncated": self.truncated,
            "sessions": self.sessions.len(),
            "totalBytes": self.sessions.values().map(|e| e.bytes).sum::<u64>(),
            "over": self.sessions.values().filter(|e| over(e)).count(),
            "use": listed,
        })
    }
}

/// The daemon's one watch.
pub(crate) fn shared() -> &'static Mutex<Watch> {
    static WATCH: OnceLock<Mutex<Watch>> = OnceLock::new();
    WATCH.get_or_init(Default::default)
}

#[cfg(test)]
#[path = "session_store_tests.rs"]
mod tests;
