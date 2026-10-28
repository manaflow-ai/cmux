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

/// Adoption-shaped tries (System lane, UserVisible, their wait inside
/// `will_block`) under `ADOPTION_REPLAYS` permits: at most that many run at
/// once, the rest park with no thread, and the System lane still runs a
/// UserVisible item at once while every permit waits on its host. Without the
/// permits and `will_block`, five such tries filled the lane's UserVisible
/// limit and the probe waited behind them.
#[test]
fn limited_retries_bound_concurrency_and_leave_the_system_lane_free() {
    use crate::mux::terminal_adoption::ADOPTION_REPLAYS;
    let mux = Mux::new_for_test("mux-retry-limited", SurfaceOptions::default());
    let tries = ADOPTION_REPLAYS + 4;
    let (started_tx, started) = mpsc::channel();
    let (release_tx, release) = mpsc::channel::<()>();
    let release = Arc::new(Mutex::new(release));
    let (done_tx, done) = mpsc::channel();
    for index in 0..tries {
        let (started_tx, release, done_tx) =
            (started_tx.clone(), Arc::clone(&release), done_tx.clone());
        mux.post_mux_retry_limited(
            Duration::ZERO,
            Priority::UserVisible,
            Lane::System,
            (&mux.terminal_replays, None),
            move |_| {
                let _ = started_tx.send(index);
                cmux_threads::work::will_block(|| {
                    let _ = release.lock().unwrap().recv();
                });
                let _ = done_tx.send(index);
                Retry::Done
            },
        )
        .unwrap();
    }
    for _ in 0..ADOPTION_REPLAYS {
        started.recv_timeout(WAIT).expect("a try started");
    }
    let deadline = Instant::now() + WAIT;
    while mux.terminal_replays.parked() != tries - ADOPTION_REPLAYS {
        assert!(Instant::now() < deadline, "the tries past the width did not park");
        std::thread::yield_now();
    }
    assert_eq!(mux.terminal_replays.held(), ADOPTION_REPLAYS);
    assert_eq!(started.try_recv(), Err(mpsc::TryRecvError::Empty), "a try ran past the width");
    let (probe_tx, probe) = mpsc::channel();
    mux.work
        .post(Priority::UserVisible, Lane::System, cmux_threads::work::Shutdown::SkipOnShutdown, {
            move || {
                let _ = probe_tx.send(());
            }
        })
        .unwrap();
    assert_eq!(probe.recv_timeout(WAIT), Ok(()), "the System lane waited behind the tries");
    for _ in 0..tries {
        release_tx.send(()).unwrap();
    }
    let mut finished: Vec<usize> = (0..tries).map(|_| done.recv_timeout(WAIT).unwrap()).collect();
    finished.sort_unstable();
    assert_eq!(finished, (0..tries).collect::<Vec<_>>());
    let deadline = Instant::now() + WAIT;
    while mux.terminal_replays.held() != 0 {
        assert!(Instant::now() < deadline, "a permit was kept");
        std::thread::yield_now();
    }
    assert_eq!(mux.terminal_replays.parked(), 0);
    mux.shutdown();
}

/// A try whose key a caller waits on (`Permits::promote`, an attach to a
/// terminal that still adopts) leaves its place in the queue: it runs at
/// once, past the width, while every permit is held and earlier tries wait.
#[test]
fn a_promoted_try_runs_before_the_queued_ones() {
    use crate::mux::terminal_adoption::ADOPTION_REPLAYS;
    let mux = Mux::new_for_test("mux-retry-promoted", SurfaceOptions::default());
    let tries = ADOPTION_REPLAYS + 4;
    let (started_tx, started) = mpsc::channel();
    let (release_tx, release) = mpsc::channel::<()>();
    let release = Arc::new(Mutex::new(release));
    for index in 0..tries {
        let (started_tx, release) = (started_tx.clone(), Arc::clone(&release));
        let key: Arc<str> = Arc::from(format!("term-{index}"));
        mux.post_mux_retry_limited(
            Duration::ZERO,
            Priority::UserVisible,
            Lane::System,
            (&mux.terminal_replays, Some(key)),
            move |_| {
                let _ = started_tx.send(index);
                // Only the held tries wait; the promoted one ends at once.
                if index < ADOPTION_REPLAYS {
                    cmux_threads::work::will_block(|| {
                        let _ = release.lock().unwrap().recv();
                    });
                }
                Retry::Done
            },
        )
        .unwrap();
        if index + 1 == ADOPTION_REPLAYS {
            // The held tries take every permit before the rest are posted.
            for _ in 0..ADOPTION_REPLAYS {
                started.recv_timeout(WAIT).expect("a try started");
            }
        }
    }
    let deadline = Instant::now() + WAIT;
    while mux.terminal_replays.parked() != tries - ADOPTION_REPLAYS {
        assert!(Instant::now() < deadline, "the tries past the width did not park");
        std::thread::yield_now();
    }
    let last = tries - 1;
    mux.terminal_replays.promote(&format!("term-{last}"));
    assert_eq!(started.recv_timeout(WAIT), Ok(last), "the promoted try waited for a permit");
    assert_eq!(started.try_recv(), Err(mpsc::TryRecvError::Empty), "a queued try ran too");
    mux.terminal_replays.demote(&format!("term-{last}"));
    for _ in 0..ADOPTION_REPLAYS {
        release_tx.send(()).unwrap();
    }
    let mut rest: Vec<usize> =
        (0..tries - ADOPTION_REPLAYS - 1).map(|_| started.recv_timeout(WAIT).unwrap()).collect();
    rest.sort_unstable();
    assert_eq!(rest, (ADOPTION_REPLAYS..last).collect::<Vec<_>>());
    mux.shutdown();
}

/// A promoted try never waits in the System lane's own queue behind the
/// tries that fill it. Five UserVisible tries hold the lane's UserVisible
/// slots (they block outside `will_block`, as a slow commit does) and twenty
/// more wait. A BestEffort try of key K must run while they still block:
/// promoted before it is posted, and also posted first and promoted after
/// (a respawn queued at its background priority before the app attached).
#[test]
fn a_promoted_try_runs_ahead_of_the_lanes_queue() {
    use crate::mux::mux_work::Permits;
    let mux = Mux::new_for_test("mux-retry-lane-promote", SurfaceOptions::default());
    let permits = Permits::new(64);
    let (started_tx, started) = mpsc::channel();
    let (release_tx, release) = mpsc::channel::<()>();
    let release = Arc::new(Mutex::new(release));
    for index in 0..25 {
        let (started_tx, release) = (started_tx.clone(), Arc::clone(&release));
        mux.post_mux_retry_limited(
            Duration::ZERO,
            Priority::UserVisible,
            Lane::System,
            (&permits, Some(Arc::from(format!("blocker-{index}")))),
            move |_| {
                let _ = started_tx.send(index);
                let _ = release.lock().unwrap().recv();
                Retry::Done
            },
        )
        .unwrap();
    }
    for _ in 0..5 {
        started.recv_timeout(WAIT).expect("a blocker started");
    }
    assert_eq!(
        started.recv_timeout(Duration::from_millis(200)),
        Err(RecvTimeoutError::Timeout),
        "the System lane ran more than 5 UserVisible tries"
    );
    let (ran_tx, ran) = mpsc::channel();
    let post_k = |key: &'static str| {
        let ran_tx = ran_tx.clone();
        mux.post_mux_retry_limited(
            Duration::ZERO,
            Priority::BestEffort,
            Lane::System,
            (&permits, Some(Arc::from(key))),
            move |_| {
                let _ = ran_tx.send(key);
                Retry::Done
            },
        )
        .unwrap();
    };
    // Promoted first, then posted.
    permits.promote("k1");
    post_k("k1");
    assert_eq!(ran.recv_timeout(WAIT), Ok("k1"), "a try promoted before its post waited");
    permits.demote("k1");
    // Posted first, then promoted.
    post_k("k2");
    assert_eq!(
        ran.recv_timeout(Duration::from_millis(300)),
        Err(RecvTimeoutError::Timeout),
        "a BestEffort try ran while UserVisible tries waited"
    );
    permits.promote("k2");
    assert_eq!(
        ran.recv_timeout(WAIT),
        Ok("k2"),
        "a try promoted after its post waited in the lane's queue"
    );
    permits.demote("k2");
    assert_eq!(started.try_recv(), Err(mpsc::TryRecvError::Empty), "a blocker ran meanwhile");
    for _ in 0..25 {
        release_tx.send(()).unwrap();
    }
    for _ in 0..20 {
        started.recv_timeout(WAIT).expect("a queued blocker ran");
    }
    mux.shutdown();
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
