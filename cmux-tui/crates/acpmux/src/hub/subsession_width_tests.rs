//! Which sub-sessions hold a width slot of their parent (`subsession_index.rs`, Leo:
//! "0 open sub-sessions and may have at most 50 open at once ... WTF IS IT COUNTING"). A child
//! counts while its harness is alive (ready, running, waiting); a hibernated (idle), dead
//! (disconnected) or closed one keeps its history but frees its slot.

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
        .filter(|e| e.dir == "mux" && e.kind == RECORD_KIND)
        .filter(|e| e.msg["childSessionId"] == child.id.as_str())
        .map(|e| e.msg["event"].as_str().unwrap_or_default().to_owned())
        .collect()
}

#[test]
fn width_slots_count_live_children_only() {
    let index = Index::default();
    index.note_status("parent", "finished", SessionStatus::Idle);
    index.note_status("parent", "dead", SessionStatus::Disconnected);
    index.note_status("parent", "closed", SessionStatus::Closed);
    index.note_status("parent", "live", SessionStatus::Running);

    assert_eq!(index.live_count("parent"), 1);
    // Not closed: the work below a parent looks at them all (`work_below.rs`).
    assert_eq!(index.open_children("parent"), vec!["dead", "finished", "live"]);
    assert!(index.reserve("parent", 1, &[]).is_err(), "the live child still binds the cap");

    index.note_status("parent", "live", SessionStatus::Idle);
    assert_eq!(index.live_count("parent"), 0);
    assert!(index.reserve("parent", 1, &[]).is_ok(), "finished children free the slot");
    // A waking child that is not live counts; a live one counts once, a closed one or a name
    // it does not know counts for nothing.
    let waking = ["finished".to_owned(), "closed".to_owned(), "gone".to_owned()];
    assert_eq!(index.reserve("parent", 1, &waking).err(), Some(1), "a waking child binds it");
    index.note_status("parent", "finished", SessionStatus::Running);
    assert_eq!(index.used("parent", &waking), 1, "a live waking child counts once");
}

#[tokio::test]
async fn only_live_children_hold_a_width_slot() {
    let (hub, parent) = hub_with_parent().await;
    let child = child_of(&hub, &parent, "a").await;
    let count = || hub.width_used(&parent.id);
    let reserve = || hub.subsessions.reserve(&parent.id, 1, &hub.waking_children(&parent.id));
    assert_eq!(child.status(), SessionStatus::Ready);
    assert_eq!(count(), 1, "a child whose harness is up holds a slot");

    for live in [SessionStatus::Running, SessionStatus::Waiting, SessionStatus::Ready] {
        hub.set_status(&child, live);
        assert_eq!(count(), 1, "a {live} child holds a slot");
    }

    // Hibernated after its turn: its harness exited, its history stays.
    hub.set_status(&child, SessionStatus::Idle);
    assert_eq!(count(), 0, "a finished, hibernated child frees its slot");
    drop(reserve().expect("the freed slot takes a new start"));

    // A prompt queued for it (behind a turn, or for one of the parent's run slots) will wake it.
    child.queued.fetch_add(1, Ordering::SeqCst);
    assert_eq!(count(), 1, "a child with a queued prompt holds a slot");
    assert!(reserve().is_err(), "a start never takes the slot its wake needs");
    child.queued.fetch_sub(1, Ordering::SeqCst);
    // Its prompt holds the turn lock while its harness starts.
    let starting = child.turn_lock.lock().await;
    assert_eq!(count(), 1, "a child starting its harness for a prompt holds a slot");
    assert!(reserve().is_err());
    hub.set_status(&child, SessionStatus::Running);
    drop(starting);
    assert_eq!(count(), 1, "a woken child holds its slot");

    // Its harness died.
    hub.set_status(&child, SessionStatus::Disconnected);
    assert_eq!(count(), 0, "a dead child frees its slot");

    hub.set_status(&child, SessionStatus::Ready);
    hub.kill(&child, false).await.unwrap();
    assert_eq!(child.status(), SessionStatus::Closed);
    assert_eq!(count(), 0, "a closed child frees its slot");
    assert_eq!(hub.subsessions.open_count(&parent.id), 0);

    // The parent's log says closed only for the real close: hibernating and dying are not one.
    assert_eq!(child_events(&hub, &parent, &child), ["closed"]);
}
