//! What keeps a session awake (`idle_eligible`): each of the gates a hub test can hold by hand.

use super::*;
use crate::config::{Config, StoreMode};
use std::path::Path;

async fn chat() -> (Arc<Hub>, Arc<Session>) {
    let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
    let mut cfg: Config = serde_json::from_value(json!({
        "harnesses": {"fake": {"argv": ["python3", fake]}},
        "defaultHarness": "fake",
    }))
    .unwrap();
    cfg.store.mode = StoreMode::Memory;
    let store = crate::store::open(&cfg.store, Path::new("/nonexistent")).unwrap();
    let hub = Hub::new(cfg, store);
    let req = NewRequest { cwd: Some(std::env::temp_dir()), ..NewRequest::default() };
    let session = hub.new_session(req).await.unwrap();
    (hub, session)
}

/// A ready chat with nothing going on is idle; an agent request waiting on its answer, a
/// sub-session at work, a stored-less Claude chat with turns, and a queued prompt each keep it.
#[tokio::test]
async fn each_gate_keeps_a_session_awake() {
    let (hub, session) = chat().await;
    assert!(hub.idle_eligible(&session), "a ready chat with nothing going on");
    {
        let _asked = AgentRequest::new(&session);
        assert!(!hub.idle_eligible(&session), "an agent request on its way");
    }
    assert!(hub.idle_eligible(&session));
    *session.work_below_since.lock().unwrap() = 1;
    assert!(!hub.idle_eligible(&session), "a sub-session at work");
    *session.work_below_since.lock().unwrap() = 0;
    {
        let mut m = session.meta.lock().unwrap();
        m.claude_unstored = true;
        m.turn_count = 1;
    }
    assert!(!hub.idle_eligible(&session), "a Claude chat whose turns are not stored");
    session.meta.lock().unwrap().claude_unstored = false;
    session.queued.fetch_add(1, Ordering::SeqCst);
    assert!(!hub.idle_eligible(&session), "a queued prompt");
    session.queued.fetch_sub(1, Ordering::SeqCst);
    assert!(hub.idle_eligible(&session));
    hub.shutdown_all().await;
}

/// A chat stored as hibernated comes back marked (it wakes on a click after a restart), and
/// clearing the hibernation drops the mark, a cause a wake recorded, and the stored flag.
#[tokio::test]
async fn a_stored_hibernation_comes_back_and_clearing_it_drops_every_trace() {
    let (hub, session) = chat().await;
    let mut meta = session.meta();
    meta.hibernated_ms = 1;
    meta.id = format!("{}-restored", meta.id);
    let restored = hub.make_session(meta);
    assert_ne!(restored.hibernated_at.load(Ordering::SeqCst), 0, "a restart lost the hibernation");
    hub.wake_cause(&restored, "click");
    hub.clear_hibernation(&restored);
    assert_eq!(restored.hibernated_at.load(Ordering::SeqCst), 0);
    assert!(restored.wake_cause.lock().unwrap().is_none(), "a stale wake cause");
    assert_eq!(restored.meta().hibernated_ms, 0);
    hub.shutdown_all().await;
}

/// A daemon still loading never counts as unused (`in_use`): each load it finishes after its
/// start keeps it, so a queued prompt or cut turn the last daemon left is resumed first.
#[tokio::test]
async fn a_daemon_still_loading_is_in_use() {
    let (hub, _session) = chat().await;
    for (gate, name) in [
        (&hub.startup_ready, "startup"),
        (&hub.adoption_ready, "adoption"),
        (&hub.logs_ready, "the chat logs"),
        (&hub.store_load.ready, "the store"),
    ] {
        gate.send_replace(false);
        assert_eq!(hub.in_use().await, Some("its startup"), "{name} still loading");
        gate.send_replace(true);
    }
}

/// A chat moving to another machine keeps the daemon until the move is committed or aborted: its
/// watch settles it, and the chat stays frozen here until then. A chat that moved away does not.
#[tokio::test]
async fn a_move_under_way_is_in_use() {
    let (hub, session) = chat().await;
    *session.moving.lock().unwrap() = Some("t-1".into());
    assert_eq!(hub.in_use().await, Some("a move under way"));
    session.meta.lock().unwrap().moved_to = Some(json!({}));
    assert_ne!(hub.in_use().await, Some("a move under way"), "a committed move");
}

/// A Cloud machine's activity counts each session at work (`sessions_at_work`): a running turn
/// (the harness's own), a queued prompt and an agent request each count it once; with none, it
/// is not at work.
#[tokio::test]
async fn sessions_at_work_counts_a_running_turn_until_it_ends() {
    let (hub, session) = chat().await;
    assert_eq!(hub.sessions_at_work(), 0, "a ready chat with nothing going on");
    session.harness_turn.store(true, Ordering::SeqCst);
    assert_eq!(hub.sessions_at_work(), 1, "a running turn");
    session.queued.fetch_add(1, Ordering::SeqCst);
    assert_eq!(hub.sessions_at_work(), 1, "one session, however much it does");
    session.harness_turn.store(false, Ordering::SeqCst);
    assert_eq!(hub.sessions_at_work(), 1, "a queued prompt");
    session.queued.fetch_sub(1, Ordering::SeqCst);
    {
        let _asked = AgentRequest::new(&session);
        assert_eq!(hub.sessions_at_work(), 1, "an agent request on its way");
    }
    assert_eq!(hub.sessions_at_work(), 0, "the turn ended");
    *session.work_below_since.lock().unwrap() = 1;
    assert_eq!(hub.sessions_at_work(), 1, "a sub-session or background subagent at work");
    *session.work_below_since.lock().unwrap() = 0;
    assert_eq!(hub.sessions_at_work(), 0);
    hub.shutdown_all().await;
}

/// cmux#33327: a shell the harness left running in the background after its turn ended (a Claude
/// background shell) keeps its session at work, so a Cloud machine is not paused under it.
#[tokio::test]
async fn sessions_at_work_counts_a_background_process_the_turn_left_running() {
    let (hub, session) = chat().await;
    assert_eq!(hub.sessions_at_work(), 0);
    let shell = |state: &str| json!({"jsonrpc": "2.0", "method": "session/update", "params": {"sessionId": "own", "update": {"sessionUpdate": "background_task_update", "toolCallId": "bg", "taskId": "bg", "state": state, "command": "serve"}}});
    let rec = hub.append(&session, "in", "background_task_update", shell("running"));
    hub.note_process(&session, &rec, None);
    assert_eq!(hub.sessions_at_work(), 1, "a background shell still running");
    let rec = hub.append(&session, "in", "background_task_update", shell("completed"));
    hub.note_process(&session, &rec, None);
    assert_eq!(hub.sessions_at_work(), 0, "the shell ended");
    hub.shutdown_all().await;
}

/// cmux#34298: the activity report's phases read what holds each session at work: its turn,
/// and the processes it left running.
#[tokio::test]
async fn sessions_at_work_detail_says_what_holds_each_session() {
    let (hub, session) = chat().await;
    assert!(hub.sessions_at_work_detail().is_empty());
    session.harness_turn.store(true, Ordering::SeqCst);
    let detail = hub.sessions_at_work_detail();
    assert_eq!(detail.len(), 1);
    assert!(detail[0].turn && !detail[0].person && detail[0].processes == 0);
    assert_eq!(detail[0].id, session.id);
    session.harness_turn.store(false, Ordering::SeqCst);
    let shell = |state: &str| json!({"jsonrpc": "2.0", "method": "session/update", "params": {"sessionId": "own", "update": {"sessionUpdate": "background_task_update", "toolCallId": "bg", "taskId": "bg", "state": state, "command": "serve"}}});
    let rec = hub.append(&session, "in", "background_task_update", shell("running"));
    hub.note_process(&session, &rec, None);
    let detail = hub.sessions_at_work_detail();
    assert_eq!(detail.len(), hub.sessions_at_work());
    assert!(!detail[0].turn && detail[0].processes == 1, "a background shell, no turn");
    let rec = hub.append(&session, "in", "background_task_update", shell("completed"));
    hub.note_process(&session, &rec, None);
    assert!(hub.sessions_at_work_detail().is_empty());
    hub.shutdown_all().await;
}

/// cmux#33328: the Cloud activity report waits on the same startup gates as `in_use`.
#[tokio::test]
async fn startup_settles_only_once_every_load_is_done() {
    let (hub, _session) = chat().await;
    assert!(hub.startup_settled());
    for (gate, name) in [
        (&hub.startup_ready, "startup"),
        (&hub.adoption_ready, "adoption"),
        (&hub.logs_ready, "the chat logs"),
        (&hub.store_load.ready, "the store"),
    ] {
        gate.send_replace(false);
        assert!(!hub.startup_settled(), "{name} still loading");
        gate.send_replace(true);
    }
    assert!(hub.startup_settled());
}
