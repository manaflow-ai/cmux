//! `cmux link serve` watches its tokio workers (p09-observability task 118): a task that blocks
//! a link worker for 3 s gives one hang record in the state directory's `hangs-<pid>.jsonl`.
//!
//! The process watch starts once per process, so this is the only test in the binary that
//! starts it.

use std::thread;
use std::time::Duration;

use serde_json::Value;

use super::{RUNTIME_NAME, start_hang_watch, tokio_runtime};

#[cfg(target_vendor = "apple")]
fn native_thread_id() -> u64 {
    // SAFETY: pthread_self has no preconditions and its result is the calling thread's handle.
    u64::from(unsafe { libc::pthread_mach_thread_np(libc::pthread_self()) })
}

#[cfg(target_os = "linux")]
fn native_thread_id() -> u64 {
    // SAFETY: gettid has no arguments and no preconditions.
    u64::try_from(unsafe { libc::syscall(libc::SYS_gettid) }).unwrap()
}

#[test]
fn link_serve_records_a_worker_blocked_for_3s_in_its_state_dir() {
    let state = tempfile::tempdir().unwrap();
    start_hang_watch(state.path());
    let runtime = tokio_runtime().unwrap();
    // A worker's run before its first park is not watched: let the idle workers park first.
    thread::sleep(Duration::from_millis(300));
    let worker = runtime
        .block_on(runtime.spawn(async {
            thread::sleep(Duration::from_secs(3));
            native_thread_id()
        }))
        .unwrap();
    drop(runtime);

    let path = state.path().join(cmux_hang_watch::file_name(std::process::id()));
    let log = std::fs::read_to_string(&path).unwrap_or_default();
    let prefix = format!("{RUNTIME_NAME}-");
    let hangs: Vec<Value> = log
        .lines()
        .map(|line| serde_json::from_str::<Value>(line).unwrap())
        .filter(|hang| hang["native_thread_id"] == worker)
        .collect();
    assert_eq!(hangs.len(), 1, "{log}");
    assert!(hangs[0]["thread"].as_str().unwrap().starts_with(&prefix), "{log}");
    assert_eq!(hangs[0]["deadline_ms"], 2_000);
}
