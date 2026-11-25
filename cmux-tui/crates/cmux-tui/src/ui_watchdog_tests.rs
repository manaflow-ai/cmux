use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use super::*;

#[derive(Default)]
struct Recorded {
    hangs: Mutex<Vec<HangReport>>,
    restarts: Mutex<Vec<HangReport>>,
}

struct TestSink(Arc<Recorded>);

impl Sink for TestSink {
    fn hang(&self, report: &HangReport) {
        self.0.hangs.lock().unwrap().push(report.clone());
    }

    fn restart(&self, report: &HangReport) {
        self.0.restarts.lock().unwrap().push(report.clone());
    }
}

fn config(threshold_ms: u64, hang_ms: u64, restart_ms: Option<u64>) -> Config {
    Config {
        threshold: Duration::from_millis(threshold_ms),
        hang: Duration::from_millis(hang_ms),
        restart: restart_ms.map(Duration::from_millis),
        dir: None,
        session: "test".into(),
    }
}

fn start(config: Config) -> (LoopWatchdog, Arc<Recorded>) {
    let recorded = Arc::new(Recorded::default());
    let watchdog = LoopWatchdog::start(config, Box::new(TestSink(recorded.clone()))).unwrap();
    (watchdog, recorded)
}

#[inline(never)]
fn deliberate_stall(length: Duration) {
    let until = Instant::now() + length;
    while Instant::now() < until {
        std::hint::black_box(std::thread::sleep(Duration::from_millis(5)));
    }
}

#[test]
fn a_deliberate_stall_is_recorded_with_a_stack() {
    let (watchdog, recorded) = start(config(50, 200, None));
    let shared = watchdog.shared().clone();
    shared.turn_begin();
    deliberate_stall(Duration::from_millis(700));
    shared.turn_end();
    drop(watchdog);
    let hangs = recorded.hangs.lock().unwrap();
    assert_eq!(hangs.len(), 1, "one report per stalled turn");
    let hang = &hangs[0];
    assert!(hang.duration >= Duration::from_millis(200), "{:?}", hang.duration);
    #[cfg(unix)]
    {
        let frames = hang.frames();
        assert!(!frames.is_empty(), "the UI thread's stack was sampled");
        assert!(
            frames.iter().any(|frame| frame.contains("deliberate_stall")),
            "the sample holds the stalled function: {frames:#?}"
        );
    }
    let (stalls, longest) = shared.stall_stats();
    assert_eq!(stalls, 1);
    assert!(longest >= Duration::from_millis(700));
    assert!(recorded.restarts.lock().unwrap().is_empty());
}

#[test]
fn a_known_wait_past_its_bound_is_cancelled() {
    let (watchdog, recorded) = start(config(50, 2_000, None));
    let shared = watchdog.shared().clone();
    let (cancel_tx, cancel_rx) = crossbeam_channel::bounded::<()>(1);
    let started = Instant::now();
    shared.turn_begin();
    let id = shared.waits.register(
        "daemon request tree",
        Duration::from_millis(150),
        Box::new(move || {
            let _ = cancel_tx.send(());
        }),
    );
    // The UI thread's own wait would last 10 s; the watchdog ends it past its 150 ms bound.
    let ended = cancel_rx.recv_timeout(Duration::from_secs(10));
    shared.waits.unregister(id);
    shared.turn_end();
    let waited = started.elapsed();
    drop(watchdog);
    assert!(ended.is_ok(), "the wait was cancelled");
    assert!(waited >= Duration::from_millis(150), "not before its bound: {waited:?}");
    assert!(waited < Duration::from_secs(2), "soon after its bound: {waited:?}");
    // It ended before the hang threshold: no hang is reported.
    assert!(recorded.hangs.lock().unwrap().is_empty());
}

#[test]
fn a_wait_within_its_bound_is_left_alone() {
    let (watchdog, _recorded) = start(config(30, 2_000, None));
    let shared = watchdog.shared().clone();
    let cancelled = Arc::new(std::sync::atomic::AtomicBool::new(false));
    let flag = cancelled.clone();
    shared.turn_begin();
    let id = shared.waits.register(
        "daemon request tree",
        Duration::from_secs(5),
        Box::new(move || flag.store(true, std::sync::atomic::Ordering::SeqCst)),
    );
    deliberate_stall(Duration::from_millis(200));
    shared.waits.unregister(id);
    shared.turn_end();
    drop(watchdog);
    assert!(!cancelled.load(std::sync::atomic::Ordering::SeqCst));
}

#[test]
fn a_hang_past_the_restart_bound_restarts_once() {
    let (watchdog, recorded) = start(config(40, 100, Some(300)));
    let shared = watchdog.shared().clone();
    shared.turn_begin();
    deliberate_stall(Duration::from_millis(600));
    shared.turn_end();
    drop(watchdog);
    let restarts = recorded.restarts.lock().unwrap();
    assert_eq!(restarts.len(), 1);
    assert!(restarts[0].duration >= Duration::from_millis(300));
}

/// The kernel timer is armed and disarmed by the UI thread without waking the watchdog, so
/// short turns and an idle loop cost it nothing (the condvar stand-in elsewhere wakes per turn).
#[cfg(any(target_os = "linux", target_os = "macos"))]
#[test]
fn an_idle_loop_costs_the_watchdog_no_wakeups() {
    let (watchdog, recorded) = start(config(200, 2_000, None));
    let shared = watchdog.shared().clone();
    // Let the thread reach its first wait.
    std::thread::sleep(Duration::from_millis(50));
    let before = shared.watchdog_wakes();
    for _ in 0..500 {
        shared.turn_begin();
        std::hint::black_box(());
        shared.turn_end();
    }
    // Idle: no turn at all.
    std::thread::sleep(Duration::from_millis(600));
    let after = shared.watchdog_wakes();
    drop(watchdog);
    assert_eq!(after - before, 0, "short turns and idle time woke the watchdog");
    assert!(recorded.hangs.lock().unwrap().is_empty());
}

#[test]
fn a_hang_is_written_to_a_hang_file_and_the_telemetry_log() {
    let dir = tempfile::tempdir().unwrap();
    let mut config = config(50, 200, None);
    config.dir = Some(dir.path().to_path_buf());
    let report = HangReport {
        session: "test".into(),
        duration: Duration::from_millis(2_500),
        stack: Vec::new(),
        waits: vec!["daemon request tree (waited 2.5s of 5.0s)".into()],
        cancelled: Vec::new(),
    };
    for _ in 0..25 {
        assert!(record::write(&config, &report).is_some());
    }
    let hangs: Vec<_> = std::fs::read_dir(dir.path().join("hangs")).unwrap().flatten().collect();
    assert!(hangs.len() <= 20, "old hang files are pruned: {}", hangs.len());
    let text = std::fs::read_to_string(hangs[0].path()).unwrap();
    assert!(text.contains("stalled: 2.50s"), "{text}");
    assert!(text.contains("daemon request tree"), "{text}");
    let log = std::fs::read_to_string(record::hang_log(dir.path())).unwrap();
    let line: serde_json::Value = serde_json::from_str(log.lines().next().unwrap()).unwrap();
    assert_eq!(line["kind"], "client-hang");
    assert_eq!(line["duration_ms"], 2500);
    assert_eq!(log.lines().count(), 25);
}

#[test]
fn restarts_stop_after_three_in_ten_minutes() {
    let now = 100_000_000;
    assert_eq!(restart::next_restarts(None, now), Some((1, now)));
    // 100 s ago: inside the 10-minute window, so the count goes on.
    assert_eq!(restart::next_restarts(Some("1:99900000"), now), Some((2, 99_900_000)));
    assert_eq!(restart::next_restarts(Some("3:99900000"), now), None);
    // Past the window the count starts over.
    assert_eq!(restart::next_restarts(Some("3:1000"), now), Some((1, now)));
    assert_eq!(restart::next_restarts(Some("garbage"), now), Some((1, now)));
}
