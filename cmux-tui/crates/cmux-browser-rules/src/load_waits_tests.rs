//! The load waits, pinned to the cases `LoadWaits`'s doc comments name.

use crate::load_waits::*;
use crate::ops;
use serde_json::json;

fn met(id: u64) -> Resolution {
    Resolution { id, outcome: Outcome::Met }
}

fn failed(id: u64, message: &str) -> Resolution {
    Resolution { id, outcome: Outcome::Failed { message: message.into() } }
}

fn ticket(waits: &LoadWaits, navigation: u64, url: &str) -> Ticket {
    Ticket { navigation: Some(navigation), ..waits.begin_navigation(Some(url.into())) }
}

fn cancelled() -> LoadError {
    LoadError { domain: "NSURLErrorDomain".into(), code: -999, message: "cancelled".into() }
}

#[test]
fn load_states_are_ordered_and_networkidle_is_load() {
    assert!(LoadState::Commit < LoadState::Domcontentloaded);
    assert!(LoadState::Domcontentloaded < LoadState::Load);
    for name in ["commit", "domcontentloaded", "load"] {
        assert_eq!(LoadState::from_name(name).map(LoadState::name), Some(name));
    }
    assert_eq!(LoadState::from_name("networkidle"), Some(LoadState::Load));
    assert_eq!(LoadState::from_name("LOAD"), None);
}

#[test]
fn a_wait_is_met_by_its_own_navigations_commit_and_finish() {
    let mut waits = LoadWaits::default();
    let ticket = ticket(&waits, 1, "https://a.test/");
    assert!(!waits.reach(10, LoadState::Commit, &ticket));
    assert!(!waits.reach(11, LoadState::Load, &ticket));
    assert!(waits.navigation_event(&NavigationEvent::Started { id: 1 }).is_empty());
    // Another navigation's commit never meets it.
    let other = NavigationEvent::Committed { id: 2, url: Some("https://b.test/".into()) };
    assert!(waits.navigation_event(&other).is_empty());
    let commit = NavigationEvent::Committed { id: 1, url: Some("https://a.test/".into()) };
    assert_eq!(waits.navigation_event(&commit), vec![met(10)]);
    assert_eq!(waits.navigation_event(&NavigationEvent::Finished { id: 1 }), vec![met(11)]);
    assert_eq!(waits.pending_count(), 0);
}

#[test]
fn domcontentloaded_is_the_message_of_the_document_its_commit_made() {
    let mut waits = LoadWaits::default();
    let ticket = ticket(&waits, 1, "https://a.test/");
    waits.navigation_event(&NavigationEvent::Started { id: 1 });
    assert!(!waits.reach(1, LoadState::Domcontentloaded, &ticket));
    waits.navigation_event(&NavigationEvent::Committed {
        id: 1,
        url: Some("https://a.test/".into()),
    });
    assert!(waits.signal(LoadState::Commit, "doc-a").is_empty());
    assert_eq!(waits.generation, 1);
    // A late state of an older document is ignored.
    assert!(waits.signal(LoadState::Domcontentloaded, "doc-old").is_empty());
    assert_eq!(waits.state, Some(LoadState::Commit));
    assert_eq!(waits.signal(LoadState::Domcontentloaded, "doc-a"), vec![met(1)]);
}

#[test]
fn a_navigation_that_commits_about_blank_for_another_url_failed() {
    let mut waits = LoadWaits::default();
    let ticket = ticket(&waits, 3, "https://nowhere.invalid/");
    waits.navigation_event(&NavigationEvent::Started { id: 3 });
    waits.reach(7, LoadState::Load, &ticket);
    let commit = NavigationEvent::Committed { id: 3, url: Some("about:blank".into()) };
    assert_eq!(
        waits.navigation_event(&commit),
        vec![failed(7, "navigation failed: https://nowhere.invalid/ did not load")]
    );
    assert!(!is_blank_error_document(Some("about:blank"), Some("ABOUT:blank")));
    assert!(!is_blank_error_document(Some("https://a.test/"), Some("https://a.test/")));
}

#[test]
fn a_replaced_navigation_hands_its_wait_to_the_replacement() {
    // The replacement started before the cancel report.
    let mut waits = LoadWaits::default();
    let first = ticket(&waits, 1, "https://a.test/");
    waits.navigation_event(&NavigationEvent::Started { id: 1 });
    waits.reach(1, LoadState::Load, &first);
    waits.navigation_event(&NavigationEvent::Started { id: 2 });
    assert!(
        waits.navigation_event(&NavigationEvent::Failed { id: 1, error: cancelled() }).is_empty()
    );
    assert_eq!(waits.waits.get(&1).and_then(|wait| wait.navigation), Some(2));
    assert_eq!(waits.navigation_event(&NavigationEvent::Finished { id: 2 }), vec![met(1)]);

    // The replacement starts after it.
    let mut waits = LoadWaits::default();
    let first = ticket(&waits, 5, "https://a.test/");
    waits.navigation_event(&NavigationEvent::Started { id: 5 });
    waits.reach(1, LoadState::Commit, &first);
    let interrupted =
        LoadError { domain: "WebKitErrorDomain".into(), code: 102, message: String::new() };
    waits.navigation_event(&NavigationEvent::Failed { id: 5, error: interrupted });
    let wait = waits.waits.get(&1).cloned().unwrap();
    assert!(wait.follows_next_navigation && wait.navigation.is_none() && !wait.started);
    // Loading ending in between does not meet a wait that follows the next navigation.
    assert!(waits.loading_ended().is_empty());
    waits.navigation_event(&NavigationEvent::Started { id: 6 });
    let commit = NavigationEvent::Committed { id: 6, url: Some("https://a.test/".into()) };
    assert_eq!(waits.navigation_event(&commit), vec![met(1)]);
}

#[test]
fn a_real_failure_fails_its_waits() {
    let mut waits = LoadWaits::default();
    let ticket = ticket(&waits, 1, "https://a.test/");
    waits.reach(4, LoadState::Load, &ticket);
    let error =
        LoadError { domain: "NSURLErrorDomain".into(), code: -1003, message: "no host".into() };
    assert!(!error.is_benign_interruption());
    assert_eq!(
        waits.navigation_event(&NavigationEvent::Failed { id: 1, error }),
        vec![failed(4, "navigation failed: no host")]
    );
}

#[test]
fn a_navigation_that_never_started_was_same_document_when_loading_ends() {
    let mut waits = LoadWaits::default();
    let ticket = ticket(&waits, 9, "https://a.test/#x");
    assert!(!waits.reach(2, LoadState::Load, &ticket));
    assert_eq!(waits.loading_ended(), vec![met(2)]);
    // A call whose wait came after loading ended returns at once.
    assert!(waits.reach(3, LoadState::Load, &ticket));
    assert_eq!(waits.pending_count(), 0);
}

#[test]
fn a_same_document_navigation_meets_every_wait_and_later_calls() {
    let mut waits = LoadWaits::default();
    let before = waits.begin_navigation(None);
    let one = ticket(&waits, 1, "https://a.test/");
    waits.reach(1, LoadState::Load, &one);
    waits.reach(2, LoadState::Commit, &before);
    assert_eq!(waits.same_document(), vec![met(1), met(2)]);
    assert_eq!(waits.state, Some(LoadState::Load));
    // WebKit reports the same-document change inside the call, before its wait exists.
    assert!(waits.reach(3, LoadState::Load, &before));
}

#[test]
fn a_ticket_without_a_navigation_waits_for_the_next_document() {
    let mut waits = LoadWaits::default();
    let reload = waits.begin_navigation(None);
    assert!(!waits.reach(1, LoadState::Domcontentloaded, &reload));
    assert!(waits.signal(LoadState::Commit, "doc-1").is_empty());
    assert_eq!(waits.signal(LoadState::Domcontentloaded, "doc-1"), vec![met(1)]);
    // Already past it: the next call returns at once.
    assert!(waits.reach(2, LoadState::Commit, &reload));
    assert!(!waits.reach(3, LoadState::Load, &reload));
}

#[test]
fn deadlines_and_closes_end_what_is_pending() {
    let mut waits = LoadWaits::default();
    let ticket = ticket(&waits, 1, "https://a.test/");
    waits.reach(1, LoadState::Load, &ticket);
    waits.reach(2, LoadState::Load, &ticket);
    assert!(waits.expire(1));
    assert!(!waits.expire(1));
    assert_eq!(waits.fail_all(), vec![2]);
    assert_eq!(waits.pending_count(), 0);
}

#[test]
fn started_navigations_are_bounded() {
    let mut waits = LoadWaits::default();
    for id in 1..=40 {
        waits.navigation_event(&NavigationEvent::Started { id });
    }
    assert_eq!(waits.started_navigations.len(), 32);
    assert_eq!(waits.started_navigations.first(), Some(&9));
    assert_eq!(waits.latest_started, Some(40));
    waits.navigation_event(&NavigationEvent::Started { id: 3 });
    assert_eq!(waits.latest_started, Some(40));
}

#[test]
fn load_waits_op_carries_the_state_between_calls() {
    let reply = ops::call(
        "browser_rules_automation_load_waits",
        json!({"input": {"kind": "begin", "requestedUrl": "https://a.test/"}}),
    )
    .unwrap();
    assert_eq!(reply["ticket"]["requestedUrl"], json!("https://a.test/"));
    let mut ticket = reply["ticket"].clone();
    ticket["navigation"] = json!(1);
    let reply = ops::call(
        "browser_rules_automation_load_waits",
        json!({"state": reply["state"], "input": {"kind": "reach", "id": 5, "target": "load", "ticket": ticket}}),
    )
    .unwrap();
    assert_eq!(reply["met"], json!(false));
    let reply = ops::call(
        "browser_rules_automation_load_waits",
        json!({"state": reply["state"], "input": {"kind": "navigation", "event": {"kind": "finished", "id": 1}}}),
    )
    .unwrap();
    assert_eq!(reply["resolved"], json!([{"id": 5, "outcome": "met"}]));
    assert_eq!(reply["state"]["waits"], json!({}));
    let reply = ops::call(
        "browser_rules_automation_load_waits",
        json!({"state": reply["state"], "input": {"kind": "signal", "state": "commit", "document": "d"}}),
    )
    .unwrap();
    assert_eq!(reply["state"]["generation"], json!(1));
    assert_eq!(
        ops::call("browser_rules_automation_load_state", json!({"name": "networkidle"})).unwrap(),
        json!("load")
    );
}
