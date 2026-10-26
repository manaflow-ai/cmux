//! The order of a failed subagent's retry records when Stop, close and the retry's own task
//! race (`subagent_retry.rs`, `Retries::steps`). Each test drives the hub's observer directly,
//! so the interleaving is fixed: the spawned retry task runs only when the test awaits.

use super::*;
use crate::config::{Config, StoreMode};
use crate::rpc::{Message, method};
use std::path::Path;
use tokio::sync::mpsc;

/// A hub with one chat (a stand-in agent) and `delays` as `autoResumeDelaysMs`.
async fn chat(delays: Vec<u64>) -> (Arc<Hub>, Arc<Session>, mpsc::Sender<String>) {
    let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
    let mut cfg: Config = serde_json::from_value(json!({
        "harnesses": {"fake": {"argv": ["python3", fake]}},
        "defaultHarness": "fake",
    }))
    .unwrap();
    cfg.store.mode = StoreMode::Memory;
    cfg.auto_resume_delays_ms = Some(delays);
    let store = crate::store::open(&cfg.store, Path::new("/nonexistent")).unwrap();
    let hub = Hub::new(cfg, store);
    let (in_tx, in_rx) = mpsc::channel(8);
    let (out_tx, mut out_rx) = mpsc::channel(256);
    tokio::spawn(crate::server::serve_connection_with(
        hub.clone(),
        in_rx,
        out_tx,
        crate::server::Origin::Local,
    ));
    let new = json!({"cwd": std::env::temp_dir(), "mcpServers": []});
    in_tx.send(Message::request(1, method::SESSION_NEW, new).to_line()).await.unwrap();
    loop {
        let reply: Value = serde_json::from_str(&out_rx.recv().await.unwrap()).unwrap();
        if reply["id"] == 1 {
            let session = hub.resolve(reply["result"]["sessionId"].as_str().unwrap()).unwrap();
            return (hub, session, in_tx);
        }
    }
}

/// A top-level subagent's end on SR2's 503, as the subagent tree reports it.
fn failed(id: &str) -> Value {
    json!({"id": id, "parent": null, "state": "failed", "task": "Push relay",
        "agentId": format!("agent-{id}"),
        "error": "API Error: 503 no non-exhausted claude accounts available"})
}

/// The chat's `subagent_retry` outcomes, `skipped:<why>` for a skip.
fn outcomes(hub: &Hub, session: &Session) -> Vec<String> {
    let records = hub.events(&session.id, 0, 10_000).unwrap();
    records
        .into_iter()
        .filter(|e| e.kind == "subagent_retry")
        .map(|e| match e.msg["skipped"].as_str() {
            Some(why) => format!("skipped:{why}"),
            None => e.msg["outcome"].as_str().unwrap_or_default().to_owned(),
        })
        .collect()
}

/// The subagent's last entry acpmux logged.
fn last_entry(hub: &Hub, session: &Session, id: &str) -> Option<Value> {
    let records = hub.events(&session.id, 0, 10_000).unwrap();
    records
        .into_iter()
        .rev()
        .filter_map(|e| e.msg.pointer("/params/_meta/acpmux/subagents/0").cloned())
        .find(|e| e["id"] == id && e.get("retryable").is_some())
}

/// Lets the spawned retry tasks run.
async fn settle() {
    tokio::time::sleep(Duration::from_millis(150)).await;
}

/// Stop before the first wait is planned: nothing is scheduled, fired or given up after it.
#[tokio::test]
async fn stop_before_the_first_wait_is_planned_leaves_no_later_record() {
    // `[0]`: it would fire at once; `[]`: it would be given up at once.
    for delays in [vec![0], vec![]] {
        let (hub, session, _conn) = chat(delays.clone()).await;
        hub.observe_subagents(&session, &[failed("s/t1")]);
        hub.stop_subagent_retries(&session, false);
        settle().await;
        assert_eq!(outcomes(&hub, &session), Vec::<String>::new(), "{delays:?}");
        let entry = last_entry(&hub, &session, "s/t1").expect("its entry after the Stop");
        assert_eq!((&entry["state"], &entry["retryable"]), (&json!("failed"), &json!(true)));
    }
}

/// Stop while the wait runs: skipped, and the woken task never fires it afterwards.
#[tokio::test]
async fn a_stopped_wait_never_fires_once_woken() {
    let (hub, session, _conn) = chat(vec![60_000]).await;
    hub.observe_subagents(&session, &[failed("s/t1")]);
    settle().await;
    assert_eq!(outcomes(&hub, &session), ["scheduled"]);
    let wake = {
        let all = hub.subagent_retries.lock();
        let failed = all.subs[&session.id]["s/t1"].failed.as_ref().unwrap();
        failed.wait.as_ref().unwrap().wake.clone()
    };
    hub.stop_subagent_retries(&session, false);
    wake.notify_one();
    settle().await;
    assert_eq!(outcomes(&hub, &session), ["scheduled", "skipped:stopped"]);
    let users = hub.events(&session.id, 0, 10_000).unwrap();
    assert!(!users.iter().any(|e| e.kind == "user_message"), "no retry prompt went out");
}

/// A failure that arrives while the chat closes (`closing` set, its retries taken) is not
/// retried.
#[tokio::test]
async fn a_failure_while_the_chat_closes_is_not_retried() {
    let (hub, session, _conn) = chat(vec![0]).await;
    session.closing.store(true, Ordering::SeqCst);
    hub.stop_subagent_retries(&session, true);
    hub.observe_subagents(&session, &[failed("s/t1")]);
    settle().await;
    assert_eq!(outcomes(&hub, &session), Vec::<String>::new());
    assert!(!hub.subagent_retries.lock().subs.contains_key(&session.id), "nothing kept");
}

/// A wait planned before close began is skipped by close and never fires.
#[tokio::test]
async fn close_after_the_wait_was_planned_skips_it() {
    let (hub, session, _conn) = chat(vec![60_000]).await;
    hub.observe_subagents(&session, &[failed("s/t1")]);
    settle().await;
    session.closing.store(true, Ordering::SeqCst);
    hub.stop_subagent_retries(&session, true);
    hub.observe_subagents(&session, &[failed("s/t2")]);
    settle().await;
    assert_eq!(outcomes(&hub, &session), ["scheduled", "skipped:closed"]);
    let entry = last_entry(&hub, &session, "s/t1").unwrap();
    assert_eq!(entry["retryable"], false, "{entry}");
}

/// Sends a prompt as a subagent retry does, with `prompt_id`.
fn send(
    hub: &Arc<Hub>,
    session: &Arc<Session>,
    prompt_id: &str,
) -> tokio::task::JoinHandle<Result<Value, RpcError>> {
    let (hub, session) = (hub.clone(), session.clone());
    let opts = PromptOptions { prompt_id: Some(prompt_id.to_owned()), ..PromptOptions::default() };
    let blocks = vec![json!({"type": "text", "text": "Resume it"})];
    tokio::spawn(async move { hub.prompt_with(&session, blocks, "acpmux", false, opts).await })
}

/// A sent retry prompt (`fire_wait` records it) about to start while Claude Code runs a turn of
/// its own: it waits for that turn's end, then starts.
#[tokio::test]
async fn a_retry_prompt_waits_out_claudes_own_turn_at_its_start() {
    let (hub, session, _conn) = chat(vec![60_000]).await;
    let key = (session.id.clone(), "subagent-retry-t1-1".to_owned());
    hub.subagent_retries.lock().sent.insert(key.clone(), false);
    session.harness_turn.store(true, Ordering::SeqCst);
    let sent = send(&hub, &session, &key.1);
    settle().await;
    assert!(!sent.is_finished(), "it started inside Claude Code's own turn");
    assert!(session.turn().is_none());
    // That turn's `result`.
    session.harness_turn.store(false, Ordering::SeqCst);
    hub.append(&session, "mux", "test_tick", json!({}));
    sent.await.unwrap().expect("it ran once that turn ended");
    // Another prompt never waits.
    session.harness_turn.store(true, Ordering::SeqCst);
    send(&hub, &session, "p-person").await.unwrap().expect("a person's prompt runs");
}

/// A retry skipped while its prompt waits to start is refused there.
#[tokio::test]
async fn a_retry_prompt_skipped_while_it_waits_to_start_is_refused() {
    let (hub, session, _conn) = chat(vec![60_000]).await;
    let key = (session.id.clone(), "subagent-retry-t1-1".to_owned());
    hub.subagent_retries.lock().sent.insert(key.clone(), false);
    session.harness_turn.store(true, Ordering::SeqCst);
    let sent = send(&hub, &session, &key.1);
    settle().await;
    hub.subagent_retries.lock().sent.insert(key, true);
    hub.append(&session, "mux", "test_tick", json!({}));
    let refused = sent.await.unwrap().unwrap_err();
    assert_eq!(refused.data.unwrap()["reason"], "subagent_retry.skipped");
    assert!(session.turn().is_none());
}
