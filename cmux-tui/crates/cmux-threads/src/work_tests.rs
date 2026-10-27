use super::*;
use std::sync::atomic::{AtomicIsize, Ordering};
use std::sync::mpsc::{Receiver, Sender, channel};

const WAIT: Duration = Duration::from_secs(10);

fn config(label: &str, cpu_width: usize, idle_timeout: Duration, keep_alive: usize) -> WorkConfig {
    WorkConfig {
        label: label.to_owned(),
        cpu_width,
        idle_timeout,
        keep_alive,
        spawner: Spawner::default(),
    }
}

fn work(label: &str, cpu_width: usize, idle_timeout: Duration, keep_alive: usize) -> Work {
    Work::new(config(label, cpu_width, idle_timeout, keep_alive)).unwrap()
}

/// Posts an item that holds its slot until the returned sender is dropped or sent to.
fn gate(
    work: &Work,
    priority: Priority,
    lane: Lane,
    shutdown: Shutdown,
) -> (Sender<()>, Receiver<()>) {
    let (release, hold) = channel::<()>();
    let (started_tx, started) = channel();
    work.post(priority, lane, shutdown, move || {
        started_tx.send(()).unwrap();
        let _ = hold.recv();
    })
    .unwrap();
    (release, started)
}

/// `count` gates, each started before this returns.
fn started_gates(
    work: &Work,
    count: usize,
    priority: Priority,
    lane: Lane,
    shutdown: Shutdown,
) -> Vec<Sender<()>> {
    (0..count)
        .map(|_| {
            let (release, started) = gate(work, priority, lane, shutdown);
            started.recv_timeout(WAIT).unwrap();
            release
        })
        .collect()
}

fn until(what: &str, mut done: impl FnMut() -> bool) {
    let deadline = Instant::now() + WAIT;
    while !done() {
        assert!(Instant::now() < deadline, "timed out waiting for {what}");
        std::thread::sleep(Duration::from_millis(5));
    }
}

fn lane_stats(work: &Work, lane: Lane) -> LaneStats {
    work.stats()[lane.index()]
}

#[test]
fn starts_the_highest_priority_item_first() {
    // Cpu at width 2: BestEffort and Idle start only on an empty lane, the others with one slot free.
    let work = work("t-order", 2, Duration::from_secs(30), 0);
    let mut gates =
        started_gates(&work, 2, Priority::UserBlocking, Lane::Cpu, Shutdown::SkipOnShutdown);
    let (order_tx, order) = channel();
    for (priority, tag) in [
        (Priority::Idle, "idle"),
        (Priority::BestEffort, "bestEffort"),
        (Priority::UserVisible, "userVisible"),
        (Priority::UserBlocking, "userBlocking-1"),
        (Priority::UserBlocking, "userBlocking-2"),
    ] {
        let order_tx = order_tx.clone();
        work.post(priority, Lane::Cpu, Shutdown::SkipOnShutdown, move || {
            order_tx.send(tag).unwrap();
        })
        .unwrap();
    }
    assert_eq!(lane_stats(&work, Lane::Cpu).pending, 5);
    // With one gate still running, one item at a time takes the other slot.
    drop(gates.pop());
    let seen: Vec<_> = (0..3).map(|_| order.recv_timeout(WAIT).unwrap()).collect();
    assert_eq!(seen, ["userBlocking-1", "userBlocking-2", "userVisible"]);
    assert_eq!(lane_stats(&work, Lane::Cpu).pending, 2);
    drop(gates);
    let seen: Vec<_> = (0..2).map(|_| order.recv_timeout(WAIT).unwrap()).collect();
    assert_eq!(seen, ["bestEffort", "idle"]);
}

#[test]
fn files_lane_limits_each_priority_by_lane_occupancy() {
    let work = work("t-files", 1, Duration::from_secs(30), 0);
    let (release, started) =
        gate(&work, Priority::UserBlocking, Lane::Files, Shutdown::SkipOnShutdown);
    started.recv_timeout(WAIT).unwrap();
    // One item runs: Idle (limit 1) waits, BestEffort (limit 2) starts.
    let idle = work.run(Priority::Idle, Lane::Files, Shutdown::SkipOnShutdown, || "idle");
    let best_effort =
        work.run(Priority::BestEffort, Lane::Files, Shutdown::SkipOnShutdown, || "bestEffort");
    assert_eq!(best_effort.wait(), Ok("bestEffort"));
    assert_eq!(idle.try_wait(), None);
    drop(release);
    assert_eq!(idle.wait(), Ok("idle"));
}

#[test]
fn system_lane_keeps_one_slot_for_user_blocking() {
    let work = work("t-system", 1, Duration::from_secs(30), 0);
    let gates =
        started_gates(&work, 5, Priority::UserVisible, Lane::System, Shutdown::SkipOnShutdown);
    let user_visible =
        work.run(Priority::UserVisible, Lane::System, Shutdown::SkipOnShutdown, || "userVisible");
    let user_blocking =
        work.run(Priority::UserBlocking, Lane::System, Shutdown::SkipOnShutdown, || "userBlocking");
    assert_eq!(user_blocking.wait(), Ok("userBlocking"));
    assert_eq!(user_visible.try_wait(), None);
    drop(gates);
    assert_eq!(user_visible.wait(), Ok("userVisible"));
}

#[test]
fn best_effort_and_idle_never_take_more_than_two_slots_of_a_lane() {
    for cpu_width in [1, 4, 16] {
        let work = work("t-cap", cpu_width, Duration::from_secs(30), 0);
        for lane in Lane::ALL {
            let mut gates = Vec::new();
            let mut started = Vec::new();
            for priority in [Priority::BestEffort; 3].into_iter().chain([Priority::Idle; 2]) {
                let (release, start) = gate(&work, priority, lane, Shutdown::SkipOnShutdown);
                gates.push(release);
                started.push(start);
            }
            // Admission happens in post, so the counts are final here.
            let stats = lane_stats(&work, lane);
            let cap = if lane == Lane::Cpu && cpu_width < 3 { 1 } else { 2 };
            assert_eq!((stats.running, stats.pending), (cap, 5 - cap), "{lane} width {cpu_width}");
            for start in &started[..cap] {
                start.recv_timeout(WAIT).unwrap();
            }
            assert_eq!(
                work.run(Priority::UserBlocking, lane, Shutdown::SkipOnShutdown, || "now").wait(),
                Ok("now"),
                "{lane} width {cpu_width}"
            );
            drop(gates);
            until("the low items to finish", || {
                let stats = lane_stats(&work, lane);
                (stats.running, stats.pending) == (0, 0)
            });
        }
    }
}

#[test]
fn shutdown_runs_block_items_and_drops_skip_items() {
    let work = Arc::new(work("t-shutdown", 2, Duration::from_secs(30), 0));
    let gates =
        started_gates(&work, 2, Priority::UserBlocking, Lane::Cpu, Shutdown::SkipOnShutdown);
    let skipped = work.run(Priority::UserBlocking, Lane::Cpu, Shutdown::SkipOnShutdown, || "skip");
    let blocked = work.run(Priority::Idle, Lane::Cpu, Shutdown::BlockShutdown, || "block");

    let shutting = Arc::clone(&work);
    let report = std::thread::spawn(move || shutting.shutdown());
    until("shutdown to drop the queued skip item", || skipped.try_wait().is_some());
    assert_eq!(skipped.wait(), Err(WorkError::Dropped));
    assert_eq!(
        work.post(Priority::UserBlocking, Lane::Files, Shutdown::SkipOnShutdown, || {}),
        Err(Refused)
    );
    // Shutdown waits for the started skip gates and for the block item queued behind them.
    assert!(!report.is_finished());
    drop(gates);
    let report = report.join().unwrap();
    assert_eq!(report, ShutdownReport { dropped: 1, unfinished: 0 });
    assert_eq!(blocked.wait(), Ok("block"));

    // After shutdown a block item is still taken and runs; a skip item is refused.
    let late =
        work.run(Priority::BestEffort, Lane::Files, Shutdown::BlockShutdown, || "late block");
    assert_eq!(late.wait(), Ok("late block"));
    let refused =
        work.run(Priority::UserBlocking, Lane::Files, Shutdown::SkipOnShutdown, || "late skip");
    assert_eq!(refused.wait(), Err(WorkError::Dropped));
}

#[test]
fn shutdown_waits_for_started_skip_items_and_not_for_continue_items() {
    let work = work("t-skip", 1, Duration::from_secs(30), 0);
    let skip =
        started_gates(&work, 1, Priority::UserBlocking, Lane::Files, Shutdown::SkipOnShutdown);
    let report = work.shutdown_until(Instant::now() + Duration::from_millis(20));
    assert_eq!(report, ShutdownReport { dropped: 0, unfinished: 1 });
    drop(skip);
    assert_eq!(work.shutdown(), ShutdownReport::default());

    let work = work_with_continue_gates();
    let begun = Instant::now();
    let report = work.shutdown_until(Instant::now() + WAIT);
    assert!(begun.elapsed() < WAIT / 2, "shutdown waited for a continue item");
    assert_eq!(report, ShutdownReport { dropped: 1, unfinished: 0 });
}

/// A Work whose Files lane is full of started continue items, with one more queued; the gates stay
/// closed for the rest of the test process.
fn work_with_continue_gates() -> Work {
    let work = work("t-continue", 1, Duration::from_secs(30), 0);
    let gates =
        started_gates(&work, 4, Priority::UserBlocking, Lane::Files, Shutdown::ContinueOnShutdown);
    std::mem::forget(gates);
    work.post(Priority::UserBlocking, Lane::Files, Shutdown::ContinueOnShutdown, || {}).unwrap();
    work
}

#[test]
fn shutdown_until_reports_block_items_past_the_deadline() {
    let work = work("t-deadline", 1, Duration::from_secs(30), 0);
    let (release, started) = gate(&work, Priority::BestEffort, Lane::Cpu, Shutdown::BlockShutdown);
    started.recv_timeout(WAIT).unwrap();
    let report = work.shutdown_until(Instant::now() + Duration::from_millis(20));
    assert_eq!(report, ShutdownReport { dropped: 0, unfinished: 1 });
    drop(release);
    assert_eq!(work.shutdown(), ShutdownReport::default());
}

#[test]
fn a_panicking_item_keeps_its_worker_and_reports_panicked() {
    let work = work("t-panic", 1, Duration::from_secs(30), 0);
    let panicked =
        work.run(Priority::UserVisible, Lane::Cpu, Shutdown::SkipOnShutdown, || -> u8 {
            panic!("boom")
        });
    assert_eq!(panicked.wait(), Err(WorkError::Panicked));
    work.post(Priority::UserVisible, Lane::Cpu, Shutdown::SkipOnShutdown, || panic!("boom"))
        .unwrap();
    // Run and post panics count the same.
    until("both panics to be counted", || lane_stats(&work, Lane::Cpu).panics == 2);
    assert_eq!(
        work.run(Priority::UserVisible, Lane::Cpu, Shutdown::SkipOnShutdown, || 7).wait(),
        Ok(7)
    );
    assert_eq!(lane_stats(&work, Lane::Cpu).panics, 2);
}

/// Fails the next `fails` worker starts; the launcher and every later worker start for real.
fn failing_spawner(fails: Arc<AtomicIsize>) -> Spawner {
    let real = Spawner::default();
    Spawner::new(move |name, qos, body| {
        let fail = !name.ends_with("-launch") && fails.fetch_sub(1, Ordering::SeqCst) > 0;
        if fail {
            return Err(io::Error::from(io::ErrorKind::WouldBlock));
        }
        real.spawn(name, qos, body)
    })
}

#[test]
fn an_item_whose_worker_cannot_start_is_dropped_when_nothing_runs() {
    let fails = Arc::new(AtomicIsize::new(1));
    let work = Work::new(WorkConfig {
        spawner: failing_spawner(Arc::clone(&fails)),
        ..config("t-nospawn", 1, Duration::from_secs(30), 0)
    })
    .unwrap();
    let item = work.run(Priority::UserBlocking, Lane::Files, Shutdown::SkipOnShutdown, || 1);
    assert_eq!(item.wait(), Err(WorkError::Dropped));
    let stats = lane_stats(&work, Lane::Files);
    assert_eq!((stats.spawn_failures, stats.running, stats.pending, stats.workers), (1, 0, 0, 0));

    // A dropped block item no longer holds shutdown.
    fails.store(1, Ordering::SeqCst);
    work.post(Priority::BestEffort, Lane::Files, Shutdown::BlockShutdown, || {}).unwrap();
    assert_eq!(work.shutdown_until(Instant::now() + WAIT), ShutdownReport::default());
    assert_eq!(
        work.run(Priority::BestEffort, Lane::Files, Shutdown::BlockShutdown, || 2).wait(),
        Ok(2)
    );
}

#[test]
fn an_item_whose_worker_cannot_start_runs_after_the_next_finished_item() {
    let fails = Arc::new(AtomicIsize::new(0));
    let work = Work::new(WorkConfig {
        spawner: failing_spawner(Arc::clone(&fails)),
        ..config("t-respawn", 1, Duration::from_secs(30), 0)
    })
    .unwrap();
    let gates =
        started_gates(&work, 1, Priority::UserBlocking, Lane::Files, Shutdown::SkipOnShutdown);
    fails.store(1, Ordering::SeqCst);
    let item = work.run(Priority::UserBlocking, Lane::Files, Shutdown::SkipOnShutdown, || 3);
    let stats = lane_stats(&work, Lane::Files);
    assert_eq!((stats.spawn_failures, stats.running, stats.pending), (1, 1, 1));
    assert_eq!(item.try_wait(), None);
    drop(gates);
    assert_eq!(item.wait(), Ok(3));
}

#[cfg(target_os = "linux")]
fn live_threads_named(prefix: &str) -> usize {
    std::fs::read_dir("/proc/self/task")
        .unwrap()
        .filter_map(|entry| std::fs::read_to_string(entry.ok()?.path().join("comm")).ok())
        .filter(|name| name.starts_with(prefix))
        .count()
}

#[test]
fn idle_workers_exit_and_leave_no_thread_and_no_wakeup() {
    let timeout = Duration::from_millis(40);
    let work = work("t-reap", 4, timeout, 0);
    let items: Vec<_> = Priority::ALL
        .into_iter()
        .flat_map(|priority| {
            Lane::ALL.map(|lane| work.run(priority, lane, Shutdown::SkipOnShutdown, || ()))
        })
        .collect();
    for item in items {
        item.wait().unwrap();
    }
    assert!(work.stats().iter().all(|lane| lane.workers_started > 0));
    until("every worker to exit", || work.stats().iter().all(|lane| lane.workers == 0));
    #[cfg(target_os = "linux")]
    {
        until("the worker threads to leave /proc", || {
            Lane::ALL
                .iter()
                .map(|lane| live_threads_named(&format!("t-reap-{lane}")))
                .sum::<usize>()
                == 0
        });
        // Only the launcher stays, waiting with no timeout.
        assert_eq!(live_threads_named("t-reap-launch"), 1);
    }
    let wakeups: Vec<_> = work.stats().map(|lane| lane.wakeups).into();
    std::thread::sleep(timeout * 5);
    assert_eq!(work.stats().map(|lane| lane.wakeups).to_vec(), wakeups);
    for lane in work.stats() {
        assert_eq!(lane.workers_started, lane.workers_exited, "{lane:?}");
    }
}

#[test]
fn the_last_waiter_above_keep_alive_waits_with_no_timeout() {
    let timeout = Duration::from_millis(30);
    let work = work("t-keep", 1, timeout, 1);
    let releases =
        started_gates(&work, 3, Priority::UserBlocking, Lane::Files, Shutdown::SkipOnShutdown);
    assert_eq!(lane_stats(&work, Lane::Files).workers, 3);
    drop(releases);
    until("the workers above keep_alive to exit", || lane_stats(&work, Lane::Files).workers == 1);
    let wakeups = lane_stats(&work, Lane::Files).wakeups;
    std::thread::sleep(timeout * 5);
    let stats = lane_stats(&work, Lane::Files);
    assert_eq!((stats.workers, stats.idle_workers, stats.wakeups), (1, 1, wakeups));
    // The kept worker still takes new work.
    assert_eq!(
        work.run(Priority::UserVisible, Lane::Files, Shutdown::SkipOnShutdown, || 1).wait(),
        Ok(1)
    );
    assert_eq!(lane_stats(&work, Lane::Files).workers, 1);
}

#[test]
fn dropping_work_runs_queued_items_then_lets_workers_exit() {
    let work = work("t-drop", 2, Duration::from_secs(30), 0);
    let gates = started_gates(&work, 2, Priority::UserVisible, Lane::Cpu, Shutdown::SkipOnShutdown);
    let queued = work.run(Priority::UserVisible, Lane::Cpu, Shutdown::SkipOnShutdown, || "queued");
    let lane = Arc::clone(&work.lanes[Lane::Cpu.index()]);
    drop(work);
    drop(gates);
    assert_eq!(queued.wait(), Ok("queued"));
    until("the released workers to exit", || lane.stats().workers == 0);
    drop(lane);
    #[cfg(target_os = "linux")]
    until("the launcher to exit", || live_threads_named("t-drop-launch") == 0);
}

#[cfg(target_os = "linux")]
fn current_nice() -> i32 {
    // SAFETY: gettid has no preconditions; getpriority reads the calling thread's nice value.
    unsafe { libc::getpriority(libc::PRIO_PROCESS, libc::gettid() as libc::id_t) }
}

/// The nice value a fresh thread of this process starts at. Below 10 the tests below show that a
/// worker started from a nicer thread still runs at it; run them at nice 0, not under `nice -n 10`.
#[cfg(target_os = "linux")]
fn base_nice() -> i32 {
    std::thread::spawn(current_nice).join().unwrap()
}

#[cfg(target_os = "linux")]
#[test]
fn user_blocking_runs_on_a_foreground_worker_after_idle_work() {
    let base = base_nice();
    let work = work("t-nice", 2, Duration::from_secs(30), 0);
    // Files: an Idle item, then three UserBlocking gates, fill the four slots.
    let (idle_release, hold) = channel::<()>();
    let (idle_tx, idle_nice) = channel();
    work.post(Priority::Idle, Lane::Files, Shutdown::SkipOnShutdown, move || {
        idle_tx.send(current_nice()).unwrap();
        let _ = hold.recv();
    })
    .unwrap();
    let idle_nice = idle_nice.recv_timeout(WAIT).unwrap();
    let gates =
        started_gates(&work, 3, Priority::UserBlocking, Lane::Files, Shutdown::SkipOnShutdown);
    let probe =
        work.run(Priority::UserBlocking, Lane::Files, Shutdown::SkipOnShutdown, current_nice);
    assert_eq!(probe.try_wait(), None);
    // The Idle worker finishes and admits the probe, whose worker it may not start itself.
    drop(idle_release);
    let fg_nice = probe.wait().unwrap();
    assert_eq!(idle_nice, base.max(10));
    assert_eq!(fg_nice, base, "UserBlocking ran at nice {fg_nice}, base {base}");
    drop(gates);
}

#[cfg(target_os = "linux")]
#[test]
fn a_background_caller_starts_user_blocking_work_at_base_nice() {
    let base = base_nice();
    let work = Arc::new(work("t-caller", 2, Duration::from_secs(30), 0));
    let caller = Arc::clone(&work);
    let (caller_nice, fg_nice) =
        crate::spawn::spawn("t-caller-bg", ThreadQos::Background, move || {
            let probe = caller.run(
                Priority::UserBlocking,
                Lane::Files,
                Shutdown::SkipOnShutdown,
                current_nice,
            );
            (current_nice(), probe.wait().unwrap())
        })
        .unwrap()
        .join()
        .unwrap();
    assert_eq!(caller_nice, base.max(10));
    assert_eq!(fg_nice, base, "UserBlocking ran at nice {fg_nice}, base {base}");
}

/// Items waiting inside `will_block` hold no slot: six of them on the System lane (its whole size)
/// leave room for a UserVisible item. Out of `will_block` they count again.
#[test]
fn will_block_items_do_not_hold_their_slots() {
    let work = work("t-willblock", 1, Duration::from_secs(30), 0);
    let (leave, left) = channel::<()>();
    let left = Arc::new(Mutex::new(left));
    let (out_tx, out) = channel::<()>();
    let mut gates = Vec::new();
    for _ in 0..6 {
        let (release, hold) = channel::<()>();
        let (started_tx, started) = channel();
        let (left, out_tx) = (Arc::clone(&left), out_tx.clone());
        work.post(Priority::UserBlocking, Lane::System, Shutdown::SkipOnShutdown, move || {
            will_block(|| {
                started_tx.send(()).unwrap();
                let _ = hold.recv();
            });
            out_tx.send(()).unwrap();
            let _ = left.lock().unwrap().recv();
        })
        .unwrap();
        started.recv_timeout(WAIT).unwrap();
        gates.push(release);
    }
    let stats = lane_stats(&work, Lane::System);
    assert_eq!((stats.running, stats.blocked), (6, 6));
    let visible =
        work.run(Priority::UserVisible, Lane::System, Shutdown::SkipOnShutdown, || "visible");
    assert_eq!(visible.wait(), Ok("visible"));
    drop(gates);
    for _ in 0..6 {
        out.recv_timeout(WAIT).unwrap();
    }
    let stats = lane_stats(&work, Lane::System);
    assert_eq!((stats.running, stats.blocked), (6, 0), "out of will_block they count again");
    let user_blocking =
        work.run(Priority::UserBlocking, Lane::System, Shutdown::SkipOnShutdown, || "blocking");
    assert_eq!(user_blocking.try_wait(), None, "the lane is full again");
    drop(leave);
    assert_eq!(user_blocking.wait(), Ok("blocking"));
}

/// Off a work item, and nested inside one, `will_block` only runs its body.
#[test]
fn will_block_off_a_worker_or_nested_counts_nothing() {
    assert_eq!(will_block(|| 7), 7);
    let work = work("t-willnest", 1, Duration::from_secs(30), 0);
    let nested = work
        .run(Priority::UserVisible, Lane::System, Shutdown::SkipOnShutdown, || {
            will_block(|| will_block(|| CURRENT_LANE.with(|lane| lane.borrow().is_none())))
        })
        .wait();
    assert_eq!(nested, Ok(true));
    assert_eq!(lane_stats(&work, Lane::System).blocked, 0);
}

/// The calling worker's thread name and whether it runs at UserInitiated (Linux: the process's base
/// nice value, which is nice 0 outside `nice -n`).
fn worker_and_class() -> (String, bool) {
    let name = std::thread::current().name().unwrap_or_default().to_owned();
    #[cfg(target_os = "linux")]
    let user_initiated = current_nice() == base_nice();
    #[cfg(target_vendor = "apple")]
    let user_initiated = crate::qos::current() == LiveQos::Class(ThreadQos::UserInitiated);
    #[cfg(not(any(target_os = "linux", target_vendor = "apple")))]
    let user_initiated = true;
    (name, user_initiated)
}

/// Task 118: once shutdown starts, an Idle block item queued behind the lane's Idle limit runs at
/// UserBlocking on a foreground worker, while the item that held the limit still runs.
#[test]
fn shutdown_runs_a_queued_idle_block_item_on_a_foreground_worker() {
    let work = Arc::new(work("t-sq", 2, Duration::from_secs(30), 0));
    // One running item fills Files for Idle (limit 1).
    let gates =
        started_gates(&work, 1, Priority::UserBlocking, Lane::Files, Shutdown::SkipOnShutdown);
    let block = work.run(Priority::Idle, Lane::Files, Shutdown::BlockShutdown, worker_and_class);
    assert_eq!(block.try_wait(), None);

    let shutting = Arc::clone(&work);
    let report = std::thread::spawn(move || shutting.shutdown());
    // Without the raise it would wait for the gate, which only the end of this test releases.
    let mut ran = None;
    until("the raised block item to run while the gate holds", || {
        ran = block.try_wait();
        ran.is_some()
    });
    let (worker, user_initiated) = ran.unwrap().unwrap();
    assert!(worker.ends_with("-files-fg"), "the block item ran on {worker}");
    assert!(user_initiated, "the block item ran below UserInitiated");
    // It ran while the gate still held the lane: shutdown waits for the started skip gate.
    assert!(!report.is_finished());
    drop(gates);
    assert_eq!(report.join().unwrap(), ShutdownReport::default());
    // It never ran on a lower worker, so no worker was raised.
    let stats = lane_stats(&work, Lane::Files);
    assert_eq!(stats.shutdown_raises + stats.shutdown_raise_refusals, 0);

    // A block item posted after shutdown runs on a foreground worker too.
    let late = work.run(Priority::Idle, Lane::Files, Shutdown::BlockShutdown, worker_and_class);
    let (worker, user_initiated) = late.wait().unwrap();
    assert!(worker.ends_with("-files-fg") && user_initiated, "the late block item ran on {worker}");
}

/// Task 118: a block item running on a BestEffort worker gets its worker raised exactly once; a
/// running skip item on the same lane is not raised.
#[test]
fn shutdown_raises_the_worker_of_a_running_best_effort_block_item_once() {
    let work = work("t-sr", 2, Duration::from_secs(30), 0);
    // Files: Idle takes the first slot (its limit), BestEffort the second.
    let skip = started_gates(&work, 1, Priority::Idle, Lane::Files, Shutdown::SkipOnShutdown);
    let block = started_gates(&work, 1, Priority::BestEffort, Lane::Files, Shutdown::BlockShutdown);
    let report = work.shutdown_until(Instant::now() + Duration::from_millis(20));
    assert_eq!(report, ShutdownReport { dropped: 0, unfinished: 2 });
    // A second shutdown raises nothing more.
    let _ = work.shutdown_until(Instant::now() + Duration::from_millis(1));
    let stats = lane_stats(&work, Lane::Files);
    assert_eq!(stats.shutdown_raises + stats.shutdown_raise_refusals, 1, "{stats:?}");
    // macOS always takes the override; Linux takes the raise only when nice 0 is allowed again.
    if cfg!(target_vendor = "apple") || crate::qos::reversible(ThreadQos::Background) {
        assert_eq!(stats.shutdown_raises, 1, "{stats:?}");
    }
    drop((skip, block));
    assert_eq!(work.shutdown(), ShutdownReport::default());
    let stats = lane_stats(&work, Lane::Files);
    assert_eq!(stats.shutdown_raises + stats.shutdown_raise_refusals, 1, "{stats:?}");
}

/// What a counting [`boost::Booster`] saw: the workers it raised and the classes the raises ended at.
#[derive(Default)]
struct BoostLog {
    raised: Vec<boost::Target>,
    ended: Vec<ThreadQos>,
}

fn counting_booster(log: &Arc<Mutex<BoostLog>>) -> boost::Booster {
    let log = Arc::clone(log);
    boost::Booster::new(move |target| {
        log.lock().unwrap().raised.push(target);
        let log = Arc::clone(&log);
        Some(Box::new(move |class| log.lock().unwrap().ended.push(class)))
    })
}

/// Task 118, on every platform and user: the raise starts on the block item's own worker while it
/// runs, and the worker ends it after the item with its own class's QoS (so the worker does not stay
/// at UserInitiated for later items).
#[test]
fn shutdown_raise_starts_on_the_item_worker_and_ends_after_it_at_the_worker_class() {
    let log = Arc::new(Mutex::new(BoostLog::default()));
    let work =
        Work::with_booster(config("t-sb", 2, Duration::from_secs(30), 0), counting_booster(&log))
            .unwrap();
    let (release, hold) = channel::<()>();
    let (worker_tx, worker) = channel();
    work.post(Priority::BestEffort, Lane::Files, Shutdown::BlockShutdown, move || {
        worker_tx.send(boost::Target::current()).unwrap();
        let _ = hold.recv();
    })
    .unwrap();
    let worker = worker.recv_timeout(WAIT).unwrap();
    let report = work.shutdown_until(Instant::now() + Duration::from_millis(20));
    assert_eq!(report, ShutdownReport { dropped: 0, unfinished: 1 });
    {
        let log = log.lock().unwrap();
        assert_eq!(log.raised, vec![worker], "the raise is not on the item's worker");
        assert!(log.ended.is_empty(), "the raise ended before the item");
    }
    let stats = lane_stats(&work, Lane::Files);
    assert_eq!((stats.shutdown_raises, stats.shutdown_raise_refusals), (1, 0), "{stats:?}");
    drop(release);
    // The worker ends the raise before the item stops holding shutdown.
    assert_eq!(work.shutdown(), ShutdownReport::default());
    let log = log.lock().unwrap();
    assert_eq!(log.ended, vec![WorkerClass::BestEffort.qos()]);
    assert_eq!(log.raised.len(), 1);
}

/// Task p02-threads-119: a checked receive in an item is one `lane-sync` site, recorded in record mode
/// and never a panic; a checked file read in it and a checked receive on a dedicated thread record
/// nothing.
#[test]
fn a_checked_receive_in_an_item_is_one_lane_sync_site() {
    crate::blocking::set_mode(crate::blocking::BlockingMode::Record);
    let work = work("t-ls", 2, Duration::from_secs(30), 0);
    let (recv_line, fs_line) = work
        .run(Priority::UserVisible, Lane::Files, Shutdown::SkipOnShutdown, || {
            assert!(crate::blocking::is_sync_primitives_disallowed());
            let (tx, rx) = channel();
            tx.send(()).unwrap();
            let recv_line = line!() + 1;
            crate::checked::sync::recv(&rx).unwrap();
            let fs_line = line!() + 1;
            crate::blocking::assert_blocking_allowed(crate::blocking::BlockingKind::Fs);
            (recv_line, fs_line)
        })
        .wait()
        .unwrap();
    let dedicated_line = std::thread::Builder::new()
        .name("t-ls-dedicated".into())
        .spawn(|| {
            let (tx, rx) = channel();
            tx.send(()).unwrap();
            let line = line!() + 1;
            crate::checked::sync::recv(&rx).unwrap();
            line
        })
        .unwrap()
        .join()
        .unwrap();
    let snapshot = crate::blocking::snapshot();
    let site = snapshot.site(file!(), recv_line).expect("the item's receive is a site");
    assert_eq!(site.count, 1);
    assert!(site.lane_sync);
    assert!(site.kinds.contains(crate::blocking::BlockingKind::Recv));
    assert!(snapshot.site(file!(), fs_line).is_none(), "an item may read a file");
    assert!(snapshot.site(file!(), dedicated_line).is_none(), "a dedicated thread may wait");
    assert!(!crate::blocking::is_sync_primitives_disallowed(), "only the item's scope");
    work.shutdown();
}
