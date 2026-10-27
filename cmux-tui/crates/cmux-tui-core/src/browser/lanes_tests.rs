use std::sync::Arc;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::mpsc::{Receiver, Sender, TryRecvError, channel, sync_channel};
use std::time::{Duration, Instant};

use super::*;

const WAIT: Duration = Duration::from_secs(10);

/// Records each turn's number on `turns`, then answers `next`.
struct Recorder {
    turns: Sender<usize>,
    count: usize,
    next: Box<dyn FnMut(usize) -> LaneTurn + Send>,
}

impl LaneTask for Recorder {
    fn run(&mut self) -> LaneTurn {
        self.count += 1;
        let _ = self.turns.send(self.count);
        (self.next)(self.count)
    }
}

fn recorder(next: impl FnMut(usize) -> LaneTurn + Send + 'static) -> (Recorder, Receiver<usize>) {
    let (turns, rx) = channel();
    (Recorder { turns, count: 0, next: Box::new(next) }, rx)
}

/// Waits until `check` holds; test-only polling of the pool's counters.
fn eventually(check: impl Fn() -> bool) -> bool {
    let deadline = Instant::now() + WAIT;
    while Instant::now() < deadline {
        if check() {
            return true;
        }
        std::thread::sleep(Duration::from_millis(2));
    }
    check()
}

#[test]
fn a_lane_starts_no_worker_until_its_first_wake() {
    let lanes = BrowserLanes::new();
    let (task, turns) = recorder(|_| LaneTurn::Idle);
    let lane = lanes.pool().start(task);
    assert_eq!(lanes.pool().live_workers(), 0);
    assert_eq!(turns.try_recv(), Err(TryRecvError::Empty));
    lane.wake();
    assert_eq!(turns.recv_timeout(WAIT), Ok(1));
}

#[test]
fn a_wake_before_the_task_starts_runs_it_once_it_starts() {
    let lanes = BrowserLanes::new();
    let lane = lanes.pool().reserve();
    lane.wake();
    lane.wake();
    let (task, turns) = recorder(|_| LaneTurn::Idle);
    lane.start(task);
    assert_eq!(turns.recv_timeout(WAIT), Ok(1));
    assert_eq!(
        turns.recv_timeout(Duration::from_millis(100)),
        Err(std::sync::mpsc::RecvTimeoutError::Timeout)
    );
}

/// A lane never runs two turns at once: wakes during a turn fold into one
/// more turn after it, and the turns stay in order.
#[test]
fn a_lane_runs_one_turn_at_a_time() {
    let lanes = BrowserLanes::new();
    let running = Arc::new(AtomicUsize::new(0));
    let overlaps = Arc::new(AtomicUsize::new(0));
    let (entered_tx, entered) = channel();
    let (release_tx, release) = sync_channel::<()>(0);
    let task = {
        let overlaps = overlaps.clone();
        recorder(move |turn| {
            if running.fetch_add(1, Ordering::AcqRel) != 0 {
                overlaps.fetch_add(1, Ordering::AcqRel);
            }
            if turn == 1 {
                let _ = entered_tx.send(());
                let _ = release.recv();
            }
            running.fetch_sub(1, Ordering::AcqRel);
            LaneTurn::Idle
        })
    };
    let (task, turns) = task;
    let lane = lanes.pool().start(task);
    lane.wake();
    entered.recv_timeout(WAIT).unwrap();
    for _ in 0..10 {
        lane.wake();
    }
    release_tx.send(()).unwrap();
    assert_eq!(turns.recv_timeout(WAIT), Ok(1));
    assert_eq!(turns.recv_timeout(WAIT), Ok(2));
    assert_eq!(
        turns.recv_timeout(Duration::from_millis(100)),
        Err(std::sync::mpsc::RecvTimeoutError::Timeout)
    );
    assert_eq!(overlaps.load(Ordering::Acquire), 0);
}

/// A lane blocked in a long turn (a CDP call to a wedged page) never delays
/// another lane: the pool starts a worker for it, and that worker exits once
/// nothing is ready.
#[test]
fn a_blocked_lane_never_delays_another_and_extra_workers_exit() {
    let lanes = BrowserLanes::new();
    let mut releases = Vec::new();
    let mut blocked = Vec::new();
    for _ in 0..BASE_WORKERS + 2 {
        let (entered_tx, entered) = channel();
        let (release_tx, release) = channel::<()>();
        let (task, _turns) = recorder(move |_| {
            let _ = entered_tx.send(());
            let _ = release.recv();
            LaneTurn::Idle
        });
        let lane = lanes.pool().start(task);
        lane.wake();
        entered.recv_timeout(WAIT).expect("a blocked lane delayed another one");
        releases.push(release_tx);
        blocked.push(lane);
    }
    let (task, turns) = recorder(|_| LaneTurn::Idle);
    lanes.pool().start(task).wake();
    assert_eq!(turns.recv_timeout(WAIT), Ok(1));
    drop(releases);
    assert!(
        eventually(|| lanes.pool().live_workers() <= BASE_WORKERS),
        "{} workers stayed",
        lanes.pool().live_workers()
    );
}

#[test]
fn a_lane_runs_again_at_its_deadline() {
    let lanes = BrowserLanes::new();
    let due = Instant::now() + Duration::from_millis(50);
    let (task, turns) =
        recorder(move |turn| if turn == 1 { LaneTurn::WakeAt(due) } else { LaneTurn::Idle });
    lanes.pool().start(task).wake();
    assert_eq!(turns.recv_timeout(WAIT), Ok(1));
    assert_eq!(turns.recv_timeout(WAIT), Ok(2));
    assert!(Instant::now() >= due);
}

#[test]
fn again_puts_a_lane_behind_the_other_ready_lanes() {
    let lanes = BrowserLanes::new();
    let (task, turns) = recorder(|turn| if turn < 3 { LaneTurn::Again } else { LaneTurn::Idle });
    lanes.pool().start(task).wake();
    for turn in 1..=3 {
        assert_eq!(turns.recv_timeout(WAIT), Ok(turn));
    }
}

#[test]
fn done_removes_the_lane_and_drops_its_task() {
    let lanes = BrowserLanes::new();
    let held = Arc::new(());
    let (task, turns) = {
        let held = held.clone();
        recorder(move |_| {
            let _ = &held;
            LaneTurn::Done
        })
    };
    let lane = lanes.pool().start(task);
    lane.wake();
    assert_eq!(turns.recv_timeout(WAIT), Ok(1));
    assert!(eventually(|| Arc::strong_count(&held) == 1));
    assert_eq!(lanes.pool().lanes(), 0);
    lane.wake();
}

#[test]
fn a_panicking_turn_ends_only_its_lane() {
    let lanes = BrowserLanes::new();
    let (task, _) = recorder(|_| panic!("lane task panic (expected by this test)"));
    lanes.pool().start(task).wake();
    let (task, turns) = recorder(|_| LaneTurn::Idle);
    lanes.pool().start(task).wake();
    assert_eq!(turns.recv_timeout(WAIT), Ok(1));
    assert!(eventually(|| lanes.pool().lanes() == 1));
}

#[test]
fn dropping_the_owner_drops_every_task() {
    let lanes = BrowserLanes::new();
    let held = Arc::new(());
    let pool = lanes.pool().clone();
    for _ in 0..3 {
        let held = held.clone();
        let (task, _) = recorder(move |_| {
            let _ = &held;
            LaneTurn::Idle
        });
        pool.start(task).wake();
    }
    drop(lanes);
    assert!(eventually(|| Arc::strong_count(&held) == 1));
    assert!(eventually(|| pool.live_workers() == 0));
    // A lane made after shutdown never runs: its task is dropped unrun.
    let (task, turns) = recorder(|_| LaneTurn::Idle);
    pool.start(task).wake();
    assert_eq!(turns.recv_timeout(WAIT), Err(std::sync::mpsc::RecvTimeoutError::Disconnected));
}

#[test]
fn a_lane_sender_wakes_on_send_and_when_its_last_clone_drops() {
    struct Drain {
        rx: Receiver<u32>,
        seen: Sender<Option<u32>>,
    }
    impl LaneTask for Drain {
        fn run(&mut self) -> LaneTurn {
            loop {
                match self.rx.try_recv() {
                    Ok(value) => {
                        let _ = self.seen.send(Some(value));
                    }
                    Err(TryRecvError::Empty) => return LaneTurn::Idle,
                    Err(TryRecvError::Disconnected) => {
                        let _ = self.seen.send(None);
                        return LaneTurn::Done;
                    }
                }
            }
        }
    }
    let lanes = BrowserLanes::new();
    let lane = lanes.pool().reserve();
    let (tx, rx) = sync_channel(4);
    let (seen_tx, seen) = channel();
    let sender = LaneSender::new(tx, lane.clone());
    lane.start(Drain { rx, seen: seen_tx });
    sender.try_send(7).unwrap();
    assert_eq!(seen.recv_timeout(WAIT), Ok(Some(7)));
    let clone = sender.clone();
    drop(sender);
    clone.try_send(8).unwrap();
    assert_eq!(seen.recv_timeout(WAIT), Ok(Some(8)));
    drop(clone);
    assert_eq!(seen.recv_timeout(WAIT), Ok(None));
    assert!(eventually(|| lanes.pool().lanes() == 0));
}

/// A lane that blocks in its turn until its release sender drops, and the
/// channel that tells its turn started.
fn blocking_lane(lanes: &BrowserLanes) -> (LaneHandle, Sender<()>, Receiver<()>) {
    let (entered_tx, entered) = channel();
    let (release_tx, release) = channel::<()>();
    let (task, _turns) = recorder(move |_| {
        let _ = entered_tx.send(());
        let _ = release.recv();
        LaneTurn::Idle
    });
    (lanes.pool().start(task), release_tx, entered)
}

/// A lane blocked in its turn until its release sender drops.
fn blocked_lane(lanes: &BrowserLanes) -> (LaneHandle, Sender<()>) {
    let (lane, release, entered) = blocking_lane(lanes);
    lane.wake();
    entered.recv_timeout(WAIT).expect("a blocked lane delayed another one");
    (lane, release)
}

/// How long a deadline may run late before a test calls it lost.
const DEADLINE_SLACK: Duration = Duration::from_secs(2);

/// A temporary worker that is the last free one is not reclaimed while a
/// deadline is armed: with every base worker blocked in a turn (a CDP call
/// to a wedged page), the deadline still runs on time.
#[test]
fn a_deadline_runs_on_time_while_every_base_worker_is_blocked() {
    let lanes = BrowserLanes::new();
    let blocked = (0..BASE_WORKERS).map(|_| blocked_lane(&lanes)).collect::<Vec<_>>();
    let due = Instant::now() + RECLAIM + Duration::from_millis(500);
    let (task, turns) =
        recorder(move |turn| if turn == 1 { LaneTurn::WakeAt(due) } else { LaneTurn::Idle });
    lanes.pool().start(task).wake();
    assert_eq!(turns.recv_timeout(WAIT), Ok(1));
    let wait = due.saturating_duration_since(Instant::now()) + DEADLINE_SLACK;
    assert_eq!(turns.recv_timeout(wait), Ok(2), "the deadline waited for a blocked turn");
    assert!(Instant::now() >= due);
    drop(blocked);
}

/// A deadline armed while no worker is free, whose worker then starts a
/// blocking turn, still runs on time: that worker starts one more first.
#[test]
fn a_deadline_armed_while_no_worker_is_free_runs_on_time() {
    let lanes = BrowserLanes::new();
    let blocked = (0..BASE_WORKERS - 1).map(|_| blocked_lane(&lanes)).collect::<Vec<_>>();
    let due = Instant::now() + RECLAIM + Duration::from_millis(500);
    let (task, turns) =
        recorder(move |turn| if turn == 1 { LaneTurn::WakeAt(due) } else { LaneTurn::Idle });
    lanes.pool().start(task).wake();
    assert_eq!(turns.recv_timeout(WAIT), Ok(1));
    // The last base worker, which armed the deadline, waits for it; a lane
    // that becomes ready now takes it into a blocking turn.
    assert!(eventually(|| lanes.pool().free_workers() == 1));
    assert_eq!(lanes.pool().live_workers(), BASE_WORKERS);
    let last = blocked_lane(&lanes);
    let wait = due.saturating_duration_since(Instant::now()) + DEADLINE_SLACK;
    assert_eq!(turns.recv_timeout(wait), Ok(2), "the deadline waited for a blocked turn");
    assert!(Instant::now() >= due);
    drop((blocked, last));
}

/// A burst of lanes that each start a worker while a deadline is armed
/// adds one worker for the deadline, not one per lane.
#[test]
fn a_burst_with_a_deadline_armed_adds_one_deadline_worker() {
    let lanes = BrowserLanes::new();
    let due = Instant::now() + Duration::from_secs(60);
    let (task, turns) =
        recorder(move |turn| if turn == 1 { LaneTurn::WakeAt(due) } else { LaneTurn::Idle });
    let timed = lanes.pool().start(task);
    timed.wake();
    assert_eq!(turns.recv_timeout(WAIT), Ok(1));
    let burst = 8;
    let blocked = (0..burst).map(|_| blocking_lane(&lanes)).collect::<Vec<_>>();
    for (lane, _, _) in &blocked {
        lane.wake();
    }
    for (_, _, entered) in &blocked {
        entered.recv_timeout(WAIT).expect("a blocked lane delayed another one");
    }
    assert!(eventually(|| lanes.pool().free_workers() >= 1));
    assert!(
        lanes.pool().live_workers() <= burst + 1,
        "{} workers for {burst} blocked lanes",
        lanes.pool().live_workers()
    );
    drop(blocked);
}
