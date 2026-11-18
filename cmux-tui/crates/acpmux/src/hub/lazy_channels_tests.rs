//! A chat makes its inbound channel and its watches at first use (CMUX-571): one a restart
//! loaded and nothing started holds none of them, a subscriber made then still reads the chat's
//! status, and its agent starts as before.

use super::*;
use std::time::Duration;

const WAIT: Duration = Duration::from_secs(20);

/// A hub on the stand-in agent, its store in `dir` (one a restart reads again).
fn hub_in(dir: &std::path::Path) -> Arc<Hub> {
    use crate::config::{Config, StoreMode};
    let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
    let cfg = json!({"harnesses": {"fake": {"argv": ["python3", fake]}}, "defaultHarness": "fake"});
    let mut cfg: Config = serde_json::from_value(cfg).unwrap();
    cfg.store.mode = StoreMode::Local;
    let store = crate::store::open(&cfg.store, dir).unwrap();
    Hub::new(cfg, store)
}

/// An open chat and a closed one written to `dir`, then a hub restarted over them: neither
/// started since, with their restored queues and inboxes looked at as a daemon's start does.
async fn restarted(dir: &std::path::Path) -> (Arc<Hub>, Arc<Session>, Arc<Session>) {
    let hub = hub_in(dir);
    let req = || NewRequest { cwd: Some(std::env::temp_dir()), ..NewRequest::default() };
    let open = hub.new_session(req()).await.unwrap().id.clone();
    let closed = hub.new_session(req()).await.unwrap();
    hub.kill(&closed, false).await.unwrap();
    let closed = closed.id.clone();
    hub.shutdown_all().await;
    drop(hub);

    let hub = hub_in(dir);
    let open = hub.resolve(&open).expect("the open chat is restored");
    let closed = hub.resolve(&closed).expect("the closed chat is restored");
    assert_eq!(closed.status(), SessionStatus::Closed);
    hub.resume_queues();
    hub.inbox_review(&open);
    hub.inbox_review(&closed);
    tokio::time::sleep(Duration::from_millis(200)).await;
    (hub, open, closed)
}

/// A loaded chat no agent ran for holds no inbound channel, no `closed` or `steer_end` watch and
/// no auto-resume release watch: at 1,000 idle chats they were about 6 MB.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_chat_loaded_and_never_started_holds_no_inbound_channel_or_watches() {
    let dir = cmux_unix_socket::short_test_dir("acpmux-lazy-none");
    let (hub, open, closed) = restarted(dir.path()).await;
    assert_eq!(open.lazy_made(), [false; 4], "an open chat never started");
    assert_eq!(closed.lazy_made(), [false; 4], "a closed chat never started");
    hub.shutdown_all().await;
}

/// A `closed` subscriber made on a chat never started reads its status as it is (#41081 F2):
/// an inbound loop that first runs on a closed chat ends at once and hands its receiver back,
/// and an open chat's agent starts and answers, its later close reaching that subscriber.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_never_started_chat_reads_its_closed_status_and_starts() {
    let dir = cmux_unix_socket::short_test_dir("acpmux-lazy-start");
    let (hub, open, closed) = restarted(dir.path()).await;
    assert!(*closed.closed_watch().borrow(), "a closed chat's first subscriber reads it closed");
    let mut open_closed = open.closed_watch();
    assert!(!*open_closed.borrow(), "an open chat's first subscriber reads it open");

    hub.spawn_inbound_loop(&closed).await;
    let handed_back = async {
        while closed.inbound_rx().lock().await.is_none() {
            tokio::time::sleep(Duration::from_millis(20)).await;
        }
    };
    tokio::time::timeout(WAIT, handed_back).await.expect("the closed chat's loop ended at once");

    let blocks = vec![json!({"type": "text", "text": "hello"})];
    let done = tokio::time::timeout(WAIT, hub.prompt(&open, blocks, "test", false))
        .await
        .expect("the turn ends")
        .expect("the agent starts and answers");
    assert_eq!(done["stopReason"], "end_turn", "{done}");
    assert!(open.lazy_made()[0], "its start made the inbound channel");

    hub.kill(&open, false).await.unwrap();
    tokio::time::timeout(WAIT, open_closed.wait_for(|closed| *closed))
        .await
        .expect("the close reaches the subscriber made before the start")
        .unwrap();
    hub.shutdown_all().await;
}
