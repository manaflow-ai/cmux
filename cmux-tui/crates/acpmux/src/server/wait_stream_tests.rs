//! A streamed token costs an open `_acpmux/wait` nothing (HOT PATH AUDIT area F, row A1,
//! handoff/hot-path-audit/stream/AUDIT.md). A wait reads its chats' rows (status, pending
//! permissions, unread, the running and the last turn), and a chunk of the agent's reply changes
//! none of them: every state change logs its own record (`status`, `turn_result`,
//! `background_turn`, ...), and the wait's 1 s poll reads one that logs none. Before, each record
//! of a waited chat woke the wait and built the summaries of every chat it waits on, once per
//! token while a Chief waited on a streaming lane.

use super::*;
use crate::config::{Config, StoreMode};
use std::sync::atomic::Ordering;

const TOKENS: usize = 500;

fn hub_with_running_chat(id: &str) -> (Arc<Hub>, Arc<crate::hub::Session>) {
    let mut config = Config::default();
    config.store.mode = StoreMode::Memory;
    let store = crate::store::open(&config.store, std::path::Path::new("/nonexistent")).unwrap();
    let meta: crate::store::SessionMeta = serde_json::from_value(json!({
        "schema": crate::store::META_SCHEMA, "id": id, "name": "lane", "harness": "claude",
        "cwd": "/tmp", "status": "running", "createdAt": 1, "updatedAt": 1
    }))
    .unwrap();
    store.save(&meta).unwrap();
    let hub = Hub::new(config, store);
    let session = hub.make_session(meta);
    hub.sessions.lock().unwrap().insert(id.to_owned(), session.clone());
    (hub, session)
}

fn chunk(id: &str, kind: &str, text: &str) -> Value {
    json!({"jsonrpc": "2.0", "method": "session/update", "params": {"sessionId": id,
        "update": {"sessionUpdate": kind, "content": {"type": "text", "text": text}}}})
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_streamed_token_does_not_evaluate_an_open_wait() {
    let id = "wait-stream-chat";
    let (hub, session) = hub_with_running_chat(id);
    let waiting = {
        let hub = hub.clone();
        tokio::spawn(async move {
            wait(&hub, &json!({"sessions": [id], "until": ["ready"], "timeoutMs": 60_000}), None)
                .await
        })
    };
    // The wait is subscribed and has read its rows once.
    tokio::time::timeout(Duration::from_secs(10), async {
        while hub.open_waits.load(Ordering::SeqCst) == 0
            || hub.wait_evaluations.load(Ordering::Relaxed) == 0
        {
            tokio::task::yield_now().await;
        }
    })
    .await
    .expect("the wait subscribes");
    let before = hub.wait_evaluations.load(Ordering::Relaxed);
    let started = tokio::time::Instant::now();
    for i in 0..TOKENS {
        let kind = if i % 5 == 0 { "agent_thought_chunk" } else { "agent_message_chunk" };
        hub.append(&session, "in", kind, chunk(id, kind, "word "));
        // Let the wait's task run after each token, as the daemon's runtime would.
        tokio::task::yield_now().await;
    }
    // Give the wait time to drain every event it was woken for (not a full poll period).
    for _ in 0..50 {
        tokio::task::yield_now().await;
    }
    tokio::time::sleep(Duration::from_millis(50)).await;
    let polls = started.elapsed().as_secs() + 1;
    let ran = hub.wait_evaluations.load(Ordering::Relaxed) - before;
    eprintln!("WAIT-STREAM tokens {TOKENS} evaluations {ran} (poll allowance {polls})");
    assert!(
        ran <= polls,
        "{ran} wait evaluations for {TOKENS} streamed tokens (at most {polls} from the 1 s poll)"
    );
    // A state change still ends the wait at once.
    hub.set_status(&session, crate::store::SessionStatus::Ready);
    let reply = tokio::time::timeout(Duration::from_secs(10), waiting)
        .await
        .expect("the status change ends the wait")
        .unwrap()
        .unwrap();
    assert_eq!(reply["timedOut"], json!(false), "{reply}");
    assert_eq!(reply["resolved"].as_array().map(Vec::len), Some(1), "{reply}");
}
