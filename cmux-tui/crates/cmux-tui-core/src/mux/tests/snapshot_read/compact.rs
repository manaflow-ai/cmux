//! The cached snapshot keeps its public workspaces, screens, panes, tabs and state fields as compact JSON text
//! (`resource_api/committed_snapshot.rs` `CompactJson`), not as `Value` trees, and a reply built from that text
//! has the bytes of the values decorated from the rows.
//!
//! CMUX-571: at 1,000 workspaces dhat put ~10.5 MB under `committed_snapshot::build`, most of it the `Value`
//! trees the cache kept between reads.

use super::*;

/// The parts of a reply that come from the cache, by the key of the decorated reference.
fn cached_parts(snapshot: &Value) -> [(&'static str, &Value); 5] {
    [
        ("workspaces", &snapshot["workspaces"]),
        ("screens", &snapshot["screens"]),
        ("panes", &snapshot["panes"]),
        ("tabs", &snapshot["tabs"]),
        ("state", &snapshot["extra"]["state"]),
    ]
}

/// A session with splits, a pinned tab, tab zooms that are not exact in binary, and a workspace status: each
/// part of the reply that comes from the cache, cold and warm, has the bytes and the value of the same part
/// decorated from the rows with no text between.
#[test]
fn a_snapshot_reply_has_the_bytes_of_the_decorated_rows() {
    let root = temp_root("compact-bytes");
    let mux = session_at_rest("snapshot-compact-bytes", &root);
    grow_to(&mux, 3);
    let created = call(
        &mux,
        "workspace.create",
        json!({"initial_content":"terminal","name":"compact-split"}),
        Some("compact-create"),
    );
    let pane = created["value"]["pane_id"].as_str().unwrap().to_string();
    call(&mux, "pane.split", json!({"pane":pane,"direction":"right"}), Some("compact-split"));
    let (before, ..) = read_cut(&mux);
    let tabs = before["tabs"].as_array().unwrap();
    assert!(tabs.len() >= 2, "setup: the split made a second tab: {before}");
    let (first, second) = (tabs[0]["id"].clone(), tabs[1]["id"].clone());
    call(&mux, "tab.update", json!({"tab":first,"zoom":1.1}), Some("compact-zoom-1"));
    call(&mux, "tab.update", json!({"tab":second,"zoom":0.7}), Some("compact-zoom-2"));
    call(&mux, "tab.pin", json!({"tab":second}), Some("compact-pin"));
    let workspace = before["workspaces"][0]["id"].as_str().unwrap().to_string();
    mux.state_workspace_status(
        &WorkspaceMutation::daemon_local("test"),
        "workspace_status.set",
        None,
        &mux.local_workspace_selectors(&workspace),
        WorkspaceStatusChange::Set {
            key: "compact".into(),
            text: "compact-status \"quoted\" \u{1F680}".into(),
            icon: None,
            color: None,
            meta: Box::default(),
        },
    )
    .unwrap();

    let (cold, ..) = read_cut(&mux);
    let (warm, ..) = read_cut(&mux);
    let reference = mux
        .committed_snapshots
        .as_ref()
        .expect("a file registry caches its snapshot")
        .with_reader_for_test(|connection| {
            crate::resource_api::decorated_snapshot_values_for_test(connection, &mux)
        })
        .unwrap();
    drop(mux);
    let _ = std::fs::remove_dir_all(&root);

    let zooms = reference["tabs"]
        .as_array()
        .unwrap()
        .iter()
        .filter_map(|tab| tab["extra"]["zoom"].as_f64())
        .collect::<Vec<_>>();
    assert_eq!(zooms.len(), 2, "setup: both tabs carry a zoom: {}", reference["tabs"]);
    assert!(
        reference["tabs"].to_string().contains("\"pinned\":true"),
        "setup: a tab is pinned: {}",
        reference["tabs"]
    );
    assert!(
        reference["state"]["workspace_status"].to_string().contains("compact-status"),
        "setup: the status is in the state fields: {}",
        reference["state"]
    );
    for (read, snapshot) in [("cold", &cold), ("warm", &warm)] {
        for (key, part) in cached_parts(snapshot) {
            assert_eq!(part, &reference[key], "the {read} reply changed the value of {key}");
            assert_eq!(
                serde_json::to_string(part).unwrap(),
                serde_json::to_string(&reference[key]).unwrap(),
                "the {read} reply changed the bytes of {key}"
            );
        }
    }
    assert_eq!(
        serde_json::to_string(&cold).unwrap(),
        serde_json::to_string(&warm).unwrap(),
        "a warm reply differs from the cold one"
    );
}

/// What the cache keeps between reads for its workspaces, screens, panes, tabs and state fields is their compact
/// text: exactly the bytes those parts of a reply serialize to, and a small bound per workspace. A cache of
/// `Value` trees has no such text (and costs about five times it).
#[test]
fn the_cached_snapshot_keeps_compact_text_not_value_trees() {
    const WORKSPACES: usize = 200;
    let root = temp_root("compact-retained");
    let mux = session_at_rest("snapshot-compact-retained", &root);
    grow_to(&mux, WORKSPACES);
    let (snapshot, ..) = read_cut(&mux);
    let retained = crate::resource_api::retained_public_bytes_for_test(&mux)
        .expect("a file registry caches its snapshot after a read");
    drop(mux);
    let _ = std::fs::remove_dir_all(&root);

    assert_eq!(snapshot["workspaces"].as_array().unwrap().len(), WORKSPACES, "setup: workspaces");
    let serialized = cached_parts(&snapshot)
        .iter()
        .map(|(_, part)| serde_json::to_string(part).unwrap().len())
        .sum::<usize>();
    assert_eq!(retained, serialized, "the cache keeps more than the compact text of its parts");
    assert!(
        retained < WORKSPACES * 2048,
        "the cache keeps {retained} bytes for {WORKSPACES} empty workspaces (bound {} bytes)",
        WORKSPACES * 2048
    );
}
