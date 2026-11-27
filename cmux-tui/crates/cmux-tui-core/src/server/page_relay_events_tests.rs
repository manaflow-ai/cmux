//! A page relay's event stream (`page-events-v1`) takes only its page's
//! events into its mailbox (audit 2026-11-18 §14, cmuxterm-hq
//! docs/investigations/2026-11-18-boneheaded-designs.md). Before, every relay
//! subscribed to the whole bus: the output of every terminal woke each
//! relay's thread, which rendered it to JSON and then dropped it for its
//! page's short list of names.
//!
//! The detector, `a_page_relay_mailbox_takes_only_its_page_events`, goes over
//! the real line loop: a relay whose thread is held for a moment while 5,000
//! unrelated events go by must neither overflow nor lose its page's event.
//! With the whole-bus mailbox it overflows (the page then resubscribes and
//! re-reads everything).

use std::time::{Duration, Instant};

use serde_json::{Value, json};

use super::tests::Client;
use crate::panic_free::RecoverPoison as _;
use crate::server::*;

fn mux(label: &str) -> Arc<Mux> {
    Mux::new_for_test(format!("page-relay-{label}"), crate::SurfaceOptions::default())
}

fn relay(mux: &Arc<Mux>, page: &str) -> Client {
    let mut client = Client::connect(mux, &format!("relay-{page}"));
    let hello = client.hello(json!({"role": "page_relay", "page": page}));
    assert_eq!(hello["ok"], true, "{hello}");
    assert_eq!(client.request(json!({"cmd": "subscribe"}))["ok"], true);
    client
}

fn named(value: &Value, name: &str) -> bool {
    value["event"] == name
}

#[test]
fn a_page_relay_mailbox_takes_only_its_page_events() {
    let mux = mux("detector");
    // The old registry path: a relay's thread reads the registry under its
    // lock once per event it renders (the incognito filter's remote check),
    // so the test can hold that thread while events go by.
    mux.control_clients.input_lane.set_for_test(false);
    let mut history = relay(&mux, "history");
    {
        let _held = mux.control_clients.state.lock().recover_poison();
        // More than a mailbox holds (event_bus.rs MAX_PENDING_EVENTS, 4,096),
        // none of them the History page's.
        for index in 0..5_000 {
            mux.emit(MuxEvent::Status(format!("busy terminal {index}")));
        }
    }
    mux.emit(MuxEvent::HistoryChanged { revision: 7, kinds: vec!["agent".into()] });
    let first = history.event_within(Duration::from_secs(10), |event| {
        named(event, "history-changed") || named(event, "overflow")
    });
    assert_eq!(
        first.as_ref().map(|event| event["event"].clone()),
        Some(json!("history-changed")),
        "the relay must take only its page's events: {first:?}",
    );
    assert_eq!(first.unwrap()["revision"], 7);
}

/// Leo's scale (audit "Scale used for cost"): about 1,600 tabs and six page
/// relays open. Each round every tab writes output once; then each relay
/// gets one event of its own page. Measures the relays' writer threads
/// (`mux-events-out`) from /proc: CPU time and wakes. The same harness runs
/// on base and on the fix (it uses only the line loop and `Mux::emit`).
///
/// `cmux-ci test -- cargo test -p cmux-tui-core --lib page_relay_fanout_bench -- --ignored --nocapture`
#[cfg(target_os = "linux")]
#[test]
#[ignore = "bench: run by hand"]
fn page_relay_fanout_bench() {
    const TABS: u64 = 1_600;
    const ROUNDS: u64 = 200;
    let mux = mux("bench");
    // Each page and the one event of its own the bench sends it last.
    let pages: [(&str, &str); 6] = [
        ("history", "history-changed"),
        ("stash", "stash-changed"),
        ("apps", "apps-changed"),
        ("bookmarks", "bookmarks-changed"),
        ("tasks", "tasks-changed"),
        ("feed", "feed-reports-changed"),
    ];
    let mut clients: Vec<(Client, &str)> =
        pages.iter().map(|(page, name)| (relay(&mux, page), *name)).collect();
    let before = relay_threads();
    let started = Instant::now();
    for _ in 0..ROUNDS {
        for tab in 0..TABS {
            mux.emit(MuxEvent::SurfaceOutput(tab));
        }
        // A bell per 16 tabs and a status line.
        for tab in (0..TABS).step_by(16) {
            mux.emit(MuxEvent::Bell(tab));
        }
        mux.emit(MuxEvent::Status("tick".into()));
    }
    let emit_ms = started.elapsed().as_secs_f64() * 1000.0;
    mux.emit(MuxEvent::HistoryChanged { revision: 1, kinds: vec!["agent".into()] });
    mux.emit(MuxEvent::StashChanged { revision: 1 });
    mux.emit(MuxEvent::AppsChanged(Arc::new(json!({"event": "apps-changed"}))));
    mux.emit_bookmarks_changed("default".into(), 1);
    mux.emit(MuxEvent::TasksChanged(Arc::new(json!({"event": "tasks-changed"}))));
    mux.emit(MuxEvent::FeedReportsChanged { revision: 1 });
    for (client, name) in &mut clients {
        let got = client.event_within(Duration::from_secs(60), |event| named(event, name));
        assert!(got.is_some(), "{name} never arrived");
    }
    let drained_ms = started.elapsed().as_secs_f64() * 1000.0;
    let after = relay_threads();
    let cpu_ms = (after.0 - before.0) as f64 / 1e6;
    let wakes = after.1 - before.1;
    let events = ROUNDS * (TABS + TABS.div_ceil(16) + 1);
    println!(
        "PAGE_RELAY_BENCH {}",
        json!({
            "relays": clients.len(),
            "tabs": TABS,
            "events_emitted": events,
            "relay_cpu_ms": (cpu_ms * 10.0).round() / 10.0,
            "relay_wakes": wakes,
            "emit_ms": (emit_ms * 10.0).round() / 10.0,
            "drained_ms": (drained_ms * 10.0).round() / 10.0,
            "relay_cpu_ns_per_event": ((after.0 - before.0) as f64 / events as f64).round(),
        })
    );
}

/// The summed CPU nanoseconds and voluntary context switches (wakes) of
/// this process's `mux-events-out` threads.
#[cfg(target_os = "linux")]
fn relay_threads() -> (u64, u64) {
    let mut cpu = 0;
    let mut wakes = 0;
    for task in std::fs::read_dir("/proc/self/task").unwrap().flatten() {
        let path = task.path();
        let comm = std::fs::read_to_string(path.join("comm")).unwrap_or_default();
        if comm.trim() != "mux-events-out" {
            continue;
        }
        let schedstat = std::fs::read_to_string(path.join("schedstat")).unwrap_or_default();
        cpu +=
            schedstat.split_whitespace().next().and_then(|ns| ns.parse::<u64>().ok()).unwrap_or(0);
        let status = std::fs::read_to_string(path.join("status")).unwrap_or_default();
        wakes += status
            .lines()
            .find_map(|line| line.strip_prefix("voluntary_ctxt_switches:"))
            .and_then(|count| count.trim().parse::<u64>().ok())
            .unwrap_or(0);
    }
    (cpu, wakes)
}
