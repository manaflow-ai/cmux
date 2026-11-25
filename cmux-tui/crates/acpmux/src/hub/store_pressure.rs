//! Part of `Hub`; see `hub/mod.rs`. A size cap on the store: the disk it lives on never fills
//! from it.
//!
//! Leo, 2026-11-24: "/home/cmux/.acpmux is full and 24 turns just died on it. clear disk
//! aggressively and make sure it can't fill up again". The retention pass (`retention.rs`) only
//! ever looked at age (closed 14 days) and ran every 6 h; the cold archive (`cold_archive.rs`) is
//! off by default. Nothing looked at size, so a lane VM with hundreds of chats closed this week
//! filled its disk and every turn on it failed `disk.full` (`store/journal_store/space.rs`).
//!
//! The retention worker now checks the store every [`CHECK_EVERY`] (one `statvfs`, and a walk of
//! the sessions folder's file sizes when a cap is set): it is under pressure when the sessions
//! folder holds more than `store.maxBytes` (default a quarter of its disk) or the disk has less
//! than `store.minFreePercent` free (default 15). Under pressure, whatever the 6 h spacing and the
//! chats' ages, it:
//!
//! 1. compacts every closed chat's log as the retention pass does (raw harness lines and long
//!    tool output go; every message stays, `store/compact.rs`), with the same holds: an agent,
//!    a client, a turn, a queue, a move or an import keep a chat whole;
//! 2. while still under pressure, cold-archives closed chats oldest first (`store/cold.rs`: one
//!    zstd file, rehydrated byte for byte on the next read), with the cold archive's own holds.
//!
//! Nothing is deleted: every chat still opens, lists and resumes. Open and idle chats are never
//! touched. It stops when the store is back under [`RELIEF`] of its cap and the disk has the
//! floor plus [`MARGIN_PERCENT`] free (no pass every check at the edge), or when no chat is left
//! to take. One log line per pass, with the bytes before and after.

use super::*;

/// How often the worker measures the store when nothing woke it.
pub(super) const CHECK_EVERY: std::time::Duration = std::time::Duration::from_secs(5 * 60);
/// A pass ends once the store is under this fraction of its cap (numerator over 10).
const RELIEF: u64 = 9;
/// A pass ends once the disk has this many percent more free than the floor.
const MARGIN_PERCENT: u64 = 5;
/// The cold archive pass measures the disk again after this many chats.
const MEASURE_EVERY_CHATS: u64 = 16;

/// The store's size and its disk's room, measured once.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) struct Pressure {
    pub free: u64,
    pub total: u64,
    /// The sessions folder's bytes; None when no cap is set (not walked).
    pub store_bytes: Option<u64>,
    pub cap: Option<u64>,
    pub floor_percent: Option<u8>,
}

impl Pressure {
    fn floor_bytes(&self, extra_percent: u64) -> Option<u64> {
        self.floor_percent.map(|p| self.total / 100 * (u64::from(p) + extra_percent))
    }

    /// Over the cap, or under the free floor.
    pub(super) fn over(&self) -> bool {
        let over_cap = matches!((self.store_bytes, self.cap), (Some(b), Some(c)) if b > c);
        let under_floor = self.floor_bytes(0).is_some_and(|floor| self.free < floor);
        over_cap || under_floor
    }

    /// Back with room to spare: a pass may stop.
    pub(super) fn relieved(&self) -> bool {
        let cap_ok = match (self.store_bytes, self.cap) {
            (Some(b), Some(c)) => b <= c / 10 * RELIEF,
            _ => true,
        };
        let floor_ok = self.floor_bytes(MARGIN_PERCENT).is_none_or(|floor| self.free >= floor);
        cap_ok && floor_ok
    }

    /// `freed` bytes later, without measuring again: the store shrank, and the disk gained them.
    fn after_freeing(mut self, freed: u64) -> Self {
        self.free = self.free.saturating_add(freed);
        self.store_bytes = self.store_bytes.map(|b| b.saturating_sub(freed));
        self
    }

    fn json(&self) -> Value {
        json!({"freeBytes": self.free, "totalBytes": self.total, "storeBytes": self.store_bytes,
               "capBytes": self.cap, "minFreePercent": self.floor_percent})
    }
}

/// Every regular file's size under `dir`, symlinks not followed. A folder that does not read is
/// left out (a chat being moved), never the reason for no answer.
fn dir_bytes(dir: &std::path::Path) -> u64 {
    let mut total = 0u64;
    let mut stack = vec![dir.to_path_buf()];
    while let Some(at) = stack.pop() {
        let Ok(entries) = std::fs::read_dir(&at) else { continue };
        for entry in entries.flatten() {
            let Ok(kind) = entry.file_type() else { continue };
            if kind.is_dir() {
                stack.push(entry.path());
            } else if kind.is_file()
                && let Ok(meta) = entry.metadata()
            {
                total = total.saturating_add(meta.len());
            }
        }
    }
    total
}

/// Tests: [`dir_bytes`].
#[cfg(test)]
pub(super) fn tests_dir_bytes(dir: &std::path::Path) -> u64 {
    dir_bytes(dir)
}

impl Hub {
    /// The store's sessions folder, when it has one on disk.
    fn store_root(&self) -> Option<PathBuf> {
        self.store.session_path("_").and_then(|p| p.parent().map(std::path::Path::to_path_buf))
    }

    /// Measures the store now (blocking: a `statvfs` and, with a cap, a walk). None for a store
    /// with no folder (memory) or a disk that does not answer.
    pub(super) fn store_pressure(&self, store: &crate::config::StoreConfig) -> Option<Pressure> {
        let root = self.store_root()?;
        let space = crate::recovery::space(&root)?;
        let cap = store.store_cap(space.total);
        Some(Pressure {
            free: space.free,
            total: space.total,
            store_bytes: cap.map(|_| dir_bytes(&root)),
            cap,
            floor_percent: store.free_floor_percent(),
        })
    }

    /// Measures the store and, under pressure, frees room in it (module docs). Blocking. The
    /// pass's report, or None when there was no pressure (or no store to measure).
    pub(super) fn relieve_store_pressure(
        self: &Arc<Self>,
        store: &crate::config::StoreConfig,
    ) -> Option<Value> {
        let before = self.store_pressure(store)?;
        if !before.over() {
            return None;
        }
        Some(self.store_pressure_pass(store, before))
    }

    fn store_pressure_pass(
        self: &Arc<Self>,
        store: &crate::config::StoreConfig,
        before: Pressure,
    ) -> Value {
        let started = std::time::Instant::now();
        // 1. Compact every closed chat, any age (one pass at a time with `_acpmux/retention`).
        let compacted = if self.retention_running.swap(true, Ordering::SeqCst) {
            json!({"skipped": "a log retention pass is already running"})
        } else {
            let _running = PressureRelease(self.retention_running.clone());
            match self.retain_logs_any_age() {
                Ok(report) => report,
                Err(e) => json!({"error": e.message}),
            }
        };
        // 2. Cold-archive closed chats, oldest first, while still under pressure.
        let mut now = self.store_pressure(store).unwrap_or(before);
        let mut archived = 0u64;
        let mut archived_freed = 0u64;
        if !now.relieved() {
            let hosted = Self::live_host_sessions();
            let mut sessions: Vec<_> = self
                .sessions()
                .into_iter()
                .filter(|s| s.meta().status == SessionStatus::Closed)
                .collect();
            sessions.sort_by_key(|s| s.meta().updated_at);
            let mut since_measure = 0u64;
            for session in sessions {
                if self.shutting_down() || now.relieved() {
                    break;
                }
                // `cold_archive_chat` takes Idle chats too: only closed ones go here.
                if session.meta().status != SessionStatus::Closed {
                    continue;
                }
                let Ok(preview) = self.cold_archive_chat(&session, None, &hosted) else {
                    continue;
                };
                let freed = preview.bytes_before.saturating_sub(preview.bytes_after);
                archived += 1;
                archived_freed += freed;
                now = now.after_freeing(freed);
                since_measure += 1;
                if since_measure >= MEASURE_EVERY_CHATS {
                    since_measure = 0;
                    if let Some(measured) = self.store_pressure(store) {
                        now = measured;
                    }
                }
            }
        }
        let after = self.store_pressure(store).unwrap_or(now);
        tracing::warn!(
            free_before = before.free,
            free_after = after.free,
            store_before = ?before.store_bytes,
            store_after = ?after.store_bytes,
            cap = ?before.cap,
            archived,
            "store pressure: compacted closed chats and cold-archived {archived} in {} ms{}",
            started.elapsed().as_millis(),
            if after.over() { "; still over: nothing more acpmux may take" } else { "" }
        );
        json!({
            "before": before.json(),
            "after": after.json(),
            "compacted": compacted,
            "coldArchived": archived,
            "coldArchivedFreedBytes": archived_freed,
            "stillOver": after.over(),
        })
    }
}

/// Ends the pass's hold on `Hub::retention_running` however it ends.
struct PressureRelease(Arc<AtomicBool>);

impl Drop for PressureRelease {
    fn drop(&mut self) {
        self.0.store(false, Ordering::SeqCst);
    }
}

#[cfg(test)]
#[path = "store_pressure_tests.rs"]
mod tests;
