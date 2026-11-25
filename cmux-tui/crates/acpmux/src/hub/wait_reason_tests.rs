//! A Waiting chat always says what it waits on (goal cloud-chat-waiting-always-explained):
//! every card that puts a chat in Waiting names its reason in `waitingOn`, the reason leaves with
//! the card, and a restored Waiting chat never reads Waiting with nothing named.

use super::*;
use crate::config::{Config, StoreMode};
use crate::store::WaitReason;
use std::path::Path;
use std::time::Duration;

fn hub() -> Arc<Hub> {
    let mut config = Config::default();
    config.store.mode = StoreMode::Memory;
    let store = crate::store::open(&config.store, Path::new("/nonexistent")).unwrap();
    Hub::new(config, store)
}

fn meta(id: &str, status: &str) -> SessionMeta {
    serde_json::from_value(json!({
        "schema": crate::store::META_SCHEMA, "id": id, "name": "worker", "harness": "fake",
        "cwd": "/tmp", "status": status, "createdAt": 1, "updatedAt": 1
    }))
    .unwrap()
}

/// Lets spawned asks run until `open` holds (bounded: a card that never opens fails the test).
async fn until(open: impl Fn() -> bool) {
    for _ in 0..1000 {
        if open() {
            return;
        }
        tokio::time::sleep(Duration::from_millis(5)).await;
    }
    panic!("the card never opened");
}

fn waiting_on(hub: &Hub, session: &Session) -> Value {
    hub.session_summary(session)["waitingOn"].clone()
}

/// A card asked through `ask_person` reads its own reason while open, and the chat leaves
/// Waiting (back to where it was) when the card closes.
async fn card_reads(kind: secrets::CardKind, expect: &str) {
    let hub = hub();
    let session = hub.insert_test_session(meta("chat", "ready"));
    let ask = {
        let (hub, session) = (hub.clone(), session.clone());
        tokio::spawn(async move {
            hub.ask_person(&session, kind, json!({"name": "TOKEN"}), Duration::from_secs(60)).await
        })
    };
    until(|| hub.secrets.waiting_in(&session.id)).await;
    assert_eq!(session.status(), SessionStatus::Waiting);
    assert_eq!(hub.waiting_on(&session), Some((expect, None)));
    assert_eq!(waiting_on(&hub, &session), expect);

    hub.cancel_pending_secrets(&session);
    let (outcome, value) = ask.await.unwrap();
    assert_eq!(outcome, "cancelled");
    assert!(value.is_none());
    assert_eq!(session.status(), SessionStatus::Ready);
    assert_eq!(hub.waiting_on(&session), None);
    assert_eq!(waiting_on(&hub, &session), Value::Null);
}

#[tokio::test]
async fn a_secret_card_reads_waiting_on_secret() {
    card_reads(secrets::CARD_SECRET, "secret").await;
}

#[tokio::test]
async fn a_root_password_card_reads_waiting_on_elevation() {
    card_reads(elevation::CARD, "elevation").await;
}

#[tokio::test]
async fn an_mcp_connect_card_reads_waiting_on_mcp_connect() {
    let hub = hub();
    let session = hub.insert_test_session(meta("chat", "ready"));
    let ask = {
        let (hub, session) = (hub.clone(), session.clone());
        tokio::spawn(async move {
            hub.request_mcp_connect(&session, "https://mcp.example.com/mcp", "chat", "docs").await
        })
    };
    until(|| hub.mcp_connects.waiting_in(&session.id)).await;
    assert_eq!(session.status(), SessionStatus::Waiting);
    assert_eq!(waiting_on(&hub, &session), "mcp_connect");

    hub.cancel_pending_mcp_connects(&session);
    let reply = ask.await.unwrap().unwrap();
    assert_eq!(reply["status"], "cancelled", "{reply}");
    assert_eq!(session.status(), SessionStatus::Ready);
    assert_eq!(waiting_on(&hub, &session), Value::Null);
}

#[test]
fn waiting_records_its_reason_and_any_other_status_clears_it() {
    let hub = hub();
    let session = hub.insert_test_session(meta("chat", "running"));
    for reason in [
        WaitReason::Question,
        WaitReason::Permission,
        WaitReason::McpConnect,
        WaitReason::Secret,
        WaitReason::Elevation,
    ] {
        hub.set_waiting(&session, reason);
        assert_eq!(session.status(), SessionStatus::Waiting);
        assert_eq!(waiting_on(&hub, &session), reason.as_str());
        hub.set_status(&session, NotWaiting::Running);
        assert_eq!(waiting_on(&hub, &session), Value::Null);
    }
}

/// A card that is open names the chat's reason even over an older one the status recorded.
#[tokio::test]
async fn an_open_card_names_the_reason() {
    let hub = hub();
    let session = hub.insert_test_session(meta("chat", "ready"));
    hub.set_waiting(&session, WaitReason::Permission);
    let ask = {
        let (hub, session) = (hub.clone(), session.clone());
        tokio::spawn(async move {
            hub.ask_person(
                &session,
                secrets::CARD_SECRET,
                json!({"name": "TOKEN"}),
                Duration::from_secs(60),
            )
            .await
        })
    };
    until(|| hub.secrets.waiting_in(&session.id)).await;
    assert_eq!(waiting_on(&hub, &session), "secret");
    let state = session.permissions.lock().unwrap_or_else(|e| e.into_inner());
    assert_eq!(hub.open_ask(&session, &state), Some(WaitReason::Secret));
    drop(state);
    hub.cancel_pending_secrets(&session);
    ask.await.unwrap();
}

/// A chat saved in Waiting has no card in this run: it loads working, and its host's re-ask on
/// adoption puts it back in Waiting with the card's reason. It never loads as a Waiting nobody
/// can explain.
#[test]
fn a_restored_waiting_chat_is_never_reasonless() {
    let hub = hub();
    hub.install_stored_session(meta("kept", "waiting"), true, true, true);
    hub.install_stored_session(meta("dropped", "waiting"), false, false, true);
    for id in ["kept", "dropped"] {
        let session = hub.sessions.lock().unwrap().get(id).cloned().unwrap();
        assert_ne!(session.status(), SessionStatus::Waiting, "{id}");
        assert_eq!(waiting_on(&hub, &session), Value::Null, "{id}");
    }
}
