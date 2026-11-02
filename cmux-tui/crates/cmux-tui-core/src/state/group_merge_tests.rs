//! `workspace_group.delete {merge_into}`: a duplicate group's members join
//! the group it duplicates, in their order, and the duplicate goes without a
//! closed-history record, since nothing of it is lost. `cmux workspace group
//! tidy` drives it (Leo, 2026-11-02: fifteen "Leads" groups of one row each).

use serde_json::json;

use super::tests::{Session, empty_workspace, error_code, mutate, read, send};
use crate::mux::*;
use crate::state::prelude::*;

fn group(mux: &Arc<Mux>, name: &str, key: &str) -> String {
    mutate(mux, "workspace_group.create", json!({"name": name}), key)["id"]
        .as_str()
        .unwrap()
        .to_string()
}

/// The workspaces of group `group`, in the personal order.
fn members(mux: &Arc<Mux>, group: &str) -> Vec<Value> {
    let mut placements: Vec<Value> = read(mux, "workspace.placement.list", json!({}))
        .as_array()
        .unwrap()
        .iter()
        .filter(|placement| placement["group_id"] == group)
        .cloned()
        .collect();
    placements.sort_by_key(|placement| placement["index"].as_u64());
    placements.iter().map(|placement| placement["workspace"]["workspace_id"].clone()).collect()
}

#[test]
fn a_merged_duplicate_hands_its_members_over_and_leaves_no_record() {
    let session = Session::new("group-merge");
    let mux = session.open();
    let a = empty_workspace(&mux, "a");
    let b = empty_workspace(&mux, "b");
    let c = empty_workspace(&mux, "c");
    let leads = group(&mux, "Leads", "leads");
    let again = group(&mux, "Leads", "leads-again");
    mutate(&mux, "workspace.place", json!({"workspace": a, "group": leads}), "a");
    mutate(&mux, "workspace.place", json!({"workspace": b, "group": again}), "b");
    mutate(&mux, "workspace.place", json!({"workspace": c, "group": leads}), "c");

    let merged = mutate(
        &mux,
        "workspace_group.delete",
        json!({"workspace_group": again, "merge_into": leads}),
        "merge",
    );

    assert_eq!(merged["merged_into"], leads.as_str(), "{merged}");
    assert_eq!(members(&mux, &leads), [json!(a), json!(b), json!(c)], "order kept");
    let groups = read(&mux, "workspace_group.list", json!({}));
    assert_eq!(groups.as_array().unwrap().len(), 1, "{groups}");
    let closed = read(&mux, "closed.list", json!({}));
    assert_eq!(closed.as_array().unwrap().len(), 0, "a merge loses nothing: {closed}");
    mux.shutdown();
}

#[test]
fn a_merge_stays_in_one_room_and_needs_its_target() {
    let session = Session::new("group-merge-room");
    let mux = session.open();
    let side = mutate(&mux, "room.create", json!({"name": "Side"}), "side");
    let here = group(&mux, "Leads", "here");
    let there = mutate(
        &mux,
        "workspace_group.create",
        json!({"name": "Leads", "room": side["id"]}),
        "there",
    )["id"]
        .as_str()
        .unwrap()
        .to_string();
    let across = send(
        &mux,
        "workspace_group.delete",
        json!({"workspace_group": there, "merge_into": here}),
        Some("across"),
    );
    assert!(across.is_err(), "another room's group is not a merge target: {across:?}");
    assert_eq!(
        error_code(send(
            &mux,
            "workspace_group.delete",
            json!({"workspace_group": there, "merge_into": "grp_missing"}),
            Some("missing"),
        )),
        "resource.not_found"
    );
    let groups = read(&mux, "workspace_group.list", json!({}));
    assert_eq!(groups.as_array().unwrap().len(), 2, "nothing deleted: {groups}");
    mux.shutdown();
}
