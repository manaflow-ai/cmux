//! A write budget per record kind for an append-only log on disk: the registry journal and
//! acpmux's event logs. It warns when one kind writes more than its budget in an hour, or when
//! most of a kind's records repeat one of the two before it (a ping-pong between two states).
//!
//! The class it catches: a writer that persists state it already persisted, or liveness that
//! belongs in memory. On Leo's Mac (2026-11-08) one such kind, `personal.session.put`, was 96.6%
//! of a 59 GB registry, and Claude Code's whole `system/init`, re-logged each turn, was ~99 MB a
//! day of acpmux's. Each fix is the same: write only on a real change (compare the canonical
//! value), coalesce bursts, keep liveness (last used, task status, counters) in memory, and fix
//! two writers that undo each other at their source.
//!
//! It only warns, once per kind and hour, and only where [`WriteBudget::enabled`]: debug builds
//! and tests, or `CMUX_WRITE_BUDGET=1`. A release build never counts.

use std::collections::HashMap;
use std::hash::{DefaultHasher, Hash, Hasher};
use std::sync::{Mutex, OnceLock};

/// One hour, the budget's window.
const WINDOW_MS: u64 = 60 * 60 * 1000;

/// What a kind may write in an hour.
#[derive(Clone, Copy, Debug)]
pub struct WriteLimits {
    /// Bytes of its records.
    pub bytes: u64,
    /// Records.
    pub records: u64,
    /// The share (percent) of its records that repeat one of the two before it, counted once
    /// the kind wrote `repeat_floor` records in the window.
    pub repeat_percent: u64,
    pub repeat_floor: u64,
}

/// The counts of one kind in its current window.
#[derive(Default)]
struct Window {
    start_ms: u64,
    bytes: u64,
    records: u64,
    repeats: u64,
    last: [Option<u64>; 2],
    warned: bool,
}

/// A log's budget: its name in the warning, its limits, and each kind's window.
pub struct WriteBudget {
    log: &'static str,
    limits: WriteLimits,
    kinds: Mutex<HashMap<String, Window>>,
}

impl WriteBudget {
    pub fn new(log: &'static str, limits: WriteLimits) -> Self {
        Self { log, limits, kinds: Mutex::new(HashMap::new()) }
    }

    /// Whether budgets count here: debug builds and tests, or `CMUX_WRITE_BUDGET=1`.
    pub fn enabled() -> bool {
        static ENABLED: OnceLock<bool> = OnceLock::new();
        *ENABLED.get_or_init(|| {
            cfg!(debug_assertions)
                || std::env::var_os("CMUX_WRITE_BUDGET").is_some_and(|v| v == "1")
        })
    }

    /// Counts a record of `kind`, `bytes` long, whose content (without its sequence or time) is
    /// `payload`, written at `now_ms`. The warning to log when this record takes the kind over a
    /// limit for the first time in its window.
    pub fn note(&self, kind: &str, bytes: usize, payload: &[u8], now_ms: u64) -> Option<String> {
        let mut hasher = DefaultHasher::new();
        payload.hash(&mut hasher);
        let hash = hasher.finish();
        let mut kinds = self.kinds.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        let window = kinds.entry(kind.to_owned()).or_default();
        if now_ms.saturating_sub(window.start_ms) >= WINDOW_MS {
            *window = Window { start_ms: now_ms, last: window.last, ..Window::default() };
        }
        window.bytes = window.bytes.saturating_add(bytes as u64);
        window.records += 1;
        if window.last.contains(&Some(hash)) {
            window.repeats += 1;
        }
        window.last = [window.last[1], Some(hash)];
        if window.warned {
            return None;
        }
        let limits = self.limits;
        let over_bytes = window.bytes > limits.bytes;
        let over_records = window.records > limits.records;
        let repeating = window.records >= limits.repeat_floor
            && window.repeats * 100 >= window.records * limits.repeat_percent;
        if !(over_bytes || over_records || repeating) {
            return None;
        }
        window.warned = true;
        Some(format!(
            "[cmux write budget] {log}: kind {kind} wrote {bytes} bytes in {records} records within \
             an hour (budget {budget_bytes} bytes, {budget_records} records); {repeats} of them \
             repeated one of the two before. Write only on a real change, coalesce bursts, keep \
             liveness in memory (cmux-tui-platform write_budget.rs).",
            log = self.log,
            bytes = window.bytes,
            records = window.records,
            budget_bytes = limits.bytes,
            budget_records = limits.records,
            repeats = window.repeats,
        ))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const LIMITS: WriteLimits =
        WriteLimits { bytes: 1000, records: 50, repeat_percent: 50, repeat_floor: 10 };

    /// A kind over its bytes warns once in its window, and again in the next hour.
    #[test]
    fn a_kind_over_its_bytes_warns_once_an_hour() {
        let budget = WriteBudget::new("test log", LIMITS);
        let warnings = |start: u64| {
            (0..8u64)
                .filter_map(|i| budget.note("big", 200, &i.to_le_bytes(), start + i))
                .collect::<Vec<_>>()
        };
        let first = warnings(0);
        assert_eq!(first.len(), 1);
        assert!(first[0].contains("kind big wrote 1200 bytes in 6 records"), "{}", first[0]);
        assert_eq!(warnings(WINDOW_MS).len(), 1, "a new window warns again");
        assert!(budget.note("other", 10, b"x", WINDOW_MS + 9).is_none(), "kinds count apart");
    }

    /// Two states written in turn (ABAB) warn as repeats though no record equals the one before.
    #[test]
    fn a_ping_pong_warns_as_repeats() {
        let budget = WriteBudget::new("test log", LIMITS);
        let warned: Vec<String> = (0..12u64)
            .filter_map(|i| budget.note("flip", 10, if i % 2 == 0 { b"a" } else { b"b" }, i))
            .collect();
        assert_eq!(warned.len(), 1);
        assert!(warned[0].contains("in 10 records"), "{}", warned[0]);
        let distinct = WriteBudget::new("test log", LIMITS);
        assert!((0..40u64).all(|i| distinct.note("new", 10, &i.to_le_bytes(), i).is_none()));
    }

    /// Too many records warn even when each is small.
    #[test]
    fn too_many_records_warn() {
        let budget = WriteBudget::new("test log", LIMITS);
        let warned = (0..60u64).filter(|i| budget.note("tick", 1, &i.to_le_bytes(), *i).is_some());
        assert_eq!(warned.count(), 1);
    }
}
