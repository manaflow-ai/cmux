//! `LoadWaits` cases, from its doc comments (no Swift test covers the type).

use crate::load_waits::*;

fn waits_for(
    w: &mut LoadWaits,
    target: LoadState,
    navigation: Option<u64>,
    url: Option<&str>,
) -> u64 {
    let mut ticket = w.snapshot();
    ticket.navigation = navigation;
    ticket.requested_url = url.map(str::to_owned);
    match w.reach(target, &ticket) {
        Reach::Pending { wait } => wait,
        Reach::Met => panic!("met at once"),
    }
}

fn ids(r: &[Resolution]) -> Vec<u64> {
    r.iter().map(|r| r.wait).collect()
}

#[test]
fn load_state_names_and_order() {
    assert_eq!(LoadState::from_name("networkidle"), Some(LoadState::Load));
    assert_eq!(LoadState::from_name("load"), Some(LoadState::Load));
    assert_eq!(LoadState::from_name("bogus"), None);
    assert!(LoadState::Commit < LoadState::Domcontentloaded);
    assert!(LoadState::Domcontentloaded < LoadState::Load);
    assert_eq!(LoadState::Domcontentloaded.name(), "domcontentloaded");
}

#[test]
fn commit_and_finish_meet_their_navigations_wait() {
    let mut w = LoadWaits::default();
    let commit = waits_for(&mut w, LoadState::Commit, Some(1), None);
    let load = waits_for(&mut w, LoadState::Load, Some(1), None);
    waits_for(&mut w, LoadState::Load, Some(2), None);
    w.navigation_event(&NavigationEvent::Started { id: 1 });
    let r =
        w.navigation_event(&NavigationEvent::Committed { id: 1, url: Some("https://a/".into()) });
    assert_eq!(ids(&r), vec![commit]);
    let r = w.navigation_event(&NavigationEvent::Finished { id: 1 });
    assert_eq!(ids(&r), vec![load]);
    assert_eq!(w.pending_count(), 1);
}

#[test]
fn domcontentloaded_comes_from_the_committed_documents_state_message() {
    let mut w = LoadWaits::default();
    let dcl = waits_for(&mut w, LoadState::Domcontentloaded, Some(1), None);
    w.navigation_event(&NavigationEvent::Started { id: 1 });
    w.navigation_event(&NavigationEvent::Committed { id: 1, url: None });
    assert!(w.signal(LoadState::Commit, "doc-a").is_empty());
    // A late state from an older document is ignored.
    assert!(w.signal(LoadState::Domcontentloaded, "old").is_empty());
    assert_eq!(ids(&w.signal(LoadState::Domcontentloaded, "doc-a")), vec![dcl]);
    assert_eq!(w.state, Some(LoadState::Domcontentloaded));
}

#[test]
fn a_state_before_any_commit_is_ignored() {
    let mut w = LoadWaits::default();
    assert!(w.signal(LoadState::Load, "x").is_empty());
    assert_eq!(w.state, None);
}

#[test]
fn a_commit_of_another_document_never_meets_the_wait() {
    let mut w = LoadWaits::default();
    waits_for(&mut w, LoadState::Commit, Some(1), None);
    let r = w.navigation_event(&NavigationEvent::Committed { id: 5, url: None });
    assert!(r.is_empty());
    assert_eq!(w.pending_count(), 1);
}

#[test]
fn a_wait_with_no_navigation_takes_the_next_committed_document() {
    let mut w = LoadWaits::default();
    let wait = waits_for(&mut w, LoadState::Load, None, None);
    assert!(w.signal(LoadState::Commit, "d1").is_empty());
    assert_eq!(ids(&w.signal(LoadState::Load, "d1")), vec![wait]);
    // The state already reached by a later document meets a ticket from before it at once.
    let ticket = Ticket::default();
    assert_eq!(w.reach(LoadState::Load, &ticket), Reach::Met);
}

#[test]
fn a_blank_document_for_a_requested_url_failed() {
    let mut w = LoadWaits::default();
    let wait = waits_for(&mut w, LoadState::Load, Some(1), Some("https://down.example/"));
    w.navigation_event(&NavigationEvent::Started { id: 1 });
    let r =
        w.navigation_event(&NavigationEvent::Committed { id: 1, url: Some("about:blank".into()) });
    assert_eq!(r.len(), 1);
    assert_eq!(r[0].wait, wait);
    assert_eq!(
        r[0].error,
        Some(WaitError {
            kind: ErrorKind::Invalid,
            message: "navigation failed: https://down.example/ did not load".into()
        })
    );
}

#[test]
fn blank_error_document_rules() {
    assert!(is_blank_error_document(Some("about:blank"), Some("https://a/")));
    assert!(!is_blank_error_document(Some("about:blank"), Some("ABOUT:blank")));
    assert!(!is_blank_error_document(Some("about:blank"), None));
    assert!(!is_blank_error_document(Some("https://a/"), Some("https://a/")));
    assert!(!is_blank_error_document(None, Some("https://a/")));
}

#[test]
fn a_failure_fails_the_wait_and_a_benign_one_hands_it_on() {
    let mut w = LoadWaits::default();
    let wait = waits_for(&mut w, LoadState::Load, Some(1), None);
    w.navigation_event(&NavigationEvent::Started { id: 1 });
    // Replaced by 2, which started before the report.
    w.navigation_event(&NavigationEvent::Started { id: 2 });
    let r = w.navigation_event(&NavigationEvent::Failed {
        id: 1,
        benign: true,
        message: "cancelled".into(),
    });
    assert!(r.is_empty());
    assert_eq!(ids(&w.navigation_event(&NavigationEvent::Finished { id: 2 })), vec![wait]);

    let wait = waits_for(&mut w, LoadState::Load, Some(3), None);
    w.navigation_event(&NavigationEvent::Started { id: 3 });
    let r = w.navigation_event(&NavigationEvent::Failed {
        id: 3,
        benign: false,
        message: "offline".into(),
    });
    assert_eq!(r[0].wait, wait);
    assert_eq!(r[0].error.as_ref().unwrap().message, "navigation failed: offline");
}

#[test]
fn a_benign_failure_with_no_replacement_follows_the_next_navigation() {
    let mut w = LoadWaits::default();
    let wait = waits_for(&mut w, LoadState::Load, Some(1), None);
    w.navigation_event(&NavigationEvent::Started { id: 1 });
    w.navigation_event(&NavigationEvent::Failed { id: 1, benign: true, message: String::new() });
    // Loading ending does not meet a wait that follows the next navigation.
    assert!(w.loading_ended().is_empty());
    w.navigation_event(&NavigationEvent::Started { id: 4 });
    assert_eq!(ids(&w.navigation_event(&NavigationEvent::Finished { id: 4 })), vec![wait]);
}

#[test]
fn loading_ending_meets_a_navigation_that_never_started() {
    let mut w = LoadWaits::default();
    let never = waits_for(&mut w, LoadState::Load, Some(1), None);
    waits_for(&mut w, LoadState::Load, Some(2), None);
    w.navigation_event(&NavigationEvent::Started { id: 2 });
    assert_eq!(ids(&w.loading_ended()), vec![never]);
    assert_eq!(w.pending_count(), 1);
}

#[test]
fn a_same_document_navigation_meets_every_wait_and_earlier_tickets() {
    let mut w = LoadWaits::default();
    let ticket = w.snapshot();
    let a = waits_for(&mut w, LoadState::Load, Some(1), None);
    let b = waits_for(&mut w, LoadState::Commit, None, None);
    assert_eq!(ids(&w.same_document()), vec![a, b]);
    assert_eq!(w.state, Some(LoadState::Load));
    assert_eq!(w.generation, 1);
    assert_eq!(w.reach(LoadState::Load, &ticket), Reach::Met);
}

#[test]
fn reach_is_met_when_loading_ended_for_an_unstarted_navigation() {
    let mut w = LoadWaits::default();
    let mut ticket = w.snapshot();
    ticket.navigation = Some(9);
    w.loading_ended();
    assert_eq!(w.reach(LoadState::Load, &ticket), Reach::Met);
}

#[test]
fn timeout_and_fail_all() {
    let mut w = LoadWaits::default();
    let a = waits_for(&mut w, LoadState::Domcontentloaded, Some(1), None);
    let b = waits_for(&mut w, LoadState::Load, Some(2), None);
    let r = w.timed_out(a, "page.goto", "30.0 seconds").unwrap();
    assert_eq!(
        r.error,
        Some(WaitError {
            kind: ErrorKind::Timeout,
            message: "page.goto: Timeout 30.0 seconds exceeded waiting for domcontentloaded".into()
        })
    );
    assert!(w.timed_out(a, "x", "y").is_none());
    let closed = WaitError {
        kind: ErrorKind::Closed,
        message: "the page's web content process ended".into(),
    };
    let r = w.fail_all(&closed);
    assert_eq!(ids(&r), vec![b]);
    assert_eq!(r[0].error, Some(closed));
    assert_eq!(w.pending_count(), 0);
}

#[test]
fn only_the_last_32_started_navigations_are_kept() {
    let mut w = LoadWaits::default();
    for id in 0..40 {
        w.navigation_event(&NavigationEvent::Started { id });
    }
    // 0 was dropped: it counts as unstarted, so a later loading end meets its ticket.
    let mut ticket = w.snapshot();
    ticket.navigation = Some(0);
    w.loading_ended();
    assert_eq!(w.reach(LoadState::Load, &ticket), Reach::Met);
    // 39 is kept: the same ticket for it waits.
    ticket.navigation = Some(39);
    assert!(matches!(w.reach(LoadState::Load, &ticket), Reach::Pending { .. }));
}

#[test]
fn the_machine_round_trips_through_json() {
    let mut w = LoadWaits::default();
    waits_for(&mut w, LoadState::Load, Some(1), Some("https://a/"));
    w.navigation_event(&NavigationEvent::Started { id: 1 });
    let again: LoadWaits = serde_json::from_value(serde_json::to_value(&w).unwrap()).unwrap();
    assert_eq!(again, w);
}
