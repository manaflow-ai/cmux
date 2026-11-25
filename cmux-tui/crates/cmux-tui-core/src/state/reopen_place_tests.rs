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
