//! Replays the cloud-chat-replies-production probe's failed runs of the 168 h to 2026-11-27 09:50Z through the real
//! [`classify`] and [`recovery`] (Leo, goals/cloud-errors-self-recover: "Fix the cause"), so the table's reach is
//! a number from one harness, not a guess. `replay_fixture.jsonl` holds each failure's code and words only (from
//! the probe ledger, `results.jsonl` on `reconciler-state/probes-app-chat-production`; ids masked). That window
//! held 51 ok runs, 77 fails and 51 skips (all cancelled in the queue).
//!
//! Run: `cargo test -p cmux-cloud-start-core recover_replay -- --nocapture`.

use std::collections::BTreeMap;

use super::{classify, recovery};

const FIXTURE: &str = include_str!("replay_fixture.jsonl");
/// The window's ok runs (the ledger's `outcome: ok`).
const OK_RUNS: usize = 51;

/// Fails whose cause a merged change already removed at its source, so they age out of the window rather than
/// need a row: (words in the failure, the change). A row here is a projection, never a recovery the table runs.
const FIXED_AT_SOURCE: &[(&str, &str)] = &[
    // "Claude is not signed in here ... no model route": the start re-resolves the route (cmux#59819, 11-27 02:59Z).
    ("no model route", "cmux#59819"),
    // agent_session.harness_missing on a just-booted machine: acpmux finds the image's harness dir (cmux#59141).
    ("isn't installed on that machine", "cmux#59141"),
    // The start no longer asks the person to choose a login mode: the words are in no source file now.
    ("haven't chosen whether your Cloud machines get yours", "words no longer produced"),
];

/// The change that removed `message`'s cause, if [`FIXED_AT_SOURCE`] names one.
fn fixed_at_source(message: &str) -> Option<&'static str> {
    FIXED_AT_SOURCE.iter().find(|(words, _)| message.contains(words)).map(|(_, change)| *change)
}

#[derive(serde::Deserialize)]
struct Row {
    code: String,
    message: String,
}

#[test]
fn recover_replay() {
    let rows: Vec<Row> = FIXTURE
        .lines()
        .filter(|l| !l.trim().is_empty())
        .map(|l| serde_json::from_str(l).expect("fixture row"))
        .collect();
    let mut by: BTreeMap<String, (usize, Option<String>)> = BTreeMap::new();
    let mut recoverable = 0;
    let mut fixed: BTreeMap<&str, usize> = BTreeMap::new();
    for row in &rows {
        let class = classify(&row.code, &row.message, false);
        let action = class.and_then(recovery);
        if action.is_some() {
            recoverable += 1;
        } else if let Some(change) = fixed_at_source(&row.message) {
            *fixed.entry(change).or_default() += 1;
        }
        let key = match class {
            Some(c) => format!("{c:?}"),
            None => format!(
                "unclassified ({})",
                if row.code.is_empty() { "probe-side" } else { &row.code }
            ),
        };
        let e = by.entry(key).or_insert((0, action.map(|a| format!("{a:?}"))));
        e.0 += 1;
    }
    let fails = rows.len();
    let total = OK_RUNS + fails;
    println!("class\tcount\taction");
    let mut sorted: Vec<_> = by.iter().collect();
    sorted.sort_by(|a, b| b.1.0.cmp(&a.1.0));
    for (k, (n, a)) in sorted {
        println!("{k}\t{n}\t{}", a.as_deref().unwrap_or("none"));
    }
    println!(
        "before {OK_RUNS}/{total} = {:.0}%; after (upper bound, every recoverable run recovers) {}/{total} = {:.0}%",
        100.0 * OK_RUNS as f64 / total as f64,
        OK_RUNS + recoverable,
        100.0 * (OK_RUNS + recoverable) as f64 / total as f64
    );
    let fixed_n: usize = fixed.values().sum();
    for (change, n) in &fixed {
        println!("cause fixed at source by {change}: {n}");
    }
    println!(
        "projected (ages out: those fixed at source stop failing) {}/{total} = {:.0}%; open with no action {}",
        OK_RUNS + recoverable + fixed_n,
        100.0 * (OK_RUNS + recoverable + fixed_n) as f64 / total as f64,
        fails - recoverable - fixed_n
    );
    assert_eq!(fails, 77);
    // Every machine_stuck run in the window has an action: the table's FreshMachine row covers it.
    assert!(recoverable >= 12, "recoverable {recoverable}");
}
