//! Wake kind 4 (`agent_timer.rs`): a /loop timer the agent set keeps its chat's agent and its
//! Cloud machine up until it fires. Times are offsets from the wall clock read once at the start,
//! passed in where the code takes a time; nothing waits on real time.
//!
//! On the base this scenario fails at its first check: between two loop runs no turn is open,
//! so the idle reaper ended Claude (and its loop) after 2 minutes and the Cloud report said 0
//! sessions at work, so the machine was paused with nothing to resume it at the due time.

use super::*;
use crate::config::{Config, StoreMode};
use crate::daemon::cloud_activity_probe as report;
use std::path::Path;

/// A self-paced /loop's ScheduleWakeup of 270 s.
const DELAY: u64 = 270_000;

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

/// Applies `goal` as the agent's `session_info_update` (what `claude_stdio/loops.rs` sends).
async fn set_goal(session: &Session, goal: Value) {
    let child = session.child.lock().await.clone().expect("the stand-in agent runs");
    let update = json!({"sessionUpdate": "session_info_update", "_meta": {"goal": goal}});
    let item = Inbound::Notification {
        method: method::SESSION_UPDATE.to_owned(),
        params: Some(json!({"sessionId": "agent-session", "update": update})),
        agent: child.generation,
        host_seq: None,
        host_incarnation: None,
        persisted: None,
    };
    session.inbound_tx().send(item).await.unwrap();
    let (done, applied) = tokio::sync::oneshot::channel();
    session.inbound_tx().send(Inbound::Barrier(done)).await.unwrap();
    applied.await.unwrap();
}

fn wakeup(at: u64) -> Value {
    json!({"kind": "loop", "status": "active", "objective": "check the deploy", "nextRunAt": at,
        "timers": [{"at": at, "recurring": false}]})
}

/// The Cloud's reading of the report this daemon sends at `now`: whether it may pause the
/// machine (0 sessions at work, `flushes_before`), and the sessions' phases.
fn cloud_reads(hub: &Hub, now: u64) -> (bool, Value) {
    let line = report::line(&hub.sessions_at_work_detail_at(now), now);
    (
        report::pausable(&line),
        line.pointer("/acp_activity/phases/turns").cloned().unwrap_or(json!([])),
    )
}

#[tokio::test]
async fn a_pending_loop_timer_keeps_its_machine_up_until_it_fires() {
    // The idle reaper reads the wall clock itself: the timer is set ahead of it.
    let start = crate::store::now_ms();
    let due = start + DELAY;
    let (hub, session) = chat().await;
    assert!(hub.idle_eligible(&session), "a ready chat with nothing going on");
    assert!(cloud_reads(&hub, start).0, "no timer: the machine may pause");

    set_goal(&session, wakeup(due)).await;
    // Between two runs: no turn open, the loop's next run 270 s ahead. A pause now (the Cloud's)
    // or Claude's exit (the reaper's, which ends the loop) means the run never comes on time.
    assert!(!hub.idle_eligible(&session), "the reaper would end the loop before it fires");
    for now in [start, start + 120_000, due - 1, due + FIRE_GRACE_MS - 1] {
        assert!(hub.pending_timer(&session, now).is_some(), "no timer pending at {now}");
        let (pausable, phases) = cloud_reads(&hub, now);
        assert!(!pausable, "the Cloud would pause the machine at {now}, before the timer fired");
        assert_eq!(phases[0]["phase"], "timer");
    }
    assert_eq!(cloud_reads(&hub, start).1[0]["wake_at"], json!(due), "the due time is reported");
    assert_eq!(cloud_reads(&hub, due).1[0].get("wake_at"), None, "due now: no time ahead");

    // Its grace over, a wakeup that did not re-arm holds nothing.
    assert_eq!(hub.pending_timer(&session, due + FIRE_GRACE_MS), None);
    assert!(cloud_reads(&hub, due + FIRE_GRACE_MS).0);
    set_goal(&session, wakeup(start - FIRE_GRACE_MS - 1)).await;
    assert!(hub.idle_eligible(&session), "a wakeup past its grace no longer holds its agent");

    // A recurring cron holds while armed, past its first known fire too.
    let cron = json!({"kind": "loop", "status": "active", "objective": "babysit", "schedule": "every 5 minutes",
        "nextRunAt": due, "timers": [{"at": due, "recurring": true}, {"at": due + 600_000, "recurring": false}]});
    set_goal(&session, cron).await;
    assert_eq!(cloud_reads(&hub, start).1[0]["wake_at"], json!(due), "the earliest timer");
    let (pausable, phases) = cloud_reads(&hub, due + 3_600_000);
    assert!(!pausable && phases[0]["phase"] == "timer" && phases[0].get("wake_at").is_none());
    assert!(!hub.idle_eligible(&session));

    // A loop stored before `timers` was listed still holds by its own next run.
    set_goal(
        &session,
        json!({"kind": "loop", "status": "active", "objective": "x", "nextRunAt": due}),
    )
    .await;
    assert_eq!(cloud_reads(&hub, start).1[0]["wake_at"], json!(due));

    // A goal that is not a loop (Codex's) holds nothing.
    set_goal(&session, json!({"status": "active", "objective": "Ship the fix"})).await;
    assert!(hub.idle_eligible(&session));
    assert!(cloud_reads(&hub, start).0);

    // Claude's exit ends its loops: nothing left to wake for.
    set_goal(&session, wakeup(due)).await;
    let child = session.child.lock().await.clone().unwrap();
    session
        .inbound_tx()
        .send(Inbound::Exited { pid: child.pid, code: None, host_seq: None })
        .await
        .unwrap();
    let (done, applied) = tokio::sync::oneshot::channel();
    session.inbound_tx().send(Inbound::Barrier(done)).await.unwrap();
    applied.await.unwrap();
    assert_eq!(hub.pending_timer(&session, start), None, "a timer outlived its agent");
    assert!(cloud_reads(&hub, start).0);
    hub.shutdown_all().await;
}

#[tokio::test]
async fn a_goal_set_over_an_armed_loop_keeps_its_timer() {
    // Greptile P1 on #51753: `goal_set` replaced the loop goal and the timer went unseen, so the
    // reaper ended Claude with its wakeup still armed.
    let start = crate::store::now_ms();
    let (hub, session) = chat().await;
    set_goal(&session, wakeup(start + DELAY)).await;
    let req = crate::generic_goal::GoalRequest {
        objective: "Land the fix".into(),
        done_when: "cargo test passes".into(),
        token_budget: None,
        time_budget_minutes: None,
    };
    hub.goal_set(&session, &req).unwrap();
    assert!(hub.pending_timer(&session, start).is_some(), "goal_set hid the armed wakeup");
    assert!(!hub.idle_eligible(&session));
    hub.shutdown_all().await;
}

#[tokio::test]
async fn a_saved_loop_goal_with_no_agent_to_hold_it_keeps_nothing_up() {
    // Greptile P1 on #51753: a loop goal restored after a reboot named timers no process held,
    // and a recurring one kept the machine up for good.
    let start = crate::store::now_ms();
    let (hub, session) = chat().await;
    let cron = json!({"kind": "loop", "status": "active", "objective": "babysit",
        "schedule": "every 5 minutes", "timers": [{"at": start + DELAY, "recurring": true}]});
    session.meta.lock().unwrap().goal = crate::goal::GoalState::from_value(&cron, None);
    assert_eq!(hub.pending_timer(&session, start), None, "a restored goal held the machine");
    assert!(hub.idle_eligible(&session));
    assert!(cloud_reads(&hub, start).0);
    hub.shutdown_all().await;
}

/// A daemon restart that adopts the live agent host: the agent still holds its wakeup, but the
/// new daemon never heard the goal update that armed it. On the base the chat was idle-eligible at
/// once, so the reaper ended the adopted agent seconds after the adoption and the wakeup never
/// fired.
#[tokio::test]
async fn an_adopted_agent_keeps_the_loop_timer_its_old_daemon_heard() {
    let start = crate::store::now_ms();
    let due = start + DELAY;
    let (hub, session) = chat().await;
    set_goal(&session, wakeup(due)).await;
    assert!(!hub.idle_eligible(&session));
    // The new daemon's session: the saved goal and the live agent, no timers heard.
    *session.loop_timers.lock().unwrap() = None;
    assert!(hub.idle_eligible(&session), "the stand-in for the new daemon before adoption");

    note_adopted_goal(&session);
    assert!(!hub.idle_eligible(&session), "the reaper would end the adopted agent's wakeup");
    assert_eq!(hub.pending_timer(&session, start), Some(PendingTimer { wake_at: Some(due) }));

    // Not a loop: nothing is held.
    set_goal(&session, json!({"status": "active", "objective": "ship it"})).await;
    note_adopted_goal(&session);
    assert_eq!(hub.pending_timer(&session, start), None);
}
