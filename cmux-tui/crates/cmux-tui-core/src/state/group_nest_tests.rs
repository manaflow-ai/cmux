//! `workspace-group-nest-v1` over `cmux.protocol/2`: a group's parent
//! (`parent_group`), its rules (no cycle, at most three levels, one room),
//! sibling order, Delete Group moving items up a level and its reopen, the
//! sidebar document following the nest, and the nest after a restart.

use serde_json::json;

use super::tests::{Session, empty_workspace, error_code, mutate, read, send};
use crate::mux::*;
use crate::state::prelude::*;

fn create(mux: &Arc<Mux>, name: &str, parent: Option<&str>) -> String {
    let mut params = json!({"name": name});
    if let Some(parent) = parent {
        params["parent_group"] = json!(parent);
    }
    mutate(mux, "workspace_group.create", params, &format!("create-{name}"))["id"]
        .as_str()
        .unwrap()
        .to_string()
}

fn groups(mux: &Arc<Mux>) -> Vec<Value> {
    read(mux, "workspace_group.list", json!({})).as_array().cloned().unwrap_or_default()
}

fn group(mux: &Arc<Mux>, id: &str) -> Value {
    groups(mux).into_iter().find(|group| group["id"] == id).unwrap_or(Value::Null)
}

fn parent_of(mux: &Arc<Mux>, id: &str) -> Value {
    group(mux, id)["parent_group"].clone()
}

/// The sidebar document item of group `id`.
fn doc_item(mux: &Arc<Mux>, id: &str) -> Value {
    let doc = read(mux, "sidebar.get", json!({}));
    let items = doc["items"].as_array().or_else(|| doc["doc"]["items"].as_array()).cloned();
    items
        .unwrap_or_default()
        .into_iter()
        .find(|item| item["id"] == format!("itm_g_{id}") || item["id"] == id)
        .unwrap_or(Value::Null)
}

fn reason(result: Result<Value, ResourceError>) -> String {
    let error = result.expect_err("request unexpectedly succeeded");
    format!("{} {}", error.code, error.message)
}

#[test]
fn groups_nest_three_levels_and_survive_a_restart() {
    let session = Session::new("group-nest-restart");
    let mux = session.open();
    let top = create(&mux, "Cloud", None);
    let project = create(&mux, "Project", Some(&top));
    let feature = create(&mux, "Feature", Some(&project));
    assert_eq!(parent_of(&mux, &project), top.as_str());
    assert_eq!(parent_of(&mux, &feature), project.as_str());
    assert!(parent_of(&mux, &top).is_null());
    // The sidebar document nests the same way.
    assert_eq!(doc_item(&mux, &feature)["parent"], format!("itm_g_{project}"));
    let w = empty_workspace(&mux, "w");
    mutate(&mux, "workspace.place", json!({"workspace": w, "group": feature}), "w-in-feature");
    mux.shutdown();
    drop(mux);

    let mux = session.open();
    assert_eq!(parent_of(&mux, &project), top.as_str(), "the nest survives a restart");
    assert_eq!(parent_of(&mux, &feature), project.as_str());
    assert_eq!(doc_item(&mux, &feature)["parent"], format!("itm_g_{project}"));
    mux.shutdown();
}

#[test]
fn a_fourth_level_a_cycle_and_another_room_are_refused() {
    let session = Session::new("group-nest-rules");
    let mux = session.open();
    let a = create(&mux, "A", None);
    let b = create(&mux, "B", Some(&a));
    let c = create(&mux, "C", Some(&b));
    let too_deep =
        send(&mux, "workspace_group.create", json!({"name": "D", "parent_group": c}), Some("d"));
    let message = reason(too_deep);
    assert!(message.contains("too_deep"), "{message}");
    assert!(groups(&mux).iter().all(|group| group["name"] != "D"));

    let cycle = send(
        &mux,
        "workspace_group.update",
        json!({"workspace_group": a, "parent_group": c}),
        Some("a-in-c"),
    );
    assert!(reason(cycle).contains("nesting"));
    let into_self = send(
        &mux,
        "workspace_group.update",
        json!({"workspace_group": a, "parent_group": a}),
        Some("a-in-a"),
    );
    assert!(reason(into_self).contains("nesting"));

    // A two-level group under b would make four levels.
    let x = create(&mux, "X", None);
    create(&mux, "Y", Some(&x));
    let deep = send(
        &mux,
        "workspace_group.update",
        json!({"workspace_group": x, "parent_group": b}),
        Some("x-in-b"),
    );
    assert!(reason(deep).contains("too_deep"));
    assert!(parent_of(&mux, &x).is_null(), "a refused nest changes nothing");

    let room = mutate(&mux, "room.create", json!({"name": "Work"}), "room-work")["id"]
        .as_str()
        .unwrap()
        .to_string();
    let elsewhere = mutate(
        &mux,
        "workspace_group.create",
        json!({"name": "Elsewhere", "room": room}),
        "create-elsewhere",
    )["id"]
        .as_str()
        .unwrap()
        .to_string();
    let cross = send(
        &mux,
        "workspace_group.update",
        json!({"workspace_group": elsewhere, "parent_group": a}),
        Some("cross"),
    );
    assert!(reason(cross).contains("cross_room"));
    assert_eq!(
        error_code(send(
            &mux,
            "workspace_group.update",
            json!({"workspace_group": x, "parent_group": "grp_missing"}),
            Some("missing"),
        )),
        "resource.not_found"
    );

    // Back to the top level.
    mutate(
        &mux,
        "workspace_group.update",
        json!({"workspace_group": c, "parent_group": null}),
        "c-top",
    );
    assert!(parent_of(&mux, &c).is_null());
    assert!(doc_item(&mux, &c)["parent"].is_null());
    mux.shutdown();
}

#[test]
fn move_orders_a_group_among_its_siblings() {
    let session = Session::new("group-nest-move");
    let mux = session.open();
    let top = create(&mux, "Top", None);
    let other = create(&mux, "Other", None);
    let one = create(&mux, "One", Some(&top));
    let two = create(&mux, "Two", Some(&top));
    let three = create(&mux, "Three", Some(&top));
    let children = |mux: &Arc<Mux>| -> Vec<String> {
        groups(mux)
            .into_iter()
            .filter(|group| group["parent_group"] == top.as_str())
            .map(|group| group["id"].as_str().unwrap().to_string())
            .collect()
    };
    assert_eq!(children(&mux), [one.clone(), two.clone(), three.clone()]);
    mutate(&mux, "workspace_group.move", json!({"workspace_group": three, "index": 0}), "three");
    assert_eq!(children(&mux), [three.clone(), one.clone(), two.clone()]);
    // Top-level groups keep their order.
    let tops: Vec<Value> =
        groups(&mux).into_iter().filter(|group| group["parent_group"].is_null()).collect();
    assert_eq!(tops[0]["id"], top.as_str());
    assert_eq!(tops[1]["id"], other.as_str());
    mux.shutdown();
}

#[test]
fn delete_moves_items_up_a_level_and_reopen_nests_them_again() {
    let session = Session::new("group-nest-delete");
    let mux = session.open();
    let top = create(&mux, "Top", None);
    let middle = create(&mux, "Middle", Some(&top));
    let inner = create(&mux, "Inner", Some(&middle));
    let w = empty_workspace(&mux, "w");
    mutate(&mux, "workspace.place", json!({"workspace": w, "group": middle}), "w-in-middle");

    mutate(&mux, "workspace_group.delete", json!({"workspace_group": middle}), "delete-middle");
    assert!(group(&mux, &middle).is_null());
    assert_eq!(parent_of(&mux, &inner), top.as_str(), "its group moves up");
    let placement = read(&mux, "workspace.placement.list", json!({}))
        .as_array()
        .unwrap()
        .iter()
        .find(|placement| placement["workspace"]["workspace_id"] == w.as_str())
        .cloned()
        .unwrap();
    assert_eq!(placement["group_id"], top.as_str(), "its workspace moves up, open");

    mutate(&mux, "closed.reopen", json!({}), "reopen");
    assert_eq!(parent_of(&mux, &middle), top.as_str());
    assert_eq!(parent_of(&mux, &inner), middle.as_str());
    mux.shutdown();
}

/// The ids of the document items under group `id`, in order.
fn doc_children(mux: &Arc<Mux>, id: &str) -> Vec<String> {
    let doc = read(mux, "sidebar.get", json!({}));
    let items = doc["items"].as_array().or_else(|| doc["doc"]["items"].as_array()).cloned();
    let parent = doc_item(mux, id)["id"].clone();
    items
        .unwrap_or_default()
        .into_iter()
        .filter(|item| item["parent"] == parent)
        .map(|item| item["id"].as_str().unwrap_or_default().to_string())
        .collect()
}

#[test]
fn a_parent_with_groups_and_workspaces_shows_its_groups_first_after_a_restart() {
    let session = Session::new("group-nest-mixed");
    let mux = session.open();
    let top = create(&mux, "Top", None);
    let w = empty_workspace(&mux, "w");
    mutate(&mux, "workspace.place", json!({"workspace": w, "group": top}), "w-in-top");
    let inner = create(&mux, "Inner", Some(&top));
    let expected = |mux: &Arc<Mux>| {
        let children = doc_children(mux, &top);
        assert_eq!(children.len(), 2, "{children:?}");
        assert_eq!(children[0], doc_item(mux, &inner)["id"].as_str().unwrap(), "{children:?}");
        assert!(children[1].contains(&w), "the workspace follows the nested group: {children:?}");
    };
    expected(&mux);
    mux.shutdown();
    drop(mux);
    let mux = session.open();
    expected(&mux);
    assert_eq!(parent_of(&mux, &inner), top.as_str());
    mux.shutdown();
}
