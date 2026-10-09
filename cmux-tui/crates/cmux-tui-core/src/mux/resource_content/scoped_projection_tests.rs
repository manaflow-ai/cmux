//! A topology create projects only the workspace it changed: its cost and
//! its journal record do not grow with the rest of the session.

use std::collections::HashSet;

use serde_json::Value;

use crate::model::State;
use crate::mux::Mux;
use crate::resource::{ContentPublicId, WorkspacePublicId};
use crate::{SurfaceOptions, WorkspaceId};

fn workspace(mux: &Mux, name: &str) -> (WorkspaceId, WorkspacePublicId) {
    mux.with_state(|state: &State| {
        let workspace = state.workspaces.iter().find(|w| w.name == name).unwrap();
        (workspace.id, workspace.public_id.clone())
    })
}

/// Public ids of every screen, pane, tab and tab content under `workspace`.
fn subtree_ids(mux: &Mux, workspace: &WorkspacePublicId) -> (HashSet<String>, u64) {
    let topology = mux.workspace_registry.lock().unwrap().resource_topology_snapshot().unwrap();
    let screens = topology
        .screens
        .iter()
        .filter(|screen| &screen.workspace_id == workspace)
        .map(|screen| screen.public_id.to_string())
        .collect::<HashSet<_>>();
    let panes = topology
        .panes
        .iter()
        .filter(|pane| screens.contains(pane.screen_id.as_str()))
        .map(|pane| pane.public_id.to_string())
        .collect::<HashSet<_>>();
    let mut ids = screens.iter().chain(&panes).cloned().collect::<HashSet<_>>();
    for tab in topology.tabs.iter().filter(|tab| panes.contains(tab.pane_id.as_str())) {
        ids.insert(tab.public_id.to_string());
        ids.insert(match &tab.content_id {
            ContentPublicId::Terminal(id) => id.to_string(),
            ContentPublicId::Browser(id) => id.to_string(),
        });
    }
    (ids, topology.revision)
}

fn stat(mux: &Mux, field: &str) -> u64 {
    serde_json::to_value(mux.resource_projection_stats()).unwrap()[field].as_u64().unwrap_or(0)
}

#[test]
fn creating_a_terminal_restates_no_resource_of_another_workspace() {
    let mux = Mux::new_for_test("scoped-projection", SurfaceOptions::default());
    mux.new_workspace(Some("a".into()), Some((80, 24))).unwrap();
    mux.new_workspace(Some("b".into()), Some((80, 24))).unwrap();
    let ((a, _), (b, b_public)) = (workspace(&mux, "a"), workspace(&mux, "b"));
    for _ in 0..3 {
        mux.create_terminal_in_workspace(a, None, None, None, Some((80, 24))).unwrap();
        mux.create_terminal_in_workspace(b, None, None, None, Some((80, 24))).unwrap();
    }
    let (b_ids, revision) = subtree_ids(&mux, &b_public);
    assert!(b_ids.len() >= 8, "workspace b has a screen, a pane and four tabs: {b_ids:?}");
    let (scoped, full) = (stat(&mux, "scoped_projections"), stat(&mux, "full_projections"));

    mux.create_terminal_in_workspace(a, None, None, None, Some((80, 24))).unwrap();

    let page = mux.workspace_registry.lock().unwrap().resource_events_after(revision).unwrap();
    assert!(!page.batches.is_empty(), "the create committed a resource revision");
    for batch in &page.batches {
        for change in batch.changes.as_array().unwrap() {
            let id = change["id"].as_str().unwrap_or_default();
            assert!(
                !b_ids.contains(id),
                "a create in workspace a restated workspace b's {} {id}: {}",
                change["resource"],
                batch.changes
            );
        }
    }
    assert_eq!(stat(&mux, "scoped_projections"), scoped + 1, "the create projected one scope");
    assert_eq!(stat(&mux, "full_projections"), full, "the create read no full topology");
    assert_eq!(stat(&mux, "crosscheck_mismatches"), 0);
}

#[test]
fn scoped_creates_match_the_full_projection_under_mixed_creates() {
    let mux = Mux::new_for_test("scoped-projection-crosscheck", SurfaceOptions::default());
    for name in ["a", "b", "c"] {
        mux.new_workspace(Some(name.into()), Some((80, 24))).unwrap();
    }
    let ids = ["a", "b", "c"].map(|name| workspace(&mux, name).0);
    for round in 0..4 {
        for (index, id) in ids.iter().enumerate() {
            if (round + index) % 2 == 0 {
                mux.create_terminal_in_workspace(*id, None, None, None, Some((80, 24))).unwrap();
            }
        }
    }
    let checks = stat(&mux, "crosschecks");
    assert!(checks >= 6, "every scoped create ran the debug cross-check: {checks}");
    assert_eq!(stat(&mux, "crosscheck_mismatches"), 0);
    let value: Value = serde_json::to_value(mux.resource_projection_stats()).unwrap();
    assert!(value["scoped_projections"].as_u64().unwrap_or(0) >= 6, "{value}");
}

#[test]
fn scoped_creates_without_the_crosscheck_leave_nothing_for_a_full_projection() {
    use crate::workspace_registry::resource_store::prune_unchanged_resource_changes;
    super::scoped_projection::without_crosscheck(|| {
        let mux = Mux::new_for_test("scoped-projection-release", SurfaceOptions::default());
        for name in ["a", "b", "c"] {
            mux.new_workspace(Some(name.into()), Some((80, 24))).unwrap();
        }
        let ids = ["a", "b", "c"].map(|name| workspace(&mux, name).0);
        for round in 0..3 {
            for id in &ids[round % 2..] {
                mux.create_terminal_in_workspace(*id, None, None, None, Some((80, 24))).unwrap();
            }
        }
        // Split, browser and create paths in b, then a scoped create in a:
        // every topology change outside a's scope was committed by its own
        // projection, so the scoped create leaves nothing behind.
        let placement =
            mux.create_terminal_in_workspace(ids[1], None, None, None, Some((80, 24))).unwrap();
        mux.split(placement.pane, crate::SplitDir::Right, Some((80, 24))).unwrap();
        let browser = mux
            .new_browser_tab("about:blank#scoped".into(), Some(placement.pane), Some((80, 24)))
            .unwrap();
        mux.create_terminal_in_workspace(ids[0], None, None, None, Some((80, 24))).unwrap();
        assert!(stat(&mux, "scoped_projections") >= 6, "creates ran scoped");
        assert_eq!(stat(&mux, "crosschecks"), 0, "the cross-check was off");
        // The reference projection of the live tree finds every row stored.
        let full = mux.resource_effect_projection().unwrap();
        let registry = mux.workspace_registry.lock().unwrap();
        let transaction = registry.connection.unchecked_transaction().unwrap();
        let written = prune_unchanged_resource_changes(&transaction, &full.patch).unwrap();
        assert!(written.changes.is_empty(), "scoped creates left rows behind: {written:?}");
        drop(transaction);
        drop(registry);
        browser.kill();
    });
}
