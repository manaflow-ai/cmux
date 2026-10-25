use super::*;
use std::sync::mpsc::{Receiver, Sender, channel};

const WAIT: Duration = Duration::from_secs(10);

fn work(label: &str, cpu_width: usize, idle_timeout: Duration, keep_alive: usize) -> Work {
    Work::new(WorkConfig { label: label.to_owned(), cpu_width, idle_timeout, keep_alive })
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
    let work = work("t-order", 1, Duration::from_secs(30), 0);
    let (release, started) =
        gate(&work, Priority::UserBlocking, Lane::Cpu, Shutdown::SkipOnShutdown);
    started.recv_timeout(WAIT).unwrap();
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
    drop(release);
    let seen: Vec<_> = (0..5).map(|_| order.recv_timeout(WAIT).unwrap()).collect();
    assert_eq!(seen, ["userBlocking-1", "userBlocking-2", "userVisible", "bestEffort", "idle"]);
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
    let gates: Vec<_> = (0..5)
        .map(|_| gate(&work, Priority::BestEffort, Lane::System, Shutdown::SkipOnShutdown))
        .collect();
    for (_, started) in &gates {
        started.recv_timeout(WAIT).unwrap();
    }
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
fn shutdown_runs_block_items_and_drops_skip_items() {
    let work = Arc::new(work("t-shutdown", 1, Duration::from_secs(30), 0));
    let (release, started) = gate(&work, Priority::BestEffort, Lane::Cpu, Shutdown::SkipOnShutdown);
    started.recv_timeout(WAIT).unwrap();
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
    // The block item waits behind the running gate, so shutdown is still waiting for it.
    assert!(!report.is_finished());
    drop(release);
    let report = report.join().unwrap();
    assert_eq!(report, ShutdownReport { dropped: 1, unfinished_block: 0 });
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
fn shutdown_until_reports_block_items_past_the_deadline() {
    let work = work("t-deadline", 1, Duration::from_secs(30), 0);
    let (release, started) = gate(&work, Priority::BestEffort, Lane::Cpu, Shutdown::BlockShutdown);
    started.recv_timeout(WAIT).unwrap();
    let report = work.shutdown_until(Instant::now() + Duration::from_millis(20));
    assert_eq!(report, ShutdownReport { dropped: 0, unfinished_block: 1 });
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
    until("the posted panic", || lane_stats(&work, Lane::Cpu).panics == 1);
    assert_eq!(
        work.run(Priority::UserVisible, Lane::Cpu, Shutdown::SkipOnShutdown, || 7).wait(),
        Ok(7)
    );
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
    until("the worker threads to leave /proc", || live_threads_named("t-reap-") == 0);
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
    let (releases, starts): (Vec<_>, Vec<_>) = (0..3)
        .map(|_| gate(&work, Priority::UserBlocking, Lane::Files, Shutdown::SkipOnShutdown))
        .unzip();
    for started in &starts {
        started.recv_timeout(WAIT).unwrap();
    }
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
    let work = work("t-drop", 1, Duration::from_secs(30), 0);
    let (release, started) =
        gate(&work, Priority::UserVisible, Lane::Cpu, Shutdown::SkipOnShutdown);
    started.recv_timeout(WAIT).unwrap();
    let queued = work.run(Priority::UserVisible, Lane::Cpu, Shutdown::SkipOnShutdown, || "queued");
    let lane = Arc::clone(&work.lanes[Lane::Cpu.index()]);
    drop(work);
    drop(release);
    assert_eq!(queued.wait(), Ok("queued"));
    until("the released workers to exit", || lane.stats().workers == 0);
}

#[cfg(target_os = "linux")]
fn current_nice() -> i32 {
    // SAFETY: gettid has no preconditions; getpriority reads the calling thread's nice value.
    unsafe { libc::getpriority(libc::PRIO_PROCESS, libc::gettid() as libc::id_t) }
}

#[cfg(target_os = "linux")]
#[test]
fn user_blocking_runs_on_a_foreground_worker_after_idle_work() {
    let work = work("t-nice", 1, Duration::from_secs(30), 0);
    let base = std::thread::spawn(current_nice).join().unwrap();
    let probe = || {
        // SAFETY: gettid has no preconditions.
        (unsafe { libc::gettid() }, current_nice())
    };
    let (idle_tid, idle_nice) =
        work.run(Priority::Idle, Lane::Files, Shutdown::SkipOnShutdown, probe).wait().unwrap();
    let (fg_tid, fg_nice) = work
        .run(Priority::UserBlocking, Lane::Files, Shutdown::SkipOnShutdown, probe)
        .wait()
        .unwrap();
    assert_ne!(fg_tid, idle_tid, "the idle worker must not run UserBlocking work");
    assert_eq!(fg_nice, base, "a UserBlocking worker runs at the process's base nice");
    if base == 0 {
        assert_eq!((idle_nice, fg_nice), (10, 0));
    }
}
