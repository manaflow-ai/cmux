//! Measurement: what one live fact of a terminal costs on the publish path
//! (`Surface::publish_pending_state`, the call the terminal publisher makes).
//!
//! A live fact takes three short locks in `mux/terminal_live.rs`: the
//! cached journal hook answer, the list of changed terminals and the
//! journal event epoch for the wake. The `session.events` streams take the
//! last two. This test prints the time of one publish call as a
//! distribution on a session of 826 workspaces (Lawrence's size) with 30
//! printing terminals:
//!
//! - `alone`: no stream waits.
//! - `streams13`: 13 threads do a stream's lock work in a tight loop (wait
//!   for the wake, read the changed terminals), which is more lock traffic
//!   than 13 real streams make.
//! - `registry_held`: another thread holds the workspace registry for the
//!   whole arm. The calls end; this is the count that matters: a live fact
//!   does not wait for a registry writer.
//! - `rows`: a journal stream follows `terminal.progress`, so each fact is
//!   one commit, as every fact was before live facts left the journal.
//!
//! Ignored: it asserts counts only and prints times. Run it by name:
//! `cargo test -p cmux-tui-core --lib terminal_live_cost -- --ignored --nocapture --test-threads 1`.

use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::mpsc::sync_channel;

use super::*;

const WORKSPACES: usize = 826;
const PRINTING_TERMINALS: usize = 30;
const STREAMS: usize = 13;
/// One step of the simulated clock (`terminal_activity.rs` pushes a moved
/// "last output" at most this often).
const TICK_MS: u64 = 5_000;
const LIVE_TICKS: u64 = 200;
const ROW_TICKS: u64 = 20;

/// Each terminal prints one frame with a new OSC 9;4 value per tick and
/// publishes it. Returns the time of each publish call, in nanoseconds.
fn publish_ticks(
    terminals: &[Arc<Surface>],
    ticks: std::ops::Range<u64>,
    start_ms: u64,
) -> Vec<u64> {
    let mut times = Vec::new();
    for tick in ticks {
        for surface in terminals {
            let frame = format!("\x1b]9;4;1;{}\x07line {tick}\r\n", tick % 100);
            surface.apply_stream_output_for_test(frame.as_bytes()).unwrap();
            surface.note_output_at_for_test(start_ms + tick * TICK_MS);
            let started = Instant::now();
            surface.publish_pending_state();
            times.push(u64::try_from(started.elapsed().as_nanos()).unwrap_or(u64::MAX));
        }
    }
    times
}

fn micros(nanos: u64) -> String {
    format!("{}.{:03}", nanos / 1000, nanos % 1000)
}

/// Journal rows and registry commits so far.
fn wrote(mux: &Mux) -> (u64, u64) {
    (mux.session_journal_head().unwrap(), mux.write_path_stats().wal_commits)
}

fn report(arm: &str, mut times: Vec<u64>, wall: Duration, added: (u64, u64)) {
    times.sort_unstable();
    let at = |permille: usize| micros(times[(times.len() - 1) * permille / 1000]);
    println!(
        "terminal_live_cost: workspaces={WORKSPACES} terminals={PRINTING_TERMINALS} arm={arm} \
         calls={} p50_us={} p95_us={} p99_us={} max_us={} wall_ms={} journal_rows={} wal_commits={}",
        times.len(),
        at(500),
        at(950),
        at(990),
        at(1000),
        wall.as_millis(),
        added.0,
        added.1,
    );
}

#[cfg(unix)]
#[test]
#[ignore = "measurement"]
fn terminal_live_cost_of_one_fact_on_826_workspaces() {
    let root = std::env::temp_dir()
        .join(format!("cmux-terminal-live-cost-{}", crate::workspace_registry::new_uuid_v4()));
    let mux = open_persistent_test_mux("terminal-live-cost", &root);
    mux.stop_journal_maintenance();
    let mut terminals = Vec::with_capacity(PRINTING_TERMINALS);
    for _ in 0..PRINTING_TERMINALS {
        terminals.push(mux.new_workspace(None, Some((80, 24))).unwrap());
    }
    for index in PRINTING_TERMINALS..WORKSPACES {
        mux.create_empty_workspace(Some(format!("idle {index}")), None, None).unwrap();
    }
    for surface in &terminals {
        surface.publish_pending_directory();
        surface.publish_pending_progress();
    }
    assert!(
        mux.wait_for_terminal_publisher_for_test(Duration::from_secs(30)),
        "the terminal publisher did not drain"
    );
    let start_ms = crate::workspace_registry::unix_epoch_ms().unwrap() + 60_000;
    let since = |before: (u64, u64)| {
        let now = wrote(&mux);
        (now.0 - before.0, now.1 - before.1)
    };
    let mut tick = 1;
    let mut next_ticks = |count: u64| {
        let ticks = tick..tick + count;
        tick += count;
        ticks
    };
    // The first fact reads the journal hooks once; it is not in an arm.
    let _ = publish_ticks(&terminals, next_ticks(1), start_ms);

    let before = wrote(&mux);
    let started = Instant::now();
    let times = publish_ticks(&terminals, next_ticks(LIVE_TICKS), start_ms);
    let wall = started.elapsed();
    report("alone", times, wall, since(before));
    assert_eq!(since(before), (0, 0), "a live fact wrote a journal row or committed");

    // 13 threads do the lock work of a `session.events` stream.
    let stop = Arc::new(AtomicBool::new(false));
    let wakes = Arc::new(AtomicU64::new(0));
    let interrupt = crate::stream_interrupt::StreamInterrupt::new();
    mux.wake_journal_waiters_on(&interrupt);
    let streams: Vec<_> = (0..STREAMS)
        .map(|_| {
            let (mux, stop, wakes, interrupt) =
                (mux.clone(), stop.clone(), wakes.clone(), interrupt.clone());
            std::thread::spawn(move || {
                let mut seen = (mux.journal_event_epoch(), mux.terminal_live_sequence());
                while !stop.load(Ordering::Acquire) {
                    let next =
                        mux.wait_for_session_event_until_interrupted(seen.0, seen.1, &interrupt);
                    let (sequence, changed) = mux.terminal_live_changes_after(seen.1);
                    wakes.fetch_add(u64::try_from(changed.len()).unwrap(), Ordering::Relaxed);
                    seen = (next.0, sequence);
                }
            })
        })
        .collect();
    let before = wrote(&mux);
    let started = Instant::now();
    let times = publish_ticks(&terminals, next_ticks(LIVE_TICKS), start_ms);
    let wall = started.elapsed();
    report("streams13", times, wall, since(before));
    stop.store(true, Ordering::Release);
    interrupt.fire();
    for stream in streams {
        stream.join().unwrap();
    }
    println!(
        "terminal_live_cost: arm=streams13 terminals_read_by_the_streams={}",
        wakes.load(Ordering::Relaxed)
    );
    assert_eq!(since(before), (0, 0), "a live fact wrote a journal row or committed");
    assert!(wakes.load(Ordering::Relaxed) > 0, "no stream thread read a changed terminal");

    // Another thread holds the workspace registry: the live facts must not wait for it.
    // (The counters read the registry: take them before the hold and after the release.)
    let before = wrote(&mux);
    let (entered, held) = sync_channel(1);
    let (release, released) = sync_channel(1);
    let holder = {
        let mux = mux.clone();
        std::thread::spawn(move || mux.hold_workspace_registry_for_test(entered, released))
    };
    held.recv_timeout(Duration::from_secs(10)).expect("the holder took the workspace registry");
    let (done, finished) = sync_channel(1);
    let publisher = {
        let (terminals, ticks) = (terminals.clone(), next_ticks(LIVE_TICKS));
        std::thread::spawn(move || {
            let started = Instant::now();
            let times = publish_ticks(&terminals, ticks, start_ms);
            done.send((times, started.elapsed())).unwrap();
        })
    };
    let published = finished.recv_timeout(Duration::from_secs(60));
    release.send(()).unwrap();
    holder.join().unwrap();
    publisher.join().unwrap();
    let (times, wall) =
        published.expect("live facts waited for the workspace registry while a writer held it");
    report("registry_held", times, wall, since(before));
    assert_eq!(since(before), (0, 0), "a live fact wrote a journal row or committed");

    // The path before: each fact is one commit while a journal stream follows the rows.
    let follower = mux.follow_terminal_progress_rows(|kind| kind == "terminal.progress");
    assert!(follower.is_some(), "a follower of `terminal.progress` is counted");
    let before = wrote(&mux);
    let started = Instant::now();
    let times = publish_ticks(&terminals, next_ticks(ROW_TICKS), start_ms);
    let wall = started.elapsed();
    let calls = u64::try_from(times.len()).unwrap();
    report("rows", times, wall, since(before));
    assert_eq!(since(before).0, calls, "a followed live fact is one journal row");
    drop(follower);

    mux.shutdown();
    let _ = std::fs::remove_dir_all(&root);
}
