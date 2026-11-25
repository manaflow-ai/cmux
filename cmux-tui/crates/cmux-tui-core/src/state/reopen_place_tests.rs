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
    if let Some(found) = group_of(&new_y) {
        assert_eq!(found, group, "y left its group");
    }
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
