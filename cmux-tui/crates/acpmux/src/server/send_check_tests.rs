//! `send_check.rs`: what one read of the hub's address book says about a send's name.

use super::*;
use crate::mesh::{BookDaemon, RoleClaim};

fn row(host: &str, name: &str, former: &[&str], roles: &[(&str, u64)]) -> BookSession {
    BookSession {
        name: name.into(),
        session_id: format!("id-{name}"),
        host: host.into(),
        former_names: former.iter().map(|n| (*n).to_owned()).collect(),
        roles: roles
            .iter()
            .map(|(a, at)| RoleClaim { address: (*a).into(), claimed_at: *at })
            .collect(),
        ..BookSession::default()
    }
}

fn book(daemons: &[&str], sessions: Vec<BookSession>) -> AddressBook {
    AddressBook {
        daemons: daemons
            .iter()
            .map(|h| BookDaemon { host: (*h).into(), ..BookDaemon::default() })
            .collect(),
        sessions,
    }
}

#[test]
fn a_bare_peer_session_id_is_qualified_with_its_host() {
    let b = book(&["far"], vec![row("far", "lane", &[], &[])]);
    assert_eq!(qualified(&b, "id-lane"), Some("far/id-lane".into()));
    assert_eq!(qualified(&b, "id-other"), None);
    // Two hosts listing one id is not a single session: left as it was.
    let b = book(&["a", "b"], vec![row("a", "lane", &[], &[]), row("b", "lane", &[], &[])]);
    assert_eq!(qualified(&b, "id-lane"), None);
}

#[test]
fn a_bare_id_on_no_host_is_refused_at_once_and_a_bare_name_is_left_alone() {
    let id = "01a215f7-98cd-76b1-8baf-fa47cb047481";
    let mut lane = row("far", "lane", &[], &[]);
    lane.session_id = id.into();
    let b = book(&["far"], vec![lane]);
    assert_eq!(bare_id(&b, id), Check::Successor(format!("far/{id}")));
    let empty = book(&["far"], vec![row("far", "other", &[], &[])]);
    let Check::Refuse(text) = bare_id(&empty, id) else { panic!("not refused") };
    assert!(text.contains("HOST/ID"), "{text}");
    // Not an id's shape: a role or a peer's short name this check cannot see is never refused.
    assert_eq!(bare_id(&empty, "lane"), Check::Queue(None));
}

#[test]
fn a_live_session_on_the_book_is_queued_checked() {
    let b = book(&["far"], vec![row("far", "lane", &[], &[])]);
    assert_eq!(in_book(&b, "far/lane"), Check::Queue(None));
}

#[test]
fn a_successor_takes_a_dead_name_by_host_name_or_bare_name_on_its_host() {
    let b = book(&["near"], vec![row("near", "lane-2", &["far/lane"], &[])]);
    assert_eq!(in_book(&b, "far/lane"), Check::Successor("near/lane-2".into()));
    let b = book(&["far"], vec![row("far", "lane-2", &["lane"], &[])]);
    assert_eq!(in_book(&b, "far/lane"), Check::Successor("far/lane-2".into()));
    // A bare former name on another host is not this one.
    let b = book(&["near"], vec![row("near", "lane-2", &["lane"], &[])]);
    assert!(matches!(in_book(&b, "far/lane"), Check::Queue(Some(_))));
}

#[test]
fn several_successors_are_refused_with_their_names() {
    let b = book(
        &["a", "b"],
        vec![row("a", "x", &["far/lane"], &[]), row("b", "y", &["far/lane"], &[])],
    );
    let Check::Refuse(text) = in_book(&b, "far/lane") else { panic!("not refused") };
    assert!(text.contains("a/x") && text.contains("b/y"), "{text}");
}

#[test]
fn a_live_host_without_the_name_is_no_session_and_a_down_one_is_unchecked() {
    let b = book(&["far"], vec![row("far", "other", &[], &[])]);
    assert!(matches!(in_book(&b, "far/gone"), Check::Refuse(_)));
    let b = book(&[], vec![]);
    let Check::Queue(Some(why)) = in_book(&b, "far/gone") else { panic!("not unchecked") };
    assert!(why.starts_with("not checked"), "{why}");
}

#[test]
fn a_role_goes_to_its_latest_claim() {
    let b = book(
        &["a", "b"],
        vec![row("a", "old", &[], &[("goal:ci", 1)]), row("b", "new", &[], &[("goal:ci", 2)])],
    );
    assert_eq!(in_book(&b, "goal:ci"), Check::Successor("b/new".into()));
    assert!(matches!(in_book(&b, "goal:nobody"), Check::Refuse(_)));
}
