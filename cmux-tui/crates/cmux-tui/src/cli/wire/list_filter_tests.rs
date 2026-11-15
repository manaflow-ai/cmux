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

/// The app's Cloud machine workspaces skip the daemon's list: `--name`
/// still filters them, and `--cwd` is refused instead of ignored.
#[test]
fn rows_from_the_app_are_filtered_by_name_and_refuse_a_workspace_cwd() {
    let rows = json!([{"id": "ws_api", "name": "api"}, {"id": "ws_web", "name": "web"}]);
    let by_name = ListFilter { name: Some("api".to_owned()), cwd: None };
    assert_eq!(
        listed(&by_name, Scope::Workspace, rows.clone()).unwrap(),
        json!([{"id": "ws_api", "name": "api"}])
    );
    assert_eq!(listed(&ListFilter::default(), Scope::Workspace, rows.clone()).unwrap(), rows);
    let by_cwd = ListFilter {
        name: None,
        cwd: Some(super::super::super::command::CwdFilter::for_test("/work")),
    };
    let error = listed(&by_cwd, Scope::Workspace, rows).unwrap_err();
    assert_eq!(error["code"], "validation.invalid");
    let terminals = json!([{"id": "t1", "cwd": "/work/app"}, {"id": "t2", "cwd": "/home"}]);
    assert_eq!(
        listed(&by_cwd, Scope::Terminal, terminals).unwrap(),
        json!([{"id": "t1", "cwd": "/work/app"}])
    );
}
