//! A workspace of another machine lists where `workspaces.newPlacement` puts
//! every new workspace (Lawrence 2026-11-12: "by default all new workspaces
//! should go to the top"). This daemon writes no personal row for another
//! machine's create: the app sees it live, unplaced, and sends
//! `sidebar.adopt`, which placed it at the end of its machine section, so a
//! new remote workspace listed last however the setting was set.

use cmux_tui_util::user_settings::NewWorkspacePlacement;
use serde_json::json;

use super::tests::{Session, read, send};
use crate::mux::*;
use crate::state::prelude::*;

const REMOTE: &str = "reg_remote_mac";

/// The workspace ids of `REMOTE`'s machine section, in document order.
fn remote_rows(mux: &Arc<Mux>) -> Vec<String> {
    let doc = read(mux, "sidebar.get", json!({}));
    let mut items: Vec<(String, String, String)> = doc["items"]
        .as_array()
        .into_iter()
        .flatten()
        .filter(|item| {
            item["body"]["type"] == "workspace" && item["body"]["ref"]["session_id"] == REMOTE
        })
        .filter(|item| item["parent"].is_null())
        .map(|item| {
            (
                item["order"].as_str().unwrap_or_default().to_string(),
                item["id"].as_str().unwrap_or_default().to_string(),
                item["body"]["ref"]["workspace_id"].as_str().unwrap_or_default().to_string(),
            )
        })
        .collect();
    items.sort();
    items.into_iter().map(|(_, _, workspace)| workspace).collect()
}

/// The `sidebar.adopt` the app sends for another machine's live workspaces
/// the document does not place yet.
fn adopt(mux: &Arc<Mux>, workspaces: &[&str], key: &str) {
    let refs: Vec<Value> = workspaces
        .iter()
        .map(|workspace| json!({"session_id": REMOTE, "workspace_id": workspace}))
        .collect();
    send(mux, "sidebar.adopt", json!({"refs": refs}), Some(key))
        .unwrap_or_else(|error| panic!("sidebar.adopt failed: {error:?}"));
}

#[test]
fn a_new_remote_workspace_goes_first_in_its_machine_section_by_default() {
    let session = Session::new("remote-adopt-top");
    let mux = session.open();
    // The machine connects: its workspaces come in their own order.
    adopt(&mux, &["ws_a", "ws_b"], "connect");
    assert_eq!(remote_rows(&mux), ["ws_a", "ws_b"], "the first adopt keeps the machine's order");

    adopt(&mux, &["ws_c"], "new-c");
    adopt(&mux, &["ws_d"], "new-d");

    assert_eq!(
        remote_rows(&mux),
        ["ws_d", "ws_c", "ws_a", "ws_b"],
        "a new workspace of another machine listed last, not first"
    );
    mux.shutdown();
}

#[test]
fn a_new_remote_workspace_goes_last_under_bottom() {
    let _bottom = NewWorkspacePlacement::Bottom.set_for_test();
    let session = Session::new("remote-adopt-bottom");
    let mux = session.open();
    adopt(&mux, &["ws_a", "ws_b"], "connect");
    adopt(&mux, &["ws_c"], "new-c");
    assert_eq!(remote_rows(&mux), ["ws_a", "ws_b", "ws_c"]);
    mux.shutdown();
}
