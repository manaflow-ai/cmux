use super::*;

fn identity(beside: Value) -> Value {
    json!({
        "caller": {"agent_session": "s", "workspace": "ws_a", "pane": "pane_chat", "screen": "screen_a"},
        "beside": beside,
    })
}

#[test]
fn an_existing_column_right_of_the_chat_takes_the_tab() {
    let placed =
        placement(&identity(json!({"pane": "pane_right", "placement": "existing_column"})));
    assert_eq!(
        placed,
        Some(Placement::Pane { workspace: "ws_a".into(), pane: "pane_right".into() })
    );
}

#[test]
fn no_column_right_of_the_chat_makes_one() {
    let placed = placement(&identity(json!({"pane": null, "placement": "new_column"})));
    assert_eq!(
        placed,
        Some(Placement::NewColumn { workspace: "ws_a".into(), chat_pane: "pane_chat".into() })
    );
}

#[test]
fn a_terminal_goes_to_the_column_pane_that_already_holds_one() {
    let beside = json!({"pane": "pane_web", "placement": "existing_column", "panes": [
        {"id": "pane_web", "kinds": ["browser"]}, {"id": "pane_term", "kinds": ["terminal"]},
    ]});
    assert_eq!(
        placement(&identity(beside)),
        Some(Placement::Pane { workspace: "ws_a".into(), pane: "pane_term".into() })
    );
    let one = json!({"pane": "pane_term", "placement": "existing_column", "panes": [
        {"id": "pane_term", "kinds": ["terminal", "browser"]},
    ]});
    assert_eq!(
        placement(&identity(one)),
        Some(Placement::Pane { workspace: "ws_a".into(), pane: "pane_term".into() })
    );
}

#[test]
fn a_terminal_beside_a_lone_browser_splits_below_it() {
    let beside = json!({"pane": "pane_web", "placement": "existing_column", "panes": [
        {"id": "pane_web", "kinds": ["browser"]},
    ]});
    assert_eq!(
        placement(&identity(beside)),
        Some(Placement::SplitBelow { workspace: "ws_a".into(), pane: "pane_web".into() })
    );
}

#[test]
fn a_full_column_without_a_terminal_takes_its_lowest_pane() {
    let beside = json!({"pane": "pane_a", "placement": "existing_column", "panes": [
        {"id": "pane_a", "kinds": ["browser"]}, {"id": "pane_b", "kinds": []},
    ]});
    assert_eq!(
        placement(&identity(beside)),
        Some(Placement::Pane { workspace: "ws_a".into(), pane: "pane_b".into() })
    );
}

#[test]
fn a_split_below_stays_in_the_column() {
    let create = json!({"shell": "make dev", "cwd": "/w"}).as_object().cloned().unwrap_or_default();
    let split = split_below_params(&create, "ws_a", "pane_web");
    assert_eq!(split["pane"], "pane_web");
    assert_eq!(split["direction"], "down");
    assert_eq!(split["shell"], "make dev");
    assert!(split.get("viewport_width").is_none());
}

#[test]
fn a_caller_the_app_does_not_find_has_no_placement() {
    let unfound = json!({"caller": {"agent_session": "s", "found": false}, "beside": null});
    assert_eq!(placement(&unfound), None);
    assert_eq!(placement(&json!({"caller": null})), None);
}

#[test]
fn a_split_keeps_the_command_and_a_rename_carries_the_name() {
    let create = json!({"session": "current", "shell": "make dev", "cwd": "/w", "name": "dev",
                            "cols": 80, "rows": 24})
    .as_object()
    .cloned()
    .unwrap_or_default();
    let split = split_params(&create, "ws_a", "pane_chat");
    assert_eq!(split["shell"], "make dev");
    assert_eq!(split["cwd"], "/w");
    assert_eq!(split["pane"], "pane_chat");
    assert_eq!(split["direction"], "right");
    assert_eq!(split["fit"], true);
    assert!(split.get("viewport_width").is_none());
    assert!(split.get("name").is_none());
    let rename = rename_params(&create, "ws_a", &json!({"tab_id": "tab_new"}));
    assert_eq!(rename.as_ref().map(|r| r["tab"].clone()), Some(json!("tab_new")));
    assert_eq!(rename.as_ref().map(|r| r["name"].clone()), Some(json!("dev")));
    assert!(rename_params(&Map::new(), "ws_a", &json!({"tab_id": "tab_new"})).is_none());
}
