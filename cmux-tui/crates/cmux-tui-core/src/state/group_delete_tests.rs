//! RECOVERABLE-BY-DEFAULT for personal workspace groups: Ungroup and Delete
//! Group (`workspace_group.delete`) keep every workspace and record the
//! group in closed history, so Reopen Closed (Cmd-Shift-T, History) forms
//! the group again with its id, name, color, icon, pin, collapse, place and
//! members, also after the daemon restarts. Driven through `cmux.protocol/2`.

use serde_json::json;

use super::tests::{Session, empty_workspace, mutate, read};
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

/// The group id of workspace `workspace`'s placement.
fn group_of(mux: &Arc<Mux>, workspace: &str) -> Value {
    read(mux, "workspace.placement.list", json!({}))
        .as_array()
        .unwrap()
        .iter()
        .find(|placement| placement["workspace"]["workspace_id"] == workspace)
        .map(|placement| placement["group_id"].clone())
        .unwrap_or(Value::Null)
}

#[test]
fn a_deleted_group_is_recorded_and_reopen_after_a_restart_forms_it_again() {
    let session = Session::new("group-delete-reopen");
    let mux = session.open();
    let a = empty_workspace(&mux, "a");
    let b = empty_workspace(&mux, "b");
    let c = empty_workspace(&mux, "c");
    group(&mux, "First");
    let work = group(&mux, "Work");
    let other = group(&mux, "Other");
    mutate(
        &mux,
        "workspace_group.update",
        json!({"workspace_group": work, "color": "#225588", "collapsed": true}),
        "work-look",
    );
    for (workspace, key) in [(&a, "a-in-work"), (&b, "b-in-work"), (&c, "c-in-work")] {
        mutate(&mux, "workspace.place", json!({"workspace": workspace, "group": work}), key);
    }

    mutate(&mux, "workspace_group.delete", json!({"workspace_group": work}), "delete-work");

    assert!(groups(&mux).iter().all(|group| group["id"] != work.as_str()), "the group is gone");
    assert!(group_of(&mux, &a).is_null(), "its workspaces stay open, ungrouped");
    let closed = read(&mux, "closed.list", json!({}));
    assert_eq!(closed.as_array().unwrap().len(), 1, "one delete, one record: {closed}");
    assert_eq!(closed[0]["member_count"], 0, "no workspace closed: {closed}");
    assert_eq!(closed[0]["group"]["id"], work.as_str(), "the record names the group: {closed}");
    assert_eq!(closed[0]["group"]["name"], "Work");
    assert_eq!(closed[0]["group"]["color"], "#225588");
    // Meanwhile c joins another group: the reopen leaves it there.
    mutate(&mux, "workspace.place", json!({"workspace": c, "group": other}), "c-in-other");
    mux.shutdown();
    drop(mux);

    // Persistence through the registry file: a new daemon on the same root.
    let mux = session.open();
    // Cmd-Shift-T: the newest record, no id.
    mutate(&mux, "closed.reopen", json!({}), "reopen");

    let restored = groups(&mux)
        .into_iter()
        .find(|group| group["id"] == work.as_str())
        .expect("reopen forms the group again with its id");
    assert_eq!(restored["name"], "Work");
    assert_eq!(restored["color"], "#225588");
    assert_eq!(restored["collapsed"], true);
    assert_eq!(restored["index"], 1, "the group keeps its place in the group order");
    assert_eq!(group_of(&mux, &a), json!(work), "a is a member again");
    assert_eq!(group_of(&mux, &b), json!(work), "b is a member again");
    assert_eq!(group_of(&mux, &c), json!(other), "a later move wins over the record");
    assert!(read(&mux, "closed.list", json!({})).as_array().unwrap().is_empty());
    mux.shutdown();
}

#[test]
fn reopening_a_group_record_twice_does_not_duplicate_the_group() {
    let session = Session::new("group-delete-twice");
    let mux = session.open();
    let a = empty_workspace(&mux, "a");
    let work = group(&mux, "Work");
    mutate(&mux, "workspace.place", json!({"workspace": a, "group": work}), "a-in-work");
    mutate(&mux, "workspace_group.delete", json!({"workspace_group": work}), "delete-work");
    let closed = read(&mux, "closed.list", json!({}));
    let id = closed[0]["id"].clone();

    mutate(&mux, "closed.reopen", json!({"closed": id}), "reopen");
    assert_eq!(groups(&mux).iter().filter(|group| group["id"] == work.as_str()).count(), 1);
    assert_eq!(group_of(&mux, &a), json!(work));
    // The record left the history with the reopen.
    assert!(read(&mux, "closed.list", json!({})).as_array().unwrap().is_empty());
    mux.shutdown();
}

#[test]
fn reopen_after_a_restart_restores_the_group_icon_and_pin() {
    let session = Session::new("group-delete-icon-pin");
    let mux = session.open();
    let a = empty_workspace(&mux, "a");
    let work = group(&mux, "Work");
    mutate(
        &mux,
        "workspace_group.update",
        json!({"workspace_group": work, "icon": "star.fill", "pinned": true}),
        "work-icon-pin",
    );
    mutate(&mux, "workspace.place", json!({"workspace": a, "group": work}), "a-in-work");
    mutate(&mux, "workspace_group.delete", json!({"workspace_group": work}), "delete-work");
    assert!(groups(&mux).iter().all(|group| group["id"] != work.as_str()), "the group is gone");
    let closed = read(&mux, "closed.list", json!({}));
    assert_eq!(closed[0]["group"]["icon"], "star.fill", "the record shows the icon: {closed}");
    mux.shutdown();
    drop(mux);

    let mux = session.open();
    mutate(&mux, "closed.reopen", json!({}), "reopen");
    let restored = groups(&mux)
        .into_iter()
        .find(|group| group["id"] == work.as_str())
        .expect("reopen forms the group again with its id");
    assert_eq!(restored["icon"], "star.fill", "the icon comes back: {restored}");
    assert_eq!(restored["pinned"], true, "the pin comes back: {restored}");
    assert_eq!(group_of(&mux, &a), json!(work));
    mux.shutdown();
}
