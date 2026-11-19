//! What one cost-ledger line costs its caller: p50 and p95 of `Ledger::record` of a turn result
//! (which emits its line), with a small ledger (100 lines, 5 sessions) and a large one (200,000
//! lines, 500 sessions), each folded from its file on disk as the daemon opens it. The large
//! one's cost must not grow with the file, the sessions or the days it holds.
//! It uses `open_with`, `record` and `flush` only, which the ledger had before its lines were
//! written at the event: copy this file to such a build, with `#[cfg(test)] mod emit_bench;` in
//! `hub/ledger/mod.rs`, for the before numbers.
//! Manual: `cargo test -p acpmux --release --lib ledger_emit_cost -- --ignored --nocapture
//! --test-threads=1`. One `LEDGER-EMIT-COST` line per home (`n`: the timed calls).

use super::*;
use serde_json::json;
use std::path::Path;
use std::time::{Duration, Instant};

/// 2026-11-08T00:00:00Z, and the days the prebuilt lines spread over.
const D0: u64 = 20_765 * DAY_MS;
const DAYS: u64 = 30;
/// Timed turn results per home.
const CALLS: usize = 2_000;
/// The sessions the timed turns go to, in either home.
const HOT: usize = 5;

fn rec(dir: &str, kind: &str, at: u64, msg: Value) -> EventRecord {
    EventRecord { seq: 0, at, dir: dir.into(), kind: kind.into(), msg, host_seq: None }
}

/// Session `s` as its meta reads, the same fields its folded line has: a turn writes no
/// session line, only its spend.
fn ctx(s: usize) -> TurnContext {
    TurnContext {
        model: Some("claude-opus-5-5".into()),
        info: SessionInfo {
            title: Some(format!("chat {s}")),
            harness: "claude".into(),
            family: Some("claude".into()),
            created_at: D0,
            ..Default::default()
        },
    }
}

/// A ledger on `dir` whose file holds `lines` spend lines over `sessions` sessions and
/// [`DAYS`] days, written straight to it, opened as the daemon opens it, with its writer idle.
fn home(dir: &Path, lines: usize, sessions: usize) -> Ledger {
    let mut text = String::with_capacity(lines * 220 + sessions * 120);
    for s in 0..sessions {
        let line = json!({"t": "s", "sid": format!("s{s}"), "title": format!("chat {s}"),
            "harness": "claude", "family": "claude", "createdAt": D0});
        text.push_str(&line.to_string());
        text.push('\n');
    }
    for i in 0..lines {
        let at = D0 - (i as u64 % DAYS) * DAY_MS + i as u64;
        let line = json!({"t": "u", "sid": format!("s{}", i % sessions), "at": at,
            "model": "claude-opus-5-5", "pv": "2026-11-08", "costUsd": 0.01,
            "harnessCostUsd": 0.01, "inputTokens": 1000, "outputTokens": 200, "turns": 1});
        text.push_str(&line.to_string());
        text.push('\n');
    }
    std::fs::create_dir_all(dir).unwrap();
    std::fs::write(dir.join(store::FILE), text).unwrap();
    let l = Ledger::open_with(Some(dir.to_path_buf()), COMPACT_BYTES, "leo@test".into());
    // The large file is past `COMPACT_BYTES`: its compaction at the start ends before the timing.
    l.flush();
    l
}

/// The time of each timed turn result's `record`, its prompt untimed.
fn cost(l: &Ledger) -> Vec<Duration> {
    let result = json!({"model": "claude-opus-5-5", "costUsd": 0.01, "inputTokens": 1000});
    let mut took = Vec::with_capacity(CALLS);
    // One untimed turn per hot session first.
    for call in 0..CALLS + HOT {
        let s = call % HOT;
        let id = format!("s{s}");
        let at = D0 + 1_000 * call as u64;
        l.record(&id, &rec("out", "user_message", at, json!({"text": "go"})), || ctx(s));
        let record = rec("mux", "turn_result", at + 500, result.clone());
        let started = Instant::now();
        l.record(&id, &record, || ctx(s));
        let elapsed = started.elapsed();
        if call >= HOT {
            took.push(elapsed);
        }
    }
    took
}

fn percentile(sorted: &[Duration], p: usize) -> f64 {
    let at = (sorted.len() * p / 100).min(sorted.len().saturating_sub(1));
    sorted.get(at).map_or(0.0, |d| d.as_secs_f64() * 1e6)
}

#[test]
#[ignore = "manual per-line cost measurement"]
fn ledger_emit_cost() {
    let mut p95 = Vec::new();
    for (name, lines, sessions) in [("small", 100, 5), ("god", 200_000, 500)] {
        let dir = tempfile::tempdir().unwrap();
        let l = home(dir.path(), lines, sessions);
        let mut took = cost(&l);
        took.sort();
        let (p50_us, p95_us) = (percentile(&took, 50), percentile(&took, 95));
        println!(
            "LEDGER-EMIT-COST home={name} n={} p50_us={p50_us:.1} p95_us={p95_us:.1}",
            took.len()
        );
        p95.push(p95_us);
        l.flush();
    }
    // Constant cost: the large home's p95 within a fifth of the small one's, and 10 us of noise.
    assert!(p95[1] <= p95[0] * 1.2 + 10.0, "p95 small {:.1} us, god {:.1} us", p95[0], p95[1]);
}
