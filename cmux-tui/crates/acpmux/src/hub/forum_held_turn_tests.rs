//! The moment between a turn showing (`start_turn`) and its prompt being built: the forum's rules
//! block (`forum_context`) is not written yet, so a rule posted then goes in with that prompt.
//! The forum tests hold a turn and post rules "behind" it (`tests/forum.rs` `Gate::hold`); they
//! may count it as running only once its prompt went out (`tests/support/held_turn.rs`), or the
//! held turn itself tells the rule they expect to wait behind it.

use super::forum::AnnounceRequest;
use super::*;
use crate::forum::Author;
use std::time::Duration;

#[path = "../../tests/support/held_turn.rs"]
mod held_turn;

const WAIT: Duration = Duration::from_secs(20);

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

fn prompt(
    hub: &Arc<Hub>,
    s: &Arc<Session>,
    text: &str,
) -> tokio::task::JoinHandle<Result<Value, RpcError>> {
    let (hub, s) = (hub.clone(), s.clone());
    let blocks = vec![json!({"type": "text", "text": text})];
    tokio::spawn(async move { hub.prompt(&s, blocks, "test", false).await })
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_turn_that_shows_before_its_prompt_is_built_does_not_count_as_held() {
    let (hub, s) = chat().await;
    tokio::time::timeout(WAIT, prompt(&hub, &s, "warm up")).await.unwrap().unwrap().unwrap();
    let (arrived_tx, arrived) = tokio::sync::oneshot::channel();
    let (release, release_rx) = tokio::sync::oneshot::channel::<()>();
    *hub.turn_shown_seam.lock().unwrap() = Some((arrived_tx, release_rx));
    let held = prompt(&hub, &s, "held");
    tokio::time::timeout(WAIT, arrived).await.unwrap().unwrap();
    // The named moment: the turn shows (`wait --until running` resolves on it), its prompt and
    // rules block are not built.
    assert!(s.turn().is_some(), "the held turn shows");
    let summary = hub.session_summary(&s);
    assert_ne!(summary["status"], "running", "the prompt went out already: {summary}");
    let counted = held_turn::prompt_sent(&summary);
    // A rule posted in this moment is told by the held turn itself.
    let rule = AnnounceRequest {
        key: "disk".into(),
        body: "Keep target dirs small.".into(),
        topic: None,
        urgent: false,
        retire: false,
    };
    hub.forum_announce(Author::Person { account: "leo".into() }, rule).await.unwrap();
    release.send(()).unwrap();
    let r = tokio::time::timeout(WAIT, held).await.unwrap().unwrap().unwrap();
    assert_eq!(r["stopReason"], "end_turn", "{r}");
    let rules = hub.forum_rules();
    let disk = rules["rules"].as_array().unwrap().iter().find(|r| r["key"] == "disk").unwrap();
    assert_eq!(disk["delivered"][0]["sessionId"], json!(s.id), "{disk}");
    assert!(
        !counted,
        "a test counted the held turn as running before its prompt was built: {summary}"
    );
    hub.shutdown_all().await;
}
