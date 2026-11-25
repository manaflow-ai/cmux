//! A host whose last entries its owner acknowledged but kept nowhere with a `hostSeq` (a stderr
//! line, a raw stream event, a repeated state update: `hub/tap.rs` counts them logged): the next
//! owner resumes after the log's last `hostSeq`, below the host's `acked_h`, and the host replays
//! nothing, having dropped them. Waiting for the hello's `last_h` then waited out the whole stall
//! (`REPLAY_STALL`, 10 s of every carrier restart fault, 2026-11-24: "adopt agent hosts 10012ms").

use super::*;

#[tokio::test]
async fn an_adoption_does_not_wait_for_acknowledged_entries_the_log_kept_nowhere() {
    let dir = scratch("unlogged-tail");
    let quiet = dir.join("agent");
    write_executable(&quiet, "#!/bin/sh\necho one >&2\necho two >&2\nexec sleep 60\n");
    let mut launch = spec(&dir, "s-unlogged-tail");
    launch.program = quiet.to_string_lossy().into_owned();
    launch.args.clear();
    let record = link::spawn(&launcher(), &launch).await.unwrap();
    let lock = live_lock(&dir, &record);

    // The first owner takes both stderr lines and acknowledges them.
    let first = hosted_agent(&record, true).await;
    assert!(
        first.wait_replayed(2, Duration::from_secs(10), Duration::from_secs(10)).await,
        "the first owner never logged the host's two entries"
    );
    tokio::time::sleep(Duration::from_millis(300)).await;

    // The next owner's log holds no `hostSeq` of them: it resumes after 0.
    let (inbound, _) = tokio::sync::mpsc::channel(64);
    let tap: acpmux::agent::Tap = std::sync::Arc::new(|_, _, _| true);
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
    let acpmux::agent::Attached::Ready(next, adopted, _) = attached else {
        panic!("the host refused its controller")
    };
    assert_eq!((adopted.last_h, adopted.acked_h), (2, 2), "{adopted:?}");
    let started = std::time::Instant::now();
    let replayed =
        next.wait_replayed(adopted.last_h, Duration::from_secs(3), Duration::from_secs(5)).await;
    let took = started.elapsed();
    assert!(replayed, "the adoption waited out its stall for entries the host had dropped");
    assert!(took < Duration::from_secs(1), "the adoption took {took:?}");

    drop((first, next));
    // SAFETY: the host this test spawned; its live lock is held, so the pid is its own.
    unsafe { libc::kill(record.host_pid as i32, libc::SIGKILL) };
    wait_dead(lock).await;
    let _ = std::fs::remove_dir_all(&dir);
}
