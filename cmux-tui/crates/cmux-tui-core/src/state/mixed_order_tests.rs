//! `personal-mixed-order-v1` over `cmux.protocol/2`: a group's slot among
//! the loose workspaces (`workspace_group.update {top_index}`), the personal
//! row a new workspace gets at create, and `workspace.list {order:
//! "personal"}`, the sidebar order every client reads.

use serde_json::json;

use super::tests::{Session, empty_workspace, error_code, mutate, read, send};
use crate::mux::*;
use crate::state::prelude::*;

/// The workspace ids of `workspace.list {order}` restricted to `ids`.
fn listed(mux: &Arc<Mux>, order: Option<&str>, ids: &[&str]) -> Vec<String> {
    let params = order.map_or_else(|| json!({}), |order| json!({"order": order}));
    read(mux, "workspace.list", params)
        .as_array()
        .unwrap()
        .iter()
        .filter_map(|workspace| workspace["id"].as_str())
        .filter(|id| ids.contains(id))
        .map(str::to_string)
        .collect()
}

fn group(mux: &Arc<Mux>, name: &str) -> String {
    mutate(mux, "workspace_group.create", json!({"name": name}), &format!("group-{name}"))["id"]
        .as_str()
        .unwrap()
        .to_string()
}

/// A group moves between loose rows, its members show at its slot in the
/// personal order, and null puts it back after every loose workspace.
#[test]
fn a_group_slot_between_loose_rows_orders_the_personal_workspace_list() {
    let session = Session::new("mixed-slot");
    let mux = session.open();
    let a = empty_workspace(&mux, "a");
    let b = empty_workspace(&mux, "b");
    let c = empty_workspace(&mux, "c");
    let d = empty_workspace(&mux, "d");
    let work = group(&mux, "Work");
    mutate(&mux, "workspace.place", json!({"workspace": d, "group": work}), "d-in-work");
    let ids = [a.as_str(), b.as_str(), c.as_str(), d.as_str()];
    let [a, b, c, d] = ids;
    assert_eq!(listed(&mux, Some("personal"), &ids), [a, b, c, d], "no slot: group last");

    // top_index alone is a valid update: the personal workspace index of
    // the row the group shows before (b).
    let moved = mutate(
        &mux,
        "workspace_group.update",
        json!({"workspace_group": work, "top_index": 1}),
        "work-before-b",
    );
    assert_eq!(moved["top_index"], 1);
    let groups = read(&mux, "workspace_group.list", json!({}));
    assert_eq!(groups[0]["top_index"], 1);
    assert_eq!(listed(&mux, Some("personal"), &ids), [a, d, b, c]);
    // The default order stays the session order.
    assert_eq!(listed(&mux, None, &ids), [a, b, c, d]);
    assert_eq!(listed(&mux, Some("session"), &ids), [a, b, c, d]);

    // c moves to the front: the group keeps its slot before b.
    mutate(&mux, "workspace.place", json!({"workspace": c, "index": 0}), "c-first");
    assert_eq!(listed(&mux, Some("personal"), &ids), [c, a, d, b]);

    let back = mutate(
        &mux,
        "workspace_group.update",
        json!({"workspace_group": work, "top_index": null}),
        "work-last",
    );
    assert!(back["top_index"].is_null());
    assert_eq!(listed(&mux, Some("personal"), &ids), [c, a, b, d]);
    assert_eq!(
        error_code(send(&mux, "workspace.list", json!({"order": "random"}), None)),
        "validation.invalid"
    );
    mux.shutdown();
}

fn personal_rows(mux: &Arc<Mux>) -> usize {
    mux.personal_snapshot().unwrap().workspaces.len()
}

/// A new workspace gets its personal row in the commit that creates it,
/// so a group slot counts it from the start.
#[test]
fn a_new_workspace_gets_a_personal_row_at_create() {
    let session = Session::new("mixed-create");
    let mux = session.open();
    let before = personal_rows(&mux);
    let a = empty_workspace(&mux, "a");
    assert_eq!(personal_rows(&mux), before + 1, "workspace.create wrote no personal row");
    let b = empty_workspace(&mux, "b");
    assert_eq!(personal_rows(&mux), before + 2);
    let placements = read(&mux, "workspace.placement.list", json!({}));
    let index = |id: &String| {
        placements
            .as_array()
            .unwrap()
            .iter()
            .find(|row| row["workspace"]["workspace_id"] == id.as_str())
            .and_then(|row| row["index"].as_u64())
            .unwrap()
    };
    assert_eq!(index(&b), index(&a) + 1, "new rows go last, in creation order");
    // The row survives a restart (it is in the store, not synthesized).
    drop(mux);
    let mux = session.open();
    assert_eq!(personal_rows(&mux), before + 2);
    mux.shutdown();
}

/// Mixed order keeps Home first: no group slot at or before Home.
#[test]
fn a_group_slot_before_home_is_refused() {
    let session = Session::new("mixed-home");
    let mux = session.open();
    send(&mux, "workspace.ensure_home", json!({}), Some("connect")).unwrap();
    let a = empty_workspace(&mux, "a");
    let work = group(&mux, "Work");
    mutate(&mux, "workspace.place", json!({"workspace": a, "group": work}), "a-in-work");
    assert_eq!(
        error_code(send(
            &mux,
            "workspace_group.update",
            json!({"workspace_group": work, "top_index": 0}),
            Some("work-first"),
        )),
        "home.pinned_first"
    );
    let after_home = mutate(
        &mux,
        "workspace_group.update",
        json!({"workspace_group": work, "top_index": 1}),
        "work-second",
    );
    assert_eq!(after_home["top_index"], 1);
    mux.shutdown();
}
