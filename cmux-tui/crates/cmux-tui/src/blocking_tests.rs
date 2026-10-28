//! `off_worker`: blocking work leaves the tokio worker and keeps its result.

use std::io;

use super::off_worker;

#[tokio::test(flavor = "multi_thread", worker_threads = 1)]
async fn off_worker_runs_the_work_as_may_block_work() {
    let before = cmux_blocking::counts();
    let present = off_worker(|| cmux_blocking::fs::exists(std::env::temp_dir())).await.unwrap();
    let after = cmux_blocking::counts();
    assert!(present);
    assert!(after.allowed > before.allowed, "the wrapped call ran as may-block work");
}

#[tokio::test]
async fn off_worker_returns_the_work_error() {
    let missing = std::env::temp_dir().join("cmux-tui-off-worker-missing").join("file");
    let error = off_worker(move || cmux_blocking::fs::read(&missing)).await.unwrap_err();
    assert_eq!(error.kind(), io::ErrorKind::NotFound);
}

#[tokio::test]
#[should_panic(expected = "the work panicked")]
async fn off_worker_resumes_a_panic_of_the_work() {
    let _: Result<(), io::Error> = off_worker(|| panic!("the work panicked")).await;
}
