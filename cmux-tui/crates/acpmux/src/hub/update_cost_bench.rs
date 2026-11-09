//! What one small update costs as the sessions grow (Leo 2026-11-04: "never ... acceptable ...
//! linear time growth degradation"): the hub's per-event paths at 100, 1,000 and 3,000 sessions.
//! Manual: `cargo test -p acpmux --lib update_cost -- --ignored --nocapture --test-threads=1`.
//! Each line is `UPDATE-COST <path> n=<sessions> per_event_us=<mean>`, for the PR's table.

use super::*;
use std::time::Instant;

const SIZES: [usize; 3] = [100, 1_000, 3_000];
/// Live sessions among them: an agent and a turn each.
const LIVE: usize = 20;

fn hub_of(n: usize) -> (Arc<Hub>, Vec<Arc<Session>>) {
    let cfg: crate::config::Config =
        serde_json::from_value(json!({"store": {"mode": "memory"}})).unwrap();
    let store = crate::store::open(&cfg.store, std::path::Path::new("/nonexistent")).unwrap();
    let hub = Hub::new(cfg.clone(), store);
    let mut live = Vec::new();
    for i in 0..n {
        let status = if i < LIVE { "idle" } else { "closed" };
        let meta: crate::store::SessionMeta = serde_json::from_value(json!({
            "schema": crate::store::META_SCHEMA, "id": format!("s-{i:05}"),
            "name": format!("s-{i:05}"), "harness": "claude", "family": "claude", "cwd": "/w",
            "status": status, "createdAt": 1, "updatedAt": i + 1,
            "preview": "A short synthetic reply", "title": "A synthetic chat",
        }))
        .unwrap();
        let session = hub.insert_test_session(meta);
        if i < LIVE {
            live.push(session);
        }
    }
    (hub, live)
}

fn report(path: &str, n: usize, rounds: usize, took: std::time::Duration) {
    let per = took.as_secs_f64() * 1e6 / rounds as f64;
    eprintln!("UPDATE-COST {path} n={n} per_event_us={per:.1}");
}

/// Fix 2: one live chat's status record, then the next session list. Every closed row's cached
/// bytes went stale on it, so each list rebuilt every closed row.
#[test]
#[ignore = "manual per-event cost measurement"]
fn update_cost_closed_rows_after_one_chats_record() {
    let runtime = tokio::runtime::Builder::new_current_thread().enable_all().build().unwrap();
    let _enter = runtime.enter();
    for n in SIZES {
        let (hub, live) = hub_of(n);
        hub.visit_session_summaries(false, |_| {});
        let rounds = 20;
        let started = Instant::now();
        for round in 0..rounds {
            let status = if round % 2 == 0 { "running" } else { "idle" };
            hub.append(&live[0], "mux", "status", json!({"status": status}));
            hub.visit_session_summaries(false, |_| {});
        }
        report("closed_rows_list_after_one_record", n, rounds, started.elapsed());
    }
}

/// Fix 4: the idle reaper's and the stalled-turn timer's next deadline, taken on every wake.
#[test]
#[ignore = "manual per-event cost measurement"]
fn update_cost_idle_and_stalled_deadlines() {
    let runtime = tokio::runtime::Builder::new_current_thread().enable_all().build().unwrap();
    let _enter = runtime.enter();
    for n in SIZES {
        let (hub, _live) = hub_of(n);
        let rounds = 200;
        let started = Instant::now();
        for _ in 0..rounds {
            std::hint::black_box(hub.next_idle_deadline());
            std::hint::black_box(hub.next_stalled_deadline(std::time::Duration::from_secs(600)));
        }
        report("idle_and_stalled_deadline", n, rounds, started.elapsed());
    }
}

/// Fix 5: a whole usage pass drops the chats no longer listed.
#[test]
#[ignore = "manual per-event cost measurement"]
fn update_cost_usage_pass_prune() {
    for n in SIZES {
        let sources: Vec<(String, crate::usage_stats::Source)> =
            (0..n).map(|i| (format!("s-{i:05}"), Default::default())).collect();
        let rounds = 20;
        let mut took = std::time::Duration::ZERO;
        for _ in 0..rounds {
            // One more tracked chat than listed: it goes.
            let mut trackers: HashMap<String, u64> =
                (0..=n).map(|i| (format!("s-{i:05}"), 0)).collect();
            let mut stats = trackers.clone();
            let started = Instant::now();
            let gone = super::usage_view::prune_unlisted(&mut trackers, &mut stats, &sources);
            took += started.elapsed();
            assert_eq!(gone.len(), 1);
            assert_eq!(stats.len(), n);
        }
        report("usage_pass_prune", n, rounds, took);
    }
}
