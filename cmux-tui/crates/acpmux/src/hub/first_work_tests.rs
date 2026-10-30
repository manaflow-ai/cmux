//! A chat's first work (`inbox.rs` `first_work`): the sender of the message that runs as its
//! first prompt is its delegator, even when another agent's message comes into the inbox while
//! that prompt waits to start, or joins its turn (`digest.rs`).

use super::*;
use std::time::Duration;

const WAIT: Duration = Duration::from_secs(20);

/// A hub with one open chat on the stand-in agent.
async fn chat() -> (Arc<Hub>, Arc<Session>) {
    use crate::config::{Config, StoreMode};
    let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
    let cfg = json!({"harnesses": {"fake": {"argv": ["python3", fake]}}, "defaultHarness": "fake"});
    let mut cfg: Config = serde_json::from_value(cfg).unwrap();
    cfg.store.mode = StoreMode::Memory;
    let store = crate::store::open(&cfg.store, std::path::Path::new("/nonexistent")).unwrap();
    let hub = Hub::new(cfg, store);
    let req = NewRequest { cwd: Some(std::env::temp_dir()), ..NewRequest::default() };
    let session = hub.new_session(req).await.unwrap();
    (hub, session)
}

/// Session `from`'s send of `text` to `to`: a plain one (`inbox`) as `session/prompt` takes it,
/// else one that queues (a peer's forward).
fn send(
    hub: &Arc<Hub>,
    to: &Arc<Session>,
    from: &str,
    prompt_id: &str,
    text: &str,
    inbox: bool,
) -> tokio::task::JoinHandle<Result<Value, RpcError>> {
    let provenance = json!({"kind": "session_message", "from": format!("acp:{from}"),
                            "fromName": from, "to": format!("acp:{}", to.id)});
    let opts = PromptOptions {
        prompt_id: Some(prompt_id.to_owned()),
        provenance: Some(provenance),
        agent: Some(from.to_owned()),
        inbox,
        ..PromptOptions::default()
    };
    let blocks = vec![json!({"type": "text", "text": text})];
    let (hub, to) = (hub.clone(), to.clone());
    tokio::spawn(async move { hub.prompt_with(&to, blocks, "test", false, opts).await })
}

/// Pauses the next prompt between its admission and its turn's start (`prompt_start_seam`).
fn pause_start(
    hub: &Hub,
) -> (tokio::sync::oneshot::Receiver<()>, tokio::sync::oneshot::Sender<()>) {
    let (arrived_tx, arrived) = tokio::sync::oneshot::channel();
    let (release, release_rx) = tokio::sync::oneshot::channel();
    *hub.prompt_start_seam.lock().unwrap() = Some((arrived_tx, release_rx));
    (arrived, release)
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_message_the_inbox_takes_before_the_first_work_starts_is_not_the_delegator() {
    let (hub, s) = chat().await;
    let (arrived, release) = pause_start(&hub);
    let first = send(&hub, &s, "s-coord", "p-brief", "do the thing", true);
    tokio::time::timeout(WAIT, arrived).await.unwrap().unwrap();
    assert!(s.turn().is_none(), "the first work has not started its turn");

    // Another agent's message while the first work waits to start goes to the inbox.
    let other = send(&hub, &s, "s-other", "p-other", "and this", true);
    let inboxed = async {
        while s.inbox.lock().unwrap().items.is_empty() {
            tokio::time::sleep(Duration::from_millis(20)).await;
        }
    };
    tokio::time::timeout(WAIT, inboxed).await.expect("the inbox takes the second message");

    release.send(()).unwrap();
    let done = tokio::time::timeout(WAIT, first).await.unwrap().unwrap().unwrap();
    assert_eq!(done["stopReason"], "end_turn", "{done}");
    assert_eq!(s.meta().delegator.as_deref(), Some("s-coord"));
    other.abort();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_message_that_joins_the_first_works_turn_is_not_the_delegator() {
    let (hub, s) = chat().await;
    let (arrived, release) = pause_start(&hub);
    let first = send(&hub, &s, "s-coord", "p-brief", "do the thing", true);
    tokio::time::timeout(WAIT, arrived).await.unwrap().unwrap();

    // Another agent's message that queues behind the first work joins its turn as a digest.
    let other = send(&hub, &s, "s-other", "p-other", "and this", false);
    let queued = async {
        while s.queue.lock().unwrap().is_empty() {
            tokio::time::sleep(Duration::from_millis(20)).await;
        }
    };
    tokio::time::timeout(WAIT, queued).await.expect("the second message queues");

    release.send(()).unwrap();
    let done = tokio::time::timeout(WAIT, first).await.unwrap().unwrap().unwrap();
    assert_eq!(done["stopReason"], "end_turn", "{done}");
    let joined = tokio::time::timeout(WAIT, other).await.unwrap().unwrap().unwrap();
    assert_eq!(joined["stopReason"], "end_turn", "{joined}");
    assert_eq!(s.meta().turn_count, 1, "the second message joined the first turn");
    assert_eq!(s.meta().delegator.as_deref(), Some("s-coord"));
}
