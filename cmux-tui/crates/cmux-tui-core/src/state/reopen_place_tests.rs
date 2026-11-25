//! Reopen (Cmd-Shift-T, History, `cmux closed reopen`) puts a closed
//! workspace back in its old place in the sidebar document when that place
//! is known (its personal row was kept), else where `workspaces.newPlacement`
//! puts a new workspace: first below Home under `top`, the default.

use serde_json::json;

use super::tests::{Session, empty_workspace, mutate, read, send};
use crate::mux::*;
use crate::state::prelude::*;
use crate::user_settings::NewWorkspacePlacement;

/// The workspace ids of `workspace.list` (the sidebar document order) that are live.
fn document_order(mux: &Arc<Mux>) -> Vec<String> {
    read(mux, "workspace.list", json!({}))
        .as_array()
        .unwrap()
        .iter()
        .filter_map(|workspace| workspace["id"].as_str().map(str::to_string))
        .collect()
}

fn home(mux: &Arc<Mux>) -> String {
    send(mux, "workspace.ensure_home", json!({}), Some("connect")).unwrap()["value"]["workspace_id"]
        .as_str()
        .unwrap()
        .to_string()
}

fn key_of(mux: &Mux, id: &str) -> String {
    mux.with_state(|state| {
        state.workspaces.iter().find(|w| w.public_id.as_str() == id).map(|w| w.key.clone())
    })
    .expect("workspace is live")
}

/// Closes workspace `id` and reopens it; returns the reopened workspace's id.
fn close_and_reopen(mux: &Arc<Mux>, id: &str, forget_place: bool) -> String {
    let key = key_of(mux, id);
    mutate(mux, "workspace.close", json!({"workspace": id}), &format!("close-{id}"));
    if forget_place {
        // A closed workspace whose place is not known (no personal row kept).
        let registry = mux.workspace_registry.lock().unwrap();
        registry
            .connection
            .get()
            .execute("DELETE FROM personal_workspaces WHERE workspace_key = ?1", [key.as_str()])
            .unwrap();
    }
    let reopened = mutate(mux, "closed.reopen", json!({}), &format!("reopen-{id}"));
    assert_eq!(reopened["kind"], "workspace", "reopen restored {reopened}");
    reopened["workspace_id"].as_str().unwrap().to_string()
}

/// A known place comes back: the reopened workspace shows between the same
/// neighbors in the sidebar document, not at the top or the bottom.
#[test]
fn a_reopened_workspace_takes_its_old_place_in_the_document() {
    let _top = NewWorkspacePlacement::Top.set_for_test();
    let session = Session::new("reopen-doc-place");
    let mux = session.open();
    let home = home(&mux);
    let a = empty_workspace(&mux, "a");
    let b = empty_workspace(&mux, "b");
    let c = empty_workspace(&mux, "c");
    assert_eq!(document_order(&mux), [home.as_str(), c.as_str(), b.as_str(), a.as_str()]);

    let reopened = close_and_reopen(&mux, &b, false);

    assert_eq!(
        document_order(&mux),
        [home.as_str(), c.as_str(), reopened.as_str(), a.as_str()],
        "the old place did not come back"
    );
    mux.shutdown();
}

/// No known place: the reopened workspace goes where a new one goes under
/// the default `top` (first below Home), not after every row.
#[test]
fn a_reopened_workspace_with_no_known_place_goes_to_the_top_by_default() {
    let _top = NewWorkspacePlacement::Top.set_for_test();
    let session = Session::new("reopen-doc-top");
    let mux = session.open();
    let home = home(&mux);
    let a = empty_workspace(&mux, "a");
    let b = empty_workspace(&mux, "b");
    let c = empty_workspace(&mux, "c");

    let reopened = close_and_reopen(&mux, &b, true);

    assert_eq!(
        document_order(&mux),
        [home.as_str(), reopened.as_str(), c.as_str(), a.as_str()],
        "not first below Home under top"
    );
    mux.shutdown();
}

/// No known place under `bottom`: the reopened workspace goes last.
#[test]
fn a_reopened_workspace_with_no_known_place_follows_bottom() {
    let _bottom = NewWorkspacePlacement::Bottom.set_for_test();
    let session = Session::new("reopen-doc-bottom");
    let mux = session.open();
    let home = home(&mux);
    let a = empty_workspace(&mux, "a");
    let b = empty_workspace(&mux, "b");
    let c = empty_workspace(&mux, "c");

    let reopened = close_and_reopen(&mux, &b, true);

    assert_eq!(
        document_order(&mux),
        [home.as_str(), a.as_str(), c.as_str(), reopened.as_str()],
        "not last under bottom"
    );
    mux.shutdown();
}

fn close(mux: &Arc<Mux>, id: &str) {
    mutate(mux, "workspace.close", json!({"workspace": id}), &format!("close-{id}"));
}

/// Reopens the newest closed workspace (Cmd-Shift-T); returns its new id.
fn reopen_newest(mux: &Arc<Mux>, key: &str) -> String {
    let reopened = mutate(mux, "closed.reopen", json!({}), key);
    assert_eq!(reopened["kind"], "workspace", "reopen restored {reopened}");
    reopened["workspace_id"].as_str().unwrap().to_string()
}

/// `order` with `old` replaced by `new`.
fn renamed(order: &[String], old: &str, new: &str) -> Vec<String> {
    order.iter().map(|id| if id == old { new.to_string() } else { id.clone() }).collect()
}

/// Every closed workspace keeps its personal row (its place) until it
/// reopens, so the row right before a reopened one is often another closed
/// workspace's. That row has no document item; the reopened workspace still
/// takes its own place after the nearest open row, not the end (#56144).
#[test]
fn a_reopened_workspace_after_a_closed_neighbor_takes_its_old_place() {
    let _top = NewWorkspacePlacement::Top.set_for_test();
    let session = Session::new("reopen-after-closed-neighbor");
    let mux = session.open();
    let _home = home(&mux);
    let a = empty_workspace(&mux, "a");
    let b = empty_workspace(&mux, "b");
    let c = empty_workspace(&mux, "c");
    let _d = empty_workspace(&mux, "d");
    let before = document_order(&mux);
    // home, d, c, b, a: c sits right before b.

    close(&mux, &c);
    close(&mux, &b);
    let new_b = reopen_newest(&mux, "reopen-b");
    let mut expected = renamed(&before, &b, &new_b);
    expected.retain(|id| id != &c);
    assert_eq!(document_order(&mux), expected, "b lost its place after the closed c");

    let new_c = reopen_newest(&mux, "reopen-c");
    assert_eq!(
        document_order(&mux),
        renamed(&renamed(&before, &b, &new_b), &c, &new_c),
        "c lost its place"
    );
    let _ = a;
    mux.shutdown();
}

/// The same inside a group: a member reopens between its old neighbors
/// when the member right before it is closed too.
#[test]
fn a_reopened_group_member_after_a_closed_member_takes_its_old_place() {
    let _bottom = NewWorkspacePlacement::Bottom.set_for_test();
    let session = Session::new("reopen-group-after-closed");
    let mux = session.open();
    let _home = home(&mux);
    let group =
        mutate(&mux, "workspace_group.create", json!({"name": "Work"}), "group-work")["id"].clone();
    let members: Vec<String> = ["w", "x", "y", "z"]
        .iter()
        .map(|name| {
            let id = empty_workspace(&mux, name);
            mutate(
                &mux,
                "workspace.place",
                json!({"workspace": id, "group": group}),
                &format!("place-{name}"),
            );
            id
        })
        .collect();
    let _loose = empty_workspace(&mux, "loose");
    let before = document_order(&mux);
    let at = |id: &str| before.iter().position(|item| item == id).unwrap();
    assert!(at(&members[0]) < at(&members[1]) && at(&members[1]) < at(&members[2]));
    assert!(at(&members[2]) < at(&members[3]));

    close(&mux, &members[1]);
    close(&mux, &members[2]);
    let new_y = reopen_newest(&mux, "reopen-y");
    let mut expected = renamed(&before, &members[2], &new_y);
    expected.retain(|id| id != &members[1]);
    assert_eq!(document_order(&mux), expected, "y lost its place in its group");
    let group_of = |id: &str| {
        read(&mux, "workspace.placement.list", json!({}))
            .as_array()
            .unwrap()
            .iter()
            .find(|row| row["workspace"]["workspace_id"].as_str() == Some(id))
            .map(|row| row["group_id"].clone())
    };
    assert_eq!(group_of(&new_y), Some(group), "y left its group");
    mux.shutdown();
}

/// Reopen after the daemon restarts (the closed history and the kept row
/// are on disk) restores the same place.
#[test]
fn a_workspace_reopened_after_a_restart_takes_its_old_place() {
    let _top = NewWorkspacePlacement::Top.set_for_test();
    let session = Session::new("reopen-after-restart");
    let mux = session.open();
    let _home = home(&mux);
    let _a = empty_workspace(&mux, "a");
    let b = empty_workspace(&mux, "b");
    let c = empty_workspace(&mux, "c");
    let _d = empty_workspace(&mux, "d");
    let before = document_order(&mux);
    close(&mux, &c);
    close(&mux, &b);
    let mut closed_order = before.clone();
    closed_order.retain(|id| id != &b && id != &c);
    assert_eq!(document_order(&mux), closed_order);
    mux.shutdown();
    drop(mux);

    let mux = session.open();
    assert_eq!(document_order(&mux), closed_order, "the restart moved the open workspaces");
    let new_b = reopen_newest(&mux, "reopen-b-after-restart");
    let mut expected = renamed(&before, &b, &new_b);
    expected.retain(|id| id != &c);
    assert_eq!(document_order(&mux), expected, "b lost its place after the restart");
    mux.shutdown();
}

/// A whole workspace restored from a stash takes its old place too: the
/// restore moves its sidebar item in the same commit, as reopen does.
#[test]
fn a_workspace_restored_from_a_stash_takes_its_old_place() {
    let _top = NewWorkspacePlacement::Top.set_for_test();
    let session = Session::new("stash-restore-place");
    let mux = session.open();
    let _home = home(&mux);
    let _a = empty_workspace(&mux, "a");
    let b = empty_workspace(&mux, "b");
    let c = empty_workspace(&mux, "c");
    let _d = empty_workspace(&mux, "d");
    let before = document_order(&mux);
    close(&mux, &c);
    let stash = mutate(&mux, "stash.create", json!({"workspaces": [b]}), "stash-b");
    let restored = mutate(&mux, "stash.restore", json!({"stash": stash["stash_id"]}), "restore-b");
    let new_b = restored["workspace_ids"][0].as_str().unwrap().to_string();
    let mut expected = renamed(&before, &b, &new_b);
    expected.retain(|id| id != &c);
    assert_eq!(document_order(&mux), expected, "b lost its place on restore");
    mux.shutdown();
}

/// Top-level item ids (workspace public id or group item id) of `section`,
/// in document order.
fn top_level(mux: &Arc<Mux>, section: &str) -> Vec<String> {
    let doc = read(mux, "sidebar.get", json!({}));
    let mut items: Vec<(String, String)> = doc["items"]
        .as_array()
        .unwrap()
        .iter()
        .filter(|item| item["section"] == section && item["parent"].is_null())
        .map(|item| {
            let id = if item["body"]["type"] == "workspace" {
                item["body"]["ref"]["workspace_id"].as_str().unwrap_or_default().to_string()
            } else {
                item["id"].as_str().unwrap().to_string()
            };
            (item["order"].as_str().unwrap().to_string(), id)
        })
        .collect();
    items.sort();
    items.into_iter().map(|(_, id)| id).collect()
}

fn section_of(mux: &Arc<Mux>, item_id: &str) -> String {
    let doc = read(mux, "sidebar.get", json!({}));
    let item = doc["items"].as_array().unwrap().iter().find(|i| i["id"] == item_id).cloned();
    item.unwrap()["section"].as_str().unwrap().to_string()
}

fn group(mux: &Arc<Mux>, name: &str) -> String {
    mutate(mux, "workspace_group.create", json!({"name": name}), &format!("group-{name}"))["id"]
        .as_str()
        .unwrap()
        .to_string()
}

fn at(order: &[String], id: &str) -> usize {
    order.iter().position(|x| x == id).unwrap()
}

/// A group edit never moves the group above the groups before it when the
/// group right before it is pinned (no item in the machine section).
#[test]
fn renaming_a_group_after_a_pinned_group_keeps_its_place() {
    let _bottom = NewWorkspacePlacement::Bottom.set_for_test();
    let session = Session::new("group-after-pinned");
    let mux = session.open();
    let _a = empty_workspace(&mux, "a");
    let (g1, g2, g3) = (group(&mux, "G1"), group(&mux, "G2"), group(&mux, "G3"));
    let (i1, i3) = (format!("itm_g_{g1}"), format!("itm_g_{g3}"));
    let section = section_of(&mux, &i1);
    mutate(&mux, "workspace_group.update", json!({"workspace_group": g2, "pinned": true}), "pin");
    assert!(at(&top_level(&mux, &section), &i1) < at(&top_level(&mux, &section), &i3));
    mutate(&mux, "workspace_group.update", json!({"workspace_group": g3, "name": "G3b"}), "ren");
    let after = top_level(&mux, &section);
    assert!(at(&after, &i1) < at(&after, &i3), "renaming G3 moved it above G1: {after:?}");
    mux.shutdown();
}

/// Slotted groups keep their order when a closed workspace sits between
/// their slots and one of them changes.
#[test]
fn renaming_a_slotted_group_after_a_closed_row_keeps_group_order() {
    let _bottom = NewWorkspacePlacement::Bottom.set_for_test();
    let session = Session::new("slot-after-closed");
    let mux = session.open();
    let a = empty_workspace(&mux, "a");
    let b = empty_workspace(&mux, "b");
    let c = empty_workspace(&mux, "c");
    let (g1, g2) = (group(&mux, "G1"), group(&mux, "G2"));
    let personal: Vec<String> = read(&mux, "workspace.list", json!({"order": "personal"}))
        .as_array()
        .unwrap()
        .iter()
        .map(|w| w["id"].as_str().unwrap().to_string())
        .collect();
    let slot = |id: &str| at(&personal, id);
    mutate(
        &mux,
        "workspace_group.update",
        json!({"workspace_group": g1, "top_index": slot(&b)}),
        "s1",
    );
    mutate(
        &mux,
        "workspace_group.update",
        json!({"workspace_group": g2, "top_index": slot(&c)}),
        "s2",
    );
    let (i1, i2) = (format!("itm_g_{g1}"), format!("itm_g_{g2}"));
    let section = section_of(&mux, &i1);
    let slotted = top_level(&mux, &section);
    assert!(at(&slotted, &a) < at(&slotted, &i1));
    assert!(at(&slotted, &i1) < at(&slotted, &b) && at(&slotted, &b) < at(&slotted, &i2));
    close(&mux, &b);
    mutate(&mux, "workspace_group.update", json!({"workspace_group": g2, "name": "G2b"}), "ren");
    let after = top_level(&mux, &section);
    assert!(at(&after, &i1) < at(&after, &i2), "renaming G2 put it above G1: {after:?}");
    mux.shutdown();
}
