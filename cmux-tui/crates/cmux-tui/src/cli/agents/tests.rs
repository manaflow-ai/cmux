use super::*;

#[test]
fn snapshot_keeps_stable_ids_and_selection() {
    let value = compose_snapshot(
        Ok(json!({"workspaces":[{"id":"ws_a"}],"tabs":[{"id":"tab_a"}]})),
        Ok(
            json!({"topology":{"windows":[{"id":"win_a"}],"focus":{"workspace":"ws_a","pane":"pane_a","tab":"tab_a"}}}),
        ),
    );
    assert_eq!(value["windows"][0]["id"], "win_a");
    assert_eq!(value["workspaces"][0]["id"], "ws_a");
    assert_eq!(value["selection"]["tab"], "tab_a");
    assert_eq!(value["sources"]["daemon"]["available"], true);
}

#[test]
fn snapshot_merges_nested_app_page_tabs_without_duplicates() {
    let value = compose_snapshot(
        Ok(json!({
            "workspaces": [{"id":"ws_a"}],
            "tabs":[{"id":"tab_a"}]
        })),
        Ok(json!({
            "topology": {
                "windows": [{
                    "workspaces": [{
                        "id":"ws_a",
                        "tabs": [
                            {"id":"page_settings","kind":"page"},
                            {"id":"tab_a","kind":"terminal"},
                            {"id":"tab_browser","kind":"browser"}
                        ]
                    }, {
                        "id":"ws_other",
                        "tabs": [{"id":"page_other","kind":"page"}]
                    }]
                }]
            }
        })),
    );
    let tabs = value["tabs"].as_array().unwrap();
    assert_eq!(tabs.iter().filter(|tab| tab["id"] == "tab_a").count(), 1);
    assert_eq!(tabs.iter().filter(|tab| tab["id"] == "page_settings").count(), 1);
    assert!(!tabs.iter().any(|tab| tab["id"] == "tab_browser"));
    assert!(!tabs.iter().any(|tab| tab["id"] == "page_other"));
}

#[test]
fn snapshot_retains_owner_failures_for_partial_readiness() {
    let value = compose_snapshot(
        Err(json!({"code":"transport.unavailable"})),
        Ok(json!({"topology":{"windows":[]}})),
    );
    assert_eq!(value["sources"]["daemon"]["available"], false);
    assert_eq!(value["sources"]["app"]["available"], true);
    assert_eq!(value["sources"]["daemon"]["error"]["code"], "transport.unavailable");
}

#[test]
fn agents_snapshot_page_preserves_complete_objects_and_continues() {
    let value = compose_snapshot(
        Ok(json!({"workspaces": [{"id": "ws_a"}, {"id": "ws_b"}]})),
        Ok(json!({"topology": {"windows": [{"workspaces": ["ws_a", "ws_b"]}]}})),
    );
    let first = snapshot_page(value.clone(), 0, 1);
    assert_eq!(first["items"][0]["kind"], "window");
    assert_eq!(first["items"][0]["value"]["workspaces"], json!(["ws_a", "ws_b"]));
    assert_eq!(first["next_offset"], 1);
    let last = snapshot_page(value, 1, 10);
    assert_eq!(last["items"].as_array().unwrap().len(), 2);
    assert_eq!(last["items"][0]["value"]["id"], "ws_a");
    assert_eq!(last["items"][1]["value"]["id"], "ws_b");
    assert_eq!(last["next_offset"], Value::Null);
}

#[test]
fn snapshot_uses_app_workspace_focus_when_both_owners_disagree() {
    let value = compose_snapshot(
        Ok(json!({
            "workspaces": [
                {"id": "ws_a", "focused": true},
                {"id": "ws_b", "focused": false}
            ]
        })),
        Ok(json!({"topology": {"focus": {"workspace": "ws_b"}}})),
    );
    assert_eq!(value["workspaces"][0]["focused"], false);
    assert_eq!(value["workspaces"][1]["focused"], true);
}

#[test]
fn snapshot_falls_back_to_daemon_focus_when_app_has_no_active_resource() {
    let value = compose_snapshot(
        Ok(json!({"focus":{"workspace":"ws_daemon","tab":"tab_daemon"}})),
        Ok(json!({"topology":{"focus":{"workspace":null,"pane":null,"tab":null}}})),
    );
    assert_eq!(value["focus"]["workspace"], "ws_daemon");
    assert_eq!(value["selection"]["tab"], "tab_daemon");
}

#[test]
fn snapshot_falls_back_when_app_focus_is_outside_selected_session() {
    let value = compose_snapshot(
        Ok(json!({
            "workspaces": [{"id":"ws_selected"}],
            "focus": {"workspace":"ws_selected","tab":"tab_selected"}
        })),
        Ok(json!({"topology":{"focus":{"workspace":"ws_remote","tab":"tab_remote"}}})),
    );
    assert_eq!(value["focus"]["workspace"], "ws_selected");
    assert_eq!(value["selection"]["tab"], "tab_selected");
}

#[test]
fn snapshot_falls_back_when_app_focus_has_no_selected_workspace() {
    let value = compose_snapshot(
        Ok(json!({
            "workspaces": [{"id":"ws_selected"}],
            "focus": {"workspace":"ws_selected","pane":"pane_selected"}
        })),
        Ok(json!({
            "topology": {"focus": {"workspace":null,"pane":"pane_remote"}}
        })),
    );
    assert_eq!(value["focus"]["workspace"], "ws_selected");
    assert_eq!(value["focus"]["pane"], "pane_selected");
}

#[test]
fn snapshot_excludes_orphan_app_page_tabs_when_daemon_has_workspaces() {
    let value = compose_snapshot(
        Ok(json!({"workspaces": [{"id":"ws_selected"}]})),
        Ok(json!({
            "topology": {
                "tabs": [{"id":"page_orphan","kind":"page"}],
                "windows": [{"workspaces": [{
                    "id":"ws_selected",
                    "tabs": [{"id":"page_selected","kind":"page"}]
                }]}]
            }
        })),
    );
    let tabs = value["tabs"].as_array().unwrap();
    assert!(tabs.iter().any(|tab| tab["id"] == "page_selected"));
    assert!(!tabs.iter().any(|tab| tab["id"] == "page_orphan"));
}

#[test]
fn snapshot_retains_orphan_app_page_tabs_when_daemon_is_unavailable() {
    let value = compose_snapshot(
        Err(json!({"code":"transport.unavailable"})),
        Ok(json!({
            "topology": {"tabs": [{"id":"page_orphan","kind":"page"}]}
        })),
    );
    assert!(value["tabs"].as_array().unwrap().iter().any(|tab| tab["id"] == "page_orphan"));
}

#[test]
fn aliases_scope_current_targets_before_resource_actions() {
    let AgentCommand::Resource { args, .. } =
        command(&["terminal".into(), "split".into(), "right".into()]).unwrap()
    else {
        panic!("expected resource command")
    };
    assert_eq!(
        args,
        vec!["workspace", "current", "screen", "current", "pane", "current", "split", "--right"]
    );

    let AgentCommand::Resource { args, .. } =
        command(&["tab".into(), "select".into(), "current".into()]).unwrap()
    else {
        panic!("expected resource command")
    };
    assert_eq!(
        args,
        vec![
            "workspace",
            "current",
            "screen",
            "current",
            "pane",
            "current",
            "tab",
            "current",
            "focus"
        ]
    );
}

#[test]
fn aliases_route_qualified_targets_to_their_session() {
    let mut global = GlobalArgs::default();
    let mut args = vec!["tab".into(), "select".into(), "build-box:tab_1a2b".into()];
    normalize_qualified_targets(&mut global, &mut args).unwrap();
    assert_eq!(global.session.as_deref(), Some("build-box"));
    assert_eq!(args[2], "tab_1a2b");

    let mut args = vec![
        "terminal".into(),
        "split".into(),
        "right".into(),
        "--surface".into(),
        "build-box:pane_1a2b".into(),
    ];
    normalize_qualified_targets(&mut global, &mut args).unwrap();
    assert_eq!(args[4], "pane_1a2b");
}

#[test]
fn aliases_map_to_existing_typed_operations() {
    let AgentCommand::Resource { action, args } = command(&[
        "terminal".into(),
        "split".into(),
        "right".into(),
        "--surface".into(),
        "pane_a".into(),
    ])
    .unwrap() else {
        panic!("expected resource command")
    };
    assert_eq!(action, "terminal.split");
    assert_eq!(args, vec!["pane", "pane_a", "split", "--right"]);
}

#[test]
fn dialog_answers_preserve_multiple_selections_and_reject_mixed_modes() {
    let AgentCommand::App { action, args } = command(&[
        "dialog".into(),
        "answer".into(),
        "request_a".into(),
        "--selection".into(),
        "one".into(),
        "--selection".into(),
        "two".into(),
    ])
    .unwrap() else {
        panic!("expected app command")
    };
    assert_eq!(action, "dialog.answer");
    assert_eq!(args, vec!["request_a", "--selection", "one", "--selection", "two"]);
    assert!(
        command(&[
            "dialog".into(),
            "answer".into(),
            "request_a".into(),
            "--mode".into(),
            "permission".into(),
            "--selection".into(),
            "one".into(),
        ])
        .is_ok()
    );
    assert!(
        dialog_answer(&[
            "request_a".into(),
            "--mode".into(),
            "permission".into(),
            "--selection".into(),
            "one".into(),
        ])
        .is_err()
    );
    let (_, params, _) = dialog_answer(&[
        "request_a".into(),
        "--selection".into(),
        "one".into(),
        "--selection".into(),
        "two".into(),
    ])
    .unwrap();
    assert_eq!(params["selections"], json!(["one", "two"]));
}

#[test]
fn snapshot_shows_agent_chat_tabs_the_daemon_lists_as_browsers() {
    // The daemon projects an agent chat tab as a `browser` at about:blank for a connection
    // without `agent-session-tabs-v1`; the app knows it is a chat and of which session.
    let value = compose_snapshot(
        Ok(json!({
            "workspaces": [{"id":"ws_a"}],
            "tabs": [
                {"id":"tab_chat","content_kind":"browser","content_id":"browser_chat","pane_id":"pane_a"},
                {"id":"tab_web","content_kind":"browser","content_id":"browser_web","pane_id":"pane_a"}
            ],
            "browsers": [
                {"id":"browser_chat","tab_id":"tab_chat","url":"about:blank"},
                {"id":"browser_web","tab_id":"tab_web","url":"https://example.com"}
            ]
        })),
        Ok(json!({
            "topology": {
                "windows": [{
                    "workspaces": [{
                        "id":"ws_a",
                        "screens": [{"panes": [{"tabs": [
                            {"id":"tab_chat","kind":"conversation","agent_session":"01a1-chat","url":"about:blank"},
                            {"id":"tab_web","kind":"browser","agent_session":null,"url":"https://example.com"}
                        ]}]}]
                    }]
                }]
            }
        })),
    );
    let tabs = value["tabs"].as_array().unwrap();
    let chat = tabs.iter().find(|tab| tab["id"] == "tab_chat").unwrap();
    assert_eq!(chat["content_kind"], "conversation");
    assert_eq!(chat["agent_session"], "01a1-chat");
    let web = tabs.iter().find(|tab| tab["id"] == "tab_web").unwrap();
    assert_eq!(web["content_kind"], "browser");
    assert!(web.get("agent_session").is_none());
    let browsers = value["browsers"].as_array().unwrap();
    assert_eq!(browsers.len(), 1, "{browsers:?}");
    assert_eq!(browsers[0]["id"], "browser_web");
}
