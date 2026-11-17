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
        workspaces: serde_json::Value::Object(rules),
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
    let rules: serde_json::Map<String, serde_json::Value> =
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
