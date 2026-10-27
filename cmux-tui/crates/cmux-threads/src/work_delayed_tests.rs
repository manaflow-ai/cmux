use std::sync::mpsc::{Receiver, Sender, channel};
use std::time::{Duration, Instant};

use super::super::{Lane, Priority, Refused, Shutdown, Spawner, Work, WorkConfig};

const WAIT: Duration = Duration::from_secs(10);

fn work(label: &str, spawner: Spawner) -> Work {
    Work::new(WorkConfig { label: label.to_owned(), spawner, ..WorkConfig::default() }).unwrap()
}

/// Posts `value` after `delay`; it arrives on `results` with the instant it ran.
fn post_value(
    work: &Work,
    delay: Duration,
    shutdown: Shutdown,
    value: u32,
    results: &Sender<(u32, Instant)>,
) -> Result<(), Refused> {
    let results = results.clone();
    work.post_delayed(delay, Priority::UserVisible, Lane::Cpu, shutdown, move || {
        let _ = results.send((value, Instant::now()));
    })
}

fn collect(results: &Receiver<(u32, Instant)>, count: usize) -> Vec<(u32, Instant)> {
    (0..count).map(|_| results.recv_timeout(WAIT).expect("a delayed item ran")).collect()
}

#[test]
fn delayed_items_run_after_their_delay_in_due_order() {
    let work = work("t-delay", Spawner::default());
    let (results, ran) = channel();
    let posted = Instant::now();
    post_value(&work, Duration::from_millis(120), Shutdown::SkipOnShutdown, 3, &results).unwrap();
    post_value(&work, Duration::from_millis(40), Shutdown::SkipOnShutdown, 1, &results).unwrap();
    post_value(&work, Duration::from_millis(80), Shutdown::SkipOnShutdown, 2, &results).unwrap();
    post_value(&work, Duration::ZERO, Shutdown::SkipOnShutdown, 0, &results).unwrap();
    let ran = collect(&ran, 4);
    assert_eq!(ran.iter().map(|(value, _)| *value).collect::<Vec<_>>(), [0, 1, 2, 3]);
    for (value, at) in &ran[1..] {
        assert!(*at - posted >= Duration::from_millis(40) * *value, "item {value} ran early");
    }
    assert_eq!(work.delayed_pending(), 0);
}

/// A delayed block item is a skip item: shutdown drops it and does not wait for it, so it can never
/// run after shutdown has said every block item finished. After shutdown a delayed post is refused,
/// block or not; a zero delay is a plain post, and a block item then still runs.
#[test]
fn shutdown_drops_every_waiting_delayed_item_block_items_too() {
    let work = work("t-dshut", Spawner::default());
    let (results, ran) = channel();
    post_value(&work, Duration::from_secs(60), Shutdown::SkipOnShutdown, 1, &results).unwrap();
    post_value(&work, Duration::from_secs(60), Shutdown::BlockShutdown, 2, &results).unwrap();
    assert_eq!(work.delayed_pending(), 2);
    let report = work.shutdown();
    assert_eq!((report.dropped, report.unfinished), (2, 0));
    assert_eq!(work.delayed_pending(), 0);
    for shutdown in [Shutdown::SkipOnShutdown, Shutdown::BlockShutdown] {
        let refused = post_value(&work, Duration::from_millis(1), shutdown, 3, &results);
        assert_eq!(refused, Err(Refused), "{shutdown:?} posted with a delay after shutdown");
    }
    post_value(&work, Duration::ZERO, Shutdown::BlockShutdown, 4, &results).unwrap();
    assert_eq!(collect(&ran, 1)[0].0, 4);
    drop(results);
    assert!(ran.recv_timeout(Duration::from_millis(50)).is_err(), "a dropped item ran");
}

/// A block item that falls due as shutdown starts either ran before shutdown returned or never
/// runs: no delayed item is out of both the delay queue and its lane's count while shutdown waits.
#[test]
fn a_delayed_block_item_due_at_shutdown_never_runs_after_it() {
    for round in 0..50 {
        let work = work("t-ddue", Spawner::default());
        let (results, ran) = channel();
        post_value(&work, Duration::from_micros(50), Shutdown::BlockShutdown, round, &results)
            .unwrap();
        let report = work.shutdown();
        assert_eq!(report.unfinished, 0);
        let ran_before = ran.try_recv().is_ok();
        drop(results);
        if !ran_before {
            assert!(
                ran.recv_timeout(Duration::from_millis(20)).is_err(),
                "round {round}: a delayed item ran after shutdown returned"
            );
        }
    }
}

#[test]
fn a_delay_thread_that_cannot_start_runs_the_item_at_once() {
    let spawner = Spawner::new(|name, qos, body| {
        if name.ends_with("-delay") {
            return Err(std::io::Error::other("refused in test"));
        }
        crate::spawn::spawn(name, qos, body).map(drop)
    });
    let work = work("t-dfail", spawner);
    let (results, ran) = channel();
    post_value(&work, Duration::from_secs(60), Shutdown::SkipOnShutdown, 7, &results).unwrap();
    assert_eq!(collect(&ran, 1)[0].0, 7);
    assert_eq!(work.delayed_pending(), 0);
}

#[cfg(target_os = "linux")]
fn nice_of_thread_named(name: &str) -> Option<i32> {
    std::fs::read_dir("/proc/self/task").unwrap().find_map(|entry| {
        let path = entry.ok()?.path();
        let comm = std::fs::read_to_string(path.join("comm")).ok()?;
        if comm.trim_end() != name {
            return None;
        }
        let stat = std::fs::read_to_string(path.join("stat")).ok()?;
        // The fields after `(comm)` start at field 3 (state); nice is field 19.
        stat.rsplit_once(')')?.1.split_whitespace().nth(16)?.parse().ok()
    })
}

/// A background-nice thread that makes the first delayed post does not start the delay thread at its
/// own nice value: the launcher starts it at the `Work`'s, so a UserBlocking deadline never waits for
/// a background thread to wake up. Run at nice 0, not under `nice -n 10` (see `work_tests.rs`).
#[cfg(target_os = "linux")]
#[test]
fn a_background_caller_starts_the_delay_thread_at_base_nice() {
    let base = std::thread::spawn(|| {
        // SAFETY: gettid has no preconditions; getpriority reads the calling thread's nice value.
        unsafe { libc::getpriority(libc::PRIO_PROCESS, libc::gettid() as libc::id_t) }
    })
    .join()
    .unwrap();
    let work = std::sync::Arc::new(work("t-dnice", Spawner::default()));
    let caller = std::sync::Arc::clone(&work);
    let (results, ran) = channel();
    crate::spawn::spawn("t-dnice-bg", crate::qos::ThreadQos::Background, move || {
        post_value(&caller, Duration::from_millis(1), Shutdown::SkipOnShutdown, 1, &results)
            .unwrap();
    })
    .unwrap()
    .join()
    .unwrap();
    collect(&ran, 1);
    assert_eq!(nice_of_thread_named("t-dnice-delay"), Some(base), "the delay thread's nice");
}

#[cfg(target_os = "linux")]
fn live_threads_named(name: &str) -> usize {
    std::fs::read_dir("/proc/self/task")
        .unwrap()
        .filter_map(|entry| std::fs::read_to_string(entry.ok()?.path().join("comm")).ok())
        .filter(|comm| comm.trim_end() == name)
        .count()
}

#[cfg(target_os = "linux")]
#[test]
fn the_delay_thread_starts_with_the_first_delayed_item_and_ends_with_the_work() {
    let work = work("t-dlife", Spawner::default());
    assert_eq!(live_threads_named("t-dlife-delay"), 0);
    let (results, ran) = channel();
    post_value(&work, Duration::from_millis(1), Shutdown::SkipOnShutdown, 1, &results).unwrap();
    collect(&ran, 1);
    assert_eq!(live_threads_named("t-dlife-delay"), 1);
    post_value(&work, Duration::from_secs(60), Shutdown::SkipOnShutdown, 2, &results).unwrap();
    drop(work);
    let deadline = Instant::now() + WAIT;
    while live_threads_named("t-dlife-delay") != 0 {
        assert!(Instant::now() < deadline, "the delay thread did not exit");
        std::thread::yield_now();
    }
    drop(results);
    assert!(ran.recv_timeout(Duration::from_millis(50)).is_err(), "a dropped item ran");
}
