use super::*;
use serde_json::json;
use std::time::Instant;

fn request(value: Value) -> Request {
    serde_json::from_value(value).unwrap()
}

#[test]
fn plans_visibility_order_and_valid_group_moves() {
    let reply = respond(&request(json!({
        "sections": {"hidden": ["recents"], "order": ["projects", "pinned"]},
        "workspaces": {"ws_1": {"hidden": true}, "ws_2": {"group": "g", "order": 4}},
        "selected": "ws_1",
        "input": [
            {"id": "sec_pinned", "keys": ["pinned"], "region": "top", "nodes": []},
            {"id": "projects", "keys": ["projects"], "region": "middle", "nodes": [{"id": "ws_1", "kind": "workspace", "workspace_ids": ["ws_1"]}, {"id": "g", "kind": "group", "workspace_ids": []}, {"id": "ws_2", "kind": "workspace", "workspace_ids": ["ws_2"]}]},
            {"id": "recents", "keys": ["recents"], "region": "bottom", "nodes": []}
        ]
    })));
    assert_eq!(reply.hidden_sections, ["recents"]);
    assert!(reply.hidden_workspaces.is_empty());
    assert!(reply.selection_overrides_hide);
    assert_eq!(reply.workspace_groups["ws_2"], "g");
    assert_eq!(reply.section_order, ["sec_pinned", "projects", "recents"]);
    assert!(reply.complete);
}

#[test]
fn unknown_group_preserves_document_placement_and_invalid_values_are_diagnosed() {
    let reply = respond(&request(json!({
        "sections": {"hidden": [5], "order": "bad"},
        "workspaces": {"ws": {"group": "missing", "order": -1}},
        "input": [{"id": "projects", "keys": ["projects"], "region": "middle", "nodes": [{"id": "ws", "kind": "workspace", "workspace_ids": ["ws"]}]}]
    })));
    assert!(reply.workspace_groups.is_empty());
    assert!(reply.problems.len() >= 4);
    assert!(!reply.complete, "a malformed value marks the settings incomplete");
}

#[test]
fn exact_group_id_wins_and_an_existing_membership_is_a_noop() {
    let reply = respond(&request(json!({
        "workspaces": {"ws": {"group": "same"}},
        "input": [{"id": "projects", "region": "middle", "nodes": [
            {"id": "same", "kind": "group", "name": "Other", "workspace_ids": ["ws"]},
            {"id": "other", "kind": "group", "name": "same", "workspace_ids": []}
        ]}]
    })));
    assert!(reply.problems.is_empty());
    assert!(reply.workspace_groups.is_empty());

    let reply = respond(&request(json!({
        "workspaces": {"ws": {"group": "same"}},
        "input": [{"id": "projects", "region": "middle", "nodes": [
            {"id": "first", "kind": "group", "name": "same", "workspace_ids": []},
            {"id": "second", "kind": "group", "name": "same", "workspace_ids": []},
            {"id": "ws", "kind": "workspace", "workspace_ids": ["ws"]}
        ]}]
    })));
    assert!(reply.workspace_groups.is_empty());
    assert_eq!(reply.problems.len(), 1);
}

/// Regression: the full-document input used to switch every customization
/// off once one section listed more than 256 rows, so a large sidebar
/// silently showed everything it was told to hide.
#[test]
fn a_section_with_thousands_of_rows_still_applies_its_hides() {
    let nodes = (0..3_000)
        .map(|index| json!({"id": format!("ws-{index}"), "kind": "workspace", "workspace_ids": [format!("ws-{index}")]}))
        .collect::<Vec<_>>();
    let reply = respond(&request(json!({
        "sections": {"hidden": ["recents"]},
        "workspaces": {"ws-2999": {"hidden": true}},
        "input": [
            {"id": "projects", "region": "middle", "nodes": nodes},
            {"id": "recents", "region": "bottom", "nodes": []}
        ]
    })));
    assert_eq!(reply.hidden_sections, ["recents"]);
    assert_eq!(reply.hidden_workspaces, ["ws-2999"]);
    assert!(reply.problems.is_empty(), "{:?}", reply.problems);
}

#[test]
fn an_oversized_outline_keeps_the_projection_unchanged() {
    let outline = (0..257)
        .map(|index| json!({"id": format!("sec-{index}"), "region": "middle"}))
        .collect::<Vec<_>>();
    let reply = respond(&request(json!({
        "sections": {"hidden": ["sec-1"]},
        "outline": outline
    })));
    assert!(reply.hidden_sections.is_empty());
    assert!(reply.section_order.is_empty());
    assert_eq!(reply.problems.len(), 1);
}

#[test]
fn duplicate_and_unknown_ids_are_diagnosed_without_changing_safe_fallbacks() {
    let reply = respond(&request(json!({
        "sections": {"hidden": ["projects", "projects", "missing"], "order": ["missing"]},
        "workspaces": {"unknown": {"hidden": true}},
        "input": [{"id": "projects", "keys": ["projects"], "region": "middle", "nodes": [
            {"id": "ws", "kind": "workspace", "workspace_ids": ["ws", "ws"]}
        ]}]
    })));
    assert_eq!(reply.hidden_sections, ["projects"]);
    assert!(reply.hidden_workspaces.is_empty());
    for path in
        ["sidebar.sections.hidden[1]", "sidebar.sections.order[0]", "sidebar.workspaces.unknown"]
    {
        assert!(reply.problems.iter().any(|problem| problem.path == path), "{path}");
    }
    assert!(reply.problems.iter().any(|problem| problem.path.ends_with("workspace_ids[1]")));
}

fn outline_request(rows: usize, settings: Value) -> Value {
    // What the native caller sends: sections and groups, plus only the
    // workspaces the settings name. `rows` never reaches the request.
    let _ = rows;
    json!({
        "sections": settings["sections"],
        "workspaces": settings["workspaces"],
        "selected": "ws-0",
        "outline": [
            {"id": "sec_pinned", "keys": ["pinned"], "region": "top"},
            {"id": "sec_m_local", "keys": ["projects", "local"], "region": "middle", "groups": [{"id": "grp", "name": "Work"}]},
            {"id": "recents", "keys": ["recents"], "region": "bottom"}
        ],
        "locations": {
            "ws-0": {"section": "sec_m_local"},
            "ws-7": {"section": "sec_m_local", "group": "grp"},
            "ws-9": {"section": "sec_m_local"}
        }
    })
}

fn settings() -> Value {
    json!({
        "sections": {"hidden": ["recents"], "order": ["projects"]},
        "workspaces": {"ws-7": {"hidden": true}, "ws-9": {"group": "Work", "order": 2}}
    })
}

#[test]
fn outline_and_legacy_input_plan_the_same_rows() {
    let outline = respond(&request(outline_request(30, settings())));
    let nodes = (0..30)
        .filter(|index| *index != 7)
        .map(|index| json!({"id": format!("ws-{index}"), "kind": "workspace", "workspace_ids": [format!("ws-{index}")]}))
        .chain([json!({"id": "grp", "kind": "group", "name": "Work", "workspace_ids": ["ws-7"]})])
        .collect::<Vec<_>>();
    let legacy = respond(&request(json!({
        "sections": settings()["sections"],
        "workspaces": settings()["workspaces"],
        "selected": "ws-0",
        "input": [
            {"id": "sec_pinned", "keys": ["pinned"], "region": "top", "nodes": []},
            {"id": "sec_m_local", "keys": ["projects", "local"], "region": "middle", "nodes": nodes},
            {"id": "recents", "keys": ["recents"], "region": "bottom", "nodes": []}
        ]
    })));
    assert_eq!(outline.revision, legacy.revision);
    assert_eq!(outline.hidden_workspaces, ["ws-7"]);
    assert_eq!(outline.workspace_groups["ws-9"], "grp");
    assert_eq!(outline.workspace_orders["ws-9"], 2);
    assert_eq!(outline.hidden_sections, ["recents"]);
    assert_eq!(
        outline.restorable,
        [
            Restorable { kind: "section", id: "recents".into(), key: "recents".into() },
            Restorable { kind: "workspace", id: "ws-7".into(), key: "ws-7".into() },
        ]
    );
}

#[test]
fn the_selected_workspace_is_never_hidden_and_stays_restorable() {
    let mut value = outline_request(30, settings());
    value["selected"] = json!("ws-7");
    let reply = respond(&request(value));
    assert!(reply.hidden_workspaces.is_empty());
    assert!(reply.selection_overrides_hide);
    assert!(reply.restorable.iter().any(|entry| entry.id == "ws-7"));

    // A selected row inside a hidden section keeps that section drawn.
    let mut value = outline_request(30, json!({"sections": {"hidden": ["projects"]}}));
    value["selected"] = json!("ws-9");
    let reply = respond(&request(value));
    assert!(reply.hidden_sections.is_empty());
    assert!(reply.selection_overrides_hide);
}

#[test]
fn section_order_never_crosses_a_region_and_is_stable_for_unranked_sections() {
    let reply = respond(&request(json!({
        "sections": {"order": ["c", "recents", "a"]},
        "outline": [
            {"id": "pinned", "region": "top"},
            {"id": "a", "region": "middle"},
            {"id": "b", "region": "middle"},
            {"id": "c", "region": "middle"},
            {"id": "recents", "region": "bottom"}
        ]
    })));
    assert_eq!(reply.section_order, ["pinned", "c", "a", "b", "recents"]);
}

#[test]
fn equal_plans_share_a_revision_and_changed_plans_do_not() {
    let first = respond(&request(outline_request(30, settings())));
    let again = respond(&request(outline_request(3_000, settings())));
    assert_eq!(first.revision, again.revision);
    let other =
        respond(&request(outline_request(30, json!({"sections": {"hidden": ["recents"]}}))));
    assert_ne!(first.revision, other.revision);
}

fn edit_reply(sections: Value, workspaces: Value, edit: Value) -> EditReply {
    super::edit(
        &serde_json::from_value(
            json!({"sections": sections, "workspaces": workspaces, "edit": edit}),
        )
        .unwrap(),
    )
}

#[test]
fn show_and_hide_edits_round_trip_and_keep_unrelated_keys() {
    let hidden = edit_reply(
        json!({"order": ["projects"]}),
        Value::Null,
        json!({"op": "hide_section", "id": "recents"}),
    );
    assert_eq!(hidden.sections, json!({"order": ["projects"], "hidden": ["recents"]}));
    let shown =
        edit_reply(hidden.sections, Value::Null, json!({"op": "show_section", "id": "recents"}));
    assert_eq!(shown.sections, json!({"order": ["projects"]}));
    assert!(shown.changed);

    let hidden = edit_reply(
        Value::Null,
        json!({"ws": {"order": 3}}),
        json!({"op": "hide_workspace", "id": "ws"}),
    );
    assert_eq!(hidden.workspaces, json!({"ws": {"order": 3, "hidden": true}}));
    let shown =
        edit_reply(Value::Null, hidden.workspaces, json!({"op": "show_workspace", "id": "ws"}));
    assert_eq!(shown.workspaces, json!({"ws": {"order": 3}}));

    // Showing the only override removes the entry, then the key.
    let shown = edit_reply(
        Value::Null,
        json!({"ws": {"hidden": true}}),
        json!({"op": "show_workspace", "id": "ws"}),
    );
    assert_eq!(shown.workspaces, Value::Null);
}

#[test]
fn show_all_clears_hides_and_reset_clears_every_projection_override() {
    let sections = json!({"hidden": ["recents"], "order": ["projects"], "look": "quiet"});
    let workspaces = json!({"a": {"hidden": true}, "b": {"hidden": true, "group": "g"}});
    let all = edit_reply(sections.clone(), workspaces.clone(), json!({"op": "show_all"}));
    assert_eq!(all.sections, json!({"order": ["projects"], "look": "quiet"}));
    assert_eq!(all.workspaces, json!({"b": {"group": "g"}}));

    let reset = edit_reply(sections, workspaces, json!({"op": "reset"}));
    assert_eq!(reset.sections, json!({"look": "quiet"}));
    assert_eq!(reset.workspaces, Value::Null);

    let noop = edit_reply(Value::Null, Value::Null, json!({"op": "reset"}));
    assert!(!noop.changed);
}

#[test]
fn edits_refuse_bad_ids_and_repair_a_malformed_entry() {
    let refused = edit_reply(Value::Null, Value::Null, json!({"op": "hide_workspace", "id": ""}));
    assert!(refused.refused.is_some());
    assert!(!refused.changed);
    let repaired =
        edit_reply(Value::Null, json!({"ws": 5}), json!({"op": "hide_workspace", "id": "ws"}));
    assert_eq!(repaired.workspaces, json!({"ws": {"hidden": true}}));
}

/// Every hide an edit makes is undone by Show for the same id, and the
/// projection of the result hides nothing (property over a small id space).
#[test]
fn every_hide_has_a_show_that_restores_the_projection() {
    let ids = ["recents", "pinned", "projects"];
    for id in ids {
        let hidden = edit_reply(Value::Null, Value::Null, json!({"op": "hide_section", "id": id}));
        let plan = respond(&request(json!({
            "sections": hidden.sections,
            "outline": [
                {"id": "sec_pinned", "keys": ["pinned"], "region": "top"},
                {"id": "projects", "region": "middle"},
                {"id": "recents", "region": "bottom"}
            ]
        })));
        assert_eq!(plan.hidden_sections.len(), 1, "{id}");
        let entry = &plan.restorable[0];
        let shown = edit_reply(
            hidden.sections,
            Value::Null,
            json!({"op": "show_section", "id": entry.key}),
        );
        assert_eq!(shown.sections, Value::Null, "{id}");
    }
}

/// The perf harness for CMUX-383 slice 2: the request the native caller
/// builds, and the plan, at 30 and 3,000 rows. Run with `--nocapture` for the
/// numbers; the assertions hold the constant-size invariant.
#[test]
fn planning_cost_is_constant_from_30_to_3000_rows() {
    fn legacy(rows: usize) -> Value {
        let nodes = (0..rows)
            .map(|index| json!({"id": format!("ws-{index}"), "kind": "workspace", "workspace_ids": [format!("ws-{index}")]}))
            .collect::<Vec<_>>();
        json!({
            "sections": settings()["sections"],
            "workspaces": settings()["workspaces"],
            "selected": "ws-0",
            "input": [
                {"id": "sec_pinned", "keys": ["pinned"], "region": "top", "nodes": []},
                {"id": "sec_m_local", "keys": ["projects"], "region": "middle", "nodes": nodes},
                {"id": "recents", "keys": ["recents"], "region": "bottom", "nodes": []}
            ]
        })
    }
    fn measure(value: &Value) -> (usize, f64) {
        let bytes = serde_json::to_vec(value).unwrap();
        let rounds = 200;
        let start = Instant::now();
        for _ in 0..rounds {
            let request: Request = serde_json::from_slice(&bytes).unwrap();
            let reply = respond(&request);
            std::hint::black_box(serde_json::to_vec(&reply).unwrap());
        }
        (bytes.len(), start.elapsed().as_secs_f64() * 1e6 / f64::from(rounds))
    }
    let (small_bytes, small_us) = measure(&outline_request(30, settings()));
    let (large_bytes, large_us) = measure(&outline_request(3_000, settings()));
    let (legacy_small_bytes, legacy_small_us) = measure(&legacy(30));
    let (legacy_large_bytes, legacy_large_us) = measure(&legacy(3_000));
    println!(
        "sidebar_projection_perf outline: 30 rows {small_bytes} B {small_us:.1} us, 3000 rows {large_bytes} B {large_us:.1} us; \
         legacy input: 30 rows {legacy_small_bytes} B {legacy_small_us:.1} us, 3000 rows {legacy_large_bytes} B {legacy_large_us:.1} us"
    );
    assert_eq!(small_bytes, large_bytes, "the request must not grow with rows");
    assert!(legacy_large_bytes > 50 * legacy_small_bytes / 10, "the legacy shape grows with rows");
}
