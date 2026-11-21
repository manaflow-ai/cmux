//! A sub-session that waits on the person makes every chat above it read `input`
//! (cmuxterm-hq#7794 #7: a subagent's ask stalled its run where nobody looked).

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

async fn child_of(hub: &Arc<Hub>, parent: &Session, short: &str, depth: u32) -> Arc<Session> {
    let req = NewRequest {
        cwd: Some(std::env::temp_dir()),
        subsession: Some(SubsessionLink {
            started_by: parent.id.clone(),
            short_name: short.to_owned(),
            depth,
            offered: false,
            worktree: None,
            plan_build_change: None,
        }),
        ..NewRequest::default()
    };
    hub.new_session(req).await.unwrap()
}

/// The counts `subsessions_waiting` records carried on `session`'s log, in order.
fn recorded(hub: &Hub, session: &Session) -> Vec<u64> {
    hub.events(&session.id, 0, 10_000)
        .unwrap()
        .into_iter()
        .filter(|e| e.dir == "mux" && e.kind == RECORD_KIND)
        .map(|e| e.msg["count"].as_u64().unwrap())
        .collect()
}

#[tokio::test]
async fn a_waiting_child_or_grandchild_makes_its_ancestors_read_input() {
    let (hub, parent) = hub_with_parent().await;
    let child = child_of(&hub, &parent, "tests", 1).await;
    let grandchild = child_of(&hub, &child, "lint", 2).await;
    hub.set_status(&parent, SessionStatus::Running);
    hub.set_status(&child, SessionStatus::Running);
    assert_eq!(hub.session_summary(&parent)["indicator"], "working");

    // The child asks to run a command: its parent's row says the person is needed.
    hub.set_status(&child, SessionStatus::Waiting);
    let summary = hub.session_summary(&parent);
    assert_eq!(summary["subsessionsWaiting"], 1, "{summary}");
    assert!(summary["subsessionsWaitingSince"].is_u64(), "{summary}");
    assert_eq!(summary["indicator"], "input", "{summary}");
    assert_eq!(summary["lane"]["state"], "input", "{summary}");
    assert!(parent.waits_below(), "the chats list marks it needsInput too");

    // A grandchild asks too: both count on the root, the child counts its own one.
    let since = summary["subsessionsWaitingSince"].clone();
    hub.set_status(&grandchild, SessionStatus::Waiting);
    assert_eq!(hub.session_summary(&parent)["subsessionsWaiting"], 2);
    assert_eq!(
        hub.session_summary(&parent)["subsessionsWaitingSince"],
        since,
        "the first ask dates it"
    );
    assert_eq!(hub.session_summary(&child)["subsessionsWaiting"], 1);

    // Answered: the child runs again, then the grandchild; the parent works, never stuck on input.
    hub.set_status(&child, SessionStatus::Running);
    hub.set_status(&grandchild, SessionStatus::Running);
    let summary = hub.session_summary(&parent);
    assert_eq!(summary["subsessionsWaiting"], 0, "{summary}");
    assert!(summary["subsessionsWaitingSince"].is_null(), "{summary}");
    assert_eq!(summary["indicator"], "working", "{summary}");
    assert_eq!(recorded(&hub, &parent), vec![1, 2, 1, 0], "each change is one record");
    hub.shutdown_all().await;
}

/// A closed child holds nothing open, whatever it waited on.
#[tokio::test]
async fn closing_a_waiting_child_clears_its_parent() {
    let (hub, parent) = hub_with_parent().await;
    let child = child_of(&hub, &parent, "tests", 1).await;
    hub.set_status(&child, SessionStatus::Waiting);
    assert_eq!(hub.session_summary(&parent)["subsessionsWaiting"], 1);
    hub.set_status(&child, SessionStatus::Closed);
    assert_eq!(hub.session_summary(&parent)["subsessionsWaiting"], 0);
    assert_ne!(hub.session_summary(&parent)["indicator"], "input");
    hub.shutdown_all().await;
}

#[test]
fn chat_lists_hear_of_a_change() {
    assert!(crate::chats::changes_activity(RECORD_KIND));
}

/// A child restored as Waiting changes no status when its host is adopted (`hosts.rs`), so the
/// adoption re-decides its parent's count, which a new daemon starts at none.
#[tokio::test]
async fn a_child_restored_waiting_counts_once_its_parent_is_redecided() {
    let (hub, parent) = hub_with_parent().await;
    let child = child_of(&hub, &parent, "tests", 1).await;
    child.meta.lock().unwrap().status = SessionStatus::Waiting;
    hub.subsessions.note_status(&parent.id, &child.id, SessionStatus::Waiting);
    assert_eq!(hub.session_summary(&parent)["subsessionsWaiting"], 0, "nothing decided it yet");
    hub.refresh_parent_asks_below(&child);
    assert_eq!(hub.session_summary(&parent)["subsessionsWaiting"], 1);
    assert_eq!(hub.session_summary(&parent)["indicator"], "input");
    hub.shutdown_all().await;
}
