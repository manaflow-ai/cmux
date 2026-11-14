//! Rust-owned planning for the configurable sidebar projection.
//!
//! The document reducer remains the source of placement truth. This module
//! only interprets the bounded settings overlay and returns deterministic
//! projection mutations for the native view to apply mechanically.

use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::{BTreeMap, BTreeSet};

const MAX_ENTRIES: usize = 256;
const MAX_ID: usize = 128;
const MAX_ORDER: i64 = 1_000_000;

#[derive(Debug, Deserialize)]
pub struct Request {
    #[serde(default)]
    pub sections: Value,
    #[serde(default)]
    pub workspaces: Value,
    #[serde(default)]
    pub input: Vec<SectionInput>,
    #[serde(default)]
    pub selected: Option<String>,
}

#[derive(Debug, Deserialize)]
pub struct SectionInput {
    pub id: String,
    #[serde(default)]
    pub keys: Vec<String>,
    #[serde(default)]
    pub region: String,
    #[serde(default)]
    pub nodes: Vec<NodeInput>,
}

#[derive(Debug, Deserialize)]
pub struct NodeInput {
    pub id: String,
    #[serde(default)]
    pub kind: String,
    #[serde(default)]
    pub workspace_ids: Vec<String>,
    #[serde(default)]
    pub name: Option<String>,
}

#[derive(Debug, Serialize)]
pub struct Reply {
    pub hidden: Vec<String>,
    pub order: Vec<String>,
    pub workspaces: BTreeMap<String, Workspace>,
    pub problems: Vec<Problem>,
    /// Section ids in the Rust-selected order. Unknown sections are retained.
    pub section_order: Vec<String>,
    /// Sections and workspaces to omit from the rendered projection.
    pub hidden_sections: Vec<String>,
    pub hidden_workspaces: Vec<String>,
    /// Valid per-workspace target group ids and explicit order keys.
    pub workspace_groups: BTreeMap<String, String>,
    pub workspace_orders: BTreeMap<String, i64>,
}

#[derive(Debug, Clone, Serialize)]
pub struct Workspace {
    pub hidden: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub group: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub order: Option<i64>,
}

#[derive(Debug)]
struct Plan {
    section_order: Vec<String>,
    hidden_sections: Vec<String>,
    hidden_workspaces: Vec<String>,
    workspace_groups: BTreeMap<String, String>,
    workspace_orders: BTreeMap<String, i64>,
}

#[derive(Debug, Serialize)]
pub struct Problem {
    pub path: String,
    pub why: String,
}

fn valid_id(value: &str) -> bool {
    !value.is_empty() && value.chars().count() <= MAX_ID
}

fn list(value: &Value, path: &str, problems: &mut Vec<Problem>) -> Vec<String> {
    let Some(items) = value.as_array() else {
        if !value.is_null() {
            problems.push(Problem { path: path.into(), why: "expected a list of ids".into() });
        }
        return Vec::new();
    };
    if items.len() > MAX_ENTRIES {
        problems.push(Problem {
            path: path.into(),
            why: format!("ignored list with more than {MAX_ENTRIES} entries"),
        });
        return Vec::new();
    }
    let mut out = Vec::new();
    for (index, item) in items.iter().take(MAX_ENTRIES).enumerate() {
        let Some(id) = item.as_str() else {
            problems.push(Problem {
                path: format!("{path}[{index}]"),
                why: "expected a string id".into(),
            });
            continue;
        };
        if !valid_id(id) {
            problems.push(Problem {
                path: format!("{path}[{index}]"),
                why: "expected a non-empty id of at most 128 characters".into(),
            });
            continue;
        }
        if out.iter().any(|seen| seen == id) {
            problems.push(Problem {
                path: format!("{path}[{index}]"),
                why: "duplicate id; keeping the first occurrence".into(),
            });
            continue;
        }
        out.push(id.to_owned());
    }
    out
}

fn config(
    request: &Request,
    problems: &mut Vec<Problem>,
) -> (Vec<String>, Vec<String>, BTreeMap<String, Workspace>) {
    let object = request.sections.as_object();
    let hidden = object.map_or_else(Vec::new, |value| {
        list(value.get("hidden").unwrap_or(&Value::Null), "sidebar.sections.hidden", problems)
    });
    let order = object.map_or_else(Vec::new, |value| {
        list(value.get("order").unwrap_or(&Value::Null), "sidebar.sections.order", problems)
    });
    if object.is_none() && !request.sections.is_null() {
        problems
            .push(Problem { path: "sidebar.sections".into(), why: "expected an object".into() });
    }

    let mut workspaces = BTreeMap::new();
    if let Some(entries) = request.workspaces.as_object() {
        if entries.len() > MAX_ENTRIES {
            problems.push(Problem {
                path: "sidebar.workspaces".into(),
                why: format!("ignored object with more than {MAX_ENTRIES} entries"),
            });
            return (hidden, order, workspaces);
        }
        for (id, value) in entries {
            let path = format!("sidebar.workspaces.{id}");
            if !valid_id(id) {
                problems.push(Problem {
                    path,
                    why: "expected a non-empty workspace id of at most 128 characters".into(),
                });
                continue;
            }
            let Some(fields) = value.as_object() else {
                problems.push(Problem { path, why: "expected an object".into() });
                continue;
            };
            let hidden = match fields.get("hidden") {
                None => false,
                Some(value) => match value.as_bool() {
                    Some(flag) => flag,
                    None => {
                        problems.push(Problem {
                            path: format!("sidebar.workspaces.{id}.hidden"),
                            why: "expected true or false".into(),
                        });
                        false
                    }
                },
            };
            let group = match fields.get("group") {
                None | Some(Value::Null) => None,
                Some(value) => match value.as_str() {
                    Some(group) if valid_id(group) => Some(group.to_owned()),
                    _ => {
                        problems.push(Problem {
                            path: format!("sidebar.workspaces.{id}.group"),
                            why: "expected a non-empty group id of at most 128 characters".into(),
                        });
                        None
                    }
                },
            };
            let order = match fields.get("order") {
                None | Some(Value::Null) => None,
                Some(value) => match value.as_i64().filter(|value| (0..=MAX_ORDER).contains(value))
                {
                    Some(value) => Some(value),
                    None => {
                        problems.push(Problem {
                            path: format!("sidebar.workspaces.{id}.order"),
                            why: format!("expected an integer from 0 to {MAX_ORDER}"),
                        });
                        None
                    }
                },
            };
            workspaces.insert(id.clone(), Workspace { hidden, group, order });
        }
    } else if !request.workspaces.is_null() {
        problems.push(Problem {
            path: "sidebar.workspaces".into(),
            why: "expected an object keyed by workspace id".into(),
        });
    }
    (hidden, order, workspaces)
}

fn plan(
    input: &[SectionInput],
    selected: Option<&str>,
    hidden: &[String],
    order: &[String],
    workspaces: &BTreeMap<String, Workspace>,
    problems: &mut Vec<Problem>,
) -> Plan {
    let input_len = input.len().min(MAX_ENTRIES);
    let mut section_for_workspace = BTreeMap::new();
    let mut section_ids = BTreeSet::new();
    let mut section_keys = BTreeSet::new();
    // `None` marks an ambiguous display name. Exact group ids are kept in a
    // separate set, so an id still wins when it happens to equal another
    // group's display name.
    let mut valid_groups: BTreeMap<String, BTreeMap<String, Option<String>>> = BTreeMap::new();
    let mut group_ids: BTreeMap<String, BTreeSet<String>> = BTreeMap::new();
    let mut add_group_alias = |section: &str, alias: &str, id: &str| {
        let aliases = valid_groups.entry(section.to_owned()).or_default();
        match aliases.get(alias) {
            None => {
                aliases.insert(alias.to_owned(), Some(id.to_owned()));
            }
            Some(Some(existing)) if existing == id => {}
            Some(_) => {
                aliases.insert(alias.to_owned(), None);
            }
        }
    };
    for (section_index, section) in input.iter().take(input_len).enumerate() {
        if !section_ids.insert(section.id.clone()) {
            problems.push(Problem {
                path: format!("sidebar.input[{section_index}].id"),
                why: "duplicate section id; keeping the first section".into(),
            });
        }
        section_keys.insert(section.id.clone());
        section_keys.extend(section.keys.iter().cloned());
        for (node_index, node) in section.nodes.iter().take(MAX_ENTRIES).enumerate() {
            if node.kind == "group" {
                group_ids.entry(section.id.clone()).or_default().insert(node.id.clone());
                if let Some(name) = &node.name {
                    add_group_alias(&section.id, name, &node.id);
                }
            }
            for (workspace_index, workspace) in
                node.workspace_ids.iter().take(MAX_ENTRIES).enumerate()
            {
                if section_for_workspace.contains_key(workspace) {
                    problems.push(Problem {
                        path: format!("sidebar.input[{section_index}].nodes[{node_index}].workspace_ids[{workspace_index}]"),
                        why: "duplicate workspace id; keeping the first listing".into(),
                    });
                } else {
                    section_for_workspace.insert(workspace.clone(), section.id.clone());
                }
            }
        }
    }
    for (index, key) in hidden.iter().enumerate() {
        if !section_keys.contains(key) {
            problems.push(Problem {
                path: format!("sidebar.sections.hidden[{index}]"),
                why: "unknown section id; ignoring it".into(),
            });
        }
    }
    for (index, key) in order.iter().enumerate() {
        if !section_keys.contains(key) {
            problems.push(Problem {
                path: format!("sidebar.sections.order[{index}]"),
                why: "unknown section id; ignoring it".into(),
            });
        }
    }
    let selected_section = selected.and_then(|id| section_for_workspace.get(id)).cloned();
    let hidden_sections = input
        .iter()
        .take(input_len)
        .filter(|section| {
            hidden.iter().any(|key| {
                section.keys.iter().any(|candidate| candidate == key) || section.id == *key
            })
        })
        .filter(|section| selected_section.as_deref() != Some(section.id.as_str()))
        .map(|section| section.id.clone())
        .collect::<Vec<_>>();
    let hidden_section_set: BTreeSet<_> = hidden_sections.iter().cloned().collect();

    let mut hidden_workspaces = Vec::new();
    let mut workspace_groups = BTreeMap::new();
    let mut workspace_orders = BTreeMap::new();
    let mut workspace_group_for = BTreeMap::new();
    for section in input.iter().take(input_len) {
        for node in section.nodes.iter().take(MAX_ENTRIES) {
            if node.kind == "group" {
                for workspace in node.workspace_ids.iter().take(MAX_ENTRIES) {
                    workspace_group_for
                        .insert(workspace.clone(), (section.id.clone(), node.id.clone()));
                }
            }
        }
    }
    for (workspace, setting) in workspaces {
        let Some(section) = section_for_workspace.get(workspace) else {
            problems.push(Problem {
                path: format!("sidebar.workspaces.{workspace}"),
                why: "unknown workspace id; ignoring it".into(),
            });
            continue;
        };
        if setting.hidden
            && selected != Some(workspace.as_str())
            && !hidden_section_set.contains(section)
        {
            hidden_workspaces.push(workspace.clone());
        }
        if let Some(target) = &setting.group {
            let group_id = if group_ids.get(section).is_some_and(|ids| ids.contains(target)) {
                Some(target.clone())
            } else {
                valid_groups
                    .get(section)
                    .and_then(|groups| groups.get(target))
                    .and_then(Option::as_ref)
                    .cloned()
            };
            if let Some(group_id) = group_id {
                if workspace_group_for.get(workspace) != Some(&(section.clone(), group_id.clone()))
                {
                    workspace_groups.insert(workspace.clone(), group_id);
                }
            } else {
                problems.push(Problem { path: format!("sidebar.workspaces.{workspace}.group"), why: "group was not found in the workspace's section; keeping its document placement".into() });
            }
        }
        if let Some(value) = setting.order {
            workspace_orders.insert(workspace.clone(), value);
        }
    }

    // Reorder only within each existing region. This keeps app and fixed-band
    // boundaries intact while allowing a user order to rank known sections.
    let mut section_order = Vec::with_capacity(input_len);
    let mut start = 0;
    while start < input_len {
        let Some(first) = input.get(start) else { break };
        let region = first.region.as_str();
        let mut end = start + 1;
        while end < input_len && input.get(end).is_some_and(|section| section.region == region) {
            end += 1;
        }
        let mut chunk = input.iter().skip(start).take(end - start).collect::<Vec<_>>();
        chunk.sort_by_key(|section| {
            order
                .iter()
                .position(|key| {
                    section.keys.iter().any(|candidate| candidate == key) || section.id == *key
                })
                .unwrap_or(usize::MAX)
        });
        section_order.extend(chunk.into_iter().map(|section| section.id.clone()));
        start = end;
    }
    Plan { section_order, hidden_sections, hidden_workspaces, workspace_groups, workspace_orders }
}

pub fn respond(request: &Request) -> Reply {
    let mut problems = Vec::new();
    let input_too_large = request.input.len() > MAX_ENTRIES
        || request.input.iter().any(|section| {
            section.nodes.len() > MAX_ENTRIES
                || section.nodes.iter().any(|node| node.workspace_ids.len() > MAX_ENTRIES)
        });
    if input_too_large {
        problems.push(Problem {
            path: "sidebar.input".into(),
            why: format!("ignored sidebar document larger than {MAX_ENTRIES} entries per level"),
        });
    }
    let (hidden, order, workspaces) = config(request, &mut problems);
    if input_too_large {
        return Reply {
            hidden,
            order,
            workspaces,
            problems,
            section_order: Vec::new(),
            hidden_sections: Vec::new(),
            hidden_workspaces: Vec::new(),
            workspace_groups: BTreeMap::new(),
            workspace_orders: BTreeMap::new(),
        };
    }
    let plan = plan(
        &request.input,
        request.selected.as_deref(),
        &hidden,
        &order,
        &workspaces,
        &mut problems,
    );
    Reply {
        hidden,
        order,
        workspaces,
        problems,
        section_order: plan.section_order,
        hidden_sections: plan.hidden_sections,
        hidden_workspaces: plan.hidden_workspaces,
        workspace_groups: plan.workspace_groups,
        workspace_orders: plan.workspace_orders,
    }
}

#[cfg(test)]
mod tests {
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
}
