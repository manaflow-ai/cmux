//! A frontend projection holds whatever one request can carry (P-AUSTIN B9
//! row 15). The app keeps its whole window state in one personal projection
//! (`WindowStateStore`, subject `windows`): every window with its workspace
//! keys, selected tab per pane and focused pane per workspace. A fixed 1 MiB
//! cap refused `put-frontend-projection` for a large session, so the window
//! state was not saved and the next launch restored an older layout.

use serde_json::{Value, json};

use super::*;

fn temp_root(label: &str) -> PathBuf {
    std::env::temp_dir().join(format!("cmux-projection-size-{label}-{}", new_uuid_v4()))
}

/// A window-state document in the app's shape (`WindowStateDocument`
/// schema 1) with `windows` windows of `workspaces` workspaces, each with
/// `panes` panes.
fn window_state(windows: usize, workspaces: usize, panes: usize) -> Value {
    let records: Vec<Value> = (0..windows)
        .map(|window| {
            let keys: Vec<String> = (0..workspaces)
                .map(|w| format!("ws-{window:03}-{w:04}-{}", "k".repeat(24)))
                .collect();
            let mut selected = serde_json::Map::new();
            let mut focused = serde_json::Map::new();
            for key in &keys {
                for pane in 0..panes {
                    selected
                        .insert(format!("pane-{key}-{pane}"), json!(format!("tab-{key}-{pane}")));
                }
                focused.insert(key.clone(), json!(format!("pane-{key}-0")));
            }
            json!({
                "id": format!("window-{window}"),
                "workspace_key": keys[0],
                "workspace_keys": keys,
                "selected_tabs": selected,
                "focused_panes": focused,
                "frame": {"x": 0.0, "y": 0.0, "width": 1440.0, "height": 900.0},
                "is_full_screen": false,
                "sidebar_hidden": false,
                "order": window,
                "is_closed": false,
            })
        })
        .collect();
    json!({"windows": records, "collapsed_groups": {}})
}

#[test]
fn a_window_state_projection_over_one_mebibyte_is_saved_and_restores_after_reopen() {
    // 4 windows x 500 workspaces x 6 panes: about 1.4 MB of JSON.
    let document = window_state(4, 500, 6);
    let bytes = canonical_json(&document).unwrap().len();
    assert!(bytes > 1024 * 1024, "the document is over the old 1 MiB cap: {bytes} bytes");
    assert!(bytes < crate::REMOTE_CLIENT_MESSAGE_MAX_BYTES, "one request carries it");
    let root = temp_root("window-state");
    {
        let mut registry = WorkspaceRegistry::open(&root, "session").unwrap();
        let stored = registry
            .put_frontend_projection(
                &WorkspaceMutation::daemon("save-windows", "cmux-next").unwrap(),
                "cmux-next",
                "personal",
                "windows",
                1,
                Some(0),
                &document,
            )
            .expect("put-frontend-projection saves the whole window state");
        assert_eq!(stored.projection.projection_revision, 1);
    }
    let registry = WorkspaceRegistry::open(&root, "session").unwrap();
    let restored = registry
        .get_frontend_projection("cmux-next", "personal", "windows")
        .unwrap()
        .expect("the window state is there after a reopen");
    assert_eq!(restored.projection, document);
    drop(registry);
    let _ = fs::remove_dir_all(root);
}
