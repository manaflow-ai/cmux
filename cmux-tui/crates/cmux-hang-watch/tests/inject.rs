//! Hang injection through a hang-watch scope (p09-observability-088): an
//! armed lane blocks at its next scope on its own thread, and the watcher
//! reports exactly one hang on that slot, and the registration is published
//! for hang-matrix.py, with the process's hang file. The page is the user's,
//! shared with every other debug process and test binary, so each check reads
//! only this process's entries. Debug builds on Unix only, as the injector's page.
#![cfg(all(debug_assertions, unix))]

use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use cmux_hang_watch::{Config, Hang, HangSink, HangWatch, ThreadKind, TraceClock};
use cmux_threads::hang_inject;

#[derive(Clone, Default)]
struct Collect(Arc<Mutex<Vec<Hang>>>);

impl HangSink for Collect {
    fn record(&self, hang: &Hang) -> std::io::Result<()> {
        self.0.lock().unwrap().push(hang.clone());
        Ok(())
    }
}

#[test]
fn an_armed_lane_hangs_once_at_its_next_scope_and_is_reported_on_its_slot() {
    let sink = Collect::default();
    let config = Config { min_deadline: Duration::from_millis(50), ..Config::default() };
    let watch = HangWatch::spawn(config, Arc::new(TraceClock), Box::new(sink.clone())).unwrap();
    let guard = watch.register_thread(ThreadKind::Lane, "inject-lane");
    let page = hang_inject::page().expect("the process page maps in /tmp");
    let mine = hang_inject::Registered { lane: "inject-lane".into(), pid: std::process::id() };
    assert!(page.registrations().contains(&mine), "the registration is published");
    page.arm("inject-lane", std::process::id(), Duration::from_millis(600)).unwrap();

    let started = Instant::now();
    drop(guard.watch(Duration::from_millis(200)));
    assert!(started.elapsed() >= Duration::from_millis(600), "{:?}", started.elapsed());
    let started = Instant::now();
    drop(guard.watch(Duration::from_millis(200)));
    assert!(started.elapsed() < Duration::from_millis(200), "the arm was taken once");
    let mine_armed = page
        .entries()
        .into_iter()
        .filter(|entry| entry.pid == std::process::id() && entry.lane == "inject-lane")
        .collect::<Vec<_>>();
    assert!(mine_armed.iter().all(|entry| entry.taken), "{mine_armed:?}");

    let hangs = sink.0.lock().unwrap().clone();
    assert_eq!(hangs.len(), 1, "{hangs:?}");
    assert_eq!(hangs[0].thread, "inject-lane");
    assert_eq!(hangs[0].kind, ThreadKind::Lane);
    assert_eq!(hangs[0].deadline_ms, 200);
}

#[test]
fn init_publishes_where_the_process_writes_its_hang_records() {
    let dir = std::env::temp_dir().join(format!("cmux-hang-watch-inject-{}", std::process::id()));
    cmux_hang_watch::init(&dir).unwrap();
    let page = hang_inject::page().expect("the process page maps in /tmp");
    let mine: Vec<_> =
        page.hang_files().into_iter().filter(|file| file.pid == std::process::id()).collect();
    assert_eq!(
        mine,
        [hang_inject::PublishedHangFile {
            pid: std::process::id(),
            path: dir.join(cmux_hang_watch::file_name(std::process::id())),
        }]
    );
}
