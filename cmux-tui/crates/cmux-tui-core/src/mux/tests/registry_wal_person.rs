//! What a person's request pays for the registry WAL's restart rule while
//! another thread commits with no pause (REGISTRY SHRINK: the log restart
//! rule). A measure: it prints a table and asserts only that it measured.
//!
//! The restart rule needs a moment with no commit: the last part of the
//! checkpoint that lets the WAL restart runs while the database's writer
//! lock (the registry connection lock) is kept from every other thread. A
//! person's split, new tab or rename that comes in that span waits for it.
//! This test says how often and how long.
//!
//! One storm thread renames a workspace with no pause, as a session build,
//! a restore or an agent burst commits. The test's own thread is the
//! person: split, close the new pane, new tab, close it, rename, one
//! request each [`PERSON_PAUSE`], each followed by the flush request of the
//! server's reply funnel. It runs until the rule held the lock
//! [`RESTARTS`] times (or [`ARM_LIMIT`] passed), then compares the person's
//! requests that met a hold with those that met none. Arms: 1, 60 and 826
//! workspaces (the session size rule).
//!
//! Run: `cargo test -p cmux-tui-core --lib -- registry_wal_person
//! --ignored --nocapture --test-threads 1`.

use super::*;
use crate::workspace_registry::wal_durability::WAL_SIZE_LIMIT_BYTES;

/// Holds of the restart rule one arm waits for.
const RESTARTS: usize = 30;
/// The longest one arm runs.
const ARM_LIMIT: Duration = Duration::from_secs(420);
/// The pause between two requests of the person.
const PERSON_PAUSE: Duration = Duration::from_millis(10);

const KINDS: [&str; 5] = ["split", "close-pane", "new-tab", "close-tab", "rename"];

/// (count, p50, p95, max) of `times` in milliseconds.
fn spread(times: &mut [Duration]) -> (usize, f64, f64, f64) {
    times.sort_unstable();
    let at = |part: f64| {
        let last = times.len().saturating_sub(1);
        // A rank in a list of a few thousand entries.
        let index = ((last as f64) * part).round() as usize;
        times.get(index.min(last)).map_or(0.0, |time| time.as_secs_f64() * 1000.0)
    };
    (times.len(), at(0.5), at(0.95), at(1.0))
}

fn row(times: &mut [Duration]) -> String {
    let (count, p50, p95, max) = spread(times);
    format!("n={count} p50_ms={p50:.2} p95_ms={p95:.2} max_ms={max:.2}")
}

fn person_requests_beside_a_change_storm(workspaces: usize) {
    let root = std::env::temp_dir()
        .join(format!("cmux-wal-person-{}", crate::workspace_registry::new_uuid_v4()));
    let mux = open_persistent_test_mux("wal-person", &root);
    // The worker would checkpoint and seal on its own ticks, which commit.
    mux.stop_journal_maintenance();
    let surface = mux.new_workspace(None, Some((80, 24))).unwrap();
    mux.request_registry_flush();
    for index in 1..workspaces {
        mux.create_empty_workspace(Some(format!("idle {index}")), None, None).unwrap();
        mux.request_registry_flush();
    }
    // The person works in the first workspace (the one with a terminal);
    // the storm renames the last one (the same one in the arm of 1).
    let (person_workspace, storm_workspace, pane) = mux.with_state(|state| {
        let first = state.workspaces[0].id;
        let last = state.workspaces[state.workspaces.len() - 1].id;
        (first, last, state.pane_of(surface.id).unwrap())
    });
    let built = mux.write_path_stats();
    let holds_before = mux.registry_connection.wal_restart_holds_for_test().len();

    let stop = Arc::new(AtomicBool::new(false));
    let storm = {
        let (mux, stop) = (mux.clone(), stop.clone());
        std::thread::spawn(move || {
            let mut changes = 0u64;
            while !stop.load(Ordering::Acquire) {
                assert!(mux.rename_workspace(storm_workspace, format!("storm {changes}")));
                // Each answered request asks for a flush (`server/connection_frame.rs`).
                mux.request_registry_flush();
                changes += 1;
            }
            changes
        })
    };

    let started = Instant::now();
    let mut requests: Vec<(usize, Instant, Instant)> = Vec::new();
    let mut timed = |kind: usize, request: &mut dyn FnMut()| {
        let from = Instant::now();
        request();
        requests.push((kind, from, Instant::now()));
        mux.request_registry_flush();
        std::thread::sleep(PERSON_PAUSE);
    };
    let mut round = 0u64;
    let holds = loop {
        let mut split = None;
        timed(0, &mut || split = Some(mux.split(pane, SplitDir::Right, Some((80, 24))).unwrap()));
        let split_pane = mux.with_state(|state| state.pane_of(split.as_ref().unwrap().id).unwrap());
        timed(1, &mut || assert!(mux.close_pane(split_pane).unwrap()));
        let mut tab = None;
        timed(2, &mut || tab = Some(mux.new_tab(Some(pane), None, Some((80, 24))).unwrap()));
        let tab_id = tab.as_ref().unwrap().id;
        timed(3, &mut || assert!(mux.close_surface(tab_id).unwrap()));
        timed(4, &mut || {
            assert!(mux.rename_workspace(person_workspace, format!("person {round}")))
        });
        round += 1;
        let holds = mux.registry_connection.wal_restart_holds_for_test();
        if holds.len() - holds_before >= RESTARTS || started.elapsed() > ARM_LIMIT {
            break holds[holds_before..].to_vec();
        }
    };
    let seconds = started.elapsed().as_secs_f64();
    stop.store(true, Ordering::Release);
    let changes = storm.join().unwrap();
    let after = mux.write_path_stats();
    mux.shutdown();
    let _ = std::fs::remove_dir_all(&root);

    let mut hold_times = holds.iter().map(|(from, to)| *to - *from).collect::<Vec<_>>();
    let held: Duration = hold_times.iter().sum();
    let met_a_hold = |from: Instant, to: Instant| {
        holds.iter().any(|(hold_from, hold_to)| *hold_from < to && *hold_to > from)
    };
    let (mut met, mut free): (Vec<Duration>, Vec<Duration>) = (Vec::new(), Vec::new());
    for (_, from, to) in &requests {
        if met_a_hold(*from, *to) { met.push(*to - *from) } else { free.push(*to - *from) }
    }
    println!(
        "registry_wal_person: workspaces={workspaces} seconds={seconds:.1} storm_changes={changes} \
         person_requests={} wal_frame_bytes={} wal_file_high_water_bytes={} limit={WAL_SIZE_LIMIT_BYTES}",
        requests.len(),
        after.registry_wal_frame_bytes - built.registry_wal_frame_bytes,
        after.registry_wal_file_high_water_bytes,
    );
    println!(
        "registry_wal_person: workspaces={workspaces} lock_holds_of_the_restart_rule {} \
         held_total_ms={:.1} held_share_of_the_run={:.4}",
        row(&mut hold_times),
        held.as_secs_f64() * 1000.0,
        held.as_secs_f64() / seconds,
    );
    println!(
        "registry_wal_person: workspaces={workspaces} person_requests_that_met_a_hold {} share={:.4}",
        row(&mut met),
        met.len() as f64 / requests.len() as f64,
    );
    println!(
        "registry_wal_person: workspaces={workspaces} person_requests_that_met_none {}",
        row(&mut free)
    );
    for (kind, name) in KINDS.iter().enumerate() {
        let of_kind = |with_hold: bool| {
            requests
                .iter()
                .filter(|(k, from, to)| *k == kind && met_a_hold(*from, *to) == with_hold)
                .map(|(_, from, to)| *to - *from)
                .collect::<Vec<_>>()
        };
        println!(
            "registry_wal_person: workspaces={workspaces} kind={name} met_a_hold {} | met_none {}",
            row(&mut of_kind(true)),
            row(&mut of_kind(false)),
        );
    }
    assert!(!requests.is_empty() && changes > 0, "the arm of {workspaces} measured nothing");
}

/// No request waits for the bulk of the checkpoint that lets the WAL
/// restart. The copy of the bulk is made [`SLOW_BULK`] slower (a large WAL
/// on a busy disk); the storm's request whose commit takes the WAL to its
/// restart point, a person's request beside it, and each span in which the
/// restart rule keeps the writer lock must all stay under [`NO_WAIT`].
#[cfg(unix)]
#[test]
fn no_request_waits_for_the_bulk_of_a_restart_checkpoint() {
    const SLOW_BULK: Duration = Duration::from_millis(600);
    const NO_WAIT: Duration = Duration::from_millis(300);
    const HOLDS: usize = 2;
    let root = std::env::temp_dir()
        .join(format!("cmux-wal-bulk-{}", crate::workspace_registry::new_uuid_v4()));
    let mux = open_persistent_test_mux("wal-bulk", &root);
    mux.stop_journal_maintenance();
    mux.new_workspace(None, Some((80, 24))).unwrap();
    mux.create_empty_workspace(Some("storm".to_owned()), None, None).unwrap();
    mux.request_registry_flush();
    let (person_workspace, storm_workspace) =
        mux.with_state(|state| (state.workspaces[0].id, state.workspaces[1].id));
    mux.registry_connection.slow_wal_restart_bulk_for_test(SLOW_BULK);

    let stop = Arc::new(AtomicBool::new(false));
    let storm = {
        let (mux, stop) = (mux.clone(), stop.clone());
        std::thread::spawn(move || {
            let (mut changes, mut slowest) = (0u64, Duration::ZERO);
            while !stop.load(Ordering::Acquire) {
                let from = Instant::now();
                assert!(mux.rename_workspace(storm_workspace, format!("storm {changes}")));
                slowest = slowest.max(from.elapsed());
                mux.request_registry_flush();
                changes += 1;
            }
            (changes, slowest)
        })
    };
    let started = Instant::now();
    let (mut requests, mut person_slowest) = (0u64, Duration::ZERO);
    let holds = loop {
        let from = Instant::now();
        assert!(mux.rename_workspace(person_workspace, format!("person {requests}")));
        person_slowest = person_slowest.max(from.elapsed());
        mux.request_registry_flush();
        requests += 1;
        std::thread::sleep(Duration::from_millis(2));
        let holds = mux.registry_connection.wal_restart_holds_for_test();
        if holds.len() >= HOLDS || started.elapsed() > Duration::from_secs(120) {
            break holds;
        }
    };
    stop.store(true, Ordering::Release);
    let (changes, storm_slowest) = storm.join().unwrap();
    mux.shutdown();
    let _ = std::fs::remove_dir_all(&root);
    let longest_hold = holds.iter().map(|(from, to)| *to - *from).max().unwrap_or(Duration::ZERO);
    println!(
        "registry_wal_bulk: storm_changes={changes} person_requests={requests} holds={} \
         longest_hold_ms={} storm_slowest_ms={} person_slowest_ms={} slow_bulk_ms={}",
        holds.len(),
        longest_hold.as_millis(),
        storm_slowest.as_millis(),
        person_slowest.as_millis(),
        SLOW_BULK.as_millis(),
    );
    assert!(holds.len() >= HOLDS, "the restart rule ran {} times in 120 s", holds.len());
    assert!(
        storm_slowest < NO_WAIT && person_slowest < NO_WAIT && longest_hold < NO_WAIT,
        "with the bulk of each restart checkpoint {} ms slower, the slowest storm request took \
         {} ms, the slowest request of the person {} ms, and the restart rule kept the writer \
         lock for {} ms; none may wait for the bulk ({} ms)",
        SLOW_BULK.as_millis(),
        storm_slowest.as_millis(),
        person_slowest.as_millis(),
        longest_hold.as_millis(),
        NO_WAIT.as_millis(),
    );
}

#[cfg(unix)]
#[test]
#[ignore = "a measure of minutes: run it by name (module docs)"]
fn person_requests_beside_a_change_storm_on_1_workspace() {
    person_requests_beside_a_change_storm(1);
}

#[cfg(unix)]
#[test]
#[ignore = "a measure of minutes: run it by name (module docs)"]
fn person_requests_beside_a_change_storm_on_60_workspaces() {
    person_requests_beside_a_change_storm(60);
}

#[cfg(unix)]
#[test]
#[ignore = "a measure of minutes: run it by name (module docs)"]
fn person_requests_beside_a_change_storm_on_826_workspaces() {
    person_requests_beside_a_change_storm(826);
}
