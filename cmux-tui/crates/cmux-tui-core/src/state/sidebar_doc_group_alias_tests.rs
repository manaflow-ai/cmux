//! `sidebar.apply` group ops named by the personal group id (#22996). A
//! personal group lists in the sidebar document as the item
//! `itm_g_<group id>`; a client that names the group by its own id (the
//! app's group actions, the CLI, an MCP caller) gets the same edit as one
//! that names the item, not `unknown_item` ("The sidebar did not make this
//! move"). Driven through `cmux.protocol/2`.

use serde_json::json;

use super::tests::{Session, empty_workspace, mutate, read, send};
use crate::mux::*;
use crate::state::prelude::*;

fn group(mux: &Arc<Mux>, name: &str) -> String {
    mutate(mux, "workspace_group.create", json!({"name": name}), &format!("group-{name}"))["id"]
        .as_str()
        .unwrap()
        .to_string()
}

fn groups(mux: &Arc<Mux>) -> Vec<Value> {
    read(mux, "workspace_group.list", json!({})).as_array().cloned().unwrap_or_default()
}

fn group_of(mux: &Arc<Mux>, workspace: &str) -> Value {
    read(mux, "workspace.placement.list", json!({}))
        .as_array()
        .unwrap()
        .iter()
        .find(|placement| placement["workspace"]["workspace_id"] == workspace)
        .map(|placement| placement["group_id"].clone())
        .unwrap_or(Value::Null)
}

fn apply(mux: &Arc<Mux>, ops: Value, key: &str) -> Result<Value, ResourceError> {
    send(mux, "sidebar.apply", json!({"ops": ops}), Some(key))
}

fn document(mux: &Arc<Mux>) -> String {
    read(mux, "sidebar.get", json!({})).to_string()
}

#[test]
fn group_ops_named_by_the_personal_id_edit_the_groups_item() {
    let session = Session::new("sidebar-group-alias");
    let mux = session.open();
    let a = empty_workspace(&mux, "a");
    let b = empty_workspace(&mux, "b");
    let work = group(&mux, "Work");
    let other = group(&mux, "Other");
    mutate(&mux, "workspace.place", json!({"workspace": a, "group": work}), "a-in-work");
    mutate(&mux, "workspace.place", json!({"workspace": b, "group": other}), "b-in-other");
    let item = format!("itm_g_{work}");
    assert!(document(&mux).contains(&item), "the group lists as its item: {}", document(&mux));

    // Rename (the group editor, `workspaceGroup.rename`).
    apply(
        &mux,
        json!([{"op": "group.update", "id": work, "patch": {"name": "Renamed"}}]),
        "rename-by-personal-id",
    )
    .unwrap_or_else(|error| panic!("group.update by the personal id: {error:?}"));
    let renamed = groups(&mux).into_iter().find(|group| group["id"] == work.as_str());
    assert_eq!(renamed.map(|group| group["name"].clone()), Some(json!("Renamed")));

    // Pin Group, then Unpin (the group's header menu).
    apply(&mux, json!([{"op": "pin", "items": [work]}]), "pin-by-personal-id")
        .unwrap_or_else(|error| panic!("pin by the personal id: {error:?}"));
    let pinned = groups(&mux).into_iter().find(|group| group["id"] == work.as_str());
    assert_eq!(pinned.map(|group| group["pinned"].clone()), Some(json!(true)));
    apply(&mux, json!([{"op": "unpin", "items": [work]}]), "unpin-by-personal-id")
        .unwrap_or_else(|error| panic!("unpin by the personal id: {error:?}"));

    // Delete Group (`workspaceGroup.delete` sends `group.ungroup`): the group goes, its workspace stays.
    apply(&mux, json!([{"op": "group.ungroup", "id": work}]), "delete-by-personal-id")
        .unwrap_or_else(|error| panic!("group.ungroup by the personal id: {error:?}"));
    assert!(groups(&mux).iter().all(|group| group["id"] != work.as_str()), "the group is gone");
    assert!(!document(&mux).contains(&item), "its item is gone: {}", document(&mux));
    assert!(group_of(&mux, &a).is_null(), "its workspace stays, ungrouped");
    assert_eq!(group_of(&mux, &b), json!(other), "another group keeps its member");

    // The item id still works, and an id that names no group is still refused.
    apply(&mux, json!([{"op": "group.ungroup", "id": format!("itm_g_{other}")}]), "delete-by-item")
        .unwrap_or_else(|error| panic!("group.ungroup by the item id: {error:?}"));
    assert!(groups(&mux).is_empty(), "both groups are gone: {:?}", groups(&mux));
    let refused = apply(&mux, json!([{"op": "group.ungroup", "id": work}]), "delete-again")
        .expect_err("a deleted group is refused");
    assert_eq!(refused.code, "validation.invalid", "{refused:?}");
    assert!(refused.message.contains("unknown_item"), "{refused:?}");
    mux.shutdown();
}
