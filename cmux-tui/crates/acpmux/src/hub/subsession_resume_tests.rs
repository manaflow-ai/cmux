//! Resume of a stopped sub-session (`subsession_resume.rs`), and a parent's Stop that stops only
//! the parent's own turn, never its sub-sessions' (Leo, 2026-11-12: "EVERYTHING FUCKING STOPPED
//! WHEN I STOPPED YOU").

use crate::config::{Config, StoreMode};
use crate::hub::auto_resume::retry_turn::RetryBy;
use crate::hub::*;
use crate::store::SubsessionLink;
use std::path::Path;
use std::time::Duration;

async fn hub_with_parent() -> (Arc<Hub>, Arc<Session>) {
    let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
    let mut cfg: Config = serde_json::from_value(json!({
        "harnesses": {"fake": {"argv": ["python3", fake]}},
        "defaultHarness": "fake",
        "permissionPolicy": "approve-all",
    }))
    .unwrap();
    cfg.store.mode = StoreMode::Memory;
    // No automatic retry: only the Resume continues a turn.
    cfg.auto_resume_delays_ms = Some(vec![]);
    let store = crate::store::open(&cfg.store, Path::new("/nonexistent")).unwrap();
    let hub = Hub::new(cfg, store);
    let req = NewRequest { cwd: Some(std::env::temp_dir()), ..NewRequest::default() };
    let parent = hub.new_session(req).await.unwrap();
    (hub, parent)
}

async fn child_of(hub: &Arc<Hub>, parent: &Session) -> Arc<Session> {
    let req = NewRequest {
        cwd: Some(std::env::temp_dir()),
        subsession: Some(SubsessionLink {
            started_by: parent.id.clone(),
            short_name: "helper".to_owned(),
            depth: 1,
            offered: false,
        }),
        ..NewRequest::default()
    };
    hub.new_session(req).await.unwrap()
}

fn by_person() -> RetryBy {
    RetryBy { control: Control::Local, trust_gate: false, full_access_device: None, from: None }
}

fn text(t: &str) -> Vec<Value> {
    vec![json!({"type": "text", "text": t})]
}

/// Starts a turn that runs until Stop, and waits until it runs.
async fn run_until_stopped(hub: &Arc<Hub>, s: &Arc<Session>) -> tokio::task::JoinHandle<()> {
    let (hub2, s2) = (hub.clone(), s.clone());
    let task = tokio::spawn(async move {
        let _ = hub2.prompt(&s2, text("until-cancel"), "test", false).await;
    });
    until(|| s.turn().is_some()).await;
    task
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

fn last_status(s: &Session) -> Option<String> {
    s.meta().last_turn.and_then(|t| t.get("status").and_then(Value::as_str).map(str::to_owned))
}

fn user_messages(hub: &Hub, s: &Session) -> Vec<Value> {
    let events = hub.events(&s.id, 0, 10_000).unwrap();
    events.into_iter().filter(|e| e.kind == "user_message").map(|e| e.msg).collect()
}

/// A stopped sub-session's Resume (`_acpmux/retry {sessionId}`) starts one new turn in the same
/// chat and agent session, a continuation of the stopped turn; base refused it
/// `retry.nothing_failed`.
#[tokio::test]
async fn resume_continues_a_stopped_sub_session_in_the_same_chat() {
    let (hub, parent) = hub_with_parent().await;
    let child = child_of(&hub, &parent).await;
    let running = run_until_stopped(&hub, &child).await;
    let stopped_turn = child.turn().unwrap();
    hub.person_stop(&child).await.unwrap();
    let _ = running.await;
    until(|| last_status(&child).as_deref() == Some("cancelled")).await;
    let agent_session = hub.session_summary(&child)["agentSessionId"].clone();

    let v = hub.retry(&child, None, by_person()).await.expect("a stopped sub-session resumes");
    assert_eq!(v["kind"], "turn", "{v}");
    let prompt_id = v["promptId"].as_str().unwrap().to_owned();
    assert!(prompt_id.starts_with("stopped-resume-"), "{v}");
    until(|| last_status(&child).as_deref() == Some("completed")).await;

    let messages = user_messages(&hub, &child);
    assert_eq!(messages.len(), 2, "{messages:?}");
    let resumed = &messages[1];
    assert_eq!(resumed["promptId"], prompt_id.as_str());
    assert!(resumed["text"].as_str().unwrap().contains("continue from where it stopped"));
    assert_eq!(
        resumed["_meta"]["provenance"],
        json!({"kind": "auto_resume", "reason": "stopped", "promptId": stopped_turn.prompt_id,
            "turnId": stopped_turn.turn_id, "manual": true})
    );
    let after = hub.session_summary(&child);
    assert_eq!(after["agentSessionId"], agent_session, "the same agent session: {after}");
    assert_eq!(hub.sessions().len(), 2, "no new session");

    // Its turn completed: nothing is stopped or failed, so nothing more goes.
    let e = hub.retry(&child, None, by_person()).await.unwrap_err();
    assert_eq!(e.data.as_ref().unwrap()["reason"], "retry.nothing_failed", "{e:?}");
    hub.shutdown_all().await;
}

/// The parent's agent resumes its stopped sub-session with `retry_session`
/// (`_acpmux/subsession/retry`); the continuation names it as its sender.
#[tokio::test]
async fn a_parent_resumes_its_stopped_sub_session_with_retry_session() {
    let (hub, parent) = hub_with_parent().await;
    let child = child_of(&hub, &parent).await;
    let running = run_until_stopped(&hub, &child).await;
    hub.person_stop(&child).await.unwrap();
    let _ = running.await;
    until(|| last_status(&child).as_deref() == Some("cancelled")).await;

    let v = hub.subsession_retry(&parent, &child, None).await.expect("the parent resumes it");
    assert_eq!(v["kind"], "turn", "{v}");
    until(|| last_status(&child).as_deref() == Some("completed")).await;
    let messages = user_messages(&hub, &child);
    let provenance = &messages.last().unwrap()["_meta"]["provenance"];
    assert_eq!(provenance["reason"], "stopped", "{provenance}");
    assert_eq!(provenance["from"], parent.id.as_str(), "{provenance}");
    hub.shutdown_all().await;
}

/// A Resume while the sub-session runs again is `retry.busy`, never a second turn queued.
#[tokio::test]
async fn resume_of_a_running_sub_session_is_busy_and_queues_nothing() {
    let (hub, parent) = hub_with_parent().await;
    let child = child_of(&hub, &parent).await;
    let running = run_until_stopped(&hub, &child).await;
    hub.person_stop(&child).await.unwrap();
    let _ = running.await;
    until(|| last_status(&child).as_deref() == Some("cancelled")).await;
    // Something else runs it again first (a message from its parent).
    let again = run_until_stopped(&hub, &child).await;

    let e = hub.retry(&child, None, by_person()).await.unwrap_err();
    assert_eq!(e.data.as_ref().unwrap()["reason"], "retry.busy", "{e:?}");
    assert!(child.queue().is_empty(), "nothing queued");
    hub.cancel(&child).await.unwrap();
    let _ = again.await;
    hub.shutdown_all().await;
}

/// A top-level chat's stopped turn is not changed: its Continue is the pane's.
#[tokio::test]
async fn a_stopped_top_level_chat_still_has_nothing_to_retry() {
    let (hub, parent) = hub_with_parent().await;
    let running = run_until_stopped(&hub, &parent).await;
    hub.person_stop(&parent).await.unwrap();
    let _ = running.await;
    until(|| last_status(&parent).as_deref() == Some("cancelled")).await;
    let e = hub.retry(&parent, None, by_person()).await.unwrap_err();
    assert_eq!(e.data.as_ref().unwrap()["reason"], "retry.nothing_failed", "{e:?}");
    hub.shutdown_all().await;
}

/// The person's Stop of a parent stops the parent's own turn only: its sub-session's turn runs on.
#[tokio::test]
async fn a_parents_stop_never_stops_its_sub_sessions() {
    let (hub, parent) = hub_with_parent().await;
    let child = child_of(&hub, &parent).await;
    let child_running = run_until_stopped(&hub, &child).await;
    let child_turn = child.turn().unwrap().turn_id;
    let parent_running = run_until_stopped(&hub, &parent).await;

    hub.person_stop(&parent).await.unwrap();
    let _ = parent_running.await;
    until(|| last_status(&parent).as_deref() == Some("cancelled")).await;
    tokio::time::sleep(Duration::from_millis(300)).await;
    assert_eq!(child.turn().map(|t| t.turn_id), Some(child_turn), "the child's turn runs on");
    assert_eq!(last_status(&child), None, "the child's turn never ended");

    hub.cancel(&child).await.unwrap();
    let _ = child_running.await;
    hub.shutdown_all().await;
}
