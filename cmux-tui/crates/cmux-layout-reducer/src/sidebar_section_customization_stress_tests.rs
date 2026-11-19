//! Stress for the sidebar settings overlay (`sidebar.sections` and
//! `sidebar.workspaces` in cmux-next.json) at the sizes a heavy user reaches:
//! 50+ sections and 500 to 20,000 workspaces. Two promises: hide, order and
//! group settings keep working at every size the document allows, and the
//! planner's cost per workspace stays flat as the sidebar grows.
//!
//! Run the table with
//! `cargo test -p cmux-layout-reducer --release sidebar_customization_stress -- --nocapture`.

use super::*;
use crate::sidebar_doc::model::{MAX_ITEMS, MAX_SECTIONS};
use serde_json::json;
use std::time::Instant;

/// `sections` sections in three regions; `workspaces` spread over them, every
/// tenth one in a group named after its section.
fn sidebar(sections: usize, workspaces: usize) -> Vec<SectionInput> {
    let per = workspaces.div_ceil(sections);
    (0..sections)
        .map(|s| {
            let region = ["top", "middle", "bottom"][s * 3 / sections];
            let ids: Vec<String> =
                (s * per..((s + 1) * per).min(workspaces)).map(|w| format!("ws_{w}")).collect();
            let (grouped, loose) = ids.split_at(ids.len() / 10);
            let mut nodes = vec![NodeInput {
                id: format!("grp_{s}"),
                kind: "group".into(),
                workspace_ids: grouped.to_vec(),
                name: Some(format!("Group {s}")),
            }];
            nodes.extend(loose.iter().map(|id| NodeInput {
                id: id.clone(),
                kind: "workspace".into(),
                workspace_ids: vec![id.clone()],
                name: None,
            }));
            SectionInput {
                id: format!("sec_{s}"),
                keys: vec![format!("key_{s}")],
                region: region.into(),
                nodes,
            }
        })
        .collect()
}

/// A settings file a user could write at this size: two hidden sections, a
/// reversed section order, and 100 workspace rules (hide, regroup, order).
fn request(sections: usize, workspaces: usize) -> Request {
    let order: Vec<String> = (0..sections).rev().map(|s| format!("key_{s}")).collect();
    let mut rules = serde_json::Map::new();
    let per = workspaces.div_ceil(sections);
    for i in 0..100.min(workspaces) {
        let w = (i * 7919) % workspaces;
        let rule = match i % 3 {
            0 => json!({"hidden": true}),
            1 => json!({"group": format!("Group {}", w / per)}),
            _ => json!({"order": i}),
        };
        rules.insert(format!("ws_{w}"), rule);
    }
    Request {
        sections: json!({"hidden": ["key_0", "key_1"], "order": order}),
        workspaces: Value::Object(rules),
        input: sidebar(sections, workspaces),
        // The selected workspace's section is never hidden; select one in the last.
        selected: Some(format!("ws_{}", workspaces - 1)),
    }
}

fn percentiles(request: &Request, runs: usize) -> (u128, u128) {
    let mut samples: Vec<u128> = (0..runs)
        .map(|_| {
            let start = Instant::now();
            std::hint::black_box(respond(std::hint::black_box(request)));
            start.elapsed().as_nanos()
        })
        .collect();
    samples.sort_unstable();
    (samples[runs / 2], samples[runs * 95 / 100])
}

#[test]
fn settings_still_apply_with_500_workspaces_in_one_section() {
    // One "Projects" section with 500 loose workspaces: the shape of a long
    // flat sidebar. The old 256-per-level cap dropped every setting here.
    let request: Request = serde_json::from_value(json!({
        "sections": {"hidden": [], "order": ["recents", "projects"]},
        "workspaces": {"ws_499": {"hidden": true}, "ws_10": {"group": "Pinned work"}},
        "input": [
            {"id": "projects", "keys": ["projects"], "region": "middle", "nodes":
                std::iter::once(json!({"id": "g", "kind": "group", "name": "Pinned work", "workspace_ids": []}))
                    .chain((0..500).map(|w| json!({"id": format!("ws_{w}"), "kind": "workspace", "workspace_ids": [format!("ws_{w}")]})))
                    .collect::<Vec<_>>()},
            {"id": "recents", "keys": ["recents"], "region": "middle", "nodes": []}
        ]
    }))
    .unwrap();
    let reply = respond(&request);
    assert_eq!(reply.hidden_workspaces, ["ws_499"], "{:?}", reply.problems);
    assert_eq!(reply.workspace_groups["ws_10"], "g");
    assert_eq!(reply.section_order, ["recents", "projects"]);
    assert!(reply.problems.is_empty(), "{:?}", reply.problems);
}

#[test]
fn settings_still_apply_with_a_300_workspace_group_and_300_rules() {
    let rules: serde_json::Map<String, Value> =
        (0..300).map(|w| (format!("ws_{w}"), json!({"order": w}))).collect();
    let request: Request = serde_json::from_value(json!({
        "sections": {"hidden": []},
        "workspaces": rules,
        "input": [{"id": "projects", "region": "middle", "nodes": [
            {"id": "big", "kind": "group", "name": "Big", "workspace_ids": (0..300).map(|w| format!("ws_{w}")).collect::<Vec<_>>()}
        ]}]
    }))
    .unwrap();
    let reply = respond(&request);
    assert_eq!(reply.workspace_orders.len(), 300, "{:?}", reply.problems);
    assert!(reply.problems.is_empty(), "{:?}", reply.problems);
}

#[test]
fn a_document_past_the_model_limits_is_still_refused() {
    // The bound moves to the document's own limits; it does not go away.
    let request = Request {
        sections: json!({"hidden": ["key_0"]}),
        workspaces: json!({}),
        input: vec![SectionInput {
            id: "sec_0".into(),
            keys: vec!["key_0".into()],
            region: "middle".into(),
            nodes: vec![NodeInput {
                id: "grp".into(),
                kind: "group".into(),
                workspace_ids: (0..=MAX_ITEMS).map(|w| format!("ws_{w}")).collect(),
                name: None,
            }],
        }],
        selected: None,
    };
    let reply = respond(&request);
    assert!(reply.hidden_sections.is_empty());
    assert!(reply.problems.iter().any(|problem| problem.path == "sidebar.input"));
}

#[test]
fn sidebar_customization_stress() {
    // 1x is a typical sidebar; the rest are the sizes Leo asked to break it at
    // (50+ sections, 500 workspaces) and the document's own ceiling.
    let sizes = [(8, 50), (50, 500), (MAX_SECTIONS, 5_000), (MAX_SECTIONS, MAX_ITEMS)];
    let mut per_workspace = Vec::new();
    println!("sections | workspaces | p50 us | p95 us | p50 ns/workspace | hidden | regrouped");
    for (sections, workspaces) in sizes {
        let request = request(sections, workspaces);
        let reply = respond(&request);
        // Every size honours the settings: two hidden sections, the reversed
        // order, and the workspace rules outside them.
        assert_eq!(
            reply.hidden_sections,
            ["sec_0", "sec_1"],
            "{sections}x{workspaces}: {:?}",
            &reply.problems[..reply.problems.len().min(3)]
        );
        assert_eq!(reply.section_order.len(), sections);
        assert!(!reply.hidden_workspaces.is_empty() || workspaces < 100);
        let runs = if workspaces > 5_000 { 40 } else { 200 };
        let (p50, p95) = percentiles(&request, runs);
        let ns = p50 / workspaces as u128;
        per_workspace.push(ns);
        println!(
            "{sections} | {workspaces} | {} | {} | {ns} | {} | {}",
            p50 / 1_000,
            p95 / 1_000,
            reply.hidden_workspaces.len(),
            reply.workspace_groups.len()
        );
    }
    // Constant cost per workspace: the planner is one pass with map lookups,
    // so 400x more workspaces may cost at most 4x more per workspace (the
    // BTreeMap log factor and cache misses), never a quadratic walk.
    let base = per_workspace[0].max(50);
    for (ns, (sections, workspaces)) in per_workspace.iter().zip(sizes) {
        assert!(*ns <= base * 4, "{sections}x{workspaces}: {ns} ns per workspace vs {base} at 1x");
    }
}

use crate::sidebar_row_layout::MAX_QUOTED;

#[test]
fn a_huge_or_unicode_workspace_key_is_quoted_short() {
    // A hand-edited file with one pasted blob as a workspace key: the problem says where, without
    // carrying the blob into every reply and every Settings diagnostic.
    let huge = "w".repeat(1 << 20);
    let unicode_ok = "名".repeat(128);
    let unicode_long = "名".repeat(129);
    let request: Request = serde_json::from_value(json!({
        "workspaces": {huge: {"hidden": true}, unicode_ok.as_str(): {"hidden": true},
                       unicode_long: {"hidden": true}},
        "input": [{"id": "projects", "region": "middle", "nodes": [
            {"id": unicode_ok, "kind": "workspace", "workspace_ids": [unicode_ok]}
        ]}]
    }))
    .unwrap();
    let reply = respond(&request);
    // 128 characters is an id, whatever their bytes; 129 is not.
    assert_eq!(reply.hidden_workspaces, [unicode_ok]);
    let bytes = serde_json::to_vec(&reply.problems).unwrap().len();
    assert!(bytes < 4 * 1024, "problems are {bytes} bytes");
    assert_eq!(reply.problems.len(), 2, "{bytes}");
    for problem in &reply.problems {
        let key = problem.path.strip_prefix("sidebar.workspaces.").unwrap();
        assert!(key.chars().count() <= MAX_QUOTED + 1, "path quotes {} chars", key.chars().count());
    }
}

#[test]
fn conflicting_rules_resolve_the_same_way_every_time() {
    // The selected workspace is hidden by its own rule and by its section; the order lists a hidden
    // section, twice, and a regroup points at a group in another section.
    let request: Request = serde_json::from_value(json!({
        "sections": {"hidden": ["a", "b"], "order": ["b", "b", "a", "missing"]},
        "workspaces": {"ws_a": {"hidden": true, "group": "gb", "order": 0}, "ws_b": {"hidden": true}},
        "selected": "ws_a",
        "input": [
            {"id": "a", "region": "middle", "nodes": [{"id": "ws_a", "kind": "workspace", "workspace_ids": ["ws_a"]}]},
            {"id": "b", "region": "middle", "nodes": [
                {"id": "gb", "kind": "group", "name": "gb", "workspace_ids": []},
                {"id": "ws_b", "kind": "workspace", "workspace_ids": ["ws_b"]}
            ]}
        ]
    }))
    .unwrap();
    let reply = respond(&request);
    // The selected row and its section stay; the other hidden section goes, with its rows.
    assert_eq!(reply.hidden_sections, ["b"]);
    assert!(reply.hidden_workspaces.is_empty(), "{:?}", reply.hidden_workspaces);
    assert!(reply.workspace_groups.is_empty());
    assert_eq!(reply.section_order, ["b", "a"]);
    let again = respond(&request);
    assert_eq!(serde_json::to_value(&reply).unwrap(), serde_json::to_value(&again).unwrap());
    // Only the selection keeps ws_a and section a: the next selection change must plan again.
    assert!(reply.selection_spared);
}

#[test]
fn the_plan_says_when_only_the_selection_keeps_a_row_shown() {
    // The app re-plans on a selection change only when this is true (or the new selection is
    // hidden), so a click on a shown row costs the same at 50 workspaces and 20,000.
    let with = |selected: Option<&str>| {
        let request: Request = serde_json::from_value(json!({
            "sections": {"hidden": ["recents"]},
            "workspaces": {"ws_h": {"hidden": true}, "ws_v": {"order": 1}},
            "selected": selected,
            "input": [
                {"id": "projects", "region": "middle", "nodes": [
                    {"id": "ws_h", "kind": "workspace", "workspace_ids": ["ws_h"]},
                    {"id": "ws_v", "kind": "workspace", "workspace_ids": ["ws_v"]}
                ]},
                {"id": "recents", "region": "bottom", "nodes": [
                    {"id": "ws_r", "kind": "workspace", "workspace_ids": ["ws_r"]}
                ]}
            ]
        }))
        .unwrap();
        respond(&request).selection_spared
    };
    assert!(with(Some("ws_h")), "a hidden row kept for its selection");
    assert!(with(Some("ws_r")), "a row of a hidden section kept for its selection");
    assert!(!with(Some("ws_v")), "a shown row");
    assert!(!with(Some("unknown")), "a selection the sidebar does not list");
    assert!(!with(None));
}

#[test]
fn sidebar_customization_stress_a_rule_for_every_workspace() {
    // The heavy end of "tons of customization": every workspace carries a rule (hide, regroup into
    // its section's group by name, or an explicit order), up to the document's ceiling.
    let sizes = [(8, 50), (50, 500), (MAX_SECTIONS, 5_000), (MAX_SECTIONS, MAX_ITEMS)];
    println!("sections | workspaces = rules | p50 us | p95 us | p50 ns/workspace");
    let mut per_workspace = Vec::new();
    for (sections, workspaces) in sizes {
        let per = workspaces.div_ceil(sections);
        let rules: serde_json::Map<String, Value> = (0..workspaces)
            .map(|w| {
                let rule = match w % 3 {
                    0 => json!({"hidden": true}),
                    1 => json!({"group": format!("Group {}", w / per)}),
                    _ => json!({"order": w}),
                };
                (format!("ws_{w}"), rule)
            })
            .collect();
        let request = Request {
            sections: json!({"order": (0..sections).rev().map(|s| format!("key_{s}")).collect::<Vec<_>>()}),
            workspaces: Value::Object(rules),
            input: sidebar(sections, workspaces),
            selected: Some("ws_0".into()),
        };
        let reply = respond(&request);
        assert!(reply.problems.is_empty(), "{:?}", &reply.problems[..reply.problems.len().min(3)]);
        assert_eq!(reply.hidden_workspaces.len(), workspaces.div_ceil(3) - 1);
        let runs = if workspaces > 5_000 { 20 } else { 100 };
        let (p50, p95) = percentiles(&request, runs);
        let ns = p50 / workspaces as u128;
        per_workspace.push(ns);
        println!("{sections} | {workspaces} | {} | {} | {ns}", p50 / 1_000, p95 / 1_000);
    }
    let base = per_workspace[0].max(100);
    for (ns, (sections, workspaces)) in per_workspace.iter().zip(sizes) {
        assert!(*ns <= base * 4, "{sections}x{workspaces}: {ns} ns per workspace vs {base} at 1x");
    }
}
