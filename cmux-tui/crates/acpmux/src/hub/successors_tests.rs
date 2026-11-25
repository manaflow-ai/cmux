//! `successors.rs`: a session answers for the sessions it took over and the roles it claimed.

use super::super::former_names::tests::{chat, hub};
use super::*;

#[test]
fn succeed_records_the_names_and_a_send_to_one_finds_the_heir() {
    let hub = hub();
    let heir = chat(&hub, "s2", "goal-ci-240936");
    let out = hub.succeed(&heir, &["far/goal-ci-a-2".to_owned()]).unwrap();
    assert_eq!(out["added"], json!(["far/goal-ci-a-2"]));
    assert_eq!(heir.meta().succeeds, ["far/goal-ci-a-2"]);
    match hub.successor_for("far/goal-ci-a-2") {
        Some(Ok(key)) => assert_eq!(key, "s2"),
        other => panic!("no successor: {other:?}"),
    }
    // A name some live session still has is never redirected.
    assert!(hub.successor_for("goal-ci-240936").is_none());
}

#[test]
fn a_second_heir_takes_the_name_from_the_first() {
    let hub = hub();
    let a = chat(&hub, "s1", "a");
    let b = chat(&hub, "s2", "b");
    hub.succeed(&a, &["far/old".to_owned()]).unwrap();
    hub.succeed(&b, &["far/old".to_owned()]).unwrap();
    assert!(a.meta().succeeds.is_empty(), "one heir per name here");
    assert!(matches!(hub.successor_for("far/old"), Some(Ok(k)) if k == "s2"));
}

#[test]
fn succeed_refuses_itself_and_bad_names() {
    let hub = hub();
    let a = chat(&hub, "s1", "a");
    assert!(hub.succeed(&a, &["a".to_owned()]).is_err());
    assert!(hub.succeed(&a, &["has space".to_owned()]).is_err());
    assert!(hub.succeed(&a, &[]).is_err());
}

#[test]
fn a_role_claim_moves_to_the_newest_claimant() {
    let hub = hub();
    let a = chat(&hub, "s1", "a");
    let b = chat(&hub, "s2", "b");
    hub.claim_role(&a, "goal:ci-linux").unwrap();
    assert!(matches!(hub.successor_for("goal:ci-linux"), Some(Ok(k)) if k == "s1"));
    let out = hub.claim_role(&b, "goal:ci-linux").unwrap();
    assert_eq!(out["releasedFrom"], json!(["a"]));
    assert!(a.meta().roles.is_empty());
    assert!(matches!(hub.successor_for("goal:ci-linux"), Some(Ok(k)) if k == "s2"));
    hub.release_role(&b, "goal:ci-linux").unwrap();
    assert!(hub.successor_for("goal:ci-linux").is_none());
    assert!(hub.release_role(&b, "goal:ci-linux").is_err(), "nothing held");
    assert!(hub.claim_role(&b, "goal:has space").is_err());
    assert!(hub.claim_role(&b, "lane:x").is_err());
}

#[test]
fn roles_list_shows_roles_and_successor_entries() {
    let hub = hub();
    let a = chat(&hub, "s1", "a");
    hub.claim_role(&a, "area:ci").unwrap();
    hub.succeed(&a, &["far/old".to_owned()]).unwrap();
    let ls = hub.roles_list();
    assert_eq!(ls["sessions"][0]["name"], "a");
    assert_eq!(ls["sessions"][0]["roles"][0]["address"], "area:ci");
    assert_eq!(ls["sessions"][0]["succeeds"], json!(["far/old"]));
}

#[test]
fn the_heartbeat_row_lists_successor_entries_and_roles() {
    let former = crate::mesh::heartbeat_former_names(&["old".into()], &["far/x".into()]);
    assert_eq!(former, ["old", "far/x"]);
}
