//! RECOVERABLE-BY-DEFAULT for personal workspace groups: Ungroup and Delete
//! Group (`workspace_group.delete`) keep every workspace and record the
//! group in closed history, so Reopen Closed (Cmd-Shift-T, History) forms
//! the group again with its id, name, color, icon, pin, collapse, place and
//! members, also after the daemon restarts. Driven through `cmux.protocol/2`.

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

/// The document's workspace item ids, as `sidebar.get` gives them.
fn placed(mux: &Arc<Mux>) -> Vec<Value> {
    read(mux, "sidebar.get", json!({}))["items"]
        .as_array()
        .into_iter()
        .flatten()
        .filter(|item| item["body"]["type"] == "workspace")
        .map(|item| item["body"]["ref"]["workspace_id"].clone())
        .collect()
}

/// The `sidebar.adopt` a client sends for workspaces its tree still shows,
/// after the daemon closed them (the app's document mirror hears of a close
/// before its tree does, and asks to place what the document "lacks").
fn adopt_late(mux: &Arc<Mux>, workspaces: &[&String], key: &str) {
    let (local, _) = mux.registry_identity();
    let refs: Vec<Value> = workspaces
        .iter()
        .map(|workspace| json!({"session_id": local, "workspace_id": workspace}))
        .collect();
    send(mux, "sidebar.adopt", json!({"refs": refs}), Some(key))
        .unwrap_or_else(|error| panic!("sidebar.adopt failed: {error:?}"));
}

/// A closed workspace keeps its personal row, so Reopen Closed gives it its
/// group and place back. A late `sidebar.adopt` of it must not place it in
/// its machine section again: the write-back of that item took the group
/// from the kept row, and the workspace came back outside its group.
#[test]
fn a_late_adopt_of_a_closed_workspace_does_not_take_its_group() {
    let session = Session::new("group-late-adopt-one");
    let mux = session.open();
    let keep = empty_workspace(&mux, "keep");
    let a = empty_workspace(&mux, "a");
    let work = group(&mux, "Work");
    mutate(&mux, "workspace.place", json!({"workspace": a, "group": work}), "a-in-work");
    mutate(&mux, "workspace.close", json!({"workspace": a}), "close-a");

    adopt_late(&mux, &[&a], "late-adopt");

    let reopened = mutate(&mux, "closed.reopen", json!({}), "reopen-a");
    let back = reopened["workspace_id"].as_str().expect("a workspace was reopened").to_string();
    assert_eq!(
        group_of(&mux, &back),
        json!(work),
        "a late adopt of the closed workspace took its group: it came back outside the group"
    );
    assert!(group_of(&mux, &keep).is_null());
    mux.shutdown();
}

/// The bulk close of a group's last workspaces (one `layout.bulk`, as the
/// app's Close Other Workspaces and its selection close send it), the delete
/// of the group they left empty and the Undo of both
/// (`GroupCloseCleanupUndoTests`), with the late adopt between the close and
/// the delete. The group record must keep its members, so the Undo forms the
/// group again around the reopened workspaces.
#[test]
fn a_late_adopt_between_the_close_and_the_group_delete_keeps_the_group_for_the_undo() {
    let session = Session::new("group-late-adopt-undo");
    let mux = session.open();
    let keep = empty_workspace(&mux, "keep");
    let a = empty_workspace(&mux, "a");
    let b = empty_workspace(&mux, "b");
    let work = group(&mux, "Work");
    let other = group(&mux, "Other");
    mutate(&mux, "workspace.place", json!({"workspace": a, "group": work}), "a-in-work");
    mutate(&mux, "workspace.place", json!({"workspace": b, "group": work}), "b-in-work");
    mutate(&mux, "workspace.place", json!({"workspace": keep, "group": other}), "keep-in-other");
    let closed = mutate(
        &mux,
        "layout.bulk",
        json!({
            "verb": "close",
            "level": "workspace",
            "selector": "selection",
            "ids": [a, b],
            "end_terminals": true,
        }),
        "close-the-group",
    );
    assert_eq!(closed["workspace_ids"], json!([a, b]), "one bulk close of both: {closed}");

    adopt_late(&mux, &[&a, &b], "late-adopt");
    let shown = placed(&mux);
    assert!(
        !shown.contains(&json!(a)) && !shown.contains(&json!(b)),
        "the document placed closed workspaces in their machine section: {shown:?}"
    );

    // The app deletes the group the close left empty, then Undo reopens the
    // group record first and the closed workspaces after it.
    mutate(&mux, "workspace_group.delete", json!({"workspace_group": work}), "delete-work");
    let closed = read(&mux, "closed.list", json!({}));
    let closed = closed.as_array().expect("closed.list is an array");
    let record = closed
        .iter()
        .find(|item| item["group"]["id"] == work.as_str())
        .expect("the group delete is one closed record")["id"]
        .clone();
    mutate(&mux, "closed.reopen", json!({"closed": record}), "reopen-work");
    let mut back = Vec::new();
    for (index, item) in closed.iter().filter(|item| item["group"].is_null()).enumerate() {
        let reopened = mutate(
            &mux,
            "closed.reopen",
            json!({"closed": item["id"]}),
            &format!("reopen-{index}"),
        );
        for workspace in reopened["workspace_ids"].as_array().into_iter().flatten() {
            back.push(workspace.as_str().expect("a workspace id").to_string());
        }
    }

    assert_eq!(back.len(), 2, "both closed workspaces reopen: {closed:?}");
    assert!(groups(&mux).iter().any(|group| group["id"] == work.as_str()), "the group is back");
    for workspace in &back {
        assert_eq!(
            group_of(&mux, workspace),
            json!(work),
            "Undo brought the group back empty: a reopened workspace is outside it"
        );
    }
    assert_eq!(group_of(&mux, &keep), json!(other));
    mux.shutdown();
}

/// The document item of workspace `workspace`, as `sidebar.get` gives it.
fn item_of(mux: &Arc<Mux>, workspace: &str) -> Option<String> {
    read(mux, "sidebar.get", json!({}))["items"]
        .as_array()
        .into_iter()
        .flatten()
        .find(|item| item["body"]["ref"]["workspace_id"] == workspace)
        .and_then(|item| item["id"].as_str().map(str::to_string))
}

/// The check on `sidebar.adopt` drops the closed ids only. Reopen Closed
/// makes the workspace again with a new id (a closed id never opens again),
/// so a reopen can not make the check refuse an open workspace: one adopt
/// that names the reopened workspace and its closed id places the first and
/// drops the second.
#[test]
fn an_adopt_places_a_reopened_workspace_and_drops_its_closed_id() {
    let session = Session::new("group-adopt-reopened");
    let mux = session.open();
    let keep = empty_workspace(&mux, "keep");
    let a = empty_workspace(&mux, "a");
    mutate(&mux, "workspace.close", json!({"workspace": a}), "close-a");
    let reopened = mutate(&mux, "closed.reopen", json!({}), "reopen-a");
    let back = reopened["workspace_id"].as_str().expect("a workspace was reopened").to_string();
    assert_ne!(back, a, "Reopen Closed gives the workspace a new id");

    // The document lacks the open workspace (the case `adopt` is for).
    let item = item_of(&mux, &back).expect("the reopened workspace has an item");
    send(&mux, "sidebar.item.remove", json!({"id": item}), Some("remove-back"))
        .unwrap_or_else(|error| panic!("sidebar.item.remove failed: {error:?}"));
    assert!(!placed(&mux).contains(&json!(back)), "the document lacks the open workspace");

    adopt_late(&mux, &[&a, &back], "adopt-both");

    let shown = placed(&mux);
    assert!(shown.contains(&json!(back)), "the open workspace is placed again: {shown:?}");
    assert!(!shown.contains(&json!(a)), "its closed id is not placed: {shown:?}");
    assert!(shown.contains(&json!(keep)), "{shown:?}");
    mux.shutdown();
}
