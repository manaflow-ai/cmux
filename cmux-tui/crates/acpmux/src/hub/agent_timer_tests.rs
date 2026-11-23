//! Wake kind 4 (`agent_timer.rs`): a /loop timer the agent set keeps its chat's agent and its
//! Cloud machine up until it fires, on a fixed wall time passed in (no waiting on real time).
//!
//! On the base this scenario fails at its first check: between two loop runs no turn is open,
//! so the idle reaper ended Claude (and its loop) after 2 minutes and the Cloud report said 0
//! sessions at work, so the machine was paused with nothing to resume it at the due time.

use super::*;
use crate::config::{Config, StoreMode};
use crate::daemon::cloud_activity_probe as report;
use std::path::Path;

const NOW: u64 = 1_790_000_000_000;
/// A self-paced /loop's ScheduleWakeup of 270 s.
const DUE: u64 = NOW + 270_000;

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
    session.inbound_tx.send(item).await.unwrap();
    let (done, applied) = tokio::sync::oneshot::channel();
    session.inbound_tx.send(Inbound::Barrier(done)).await.unwrap();
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
    let (hub, session) = chat().await;
    assert!(hub.idle_eligible(&session), "a ready chat with nothing going on");
    assert!(cloud_reads(&hub, NOW).0, "no timer: the machine may pause");

    set_goal(&session, wakeup(DUE)).await;
    // Between two runs: no turn open, the loop's next run 270 s ahead. A pause now (the Cloud's)
    // or Claude's exit (the reaper's, which ends the loop) means the run never comes on time.
    for now in [NOW, NOW + 120_000, DUE - 1, DUE + FIRE_GRACE_MS - 1] {
        assert!(!hub.idle_eligible(&session), "the reaper would end the loop at {now}");
        let (pausable, phases) = cloud_reads(&hub, now);
        assert!(!pausable, "the Cloud would pause the machine at {now}, before the timer fired");
        assert_eq!(phases[0]["phase"], "timer");
    }
    assert_eq!(cloud_reads(&hub, NOW).1[0]["wake_at"], json!(DUE), "the due time is reported");
    assert_eq!(cloud_reads(&hub, DUE).1[0].get("wake_at"), None, "due now: no time ahead");

    // Its grace over, a wakeup that did not re-arm holds nothing.
    assert!(hub.idle_eligible(&session));
    assert!(cloud_reads(&hub, DUE + FIRE_GRACE_MS).0);

    // A recurring cron holds while armed, past its first known fire too.
    let cron = json!({"kind": "loop", "status": "active", "objective": "babysit", "schedule": "every 5 minutes",
        "nextRunAt": DUE, "timers": [{"at": DUE, "recurring": true}, {"at": DUE + 600_000, "recurring": false}]});
    set_goal(&session, cron).await;
    assert_eq!(cloud_reads(&hub, NOW).1[0]["wake_at"], json!(DUE), "the earliest timer");
    let (pausable, phases) = cloud_reads(&hub, DUE + 3_600_000);
    assert!(!pausable && phases[0]["phase"] == "timer" && phases[0].get("wake_at").is_none());
    assert!(!hub.idle_eligible(&session));

    // A loop stored before `timers` was listed still holds by its own next run.
    set_goal(
        &session,
        json!({"kind": "loop", "status": "active", "objective": "x", "nextRunAt": DUE}),
    )
    .await;
    assert_eq!(cloud_reads(&hub, NOW).1[0]["wake_at"], json!(DUE));

    // A goal that is not a loop (Codex's) holds nothing.
    set_goal(&session, json!({"status": "active", "objective": "Ship the fix"})).await;
    assert!(hub.idle_eligible(&session));
    assert!(cloud_reads(&hub, NOW).0);

    // Claude's exit ends its loops: nothing left to wake for.
    set_goal(&session, wakeup(DUE)).await;
    let child = session.child.lock().await.clone().unwrap();
    session
        .inbound_tx
        .send(Inbound::Exited { pid: child.pid, code: None, host_seq: None })
        .await
        .unwrap();
    let (done, applied) = tokio::sync::oneshot::channel();
    session.inbound_tx.send(Inbound::Barrier(done)).await.unwrap();
    applied.await.unwrap();
    assert_eq!(hub.pending_timer(&session, NOW), None, "a timer outlived its agent");
    assert!(cloud_reads(&hub, NOW).0);
    hub.shutdown_all().await;
}
