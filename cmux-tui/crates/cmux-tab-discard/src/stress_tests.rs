//! The discard and freeze plans as the hidden pages grow (Leo, 2026-11-17: "we should be stress
//! testing everything that isn't already stress tested"). A pass ranks every hidden page, so it is
//! O(pages log pages) by nature; this prints how long one pass takes at 1, 100, 1,000 and 10,000
//! pages with eight host exclusions, one `STRESS-TAB-DISCARD` JSON line per size and plan.
//!
//! Gated: `CMUX_STRESS=1`, or a plain `cargo test` filter naming `tab_discard_stress_bench`.
//!
//! ```text
//! env CMUX_STRESS=1 cargo test -p cmux-tab-discard --release tab_discard_stress_bench -- --nocapture
//! ```

use crate::plan::{Candidate, Pressure, freeze_plan, plan};
use crate::setting::Setting;
use serde_json::{Value, json};
use std::time::Instant;

fn bench_selected() -> bool {
    if std::env::var_os("CMUX_STRESS").is_some_and(|v| v == "1") {
        return true;
    }
    let args: Vec<String> = std::env::args().collect();
    args.iter().skip(1).any(|a| a.contains("tab_discard_stress_bench"))
        && !args.iter().any(|a| a == "--exact")
}

#[derive(Default)]
struct Samples(Vec<f64>);

impl Samples {
    fn push(&mut self, since: Instant) {
        self.0.push(since.elapsed().as_secs_f64() * 1000.0);
    }

    fn summary(&self) -> Value {
        let mut v = self.0.clone();
        v.sort_by(f64::total_cmp);
        let at = |q: f64| {
            if v.is_empty() {
                return 0.0;
            }
            let i = ((v.len() - 1) as f64 * q).round() as usize;
            (v[i] * 1000.0).round() / 1000.0
        };
        json!({ "n": v.len(), "p50": at(0.5), "p95": at(0.95), "max": at(1.0) })
    }
}

/// `count` hidden pages: varied hosts (some unicode, some duplicate keys' hosts), ages, focus
/// counts and memory, a few pinned or kept.
fn candidates(count: usize) -> Vec<Candidate> {
    (0..count)
        .map(|index| Candidate {
            key: format!("tab-{index}"),
            hidden_for: (index % 7_200) as f64,
            host: Some(match index % 5 {
                0 => format!("site{}.example.com", index % 50),
                1 => "bücher.example.de".to_owned(),
                2 => format!("Docs{}.Example.ORG", index % 13),
                3 => "localhost".to_owned(),
                _ => format!("{}.cdn.test", index % 97),
            }),
            is_pinned: index % 31 == 0,
            recent_focus_count: (index % 17) as i64,
            memory_bytes: Some(((index % 400) as u64) << 20),
            recently_kept: index % 23 == 0,
            ..Candidate::default()
        })
        .collect()
}

fn setting() -> Setting {
    Setting {
        exclusions: (0..8).map(|n| format!("*.excluded{n}.test")).collect(),
        ..Setting::default()
    }
}

#[test]
fn tab_discard_stress_bench() {
    if !bench_selected() {
        eprintln!("tab_discard_stress_bench skipped: set CMUX_STRESS=1");
        return;
    }
    let setting = setting();
    for size in [1_usize, 100, 1_000, 10_000] {
        let pages = candidates(size);
        let rounds = if size >= 10_000 { 20 } else { 50 };
        for pressure in [Pressure::Normal, Pressure::Critical] {
            let mut samples = Samples::default();
            let mut due = 0;
            for _ in 0..rounds {
                let started = Instant::now();
                due = plan(&setting, pressure, &pages).due.len();
                samples.push(started);
            }
            let line = json!({"size": size, "op": "plan", "pressure": format!("{pressure:?}"),
                              "ms": samples.summary(), "work": {"due": due}});
            println!("STRESS-TAB-DISCARD {line}");
        }
        let mut samples = Samples::default();
        let mut due = 0;
        for _ in 0..rounds {
            let started = Instant::now();
            due = freeze_plan(&setting, &pages).due.len();
            samples.push(started);
        }
        let line = json!({"size": size, "op": "freeze_plan", "ms": samples.summary(),
                          "work": {"due": due}});
        println!("STRESS-TAB-DISCARD {line}");
    }
}

/// Degenerate inputs: none, one, duplicate keys, and every page exempt.
#[test]
fn plans_hold_for_empty_one_duplicate_and_all_exempt_sets() {
    let setting = setting();
    assert!(plan(&setting, Pressure::Critical, &[]).due.is_empty());
    let one = candidates(1);
    assert!(plan(&setting, Pressure::Critical, &one).due.len() <= 1);
    let mut duplicates = candidates(4);
    for page in &mut duplicates {
        page.key = "same".into();
    }
    assert!(plan(&setting, Pressure::Critical, &duplicates).due.len() <= 3);
    let pinned = candidates(1_000)
        .into_iter()
        .map(|page| Candidate { is_pinned: true, ..page })
        .collect::<Vec<_>>();
    let result = plan(&setting, Pressure::Critical, &pinned);
    assert!(result.due.is_empty());
    assert_eq!(result.exemptions.len(), 1_000);
}
