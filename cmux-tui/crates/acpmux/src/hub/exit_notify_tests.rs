//! A closed session's exit record reaches the session that started it once (`exit_notify.rs`).

use super::*;
use crate::close_why::{CloseActor, CloseWhy};
use crate::config::{Config, StoreMode};
use std::path::Path;

fn hub() -> Arc<Hub> {
    let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
    let mut cfg: Config = serde_json::from_value(json!({
        "harnesses": {"fake": {"argv": ["python3", fake]}},
        "defaultHarness": "fake",
    }))
    .unwrap();
    cfg.store.mode = StoreMode::Memory;
    let store = crate::store::open(&cfg.store, Path::new("/nonexistent")).unwrap();
    Hub::new(cfg, store)
}

async fn chat(hub: &Arc<Hub>, parent: Option<&Session>) -> Arc<Session> {
    let req = NewRequest { cwd: Some(std::env::temp_dir()), ..NewRequest::default() };
    let s = hub.new_session(req).await.unwrap();
    if let Some(p) = parent {
        let tags = json!({"spawnedBy": p.id, "goal": "ship it"});
        hub.set_tags(&s, tags.as_object(), &[], None);
    }
    s
}

/// The exit records `session`'s log got, as their provenance.
fn heard(hub: &Hub, session: &Session) -> Vec<Value> {
    hub.events(&session.id, 0, 100_000)
        .unwrap()
        .into_iter()
        .filter(|r| r.kind == "user_message")
        .map(|r| r.msg["_meta"]["provenance"].clone())
        .filter(|p| p["kind"] == crate::exit_record::KIND)
        .collect()
}

async fn wait_heard(hub: &Hub, session: &Session) -> Vec<Value> {
    for _ in 0..200 {
        let h = heard(hub, session);
        if !h.is_empty() {
            return h;
        }
        tokio::time::sleep(std::time::Duration::from_millis(25)).await;
    }
    vec![]
}

async fn stop(hub: &Arc<Hub>, s: &Arc<Session>, actor: CloseActor) {
    let mut why = CloseWhy::actor(actor);
    why.reason = Some("test".into());
    let condition = super::stop_if_idle::StopCondition::default();
    hub.stop_why(s, false, condition, why).await.unwrap();
}

#[tokio::test]
async fn the_parent_hears_its_lane_close_once() {
    let hub = hub();
    let parent = chat(&hub, None).await;
    let lane = chat(&hub, Some(&parent)).await;
    stop(&hub, &lane, CloseActor::new("ttl")).await;
    let h = wait_heard(&hub, &parent).await;
    assert_eq!(h.len(), 1, "{h:?}");
    assert_eq!(h[0]["from"], lane.id.as_str());
    assert_eq!(h[0]["class"], "killed");
    assert_eq!(h[0]["record"]["owned"]["goal"], "ship it");
    // A second stop of a closed chat writes no new close, so nothing new is sent.
    hub.kill(&lane, false).await.unwrap();
    tokio::time::sleep(std::time::Duration::from_millis(200)).await;
    assert_eq!(heard(&hub, &parent).len(), 1);
    let told = hub.events(&lane.id, 0, 10_000).unwrap();
    assert!(told.iter().any(|e| e.dir == "mux" && e.kind == "exit_told"));
}

#[tokio::test]
async fn a_closed_parent_passes_it_up() {
    let hub = hub();
    let top = chat(&hub, None).await;
    let mid = chat(&hub, Some(&top)).await;
    let lane = chat(&hub, Some(&mid)).await;
    // mid closed by top itself: top hears nothing of mid.
    stop(&hub, &mid, CloseActor::new("cli").session(Some(&top.id))).await;
    stop(&hub, &lane, CloseActor::new("harness_exit")).await;
    let h = wait_heard(&hub, &top).await;
    assert_eq!(h.len(), 1, "only the lane's record reaches top: {h:?}");
    assert_eq!(h[0]["from"], lane.id.as_str());
    assert_eq!(h[0]["class"], "crashed");
    assert_eq!(h[0]["via"], json!([mid.meta().name]));
}

/// A crash's exit record for `lane`, as the close builds it.
fn record_of(lane: &Session) -> crate::exit_record::ExitRecord {
    let close = crate::close_why::CloseRecord {
        closed_at: 1,
        actor: CloseActor::new("harness_exit"),
        reason: "exit 1".into(),
        outcome: "crashed".into(),
    };
    lane.read_meta(|m| crate::exit_record::ExitRecord::new(m, close, vec![]))
}

#[tokio::test]
async fn a_supervisor_restart_reopens_the_crashed_chat_once() {
    let hub = hub();
    let lane = chat(&hub, None).await;
    stop(&hub, &lane, CloseActor::new("harness_exit")).await;
    assert_eq!(lane.status(), SessionStatus::Closed);
    let record = record_of(&lane);
    hub.supervisor_restart(&lane, &record).await;
    let sent = |hub: &Hub| {
        hub.events(&lane.id, 0, 100_000)
            .unwrap()
            .into_iter()
            .filter(|r| r.kind == "user_message")
            .map(|r| r.msg["_meta"]["provenance"].clone())
            .filter(|p| p["kind"] == crate::supervisor::RESTART_KIND)
            .count()
    };
    assert_ne!(lane.status(), SessionStatus::Closed, "the restart reopens it");
    assert_eq!(sent(&hub), 1);
    // A chat already open again is left alone: no second restart prompt.
    hub.supervisor_restart(&lane, &record).await;
    assert_eq!(sent(&hub), 1);
}

#[tokio::test]
async fn an_escalation_tells_the_parent_why() {
    let hub = hub();
    let parent = chat(&hub, None).await;
    let lane = chat(&hub, Some(&parent)).await;
    stop(&hub, &lane, CloseActor::new("harness_exit")).await;
    // The close's own delivery (no note) is the first; wait it out, then send the escalation
    // with a fresh close time so its prompt id is new.
    let _ = wait_heard(&hub, &parent).await;
    let mut record = record_of(&lane);
    record.close.closed_at += 1;
    let note =
        crate::supervisor::Decision::Escalate { to: None, why: "3 restarts in 360 min".into() }
            .parent_note();
    hub.exit_record_deliver(&record, &parent.id, note.as_deref()).await;
    let h = heard(&hub, &parent);
    let up = h.iter().find(|p| p.get("supervisor").is_some()).expect("escalation heard");
    assert!(up["supervisor"].as_str().unwrap().starts_with("acpmux stopped restarting it"));
}
