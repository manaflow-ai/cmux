//! On a tokio worker, write_important is one compensated blocking call: the
//! worker hands its queue to another thread for the length of the write
//! (`cmux_blocking::scoped_blocking_call`, Chrome's `ScopedBlockingCall`).
//! Its own test binary: the counters are per process.

use cmux_important_file::{Mode, write_important};

#[test]
fn a_write_on_a_multi_thread_worker_is_compensated() {
    let runtime = cmux_blocking::runtime::multi_thread().worker_threads(1).build().unwrap();
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("briefs.json");
    let before = cmux_blocking::counts();
    let task_path = path.clone();
    runtime
        .block_on(async move {
            tokio::spawn(async move { write_important(&task_path, b"{}", Mode::Default) }).await
        })
        .unwrap()
        .unwrap();
    let after = cmux_blocking::counts();
    assert_eq!(
        after.compensated + after.unconfirmed,
        before.compensated + before.unconfirmed + 1,
        "{before:?} -> {after:?}"
    );
    assert_eq!(std::fs::read(&path).unwrap(), b"{}");
}
