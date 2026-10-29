//! A stop (`kill`) against agent starts that race it (`ensure_child`, ergo-walk2 2026-10-25:
//! "session stop says closed but acpmux ls still shows it ready"). Each test fixes the order by
//! hand: the stop count a start was asked under, the spawn lock a start in flight holds.

use super::*;
use crate::config::{Config, StoreMode};
use std::path::Path;

/// A hub with one open chat whose stand-in agent is running.
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

/// The kinds of `session`'s mux records after `seq`.
fn kinds_after(hub: &Hub, session: &Session, seq: u64) -> Vec<String> {
    let events = hub.events(&session.id, seq, 10_000).unwrap();
    events.into_iter().filter(|e| e.dir == "mux").map(|e| e.kind).collect()
}

fn last_seq(hub: &Hub, session: &Session) -> u64 {
    hub.events(&session.id, 0, 10_000).unwrap().last().map_or(0, |e| e.seq)
}

async fn has_live_child(session: &Session) -> bool {
    let child = session.child.lock().await.clone();
    match child {
        Some(child) => child.is_alive().await,
        None => false,
    }
}

/// A prompt that came before the stop and reaches its agent start after it (it waited on the
/// spawn lock a start in flight held): the start ends, nothing reopens the chat, and a request
/// after the stop still reopens it.
#[tokio::test]
async fn a_start_asked_for_before_a_stop_leaves_the_session_closed() {
    let (hub, session) = chat().await;
    hub.kill(&session, false).await.unwrap();
    // The chat is closed; a prompt for it comes, and the start it needs waits for the lock.
    let asked = session.stops.load(Ordering::SeqCst);
    let held = session.spawn_lock.lock().await;
    let start = {
        let (hub, session) = (hub.clone(), session.clone());
        tokio::spawn(async move { hub.child_for_since(&session, asked).await })
    };
    // Stopped again before that start gets the lock.
    hub.kill(&session, false).await.unwrap();
    let seq = last_seq(&hub, &session);
    drop(held);
    let started = start.await.unwrap();
    assert!(started.is_err(), "a start asked for before the stop went on");
    assert_eq!(session.status(), SessionStatus::Closed);
    assert!(!has_live_child(&session).await, "the stopped start left an agent running");
    let later = kinds_after(&hub, &session, seq);
    assert!(!later.iter().any(|k| k == "reopened"), "{later:?}");
    assert!(!later.iter().any(|k| k == "status"), "{later:?}");

    // A request after the stop reopens it, as before.
    hub.child_for(&session).await.unwrap();
    assert_ne!(session.status(), SessionStatus::Closed);
    assert!(kinds_after(&hub, &session, seq).iter().any(|k| k == "reopened"));
}

/// A request from before a stop that reaches its start only after a later request reopened
/// the chat: it fails, and leaves the agent that later request started running.
#[tokio::test]
async fn a_start_asked_for_before_a_stop_leaves_a_later_start_alone() {
    let (hub, session) = chat().await;
    let asked = session.stops.load(Ordering::SeqCst);
    hub.kill(&session, false).await.unwrap();
    let fresh = hub.child_for(&session).await.unwrap();
    assert_ne!(session.status(), SessionStatus::Closed);
    let stale = hub.child_for_since(&session, asked).await;
    assert!(stale.is_err(), "a request from before the stop got an agent");
    assert!(fresh.is_alive().await, "the stale request ended the agent a later request started");
    let now = session.child.lock().await.clone().expect("an agent");
    assert!(Arc::ptr_eq(&now, &fresh));
    assert_ne!(session.status(), SessionStatus::Closed);
}

/// A new chat's start-up steps after its agent started (its start model, effort, mode) run
/// under the creation's stop count: stopped in between, they start nothing again.
#[tokio::test]
async fn a_creation_step_after_a_stop_starts_nothing() {
    let (hub, session) = chat().await;
    let created = session.stops.load(Ordering::SeqCst);
    hub.kill(&session, false).await.unwrap();
    let seq = last_seq(&hub, &session);
    let step = REQUEST_STOPS.scope((session.id.clone(), created), hub.child_for(&session)).await;
    assert!(step.is_err(), "a creation step after the stop started the agent again");
    assert_eq!(session.status(), SessionStatus::Closed);
    assert!(!has_live_child(&session).await);
    let later = kinds_after(&hub, &session, seq);
    assert!(!later.iter().any(|k| k == "reopened"), "{later:?}");
    // The count of another session's request does not fence this one.
    let other = (format!("{}-other", session.id), created);
    REQUEST_STOPS.scope(other, hub.child_for(&session)).await.unwrap();
    assert_ne!(session.status(), SessionStatus::Closed);
}

/// A creation that failed after a stop leaves the chat a later request reopened, and its agent;
/// one nobody reopened is discarded, as any failed creation.
#[tokio::test]
async fn a_failed_creation_leaves_a_chat_a_later_request_reopened() {
    let (hub, session) = chat().await;
    let created = session.stops.load(Ordering::SeqCst);
    hub.kill(&session, false).await.unwrap();
    let fresh = hub.child_for(&session).await.unwrap();
    hub.discard_failed_creation(&session, created).await;
    assert!(fresh.is_alive().await, "the failed creation ended the reopened chat's agent");
    assert!(hub.resolve(&session.id).is_ok(), "the failed creation purged the reopened chat");
    assert_ne!(session.status(), SessionStatus::Closed);

    let (hub, session) = chat().await;
    let created = session.stops.load(Ordering::SeqCst);
    hub.kill(&session, false).await.unwrap();
    hub.discard_failed_creation(&session, created).await;
    assert!(hub.resolve(&session.id).is_err(), "a failed creation nobody reopened was kept");
}

/// A closed chat whose agent is still running (a host the daemon adopted at its start that
/// outlived the stop): a request reopens it and finds it ready, never a running agent behind a
/// chat `acpmux ls` lists as closed.
#[tokio::test]
async fn a_closed_session_with_a_live_agent_reopens_for_a_request() {
    let (hub, session) = chat().await;
    assert!(has_live_child(&session).await);
    hub.set_status(&session, SessionStatus::Closed);
    let seq = last_seq(&hub, &session);
    hub.child_for(&session).await.unwrap();
    assert_eq!(session.status(), SessionStatus::Ready);
    let later = kinds_after(&hub, &session, seq);
    assert!(later.iter().any(|k| k == "reopened"), "{later:?}");
}
