//! The harness of fuzz-catalog rows b (CLI and socket) and l (trust
//! boundaries): a seeded generator, an isolated headless daemon, a socket
//! connection with a deadline per call, and the oracle.
//!
//! The oracle: every request gets a typed answer (`ok: true`) or a typed
//! error (`ok: false` with a catalog error code) before its deadline; the
//! daemon never exits; and a refused mutation leaves the session's topology
//! as it was. A malformed request that the daemon accepts is a finding too.
//!
//! Reproduce one run with `CMUX_FUZZ_SEED=<seed>` (printed at the start of
//! every test) and widen it with `CMUX_FUZZ_CASES=<cases per operation>`.

#![allow(dead_code)]

pub mod catalog;
pub mod cli_cases;
pub mod daemon;
pub mod generate;
pub mod harness;
pub mod oracle;

use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

/// splitmix64: small, fast and the same on every host, so a seed replays.
#[derive(Clone)]
pub struct Rng(u64);

impl Rng {
    pub fn new(seed: u64) -> Self {
        Self(seed)
    }

    pub fn next_u64(&mut self) -> u64 {
        self.0 = self.0.wrapping_add(0x9E37_79B9_7F4A_7C15);
        let mut z = self.0;
        z = (z ^ (z >> 30)).wrapping_mul(0xBF58_476D_1CE4_E5B9);
        z = (z ^ (z >> 27)).wrapping_mul(0x94D0_49BB_1331_11EB);
        z ^ (z >> 31)
    }

    /// A value in `0..bound` (0 when `bound` is 0).
    pub fn below(&mut self, bound: usize) -> usize {
        if bound == 0 { 0 } else { (self.next_u64() % bound as u64) as usize }
    }

    pub fn chance(&mut self, percent: u64) -> bool {
        self.next_u64() % 100 < percent
    }

    pub fn pick<'a, T>(&mut self, items: &'a [T]) -> &'a T {
        &items[self.below(items.len())]
    }

    /// A child generator for one case, so a case replays from (seed, label).
    pub fn fork(&self, label: &str) -> Rng {
        let mut hash = self.0 ^ 0xCBF2_9CE4_8422_2325;
        for byte in label.bytes() {
            hash ^= u64::from(byte);
            hash = hash.wrapping_mul(0x0100_0000_01B3);
        }
        Rng(hash)
    }
}

/// The run's seed: `CMUX_FUZZ_SEED`, or the clock (printed, so it replays).
pub fn seed(test: &str) -> u64 {
    let seed = std::env::var("CMUX_FUZZ_SEED")
        .ok()
        .and_then(|value| value.parse().ok())
        .unwrap_or_else(|| {
            SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_nanos() as u64).unwrap_or(1)
        });
    eprintln!("fuzz-seed {test} {seed} (replay: CMUX_FUZZ_SEED={seed})");
    seed
}

/// Cases per operation and kind: `CMUX_FUZZ_CASES`, default `default`.
pub fn cases(default: usize) -> usize {
    std::env::var("CMUX_FUZZ_CASES")
        .ok()
        .and_then(|value| value.parse().ok())
        .filter(|cases| *cases > 0)
        .unwrap_or(default)
}

/// A wall-clock budget per test, under nextest's 120 s limit: a test that
/// runs out stops early and says so in its summary (`budget_stop`), so a slow
/// host gives a partial run, never a TIMEOUT with no report.
pub struct Budget {
    end: Instant,
}

impl Budget {
    pub fn start() -> Self {
        let secs =
            std::env::var("CMUX_FUZZ_BUDGET_SECS").ok().and_then(|v| v.parse().ok()).unwrap_or(90);
        Self { end: Instant::now() + Duration::from_secs(secs) }
    }

    pub fn spent(&self) -> bool {
        Instant::now() >= self.end
    }
}
