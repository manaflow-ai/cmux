//! What the last passes measured, so the next one does not walk it all again.
//!
//! A care pass used to read every worktree's facts (a dozen git runs each)
//! and walk every folder it might free, every tick: its cost grew with the
//! tree. The memo keeps, in the archive store (`.care-walk-memo`, not a
//! manifest):
//!
//! - a measured folder's sizes, walked again once they are older than their
//!   time to live, and only while the pass's walk budget lasts: a pass's
//!   cost stays the same however many folders there are. A folder never
//!   measured is always walked.
//! - a worktree's facts, read again when a cheap signature (HEAD, branch,
//!   the times of its folder, index, HEAD, reflog and its branch's refs)
//!   moves or their time to live ends.
//!
//! Both only describe: before a pass acts on a worktree it reads its facts
//! afresh (`inventory::rescan` bypasses the memo) and decides again.
//!
//! Only the thread of a pass that opened the memo (`open`) uses it; everything else walks
//! and reads as before.

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::cell::{Cell, RefCell};

use serde::{Deserialize, Serialize};

use crate::disk::Sizes;
use crate::inventory::Facts;

const FILE: &str = ".care-walk-memo";
/// How long a measured size or read facts stand before they are read again;
/// each entry adds up to as much again, by its path, so they do not all end
/// on the same tick.
const TTL_MS: u64 = 30 * 60 * 1000;
/// The most entries one pass stats to measure again folders it measured
/// before (new folders are always measured).
pub const REWALK_BUDGET: u64 = 200_000;
/// Entries not seen for this long are dropped.
const FORGET_MS: u64 = 7 * 24 * 60 * 60 * 1000;

#[derive(Debug, Default, Serialize, Deserialize)]
struct Memo {
    #[serde(default)]
    sizes: HashMap<String, SizeEntry>,
    #[serde(default)]
    facts: HashMap<String, FactsEntry>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct SizeEntry {
    at: u64,
    seen: u64,
    total: u64,
    #[serde(default)]
    parts: Vec<(PathBuf, u64)>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct FactsEntry {
    at: u64,
    seen: u64,
    sig: Signature,
    facts: Facts,
}

/// What a worktree's facts were read under.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Signature {
    pub head: Option<String>,
    pub branch: Option<String>,
    pub times: Vec<u64>,
}

struct Open {
    dir: PathBuf,
    memo: Memo,
    budget: u64,
}

thread_local! {
    // A pass runs on one thread: the memo and its counters are that thread's.
    static MEMO: RefCell<Option<Open>> = const { RefCell::new(None) };
    static COST: Cell<Cost> = const { Cell::new(Cost::ZERO) };
}

/// What a pass's walks and reads cost.
#[derive(Debug, Default, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Cost {
    /// Entries stat'ed by the size walks.
    pub stats: u64,
    /// Folders listed by the size walks.
    pub dirs: u64,
    /// Bytes the size walks added up.
    pub bytes: u64,
    /// Sizes walked / answered from the memo.
    pub sizes_walked: u64,
    pub sizes_reused: u64,
    /// Worktrees whose facts were read with git / answered from the memo.
    pub facts_read: u64,
    pub facts_reused: u64,
}

impl Cost {
    const ZERO: Cost = Cost {
        stats: 0,
        dirs: 0,
        bytes: 0,
        sizes_walked: 0,
        sizes_reused: 0,
        facts_read: 0,
        facts_reused: 0,
    };
}

/// Adds to this thread's cost.
pub(crate) fn count(add: impl FnOnce(&mut Cost)) {
    COST.with(|cost| {
        let mut now = cost.get();
        add(&mut now);
        cost.set(now);
    });
}

fn stats() -> u64 {
    COST.with(|cost| cost.get().stats)
}

/// This thread's cost so far, counters reset.
pub fn take_cost() -> Cost {
    COST.with(|cost| cost.replace(Cost::ZERO))
}

/// Whether the memo is switched off (`CMUX_CARE_NO_MEMO=1`: every pass
/// walks and reads everything, as before it existed).
fn disabled() -> bool {
    std::env::var_os("CMUX_CARE_NO_MEMO").is_some_and(|v| !v.is_empty() && v != "0")
}

/// Loads the memo kept in `dir` for this pass; a missing or unreadable one
/// starts empty.
pub fn open(dir: &Path) {
    if disabled() {
        return;
    }
    let memo = std::fs::read(dir.join(FILE))
        .ok()
        .and_then(|bytes| serde_json::from_slice::<Memo>(&bytes).ok())
        .unwrap_or_default();
    MEMO.with(|m| *m.borrow_mut() = Some(Open { dir: dir.to_path_buf(), memo, budget: REWALK_BUDGET }));
}

/// Writes the memo back (entries not seen for a week dropped) and closes it.
pub fn close(now: u64) -> Result<(), String> {
    let Some(mut open) = MEMO.with(|m| m.borrow_mut().take()) else { return Ok(()) };
    let fresh = |seen: u64| now.saturating_sub(seen) < FORGET_MS;
    open.memo.sizes.retain(|_, e| fresh(e.seen));
    open.memo.facts.retain(|_, e| fresh(e.seen));
    let bytes = serde_json::to_vec(&open.memo).map_err(|e| e.to_string())?;
    let path = open.dir.join(FILE);
    let tmp = open.dir.join(format!("{FILE}.{}.tmp", std::process::id()));
    std::fs::write(&tmp, bytes).map_err(|e| format!("{}: {e}", tmp.display()))?;
    std::fs::rename(&tmp, &path).map_err(|e| {
        let _ = std::fs::remove_file(&tmp);
        format!("{}: {e}", path.display())
    })
}

fn with<R>(f: impl FnOnce(&mut Option<Open>) -> R) -> R {
    MEMO.with(|m| f(&mut m.borrow_mut()))
}

/// The time to live of the entry at `key`: TTL plus up to TTL more, by its
/// key, so entries measured on one tick come due on different ones.
fn ttl(key: &str) -> u64 {
    let hash = key.bytes().fold(0xcbf2_9ce4_8422_2325u64, |h, b| {
        (h ^ u64::from(b)).wrapping_mul(0x0000_0100_0000_01b3)
    });
    TTL_MS + hash % TTL_MS
}

fn size_key(root: &Path, parts: &[PathBuf]) -> String {
    let mut parts: Vec<String> = parts.iter().map(|p| p.display().to_string()).collect();
    parts.sort();
    format!("{}\0{}", root.display(), parts.join("\0"))
}

/// `walk(root)`'s sizes, from the memo when they stand: measured within
/// their time to live, or older but the pass's walk budget spent.
pub(crate) fn sizes(
    root: &Path,
    parts: &[PathBuf],
    now: u64,
    walk: impl FnOnce() -> Sizes,
) -> Sizes {
    let key = size_key(root, parts);
    let reused = with(|open| {
        let open = open.as_mut()?;
        let entry = open.memo.sizes.get_mut(&key)?;
        let due = now.saturating_sub(entry.at) >= ttl(&key);
        if due && open.budget > 0 {
            return None;
        }
        entry.seen = now;
        Some(Sizes { total: entry.total, parts: entry.parts.iter().cloned().collect(), partial: false })
    });
    if let Some(sizes) = reused {
        count(|c| c.sizes_reused += 1);
        return sizes;
    }
    let before = stats();
    let sizes = walk();
    let spent = stats().saturating_sub(before);
    count(|c| {
        c.sizes_walked += 1;
        c.bytes += sizes.total;
    });
    with(|open| {
        let Some(open) = open.as_mut() else { return };
        open.budget = open.budget.saturating_sub(spent);
        if !sizes.partial {
            open.memo.sizes.insert(
                key,
                SizeEntry {
                    at: now,
                    seen: now,
                    total: sizes.total,
                    parts: sizes.parts.iter().map(|(p, b)| (p.clone(), *b)).collect(),
                },
            );
        }
    });
    sizes
}

/// The facts last read at `path`, while `sig` still matches and they stand.
pub(crate) fn facts(path: &Path, now: u64, sig: impl FnOnce(&Facts) -> Signature) -> Option<Facts> {
    let key = path.display().to_string();
    let cached = with(|open| {
        let entry = open.as_ref()?.memo.facts.get(&key)?;
        (now.saturating_sub(entry.at) < ttl(&key)).then(|| entry.clone())
    })?;
    if sig(&cached.facts) != cached.sig {
        return None;
    }
    with(|open| {
        if let Some(entry) = open.as_mut().and_then(|o| o.memo.facts.get_mut(&key)) {
            entry.seen = now;
        }
    });
    count(|c| c.facts_reused += 1);
    Some(cached.facts)
}

/// Whether this thread's pass opened the memo.
pub(crate) fn is_open() -> bool {
    with(|open| open.is_some())
}

/// Keeps facts just read at `path` under `sig`.
pub(crate) fn keep_facts(path: &Path, now: u64, sig: Signature, facts: &Facts) {
    count(|c| c.facts_read += 1);
    with(|open| {
        if let Some(open) = open.as_mut() {
            open.memo.facts.insert(
                path.display().to_string(),
                FactsEntry { at: now, seen: now, sig, facts: facts.clone() },
            );
        }
    });
}

#[cfg(test)]
pub(crate) fn reset_for_test() {
    with(|open| *open = None);
    let _ = take_cost();
}

#[cfg(test)]
#[path = "walk_memo_tests.rs"]
mod tests;
