//! A new session's wait for the daemon's startup is bounded (`startup.rs`,
//! `NEW_SESSION_STARTUP_WAIT`): 2026-11-07, a startup held by one agent host that never answered
//! its adoption hello left every `acpmux new` on that machine with no reply for hours.

use super::startup::NEW_SESSION_STARTUP_WAIT;
use super::*;
use crate::config::{Config, StoreMode};
use std::path::Path;

fn hub() -> Arc<Hub> {
    let mut cfg = Config::default();
    cfg.store.mode = StoreMode::Memory;
    let store = crate::store::open(&cfg.store, Path::new("/nonexistent")).unwrap();
    Hub::new(cfg, store)
}

#[tokio::test(start_paused = true)]
async fn daemon_peer_gate_waits_for_local_initialization() {
    let mut cfg = Config::default();
    cfg.store.mode = StoreMode::Memory;
    cfg.peers
        .insert("held".into(), serde_json::from_value(json!({"url": "ws://127.0.0.1:1"})).unwrap());
    let store = crate::store::open(&cfg.store, Path::new("/nonexistent")).unwrap();
    let hub = Hub::build(cfg, store, Mailbox::memory(), true, true, None, false);
    assert!(
        tokio::time::timeout(std::time::Duration::from_millis(1), hub.wait_local_ready())
            .await
            .is_err(),
        "daemon peer dialing was released before local initialization"
    );
    hub.mark_local_ready();
    tokio::time::timeout(std::time::Duration::from_millis(1), hub.wait_local_ready())
        .await
        .expect("local initialization releases peer dialing");
    hub.begin_shutdown();
    hub.start_saved_peers().await;
    assert!(hub.peers.lock().unwrap().is_empty(), "a released peer gate dialed during shutdown");
}

#[tokio::test(start_paused = true)]
async fn a_new_session_behind_a_startup_that_never_ends_fails_naming_the_phase() {
    let hub = hub();
    // A startup that never finishes, as one held by a wedged host's adoption.
    hub.begin_startup(false);
    let phase = hub.loading_status()["phase"].as_str().unwrap().to_owned();
    let started = tokio::time::Instant::now();
    let req = NewRequest { cwd: Some(std::env::temp_dir()), ..NewRequest::default() };
    let error = hub.new_session(req).await.err().expect("no session starts before startup ends");
    assert!(started.elapsed() >= NEW_SESSION_STARTUP_WAIT, "it gave up early");
    let data = error.data.clone().unwrap_or_default();
    assert_eq!(data["reason"], "deadline_exceeded", "{error:?}");
    assert_eq!(data["retryable"], true, "{error:?}");
    assert_eq!(data["phase"], phase.as_str(), "{error:?}");
    assert!(error.message.contains("daemon startup"), "{}", error.message);
    assert!(error.message.contains(&format!("phase {phase}")), "{}", error.message);
    assert!(hub.sessions.lock().unwrap().is_empty(), "a refused create made a session");
}

#[tokio::test(start_paused = true)]
async fn a_slow_startup_that_ends_within_the_wait_is_waited_for() {
    let hub = hub();
    hub.begin_startup(false);
    let finisher = hub.clone();
    tokio::spawn(async move {
        tokio::time::sleep(NEW_SESSION_STARTUP_WAIT / 2).await;
        finisher.spawn_ready.send_replace(true);
    });
    hub.wait_spawn_ready_within(NEW_SESSION_STARTUP_WAIT)
        .await
        .expect("a slow startup is waited for");
}

/// Leo, 2026-11-12: "everything waits on everything". A startup whose adoption never ends (one
/// agent host that never answers) holds no new chat once what an agent start needs is ready: it
/// answers at once, whatever it answers, never the startup's deadline.
#[tokio::test(start_paused = true)]
async fn a_new_session_does_not_wait_for_another_chats_adoption() {
    let hub = hub();
    hub.begin_startup(false);
    hub.adoption_ready.send_replace(false);
    hub.spawn_ready.send_replace(true);
    let started = tokio::time::Instant::now();
    let req = NewRequest { cwd: Some(std::env::temp_dir()), ..NewRequest::default() };
    let answer = hub.new_session(req).await;
    assert!(started.elapsed() < NEW_SESSION_STARTUP_WAIT, "the new session waited for adoption");
    if let Err(error) = answer {
        let data = error.data.clone().unwrap_or_default();
        assert_ne!(data["reason"], "deadline_exceeded", "it waited for startup: {error:?}");
    }
}

#[test]
fn the_error_says_what_each_phase_is_doing() {
    let wait = std::time::Duration::from_secs(1);
    let adopting = super::startup::startup_wait_error("adopting", wait);
    assert!(adopting.message.contains("reattaching the agent hosts"), "{}", adopting.message);
    assert!(adopting.message.contains("no session was created"), "{}", adopting.message);
    let store = super::startup::startup_wait_error("loading-store", wait);
    assert!(store.message.contains("session index"), "{}", store.message);
}
