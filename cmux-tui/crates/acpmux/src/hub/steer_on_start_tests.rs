//! The person's steer that comes while another prompt holds the chat's turn and has not shown it
//! yet (its agent starting, its uploads read: `Session::turn_claimed`) queues behind it and
//! steers into that turn once it shows (`queue.rs` `QueuedPrompt::steer_on_start`). Before, it
//! waited in the queue for that whole turn (Leo, 2026-11-14, two prompts sent while the agent
//! ran landed in the queue: "but all my things should be steer by default in the app?").

use super::*;
use std::time::Duration;

const WAIT: Duration = Duration::from_secs(20);

/// A hub with one open chat on the stand-in agent steering as Claude Code does.
async fn chat() -> (Arc<Hub>, Arc<Session>) {
    use crate::config::{Config, StoreMode};
    let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
    let argv = ["/usr/bin/env", "FAKE_CLAUDE_STEER=1", "python3", fake];
    let cfg = json!({"harnesses": {"fake": {
        "argv": argv,
        "env": {"ACPMUX_SESSION_CPU_CLASS": "normal"},
    }}, "defaultHarness": "fake"});
    let mut cfg: Config = serde_json::from_value(cfg).unwrap();
    cfg.store.mode = StoreMode::Memory;
    let store = crate::store::open(&cfg.store, std::path::Path::new("/nonexistent")).unwrap();
    let hub = Hub::new(cfg, store);
    let req = NewRequest { cwd: Some(std::env::temp_dir()), ..NewRequest::default() };
    let session = hub.new_session(req).await.unwrap();
    (hub, session)
}

fn send(
    hub: &Arc<Hub>,
    s: &Arc<Session>,
    prompt_id: &str,
    text: &str,
    steer: bool,
    accepted: Option<tokio::sync::oneshot::Sender<Value>>,
) -> tokio::task::JoinHandle<Result<Value, RpcError>> {
    let opts = PromptOptions {
        prompt_id: Some(prompt_id.to_owned()),
        on_accepted: accepted.map(|tx| {
            Box::new(move |v| {
                let _ = tx.send(v);
            }) as Box<dyn FnOnce(Value) + Send>
        }),
        ..PromptOptions::default()
    };
    let blocks = vec![json!({"type": "text", "text": text})];
    let (hub, s) = (hub.clone(), s.clone());
    tokio::spawn(async move { hub.prompt_with(&s, blocks, "test", steer, opts).await })
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn the_persons_steer_sent_as_a_turn_starts_steers_into_it_not_the_queue() {
    let (hub, s) = chat().await;
    // The first prompt holds the turn lock, stopped before its turn shows.
    let (arrived_tx, arrived) = tokio::sync::oneshot::channel();
    let (release, release_rx) = tokio::sync::oneshot::channel::<()>();
    *hub.prompt_start_seam.lock().unwrap() = Some((arrived_tx, release_rx));
    let first = send(&hub, &s, "sos-a", "until-cancel", false, None);
    tokio::time::timeout(WAIT, arrived).await.unwrap().unwrap();
    assert!(s.turn().is_none(), "the first prompt has not shown its turn");

    // The person's steer comes now: no turn to steer into yet, so it waits behind the first.
    let (tx, accepted) = tokio::sync::oneshot::channel();
    let steer = send(&hub, &s, "sos-b", "steer this in", true, Some(tx));
    let accepted = tokio::time::timeout(WAIT, accepted).await.unwrap().unwrap();
    assert_eq!(accepted["queued"], json!(true), "{accepted}");
    // Its `queued` record says it only waits for the turn to show, so a client keeps its bubble in
    // the transcript instead of drawing it as a queued row (Leo, 2026-11-24).
    let queued = hub.events(&s.id, 0, 100_000).unwrap();
    let queued = queued.iter().find(|r| r.kind == "queued" && r.msg["promptId"] == "sos-b");
    let queued = queued.expect("the steer's queued record");
    assert_eq!(queued.msg["steerOnStart"], json!(true), "{}", queued.msg);

    // The first turn shows and runs until it is stopped: the steer goes into it, at once.
    release.send(()).unwrap();
    let answer = tokio::time::timeout(WAIT, steer)
        .await
        .expect("the steer went into the running turn, not behind it")
        .unwrap()
        .unwrap();
    assert_eq!(answer["stopReason"], "steered", "{answer}");
    let turn = s.turn().expect("the first turn still runs");
    assert_eq!(turn.prompt_id, "sos-a");
    let records = hub.events(&s.id, 0, 100_000).unwrap();
    let steered = records
        .iter()
        .find(|r| r.dir == "mux" && r.kind == "user_message" && r.msg["promptId"] == "sos-b");
    let steered = steered.expect("the steer's user_message");
    assert_eq!(steered.msg["steer"], json!(true), "{}", steered.msg);
    assert_eq!(steered.msg["turnId"], json!(turn.turn_id), "{}", steered.msg);
    // It went in once, and started no turn of its own.
    let starts =
        records.iter().filter(|r| r.kind == "turn_started" && r.msg["promptId"] == "sos-b").count();
    assert_eq!(starts, 0);
    assert!(s.queue().is_empty(), "nothing waits in the queue");

    let _ = hub.cancel(&s).await;
    let _ = tokio::time::timeout(WAIT, first).await;
    hub.shutdown_all().await;
}

/// A prompt the person queued on purpose (⌘Return, Queue for later: no `steer`) still waits for
/// the whole turn.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_prompt_queued_on_purpose_as_a_turn_starts_still_waits_for_it() {
    let (hub, s) = chat().await;
    let (arrived_tx, arrived) = tokio::sync::oneshot::channel();
    let (release, release_rx) = tokio::sync::oneshot::channel::<()>();
    *hub.prompt_start_seam.lock().unwrap() = Some((arrived_tx, release_rx));
    let first = send(&hub, &s, "sos-c", "until-cancel", false, None);
    tokio::time::timeout(WAIT, arrived).await.unwrap().unwrap();
    let (tx, accepted) = tokio::sync::oneshot::channel();
    let later = send(&hub, &s, "sos-d", "after the turn", false, Some(tx));
    let accepted = tokio::time::timeout(WAIT, accepted).await.unwrap().unwrap();
    assert_eq!(accepted["queued"], json!(true), "{accepted}");
    // A queued row, as it waits for the whole turn.
    let queued = hub.events(&s.id, 0, 100_000).unwrap();
    let queued = queued.iter().find(|r| r.kind == "queued" && r.msg["promptId"] == "sos-d");
    assert!(queued.expect("its queued record").msg.get("steerOnStart").is_none());
    release.send(()).unwrap();
    let running = async {
        while s.turn().is_none() {
            tokio::time::sleep(Duration::from_millis(20)).await;
        }
    };
    tokio::time::timeout(WAIT, running).await.expect("the first turn shows");
    tokio::time::sleep(Duration::from_millis(500)).await;
    assert!(!later.is_finished(), "a queued prompt went in before the turn ended");
    assert_eq!(s.queue().len(), 1, "it still waits");
    let _ = hub.cancel(&s).await;
    let _ = tokio::time::timeout(WAIT, first).await;
    let r = tokio::time::timeout(WAIT, later).await.unwrap().unwrap().unwrap();
    assert_eq!(r["stopReason"], "end_turn", "{r}");
    hub.shutdown_all().await;
}
