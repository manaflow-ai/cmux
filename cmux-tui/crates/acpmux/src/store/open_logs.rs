//! How many chat logs the store holds open (`LocalStore::append_line`). Past that many, each
//! append to a chat whose log is closed first closes the least recently written log, and that
//! close syncs the log under the store-wide writers' lock (and, in the journal store, its order
//! lock), so every chat's appends wait on the disk meanwhile. With more chats streaming than logs
//! open, almost every streamed record evicted one: on a fleet Mac a sync takes 5-10 ms (p50), so
//! the whole daemon wrote one record per sync.
//!
//! The bound exists for the open-file limit (cmux16, 2026-10-22: a daemon held one descriptor per
//! chat it had written, 193 of its 256, and every agent start failed with "Too many open files").
//! So it follows that limit: a sixteenth of the soft limit this process runs under, never fewer
//! than [`MIN`] (at launchd's 256 that keeps 192 descriptors for everything else, as before) and
//! never more than [`MAX`]. The daemon raises its soft limit before it opens the store
//! (`daemon/open_file_limit.rs`), usually to 10,240 or more on macOS: then [`MAX`] chats stream
//! with no eviction.

/// The fewest logs held open, whatever the limit: the bound before it followed the limit.
const MIN: usize = 64;
/// The most logs held open, whatever the limit.
const MAX: usize = 512;

/// The logs held open under a soft open-file limit of `soft` (None: unknown).
pub(super) fn for_limit(soft: Option<u64>) -> usize {
    soft.map_or(MIN, |soft| usize::try_from(soft / 16).unwrap_or(MAX).clamp(MIN, MAX))
}

/// The logs a store opened now holds open: [`for_limit`] of this process's soft open-file limit.
pub fn now() -> usize {
    for_limit(soft_limit())
}

#[cfg(unix)]
fn soft_limit() -> Option<u64> {
    let mut lim = libc::rlimit { rlim_cur: 0, rlim_max: 0 };
    // SAFETY: getrlimit writes only into the local struct it is given.
    if unsafe { libc::getrlimit(libc::RLIMIT_NOFILE, &mut lim) } != 0 {
        return None;
    }
    #[allow(clippy::useless_conversion)]
    Some(u64::from(lim.rlim_cur))
}

#[cfg(not(unix))]
fn soft_limit() -> Option<u64> {
    None
}

#[cfg(test)]
impl super::LocalStore {
    /// This store holding at most `logs` logs open, whatever the open-file limit.
    pub(super) fn with_open_logs(mut self, logs: usize) -> Self {
        self.open_logs = logs;
        self
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::store::{EventRecord, LocalStore, Store as _};

    #[test]
    fn the_bound_follows_the_open_file_limit() {
        // Unknown, or launchd's default for a user agent: the bound before it followed the limit.
        assert_eq!(for_limit(None), 64);
        assert_eq!(for_limit(Some(256)), 64);
        assert_eq!(for_limit(Some(1024)), 64);
        assert_eq!(for_limit(Some(4096)), 256);
        // What the daemon raises itself to on macOS, and the Linux default it raises to.
        assert_eq!(for_limit(Some(10_240)), 512);
        assert_eq!(for_limit(Some(65_536)), 512);
        assert_eq!(for_limit(Some(u64::MAX)), 512);
    }

    /// Writes three records to each of 100 chats in turn, the way 100 streaming chats write, and
    /// returns how many log syncs the second and third rounds made (the first opens every log).
    fn syncs_while_100_chats_stream(logs: usize) -> u64 {
        let dir = std::env::temp_dir().join(format!("acpmux-open-logs-{}", uuid::Uuid::now_v7()));
        let store = LocalStore::new(dir.clone(), 1 << 20).unwrap().with_open_logs(logs);
        let record = |seq| EventRecord {
            seq,
            at: seq,
            dir: "in".into(),
            kind: "agent_message_chunk".into(),
            msg: serde_json::json!({"text": "a streamed chunk"}),
            host_seq: None,
        };
        let syncs = || super::super::log_sync::ALL_SYNCS.with(std::cell::Cell::get);
        let chats: Vec<String> = (0..100).map(|n| format!("chat-{n:03}")).collect();
        for chat in &chats {
            store.append(chat, &record(1)).unwrap();
        }
        let before = syncs();
        for seq in 2..=3 {
            for chat in &chats {
                store.append(chat, &record(seq)).unwrap();
            }
        }
        let made = syncs() - before;
        for chat in &chats {
            let seqs: Vec<u64> =
                store.events(chat, 0, usize::MAX).unwrap().iter().map(|e| e.seq).collect();
            assert_eq!(seqs, [1, 2, 3], "{chat}");
        }
        let _ = std::fs::remove_dir_all(&dir);
        made
    }

    #[test]
    fn more_chats_than_the_old_bound_stream_with_no_sync_under_the_raised_limit() {
        // Under the limit the daemon raises itself to, 100 chats keep their logs open.
        assert_eq!(syncs_while_100_chats_stream(for_limit(Some(10_240))), 0);
        // At the old bound each of those 200 appends closed, and synced, another chat's log.
        assert_eq!(syncs_while_100_chats_stream(for_limit(None)), 200);
    }
}
