#![cfg(unix)]
//! Deterministic simulation of the carrier's session layer: the real `RemoteDaemon` and
//! `ClientConnection` (Noise, the reliable session's sequence, ack and replay, heartbeat and
//! reconnect at the carrier dial's policy) over a simulated carrier with a seeded fault plan, on
//! a paused tokio clock. Each seed picks the prompts, each turn's length, two relays' latency
//! and up to three faults: a cut, a network drop (one way or both, 1 s to 150 s, past the 2 min
//! resume lease), a slow link, a swap to the other relay while the first one is silent, and a
//! daemon restart mid-turn. The app layer on top is acpmux's shape: a durable event log on the
//! machine, attach after the last event seen, a prompt resent by id until its turn starts. The
//! invariants (`carrier_sim/invariants.rs`): no event lost, none twice, in order, every prompt
//! once, a session ends only typed and only for a cause, every fault recovers within 30 s.
//!
//! Run (from `cmux-tui/`):
//!
//! ```text
//! cargo test -p cmux-remote --test carrier_sim                     # CARRIER_SIM_SEEDS (default 64)
//! CARRIER_SIM_SEEDS=5000 CARRIER_SIM_SEED_BASE=100000 cargo test -p cmux-remote --test carrier_sim
//! CARRIER_SIM_SEED=42 cargo test -p cmux-remote --test carrier_sim -- --nocapture   # one seed, traced
//! ```
//!
//! `CARRIER_SIM_REPORT=FILE` writes the run's numbers as JSON (seeds, failures, lost and
//! duplicated events, recovery p50/p95/max per fault kind). A failing seed prints the command
//! that replays it. Not modelled: `invariants::NOT_CHECKED`.

#[path = "carrier_sim/invariants.rs"]
mod invariants;
#[path = "carrier_sim/net.rs"]
mod net;
#[path = "carrier_sim/plan.rs"]
mod plan;
#[path = "carrier_sim/rng.rs"]
mod rng;
#[path = "carrier_sim/world.rs"]
mod world;

use std::collections::BTreeMap;
use std::time::Duration;

fn env_u64(name: &str) -> Option<u64> {
    std::env::var(name).ok().and_then(|v| v.trim().parse().ok())
}

fn replay_command(seed: u64) -> String {
    format!(
        "(cd cmux-tui && CARRIER_SIM_SEED={seed} cargo test -p cmux-remote --test carrier_sim \
         seeds_hold -- --nocapture)"
    )
}

fn percentile(sorted: &[Duration], p: f64) -> Duration {
    if sorted.is_empty() {
        return Duration::ZERO;
    }
    let at = ((sorted.len() as f64 - 1.0) * p).round() as usize;
    sorted[at.min(sorted.len() - 1)]
}

/// Every seed of the run, or the one CARRIER_SIM_SEED names, with its trace.
#[test]
fn seeds_hold() {
    if let Some(seed) = env_u64("CARRIER_SIM_SEED") {
        let o = world::run(seed, true);
        eprintln!("plan: {:#?}", o.plan);
        eprintln!("{}", o.trace.join("\n"));
        eprintln!("recoveries: {:#?}", o.recoveries);
        if let Err(failure) = invariants::check(&o) {
            panic!("seed {seed}: {failure}\nreplay: {}", replay_command(seed));
        }
        eprintln!(
            "seed {seed}: every invariant holds ({} simulated, {} events, {} sessions, {} \
             daemon restarts)",
            world::human(o.simulated),
            o.log.len(),
            o.sessions,
            o.restarts
        );
        return;
    }
    let seeds = env_u64("CARRIER_SIM_SEEDS").unwrap_or(64);
    let base = env_u64("CARRIER_SIM_SEED_BASE").unwrap_or(0);
    let threads = std::thread::available_parallelism().map_or(4, |n| n.get()).min(16) as u64;
    let started = std::time::Instant::now();
    // Each thread runs every `threads`th seed on its own runtimes.
    let results: Vec<(u64, world::Outcome)> = std::thread::scope(|scope| {
        let handles: Vec<_> = (0..threads)
            .map(|t| {
                scope.spawn(move || {
                    (base + t..base + seeds)
                        .step_by(threads as usize)
                        .map(|seed| (seed, world::run(seed, true)))
                        .collect::<Vec<_>>()
                })
            })
            .collect();
        // A worker that panicked fails the run with its own panic, never as a sweep short of seeds.
        handles
            .into_iter()
            .flat_map(|h| h.join().unwrap_or_else(|panic| std::panic::resume_unwind(panic)))
            .collect()
    });
    assert_eq!(results.len() as u64, seeds, "every requested seed ran");
    let wall = started.elapsed();
    let mut failures = Vec::new();
    let mut by_invariant: BTreeMap<String, u64> = BTreeMap::new();
    let mut recover: BTreeMap<String, Vec<Duration>> = BTreeMap::new();
    let (mut simulated, mut events, mut lost, mut twice) = (Duration::ZERO, 0_u64, 0_u64, 0_u64);
    for (seed, o) in &results {
        simulated += o.simulated;
        events += o.log.len() as u64;
        lost += (1..=o.log.len() as u64).filter(|s| !o.seqs.contains(s)).count() as u64;
        twice += o.seqs.len().saturating_sub({
            let mut u = o.seqs.clone();
            u.sort_unstable();
            u.dedup();
            u.len()
        }) as u64;
        for r in &o.recoveries {
            if let Some(took) = r.took {
                recover.entry(r.kind.clone()).or_default().push(took);
            }
        }
        if let Err(failure) = invariants::check(o) {
            let name = failure.split(':').next().unwrap_or("?").to_string();
            *by_invariant.entry(name).or_default() += 1;
            failures.push(format!("seed {seed}: {failure}\n  replay: {}", replay_command(*seed)));
        }
    }
    eprintln!(
        "sim: {seeds} seeds in {:.1} s on {threads} threads, {} simulated ({:.0}x real time), \
         {events} events, {lost} lost, {twice} duplicated, {} failing seeds",
        wall.as_secs_f64(),
        world::human(simulated),
        simulated.as_secs_f64() / wall.as_secs_f64().max(1e-9),
        failures.len()
    );
    let mut kinds = Vec::new();
    for (kind, took) in &mut recover {
        took.sort_unstable();
        let (p50, p95, max) = (
            percentile(took, 0.5),
            percentile(took, 0.95),
            took.last().copied().unwrap_or_default(),
        );
        eprintln!(
            "sim: recover after {kind}: p50 {} ms, p95 {} ms, max {} ms ({} faults)",
            p50.as_millis(),
            p95.as_millis(),
            max.as_millis(),
            took.len()
        );
        kinds.push(format!(
            "{{\"kind\":{kind:?},\"n\":{},\"p50_ms\":{},\"p95_ms\":{},\"max_ms\":{}}}",
            took.len(),
            p50.as_millis(),
            p95.as_millis(),
            max.as_millis()
        ));
    }
    for (name, n) in &by_invariant {
        eprintln!("sim: {n} seeds broke \"{name}\"");
    }
    eprintln!("sim: not checked yet: {}", invariants::NOT_CHECKED.join("; "));
    if let Ok(path) = std::env::var("CARRIER_SIM_REPORT") {
        let report = format!(
            "{{\"seeds\":{seeds},\"seed_base\":{base},\"failing_seeds\":{},\"events\":{events},\
             \"lost_events\":{lost},\"duplicated_events\":{twice},\"recover\":[{}]}}\n",
            failures.len(),
            kinds.join(",")
        );
        if let Err(e) = std::fs::write(&path, report) {
            eprintln!("sim: could not write {path}: {e}");
        }
    }
    for f in failures.iter().take(40) {
        eprintln!("{f}");
    }
    assert!(
        failures.is_empty(),
        "{} of {seeds} seeds failed (first: {})",
        failures.len(),
        failures[0]
    );
}

/// The seeds that found a bug, each kept so it stays found: 3 (the daemon's deadlines on another
/// clock than its timers: every link group past 30 s expired as it formed), 479 (a relay that goes
/// silent for 60 s: with a 5 s heartbeat and a 15 s answer window the link took 35 s to notice and
/// recover, past the 30 s bound; the 6 s silent-link death recovers it in under 8 s) and 658 (a
/// relay that stalls after the Noise handshake: the wait for link-ready had no deadline, and the
/// session it returned 60 s later was one the daemon had dropped).
#[test]
fn seeds_that_found_bugs_hold() {
    for seed in [3, 479, 658] {
        let o = world::run(seed, true);
        if let Err(failure) = invariants::check(&o) {
            panic!("seed {seed}: {failure}\nreplay: {}", replay_command(seed));
        }
    }
}

/// A seed is one run: the same seed twice gives the same events, sessions and recoveries.
#[test]
fn a_seed_replays_exactly() {
    for seed in [7, 1_234, 99_991] {
        let fingerprint = |o: &world::Outcome| {
            format!(
                "{:?} {:?} {} {:?} {:?}",
                o.log,
                o.seqs,
                o.sessions,
                o.ends,
                o.recoveries.iter().map(|r| (&r.kind, r.healed_at, r.took)).collect::<Vec<_>>()
            )
        };
        let a = fingerprint(&world::run(seed, true));
        let b = fingerprint(&world::run(seed, true));
        assert_eq!(a, b, "seed {seed} ran two ways");
    }
}
