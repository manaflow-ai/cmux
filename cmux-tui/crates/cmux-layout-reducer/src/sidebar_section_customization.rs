//! Rust-owned planning for the configurable sidebar projection (CMUX-383
//! slice 2).
//!
//! The sidebar document stays the source of placement truth. This module
//! interprets the bounded `sidebar.sections` / `sidebar.workspaces` settings
//! overlay and returns deterministic projection mutations for the native view
//! to apply mechanically, plus the edits that undo a hide (Show, Show All,
//! Reset) so every surface writes the same keys a file edit does.
//!
//! Cost model. The planning request carries the document's *outline* (its
//! sections and their groups) and the location of only the workspaces the
//! settings name, plus the selected one. Its size and the planning work depend
//! on the settings and on how many sections and groups exist, never on how
//! many workspace rows the document lists: a 30-row and a 3,000-row sidebar
//! send the same request. The older `input` shape (every node of every
//! section) is still accepted and folded into the same outline, so a caller
//! that has not moved yet keeps working; it no longer switches customization
//! off when a section lists more than 256 rows.

use serde::{Deserialize, Serialize};
use serde_json::{Map, Value};
use std::collections::{BTreeMap, BTreeSet};

/// Settings entries (hidden ids, ordered ids, workspace overrides) and
/// outline entries (sections, groups per section) read per level.
pub const MAX_ENTRIES: usize = 256;
const MAX_ID: usize = 128;
const MAX_ORDER: i64 = 1_000_000;

#[derive(Debug, Default, Deserialize)]
pub struct Request {
    #[serde(default)]
    pub sections: Value,
    #[serde(default)]
    pub workspaces: Value,
    /// The document's sections and groups, in document order.
    #[serde(default)]
    pub outline: Vec<SectionOutline>,
    /// Where each workspace the settings name (and the selected one) lists:
    /// its section id and, when it is a group member, the group id.
    #[serde(default)]
    pub locations: BTreeMap<String, Location>,
    /// Legacy full-document input; folded into `outline` and `locations`.
    #[serde(default)]
    pub input: Vec<SectionInput>,
    #[serde(default)]
    pub selected: Option<String>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct SectionOutline {
    pub id: String,
    #[serde(default)]
    pub keys: Vec<String>,
    #[serde(default)]
    pub region: String,
    #[serde(default)]
    pub groups: Vec<GroupOutline>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct GroupOutline {
    pub id: String,
    #[serde(default)]
    pub name: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
pub struct Location {
    pub section: String,
    #[serde(default)]
    pub group: Option<String>,
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
    /// True when the settings themselves had no malformed value. A caller
    /// keeps its last good projection when this is false (an unknown id is a
    /// document fact, not a malformed value, and leaves this true).
    pub complete: bool,
    /// Section ids in the Rust-selected order. Unknown sections are retained.
    pub section_order: Vec<String>,
    /// Sections and workspaces to omit from the rendered projection.
    pub hidden_sections: Vec<String>,
    pub hidden_workspaces: Vec<String>,
    /// Valid per-workspace target group ids and explicit order keys.
    pub workspace_groups: BTreeMap<String, String>,
    pub workspace_orders: BTreeMap<String, i64>,
    /// Every hide the settings make that names something the document has,
    /// including one the selection is overriding: the list a Show control,
    /// Settings and the command palette offer to undo.
    pub restorable: Vec<Restorable>,
    /// True when a hide was skipped because it would hide the selection. A
    /// selection change away from it must project again.
    pub selection_overrides_hide: bool,
    /// A stable digest of the plan: equal revisions project the same rows.
    pub revision: u64,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct Restorable {
    /// `section` or `workspace`.
    pub kind: &'static str,
    /// The section id or workspace id.
    pub id: String,
    /// The settings value to clear: the `sidebar.sections.hidden` entry as
    /// written (a section id or one of its keys), or the workspace id.
    pub key: String,
}

#[derive(Debug, Clone, Serialize)]
pub struct Workspace {
    pub hidden: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub group: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub order: Option<i64>,
}

#[derive(Debug, Default)]
struct Plan {
    section_order: Vec<String>,
    hidden_sections: Vec<String>,
    hidden_workspaces: Vec<String>,
    workspace_groups: BTreeMap<String, String>,
    workspace_orders: BTreeMap<String, i64>,
    restorable: Vec<Restorable>,
    selection_overrides_hide: bool,
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
                None | Some(Value::Null) => false,
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

/// Folds the legacy full-document `input` into an outline and the locations
/// of only the workspaces `wanted` names, keeping the first listing of each.
fn fold_input(
    input: &[SectionInput],
    wanted: &BTreeSet<&str>,
    problems: &mut Vec<Problem>,
) -> (Vec<SectionOutline>, BTreeMap<String, Location>) {
    let mut outline = Vec::with_capacity(input.len().min(MAX_ENTRIES + 1));
    let mut locations = BTreeMap::new();
    let mut listed = BTreeSet::new();
    for (section_index, section) in input.iter().enumerate() {
        let mut groups = Vec::new();
        for (node_index, node) in section.nodes.iter().enumerate() {
            let group = (node.kind == "group").then(|| node.id.clone());
            if group.is_some() {
                groups.push(GroupOutline { id: node.id.clone(), name: node.name.clone() });
            }
            for (workspace_index, workspace) in node.workspace_ids.iter().enumerate() {
                if !listed.insert(workspace.as_str()) {
                    problems.push(Problem {
                        path: format!(
                            "sidebar.input[{section_index}].nodes[{node_index}].workspace_ids[{workspace_index}]"
                        ),
                        why: "duplicate workspace id; keeping the first listing".into(),
                    });
                    continue;
                }
                if wanted.contains(workspace.as_str()) {
                    locations.insert(
                        workspace.clone(),
                        Location { section: section.id.clone(), group: group.clone() },
                    );
                }
            }
        }
        outline.push(SectionOutline {
            id: section.id.clone(),
            keys: section.keys.clone(),
            region: section.region.clone(),
            groups,
        });
    }
    (outline, locations)
}

fn section_matches(section: &SectionOutline, key: &str) -> bool {
    section.id == key || section.keys.iter().any(|candidate| candidate == key)
}

fn plan(
    outline: &[SectionOutline],
    locations: &BTreeMap<String, Location>,
    selected: Option<&str>,
    hidden: &[String],
    order: &[String],
    workspaces: &BTreeMap<String, Workspace>,
    problems: &mut Vec<Problem>,
) -> Plan {
    let mut section_ids = BTreeSet::new();
    let mut section_keys = BTreeSet::new();
    // Per section: exact group ids, and display names (`None` marks an
    // ambiguous name). An exact id wins over another group's display name.
    let mut group_ids: BTreeMap<&str, BTreeSet<&str>> = BTreeMap::new();
    let mut group_names: BTreeMap<&str, BTreeMap<&str, Option<&str>>> = BTreeMap::new();
    let mut sections = Vec::with_capacity(outline.len());
    for (section_index, section) in outline.iter().enumerate() {
        if !section_ids.insert(section.id.as_str()) {
            problems.push(Problem {
                path: format!("sidebar.input[{section_index}].id"),
                why: "duplicate section id; keeping the first section".into(),
            });
            continue;
        }
        sections.push(section);
        section_keys.insert(section.id.as_str());
        section_keys.extend(section.keys.iter().map(String::as_str));
        let ids = group_ids.entry(section.id.as_str()).or_default();
        let names = group_names.entry(section.id.as_str()).or_default();
        for group in &section.groups {
            ids.insert(group.id.as_str());
            if let Some(name) = group.name.as_deref() {
                match names.get(name) {
                    None => {
                        names.insert(name, Some(group.id.as_str()));
                    }
                    Some(Some(existing)) if *existing == group.id => {}
                    Some(_) => {
                        names.insert(name, None);
                    }
                }
            }
        }
    }
    for (index, key) in hidden.iter().enumerate() {
        if !section_keys.contains(key.as_str()) {
            problems.push(Problem {
                path: format!("sidebar.sections.hidden[{index}]"),
                why: "unknown section id; ignoring it".into(),
            });
        }
    }
    for (index, key) in order.iter().enumerate() {
        if !section_keys.contains(key.as_str()) {
            problems.push(Problem {
                path: format!("sidebar.sections.order[{index}]"),
                why: "unknown section id; ignoring it".into(),
            });
        }
    }
    let known = |id: &str| -> Option<&Location> {
        locations.get(id).filter(|location| section_ids.contains(location.section.as_str()))
    };
    let selected_section = selected.and_then(known).map(|location| location.section.as_str());

    let mut out = Plan::default();
    let mut hidden_section_set = BTreeSet::new();
    for section in &sections {
        let Some(key) = hidden.iter().find(|key| section_matches(section, key)) else { continue };
        out.restorable.push(Restorable {
            kind: "section",
            id: section.id.clone(),
            key: key.clone(),
        });
        if selected_section == Some(section.id.as_str()) {
            out.selection_overrides_hide = true;
        } else {
            out.hidden_sections.push(section.id.clone());
            hidden_section_set.insert(section.id.as_str());
        }
    }

    for (workspace, setting) in workspaces {
        let Some(location) = known(workspace) else {
            problems.push(Problem {
                path: format!("sidebar.workspaces.{workspace}"),
                why: "unknown workspace id; ignoring it".into(),
            });
            continue;
        };
        let section = location.section.as_str();
        if setting.hidden {
            out.restorable.push(Restorable {
                kind: "workspace",
                id: workspace.clone(),
                key: workspace.clone(),
            });
            if selected == Some(workspace.as_str()) {
                out.selection_overrides_hide = true;
            } else if !hidden_section_set.contains(section) {
                out.hidden_workspaces.push(workspace.clone());
            }
        }
        if let Some(target) = &setting.group {
            let group_id =
                if group_ids.get(section).is_some_and(|ids| ids.contains(target.as_str())) {
                    Some(target.as_str())
                } else {
                    group_names
                        .get(section)
                        .and_then(|names| names.get(target.as_str()))
                        .copied()
                        .flatten()
                };
            if let Some(group_id) = group_id {
                if location.group.as_deref() != Some(group_id) {
                    out.workspace_groups.insert(workspace.clone(), group_id.to_owned());
                }
            } else {
                problems.push(Problem {
                    path: format!("sidebar.workspaces.{workspace}.group"),
                    why: "group was not found in the workspace's section; keeping its document placement".into(),
                });
            }
        }
        if let Some(value) = setting.order {
            out.workspace_orders.insert(workspace.clone(), value);
        }
    }

    // Reorder only within each existing region. This keeps app and fixed-band
    // boundaries intact while allowing a user order to rank known sections.
    // The sort is stable, so unranked sections keep document order.
    let mut start = 0;
    while start < sections.len() {
        let region = sections.get(start).map_or("", |section| section.region.as_str());
        let end = sections
            .iter()
            .skip(start)
            .position(|section| section.region != region)
            .map_or(sections.len(), |offset| start + offset);
        let mut chunk = sections.iter().skip(start).take(end - start).collect::<Vec<_>>();
        chunk.sort_by_key(|section| {
            order.iter().position(|key| section_matches(section, key)).unwrap_or(usize::MAX)
        });
        out.section_order.extend(chunk.into_iter().map(|section| section.id.clone()));
        start = end;
    }
    out
}

/// FNV-1a over the plan's fields: stable across runs and hosts.
fn revision(plan: &Plan) -> u64 {
    let mut hash: u64 = 0xcbf2_9ce4_8422_2325;
    let mut eat = |bytes: &[u8]| {
        for byte in bytes {
            hash ^= u64::from(*byte);
            hash = hash.wrapping_mul(0x0100_0000_01b3);
        }
        hash ^= 0xff;
        hash = hash.wrapping_mul(0x0100_0000_01b3);
    };
    for id in &plan.section_order {
        eat(b"o");
        eat(id.as_bytes());
    }
    for id in &plan.hidden_sections {
        eat(b"s");
        eat(id.as_bytes());
    }
    for id in &plan.hidden_workspaces {
        eat(b"w");
        eat(id.as_bytes());
    }
    for (workspace, group) in &plan.workspace_groups {
        eat(b"g");
        eat(workspace.as_bytes());
        eat(group.as_bytes());
    }
    for (workspace, order) in &plan.workspace_orders {
        eat(b"r");
        eat(workspace.as_bytes());
        eat(&order.to_le_bytes());
    }
    hash
}

pub fn respond(request: &Request) -> Reply {
    let mut problems = Vec::new();
    let (hidden, order, workspaces) = config(request, &mut problems);
    let complete = problems.is_empty();

    let folded;
    let (outline, locations) = if request.input.is_empty() {
        (request.outline.as_slice(), &request.locations)
    } else {
        let wanted = workspaces
            .keys()
            .map(String::as_str)
            .chain(request.selected.as_deref())
            .collect::<BTreeSet<_>>();
        folded = fold_input(&request.input, &wanted, &mut problems);
        (folded.0.as_slice(), &folded.1)
    };
    let too_large = outline.len() > MAX_ENTRIES
        || outline.iter().any(|section| section.groups.len() > MAX_ENTRIES)
        || locations.len() > 2 * MAX_ENTRIES + 1;
    let plan = if too_large {
        problems.push(Problem {
            path: "sidebar.input".into(),
            why: format!(
                "ignored sidebar outline with more than {MAX_ENTRIES} sections or groups per section"
            ),
        });
        Plan::default()
    } else {
        plan(
            outline,
            locations,
            request.selected.as_deref(),
            &hidden,
            &order,
            &workspaces,
            &mut problems,
        )
    };
    let revision = revision(&plan);
    Reply {
        hidden,
        order,
        workspaces,
        problems,
        complete,
        section_order: plan.section_order,
        hidden_sections: plan.hidden_sections,
        hidden_workspaces: plan.hidden_workspaces,
        workspace_groups: plan.workspace_groups,
        workspace_orders: plan.workspace_orders,
        restorable: plan.restorable,
        selection_overrides_hide: plan.selection_overrides_hide,
        revision,
    }
}

/// One undo-or-hide edit of the projection settings. Every surface (Settings,
/// the command palette, a row menu) goes through these, so each writes the
/// same keys a hand edit of `cmux-next.json` does.
#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
#[serde(tag = "op", rename_all = "snake_case")]
pub enum Edit {
    HideSection {
        id: String,
    },
    ShowSection {
        id: String,
    },
    HideWorkspace {
        id: String,
    },
    ShowWorkspace {
        id: String,
    },
    /// Clears every hide (sections and workspaces); keeps order and groups.
    ShowAll,
    /// Removes every projection override: hides, section order, and
    /// per-workspace hidden/group/order.
    Reset,
}

#[derive(Debug, Deserialize)]
pub struct EditRequest {
    #[serde(default)]
    pub sections: Value,
    #[serde(default)]
    pub workspaces: Value,
    pub edit: Edit,
}

#[derive(Debug, PartialEq, Serialize)]
pub struct EditReply {
    /// The new `sidebar.sections` value; `null` removes the key.
    pub sections: Value,
    /// The new `sidebar.workspaces` value; `null` removes the key.
    pub workspaces: Value,
    pub changed: bool,
    /// Set when the edit was refused (an invalid id, a full list).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub refused: Option<String>,
}

fn object_or_empty(value: &Value) -> Map<String, Value> {
    value.as_object().cloned().unwrap_or_default()
}

fn or_null(map: Map<String, Value>) -> Value {
    if map.is_empty() { Value::Null } else { Value::Object(map) }
}

fn hidden_list(sections: &Map<String, Value>) -> Vec<Value> {
    sections.get("hidden").and_then(Value::as_array).cloned().unwrap_or_default()
}

fn set_hidden_list(sections: &mut Map<String, Value>, list: Vec<Value>) {
    if list.is_empty() {
        sections.remove("hidden");
    } else {
        sections.insert("hidden".into(), Value::Array(list));
    }
}

fn clear_workspace_field(workspaces: &mut Map<String, Value>, id: &str, field: &str) {
    let Some(entry) = workspaces.get_mut(id) else { return };
    let empty = match entry.as_object_mut() {
        Some(fields) => {
            fields.remove(field);
            fields.is_empty()
        }
        None => true,
    };
    if empty {
        workspaces.remove(id);
    }
}

pub fn edit(request: &EditRequest) -> EditReply {
    let mut sections = object_or_empty(&request.sections);
    let mut workspaces = object_or_empty(&request.workspaces);
    let refuse = |why: &str| EditReply {
        sections: request.sections.clone(),
        workspaces: request.workspaces.clone(),
        changed: false,
        refused: Some(why.to_owned()),
    };
    match &request.edit {
        Edit::HideSection { id }
        | Edit::HideWorkspace { id }
        | Edit::ShowSection { id }
        | Edit::ShowWorkspace { id }
            if !valid_id(id) =>
        {
            return refuse("expected a non-empty id of at most 128 characters");
        }
        Edit::HideSection { id } => {
            let mut list = hidden_list(&sections);
            if !list.iter().any(|value| value.as_str() == Some(id)) {
                if list.len() >= MAX_ENTRIES {
                    return refuse("sidebar.sections.hidden is full");
                }
                list.push(Value::String(id.clone()));
            }
            set_hidden_list(&mut sections, list);
        }
        Edit::ShowSection { id } => {
            let mut list = hidden_list(&sections);
            list.retain(|value| value.as_str() != Some(id));
            set_hidden_list(&mut sections, list);
        }
        Edit::HideWorkspace { id } => {
            if !workspaces.contains_key(id) && workspaces.len() >= MAX_ENTRIES {
                return refuse("sidebar.workspaces is full");
            }
            let entry = workspaces.entry(id.clone()).or_insert_with(|| Value::Object(Map::new()));
            if !entry.is_object() {
                *entry = Value::Object(Map::new());
            }
            if let Some(fields) = entry.as_object_mut() {
                fields.insert("hidden".into(), Value::Bool(true));
            }
        }
        Edit::ShowWorkspace { id } => clear_workspace_field(&mut workspaces, id, "hidden"),
        Edit::ShowAll => {
            sections.remove("hidden");
            let ids = workspaces.keys().cloned().collect::<Vec<_>>();
            for id in ids {
                clear_workspace_field(&mut workspaces, &id, "hidden");
            }
        }
        Edit::Reset => {
            sections.remove("hidden");
            sections.remove("order");
            workspaces.clear();
        }
    }
    let sections = or_null(sections);
    let workspaces = or_null(workspaces);
    let changed =
        sections != normalized(&request.sections) || workspaces != normalized(&request.workspaces);
    EditReply { sections, workspaces, changed, refused: None }
}

fn normalized(value: &Value) -> Value {
    match value.as_object() {
        Some(map) if map.is_empty() => Value::Null,
        Some(_) => value.clone(),
        None => Value::Null,
    }
}

#[cfg(test)]
#[path = "sidebar_section_customization_tests.rs"]
mod tests;
