use serde_json::json;

use super::*;

fn ids(workspaces: &[Value]) -> Vec<&str> {
    workspaces.iter().map(|workspace| workspace["id"].as_str().unwrap()).collect()
}

/// This machine's section: `a`, then the archived tail `z`; `new` is not placed yet.
fn listed(active: &str) -> (Vec<Value>, DocumentOrder) {
    let order = DocumentOrder {
        ids: vec!["a".into(), "z".into()],
        machine_start: 0,
        archived_start: Some(1),
    };
    let workspaces =
        ["z", "new", "a"].map(|id| json!({ "id": id, "active": id == active })).to_vec();
    (workspaces, order)
}

#[test]
fn a_new_workspace_lists_above_the_archived_tail() {
    let (mut workspaces, order) = listed("a");
    sort_workspaces(&mut workspaces, "id", &order, NewWorkspacePlacement::Bottom);
    assert_eq!(ids(&workspaces), ["a", "new", "z"]);
    // After an archived active workspace: above the tail too.
    let (mut workspaces, order) = listed("z");
    sort_workspaces(&mut workspaces, "id", &order, NewWorkspacePlacement::AfterCurrent);
    assert_eq!(ids(&workspaces), ["a", "new", "z"]);
    let (mut workspaces, order) = listed("a");
    sort_workspaces(&mut workspaces, "id", &order, NewWorkspacePlacement::AfterCurrent);
    assert_eq!(ids(&workspaces), ["a", "new", "z"]);
}
