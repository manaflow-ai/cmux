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
#[cfg(test)]
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
#[path = "outbox_stats_tests.rs"]
mod tests;
