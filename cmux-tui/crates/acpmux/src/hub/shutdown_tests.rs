//! A restart hands a running turn to the next daemon (`shutdown.rs`): the old daemon writes no end
//! of its own for it, whether the shutdown took the turn or its end was already under way, so the
//! next daemon finds the turn cut and continues it (`restart_resume.rs`).

use super::*;
use std::time::Duration;

const WAIT: Duration = Duration::from_secs(20);

/// A hub on the stand-in agent, its store in `dir`.
fn hub_in(dir: &std::path::Path) -> Arc<Hub> {
    use crate::config::{Config, StoreMode};
    let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
    let cfg = json!({"harnesses": {"fake": {"argv": ["python3", fake]}}, "defaultHarness": "fake"});
    let mut cfg: Config = serde_json::from_value(cfg).unwrap();
    cfg.store.mode = StoreMode::Local;
    let store = crate::store::open(&cfg.store, dir).unwrap();
    Hub::new(cfg, store)
}

/// The `kind` records of the chat's log.
fn records(hub: &Hub, s: &Session, kind: &str) -> Vec<Value> {
    let records = hub.events(&s.id, 0, 100_000).unwrap();
    records.into_iter().filter(|r| r.kind == kind).map(|r| r.msg).collect()
}

/// The turn's end was under way when the shutdown began (Sol review of #28503): its agent died,
/// `finish_turn` took the turn and is held there, so the shutdown finds no turn to take. Let go
/// after the shutdown began, the end writes nothing, and the next daemon continues the turn.
#[tokio::test]
async fn a_turn_whose_end_was_under_way_at_a_restart_is_continued_by_the_next_daemon() {
    let dir = std::env::temp_dir().join(format!("acpmux-handoff-{}", uuid::Uuid::now_v7()));
    let hub = hub_in(&dir);
    let req = NewRequest { cwd: Some(std::env::temp_dir()), ..NewRequest::default() };
    let s = hub.new_session(req).await.unwrap();
    let (arrived_tx, arrived) = tokio::sync::oneshot::channel();
    let (release, release_rx) = tokio::sync::oneshot::channel();
    *hub.finish_seam.lock().unwrap() = Some((arrived_tx, release_rx));
    let opts = PromptOptions { prompt_id: Some("p-cut".to_owned()), ..PromptOptions::default() };
    let blocks = vec![json!({"type": "text", "text": "die-later: gone"})];
    let turn = {
        let (hub, s) = (hub.clone(), s.clone());
        tokio::spawn(async move { hub.prompt_with(&s, blocks, "test", false, opts).await })
    };
    tokio::time::timeout(WAIT, arrived).await.unwrap().unwrap();
    assert!(s.turn().is_none(), "the end took the turn before the shutdown");
    hub.shutdown_all().await;
    let _ = release.send(());
    let answer = tokio::time::timeout(WAIT, turn).await.unwrap().unwrap();
    assert!(answer.is_err(), "{answer:?}");
    for kind in ["turn_result", "turn_error", "auto_resume_scheduled"] {
        let late = records(&hub, &s, kind);
        assert!(late.is_empty(), "the old daemon wrote a {kind} after the shutdown: {late:?}");
    }
    let id = s.id.clone();
    drop(s);
    drop(hub);

    let hub = hub_in(&dir);
    let s = hub.resolve(&id).unwrap();
    hub.session_log(&s).await;
    let queued = records(&hub, &s, "queued");
    assert!(
        queued.iter().any(|m| m["promptId"] == "p-cut~resume-1"),
        "the cut turn's continuation was not queued: {queued:?}"
    );
    hub.shutdown_all().await;
    let _ = std::fs::remove_dir_all(&dir);
}

/// A route switch asked during a turn moves the chat when the turn ends (`route_switch.rs`), but
/// not once a shutdown began (Sol review of #28503): the agent the shutdown left for the next
/// daemon (here one whose child it could not reach) stays alive, unkilled by a restart that could
/// not start it again anyway.
#[tokio::test]
async fn a_turn_ending_after_a_shutdown_began_leaves_the_kept_agent_to_the_next_daemon() {
    let dir = std::env::temp_dir().join(format!("acpmux-handoff-{}", uuid::Uuid::now_v7()));
    let hub = hub_in(&dir);
    let req = NewRequest { cwd: Some(std::env::temp_dir()), ..NewRequest::default() };
    let s = hub.new_session(req).await.unwrap();
    let (arrived_tx, arrived) = tokio::sync::oneshot::channel();
    let (release, release_rx) = tokio::sync::oneshot::channel();
    *hub.finish_seam.lock().unwrap() = Some((arrived_tx, release_rx));
    let blocks = vec![json!({"type": "text", "text": "hi"})];
    let turn = {
        let (hub, s) = (hub.clone(), s.clone());
        tokio::spawn(async move {
            hub.prompt_with(&s, blocks, "test", false, PromptOptions::default()).await
        })
    };
    tokio::time::timeout(WAIT, arrived).await.unwrap().unwrap();
    s.route_switch.store(true, Ordering::SeqCst);
    let child = s.child.lock().await.clone().expect("the turn's agent");
    {
        // The shutdown cannot reach this child: it keeps it for the next daemon.
        let _held = s.child.lock().await;
        hub.shutdown_all().await;
    }
    let _ = release.send(());
    let answer = tokio::time::timeout(WAIT, turn).await.unwrap().unwrap();
    assert!(answer.is_ok(), "{answer:?}");
    let kept = s.child.lock().await.clone();
    assert!(kept.is_some_and(|c| Arc::ptr_eq(&c, &child)), "the turn's end took the kept agent");
    assert!(child.is_alive().await, "the turn's end killed the agent the shutdown kept");
    child.kill().await;
    let _ = std::fs::remove_dir_all(&dir);
}
