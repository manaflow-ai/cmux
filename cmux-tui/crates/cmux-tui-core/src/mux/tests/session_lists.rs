//! DAEMON LISTS STOP 800 (2026-11-10): at the person's session size (826 workspaces, 798
//! terminals) the CLI's `terminal list` took 223.8 ms and `pane list` 74.7 ms (13.1 ms and 11.7 ms
//! at 60 workspaces; SESSION 800, headless daemon). A list with no scope built the whole session
//! snapshot (each workspace, screen, pane, tab, terminal, browser, notification, agent and
//! projection, with each workspace, screen and tab decorated from SQLite) under the registry lock
//! and the state lock, and then kept one collection. `terminal.list` then asked, for each terminal,
//! a function that made three maps of the whole snapshot: its filter cost the square of the
//! session.
//!
//! A list with no scope builds its own collection only: the same values in the same order, with no
//! session snapshot. A pane or tab list takes the state lock no more often than a ping does.
//!
//! The checks: (1) counts with no clock: no session snapshot is built, the tables read, the state
//! locks taken; (2) a time ratio with the session size as the one argument (60 by default, 826 with
//! `--include-ignored`): the list against the session snapshot of the same session, the best of
//! seven runs of each in turn, so the load of the host is the same for the two.

use std::cell::Cell;
use std::hint::black_box;
use std::rc::Rc;
use std::time::Instant;

use serde_json::{Value, json};

use super::read_paths::{resource, touched};
use super::*;

mod tab_state_fields;

/// A session in the shape of the person's: each workspace has one screen with one pane and one
/// terminal; each eighth workspace has a second terminal tab. No terminal has a process.
fn session_of(workspaces: usize) -> Arc<Mux> {
    let mux = test_mux();
    fill(&mux, workspaces);
    mux
}

/// Add `workspaces` workspaces in the shape of [`session_of`] to `mux`.
fn fill(mux: &Arc<Mux>, workspaces: usize) {
    for index in 0..workspaces {
        let surface = mux.new_workspace(Some(format!("w{index}")), Some((80, 24))).unwrap();
        if index % 8 == 0 {
            let pane = mux.with_state(|state| state.pane_of(surface.id).unwrap());
            mux.new_tab(Some(pane), None, Some((80, 24))).unwrap();
        }
    }
}

/// `request`'s result, and whether a whole session snapshot was built for it.
fn with_snapshot_watch(request: impl FnOnce() -> Value) -> (Value, bool) {
    let built = Rc::new(Cell::new(false));
    let seen = built.clone();
    crate::resource_api::set_snapshot_before_projection_hook(move || seen.set(true));
    let value = request();
    let built = built.get();
    // A hook that did not run stays set: replace it, so a later snapshot of this thread runs nothing.
    crate::resource_api::set_snapshot_before_projection_hook(|| {});
    (value, built)
}

/// How many times `request` took the session's state lock on this thread.
fn state_locks_of(request: impl FnOnce()) -> u64 {
    let before = state_locks_taken_on_this_thread();
    request();
    state_locks_taken_on_this_thread() - before
}

/// Tables that no list of one collection has a use for.
const NOT_A_LIST_TABLE: &[&str] = &[
    "resource_agent_projections",
    "resource_effect_receipts",
    "frontend_projections",
    "session_journal",
];

/// The session-wide lists, each with its collection of the snapshot and the tables it has no use
/// for besides [`NOT_A_LIST_TABLE`].
const SESSION_LISTS: &[(&str, &str, &[&str])] = &[
    ("terminal.list", "terminals", &["resource_screens", "resource_panes"]),
    (
        "pane.list",
        "panes",
        &["resource_tabs", "resource_browsers", "resource_terminals", "terminal_hosts"],
    ),
    ("tab.list", "tabs", &["resource_screens", "terminal_hosts"]),
];

#[test]
fn a_session_wide_list_builds_its_collection_only() {
    let mux = session_of(3);
    let split = mux.new_workspace(Some("split".into()), Some((80, 24))).unwrap();
    let pane = mux.with_state(|state| state.pane_of(split.id).unwrap());
    mux.split(pane, SplitDir::Right, Some((80, 24))).unwrap();
    let snapshot = resource(&mux, "session.snapshot", json!({}));
    let ping_locks = state_locks_of(|| {
        resource(&mux, "session.ping", json!({}));
    });

    for (operation, collection, unused) in SESSION_LISTS {
        let expected = &snapshot[*collection];
        assert!(
            expected.as_array().is_some_and(|rows| rows.len() >= 4),
            "the session has {collection} to list: {snapshot}"
        );
        let mut listed = Value::Null;
        let mut built = false;
        let touched = touched(&mux, || {
            (listed, built) = with_snapshot_watch(|| resource(&mux, operation, json!({})));
        });
        assert_eq!(&listed, expected, "{operation} equals the snapshot's {collection}");
        assert!(!built, "{operation} with no scope built the whole session snapshot");
        let extra = NOT_A_LIST_TABLE
            .iter()
            .chain(unused.iter())
            .filter(|table| touched.read.contains(**table))
            .collect::<Vec<_>>();
        assert!(extra.is_empty(), "{operation} read {extra:?}");
        assert!(touched.written.is_empty(), "{operation} wrote {:?}", touched.written);

        let locks = state_locks_of(|| {
            resource(&mux, operation, json!({}));
        });
        // A terminal list reads each terminal's live surface: one more short hold.
        let allowed = if *collection == "terminals" { ping_locks + 1 } else { ping_locks };
        assert!(
            locks <= allowed,
            "{operation} took the state lock {locks} times; a ping takes it {ping_locks} times"
        );
    }
}

/// The best of `runs` runs of each request, in turn, in milliseconds.
fn best_ms<const N: usize>(runs: usize, mut requests: [&mut dyn FnMut(); N]) -> [f64; N] {
    let mut best = [f64::INFINITY; N];
    for _ in 0..runs {
        for (slot, request) in best.iter_mut().zip(requests.iter_mut()) {
            let start = Instant::now();
            request();
            *slot = slot.min(start.elapsed().as_secs_f64() * 1000.0);
        }
    }
    best
}

/// The lists of a session of `workspaces` workspaces against its whole snapshot.
fn check_list_cost(workspaces: usize) {
    let start = Instant::now();
    let mux = session_of(workspaces);
    let made_ms = start.elapsed().as_secs_f64() * 1000.0;
    let request = |operation: &'static str| {
        let mux = mux.clone();
        move || {
            black_box(resource(&mux, operation, json!({})));
        }
    };
    let (mut snapshot, mut terminals, mut panes, mut tabs) = (
        request("session.snapshot"),
        request("terminal.list"),
        request("pane.list"),
        request("tab.list"),
    );
    let [snapshot_ms, terminals_ms, panes_ms, tabs_ms] =
        best_ms(7, [&mut snapshot, &mut terminals, &mut panes, &mut tabs]);
    let rows =
        |operation: &str| resource(&mux, operation, json!({})).as_array().map_or(0, Vec::len);
    eprintln!(
        "session-lists workspaces={workspaces} terminals={} panes={} tabs={} made_ms={made_ms:.0} \
         best of 7, ms: session.snapshot={snapshot_ms:.2} terminal.list={terminals_ms:.2} \
         pane.list={panes_ms:.2} tab.list={tabs_ms:.2}",
        rows("terminal.list"),
        rows("pane.list"),
        rows("tab.list"),
    );
    for (operation, list_ms) in [("terminal.list", terminals_ms), ("pane.list", panes_ms)] {
        assert!(
            list_ms < snapshot_ms * 0.6,
            "{operation} with no scope took {list_ms:.2} ms at {workspaces} workspaces; the whole \
             session snapshot took {snapshot_ms:.2} ms: the list costs the session, not its reply"
        );
    }
}

#[test]
fn a_session_wide_list_costs_less_than_the_session_snapshot_at_60() {
    check_list_cost(60);
}

/// The person's session size. Run with `--include-ignored`: a unit test checks each create's
/// delta against the whole tree, so the session takes long to make.
#[test]
#[ignore = "826 workspaces: run with --include-ignored"]
fn a_session_wide_list_costs_less_than_the_session_snapshot_at_826() {
    check_list_cost(826);
}
