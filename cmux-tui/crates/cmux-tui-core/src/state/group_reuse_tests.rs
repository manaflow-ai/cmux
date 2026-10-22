//! `workspace-group-reuse-v1` over `cmux.protocol/2`:
//! `workspace_group.create {reuse_existing: true}` is find-or-create. It
//! answers the personal group already named `name` (trimmed, any case) and
//! makes a group only when none has that name, so agents that file each
//! workspace "into the Agents group" never make a second "Agents".

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

/// A reuse create of a name that exists (other case, extra spaces) answers
/// the existing group and adds none; a fresh name still makes a group.
#[test]
fn a_reuse_create_answers_the_group_of_that_name_and_makes_no_duplicate() {
    let session = Session::new("group-reuse");
    let mux = session.open();
    let first =
        mutate(&mux, "workspace_group.create", json!({"name": "Agents & routing"}), "create-first");
    let again = mutate(
        &mux,
        "workspace_group.create",
        json!({"name": "  agents & ROUTING ", "reuse_existing": true}),
        "create-again",
    );
    assert_eq!(again["id"], first["id"], "the existing group is reused: {again}");
    assert_eq!(again["name"], "Agents & routing", "a reuse keeps the group's name");
    assert_eq!(group_names(&mux), ["Agents & routing"], "no duplicate group");

    let other = mutate(
        &mux,
        "workspace_group.create",
        json!({"name": "Performance", "reuse_existing": true}),
        "create-other",
    );
    assert_ne!(other["id"], first["id"]);
    assert_eq!(group_names(&mux), ["Agents & routing", "Performance"]);
    mux.shutdown();
}

/// Without `reuse_existing` a create keeps its old meaning (the app's
/// "New Group" may make two groups of one name).
#[test]
fn a_plain_create_still_makes_a_second_group_of_one_name() {
    let session = Session::new("group-reuse-plain");
    let mux = session.open();
    mutate(&mux, "workspace_group.create", json!({"name": "New Group"}), "one");
    mutate(&mux, "workspace_group.create", json!({"name": "New Group"}), "two");
    assert_eq!(group_names(&mux), ["New Group", "New Group"]);
    mux.shutdown();
}
