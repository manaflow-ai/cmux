//! The wall time of one `close-workspace` call with `end_terminals`, printed and NOT asserted.
//!
//! `workspace_close_cost` counts what a close does; this says how long the call takes, for a
//! close of the LAST workspace (no workspace after it), a MIDDLE one and the FIRST one, at 60 and
//! at 826 workspaces (one terminal each). A time is not a test result (a loaded host changes it),
//! so nothing here can fail on it and the test is ignored by default. Run it on the fleet:
//!
//! ```text
//! cargo test -p cmux-tui-core --lib workspace_close_time -- --ignored --nocapture
//! cargo test --release -p cmux-tui-core --lib workspace_close_time -- --ignored --nocapture
//! ```
//!
//! What it measures: the in-process call (`Mux::close_workspace_ending_terminals`) in a test
//! build, with the debug cross-check off as a release daemon runs. It is not the socket reply time
//! of a release daemon:
//! - no request parse, no reply write, no other client;
//! - the registry is SQLite in memory (`Mux::new_with_test_surface_runtime`,
//!   `WorkspaceRegistry::in_memory`): no file, no WAL, no disk write;
//! - each terminal is a placeholder (`Surface::exited_terminal_placeholder`): the close asks no
//!   terminal host to stop and stores no archive of a screen;
//! - the order of the arms is fixed (last, middle, first, in each new session), so "last" also
//!   pays what a new registry pays on its first close.
//!
//! The test-only check of each tree entity against the whole tree's JSON
//! (`server::tree_entity_json`) is off on this test's thread, with the switch that #40700 added
//! for its bench: it costs about 14 ms of each close at 826 workspaces (1 ms at 60) in a test
//! build and is not in a daemon.

use std::time::{Duration, Instant};

use super::workspace_close_cost::session;
use super::*;
use crate::mux::resource_content::without_crosscheck;

/// Sessions made for each size; each one gives one time for each of the three closes.
const SAMPLES: usize = 5;

/// Close the workspace at `index`, ending its terminal, and return the time of the call.
fn timed_close(mux: &Arc<Mux>, index: usize) -> Duration {
    let key = mux.with_state(|state| state.workspaces[index].key.clone());
    let mutation =
        WorkspaceMutation::daemon(format!("close-time-{key}"), "close-time-test").unwrap();
    let started = Instant::now();
    without_crosscheck(|| {
        mux.close_workspace_ending_terminals(None, Some(&key), None, None, &mutation).unwrap();
    });
    started.elapsed()
}

fn milliseconds(time: Duration) -> f64 {
    time.as_secs_f64() * 1000.0
}

/// Median, min and max of `times`, and each one in the order it was measured.
fn summary(times: &[Duration]) -> String {
    let mut sorted = times.to_vec();
    sorted.sort();
    let each = times.iter().map(|time| format!("{:.3}", milliseconds(*time))).collect::<Vec<_>>();
    format!(
        "median {:.3} ms, min {:.3} ms, max {:.3} ms (each, in order: {})",
        milliseconds(sorted[sorted.len() / 2]),
        milliseconds(sorted[0]),
        milliseconds(sorted[sorted.len() - 1]),
        each.join(" ")
    )
}

#[test]
#[ignore = "a measurement that asserts nothing: run it with `-- --ignored --nocapture`"]
fn the_time_of_one_workspace_close_is_printed() {
    // The switch has no reset: it is set on a thread that ends with the measurement, so no other
    // test body can run with the check off, whatever thread the test harness gives this one.
    let measured = std::thread::spawn(print_the_close_times).join();
    assert!(measured.is_ok(), "the measuring thread panicked");
}

fn print_the_close_times() {
    // `server` gives the switch of `tree_json` under a second name: under its own name the call
    // `tree_json::skip_entity_check_on_this_thread_for_bench()` in the open bench of `server`
    // would be an unnecessary qualification for clippy.
    crate::server::skip_tree_entity_check();
    let build = if cfg!(debug_assertions) {
        "debug assertions on (the dev profile)"
    } else {
        "debug assertions off (--release)"
    };
    eprintln!(
        "close time: the in-process call in a test build, {build}, with the test-only check of \
         the tree entity against the whole tree off; not the socket reply time of a release \
         daemon. {SAMPLES} new sessions for each size; in each one a close of the last \
         workspace, then of a middle one, then of the first one."
    );
    for workspaces in [60, 826] {
        let (mut last, mut middle, mut first) = (Vec::new(), Vec::new(), Vec::new());
        for _ in 0..SAMPLES {
            // Made with the debug cross-check off: with it, each create also runs a full
            // projection, and making 826 workspaces takes minutes.
            let mux = without_crosscheck(|| session(workspaces));
            let live = mux.with_state(|state| state.workspaces.len());
            last.push(timed_close(&mux, live - 1));
            middle.push(timed_close(&mux, (live - 1) / 2));
            first.push(timed_close(&mux, 0));
        }
        for (name, times) in [("last", &last), ("middle", &middle), ("first", &first)] {
            eprintln!("close time at {workspaces} workspaces, {name}: {}", summary(times));
        }
    }
}
