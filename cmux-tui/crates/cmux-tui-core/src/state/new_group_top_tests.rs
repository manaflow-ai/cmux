//! A group made with no place (`cmux workspace group create`, MCP, iOS, the
//! Chief's subagent groups) forms where `workspaces.newPlacement` puts a new
//! workspace: under `top` (the default) first, right below Home, so the new
//! workspace it holds shows at the top of the sidebar, not after every older
//! group. An explicit `index` and the `bottom` setting keep the old place.

use serde_json::json;

use super::tests::{Session, empty_workspace, mutate, read, send};
use crate::mux::*;
use crate::state::prelude::*;
use crate::user_settings::NewWorkspacePlacement;

/// The workspace ids of `workspace.list` (the sidebar document order) restricted to `ids`.
fn document_order(mux: &Arc<Mux>, ids: &[&str]) -> Vec<String> {
    read(mux, "workspace.list", json!({}))
        .as_array()
        .unwrap()
        .iter()
        .filter_map(|workspace| workspace["id"].as_str())
        .filter(|id| ids.contains(id))
        .map(str::to_string)
        .collect()
}

fn group(mux: &Arc<Mux>, params: Value, key: &str) -> String {
    mutate(mux, "workspace_group.create", params, key)["id"].as_str().unwrap().to_string()
}

fn home(mux: &Arc<Mux>) -> String {
    send(mux, "workspace.ensure_home", json!({}), Some("connect")).unwrap()["value"]["workspace_id"]
        .as_str()
        .unwrap()
        .to_string()
}

/// The group ids of `workspace_group.list`, in group order.
fn group_order(mux: &Arc<Mux>) -> Vec<String> {
    read(mux, "workspace_group.list", json!({}))
        .as_array()
        .unwrap()
        .iter()
        .filter_map(|group| group["id"].as_str())
        .map(str::to_string)
        .collect()
}

/// What the Chief runs for a subagent: create the workspace, make a group
/// for its topic, add the workspace. The group and the workspace show first,
/// below Home, above the loose rows and every older group.
#[test]
fn a_group_made_with_no_place_forms_first_below_home_under_top() {
    let _top = NewWorkspacePlacement::Top.set_for_test();
    let session = Session::new("new-group-top");
    let mux = session.open();
    let home = home(&mux);
    let a = empty_workspace(&mux, "a");
    let b = empty_workspace(&mux, "b");
    // An older group, after every loose row (index 0, no slot among them).
    let old = group(&mux, json!({"name": "Old", "index": 0}), "group-old");
    mutate(&mux, "workspace.place", json!({"workspace": a, "group": old}), "a-in-old");

    let n = empty_workspace(&mux, "n");
    let new = group(&mux, json!({"name": "New"}), "group-new");
    mutate(&mux, "workspace.place", json!({"workspace": n, "group": new}), "n-in-new");

    let ids = [home.as_str(), a.as_str(), b.as_str(), n.as_str()];
    assert_eq!(
        document_order(&mux, &ids),
        [home.as_str(), n.as_str(), b.as_str(), a.as_str()],
        "the new group is not first below Home in the document"
    );
    assert_eq!(group_order(&mux), [new, old], "the new group is not the first group");

    // A workspace made later still lands above it, as the newest row.
    let m = empty_workspace(&mux, "m");
    let ids = [home.as_str(), a.as_str(), b.as_str(), n.as_str(), m.as_str()];
    assert_eq!(
        document_order(&mux, &ids),
        [home.as_str(), m.as_str(), n.as_str(), b.as_str(), a.as_str()],
        "a newer workspace does not list above the newer group"
    );
    mux.shutdown();
}

/// `bottom` keeps a group with no place last; an explicit `index` is kept
/// under any setting.
#[test]
fn a_group_with_an_index_or_under_bottom_keeps_its_place() {
    let session = Session::new("new-group-bottom");
    let mux = session.open();
    let _home = home(&mux);
    let first = group(&mux, json!({"name": "First", "index": 0}), "group-first");
    {
        let _bottom = NewWorkspacePlacement::Bottom.set_for_test();
        let last = group(&mux, json!({"name": "Last"}), "group-last");
        assert_eq!(
            group_order(&mux),
            [first.as_str(), last.as_str()],
            "bottom did not keep the group last"
        );
        let groups = read(&mux, "workspace_group.list", json!({}));
        assert!(groups[1]["top_index"].is_null(), "bottom gave the group a slot among loose rows");
    }
    let _top = NewWorkspacePlacement::Top.set_for_test();
    let second = group(&mux, json!({"name": "Second", "index": 1}), "group-second");
    assert_eq!(group_order(&mux)[1], second, "an explicit index was not kept");
    let groups = read(&mux, "workspace_group.list", json!({}));
    assert!(groups[1]["top_index"].is_null(), "an explicit index got a slot among loose rows");
    mux.shutdown();
}
