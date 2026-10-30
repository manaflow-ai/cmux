//! A chat's first work (`inbox.rs` `first_work`): the sender of the message that runs as its
//! first prompt is its delegator, even when another agent's message comes into the inbox while
//! that prompt waits to start, or joins its turn (`digest.rs`), or a person's prompt runs first.
//! No notice runs before it.

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
        // What the sender cannot go on without: it wakes an idle chat (`inbox.rs` `wakes`).
        class: Some(crate::prompt_class::PromptClass::Block),
        inbox,
        ..PromptOptions::default()
    };
    let blocks = vec![json!({"type": "text", "text": text})];
    let (hub, to) = (hub.clone(), to.clone());
    tokio::spawn(async move { hub.prompt_with(&to, blocks, "test", false, opts).await })
}

/// Pauses the next prompt that reaches `seam`: `prompt_start_seam`, between its turn's
/// admission and start, or `first_work_seam`, once it holds the first work and before it queues.
fn pause(
    seam: &full_access_bound::WriteSeam,
) -> (tokio::sync::oneshot::Receiver<()>, tokio::sync::oneshot::Sender<()>) {
    let (arrived_tx, arrived) = tokio::sync::oneshot::channel();
    let (release, release_rx) = tokio::sync::oneshot::channel();
    *seam.lock().unwrap() = Some((arrived_tx, release_rx));
    (arrived, release)
}

/// The `kind` records of the chat's log.
fn records(hub: &Hub, s: &Session, kind: &str) -> Vec<Value> {
    let records = hub.events(&s.id, 0, 100_000).unwrap();
    records.into_iter().filter(|r| r.kind == kind).map(|r| r.msg).collect()
}

/// The prompt ids of the chat's turns, in order.
fn turns(hub: &Hub, s: &Session) -> Vec<Value> {
    records(hub, s, "user_message").into_iter().map(|m| m["promptId"].clone()).collect()
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_message_the_inbox_takes_before_the_first_work_starts_is_not_the_delegator() {
    let (hub, s) = chat().await;
    let (arrived, release) = pause(&hub.prompt_start_seam);
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
    let (arrived, release) = pause(&hub.prompt_start_seam);
    let first = send(&hub, &s, "s-coord", "p-brief", "do the thing", true);
    tokio::time::timeout(WAIT, arrived).await.unwrap().unwrap();

    // Two more agents' messages that queue: the one that comes while the first work holds the
    // turn's lock waits on it, the next waits in the queue behind it and joins the first work's
    // turn as a digest (`digest.rs` `take_joined`).
    let waits = send(&hub, &s, "s-other", "p-other", "and this", false);
    let waiting = async {
        while s.queued() == 0 {
            tokio::time::sleep(Duration::from_millis(20)).await;
        }
    };
    tokio::time::timeout(WAIT, waiting).await.expect("the second message waits");
    let joins = send(&hub, &s, "s-third", "p-third", "and that", false);
    let queued = async {
        while s.queue.lock().unwrap().is_empty() {
            tokio::time::sleep(Duration::from_millis(20)).await;
        }
    };
    tokio::time::timeout(WAIT, queued).await.expect("the third message queues");

    release.send(()).unwrap();
    let done = tokio::time::timeout(WAIT, first).await.unwrap().unwrap().unwrap();
    assert_eq!(done["stopReason"], "end_turn", "{done}");
    for other in [waits, joins] {
        let r = tokio::time::timeout(WAIT, other).await.unwrap().unwrap().unwrap();
        assert_eq!(r["stopReason"], "end_turn", "{r}");
    }
    assert_eq!(s.meta().turn_count, 2, "the third message joined the first turn");
    assert_eq!(s.meta().delegator.as_deref(), Some("s-coord"));
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_blocker_that_comes_before_the_first_work_queues_waits_for_it() {
    let (hub, s) = chat().await;
    let (arrived, release) = pause(&hub.first_work_seam);
    let first = send(&hub, &s, "s-coord", "p-brief", "do the thing", true);
    tokio::time::timeout(WAIT, arrived).await.unwrap().unwrap();

    // A blocker goes to the inbox; past the wake's debounce no notice has taken the chat's turn.
    let other = send(&hub, &s, "s-other", "p-other", "stuck on this", true);
    let inboxed = async {
        while s.inbox.lock().unwrap().items.is_empty() {
            tokio::time::sleep(Duration::from_millis(20)).await;
        }
    };
    tokio::time::timeout(WAIT, inboxed).await.expect("the inbox takes the blocker");
    tokio::time::sleep(Duration::from_millis(inbox::WAKE_DEBOUNCE_MS + 1_500)).await;
    assert!(s.turn().is_none(), "a notice took the chat's turn before its first work");

    release.send(()).unwrap();
    let done = tokio::time::timeout(WAIT, first).await.unwrap().unwrap().unwrap();
    assert_eq!(done["stopReason"], "end_turn", "{done}");
    let all = turns(&hub, &s);
    assert_eq!(all.first(), Some(&json!("p-brief")), "{all:?}");
    assert_eq!(s.meta().delegator.as_deref(), Some("s-coord"));
    other.abort();
}

/// A person's prompt that takes the chat's first turn: the first work waits in the queue behind
/// it, marked as the first work in the provenance that queue keeps across a restart
/// (`queue.rs`), and its sender is the delegator once it runs.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_persons_prompt_before_the_first_work_queues_leaves_its_sender_the_delegator() {
    let (hub, s) = chat().await;
    let (arrived, release) = pause(&hub.first_work_seam);
    let first = send(&hub, &s, "s-coord", "p-brief", "do the thing", true);
    tokio::time::timeout(WAIT, arrived).await.unwrap().unwrap();

    // The person's prompt takes the chat's first turn and holds it at a gate.
    let gate = std::env::temp_dir().join(format!("acpmux-first-work-{}", uuid::Uuid::now_v7()));
    assert!(std::process::Command::new("mkfifo").arg(&gate).status().unwrap().success());
    let mine = {
        let (hub, s) = (hub.clone(), s.clone());
        let text = format!("gate: {}", gate.display());
        tokio::spawn(async move {
            hub.prompt(&s, vec![json!({"type": "text", "text": text})], "test", false).await
        })
    };
    let running = async {
        while s.turn().is_none() {
            tokio::time::sleep(Duration::from_millis(20)).await;
        }
    };
    tokio::time::timeout(WAIT, running).await.expect("the person's turn runs");

    // The first work queues behind it, marked.
    release.send(()).unwrap();
    let queued = async {
        loop {
            let marked =
                records(&hub, &s, "queued").into_iter().find(|m| m["promptId"] == "p-brief");
            if let Some(m) = marked {
                return m;
            }
            tokio::time::sleep(Duration::from_millis(20)).await;
        }
    };
    let queued = tokio::time::timeout(WAIT, queued).await.expect("the first work queues");
    assert_eq!(queued["_meta"]["provenance"]["firstWork"], true, "{queued}");

    let path = gate.clone();
    tokio::task::spawn_blocking(move || std::fs::write(path, "go")).await.unwrap().unwrap();
    let mine = tokio::time::timeout(WAIT, mine).await.unwrap().unwrap().unwrap();
    assert_eq!(mine["stopReason"], "end_turn", "{mine}");
    let done = tokio::time::timeout(WAIT, first).await.unwrap().unwrap().unwrap();
    assert_eq!(done["stopReason"], "end_turn", "{done}");
    assert_eq!(s.meta().turn_count, 2);
    assert_eq!(s.meta().delegator.as_deref(), Some("s-coord"));
    let _ = std::fs::remove_file(gate);
}
