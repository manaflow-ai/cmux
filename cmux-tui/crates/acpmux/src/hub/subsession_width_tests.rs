//! Which sub-sessions hold a width slot of their parent (`subsessions.rs`, Leo:
//! "0 open sub-sessions and may have at most 50 open at once ... WTF IS IT COUNTING"). A child
//! counts while its harness is alive (ready, running, waiting); a hibernated (idle), dead
//! (disconnected) or closed one keeps its history but frees its slot. `open_count` is what a
//! start's reservation weighs against `maxChildren`.

use super::*;
use crate::config::{Config, StoreMode};
use crate::store::SubsessionLink;
use std::path::Path;

async fn hub_with_parent() -> (Arc<Hub>, Arc<Session>) {
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
    let parent = hub.new_session(req).await.unwrap();
    (hub, parent)
}

async fn child_of(hub: &Arc<Hub>, parent: &Session, short: &str) -> Arc<Session> {
    let req = NewRequest {
        cwd: Some(std::env::temp_dir()),
        subsession: Some(SubsessionLink {
            started_by: parent.id.clone(),
            short_name: short.to_owned(),
            depth: 1,
            offered: false,
        }),
        ..NewRequest::default()
    };
    hub.new_session(req).await.unwrap()
}

/// The `subsession` record events about `child` on `parent`'s log.
fn child_events(hub: &Hub, parent: &Session, child: &Session) -> Vec<String> {
    let events = hub.events(&parent.id, 0, 10_000).unwrap();
    events
        .into_iter()
        .filter(|e| e.dir == "mux" && e.kind == crate::hub::subsessions::RECORD_KIND)
        .filter(|e| e.msg["childSessionId"] == child.id.as_str())
        .map(|e| e.msg["event"].as_str().unwrap_or_default().to_owned())
        .collect()
}

#[tokio::test]
async fn only_live_children_hold_a_width_slot() {
    let (hub, parent) = hub_with_parent().await;
    let child = child_of(&hub, &parent, "a").await;
    let count = || hub.subsessions.open_count(&parent.id);
    assert_eq!(child.status(), SessionStatus::Ready);
    assert_eq!(count(), 1, "a child whose harness is up holds a slot");

    for live in [SessionStatus::Running, SessionStatus::Waiting, SessionStatus::Ready] {
        hub.set_status(&child, live);
        assert_eq!(count(), 1, "a {live} child holds a slot");
    }

    // Hibernated after its turn: its harness exited, its history stays.
    hub.set_status(&child, SessionStatus::Idle);
    assert_eq!(count(), 0, "a finished, hibernated child frees its slot");

    // Woken by a prompt: it holds a slot again.
    hub.set_status(&child, SessionStatus::Running);
    assert_eq!(count(), 1, "a woken child holds its slot again");

    // Its harness died.
    hub.set_status(&child, SessionStatus::Disconnected);
    assert_eq!(count(), 0, "a dead child frees its slot");

    hub.set_status(&child, SessionStatus::Ready);
    hub.kill(&child, false).await.unwrap();
    assert_eq!(child.status(), SessionStatus::Closed);
    assert_eq!(count(), 0, "a closed child frees its slot");

    // The parent's log says closed only for the real close: hibernating and dying are not one.
    assert_eq!(child_events(&hub, &parent, &child), ["closed"]);
}
