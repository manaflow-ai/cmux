//! The chat book's translator keeps a chat's queue as v1 does: the hub's own enqueue, holds and
//! send-now run here, and after each step the queue the translator reads from the session's log
//! (ids in order, held flags) is the hub's. Then a restart: the hub's restored queue against the
//! translator's of the same log.

use super::*;
use crate::config::{Config, StoreMode};
use acpmux_book::translate::{self as book, Harness, prompt_hash};
use std::time::Duration;

const WAIT: Duration = Duration::from_secs(20);
const FAKE: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");

fn durable(dir: &std::path::Path) -> Arc<Hub> {
    let mut cfg: Config = serde_json::from_value(json!({
        "harnesses": {"fake": {"argv": ["python3", FAKE]}},
        "defaultHarness": "fake"
    }))
    .unwrap();
    cfg.store.mode = StoreMode::Local;
    let store = crate::store::open(&cfg.store, dir).unwrap();
    Hub::new(cfg, store)
}

fn prompt_as(
    hub: &Arc<Hub>,
    s: &Arc<Session>,
    text: &str,
    prompt_id: &str,
    agent: Option<&str>,
) -> tokio::task::JoinHandle<Result<Value, RpcError>> {
    let (hub, s) = (hub.clone(), s.clone());
    let blocks = vec![json!({"type": "text", "text": text})];
    let opts = PromptOptions {
        prompt_id: Some(prompt_id.to_owned()),
        agent: agent.map(str::to_owned),
        ..Default::default()
    };
    tokio::spawn(async move { hub.prompt_with(&s, blocks, "test", false, opts).await })
}

async fn until(what: &str, check: impl Fn() -> bool) {
    let wait = async {
        while !check() {
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
    };
    tokio::time::timeout(WAIT, wait).await.unwrap_or_else(|_| panic!("{what}"));
}

/// The queue a translator reads from the whole log, as (id, held). The book keeps a hash of
/// each id: it is named by the hub's ids, and by the log's own `promptId`s (a restart's
/// continuation has an id the test did not choose).
fn translated(hub: &Hub, id: &str) -> Vec<(String, bool)> {
    let mut state = book::State::default();
    let mut names = std::collections::HashMap::new();
    for (place, record) in hub.events(id, 0, 1_000_000).unwrap().iter().enumerate() {
        if let Some(prompt) = record.msg.get("promptId").and_then(Value::as_str) {
            names.insert(prompt_hash(prompt), prompt.to_owned());
        }
        let line = serde_json::to_vec(record).unwrap();
        let _ = book::translate(&mut state, Harness::V1, place as u64, 1, &line);
    }
    let name = |hash: u64| names.get(&hash).cloned().unwrap_or_else(|| format!("#{hash:016x}"));
    state.queue().map(|entry| (name(entry.id_hash), entry.held())).collect()
}

fn hub_queue(s: &Session) -> Vec<(String, bool)> {
    s.queue().iter().map(|q| (q.prompt_id.clone(), q.held)).collect()
}

/// The two agree within the wait; the hub logs each change under the lock that made it.
async fn agree(hub: &Hub, s: &Session, step: &str) {
    let wait = async {
        while translated(hub, &s.id) != hub_queue(s) {
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
    };
    if tokio::time::timeout(WAIT, wait).await.is_err() {
        panic!(
            "{step}: the hub's queue {:?}, the translator's {:?}",
            hub_queue(s),
            translated(hub, &s.id)
        );
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn the_translators_queue_is_the_hubs_after_every_step_and_a_restart() {
    let dir = std::env::temp_dir().join(format!("acpmux-queue-order-{}", uuid::Uuid::now_v7()));
    let hub = durable(&dir);
    let req = NewRequest { cwd: Some(std::env::temp_dir()), ..NewRequest::default() };
    let s = hub.new_session(req).await.unwrap();
    let id = s.id.clone();
    let _running = prompt_as(&hub, &s, "until-cancel", "p-run", None);
    until("the turn runs", || s.turn().is_some()).await;

    let _a = prompt_as(&hub, &s, "first", "p-a", None);
    until("p-a queues", || s.queue().len() == 1).await;
    agree(&hub, &s, "a person's prompt").await;
    let _agent = prompt_as(&hub, &s, "build is green", "p-agent", Some("builder"));
    until("p-agent queues", || s.queue().len() == 2).await;
    agree(&hub, &s, "an agent's message").await;
    // A person's prompt goes ahead of the agent's message: `queued`, then `queue_order`.
    let _b = prompt_as(&hub, &s, "second", "p-b", None);
    until("p-b queues", || s.queue().len() == 3).await;
    let order: Vec<String> = hub_queue(&s).into_iter().map(|(id, _)| id).collect();
    assert_eq!(order, ["p-a", "p-b", "p-agent"]);
    agree(&hub, &s, "a person's prompt ahead of an agent's message").await;

    let turn = s.turn().unwrap().turn_id;
    hub.pause_queue(&s, &turn);
    until("all are held", || s.queue().iter().all(|q| q.held)).await;
    agree(&hub, &s, "a failed turn holds the queue").await;
    assert!(hub.resume_held(&s, &["p-b".to_owned()]));
    agree(&hub, &s, "one is released").await;
    assert!(hub.put_next(&s, "p-agent", None).unwrap());
    let order: Vec<String> = hub_queue(&s).into_iter().map(|(id, _)| id).collect();
    assert_eq!(order.first().map(String::as_str), Some("p-agent"));
    agree(&hub, &s, "send now").await;

    hub.shutdown_all().await;
    drop(s);
    drop(hub);
    let hub = durable(&dir);
    let s = hub.resolve(&id).unwrap();
    hub.restore_queue(&s);
    let restored = hub_queue(&s);
    assert!(!restored.is_empty(), "a restart restored no queue");
    assert_eq!(translated(&hub, &id), restored, "a restart");
    hub.shutdown_all().await;
    let _ = std::fs::remove_dir_all(&dir);
}
