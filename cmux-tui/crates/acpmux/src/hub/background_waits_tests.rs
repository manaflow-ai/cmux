//! The working shelf's count: what a chat waits on that wakes it by itself reaches its summary
//! as `backgroundWaits`, and each change is a record watchers hear as `session_changed`.

use super::*;
use crate::agent::Direction;
use crate::config::{Config, StoreMode};
use crate::rpc::Message;
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

fn waits(hub: &Hub, session: &Session) -> Value {
    hub.session_summary(session).get("backgroundWaits").cloned().unwrap_or(Value::Null)
}

fn recorded(hub: &Hub, session: &Session) -> Vec<Value> {
    hub.events(&session.id, 0, 10_000)
        .unwrap()
        .into_iter()
        .filter(|e| e.dir == "mux" && e.kind == RECORD_KIND)
        .map(|e| e.msg["count"].clone())
        .collect()
}

/// Leo's done-when: "a chat waiting on a 60 s background job folds and comes back when it ends".
/// A running task that brings its end to the chat counts while it runs and not once it ended; a
/// task without `notify` never counts.
#[cfg(unix)]
#[tokio::test]
async fn a_running_notify_task_is_a_background_wait_until_it_ends() {
    let (hub, session) = chat().await;
    assert_eq!(waits(&hub, &session), Value::Null, "nothing waits yet");

    let quiet = hub.bg_fake_running(&session, false).unwrap();
    hub.refresh_background_tasks(&session);
    assert_eq!(waits(&hub, &session), Value::Null, "a task without notify wakes nothing");

    let run = hub.bg_fake_running(&session, true).unwrap();
    hub.refresh_background_tasks(&session);
    assert_eq!(waits(&hub, &session), json!(1));

    drop(run);
    hub.refresh_background_tasks(&session);
    assert_eq!(waits(&hub, &session), Value::Null, "absent at 0 once the task ended");
    assert_eq!(recorded(&hub, &session), vec![json!(1), json!(0)], "one record per change");
    assert_eq!(
        crate::server::session_change_kind(RECORD_KIND),
        Some(RECORD_KIND),
        "watchers hear each change as session_changed"
    );
    drop(quiet);
    hub.shutdown_all().await;
}

/// A live watch that wakes the chat counts from its add to its removal, with no refresh asked.
#[tokio::test]
async fn a_watch_to_the_chat_is_a_background_wait() {
    let (hub, session) = chat().await;
    let watched = hub
        .new_session(NewRequest { cwd: Some(std::env::temp_dir()), ..NewRequest::default() })
        .await
        .unwrap();
    let id = "w-background-waits".to_owned();
    hub.watches
        .add(
            &hub,
            watches::Watch {
                id: id.clone(),
                to: session.id.clone(),
                sessions: vec![watched.id.clone()],
                until: vec!["ready".into()],
                match_text: None,
                once: true,
                caller: None,
                active: true,
                cursors: Default::default(),
                offline: Default::default(),
                ..Default::default()
            },
        )
        .unwrap();
    assert_eq!(waits(&hub, &session), json!(1));
    assert_eq!(waits(&hub, &watched), Value::Null, "the watched chat waits on nothing");

    hub.watches.remove(&hub, &id).unwrap();
    assert_eq!(waits(&hub, &session), Value::Null);
    assert_eq!(recorded(&hub, &session), vec![json!(1), json!(0)]);
    hub.shutdown_all().await;
}

/// A background subagent still running counts; a foreground one is the turn's own work.
#[tokio::test]
async fn a_background_subagent_is_a_background_wait() {
    let (hub, session) = chat().await;
    session.meta.lock().unwrap().agent_session_id = Some("acp-root".to_owned());
    let tap = hub.session_tap(&session);
    let update = |update: Value| Message::Notification {
        method: crate::rpc::method::SESSION_UPDATE.to_owned(),
        params: Some(json!({"sessionId": "acp-root", "update": update})),
    };
    tap(
        Direction::In,
        &update(json!({"sessionUpdate": "subagent_spawned", "subagentSessionId": "fg",
            "name": "Read the logs", "background": false})),
        None,
    );
    assert_eq!(waits(&hub, &session), Value::Null, "a foreground subagent is not a wait");
    tap(
        Direction::In,
        &update(json!({"sessionUpdate": "subagent_spawned", "subagentSessionId": "bg",
            "name": "Fix the build", "background": true})),
        None,
    );
    assert_eq!(waits(&hub, &session), json!(1));
    tap(
        Direction::In,
        &update(json!({"sessionUpdate": "subagent_state_update", "subagentSessionId": "bg",
            "state": "completed"})),
        None,
    );
    assert_eq!(waits(&hub, &session), Value::Null);
    hub.shutdown_all().await;
}
