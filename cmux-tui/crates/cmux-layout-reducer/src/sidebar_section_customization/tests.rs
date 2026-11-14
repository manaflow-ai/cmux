use super::*;
use serde_json::json;

#[test]
fn plans_visibility_order_and_valid_group_moves() {
    let request: Request = serde_json::from_value(json!({
            "sections": {"hidden": ["recents"], "order": ["projects", "pinned"]},
            "workspaces": {"ws_1": {"hidden": true}, "ws_2": {"group": "g", "order": 4}},
            "selected": "ws_1",
            "input": [
                {"id": "sec_pinned", "keys": ["pinned"], "region": "top", "nodes": []},
                {"id": "projects", "keys": ["projects"], "region": "middle", "nodes": [{"id": "ws_1", "kind": "workspace", "workspace_ids": ["ws_1"]}, {"id": "g", "kind": "group", "workspace_ids": []}, {"id": "ws_2", "kind": "workspace", "workspace_ids": ["ws_2"]}]},
                {"id": "recents", "keys": ["recents"], "region": "bottom", "nodes": []}
            ]
        })).unwrap();
    let reply = respond(&request);
    assert_eq!(reply.hidden_sections, ["recents"]);
    assert!(reply.hidden_workspaces.is_empty());
    assert_eq!(reply.workspace_groups["ws_2"], "g");
    assert_eq!(reply.section_order, ["sec_pinned", "projects", "recents"]);
}

#[test]
fn unknown_group_preserves_document_placement_and_invalid_values_are_diagnosed() {
    let request: Request = serde_json::from_value(json!({
            "sections": {"hidden": [5], "order": "bad"},
            "workspaces": {"ws": {"group": "missing", "order": -1}},
            "input": [{"id": "projects", "keys": ["projects"], "region": "middle", "nodes": [{"id": "ws", "kind": "workspace", "workspace_ids": ["ws"]}]}]
        })).unwrap();
    let reply = respond(&request);
    assert!(reply.workspace_groups.is_empty());
    assert!(reply.problems.len() >= 4);
}

#[test]
fn exact_group_id_wins_and_an_existing_membership_is_a_noop() {
    let request: Request = serde_json::from_value(json!({
        "workspaces": {"ws": {"group": "same"}},
        "input": [{"id": "projects", "region": "middle", "nodes": [
            {"id": "same", "kind": "group", "name": "Other", "workspace_ids": ["ws"]},
            {"id": "other", "kind": "group", "name": "same", "workspace_ids": []}
        ]}]
    }))
    .unwrap();
    let reply = respond(&request);
    assert!(reply.problems.is_empty());
    assert!(reply.workspace_groups.is_empty());

    let display_name_request: Request = serde_json::from_value(json!({
        "workspaces": {"ws": {"group": "same"}},
        "input": [{"id": "projects", "region": "middle", "nodes": [
            {"id": "first", "kind": "group", "name": "same", "workspace_ids": []},
            {"id": "second", "kind": "group", "name": "same", "workspace_ids": []},
            {"id": "ws", "kind": "workspace", "workspace_ids": ["ws"]}
        ]}]
    }))
    .unwrap();
    let reply = respond(&display_name_request);
    assert!(reply.workspace_groups.is_empty());
    assert_eq!(reply.problems.len(), 1);
}

#[test]
fn oversized_document_keeps_the_projection_unchanged() {
    let nodes = (0..257)
            .map(|index| json!({"id": format!("ws-{index}"), "kind": "workspace", "workspace_ids": [format!("ws-{index}")]}))
            .collect::<Vec<_>>();
    let request: Request = serde_json::from_value(json!({
        "sections": {"hidden": ["projects"]},
        "input": [{"id": "projects", "region": "middle", "nodes": nodes}]
    }))
    .unwrap();
    let reply = respond(&request);
    assert!(reply.hidden_sections.is_empty());
    assert!(reply.hidden_workspaces.is_empty());
    assert_eq!(reply.section_order, Vec::<String>::new());
    assert_eq!(reply.problems.len(), 1);
}

#[test]
fn duplicate_and_unknown_ids_are_diagnosed_without_changing_safe_fallbacks() {
    let request: Request = serde_json::from_value(json!({
        "sections": {"hidden": ["projects", "projects", "missing"], "order": ["missing"]},
        "workspaces": {"unknown": {"hidden": true}},
        "input": [{"id": "projects", "keys": ["projects"], "region": "middle", "nodes": [
            {"id": "ws", "kind": "workspace", "workspace_ids": ["ws", "ws"]}
        ]}]
    }))
    .unwrap();
    let reply = respond(&request);
    assert_eq!(reply.hidden_sections, ["projects"]);
    assert!(reply.hidden_workspaces.is_empty());
    assert!(reply.problems.iter().any(|problem| problem.path == "sidebar.sections.hidden[1]"));
    assert!(reply.problems.iter().any(|problem| problem.path == "sidebar.sections.hidden[1]"));
    assert!(reply.problems.iter().any(|problem| problem.path == "sidebar.sections.order[0]"));
    assert!(reply.problems.iter().any(|problem| problem.path == "sidebar.workspaces.unknown"));
    assert!(reply.problems.iter().any(|problem| problem.path.ends_with("workspace_ids[1]")));
}
