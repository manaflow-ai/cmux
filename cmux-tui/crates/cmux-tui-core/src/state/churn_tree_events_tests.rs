//! Sidebar churn (the app's sidebar-churn bench): the four CLI writes that
//! rearrange the sidebar each reach a subscribed frontend as a change to one
//! workspace, never as `tree-changed`, which makes every delta client
//! (the macOS app) refetch and re-apply the whole tree (`list-workspaces`)
//! for a change to one workspace.

use serde_json::json;

use super::tests::{empty_workspace, mutate};
use crate::MuxEventReceiver;
use crate::mux::*;
use crate::surface::SurfaceOptions;

/// The events a write sent to a subscriber, drained after it returns.
fn tree_changes(events: &MuxEventReceiver) -> usize {
    let mut count = 0;
    while let Ok(event) = events.try_recv() {
        if matches!(event, MuxEvent::TreeChanged) {
            count += 1;
        }
    }
    count
}

#[test]
fn the_sidebar_churn_writes_never_send_tree_changed() {
    let mux = Mux::new_for_test("state-churn-tree-events", SurfaceOptions::default());
    let workspaces =
        (0..3).map(|i| empty_workspace(&mux, &format!("churn-{i}"))).collect::<Vec<_>>();
    let group =
        mutate(&mux, "workspace_group.create", json!({"name": "Churn"}), "churn-group")["id"]
            .as_str()
            .unwrap()
            .to_string();
    let events = mux.subscribe();
    let writes = [
        // `cmux workspace <id> move --index 0`
        ("workspace.move", json!({"workspace": workspaces[2], "index": 0}), "move"),
        // `cmux workspace <id> update --task-status done`
        ("workspace.update", json!({"workspace": workspaces[1], "task_status": "done"}), "task"),
        // `cmux workspace <id> update --description ...`
        ("workspace.update", json!({"workspace": workspaces[1], "description": "notes"}), "notes"),
        // `cmux workspace group <g> add --workspace <id> --index 0`
        (
            "workspace.place",
            json!({"workspace": workspaces[0], "group": group, "index": 0}),
            "group",
        ),
        // `cmux workspace <id> status set bench "step 1"`
        (
            "workspace_status.set",
            json!({"workspace": workspaces[0], "key": "bench", "text": "step 1"}),
            "pill",
        ),
    ];
    for (operation, params, key) in writes {
        mutate(&mux, operation, params, &format!("write-{key}"));
        assert_eq!(
            tree_changes(&events),
            0,
            "{operation} ({key}) sent tree-changed: every delta client refetches the whole tree"
        );
    }
}
