//! Cmd-N lands on top in one state change (plans/cmux-next/sidebar-ordering-DESIGN.md,
//! "A new workspace is first, in one change"): a create is one commit, and that commit carries the
//! new workspace's sidebar document item at the top of its machine section (below Home), so a
//! client applying the commit's batch has the final order and never sends a move of its own.

use serde_json::{Value, json};

use super::tests::{Session, empty_workspace, read, revision, send};
use crate::mux::*;
use crate::state::prelude::*;

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

#[test]
fn a_create_is_one_commit_that_puts_the_new_workspace_first_in_the_document() {
    let session = Session::new("new-doc-top");
    let mux = session.open();
    let home = send(&mux, "workspace.ensure_home", json!({}), Some("connect")).unwrap()["value"]
        ["workspace_id"]
        .as_str()
        .unwrap()
        .to_string();
    let a = empty_workspace(&mux, "a");
    let b = empty_workspace(&mux, "b");
    let before = revision(&mux);
    let c = empty_workspace(&mux, "c");

    assert_eq!(revision(&mux), before + 1, "the create took more than one commit");
    let batches = mux.resource_events_after(before).unwrap().batches;
    assert_eq!(batches.len(), 1, "the create published {} batches", batches.len());
    let changes = batches[0].changes.as_array().cloned().unwrap_or_default();
    let item = |change: &Value| {
        change["resource"] == "sidebar_item" && change.to_string().contains(c.as_str())
    };
    assert!(
        changes.iter().any(item),
        "the create's batch has no sidebar item for the new workspace: {changes:?}"
    );
    let ids = [home.as_str(), a.as_str(), b.as_str(), c.as_str()];
    assert_eq!(
        document_order(&mux, &ids),
        [home.as_str(), c.as_str(), b.as_str(), a.as_str()],
        "the new workspace is not first below Home in the document"
    );
    mux.shutdown();
}

/// `top` with a stale personal order (Home's row out of first, as a sidebar-doc
/// sync can leave it; `home_already_out_of_first_slot_does_not_block_other_moves`):
/// the daemon puts the new row right after Home's row, and the document shows it
/// first below Home, not after the rows the stale order lists before Home.
#[test]
fn a_create_under_top_is_first_in_the_document_when_home_is_not_first_in_the_personal_order() {
    let _top = crate::user_settings::NewWorkspacePlacement::Top.set_for_test();
    let session = Session::new("new-doc-top-stale-home");
    let mux = session.open();
    let home = send(&mux, "workspace.ensure_home", json!({}), Some("connect")).unwrap()["value"]
        ["workspace_id"]
        .as_str()
        .unwrap()
        .to_string();
    let a = empty_workspace(&mux, "a");
    let b = empty_workspace(&mux, "b");
    let b_key = mux.with_state(|state| {
        state.workspaces.iter().find(|item| item.public_id.as_str() == b).unwrap().key.clone()
    });
    {
        // Personal order b, Home, a; the document still shows Home, b, a.
        let registry = mux.workspace_registry.lock().unwrap();
        let db = registry.connection.get();
        db.execute(
            "UPDATE personal_workspaces
             SET position = (SELECT MIN(position) - 1 FROM personal_workspaces)
             WHERE workspace_key = ?1",
            [&b_key],
        )
        .unwrap();
    }
    let ids = [home.as_str(), a.as_str(), b.as_str()];
    assert_eq!(document_order(&mux, &ids), [home.as_str(), b.as_str(), a.as_str()]);
    let c = empty_workspace(&mux, "c");
    let ids = [home.as_str(), a.as_str(), b.as_str(), c.as_str()];
    assert_eq!(
        document_order(&mux, &ids),
        [home.as_str(), c.as_str(), b.as_str(), a.as_str()],
        "the new workspace is not first below Home in the document"
    );
    mux.shutdown();
}

/// The app's Cmd-N under `top`, seeded as `CmdNTopInGroupFramesTests` does: each create names the
/// window's current workspace and `top` (`create-workspace {places_by_setting, current, placement}`);
/// the new one is first in the document whatever the current workspace is.
#[test]
fn top_creates_naming_the_current_workspace_go_first_in_the_document() {
    use crate::state::personal_order::{ClientCurrent, with_client_current};
    use crate::user_settings::NewWorkspacePlacement;
    let _top = NewWorkspacePlacement::Top.set_for_test();
    let session = Session::new("new-doc-top-client-current");
    let mux = session.open();
    let key_of = |id: &str| {
        mux.with_state(|state| {
            state.workspaces.iter().find(|item| item.public_id.as_str() == id).unwrap().key.clone()
        })
    };
    let made = |name: &str, current: Option<String>, placement: NewWorkspacePlacement| {
        with_client_current(Some(ClientCurrent { current, placement: Some(placement) }), || {
            empty_workspace(&mux, name)
        })
    };
    let w0 = made("w0", None, NewWorkspacePlacement::AfterCurrent);
    let w1 = made("w1", Some(key_of(&w0)), NewWorkspacePlacement::Top);
    let w2 = made("w2", Some(key_of(&w1)), NewWorkspacePlacement::Top);
    let w3 = made("w3", Some(key_of(&w2)), NewWorkspacePlacement::Top);
    let ids = [w0.as_str(), w1.as_str(), w2.as_str(), w3.as_str()];
    assert_eq!(document_order(&mux, &ids), [w3.as_str(), w2.as_str(), w1.as_str(), w0.as_str()]);
    let w4 = made("w4", Some(key_of(&w0)), NewWorkspacePlacement::Top);
    let w5 = made("w5", None, NewWorkspacePlacement::Top);
    let ids = [w0.as_str(), w1.as_str(), w2.as_str(), w3.as_str(), w4.as_str(), w5.as_str()];
    assert_eq!(
        document_order(&mux, &ids),
        [w5.as_str(), w4.as_str(), w3.as_str(), w2.as_str(), w1.as_str(), w0.as_str()],
        "a top create naming a current workspace is not first in the document (w0..w5 = {ids:?})"
    );
    mux.shutdown();
}
