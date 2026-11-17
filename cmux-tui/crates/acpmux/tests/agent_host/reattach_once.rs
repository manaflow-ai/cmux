//! A reattach never logs an entry that the reader of the closed link still logs.
//!
//! The link's socket reader moves the host's entries into a queue that the agent's reader logs
//! one by one. When the link closes (another owner took the host over, a broken socket), the
//! agent counts as not alive at once, but its reader may still hold entries it has not logged.
//! A reattach then resumes after the last entry logged so far, and the host replays the entries
//! that reader still holds: both readers logged them, and the chat had the same hostSeq twice.

use super::*;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_reattach_never_logs_an_entry_the_old_reader_still_logs() {
    const LINES: u64 = 40;
    let dir = scratch("reattach-once");
    let mut launch = spec(&dir, "s-reattach-once");
    launch.program = "/bin/sh".into();
    launch.args = vec![
        "-c".into(),
        format!(
            "i=0; while [ $i -lt {LINES} ]; do echo \"line $i\" >&2; i=$((i+1)); done; exec sleep 60"
        ),
    ];
    let record = link::spawn(&launcher(), &launch).await.expect("spawn host");
    let lock = live_lock(&dir, &record);
    // The host has every line before any controller reads one.
    tokio::time::sleep(Duration::from_millis(500)).await;

    // The log: each hostSeq the agent logged. Its first entry is held until `release`, as a busy
    // store holds a write, so the link's queue still has the rest when the link closes.
    let logged = Arc::new(Mutex::new(Vec::<u64>::new()));
    let held = Arc::new(AtomicBool::new(false));
    let release = Arc::new(AtomicBool::new(false));
    let tap: acpmux::agent::Tap = {
        let (logged, held, release) = (logged.clone(), held.clone(), release.clone());
        Arc::new(move |_, _, h| {
            if let Some(h) = h {
                if !held.swap(true, Ordering::SeqCst) {
                    // Off the runtime's workers, so the rest of the test runs meanwhile.
                    tokio::task::block_in_place(|| {
                        let until = std::time::Instant::now() + Duration::from_secs(20);
                        while !release.load(Ordering::SeqCst) && std::time::Instant::now() < until {
                            std::thread::sleep(Duration::from_millis(5));
                        }
                    });
                }
                logged.lock().unwrap().push(h);
            }
            true
        })
    };
    let (inbound, _) = tokio::sync::mpsc::channel(64);
    let attached = acpmux::agent::ChildAgent::attach_hosted(
        "fake",
        record.clone(),
        0,
        Vec::new(),
        inbound,
        tap,
    )
    .await
    .unwrap();
    let acpmux::agent::Attached::Ready(agent, ..) = attached else {
        panic!("the host refused its controller")
    };
    let until = std::time::Instant::now() + Duration::from_secs(10);
    while !held.load(Ordering::SeqCst) {
        assert!(std::time::Instant::now() < until, "the first entry never reached the log");
        tokio::time::sleep(Duration::from_millis(10)).await;
    }
    // Every entry is in the link's queue.
    tokio::time::sleep(Duration::from_millis(500)).await;

    // Another owner takes the host over and leaves without acknowledging anything: this
    // agent's link closes, and the host still keeps every entry for the next owner.
    let (taken, _) = connected(&record, 0).await;
    drop(taken);
    let until = std::time::Instant::now() + Duration::from_secs(10);
    while agent.is_alive().await {
        assert!(std::time::Instant::now() < until, "the agent's link never closed");
        tokio::time::sleep(Duration::from_millis(10)).await;
    }
    agent.reattach().await.expect("reattach");
    release.store(true, Ordering::SeqCst);

    let until = std::time::Instant::now() + Duration::from_secs(20);
    while (logged.lock().unwrap().iter().max().copied().unwrap_or(0)) < LINES {
        assert!(std::time::Instant::now() < until, "not every entry was logged: {logged:?}");
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    // Room for a late copy from either reader.
    tokio::time::sleep(Duration::from_millis(500)).await;
    let logged = logged.lock().unwrap().clone();
    // SAFETY: the host this test spawned; its live lock is held, so the pid is its own.
    unsafe { libc::kill(record.host_pid as i32, libc::SIGKILL) };
    wait_dead(lock).await;
    let _ = std::fs::remove_dir_all(&dir);
    let mut once = logged.clone();
    once.sort_unstable();
    once.dedup();
    assert_eq!(logged, once, "an entry was logged twice, or out of order");
    assert_eq!(once, (1..=LINES).collect::<Vec<_>>(), "an entry was not logged");
}
