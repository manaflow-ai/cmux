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
