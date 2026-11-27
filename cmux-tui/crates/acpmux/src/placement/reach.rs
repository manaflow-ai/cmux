//! Part of `placement.rs`: whether a candidate can be reached now, as an input to its fit.
//!
//! A pick is only as good as the transport to it. On 2026-11-25, `machine pick` chose a host
//! whose last health reading was still in the cache, but the copy a launcher sent to it got
//! "Connection closed" and the launch went elsewhere by hand. Two facts now pass such a host
//! over (`weigh` refuses it, not for load, so it never takes work as the overloaded fallback):
//!
//! - its reading is older than [`STALE_MS`], or its newest health read failed after the reading
//!   it has (`healthFailedAt`, kept by `hub/hub_health.rs`); and
//! - a transfer to it failed within [`COOLDOWN_MS`]: `acpmux machine unreachable HOST` records
//!   one (a launcher whose scp or ssh to its pick fails calls it), in [`FILE`] under acpmux's
//!   home, at most [`MAX_HOSTS`] hosts, read at each placement. The cooldown matches fleet-relay's
//!   dead-route memory: one failure keeps the host off for ten minutes, then it is tried again.

use anyhow::Context;
use serde_json::{Map, Value, json};
use std::path::{Path, PathBuf};

/// A reading older than this is not believed: a direct link asks every minute and the hub
/// refresh asks every minute while placing, so five missed asks mean the transport is gone.
pub const STALE_MS: u64 = 5 * 60_000;

/// How long one failed transfer keeps a host out of the pick.
pub const COOLDOWN_MS: u64 = 10 * 60_000;

/// The failure file's name in acpmux's home.
pub const FILE: &str = "unreachable-hosts.json";

/// The most hosts the file keeps; the oldest go first.
pub const MAX_HOSTS: usize = 256;

/// Why a peer row's own fields say it cannot be reached at `now`, or `None`.
pub fn row_unreachable(row: &Value, now: u64) -> Option<String> {
    let at = row.get("healthAt").and_then(Value::as_u64);
    let failed = row.get("healthFailedAt").and_then(Value::as_u64);
    if let Some(failed) = failed
        && at.is_none_or(|at| failed > at)
    {
        let ago = now.saturating_sub(failed) / 1000;
        return Some(format!(
            "unreachable: its last health read failed {ago}s ago (`acpmux machine pick` refreshes hub readings as they come due)"
        ));
    }
    let at = at?;
    let age = now.saturating_sub(at);
    (age > STALE_MS).then(|| {
        format!(
            "unreachable: its last health reading is {} min old, past the {} min a live link keeps (`acpmux machine pick` refreshes hub readings as they come due)",
            age / 60_000,
            STALE_MS / 60_000
        )
    })
}

/// The failed transfers this machine recorded, by host (canonical name).
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Failures(Map<String, Value>);

impl Failures {
    /// The file's path.
    pub fn path() -> PathBuf {
        crate::config::home().join(FILE)
    }

    /// The file as it is; missing or unreadable is none.
    pub fn load() -> Self {
        std::fs::read(Self::path()).ok().map(|b| Self::parse(&b)).unwrap_or_default()
    }

    pub fn parse(bytes: &[u8]) -> Self {
        match serde_json::from_slice(bytes) {
            Ok(Value::Object(m)) => Self(m),
            _ => Self::default(),
        }
    }

    /// Why `host` is passed over at `now`: a transfer to it failed within [`COOLDOWN_MS`].
    pub fn failure(&self, host: &str, now: u64) -> Option<String> {
        let e = self.0.get(&super::canonical(host))?;
        let at = e.get("at").and_then(Value::as_u64)?;
        let age = now.saturating_sub(at);
        if age >= COOLDOWN_MS {
            return None;
        }
        let why = e.get("why").and_then(Value::as_str).unwrap_or("a transfer failed");
        Some(format!(
            "unreachable: {why} {}s ago; tried again in {} min (`acpmux machine unreachable {host} --clear` now)",
            age / 1000,
            (COOLDOWN_MS - age).div_ceil(60_000)
        ))
    }

    /// `host` failed at `now` for `why`; entries past the cooldown and past [`MAX_HOSTS`] dropped.
    pub fn record(&mut self, host: &str, why: &str, now: u64) {
        self.prune(now);
        self.0.insert(super::canonical(host), json!({"at": now, "why": why}));
        while self.0.len() > MAX_HOSTS {
            let oldest = self
                .0
                .iter()
                .min_by_key(|(_, e)| e.get("at").and_then(Value::as_u64).unwrap_or(0))
                .map(|(k, _)| k.clone());
            match oldest {
                Some(k) => self.0.remove(&k),
                None => break,
            };
        }
    }

    /// `host` reached again: its failure is forgotten. Whether it had one.
    pub fn clear(&mut self, host: &str) -> bool {
        self.0.remove(&super::canonical(host)).is_some()
    }

    fn prune(&mut self, now: u64) {
        self.0.retain(|_, e| {
            e.get("at")
                .and_then(Value::as_u64)
                .is_some_and(|at| now.saturating_sub(at) < COOLDOWN_MS)
        });
    }

    pub fn to_bytes(&self) -> Vec<u8> {
        serde_json::to_vec_pretty(&Value::Object(self.0.clone())).unwrap_or_default()
    }

    /// Serialize launcher updates across processes. The lock stays on a separate file because
    /// the atomic write replaces the data file, and with it the inode a writer would lock.
    pub fn update<T>(dir: &Path, edit: impl FnOnce(&mut Self) -> T) -> anyhow::Result<T> {
        crate::config::private_state_dir(dir)?;
        let path = dir.join(FILE);
        let lock = crate::config::private_state_rw(&path.with_extension("lock"))?;
        let _held = cmux_file_lock::FileLock::take(lock, cmux_file_lock::Kind::Exclusive)
            .with_context(|| format!("lock {}", path.display()))?;
        let mut failures = match std::fs::read(&path) {
            Ok(bytes) => Self::parse(&bytes),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Self::default(),
            Err(e) => return Err(e).with_context(|| format!("read {}", path.display())),
        };
        let result = edit(&mut failures);
        crate::config::write_atomic(&path, &failures.to_bytes())?;
        Ok(result)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_stale_reading_or_a_failed_read_after_it_is_unreachable() {
        let now = 10 * STALE_MS;
        assert_eq!(row_unreachable(&json!({"healthAt": now - 60_000}), now), None);
        let stale = row_unreachable(&json!({"healthAt": now - STALE_MS - 1}), now).unwrap();
        assert!(stale.contains("5 min old"), "{stale}");
        let failed = row_unreachable(
            &json!({"healthAt": now - 90_000, "healthFailedAt": now - 30_000}),
            now,
        )
        .unwrap();
        assert!(failed.contains("failed 30s ago"), "{failed}");
        // A read that failed before the reading it has is old news.
        assert_eq!(
            row_unreachable(&json!({"healthAt": now - 1_000, "healthFailedAt": now - 30_000}), now),
            None
        );
        // No reading and no failure: unknown, not unreachable (`weigh` says so).
        assert_eq!(row_unreachable(&json!({}), now), None);
        assert!(row_unreachable(&json!({"healthFailedAt": now - 1_000}), now).is_some());
    }

    #[test]
    fn a_failed_transfer_keeps_a_host_off_for_the_cooldown() {
        let mut f = Failures::default();
        f.record("Lane-A", "scp: Connection closed", 1_000);
        let why = f.failure("lane-a", 31_000).unwrap();
        assert!(why.contains("scp: Connection closed 30s ago"), "{why}");
        assert!(why.contains("tried again in 10 min"), "{why}");
        assert_eq!(f.failure("lane-a", 1_000 + COOLDOWN_MS), None);
        assert_eq!(f.failure("lane-b", 2_000), None);
        // Round trip through the file's bytes.
        assert_eq!(Failures::parse(&f.to_bytes()), f);
        assert!(f.clear("lane-a"));
        assert_eq!(f.failure("lane-a", 2_000), None);
        assert_eq!(Failures::parse(b"not json"), Failures::default());
    }

    #[test]
    fn concurrent_launchers_keep_each_hosts_failure() {
        const HOSTS: usize = 16;
        let dir = tempfile::tempdir().unwrap();
        let dir = dir.path();
        let start = std::sync::Barrier::new(HOSTS);
        std::thread::scope(|threads| {
            for i in 0..HOSTS {
                let start = &start;
                threads.spawn(move || {
                    start.wait();
                    Failures::update(dir, |f| f.record(&format!("lane-{i}"), "copy failed", 1))
                        .unwrap();
                });
            }
        });
        let stored = Failures::parse(&std::fs::read(dir.join(FILE)).unwrap());
        for i in 0..HOSTS {
            assert!(stored.failure(&format!("lane-{i}"), 2).is_some());
        }
    }

    #[test]
    fn the_file_keeps_at_most_max_hosts_and_drops_expired_ones() {
        let mut f = Failures::default();
        for i in 0..(MAX_HOSTS as u64 + 5) {
            f.record(&format!("h{i}"), "x", 1_000 + i);
        }
        assert_eq!(f.0.len(), MAX_HOSTS);
        assert!(f.failure("h0", 2_000).is_none(), "the oldest went first");
        f.record("late", "x", 10 * COOLDOWN_MS);
        assert_eq!(f.0.len(), 1, "expired entries pruned");
    }
}
