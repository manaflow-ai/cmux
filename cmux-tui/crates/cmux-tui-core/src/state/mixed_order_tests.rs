//! `personal-mixed-order-v1` over `cmux.protocol/2`: a group's slot among
//! the loose workspaces (`workspace_group.update {top_index}`), the personal
//! row a new workspace gets at create, and `workspace.list {order:
//! "personal"}`, the sidebar order every client reads.

use serde_json::json;

use super::tests::{
    Session, empty_workspace, error_code, mutate, placements_by_id, read, replayed_placements,
    revision, send,
};
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
    // Made in sidebar order (workspaces.newPlacement bottom).
    let _bottom = crate::user_settings::NewWorkspacePlacement::Bottom.set_for_test();
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
    assert_eq!(index(&b) + 1, index(&a), "a new row goes first (workspaces.newPlacement top)");
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

/// `workspaces.newPlacement` defaults to `top` for every client: a workspace
/// made by a plain `workspace.create` (what the TUI, the CLI, iOS and agents
/// send; no app places it afterwards) gets the first row below Home in the
/// commit that creates it, before a group placed right below Home, and keeps
/// it across a restart.
#[test]
fn a_new_workspace_from_any_client_lands_at_the_top_by_default() {
    let session = Session::new("new-top");
    let mux = session.open();
    let home = send(&mux, "workspace.ensure_home", json!({}), Some("connect")).unwrap()["value"]
        ["workspace_id"]
        .as_str()
        .unwrap()
        .to_string();
    let a = empty_workspace(&mux, "a");
    let work = group(&mux, "Work");
    mutate(&mux, "workspace.place", json!({"workspace": a, "group": work}), "a-in-work");
    mutate(
        &mux,
        "workspace_group.update",
        json!({"workspace_group": work, "top_index": 1}),
        "work-below-home",
    );
    let (start, before) = (placements_by_id(&mux), revision(&mux));
    let b = empty_workspace(&mux, "b");
    let c = empty_workspace(&mux, "c");
    assert_eq!(
        replayed_placements(&mux, start, before),
        placements_by_id(&mux),
        "session.events does not carry every moved placement"
    );
    let ids = [home.as_str(), a.as_str(), b.as_str(), c.as_str()];
    let expected = [home.as_str(), c.as_str(), b.as_str(), a.as_str()];
    assert_eq!(listed(&mux, Some("personal"), &ids), expected, "new workspaces not on top");
    let placements = read(&mux, "workspace.placement.list", json!({}));
    let index = |id: &str| {
        placements
            .as_array()
            .unwrap()
            .iter()
            .find(|row| row["workspace"]["workspace_id"] == id)
            .and_then(|row| row["index"].as_u64())
            .unwrap()
    };
    assert_eq!((index(&home), index(&c), index(&b)), (0, 1, 2));
    // The group stays after the new loose rows, at its place before `a`'s row.
    let groups = read(&mux, "workspace_group.list", json!({}));
    assert_eq!(groups[0]["top_index"], 3, "the group slot did not move past the new rows");
    drop(mux);
    let mux = session.open();
    assert_eq!(listed(&mux, Some("personal"), &ids), expected, "the top place is not stored");
    mux.shutdown();
}

/// `afterCurrent`: right after the session's active workspace, inside its
/// group; Home (or no current workspace) falls back to top. `bottom`: last.
#[test]
fn a_new_workspace_follows_the_after_current_and_bottom_settings() {
    use crate::user_settings::NewWorkspacePlacement;
    let session = Session::new("new-after-current");
    let mux = session.open();
    let home = send(&mux, "workspace.ensure_home", json!({}), Some("connect")).unwrap()["value"]
        ["workspace_id"]
        .as_str()
        .unwrap()
        .to_string();
    let a = empty_workspace(&mux, "a");
    let b = empty_workspace(&mux, "b");
    let work = group(&mux, "Work");
    mutate(&mux, "workspace.place", json!({"workspace": a, "group": work}), "a-in-work");
    // Personal order now: home, b, then Work [a] after every loose row.
    let after = NewWorkspacePlacement::AfterCurrent.set_for_test();
    mutate(&mux, "workspace.focus", json!({"workspace": b}), "focus-b");
    let c = empty_workspace(&mux, "c");
    mutate(&mux, "workspace.focus", json!({"workspace": a}), "focus-a");
    let d = empty_workspace(&mux, "d");
    mutate(&mux, "workspace.focus", json!({"workspace": home}), "focus-home");
    let e = empty_workspace(&mux, "e");
    drop(after);
    let bottom = NewWorkspacePlacement::Bottom.set_for_test();
    let f = empty_workspace(&mux, "f");
    drop(bottom);
    let ids = [&home, &a, &b, &c, &d, &e, &f].map(String::as_str);
    let [home, a, b, c, d, e, f] = ids;
    assert_eq!(listed(&mux, Some("personal"), &ids), [home, e, b, c, f, a, d]);
    let placements = read(&mux, "workspace.placement.list", json!({}));
    let group_of = |id: &str| {
        placements
            .as_array()
            .unwrap()
            .iter()
            .find(|row| row["workspace"]["workspace_id"] == id)
            .map(|row| row["group_id"].clone())
            .unwrap()
    };
    assert_eq!(group_of(d), json!(work), "after a grouped workspace: in its group");
    assert!(group_of(c).is_null() && group_of(e).is_null() && group_of(f).is_null());
    mux.shutdown();
}
