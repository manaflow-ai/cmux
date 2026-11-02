//! `workspace_group.create {reuse: true}`: an agent that puts each of its
//! lanes "in Leads" asks for that group once per lane. Each ask answers the
//! room's group of that name, so the sidebar shows one "Leads", not one per
//! lane (Leo, 2026-11-02: fifteen "Leads" groups of one row each).

use serde_json::json;

use super::tests::{Session, mutate, read};

fn group_names(mux: &std::sync::Arc<crate::mux::Mux>) -> Vec<String> {
    read(mux, "workspace_group.list", json!({}))
        .as_array()
        .unwrap()
        .iter()
        .map(|group| group["name"].as_str().unwrap().to_string())
        .collect()
}

#[test]
fn reuse_answers_the_rooms_group_of_that_name() {
    let session = Session::new("group-reuse");
    let mux = session.open();
    let leads = mutate(&mux, "workspace_group.create", json!({"name": "Leads"}), "leads");
    for (n, name) in ["Leads", " Leads ", "Leads"].into_iter().enumerate() {
        let again = mutate(
            &mux,
            "workspace_group.create",
            json!({"name": name, "reuse": true}),
            &format!("leads-{n}"),
        );
        assert_eq!(again["id"], leads["id"], "{name:?} is the same group: {again}");
    }
    assert_eq!(group_names(&mux), ["Leads"]);
    mux.shutdown();
}

#[test]
fn reuse_makes_the_group_when_none_has_that_name() {
    let session = Session::new("group-reuse-new");
    let mux = session.open();
    mutate(&mux, "workspace_group.create", json!({"name": "Reviews"}), "reviews");
    let made =
        mutate(&mux, "workspace_group.create", json!({"name": "Leads", "reuse": true}), "leads");
    assert_eq!(made["name"], "Leads");
    // The name compares as typed, case included, as the app's exact match does.
    mutate(&mux, "workspace_group.create", json!({"name": "leads", "reuse": true}), "lower");
    assert_eq!(group_names(&mux).len(), 3, "{:?}", group_names(&mux));
    mux.shutdown();
}

#[test]
fn reuse_never_answers_another_rooms_group() {
    let session = Session::new("group-reuse-room");
    let mux = session.open();
    let side = mutate(&mux, "room.create", json!({"name": "Side"}), "side");
    let home = mutate(&mux, "workspace_group.create", json!({"name": "Leads"}), "home");
    let there = mutate(
        &mux,
        "workspace_group.create",
        json!({"name": "Leads", "room": side["id"], "reuse": true}),
        "side-leads",
    );
    assert_ne!(there["id"], home["id"], "another space's group is not this one");
    assert_eq!(there["room_id"], side["id"]);
    mux.shutdown();
}

/// Without `reuse` a create still makes a group: New Group of a name a
/// group already has is a person's choice.
#[test]
fn a_plain_create_still_makes_another_group() {
    let session = Session::new("group-reuse-plain");
    let mux = session.open();
    mutate(&mux, "workspace_group.create", json!({"name": "Leads"}), "one");
    mutate(&mux, "workspace_group.create", json!({"name": "Leads"}), "two");
    assert_eq!(group_names(&mux), ["Leads", "Leads"]);
    mux.shutdown();
}
