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
    for row in &rows {
        let class = classify(&row.code, &row.message, false);
        let action = class.and_then(recovery);
        if action.is_some() {
            recoverable += 1;
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
    assert_eq!(fails, 77);
    // Every machine_stuck run in the window has an action: the table's FreshMachine row covers it.
    assert!(recoverable >= 12, "recoverable {recoverable}");
}
