use serde_json::json;

use super::*;

fn snapshot() -> Value {
    json!({
        "screens": [
            {"id": "scr_a", "workspace_id": "ws_a"},
            {"id": "scr_b", "workspace_id": "ws_b"},
        ],
        "panes": [
            {"id": "pane_a", "screen_id": "scr_a"},
            {"id": "pane_b", "screen_id": "scr_b"},
        ],
        "tabs": [
            {"id": "tab_a", "pane_id": "pane_a", "content_kind": "terminal", "content_id": "term_a"},
            {"id": "tab_b", "pane_id": "pane_b", "content_kind": "terminal", "content_id": "term_b"},
            {"id": "tab_w", "pane_id": "pane_b", "content_kind": "browser", "content_id": "term_a"},
        ],
        "terminals": [
            {"id": "term_a", "cwd": "/work/app"},
            {"id": "term_b", "cwd": "/home"},
        ],
    })
}

#[test]
fn a_workspace_or_pane_is_in_a_folder_when_one_of_its_terminals_is() {
    let under_work = |folder: &str| folder.starts_with("/work");
    let workspaces = ids_in_folder(&snapshot(), Scope::Workspace, under_work);
    assert_eq!(workspaces, HashSet::from(["ws_a".to_owned()]));
    let panes = ids_in_folder(&snapshot(), Scope::Pane, under_work);
    assert_eq!(panes, HashSet::from(["pane_a".to_owned()]));
    assert!(ids_in_folder(&snapshot(), Scope::Workspace, |_| false).is_empty());
}

#[test]
fn a_tree_gives_each_workspace_its_panes_tabs_and_creator() {
    let rows = vec![
        json!({"id": "ws_a", "name": "tiny-weather",
               "extra": {"created_by": {"kind": "agent", "session": "s1", "creator": "ws_b"}}}),
        json!({"id": "ws_b", "name": "home", "extra": {}}),
        json!({"id": "ws_cloud", "name": "vm", "origin": "cloud"}),
    ];
    let tree = with_trees(&snapshot(), rows);
    assert_eq!(tree[0]["created_by"], json!({"kind": "agent", "session": "s1", "creator": "ws_b"}));
    assert_eq!(
        tree[0]["panes"],
        json!([{"id": "pane_a", "screen_id": "scr_a", "tabs": [
            {"id": "tab_a", "content_kind": "terminal", "content_id": "term_a", "cwd": "/work/app"},
        ]}])
    );
    assert_eq!(tree[1]["created_by"], Value::Null);
    assert_eq!(tree[1]["panes"][0]["tabs"].as_array().map(Vec::len), Some(2));
    assert_eq!(tree[1]["panes"][0]["tabs"][1]["content_kind"], "browser");
    assert!(tree[1]["panes"][0]["tabs"][1].get("cwd").is_none());
    // A Cloud machine's row, which this session's snapshot does not hold, is left as it is.
    assert_eq!(tree[2], json!({"id": "ws_cloud", "name": "vm", "origin": "cloud"}));

    let table = tree_human_rows(tree.as_array().unwrap());
    assert_eq!(table[0]["workspace"], "ws_a");
    assert_eq!(table[0]["created_by"], "agent s1");
    assert_eq!(table[0]["tab"], "tab_a");
    assert_eq!(table[0]["cwd"], "/work/app");
    // One row per tab, and a workspace with no tabs still gets one.
    assert_eq!(table.as_array().map(Vec::len), Some(4));
    assert_eq!(table[3]["workspace"], "ws_cloud");
}

#[test]
fn ids_keep_only_the_named_workspaces() {
    let filter = ListFilter { ids: vec!["ws_a".into(), "ws_c".into()], ..ListFilter::default() };
    let rows = json!([{"id": "ws_api"}, {"id": "ws_b"}, {"id": "ws_c1"}]);
    assert_eq!(
        listed(&filter, Scope::Workspace, rows).unwrap(),
        json!([{"id": "ws_api"}, {"id": "ws_c1"}])
    );
    let tree = ListFilter { tree: true, ..ListFilter::default() };
    assert_eq!(
        listed(&tree, Scope::Workspace, json!([])).unwrap_err()["code"],
        "validation.invalid"
    );
}

/// The app's Cloud machine workspaces skip the daemon's list: `--name`
/// still filters them, and `--cwd` is refused instead of ignored.
#[test]
fn rows_from_the_app_are_filtered_by_name_and_refuse_a_workspace_cwd() {
    let rows = json!([{"id": "ws_api", "name": "api"}, {"id": "ws_web", "name": "web"}]);
    let by_name = ListFilter { name: Some("api".to_owned()), ..ListFilter::default() };
    assert_eq!(
        listed(&by_name, Scope::Workspace, rows.clone()).unwrap(),
        json!([{"id": "ws_api", "name": "api"}])
    );
    assert_eq!(listed(&ListFilter::default(), Scope::Workspace, rows.clone()).unwrap(), rows);
    let by_cwd = ListFilter {
        cwd: Some(super::super::super::command::CwdFilter::for_test("/work")),
        ..ListFilter::default()
    };
    let error = listed(&by_cwd, Scope::Workspace, rows).unwrap_err();
    assert_eq!(error["code"], "validation.invalid");
    let terminals = json!([{"id": "t1", "cwd": "/work/app"}, {"id": "t2", "cwd": "/home"}]);
    assert_eq!(
        listed(&by_cwd, Scope::Terminal, terminals).unwrap(),
        json!([{"id": "t1", "cwd": "/work/app"}])
    );
}
