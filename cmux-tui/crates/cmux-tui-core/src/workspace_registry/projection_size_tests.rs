//! The size bound of a stored frontend projection (P-AUSTIN B9 row 15): a
//! projection at the bound is stored, one byte over is refused with its size,
//! and the idempotency ledger keeps no copy of the body.

use serde_json::{Value, json};

use super::*;

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
fn a_projection_over_its_snapshot_share_is_refused_with_its_size() {
    let mut registry = WorkspaceRegistry::in_memory("projection-bound").unwrap();
    let bound = MAX_PROJECTION_BYTES;
    let filler = |bytes: usize| json!({"windows": [], "pad": "x".repeat(bytes)});
    let overhead = canonical_json(&filler(0)).unwrap().len();
    let put = |registry: &mut WorkspaceRegistry, id: &str, document: &Value, expected: u64| {
        registry.put_frontend_projection(
            &WorkspaceMutation::daemon(id, "cmux-next").unwrap(),
            "cmux-next",
            "personal",
            "windows",
            1,
            Some(expected),
            document,
        )
    };
    put(&mut registry, "at-bound", &filler(bound - overhead), 0)
        .expect("a projection at the bound is stored");
    let error =
        put(&mut registry, "over-bound", &filler(bound - overhead + 1), 1).unwrap_err().to_string();
    assert!(
        error.contains(&format!("is {} bytes, over {bound}", bound + 1)),
        "the refusal names the size: {error}"
    );
}

/// The idempotency ledger keeps a digest and a result without the body, so a
/// large window state is stored once per save, not three times; a replay
/// still returns the body, and a retry with another body is refused.
#[test]
fn the_projection_ledger_keeps_no_copy_of_the_body_and_still_replays_it() {
    let mut registry = WorkspaceRegistry::in_memory("projection-ledger").unwrap();
    let document = window_state(2, 100, 4);
    let mutation = WorkspaceMutation::daemon("save-1", "cmux-next").unwrap();
    let put = |registry: &mut WorkspaceRegistry, document: &Value| {
        registry.put_frontend_projection(
            &mutation,
            "cmux-next",
            "personal",
            "windows",
            1,
            Some(0),
            document,
        )
    };
    assert!(!put(&mut registry, &document).unwrap().replayed);
    let (fingerprint, result): (String, String) = registry
        .connection
        .get()
        .query_row(
            "SELECT fingerprint, result_json FROM projection_mutations WHERE mutation_id = 'save-1'",
            [],
            |row| Ok((row.get(0)?, row.get(1)?)),
        )
        .unwrap();
    let body = canonical_json(&document).unwrap().len();
    assert!(fingerprint.starts_with("sha256:") && fingerprint.len() < 100, "{fingerprint}");
    assert!(result.len() < 1024, "the result keeps no body: {} bytes of {body}", result.len());
    let replay = put(&mut registry, &document).unwrap();
    assert!(replay.replayed);
    assert_eq!(replay.projection.projection, document);
    assert_eq!(replay.projection.projection_revision, 1);
    let error = put(&mut registry, &window_state(2, 100, 5)).unwrap_err().to_string();
    assert!(error.contains("retried with a different payload"), "{error}");
}
