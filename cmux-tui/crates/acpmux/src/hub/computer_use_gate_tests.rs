//! The Computer Use gate (`computer_use_gate.rs`) on each hub route a prompt that names
//! `@computer-use` takes while this Mac's Computer Use is not ready: a queued prompt that starts,
//! a steer, a queue edit, Send now and `interrupt`, a failed turn's Retry and `/btw`. The
//! `session/prompt` route and the app's method are covered end to end in
//! `tests/local_app_origin.rs`.

use super::Slot;
use crate::config::{Config, StoreMode};
use crate::hub::auto_resume::retry_turn::RetryBy;
use crate::hub::*;
use std::time::Duration;

const FAKE: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
const ASKS: &str = "open Notes with @computer-use";

fn hub_with(steer: bool) -> Arc<Hub> {
    let argv = if steer {
        json!(["/usr/bin/env", "FAKE_CLAUDE_STEER=1", "python3", FAKE])
    } else {
        json!(["python3", FAKE])
    };
    let mut cfg: Config = serde_json::from_value(json!({
        "harnesses": {"fake": {"argv": argv}},
        "defaultHarness": "fake",
        "agentInbox": false,
    }))
    .unwrap();
    cfg.store.mode = StoreMode::Memory;
    let store = crate::store::open(&cfg.store, std::path::Path::new("/nonexistent")).unwrap();
    Hub::new(cfg, store)
}

async fn chat(hub: &Arc<Hub>) -> Arc<Session> {
    let req = NewRequest { cwd: Some(std::env::temp_dir()), ..Default::default() };
    hub.new_session(req).await.unwrap()
}

fn text(t: &str) -> Vec<Value> {
    vec![json!({"type": "text", "text": t})]
}

fn refused_for(e: &RpcError, state: &str) {
    assert_eq!(
        e.data,
        Some(json!({"reason": crate::computer_use_gate::REASON, "state": state})),
        "{e:?}"
    );
}

async fn until(mut done: impl FnMut() -> bool) {
    for _ in 0..800 {
        if done() {
            return;
        }
        tokio::time::sleep(Duration::from_millis(25)).await;
    }
    panic!("timed out");
}

/// A prompt in `session`'s queue with `words`, as `session/prompt` queues one.
fn queue(hub: &Hub, session: &Arc<Session>, id: &str, words: &str) {
    let blocks = text(words);
    let replaced = std::sync::OnceLock::new();
    let slot = Slot {
        text: words,
        blocks: &blocks,
        display_parts: None,
        client: "gate-test",
        prompt_id: id,
        control: Control::Local,
        cloud_mobile: false,
        trust_gate: false,
        interrupt: false,
        interrupt_turn: None,
        provenance: None,
        agent: None,
        class: None,
        supersede: None,
        full_access_device: None,
        replaced: &replaced,
        no_queue: false,
        admitted: false,
        after_turn: false,
        steer_on_start: false,
    };
    session.queued.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
    let limits = crate::hub::queue_admission::QueueLimits { prompts: None, bytes: None };
    hub.enqueue_or_refuse(session, &slot, id, limits).unwrap();
}

/// A turn that runs until the returned gate is written.
async fn gated_turn(
    hub: &Arc<Hub>,
    session: &Arc<Session>,
) -> (std::path::PathBuf, tokio::task::JoinHandle<Result<Value, RpcError>>) {
    let dir = std::env::temp_dir().join(format!("acpmux-cu-gate-{}", uuid::Uuid::now_v7()));
    std::fs::create_dir_all(&dir).unwrap();
    let fifo = dir.join("gate");
    let path = std::ffi::CString::new(fifo.to_str().unwrap()).unwrap();
    // SAFETY: a new path in this test's own folder.
    assert_eq!(unsafe { libc::mkfifo(path.as_ptr(), 0o600) }, 0);
    let (h, s, words) = (hub.clone(), session.clone(), format!("gate: {}", fifo.display()));
    let turn = tokio::spawn(async move { h.prompt(&s, text(&words), "test", false).await });
    until(|| session.turn().is_some()).await;
    (fifo, turn)
}

async fn open(fifo: std::path::PathBuf) {
    tokio::task::spawn_blocking(move || std::fs::write(fifo, b"go")).await.unwrap().unwrap();
}

/// A prompt queued while Computer Use was unknown is refused when it starts once the app says
/// it needs setup: logged `prompt_refused`, its `queued` record keeping its words, and never
/// written to the agent.
#[tokio::test]
async fn a_queued_computer_use_prompt_is_refused_when_it_starts() {
    let hub = hub_with(false);
    let session = chat(&hub).await;
    let (fifo, first) = gated_turn(&hub, &session).await;
    let (tx, rx) = tokio::sync::oneshot::channel();
    let opts = PromptOptions {
        prompt_id: Some("q-cu".into()),
        on_accepted: Some(Box::new(move |v| {
            let _ = tx.send(v);
        })),
        ..Default::default()
    };
    let (h, s) = (hub.clone(), session.clone());
    let queued =
        tokio::spawn(async move { h.prompt_with(&s, text(ASKS), "test", false, opts).await });
    let accepted = tokio::time::timeout(Duration::from_secs(20), rx).await.unwrap().unwrap();
    assert_eq!(accepted["queued"], true, "{accepted}");

    hub.computer_use_gate.set(Some("needs_setup"));
    open(fifo).await;
    first.await.unwrap().unwrap();
    let e = queued.await.unwrap().unwrap_err();
    refused_for(&e, "needs_setup");

    let events = hub.events(&session.id, 0, 10_000).unwrap();
    let of = |kind: &'static str| {
        events.iter().filter(move |r| r.kind == kind && r.msg["promptId"] == "q-cu").count()
    };
    assert_eq!(of("prompt_refused"), 1);
    assert_eq!(of("turn_started"), 0, "it never started a turn");
    let words = events.iter().find(|r| r.kind == "queued" && r.msg["promptId"] == "q-cu");
    assert_eq!(
        words.map(|r| r.msg["text"].clone()),
        Some(json!(ASKS)),
        "its words stay in the log"
    );
    assert!(session.queue().is_empty());
    hub.shutdown_all().await;
}

/// A steer into a running turn is held too.
#[tokio::test]
async fn a_computer_use_steer_is_refused() {
    let hub = hub_with(true);
    let session = chat(&hub).await;
    let (fifo, first) = gated_turn(&hub, &session).await;
    hub.computer_use_gate.set(Some("starting"));
    let e = hub.prompt(&session, text(ASKS), "test", true).await.unwrap_err();
    refused_for(&e, "starting");
    open(fifo).await;
    first.await.unwrap().unwrap();
    hub.shutdown_all().await;
}

/// A queue edit that writes `@computer-use` is refused and the prompt keeps its words; Send now
/// and `interrupt` of a prompt that names it leave it queued. Once ready, the edit goes.
#[tokio::test]
async fn a_queue_edit_send_now_or_interrupt_naming_computer_use_is_refused() {
    let hub = hub_with(false);
    let session = chat(&hub).await;
    queue(&hub, &session, "q-1", "waiting");
    hub.computer_use_gate.set(Some("disabled"));
    let edit = json!({"sessionId": session.id, "promptId": "q-1", "op": "update", "text": ASKS});
    let e = hub.queue_edit(&session, &edit, Control::Local, false, None).await.unwrap_err();
    refused_for(&e, "disabled");
    assert_eq!(session.queue()[0].preview, "waiting");

    hub.computer_use_gate.set(Some("ready"));
    hub.queue_edit(&session, &edit, Control::Local, false, None).await.unwrap();
    assert_eq!(session.queue()[0].preview, ASKS);

    hub.computer_use_gate.set(Some("unavailable"));
    for op in ["send_now", "interrupt"] {
        let ask = json!({"sessionId": session.id, "promptId": "q-1", "op": op});
        let e = hub.queue_edit(&session, &ask, Control::Local, false, None).await.unwrap_err();
        refused_for(&e, "unavailable");
        assert_eq!(session.queue().len(), 1, "{op} took it out of the queue");
    }
    hub.shutdown_all().await;
}

/// A Retry rebuilds the failed turn's words; while they name `@computer-use` and Computer Use is
/// not ready it is refused and the failed turn stays failed. Ready, the retry goes.
#[tokio::test]
async fn a_retry_of_a_computer_use_prompt_waits_for_ready() {
    let hub = hub_with(false);
    let session = chat(&hub).await;
    let failed = hub.prompt(&session, text(&format!("fail: {ASKS}")), "test", false).await;
    assert!(failed.is_err(), "{failed:?}");
    let status =
        |s: &Session| s.meta().last_turn.and_then(|t| t["status"].as_str().map(str::to_owned));
    until(|| status(&session).as_deref() == Some("failed")).await;

    hub.computer_use_gate.set(Some("needs_setup"));
    let by = || RetryBy {
        control: Control::Local,
        trust_gate: false,
        full_access_device: None,
        from: None,
    };
    let e = hub.retry(&session, None, by()).await.unwrap_err();
    refused_for(&e, "needs_setup");
    assert_eq!(status(&session).as_deref(), Some("failed"));

    hub.computer_use_gate.set(Some("ready"));
    let v = hub.retry(&session, None, by()).await.expect("a retry once ready");
    assert!(v["promptId"].as_str().is_some(), "{v}");
    hub.shutdown_all().await;
}

/// `/btw` that names `@computer-use` is refused before a side session is made.
#[tokio::test]
async fn a_computer_use_side_question_is_refused() {
    let hub = hub_with(false);
    let session = chat(&hub).await;
    hub.computer_use_gate.set(Some("needs_setup"));
    let before = hub.sessions().len();
    let e = hub
        .btw(&session, ASKS, None, None, "test", false, PromptOptions::default())
        .await
        .unwrap_err();
    refused_for(&e, "needs_setup");
    assert_eq!(hub.sessions().len(), before, "a side session was made");
    hub.shutdown_all().await;
}

/// Unknown (an older app) and ready hold nothing.
#[tokio::test]
async fn an_unknown_or_ready_state_holds_nothing() {
    let hub = hub_with(false);
    let session = chat(&hub).await;
    hub.prompt(&session, text(ASKS), "test", false).await.expect("unknown holds nothing");
    hub.computer_use_gate.set(Some("ready"));
    hub.prompt(&session, text(ASKS), "test", false).await.expect("ready holds nothing");
    hub.computer_use_gate.set(Some("needs_setup"));
    hub.prompt(&session, text("open it with @browser-use"), "test", false)
        .await
        .expect("another tool is not held");
    hub.shutdown_all().await;
}

/// Another agent's message that names `@computer-use` in passing is not the person asking for it:
/// it starts while Computer Use is not ready.
#[tokio::test]
async fn another_agents_message_naming_computer_use_is_not_held() {
    let hub = hub_with(false);
    let session = chat(&hub).await;
    hub.computer_use_gate.set(Some("needs_setup"));
    let opts = PromptOptions {
        prompt_id: Some("agent-msg".into()),
        agent: Some("reviewer".into()),
        provenance: Some(crate::prompt_provenance::named_sender("reviewer", &session.id)),
        ..Default::default()
    };
    let answer = hub.prompt_with(&session, text(ASKS), "test", false, opts).await;
    assert!(answer.is_ok(), "{answer:?}");
    hub.shutdown_all().await;
}
