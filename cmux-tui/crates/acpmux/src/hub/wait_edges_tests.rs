use super::super::NewRequest;
use super::super::host_level::FOR_NO_PERSON;
use super::*;
use crate::subrouter_priority::{BACKGROUND, INTERACTIVE};
use std::sync::atomic::Ordering;

fn test_hub() -> Arc<Hub> {
    let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
    let mut cfg: crate::config::Config = serde_json::from_value(serde_json::json!({
        "harnesses": {"fake": {"argv": ["python3", fake]}},
        "defaultHarness": "fake",
    }))
    .unwrap();
    cfg.store.mode = crate::config::StoreMode::Memory;
    let store = crate::store::open(&cfg.store, std::path::Path::new("/nonexistent")).unwrap();
    Hub::new(cfg, store)
}

/// An agent's chat named `name`: no person's, so its class comes from its name and role.
async fn chat(hub: &Arc<Hub>, name: &str) -> Arc<Session> {
    let s = hub
        .new_session(NewRequest {
            cwd: Some(std::env::temp_dir()),
            name: Some(name.to_owned()),
            ..NewRequest::default()
        })
        .await
        .unwrap();
    s.start_for.store(FOR_NO_PERSON, Ordering::SeqCst);
    s
}

fn own(hub: &Hub, s: &Session) -> &'static str {
    hub.subrouter_priority(s, &s.meta(), hub.for_a_person(s))
}

#[cfg(unix)]
#[tokio::test]
async fn a_lane_runs_at_the_coordinators_class_while_it_waits_and_drops_back_after() {
    let hub = test_hub();
    let coord = chat(&hub, "ops-coord").await;
    let lane = chat(&hub, "lane-build").await;
    let helper = chat(&hub, "lane-build-helper").await;
    let other = chat(&hub, "lane-other").await;
    assert_eq!(own(&hub, &coord), INTERACTIVE);
    assert_eq!(own(&hub, &lane), BACKGROUND);
    assert_eq!(hub.inherit_priority(&lane, BACKGROUND), BACKGROUND, "nobody waits yet");

    let coord_waits = hub.wait_edge(Some(&coord.id), std::slice::from_ref(&lane.id));
    let lane_waits = hub.wait_edge(Some(&lane.id), std::slice::from_ref(&helper.id));
    assert_eq!(hub.inherit_priority(&lane, BACKGROUND), INTERACTIVE);
    assert_eq!(hub.inherit_priority(&helper, BACKGROUND), INTERACTIVE, "through the lane");
    assert_eq!(hub.inherit_priority(&other, BACKGROUND), BACKGROUND, "only the lane waited on");

    drop(coord_waits);
    assert_eq!(hub.inherit_priority(&lane, BACKGROUND), BACKGROUND, "the wait ended");
    assert_eq!(hub.inherit_priority(&helper, BACKGROUND), BACKGROUND);
    drop(lane_waits);
    assert!(hub.waiters_of(&helper.id).is_empty());
    assert!(hub.wait_edges.by_target.lock().unwrap().is_empty(), "no edge outlives its wait");
}

#[cfg(unix)]
#[tokio::test]
async fn overlapping_waits_count_and_a_self_wait_or_no_caller_adds_nothing() {
    let hub = test_hub();
    let coord = chat(&hub, "ops-coord").await;
    let lane = chat(&hub, "lane-build").await;
    let ids = [lane.id.clone(), lane.id.clone()];
    let a = hub.wait_edge(Some(&coord.id), &ids);
    let b = hub.wait_edge(Some(&coord.id), std::slice::from_ref(&lane.id));
    drop(a);
    assert_eq!(hub.inherit_priority(&lane, BACKGROUND), INTERACTIVE, "the second wait holds");
    drop(b);
    assert_eq!(hub.inherit_priority(&lane, BACKGROUND), BACKGROUND);
    let _none = hub.wait_edge(None, std::slice::from_ref(&lane.id));
    let _own = hub.wait_edge(Some(&lane.id), std::slice::from_ref(&lane.id));
    assert!(hub.waiters_of(&lane.id).is_empty());
}
