//! A Stop always ends its turn as stopped (`cancel.rs`), so clients offer Continue on it: also a
//! Stop while the chat has no agent (it starts, or a failover's fallback does), which used to be
//! refused with "session has no live agent" while the turn ran on, and a Stop its adapter
//! answers with a stop reason other than `cancelled`, which used to read as completed.
//! Leo, 2026-10-29: "this is so awkward the stop button doesnt really work and resume doesnt
//! really appear!?"

use super::*;
use std::time::Duration;

const WAIT: Duration = Duration::from_secs(20);

/// A hub with one open chat on the stand-in agent, that fails over to itself
/// (`FAKE_FALLBACK=1`) when `fails_over`.
async fn chat(fails_over: bool) -> (Arc<Hub>, Arc<Session>) {
    use crate::config::{Config, StoreMode};
    let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
    let mut cfg =
        json!({"harnesses": {"fake": {"argv": ["python3", fake]}}, "defaultHarness": "fake"});
    if fails_over {
        cfg["harnesses"]["fake"]["fallback"] = json!("fake-fallback");
        let fallback = ["/usr/bin/env", "FAKE_FALLBACK=1", "python3", fake];
        cfg["harnesses"]["fake-fallback"] = json!({"argv": fallback});
    }
    let mut cfg: Config = serde_json::from_value(cfg).unwrap();
    cfg.store.mode = StoreMode::Memory;
    let store = crate::store::open(&cfg.store, std::path::Path::new("/nonexistent")).unwrap();
    let hub = Hub::new(cfg, store);
    let req = NewRequest { cwd: Some(std::env::temp_dir()), ..NewRequest::default() };
    let session = hub.new_session(req).await.unwrap();
    (hub, session)
}

fn prompt(
    hub: &Arc<Hub>,
    s: &Arc<Session>,
    text: &str,
) -> tokio::task::JoinHandle<Result<Value, RpcError>> {
    let (hub, s) = (hub.clone(), s.clone());
    let blocks = vec![json!({"type": "text", "text": text})];
    tokio::spawn(async move { hub.prompt(&s, blocks, "test", false).await })
}

/// Waits for the first record of `kind` (from `dir`, any when empty) that `ok` takes.
async fn record(
    hub: &Hub,
    s: &Session,
    dir: &str,
    kind: &str,
    ok: impl Fn(&Value) -> bool,
) -> EventRecord {
    let find = async {
        loop {
            let events = hub.events(&s.id, 0, 100_000).unwrap();
            if let Some(e) = events
                .into_iter()
                .find(|e| (dir.is_empty() || e.dir == dir) && e.kind == kind && ok(&e.msg))
            {
                return e;
            }
            tokio::time::sleep(Duration::from_millis(20)).await;
        }
    };
    tokio::time::timeout(WAIT, find).await.unwrap_or_else(|_| panic!("no {dir} {kind} record"))
}

/// How many `session/prompt` requests holding `text` were written to an agent.
fn written(hub: &Hub, s: &Session, text: &str) -> usize {
    let records = hub.events(&s.id, 0, 100_000).unwrap();
    let prompts = records.iter().filter(|r| r.dir == "out" && r.kind == "session/prompt");
    prompts.filter(|r| r.msg["params"]["prompt"].to_string().contains(text)).count()
}

fn state(hub: &Hub, s: &Arc<Session>) -> Value {
    hub.session_summary(s)["state"].clone()
}

/// A Stop while the chat's agent has not started yet (it was stopped, and the prompt starts it
/// again): the chat has no agent to cancel. The Stop is taken, the turn reads `stopping`, its
/// prompt never reaches the agent, and the turn ends cancelled once the agent is up.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_stop_while_the_agent_starts_is_taken_and_ends_the_turn_cancelled() {
    let (hub, s) = chat(false).await;
    hub.kill(&s, false).await.unwrap();
    // Held here, the agent start the prompt makes waits: the chat has no agent meanwhile.
    let spawning = s.spawn_lock.lock().await;
    let run = prompt(&hub, &s, "hello while starting");
    let opened = async {
        while s.turn().is_none() {
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
    };
    tokio::time::timeout(WAIT, opened).await.expect("the turn opens");
    assert!(s.child.lock().await.is_none(), "the chat has an agent already");
    hub.cancel(&s).await.expect("a Stop of a turn whose agent is starting is refused");
    assert_eq!(state(&hub, &s), "stopping", "the Stop does not show");
    drop(spawning);
    let answer = tokio::time::timeout(WAIT, run).await.expect("the prompt answers").unwrap();
    let e = answer.expect_err("the prompt ran after the Stop");
    assert_eq!(e.data.as_ref().map(|d| d["reason"].clone()), Some(json!("stopped")), "{e:?}");
    assert_eq!(written(&hub, &s, "hello while starting"), 0);
    let result = record(&hub, &s, "mux", "turn_result", |_| true).await;
    assert_eq!(result.msg["status"], "cancelled", "{:?}", result.msg);
    assert_ne!(state(&hub, &s), "stopping");
    assert_ne!(state(&hub, &s), "running");
}

/// A Stop during a failover, after the first agent was let go and before its fallback started:
/// the fallback never gets the prompt, and the turn ends cancelled.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_stop_during_a_failover_keeps_the_prompt_from_the_fallback() {
    let (hub, s) = chat(true).await;
    let run = prompt(&hub, &s, "slow-limit");
    record(&hub, &s, "out", "session/prompt", |_| true).await;
    // The first agent answers its usage limit in a second; its fallback's start waits here.
    let spawning = s.spawn_lock.lock().await;
    record(&hub, &s, "mux", "failover", |_| true).await;
    // The failover lets the first agent go and puts the turn back (`detach_child`).
    let detached = async {
        while s.child.lock().await.is_some() || s.turn().is_none() {
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
    };
    tokio::time::timeout(WAIT, detached).await.expect("the first agent is let go, the turn kept");
    hub.cancel(&s).await.expect("a Stop during the failover is refused");
    assert_eq!(state(&hub, &s), "stopping", "the Stop does not show");
    drop(spawning);
    let answer = tokio::time::timeout(WAIT, run).await.expect("the prompt answers").unwrap();
    assert!(answer.is_err(), "the turn ran on on the fallback after the Stop: {answer:?}");
    assert_eq!(written(&hub, &s, "slow-limit"), 1, "the fallback got the prompt after the Stop");
    let result = record(&hub, &s, "mux", "turn_result", |_| true).await;
    assert_eq!(result.msg["status"], "cancelled", "{:?}", result.msg);
}

/// An adapter that stops on the cancel but answers `end_turn`: the turn ended because of the
/// Stop, and reads as stopped, not completed.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_stop_its_agent_answers_end_turn_still_ends_the_turn_cancelled() {
    let (hub, s) = chat(false).await;
    let run = prompt(&hub, &s, "cancel-ends-turn");
    record(&hub, &s, "", "agent_message_chunk", |m| {
        m["params"]["update"]["content"]["text"] == "running"
    })
    .await;
    hub.cancel(&s).await.unwrap();
    let answer = tokio::time::timeout(WAIT, run).await.expect("the prompt answers").unwrap();
    assert_eq!(answer.unwrap()["stopReason"], "end_turn");
    let result = record(&hub, &s, "mux", "turn_result", |_| true).await;
    assert_eq!(result.msg["status"], "cancelled", "{:?}", result.msg);
    assert_eq!(s.meta().last_turn.as_ref().map(|t| t["status"].clone()), Some(json!("cancelled")));

    // A turn nobody stopped still completes.
    let next = prompt(&hub, &s, "hello");
    tokio::time::timeout(WAIT, next).await.unwrap().unwrap().unwrap();
    let events = hub.events(&s.id, 0, 100_000).unwrap();
    let last = events.iter().rev().find(|e| e.kind == "turn_result").unwrap();
    assert_eq!(last.msg["status"], "completed", "{:?}", last.msg);
}

/// An adapter whose interrupt fails the turn: the error is the Stop's doing, so the turn reads as
/// stopped, with Continue, and holds no queue as a failure does.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_stop_its_agent_answers_with_an_error_still_ends_the_turn_cancelled() {
    let (hub, s) = chat(false).await;
    let run = prompt(&hub, &s, "cancel-errors");
    record(&hub, &s, "", "agent_message_chunk", |m| {
        m["params"]["update"]["content"]["text"] == "running"
    })
    .await;
    hub.cancel(&s).await.unwrap();
    let answer = tokio::time::timeout(WAIT, run).await.expect("the prompt answers").unwrap();
    assert!(answer.is_err(), "{answer:?}");
    let result = record(&hub, &s, "mux", "turn_result", |_| true).await;
    assert_eq!(result.msg["status"], "cancelled", "{:?}", result.msg);
    let events = hub.events(&s.id, 0, 100_000).unwrap();
    assert!(!events.iter().any(|e| e.kind == "queue_paused"), "the Stop's turn held the queue");
}
