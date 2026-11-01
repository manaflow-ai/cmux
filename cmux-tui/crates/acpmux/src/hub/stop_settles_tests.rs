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
        // A sign-in failure fails over; a usage limit waits for its reset (`auto_resume.rs`).
        cfg["harnesses"]["fake"]["argv"] =
            json!(["/usr/bin/env", "FAKE_AUTH_FAIL=1", "python3", fake]);
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
    // The first agent answers a sign-in failure in a second; its fallback's start waits here.
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

/// A Stop while the agent starts, and then the start fails: the Stop was taken, so the turn
/// reads as stopped, not as the start's failure.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_stop_while_the_agent_starts_ends_the_turn_cancelled_when_the_start_then_fails() {
    let (hub, s) = chat(false).await;
    hub.kill(&s, false).await.unwrap();
    let spawning = s.spawn_lock.lock().await;
    let run = prompt(&hub, &s, "hello while starting");
    until("the turn opens", || s.turn().is_some()).await;
    hub.cancel(&s).await.expect("a Stop of a turn whose agent is starting is refused");
    // The start that comes now misses its budget.
    hub.config.write().await.agent_start_timeout_ms = Some(1);
    drop(spawning);
    let answer = tokio::time::timeout(WAIT, run).await.expect("the prompt answers").unwrap();
    assert!(answer.is_err(), "{answer:?}");
    let result = record(&hub, &s, "mux", "turn_result", |_| true).await;
    assert_eq!(result.msg["status"], "cancelled", "{:?}", result.msg);
    assert_ne!(state(&hub, &s), "stopping");
}

/// Other agents' messages that joined a turn a Stop kept from its agent come back held by the
/// Stop: they never start a turn the moment the stopped one ended.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn messages_that_joined_a_stopped_turn_come_back_held_by_the_stop() {
    let (hub, s) = chat(false).await;
    let first = prompt(&hub, &s, "until-cancel");
    record(&hub, &s, "", "agent_message_chunk", |m| {
        m["params"]["update"]["content"]["text"] == "running"
    })
    .await;
    // Two agents' messages wait behind the running turn: the second joins the first's turn
    // (`digest.rs`).
    let head = prompt_as(&hub, &s, "build is green", "p-head", Some("builder"));
    until("the first message queues", || s.queue().len() == 1).await;
    let _joined = prompt_as(&hub, &s, "lint is green", "p-join", Some("linter"));
    until("both messages queue", || s.queue().len() == 2).await;
    let (arrived_tx, arrived) = tokio::sync::oneshot::channel();
    let (release, release_rx) = tokio::sync::oneshot::channel();
    *hub.copy_seam.lock().unwrap() = Some((arrived_tx, release_rx));
    hub.cancel(&s).await.unwrap();
    let _ = tokio::time::timeout(WAIT, first).await.expect("the first turn ends");
    // Their turn has started and is making its prompt's copies: the person stops it.
    tokio::time::timeout(WAIT, arrived).await.expect("the copies are made").unwrap();
    assert!(s.queue().is_empty(), "the second message did not join: {:?}", s.queue());
    hub.person_stop(&s).await.expect("the Stop is refused");
    release.send(()).unwrap();
    let answer = tokio::time::timeout(WAIT, head).await.expect("the prompt answers").unwrap();
    assert!(answer.is_err(), "{answer:?}");
    record(&hub, &s, "mux", "queue_paused", |m| {
        m["reason"] == "stop" && m["held"] == json!(["p-join"])
    })
    .await;
    tokio::time::sleep(Duration::from_millis(500)).await;
    let row = hub.session_summary(&s);
    assert_eq!(row["queue"][0]["promptId"], "p-join", "{row}");
    assert_eq!(row["queue"][0]["heldByStop"], true, "{row}");
    assert_eq!(written(&hub, &s, "lint is green"), 0, "the message ran after the Stop");
}

/// An automatic release of the prompts a failed turn held lets the person's go, never another
/// agent's message a Stop holds: the record names only those it let go.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn an_automatic_release_names_only_the_prompts_it_let_go() {
    let (hub, s) = chat(false).await;
    let _running = prompt(&hub, &s, "until-cancel");
    record(&hub, &s, "", "agent_message_chunk", |m| {
        m["params"]["update"]["content"]["text"] == "running"
    })
    .await;
    let turn = s.turn().unwrap().turn_id;
    let _mine = prompt_as(&hub, &s, "then the tests", "p-mine", None);
    let _theirs = prompt_as(&hub, &s, "build is green", "p-agent", Some("builder"));
    until("both queue", || s.queue().len() == 2).await;
    // A failed turn held both; then the person's Stop holds the agent's.
    hub.pause_queue(&s, &turn);
    hub.hold_agent_messages(&s, &turn);
    // The Stop's record names the agent's message a failed turn held already: a pane shows it
    // held by the Stop.
    record(&hub, &s, "mux", "queue_paused", |m| {
        m["reason"] == "stop" && m["held"] == json!(["p-agent"])
    })
    .await;
    assert!(hub.resume_held(&s, &["p-mine".to_owned(), "p-agent".to_owned()]));
    let resumed = record(&hub, &s, "mux", "queue_resumed", |_| true).await;
    assert_eq!(resumed.msg["promptIds"], json!(["p-mine"]), "{:?}", resumed.msg);
    let held: Vec<(String, bool)> =
        s.queue().iter().map(|q| (q.prompt_id.clone(), q.held)).collect();
    assert!(held.contains(&("p-agent".to_owned(), true)), "{held:?}");
}
