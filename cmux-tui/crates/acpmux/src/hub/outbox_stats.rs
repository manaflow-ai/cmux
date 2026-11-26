//! Part of `Hub`; see `hub/outbox.rs`. The outbox's counters: what `/proc/net/snmp` is to a
//! kernel's sockets, for agent sends (RFD 0180, cmuxterm-hq; `design/acpmux-otp-rework.md` E3).
//!
//! Before these, a send's reliability was read only by grepping `daemon.log` and `outbox.json`
//! (69 deliveries in 42 h on one lane VM, p95 87 ms, the slowest 1,400 s). The counters are
//! cumulative since `sinceMs` and live in the outbox's book, so every change counts under the lock
//! it already takes: a new delivery (`queued`), its settling (`delivered`, `held`, `failed` by
//! class), each attempt past the first (`retries`), each mesh relay lease of an inbound message
//! (`relayLeases`, `relayReleases` for one leased again), and created-to-delivered latency in
//! log2 buckets of milliseconds. The gauges (queue depth, the oldest undelivered message's age)
//! come from the scan `unsettled` already makes, never a scan of their own.
//!
//! They are saved beside `outbox.json` as `outbox.stats.json`, one stable name written in place
//! (no temp names for fseventsd to remember), at most every [`SAVE_EVERY_MS`] and only with a save
//! the outbox already makes (group commit); a lost or torn file starts the counters again.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

use super::outbox::State;

/// How many latency buckets: bucket 0 is 0 ms, bucket `i` holds `[2^(i-1), 2^i)` ms; the last
/// holds everything from 2^30 ms (12 days) up.
pub(crate) const BUCKETS: usize = 32;

/// The counters are written with a save at most this often.
pub(crate) const SAVE_EVERY_MS: u64 = 10_000;

/// The failure classes a failed delivery is counted under: a bounded set, so the file and the
/// status stay small whatever the errors say.
pub(crate) const CLASSES: &[&str] = &[
    "unknown_recipient",
    "no_session",
    "hub_unavailable",
    "timeout",
    "open_lapsed",
    "folder_missing",
    "refused",
    "other",
];

/// The class of failure `error` reads as (one of [`CLASSES`]).
pub(crate) fn class(error: Option<&str>) -> &'static str {
    let Some(e) = error else { return "other" };
    if e.contains("unknown_recipient") {
        "unknown_recipient"
    } else if e.starts_with(super::no_session::NO_SESSION_PREFIX) {
        "no_session"
    } else if e.contains("mesh.unavailable") || e.contains(" 503") {
        "hub_unavailable"
    } else if e == super::outbox::OPEN_LAPSED {
        "open_lapsed"
    } else if e.starts_with(super::outbox::FOLDER_MISSING) {
        "folder_missing"
    } else if e.contains("timed out") || e.contains("no answer") || e.contains("nothing heard") {
        "timeout"
    } else if e.contains("refused") || e.contains("denied") {
        "refused"
    } else {
        "other"
    }
}

/// The bucket of a latency of `ms` milliseconds.
pub(crate) fn bucket(ms: u64) -> usize {
    if ms == 0 { 0 } else { ((64 - ms.leading_zeros()) as usize).min(BUCKETS - 1) }
}

/// The outbox's cumulative counters.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Counters {
    /// When counting started (the first daemon that kept this file).
    pub since_ms: u64,
    pub queued: u64,
    pub delivered: u64,
    pub held: u64,
    /// Failed deliveries by [`class`].
    pub failed: BTreeMap<String, u64>,
    /// Attempts past each delivery's first.
    pub retries: u64,
    /// Inbound messages the mesh hub leased to this daemon, and of those, ones leased again (a
    /// lease that ended unacked).
    pub relay_leases: u64,
    pub relay_releases: u64,
    /// Created-to-delivered latency, [`BUCKETS`] log2 buckets of milliseconds.
    pub latency_ms_log2: Vec<u64>,
}

impl Counters {
    pub fn starting(now: u64) -> Self {
        Self { since_ms: now, latency_ms_log2: vec![0; BUCKETS], ..Self::default() }
    }

    /// A new delivery was kept.
    pub fn note_queued(&mut self) {
        self.queued += 1;
    }

    /// A delivery changed from `before` (its state and attempts) to `after_state`,
    /// `after_attempts`, at `now`; `created_at` and `error` are the delivery's.
    pub fn note_change(
        &mut self,
        before: (State, u32),
        after_state: State,
        after_attempts: u32,
        created_at: u64,
        error: Option<&str>,
        now: u64,
    ) {
        // Every attempt numbered past 1 that this change started is a retry.
        let first_retry = before.1.max(1);
        self.retries += u64::from(after_attempts.saturating_sub(first_retry));
        if before.0 == after_state {
            return;
        }
        match after_state {
            State::Delivered => {
                self.delivered += 1;
                self.note_latency(now.saturating_sub(created_at));
            }
            State::Held => self.held += 1,
            State::Failed => *self.failed.entry(class(error).to_owned()).or_default() += 1,
            State::Queued | State::Delivering => {}
        }
    }

    fn note_latency(&mut self, ms: u64) {
        if self.latency_ms_log2.len() != BUCKETS {
            self.latency_ms_log2.resize(BUCKETS, 0);
        }
        self.latency_ms_log2[bucket(ms)] += 1;
    }

    /// The mesh relay leased an inbound message for its `attempt`th time (1 for the first).
    pub fn note_relay_lease(&mut self, attempt: u32) {
        self.relay_leases += 1;
        if attempt > 1 {
            self.relay_releases += 1;
        }
    }

    /// The upper bound in ms of the bucket that holds quantile `q` (0..=1) of the delivered
    /// latencies; None before any delivery.
    pub fn latency_quantile_ms(&self, q: f64) -> Option<u64> {
        let total: u64 = self.latency_ms_log2.iter().sum();
        if total == 0 {
            return None;
        }
        let rank = ((q.clamp(0.0, 1.0) * total as f64).ceil() as u64).max(1);
        let mut seen = 0;
        for (i, n) in self.latency_ms_log2.iter().enumerate() {
            seen += n;
            if seen >= rank {
                return Some(if i == 0 { 0 } else { 1u64 << i });
            }
        }
        None
    }

    pub fn failed_total(&self) -> u64 {
        self.failed.values().sum()
    }

    /// `send_status {stats: true}`'s answer, with the gauges `depth` (deliveries not settled)
    /// and `oldest_ms` (the oldest of those's age).
    pub fn status(&self, depth: usize, oldest_ms: Option<u64>) -> Value {
        json!({
            "sinceMs": self.since_ms,
            "queued": self.queued,
            "delivered": self.delivered,
            "held": self.held,
            "failed": self.failed,
            "failedTotal": self.failed_total(),
            "retries": self.retries,
            "relayLeases": self.relay_leases,
            "relayReleases": self.relay_releases,
            "latencyMsLog2": self.latency_ms_log2,
            "latencyP50Ms": self.latency_quantile_ms(0.5),
            "latencyP95Ms": self.latency_quantile_ms(0.95),
            "latencyP99Ms": self.latency_quantile_ms(0.99),
            "depth": depth,
            "oldestUndeliveredMs": oldest_ms,
        })
    }
}

/// `outbox.stats.json` beside `outbox.json` at `path`.
pub(crate) fn stats_path(path: &Path) -> PathBuf {
    path.with_extension("stats.json")
}

/// The counters saved beside the outbox at `path`; fresh ones from `now` when there are none or
/// they cannot be read.
pub(crate) fn read(path: &Path, now: u64) -> Counters {
    std::fs::read(stats_path(path))
        .ok()
        .and_then(|b| serde_json::from_slice::<Counters>(&b).ok())
        .filter(|c| c.since_ms > 0)
        .map(|mut c| {
            c.latency_ms_log2.resize(BUCKETS, 0);
            c
        })
        .unwrap_or_else(|| Counters::starting(now))
}

/// Writes `bytes` to the counters' file for the outbox at `path`, in place under its one name.
pub(crate) fn write(path: &Path, bytes: &[u8]) -> std::io::Result<()> {
    use std::io::Write;
    let mut f = crate::home_fs::OpenOptions::new()
        .write(true)
        .create(true)
        .truncate(true)
        .mode(0o600)
        .open(stats_path(path))?;
    f.write_all(bytes)
}

/// The compact line `acpmux ls` shows for `stats` (a `status` answer): None before any send.
pub fn ls_line(stats: &Value) -> Option<String> {
    let n = |k: &str| stats.get(k).and_then(Value::as_u64).unwrap_or(0);
    let queued = n("queued");
    if queued == 0 && n("relayLeases") == 0 {
        return None;
    }
    let mut line = format!(
        "sends: {queued} queued, {} delivered, {} failed, {} held, {} retries",
        n("delivered"),
        n("failedTotal"),
        n("held"),
        n("retries"),
    );
    if let (Some(p50), Some(p95)) = (
        stats.get("latencyP50Ms").and_then(Value::as_u64),
        stats.get("latencyP95Ms").and_then(Value::as_u64),
    ) {
        line.push_str(&format!(", p50 ≤{p50} ms, p95 ≤{p95} ms"));
    }
    if let Some(oldest) = stats.get("oldestUndeliveredMs").and_then(Value::as_u64) {
        line.push_str(&format!(", oldest waiting {} s", oldest / 1000));
    }
    if n("relayLeases") > 0 {
        line.push_str(&format!(
            "; relay {} leases, {} again",
            n("relayLeases"),
            n("relayReleases")
        ));
    }
    Some(line)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn buckets_are_log2_of_milliseconds() {
        assert_eq!(bucket(0), 0);
        assert_eq!(bucket(1), 1);
        assert_eq!(bucket(2), 2);
        assert_eq!(bucket(3), 2);
        assert_eq!(bucket(87), 7);
        assert_eq!(bucket(1_400_000), 21);
        assert_eq!(bucket(u64::MAX), BUCKETS - 1);
    }

    #[test]
    fn a_delivery_counts_once_with_its_latency_and_retries() {
        let mut c = Counters::starting(1);
        c.note_queued();
        // Attempt 1 starts: no retry.
        c.note_change((State::Queued, 0), State::Delivering, 1, 100, None, 110);
        // Attempts 2 and 3: two retries.
        c.note_change((State::Delivering, 1), State::Queued, 1, 100, None, 120);
        c.note_change((State::Queued, 1), State::Delivering, 3, 100, None, 130);
        c.note_change((State::Delivering, 3), State::Delivered, 3, 100, None, 187);
        // A later change that keeps it delivered does not count it again.
        c.note_change((State::Delivered, 3), State::Delivered, 3, 100, None, 200);
        assert_eq!((c.queued, c.delivered, c.retries), (1, 1, 2));
        assert_eq!(c.latency_ms_log2[bucket(87)], 1);
        assert_eq!(c.latency_quantile_ms(0.95), Some(128));
    }

    #[test]
    fn failures_count_by_a_bounded_class() {
        let mut c = Counters::starting(1);
        for e in [
            "the mesh hub refused it: the hub answered 404 mesh.unknown_recipient",
            "the hub answered 503 mesh.unavailable",
            super::super::outbox::OPEN_LAPSED,
            "something nobody expected",
        ] {
            c.note_change((State::Delivering, 1), State::Failed, 1, 0, Some(e), 5);
        }
        c.note_change((State::Delivering, 1), State::Held, 1, 0, None, 5);
        assert_eq!(c.failed_total(), 4);
        for k in c.failed.keys() {
            assert!(CLASSES.contains(&k.as_str()), "{k}");
        }
        assert_eq!(c.failed["unknown_recipient"], 1);
        assert_eq!(c.failed["hub_unavailable"], 1);
        assert_eq!(c.failed["open_lapsed"], 1);
        assert_eq!(c.failed["other"], 1);
        assert_eq!(c.held, 1);
    }

    #[test]
    fn relay_leases_count_the_ones_leased_again() {
        let mut c = Counters::starting(1);
        c.note_relay_lease(1);
        c.note_relay_lease(2);
        c.note_relay_lease(25);
        assert_eq!((c.relay_leases, c.relay_releases), (3, 2));
    }

    #[test]
    fn counters_survive_a_restart_and_a_torn_file_starts_again() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("outbox.json");
        assert_eq!(read(&path, 7), Counters::starting(7));
        let mut c = Counters::starting(3);
        c.note_queued();
        c.note_change((State::Delivering, 1), State::Delivered, 1, 0, None, 9);
        write(&path, &serde_json::to_vec(&c).unwrap()).unwrap();
        assert_eq!(read(&path, 99), c);
        write(&path, b"{\"sinceMs\": 3, \"queu").unwrap();
        assert_eq!(read(&path, 42), Counters::starting(42));
    }

    #[test]
    fn ls_shows_one_compact_line() {
        let mut c = Counters::starting(1);
        assert_eq!(ls_line(&c.status(0, None)), None);
        c.note_queued();
        c.note_queued();
        c.note_change((State::Delivering, 1), State::Delivered, 1, 0, None, 40);
        assert_eq!(
            ls_line(&c.status(1, Some(65_000))).as_deref(),
            Some(
                "sends: 2 queued, 1 delivered, 0 failed, 0 held, 0 retries, p50 ≤64 ms, \
                 p95 ≤64 ms, oldest waiting 65 s"
            )
        );
    }
}
