//! Bench (`#[ignore]`): the two daemon reads the cmux NEXT app waits on at launch, in a session of
//! 5 and of 120 workspaces (one running terminal each, file-backed registry, the journal's public
//! fold seeded: `mux/tests/workspace_close_cost.rs` `session_in`).
//! - `list_workspaces`: the `list-workspaces` reply that `DaemonConnection.fetchSnapshot` asks for
//!   (no `known`, no `limit`), through `handle_command`, serialized to a JSON string.
//! - `session_snapshot`: `public_session_snapshot` plus `serde_json::to_string`, the first frame
//!   that `session.events` sends (`session_event_stream.rs`, `prepare_session_event_stream`).
//!
//! Prints one `TTI-BENCH <name> n=<iterations> median_ms=<ms>` line per read and size.
//!
//! cd cmux-tui && cargo test --release -p cmux-tui-core --lib launch_read_bench -- --ignored --nocapture

use super::tests::captured_writer;
use super::*;
use crate::mux::tests::workspace_close_cost::file_session_for_bench;

const ITERATIONS: usize = 20;
const SIZES: [usize; 2] = [5, 120];

fn median_ms(mut times: Vec<f64>) -> f64 {
    times.sort_by(f64::total_cmp);
    times[times.len() / 2]
}

fn time(mut body: impl FnMut() -> usize) -> (f64, usize) {
    // One warm-up read: the first read after the seed fills caches that a launch read finds warm
    // after the daemon's own start.
    let bytes = body();
    let times = (0..ITERATIONS)
        .map(|_| {
            let started = Instant::now();
            std::hint::black_box(body());
            started.elapsed().as_secs_f64() * 1000.0
        })
        .collect();
    (median_ms(times), bytes)
}

#[test]
#[ignore = "bench: run with --ignored --nocapture"]
fn launch_read_bench() {
    // Unit tests check each tree entity against the whole tree; the daemon never does.
    skip_tree_entity_check();
    let profile = if cfg!(debug_assertions) { "debug" } else { "release" };
    for workspaces in SIZES {
        let root = std::env::temp_dir().join(format!(
            "cmux-launch-read-bench-{workspaces}-{}",
            crate::workspace_registry::new_uuid_v4()
        ));
        let mux = file_session_for_bench(&root, workspaces);
        assert_eq!(mux.with_state(|state| state.workspaces.len()), workspaces);

        let (list_ms, list_bytes) = time(|| {
            let command: Command =
                serde_json::from_value(json!({"cmd": "list-workspaces"})).unwrap();
            let (writer, _) = captured_writer();
            let reply = handle_command(&mux, mux.local_test_client(0), command, &writer).unwrap();
            serde_json::to_string(&reply).unwrap().len()
        });
        println!(
            "TTI-BENCH list_workspaces ws={workspaces} n={ITERATIONS} median_ms={list_ms:.3} \
             bytes={list_bytes} profile={profile}"
        );

        let (snapshot_ms, snapshot_bytes) = time(|| {
            let snapshot = crate::resource_api::public_session_snapshot(&mux).unwrap();
            serde_json::to_string(&snapshot).unwrap().len()
        });
        println!(
            "TTI-BENCH session_snapshot ws={workspaces} n={ITERATIONS} median_ms={snapshot_ms:.3} \
             bytes={snapshot_bytes} profile={profile}"
        );

        drop(mux);
        let _ = std::fs::remove_dir_all(&root);
    }
}
