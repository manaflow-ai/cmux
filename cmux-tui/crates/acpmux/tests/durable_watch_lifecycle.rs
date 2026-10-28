//! Ordinary wake messages across local turns, peer outages and daemon crashes.
#![cfg(unix)]
#[path = "support/daemon_env.rs"]
mod daemon_env;
const HERMETIC: daemon_env::Process = daemon_env::Process::stand_in();
#[path = "durable_watch_lifecycle/daemon.rs"]
mod daemon;
use daemon::{Daemon, next_wake, observe, quiet};
use serde_json::{Value, json};
#[path = "durable_watch_lifecycle/peer.rs"]
mod peer;
#[path = "durable_watch_lifecycle/purge.rs"]
mod purge;
use peer::Peer;
use std::{sync::atomic::Ordering, time::Duration};

fn deliveries_empty(v: &Value) -> bool {
    v["deliveries"].as_array().unwrap().is_empty()
}
fn watch_gone(v: &Value, id: &Value) -> bool {
    v["watches"].as_array().unwrap().iter().all(|w| &w["id"] != id)
}

#[tokio::test]
async fn local_and_peer_turns_wake_once_and_one_shot_is_removed_after_delivery() {
    let mut a = Daemon::new().await;
    let mut b = Daemon::new().await;
    let sink = a.chat("coordinator").await;
    let local = a.chat("local-job").await;
    let remote = b.chat("peer-job").await;
    a.peer(&b).await;
    let mut notes = observe(&a, &sink).await;
    let watch = a
        .watch(&sink, vec![local.clone(), format!("b/{remote}")], "ready", true, Some("finished"))
        .await;
    a.prompt(&local, "local finished").await;
    let first = next_wake(&mut notes).await;
    assert!(
        first.contains(&local) && first.contains("is ready") && first.contains("local finished"),
        "{first}"
    );
    a.settled(|v| watch_gone(v, &watch["id"])).await;
    a.watch(
        &sink,
        vec![local.clone(), format!("b/{remote}")],
        "ready",
        true,
        Some("peer finished"),
    )
    .await;
    b.prompt(&remote, "peer finished").await;
    let second = next_wake(&mut notes).await;
    assert!(
        second.contains(&format!("b/{remote}")) && second.contains("peer finished"),
        "{second}"
    );
    assert!(
        second.contains(&format!("acpmux history b/{remote}")) && second.contains("acpmux pending")
    );
    quiet(&mut notes).await;
    assert_eq!(a.wakes(&sink).await.len(), 2);
    let once = a.watch(&sink, vec![local.clone()], "ready", true, Some("next finish")).await;
    a.prompt(&local, "next finish").await;
    assert!(next_wake(&mut notes).await.contains(&local));
    a.settled(|v| watch_gone(v, &once["id"]) && deliveries_empty(v)).await;
    a.prompt(&local, "next finish again").await;
    quiet(&mut notes).await;
    assert_eq!(a.wakes(&sink).await.len(), 3);
    a.stop().await;
    b.stop().await;
}

#[tokio::test]
async fn peer_offline_notice_is_once_and_watch_resolves_after_reconnect() {
    let mut a = Daemon::new().await;
    let mut b = Daemon::new().await;
    let sink = a.chat("coordinator").await;
    let source = b.chat("source").await;
    let other = b.chat("other-source").await;
    a.peer(&b).await;
    let mut notes = observe(&a, &sink).await;
    let watch = a
        .watch(
            &sink,
            vec![format!("b/{source}"), format!("b/{other}")],
            "ready",
            true,
            Some("returned"),
        )
        .await;
    b.disconnect().await;
    assert!(next_wake(&mut notes).await.contains("Peer b is offline"));
    quiet(&mut notes).await;
    let listed = a.list().await;
    assert_eq!(listed["watches"][0]["active"], true);
    a.restart().await;
    let mut notes = observe(&a, &sink).await;
    quiet(&mut notes).await;
    b.start_again().await;
    a.peer(&b).await;
    b.prompt(&source, "returned").await;
    let wake = next_wake(&mut notes).await;
    assert!(wake.contains(&source) && wake.contains("is ready"), "{wake}");
    a.settled(|v| watch_gone(v, &watch["id"])).await;
    assert_eq!(a.wakes(&sink).await.len(), 2);
    a.stop().await;
    b.stop().await;
}

#[tokio::test]
async fn pending_permission_wakes_survive_restart_and_reissue_without_duplicates() {
    let mut a = Daemon::new().await;
    let mut b = Daemon::new().await;
    let sink = b.chat("coordinator").await;
    let source = a.chat("source").await;
    a.peer(&b).await;
    let watch = a.watch(&format!("b/{sink}"), vec![source.clone()], "permission", true, None).await;
    // The sink is offline before either permission resolves the watch. Its wakes are owed.
    b.disconnect().await;
    a.send(&source, "permission-batch: watch-pair").await;
    let count = |v: &Value| {
        v["deliveries"]
            .as_array()
            .unwrap()
            .iter()
            .map(|d| d["status"].as_str().unwrap_or_default())
            .filter(|s| *s != "delivered")
            .count()
    };
    // Two pending requests can be one batched delivery or two separate deliveries.
    a.settled(|v| count(v) > 0).await;
    a.state_when("_acpmux/info", json!({"sessionId": source}), |v| {
        v["pending"].as_array().is_some_and(|p| p.len() == 2)
    })
    .await;
    a.restart().await;
    let info = a
        .state_when("_acpmux/info", json!({"sessionId": source}), |v| {
            v["pending"].as_array().is_some_and(|p| p.len() == 2)
        })
        .await;
    assert_eq!(info["pending"].as_array().unwrap().len(), 2, "{info}");
    assert_eq!(a.list().await["watches"][0]["id"], watch["id"]);
    b.start_again().await;
    let mut notes = observe(&b, &sink).await;
    a.peer(&b).await;
    let text = next_wake(&mut notes).await;
    assert!(text.contains("is permission"), "{text}");
    a.settled(|v| deliveries_empty(v) && watch_gone(v, &watch["id"])).await;
    a.restart().await;
    a.peer(&b).await;
    quiet(&mut notes).await;
    assert_eq!(b.wakes(&sink).await.len(), 1);
    a.stop().await;
    b.stop().await;
}

#[tokio::test]
async fn failed_wake_stays_listed_and_retries_after_recipient_is_repaired() {
    let mut a = Daemon::new().await;
    let peer = Peer::new(Duration::ZERO, 1).await;
    peer.reject.store(true, Ordering::SeqCst);
    peer.connect(&a).await;
    let source = a.chat("source").await;
    let watch =
        a.watch("scripted/job-0", vec![source.clone()], "ready", true, Some("finished")).await;
    a.prompt(&source, "finished").await;
    let failed = a
        .settled(|v| v["deliveries"].as_array().unwrap().iter().any(|d| d["status"] == "failed"))
        .await;
    assert!(!watch_gone(&failed, &watch["id"]));
    assert!(failed["deliveries"][0]["error"].is_string(), "{failed}");
    peer.reject.store(false, Ordering::SeqCst);
    peer.connect(&a).await;
    a.settled(|v| watch_gone(v, &watch["id"]) && deliveries_empty(v)).await;
    assert_eq!(peer.accepted.load(Ordering::SeqCst), 1);
    a.stop().await;
}

#[tokio::test]
async fn remote_replay_checkpoints_pages_even_when_total_exceeds_request_deadline() {
    for (summary, timeout) in [(601, false), (0, false), (601, true)] {
        let mut a = Daemon::new().await;
        let peer = Peer::scripted(Duration::from_millis(100), 1, summary, timeout).await;
        peer.connect(&a).await;
        let sink = a.chat("coordinator").await;
        let mut notes = observe(&a, &sink).await;
        let watch =
            a.watch(&sink, vec!["scripted/job-0".into()], "ready", true, Some("complete")).await;
        assert!(next_wake(&mut notes).await.contains("is ready"));
        a.settled(|v| watch_gone(v, &watch["id"])).await;
        let expected = if timeout { vec![0, 256, 256, 512] } else { vec![0, 256, 512] };
        assert_eq!(*peer.pages.lock().unwrap(), expected, "summary={summary}, timeout={timeout}");
        assert_eq!(a.wakes(&sink).await.len(), 1);
        a.stop().await;
    }
}

#[tokio::test]
async fn stalled_remote_reads_do_not_delay_local_wakes() {
    let mut a = Daemon::new().await;
    let peer = Peer::new(Duration::from_secs(5), 100).await;
    peer.connect(&a).await;
    let sink = a.chat("coordinator").await;
    let local = a.chat("local-job").await;
    let mut notes = observe(&a, &sink).await;
    let mut sources: Vec<_> = (0..100).map(|i| format!("scripted/job-{i}")).collect();
    sources.push(local.clone());
    a.watch(&sink, sources, "ready", true, Some("finished")).await;
    peer.read_started().await;
    a.prompt(&local, "finished").await;
    let wake = tokio::time::timeout(Duration::from_secs(2), next_wake(&mut notes))
        .await
        .expect("local wake blocked by remote reads");
    assert!(wake.contains(&local));
    a.stop().await;
}

#[tokio::test]
async fn remote_replay_resumes_from_saved_page_after_daemon_restart() {
    let mut a = Daemon::new().await;
    let peer = Peer::new(Duration::from_millis(100), 1).await;
    peer.connect(&a).await;
    let sink = a.chat("coordinator").await;
    a.watch(&sink, vec!["scripted/job-0".into()], "ready", true, Some("complete")).await;
    loop {
        peer.read_started().await;
        if peer.pages.lock().unwrap().contains(&256) {
            break;
        }
    }
    a.restart().await;
    let mut notes = observe(&a, &sink).await;
    assert!(next_wake(&mut notes).await.contains("is ready"));
    assert_eq!(peer.pages.lock().unwrap().iter().filter(|p| **p == 0).count(), 1);
    assert_eq!(a.wakes(&sink).await.len(), 1);
    a.stop().await;
}

#[tokio::test]
async fn corrupt_watch_file_is_quarantined_and_older_cursors_still_resolve() {
    let mut a = Daemon::new().await;
    a.disconnect().await;
    let path = a.dir.path().join("watches.json");
    std::fs::write(&path, b"{bad").unwrap();
    a.start_again().await;
    assert_eq!(a.list().await["watches"], json!([]));
    let bad = std::fs::read_dir(a.dir.path())
        .unwrap()
        .flatten()
        .find(|e| e.file_name().to_string_lossy().starts_with("watches.json.bad-"))
        .unwrap();
    assert_eq!(std::fs::read(bad.path()).unwrap(), b"{bad");
    let sink = a.chat("sink").await;
    let source = a.chat("source").await;
    let watch = a.watch(&sink, vec![source.clone()], "ready", true, Some("migrated")).await;
    a.disconnect().await;
    let mut saved: Value = serde_json::from_slice(&std::fs::read(&path).unwrap()).unwrap();
    let cursor = &mut saved["watches"][watch["id"].as_str().unwrap()]["cursors"][&source];
    cursor.as_object_mut().unwrap().retain(|k, _| {
        ["seq", "initial", "reply", "tail", "matched", "last_resolve"].contains(&k.as_str())
    });
    std::fs::write(&path, serde_json::to_vec(&saved).unwrap()).unwrap();
    a.start_again().await;
    assert_eq!(a.list().await["watches"][0]["id"], watch["id"]);
    let mut notes = observe(&a, &sink).await;
    a.prompt(&source, "migrated").await;
    assert!(next_wake(&mut notes).await.contains("is ready"));
    a.stop().await;
}
