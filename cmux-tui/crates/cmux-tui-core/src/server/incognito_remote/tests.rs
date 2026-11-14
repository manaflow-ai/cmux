use super::*;

#[test]
fn target_keys_name_objects_and_never_counters() {
    for key in [
        "workspace",
        "workspace_key",
        "destination_workspace",
        "surfaces",
        "tab_resource_id",
        "terminal_id",
        "resource_id",
        "key",
        "target",
        "screens",
    ] {
        assert!(is_target_key(key), "{key}");
    }
    for key in ["workspace_revision", "terminal_revision", "pane_revision", "id", "name", "cols"] {
        assert!(!is_target_key(key), "{key}");
    }
}

#[test]
fn prune_drops_nested_rows_and_ids_rows() {
    let hidden = Hidden {
        numbers: HashSet::from([7]),
        names: HashSet::from(["ws_hidden".to_string()]),
        ..Hidden::default()
    };
    let mut reply = json!({
        "ids": [{"kind": "workspace", "id": 7, "short_id": "a"},
                {"kind": "workspace", "id": 8, "short_id": "b"}],
        "clients": [{"client": 7, "attached": [{"surface": 7}, {"surface": 9}]}],
        "workspace_revision": 7,
    });
    hidden.prune_reply(&mut reply);
    assert_eq!(
        reply,
        json!({
            "ids": [{"kind": "workspace", "id": 8, "short_id": "b"}],
            "clients": [{"client": 7, "attached": [{"surface": 9}]}],
            "workspace_revision": 7,
        })
    );
}

#[test]
fn selectors_that_could_resolve_to_a_hidden_workspace_are_refused() {
    let hidden = Hidden { labels: HashSet::from(["private".to_string()]), ..Hidden::default() };
    for request in [
        json!({"cmd": "x", "workspace": "current"}),
        json!({"params": {"destination_workspace": "name:anything"}}),
        json!({"cmd": "x", "workspace": "private"}),
    ] {
        assert!(hidden.named_in_request(&request).is_some(), "{request}");
    }
    assert!(hidden.named_in_request(&json!({"cmd": "x", "workspace": 3})).is_none());
}

#[test]
fn keyboard_input_is_never_a_workspace_name() {
    let hidden = Hidden { labels: HashSet::from(["enter".to_string()]), ..Hidden::default() };
    for request in [
        json!({"cmd": "send-key", "surface": 3, "keys": ["enter"]}),
        json!({"cmd": "send-key", "surface": 3, "key": "enter"}),
        json!({"cmd": "send-key", "surface": 3, "keys": ["current"]}),
    ] {
        assert!(hidden.named_in_request(&request).is_none(), "{request}");
    }
    assert!(hidden.named_in_request(&json!({"cmd": "x", "workspace": "enter"})).is_some());
}

#[test]
fn the_request_id_is_never_a_target() {
    assert!(!Hidden::names_a_target(&json!({"id": {"pane": 4}, "cmd": "new-tab"})));
    assert!(!Hidden::names_a_target(&json!({"id": 1, "cmd": "new-tab", "pane": false})));
    assert!(Hidden::names_a_target(&json!({"id": 1, "cmd": "new-tab", "pane": 4})));
    assert!(Hidden::names_a_target(&json!({"id": 1, "cmd": "set-split-ratio", "split": 9})));
}

#[test]
fn groups_and_splits_of_a_hidden_workspace_are_refused() {
    let hidden = Hidden {
        numbers: HashSet::from([5]),
        splits: HashSet::from([9]),
        names: HashSet::from(["tg_hidden".to_string()]),
        ..Hidden::default()
    };
    for request in [
        json!({"cmd": "close-tab-group", "group": "tg_hidden", "end_terminals": true}),
        json!({"cmd": "set-split-ratio", "split": 9, "ratio": 0.5}),
    ] {
        assert!(hidden.named_in_request(&request).is_some(), "{request}");
    }
    // A split id is its own id space: pane 9 is not split 9.
    assert!(hidden.named_in_request(&json!({"cmd": "focus-pane", "pane": 9})).is_none());
    assert!(hidden.named_in_request(&json!({"cmd": "set-split-ratio", "split": 5})).is_none());
}

#[test]
fn row_and_column_fields_name_splits_but_terminal_sizes_do_not() {
    let hidden = Hidden { splits: HashSet::from([9]), ..Hidden::default() };
    for request in [
        json!({"cmd": "set-row-heights", "column": 9, "heights": []}),
        json!({"cmd": "set-row-heights", "column": 4, "heights": [{"row": 9, "height": 1}]}),
        json!({"cmd": "move-tab", "surface": 3, "after_column": 9}),
    ] {
        assert!(hidden.named_in_request(&request).is_some(), "{request}");
    }
    assert!(hidden.named_in_request(&json!({"cmd": "resize", "rows": 9, "cols": 9})).is_none());
    assert!(!is_target_key("rows") && !is_target_key("top_row"));
}

#[test]
fn saved_groups_of_a_hidden_workspace_are_left_out_and_refused() {
    let hidden =
        Hidden { saved: HashSet::from(["ssaved_hidden".to_string()]), ..Hidden::default() };
    let mut reply = json!({"groups": [
        {"id": "ssaved_hidden", "name": "secret"},
        {"id": "ssaved_other", "name": "shown"},
    ]});
    hidden.prune_reply(&mut reply);
    assert_eq!(reply, json!({"groups": [{"id": "ssaved_other", "name": "shown"}]}));
    let request = json!({"cmd": "reopen-saved-screen-group", "saved": "ssaved_hidden"});
    assert_eq!(hidden.saved_in(&request), Some("ssaved_hidden"));
    assert!(hidden.saved_in(&json!({"saved": "ssaved_other"})).is_none());
    let failing_closed = Hidden { all: true, ..Hidden::default() };
    assert!(failing_closed.mentions_saved(&json!({"saved": "saved_x"})));
}

#[test]
fn sidebar_items_and_ungrouped_rows_of_a_hidden_workspace_are_left_out() {
    let hidden = Hidden { names: HashSet::from(["ws_hidden".to_string()]), ..Hidden::default() };
    let mut reply = json!({"ok": true, "result": {"value": {
        "sections": [{"id": "sec_pinned", "items": [
            {"id": "i1", "ref": {"kind": "workspace", "value": "main:ws_hidden"}},
            {"id": "i2", "ref": {"kind": "workspace", "value": "ws_shown"}},
        ]}],
        "ungrouped": [{"workspace": {"workspace_id": "ws_hidden"}},
                      {"workspace": {"workspace_id": "ws_shown"}}],
    }}});
    hidden.prune_reply(&mut reply);
    let text = reply.to_string();
    assert!(!text.contains("ws_hidden"), "{text}");
    assert_eq!(text.matches("ws_shown").count(), 2, "{text}");
}

#[test]
fn a_clients_attached_surfaces_of_a_hidden_workspace_are_left_out() {
    let hidden = Hidden { numbers: HashSet::from([7]), ..Hidden::default() };
    let mut reply = json!({"clients": [{"client": 3, "attached": [7, 9], "sizes": []}]});
    hidden.prune_reply(&mut reply);
    assert_eq!(reply, json!({"clients": [{"client": 3, "attached": [9], "sizes": []}]}));
}

#[test]
fn a_sidebar_ref_to_a_hidden_workspace_is_refused() {
    let hidden = Hidden { names: HashSet::from(["ws_hidden".to_string()]), ..Hidden::default() };
    let request = json!({"protocol": "cmux.protocol/2", "params": {"op": {"kind": "item.add",
            "item": {"id": "it_1", "ref": {"kind": "workspace", "value": "main:ws_hidden"}}}}});
    assert_eq!(hidden.named_in_request(&request).map(|(kind, _)| kind), Some("workspace"));
    let shown =
        json!({"params": {"op": {"item": {"ref": {"kind": "workspace", "value": "ws_x"}}}}});
    assert!(hidden.named_in_request(&shown).is_none());
}

#[test]
fn window_title_commands_never_act_on_the_current_workspace() {
    for command in ["set-window-title", "clear-window-title"] {
        assert!(NO_CURRENT_TARGET.contains(&command), "{command}");
    }
}

#[test]
fn a_hidden_event_teaches_its_entity_ids_but_never_its_sidebar_group() {
    let mut hidden = Hidden::default();
    hidden.learn(
        &json!({"event": "workspace-added", "workspace": 3, "entity": {
                "id": 3, "resource_id": "ws_x", "key": "k", "group": "grp_shared",
                "screens": [{"id": 4, "panes": [{"id": 5, "tabs": [{"surface": 6}]}]}]}}),
        false,
    );
    for number in [3, 4, 5, 6] {
        assert!(hidden.numbers.contains(&number), "{number}");
    }
    assert!(hidden.names.contains("ws_x") && hidden.names.contains("k"));
    assert!(!hidden.names.contains("grp_shared"));
    assert!(!hidden.hides_event(&json!({"event": "workspace-changed", "group": "grp_shared"})));
    assert!(hidden.hides_event(&json!({"event": "title-changed", "surface": 6})));
}
