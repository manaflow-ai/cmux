//! What keeps a client-less daemon from its idle exit, on a real hub
//! (`cargo test -p acpmux idle_exit`): each kind of live agent work counts in
//! `Hub::live_agent_count` or `Hub::live_process_count`, and with one in
//! place the exit waits past the grace on a manual clock.

use super::*;
use crate::clock::ManualClock;
use crate::daemon_lifecycle::{HubLiveness, IDLE_EXIT_GRACE, wait_for_daemon_exit};
use cmux_owner_liveness::OwnerLiveness;

fn hub() -> Arc<Hub> {
    let mut cfg = crate::config::Config::default();
    cfg.store.mode = crate::config::StoreMode::Memory;
    let store = crate::store::open(&cfg.store, std::path::Path::new("/nonexistent")).unwrap();
    Hub::new(cfg, store)
}

/// A chat with nothing running, registered on `hub`.
fn chat(hub: &Arc<Hub>, id: &str) -> Arc<Session> {
    let meta: SessionMeta = serde_json::from_value(json!({
        "schema": "acpmux.session.v1",
        "id": id,
        "name": id,
        "harness": "claude",
        "family": "claude",
        "cwd": "/tmp",
        "status": "idle",
        "createdAt": 1,
        "updatedAt": 2,
    }))
    .unwrap();
    let session = hub.make_session(meta);
    hub.sessions.lock().unwrap().insert(id.to_owned(), session.clone());
    session
}

fn turn(turn_id: &str) -> TurnInfo {
    TurnInfo::prompted("test", "build it", turn_id, "p1", Control::Local)
}

async fn settle() {
    for _ in 0..16 {
        tokio::task::yield_now().await;
    }
}

/// Whether the idle exit resolves within three graces on a manual clock.
async fn exits_within_three_graces(hub: &Arc<Hub>) -> bool {
    let clock = ManualClock::new();
    let exit = {
        let (hub, clock) = (hub.clone(), clock.clone());
        tokio::spawn(async move {
            // No app named this daemon, and `leftoverDaemonIdleExit` is on.
            let liveness = HubLiveness { hub: hub.clone(), owner: OwnerLiveness::new(None) };
            wait_for_daemon_exit(&hub.clients, clock, &liveness, false).await;
        })
    };
    for _ in 0..3 {
        settle().await;
        clock.advance(IDLE_EXIT_GRACE);
        settle().await;
    }
    let exited = exit.is_finished();
    exit.abort();
    exited
}

#[tokio::test]
async fn idle_exit_an_idle_chat_keeps_nothing() {
    let hub = hub();
    chat(&hub, "idle");
    assert_eq!(hub.live_agent_count(), 0);
    assert_eq!(hub.live_process_count(), 0);
    assert!(exits_within_three_graces(&hub).await, "an idle chat kept the daemon");
}

#[tokio::test]
async fn idle_exit_a_running_turn_is_live() {
    let hub = hub();
    let session = chat(&hub, "turn");
    *session.turn.lock().unwrap() = Some(turn("t1"));
    assert_eq!(hub.live_agent_count(), 1);
    assert!(!exits_within_three_graces(&hub).await, "exited during a turn");
}

#[tokio::test]
async fn idle_exit_a_held_turn_lock_is_live() {
    let hub = hub();
    let session = chat(&hub, "lock");
    let _held = session.turn_lock.lock().await;
    assert_eq!(hub.live_agent_count(), 1);
}

#[tokio::test]
async fn idle_exit_a_queued_prompt_is_live() {
    let hub = hub();
    let session = chat(&hub, "queued");
    session.queued.store(1, Ordering::SeqCst);
    assert_eq!(hub.live_agent_count(), 1);
    assert!(!exits_within_three_graces(&hub).await, "exited with a queued prompt");
}

#[tokio::test]
async fn idle_exit_a_pending_permission_is_live() {
    let hub = hub();
    let session = chat(&hub, "asks");
    let (reply, _answer) = tokio::sync::oneshot::channel();
    let pending = PendingPermission {
        request: json!({"toolCall": {"title": "rm -rf build"}}),
        reply,
        decision_nonce: "n1".into(),
        ancestor_may_answer: false,
        prev_status: SessionStatus::Running,
    };
    session.permissions.lock().unwrap().pending.insert("r1".into(), pending);
    assert_eq!(hub.live_agent_count(), 1);
    assert!(!exits_within_three_graces(&hub).await, "exited with a permission pending");
}

#[tokio::test]
async fn idle_exit_a_start_in_flight_is_live() {
    let hub = hub();
    let session = chat(&hub, "spawn");
    let _starting = session.spawn_lock.lock().await;
    assert_eq!(hub.live_agent_count(), 1);
}

#[tokio::test]
async fn idle_exit_a_running_background_process_is_live() {
    let hub = hub();
    let session = chat(&hub, "procs");
    let update = json!({"params": {"update": {
        "toolCallId": "tool-1", "taskId": "task-1", "state": "running", "command": "npm run dev",
    }}});
    let rec = EventRecord {
        seq: 1,
        at: 1,
        dir: "in".into(),
        kind: "background_task_update".into(),
        msg: update,
        host_seq: None,
    };
    hub.note_process(&session, &rec, None);
    assert_eq!(hub.live_agent_count(), 0, "a process is no agent");
    assert_eq!(hub.live_process_count(), 1);
    assert!(!exits_within_three_graces(&hub).await, "exited with a process running");
}

/// cmuxterm-hq#2503: a turn a relay outage cut waits up to 20 minutes for its
/// continuation, in this process only. The chat has no harness and no client
/// meanwhile; the daemon stays for the continuation.
#[tokio::test]
async fn idle_exit_a_waiting_continuation_is_live() {
    let hub = hub();
    hub.config.write().await.auto_resume_delays_ms = Some(vec![1_200_000]);
    let session = chat(&hub, "cut");
    *session.turn.lock().unwrap() = Some(turn("t1"));
    assert!(hub.take_turn(&session, "t1").is_some());
    let cut = auto_resume::CutTurn {
        prompt_id: "p1",
        turn_id: "t1",
        control: Control::Local,
        trust_gate: false,
        error: "stream disconnected before completion",
    };
    hub.schedule_auto_resume(&session, "t1", Some(cut));
    settle().await;
    assert!(session.turn().is_none() && session.child.lock().await.is_none());
    assert!(hub.continuation_pending(&session));
    assert_eq!(hub.live_agent_count(), 1);
    assert!(!exits_within_three_graces(&hub).await, "exited with a continuation waiting");
}
