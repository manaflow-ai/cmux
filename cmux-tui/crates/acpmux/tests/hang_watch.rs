//! The daemon's hang-watch registrations: a sync thread registers once and
//! is blamed for an item past its deadline, never for its wait; a blocking-pool item is watched
//! under its own registration on a thread nobody registered, and under the thread's own on one
//! that is registered. A wait for a child process inside an item is the child's, never a hang.
//!
//! The process watch is per process, so this file holds one test.

// Unix only until the Windows port runs the daemon.
#![cfg(unix)]

#[path = "support/daemon_env.rs"]
mod daemon_env;
// No daemon and no agent: the test drives the hang-watch helpers only.
const HERMETIC: daemon_env::Process = daemon_env::Process::deny();

use std::io;
use std::sync::mpsc::{Receiver, Sender, channel};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use acpmux::daemon::hang_watch::{BLOCKING_THREAD, SyncThread, blocking_item, spawn_blocking};
use cmux_hang_watch::{Config, Hang, HangSink, ThreadKind, TraceClock};

const DEADLINE: Duration = Duration::from_millis(100);
const SLOW: Duration = Duration::from_millis(400);

struct Recorded(Mutex<Sender<Hang>>);

impl HangSink for Recorded {
    fn record(&self, hang: &Hang) -> io::Result<()> {
        let _ = self.0.lock().unwrap().send(hang.clone());
        Ok(())
    }
}

/// A proxy launcher that answers `--version` after [`SLOW`].
fn slow_launcher() -> String {
    use std::os::unix::fs::PermissionsExt;
    let dir = std::env::temp_dir().join(format!("acpmux-hang-launcher-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let path = dir.join("sr-slow");
    let script = format!("#!/bin/sh\nsleep {}\necho 'sr 1.0'\n", SLOW.as_secs_f64());
    std::fs::write(&path, script).unwrap();
    std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o755)).unwrap();
    path.to_string_lossy().into_owned()
}

fn registered() -> u64 {
    cmux_hang_watch::stats().expect("the process watch runs").registered
}

fn next_hang(hangs: &Receiver<Hang>) -> Hang {
    hangs.recv_timeout(Duration::from_secs(10)).expect("the slow item is reported")
}

fn none_left(hangs: &Receiver<Hang>, what: &str) {
    let left: Vec<Hang> = hangs.try_iter().collect();
    assert!(left.is_empty(), "{what}: {left:?}");
}

#[test]
fn hang_watch_sync_threads_and_blocking_items_blame_slow_items_only() {
    let (sender, hangs) = channel();
    // A short period and a wide drift tolerance: a loaded machine's late pass must not skip an item.
    let config =
        Config { min_deadline: Duration::from_millis(20), drift_tolerance: Duration::from_secs(5) };
    cmux_hang_watch::init_process(
        config,
        Arc::new(TraceClock),
        Box::new(Recorded(Mutex::new(sender))),
    )
    .expect("the process watch starts");

    // A sync thread: registered while it lives, blamed for a slow item, never for its wait, and
    // a blocking item it runs itself uses its own registration.
    let (ready, waiting) = channel();
    let (go, gate) = channel::<()>();
    let worker = std::thread::spawn(move || {
        let watched = SyncThread::register("acpmux-test-sync", DEADLINE);
        assert!(watched.is_registered());
        ready.send(()).unwrap();
        // The wait for the next item, past the deadline: no scope is open.
        gate.recv().unwrap();
        {
            let _item = watched.item();
            std::thread::sleep(SLOW);
        }
        ready.send(()).unwrap();
        gate.recv().unwrap();
        blocking_item(DEADLINE, || std::thread::sleep(SLOW));
    });
    waiting.recv().unwrap();
    assert_eq!(registered(), 1);
    std::thread::sleep(SLOW);
    none_left(&hangs, "a sync thread was blamed for its wait");
    go.send(()).unwrap();
    let hang = next_hang(&hangs);
    assert_eq!((hang.thread.as_str(), hang.kind), ("acpmux-test-sync", ThreadKind::Lane));
    assert_eq!(hang.deadline_ms, DEADLINE.as_millis() as u64);
    waiting.recv().unwrap();
    go.send(()).unwrap();
    let hang = next_hang(&hangs);
    assert_eq!(hang.thread, "acpmux-test-sync", "a registered thread registered again");
    worker.join().unwrap();
    assert_eq!(registered(), 0, "the sync thread's slot outlived it");
    none_left(&hangs, "an item was reported twice");

    // A blocking item that waits past its deadline for a child process: a proxy launcher whose
    // `--version` is slow (`verify_launchers`).
    let launcher = slow_launcher();
    std::thread::spawn(move || {
        blocking_item(DEADLINE, || {
            let mut cfg: acpmux::config::Config =
                serde_json::from_value(serde_json::json!({"harnesses": {
                    "claude-sr": {"argv": [launcher, "claude", "proxy"], "kind": "claude-stdio"},
                }}))
                .unwrap();
            acpmux::config::verify_launchers_with(&mut cfg, None);
            assert!(!cfg.unavailable.contains_key("claude-sr"), "{:?}", cfg.unavailable);
        });
    })
    .join()
    .unwrap();
    std::thread::sleep(SLOW);
    none_left(&hangs, "a blocking item was blamed for its child process's wait");

    // Blocking-pool items: watched under their own registration, freed with the item.
    let runtime = tokio::runtime::Builder::new_multi_thread().worker_threads(1).build().unwrap();
    runtime.block_on(async {
        assert_eq!(spawn_blocking(|| 7).await.unwrap(), 7);
        assert_eq!(registered(), 0, "a quick item's registration outlived it");
        tokio::task::spawn_blocking(|| blocking_item(DEADLINE, || std::thread::sleep(SLOW)))
            .await
            .unwrap();
    });
    let hang = next_hang(&hangs);
    assert_eq!((hang.thread.as_str(), hang.kind), (BLOCKING_THREAD, ThreadKind::Pool));
    assert_eq!(registered(), 0, "a slow item's registration outlived it");
    none_left(&hangs, "a blocking item was reported twice");
}
