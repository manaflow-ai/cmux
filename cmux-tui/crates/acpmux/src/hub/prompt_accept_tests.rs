//! Fuzz row g, g1: a prompt that comes while another prompt holds the chat's turn lock and has
//! not shown its turn yet (`start_turn` runs after awaits) is accepted at once, queued next, not
//! after that whole turn (`queue.rs` `queue_slot`, `Session::turn_claimed`).

use super::*;
use std::time::Duration;

const WAIT: Duration = Duration::from_secs(20);

/// A hub with one open chat on the stand-in agent, its store in memory.
async fn chat() -> (Arc<Hub>, Arc<Session>) {
    chat_with_store(None).await
}

async fn chat_with_store(store: Option<Box<dyn crate::store::Store>>) -> (Arc<Hub>, Arc<Session>) {
    use crate::config::{Config, StoreMode};
    let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
    let cfg = json!({"harnesses": {"fake": {"argv": ["python3", fake]}}, "defaultHarness": "fake"});
    let mut cfg: Config = serde_json::from_value(cfg).unwrap();
    cfg.store.mode = StoreMode::Memory;
    let store = store.unwrap_or_else(|| {
        crate::store::open(&cfg.store, std::path::Path::new("/nonexistent")).unwrap()
    });
    let hub = Hub::new(cfg, store);
    let req = NewRequest { cwd: Some(std::env::temp_dir()), ..NewRequest::default() };
    let session = hub.new_session(req).await.unwrap();
    (hub, session)
}

/// The person's prompt `text` under `prompt_id`; its acceptance goes to `accepted`.
fn prompt(
    hub: &Arc<Hub>,
    s: &Arc<Session>,
    prompt_id: &str,
    text: &str,
    accepted: tokio::sync::oneshot::Sender<Value>,
) -> tokio::task::JoinHandle<Result<Value, RpcError>> {
    let opts = PromptOptions {
        prompt_id: Some(prompt_id.to_owned()),
        on_accepted: Some(Box::new(move |v| {
            let _ = accepted.send(v);
        })),
        ..PromptOptions::default()
    };
    let blocks = vec![json!({"type": "text", "text": text})];
    let (hub, s) = (hub.clone(), s.clone());
    tokio::spawn(async move { hub.prompt_with(&s, blocks, "test", false, opts).await })
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_prompt_behind_one_about_to_start_its_turn_is_accepted_queued_at_once() {
    let (hub, s) = chat().await;
    // The first prompt holds the turn lock, stopped before its turn shows.
    let (arrived_tx, arrived) = tokio::sync::oneshot::channel();
    let (release, release_rx) = tokio::sync::oneshot::channel::<()>();
    *hub.prompt_start_seam.lock().unwrap() = Some((arrived_tx, release_rx));
    let (first_tx, first_accepted) = tokio::sync::oneshot::channel();
    let first = prompt(&hub, &s, "g1-a", "first", first_tx);
    tokio::time::timeout(WAIT, arrived).await.unwrap().unwrap();
    assert!(s.turn().is_none(), "the first prompt has not shown its turn");

    // The second is accepted while the first still holds the chat: queued, next.
    let (second_tx, second_accepted) = tokio::sync::oneshot::channel();
    let second = prompt(&hub, &s, "g1-b", "second", second_tx);
    let accepted = tokio::time::timeout(WAIT, second_accepted)
        .await
        .expect("the second prompt is accepted before the first turn ends")
        .unwrap();
    assert!(s.turn().is_none(), "accepted while the first prompt still waits to start");
    assert_eq!(
        (&accepted["queued"], &accepted["state"], &accepted["position"]),
        (&json!(true), &json!("queued"), &json!(1)),
        "{accepted}"
    );
    let queued = hub.events(&s.id, 0, 10_000).unwrap();
    assert!(
        queued.iter().any(|r| r.kind == "queued" && r.msg["promptId"] == "g1-b"),
        "its queued record is in the journal when it is accepted"
    );

    // Both run, in order.
    release.send(()).unwrap();
    let started = tokio::time::timeout(WAIT, first_accepted).await.unwrap().unwrap();
    assert_eq!((&started["queued"], &started["state"]), (&json!(false), &json!("started")));
    for done in [first, second] {
        let r = tokio::time::timeout(WAIT, done).await.unwrap().unwrap().unwrap();
        assert_eq!(r["stopReason"], "end_turn", "{r}");
    }
    let order: Vec<Value> = hub
        .events(&s.id, 0, 10_000)
        .unwrap()
        .into_iter()
        .filter(|r| r.kind == "user_message")
        .map(|r| r.msg["promptId"].clone())
        .collect();
    assert_eq!(order, [json!("g1-a"), json!("g1-b")]);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn exact_prompt_stop_fences_admission_before_turn_without_stopping_next_person() {
    let (hub, session) = chat().await;
    let (arrived_tx, arrived) = tokio::sync::oneshot::channel();
    let (release, release_rx) = tokio::sync::oneshot::channel();
    *hub.prompt_start_seam.lock().unwrap() = Some((arrived_tx, release_rx));
    let (accepted_tx, _accepted) = tokio::sync::oneshot::channel();
    let stopped = prompt(&hub, &session, "workflow-dequeued", "must not reach agent", accepted_tx);
    tokio::time::timeout(WAIT, arrived).await.unwrap().unwrap();
    assert!(session.turn().is_none());
    hub.cancel_prompt(&session, "workflow-dequeued").await.unwrap();
    release.send(()).unwrap();
    let result = tokio::time::timeout(WAIT, stopped).await.unwrap().unwrap();
    assert!(result.is_err() || result.unwrap()["stopReason"] == "cancelled");
    assert!(
        !hub.events(&session.id, 0, 10000)
            .unwrap()
            .iter()
            .any(|event| event.kind == "user_message"
                && event.msg["promptId"] == "workflow-dequeued")
    );
    let (accepted_tx, _accepted) = tokio::sync::oneshot::channel();
    let next = prompt(&hub, &session, "person-after-pause", "person next", accepted_tx);
    assert_eq!(
        tokio::time::timeout(WAIT, next).await.unwrap().unwrap().unwrap()["stopReason"],
        "end_turn"
    );
    // Reconstruct the lazy cache as after a daemon restart: the fence is durable.
    hub.clear_prompt_stop_cache_for_test(&session);
    let turn = TurnInfo::prompted(
        "workflow",
        "replay",
        "new-turn",
        "workflow-dequeued~resume-1",
        Control::Local,
    );
    assert!(hub.start_turn(&session, None, false, false, turn).is_err());
    hub.shutdown_all().await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn exact_prompt_stop_survives_malformed_lines_and_an_unterminated_log_tail() {
    use std::io::Write;
    let directory = cmux_unix_socket::short_test_dir("prompt-stop-corrupt");
    let store = crate::store::LocalStore::new(directory.path().to_owned(), 1 << 20).unwrap();
    let (hub, session) = chat_with_store(Some(Box::new(store))).await;
    let (arrived_tx, arrived) = tokio::sync::oneshot::channel();
    let (release, release_rx) = tokio::sync::oneshot::channel();
    *hub.prompt_start_seam.lock().unwrap() = Some((arrived_tx, release_rx));
    let (accepted_tx, _accepted) = tokio::sync::oneshot::channel();
    let stopped = prompt(&hub, &session, "workflow-torn", "must not reach agent", accepted_tx);
    tokio::time::timeout(WAIT, arrived).await.unwrap().unwrap();
    hub.store.flush_session(&session.id).unwrap();
    hub.store.close_log(&session.id);
    let path = directory.path().join(&session.id).join("events").join("000001.ndjson");
    let mut log = std::fs::OpenOptions::new().append(true).open(path).unwrap();
    // Existing malformed history must not freeze the chat. A real truncated final line
    // also joins the next append: acknowledgement must prove the stop can be read back.
    log.write_all(b"{malformed history}\n{\"seq\":999").unwrap();
    log.sync_all().unwrap();
    drop(log);
    hub.cancel_prompt(&session, "workflow-torn").await.unwrap();
    release.send(()).unwrap();
    let result = tokio::time::timeout(WAIT, stopped).await.unwrap().unwrap();
    assert!(result.is_err() || result.unwrap()["stopReason"] == "cancelled");

    let (accepted_tx, _accepted) = tokio::sync::oneshot::channel();
    let next = prompt(&hub, &session, "person-after-torn", "person next", accepted_tx);
    assert_eq!(
        tokio::time::timeout(WAIT, next).await.unwrap().unwrap().unwrap()["stopReason"],
        "end_turn"
    );
    hub.clear_prompt_stop_cache_for_test(&session);
    let turn = TurnInfo::prompted(
        "workflow",
        "late retry",
        "retry-turn",
        "workflow-torn~resume-1",
        Control::Local,
    );
    assert!(
        hub.start_turn(&session, None, false, false, turn).is_err(),
        "acknowledged stop was lost inside the malformed tail"
    );
    hub.shutdown_all().await;
}
