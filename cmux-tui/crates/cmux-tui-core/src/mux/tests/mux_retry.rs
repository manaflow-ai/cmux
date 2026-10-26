//! One-shot daemon work runs on `Mux::work`, not on a thread per operation
//! (p02-threads 230): a retry reposts itself with a delay, and a start's
//! adoptions wait for ready without a thread each.

use std::sync::mpsc::{self, RecvTimeoutError};

use cmux_threads::work::{Lane, Priority};

use super::*;
use crate::mux::mux_work::Retry;

const WAIT: Duration = Duration::from_secs(10);

fn live_threads_named(prefix: &str) -> usize {
    cmux_threads::snapshot().iter().filter(|row| row.name.starts_with(prefix)).count()
}

#[test]
fn a_retry_backs_off_on_work_items_and_ends_when_done() {
    let mux = Mux::new_for_test("mux-retry-done", SurfaceOptions::default());
    let (tries_tx, tries) = mpsc::channel();
    let mut count = 0;
    let started = Instant::now();
    mux.post_mux_retry(Duration::from_millis(1), Priority::UserVisible, Lane::Cpu, move |_| {
        count += 1;
        let _ = tries_tx.send(std::thread::current().name().unwrap_or_default().to_owned());
        if count < 3 { Retry::After(Duration::from_millis(20)) } else { Retry::Done }
    })
    .unwrap();
    for _ in 0..3 {
        let thread = tries.recv_timeout(WAIT).expect("a try ran");
        assert_eq!(thread, "mux-cpu-fg", "a try ran off the work lane");
    }
    assert!(started.elapsed() >= Duration::from_millis(40), "the backoff was skipped");
    // Done: the attempt, and the sender it owns, are dropped.
    assert_eq!(tries.recv_timeout(WAIT), Err(RecvTimeoutError::Disconnected));
    assert_eq!(mux.work.delayed_pending(), 0);
    mux.shutdown();
}

#[test]
fn shutdown_drops_a_waiting_retry_and_its_state() {
    let mux = Mux::new_for_test("mux-retry-shutdown", SurfaceOptions::default());
    let (held_tx, held) = mpsc::channel::<()>();
    mux.post_mux_retry(Duration::from_secs(60), Priority::UserVisible, Lane::Files, move |_| {
        let _ = held_tx.send(());
        Retry::Done
    })
    .unwrap();
    assert_eq!(mux.work.delayed_pending(), 1);
    mux.shutdown();
    assert_eq!(held.recv_timeout(WAIT), Err(RecvTimeoutError::Disconnected), "the try ran");
    assert_eq!(mux.work.delayed_pending(), 0);
    // After shutdown a retry is refused.
    let refused =
        mux.post_mux_retry(Duration::ZERO, Priority::UserVisible, Lane::Files, |_| Retry::Done);
    assert!(refused.is_err());
}

#[test]
fn held_start_adoptions_start_on_ready_with_no_thread_each() {
    let mux = Mux::new_for_test("mux-retry-startup", SurfaceOptions::default());
    let adopt_threads = live_threads_named("terminal-adopt-");
    let (started_tx, started) = mpsc::channel();
    for index in 0..20 {
        let started_tx = started_tx.clone();
        mux.hold_startup_adoption(
            format!("term-{index}"),
            Box::new(move |_| {
                let _ = started_tx.send(index);
            }),
        );
    }
    drop(started_tx);
    assert_eq!(started.try_recv(), Err(mpsc::TryRecvError::Empty), "an adoption started early");
    assert_eq!(live_threads_named("terminal-adopt-"), adopt_threads);
    // A request that waits on one starts it at once.
    mux.wait_for_terminal_adoption("term-7", Duration::ZERO);
    assert_eq!(started.recv_timeout(WAIT), Ok(7));
    mux.release_startup_adoptions();
    let mut rest: Vec<i32> = started.iter().collect();
    rest.sort_unstable();
    assert_eq!(rest, (0..20).filter(|index| *index != 7).collect::<Vec<_>>());
    // After ready, an adoption starts at once.
    let (late_tx, late) = mpsc::channel();
    mux.hold_startup_adoption(
        "term-late".to_owned(),
        Box::new(move |_| {
            let _ = late_tx.send(());
        }),
    );
    assert_eq!(late.try_recv(), Ok(()));
    mux.shutdown();
}
