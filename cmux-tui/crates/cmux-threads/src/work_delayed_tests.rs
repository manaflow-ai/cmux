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

#[test]
fn shutdown_drops_a_waiting_skip_item_and_runs_a_waiting_block_item() {
    let work = work("t-dshut", Spawner::default());
    let (results, ran) = channel();
    post_value(&work, Duration::from_secs(60), Shutdown::SkipOnShutdown, 1, &results).unwrap();
    post_value(&work, Duration::from_secs(60), Shutdown::BlockShutdown, 2, &results).unwrap();
    assert_eq!(work.delayed_pending(), 2);
    let report = work.shutdown();
    assert_eq!((report.dropped, report.unfinished), (1, 0));
    assert_eq!(collect(&ran, 1)[0].0, 2);
    assert_eq!(work.delayed_pending(), 0);
    // After shutdown a skip item is refused and a block item still runs.
    let refused =
        post_value(&work, Duration::from_millis(1), Shutdown::SkipOnShutdown, 3, &results);
    assert_eq!(refused, Err(Refused));
    post_value(&work, Duration::from_millis(1), Shutdown::BlockShutdown, 4, &results).unwrap();
    assert_eq!(collect(&ran, 1)[0].0, 4);
    drop(results);
    assert!(ran.recv_timeout(Duration::from_millis(50)).is_err(), "a dropped item ran");
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
