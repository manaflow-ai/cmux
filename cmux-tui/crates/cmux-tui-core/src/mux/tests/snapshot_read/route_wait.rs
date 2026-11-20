//! A measure, not a guard: how long the snapshot reader that builds waits for the state lock beside real mutators
//! at 826 workspaces (`resource_api/committed_snapshot.rs` `routes_of_committed_rows_are_published`).
//!
//! The reader that builds the rows of a new commit tries the state lock once. When a thread holds it, the reader
//! waits for that hold, so the wait has the length of the state lock holds of the session. This test runs real
//! mutators (a workspace create with a terminal and a split through the request path, an empty workspace create)
//! beside a thread that reads the snapshot in a loop, and prints the number and the length of the waits and the
//! holds of the state lock by site.
//!
//! What it does not show: there is ONE mutator thread and the 826 workspaces are empty, so a hold can end inside
//! the reader's build and the try finds the lock free (a daemon in use has more and longer holders); most reads
//! of the loop are cache reads, which make no try; "reads after a new commit" counts loop turns that saw the
//! commit count move, not builds; the holds by site are from the start of the session, with the 826 setup
//! creates in them; a reader that waits behind the builder mutex is not counted. Run it alone:
//! `cargo test -p cmux-tui-core --lib -- snapshot_route_wait_at_826 --ignored --nocapture --test-threads 1`

use std::sync::atomic::AtomicBool;
use std::time::Instant;

use super::*;

/// (count, p50, p95, max) of `values`, in the unit of the values.
fn spread(mut values: Vec<u64>) -> (usize, u64, u64, u64) {
    values.sort_unstable();
    let Some(max) = values.last().copied() else {
        return (0, 0, 0, 0);
    };
    let at = |percent: usize| values[(values.len() * percent / 100).min(values.len() - 1)];
    (values.len(), at(50), at(95), max)
}

#[test]
#[ignore = "a measure: prints the waits of the snapshot builder beside real mutators at 826 workspaces"]
fn snapshot_route_wait_at_826_workspaces() {
    const WORKSPACES: usize = 826;
    const TERMINAL_ROUNDS: usize = 20;
    const EMPTY_CREATES_PER_ROUND: usize = 10;
    let root = temp_root("route-wait");
    let mux = session_at_rest("snapshot-route-wait", &root);
    grow_to(&mux, WORKSPACES);
    read_cut(&mux);

    let done = Arc::new(AtomicBool::new(false));
    let reader = {
        let (mux, done) = (mux.clone(), done.clone());
        std::thread::spawn(move || {
            let mut read_micros = Vec::new();
            let (mut reads_of_a_new_commit, mut failed_reads) = (0_u64, 0_u64);
            let mut commits_seen = mux.registry_connection.durability_counts().0;
            while !done.load(Ordering::Acquire) {
                let commits = mux.registry_connection.durability_counts().0;
                if commits != commits_seen {
                    commits_seen = commits;
                    reads_of_a_new_commit += 1;
                }
                let started = Instant::now();
                if let Err(error) = public_session_snapshot(&mux) {
                    failed_reads += 1;
                    eprintln!("snapshot-route-wait: a read failed: {error:?}");
                }
                read_micros.push(started.elapsed().as_micros() as u64);
            }
            let waits = crate::resource_api::route_wait_times_on_this_thread()
                .into_iter()
                .map(|wait| wait.as_micros() as u64)
                .collect::<Vec<_>>();
            (read_micros, (reads_of_a_new_commit, failed_reads), waits)
        })
    };

    let started = Instant::now();
    let mut mutations = 0_u64;
    for round in 0..TERMINAL_ROUNDS {
        let created = call(
            &mux,
            "workspace.create",
            json!({"initial_content":"terminal","name":format!("route-wait-{round}")}),
            Some(&format!("route-wait-create-{round}")),
        );
        let pane = created["value"]["pane_id"].as_str().unwrap().to_string();
        call(
            &mux,
            "pane.split",
            json!({"pane":pane,"direction":"right"}),
            Some(&format!("route-wait-split-{round}")),
        );
        for _ in 0..EMPTY_CREATES_PER_ROUND {
            mux.create_empty_workspace(None, None, None).unwrap();
        }
        mutations += 2 + EMPTY_CREATES_PER_ROUND as u64;
    }
    let mutator_millis = started.elapsed().as_millis();
    done.store(true, Ordering::Release);
    let (read_micros, (reads_of_a_new_commit, failed_reads), waits) = reader.join().unwrap();
    let state = mux.state.stats().detail();
    drop(mux);
    let _ = std::fs::remove_dir_all(&root);

    let (reads, read_p50, read_p95, read_max) = spread(read_micros);
    let (wait_count, wait_p50, wait_p95, wait_max) = spread(waits);
    eprintln!(
        "snapshot-route-wait: {WORKSPACES} workspaces at the start, {mutations} mutations ({TERMINAL_ROUNDS} workspace.create with a terminal, {TERMINAL_ROUNDS} pane.split, {} empty workspace creates) in {mutator_millis} ms",
        TERMINAL_ROUNDS * EMPTY_CREATES_PER_ROUND
    );
    eprintln!(
        "snapshot-route-wait: snapshot reads {reads} (after a new commit: {reads_of_a_new_commit}, failed: {failed_reads}), read us p50 {read_p50} p95 {read_p95} max {read_max}"
    );
    eprintln!(
        "snapshot-route-wait: builder waits for the state lock: count {wait_count}, us p50 {wait_p50} p95 {wait_p95} max {wait_max}"
    );
    eprintln!(
        "snapshot-route-wait: state lock holds us {:?}, waits us {:?}, contended {}",
        state.hold_us, state.wait_us, state.contended_acquisitions
    );
    for site in state.by_hold_p99.iter().take(8) {
        eprintln!(
            "snapshot-route-wait: state lock site {} acquisitions {} hold us max {} p99 {} total {}",
            site.site, site.acquisitions, site.hold_max_us, site.hold_p99_us, site.hold_total_us
        );
    }
    assert!(reads > 0, "setup: the reader read the snapshot beside the mutators");
}
