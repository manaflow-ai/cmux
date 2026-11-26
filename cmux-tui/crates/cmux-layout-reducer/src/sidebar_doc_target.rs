//! Where a sidebar drop or keyboard move lands in the document, and how an intent that names a
//! remote machine's group reaches the daemon, moved from Swift's `SidebarDocStore.target`
//! (`SidebarDocProjection.swift`), `SidebarDocDrag.swift` (`topLevelAnchor`, `nestedGroups`,
//! `unplacedTarget`, `keyboardMove`) and `SidebarHostGroup.swift` (`hostGroupID`, `hostMachine`,
//! `resolvingHostGroup`, `documentNodeCount`).

use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::collections::{BTreeMap, BTreeSet};

/// The prefix of a machine's document section id (`SidebarDocStore.machineSectionPrefix`).
pub const MACHINE_SECTION_PREFIX: &str = "sec_m_";
/// The prefix of a remote group's id (`SidebarGroup.hostGroupID`): never a document group's.
pub const HOST_GROUP_PREFIX: &str = "host:";

/// A move's anchor in the document (`SidebarDocTarget`).
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct Target {
    pub section: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub parent: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub before: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub after: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub index: Option<i64>,
}

/// The anchor target of a list position: before the `index`th staying sibling, after the last one
/// when past the end, else `index` 0 of an empty list.
pub fn target(
    section: &str,
    parent: Option<&str>,
    index: i64,
    siblings: &[String],
    moving: &BTreeSet<String>,
) -> Target {
    let staying: Vec<&String> = siblings.iter().filter(|id| !moving.contains(*id)).collect();
    let base =
        Target { section: section.into(), parent: parent.map(Into::into), ..Target::default() };
    if index >= 0
        && let Some(before) = usize::try_from(index).ok().and_then(|index| staying.get(index))
    {
        return Target { before: Some((*before).clone()), ..base };
    }
    if let Some(last) = staying.last() {
        return Target { after: Some((*last).clone()), ..base };
    }
    Target { index: Some(0), ..base }
}

/// `target` with its anchor moved off a nested group: a top-level slot counts the section's rows
/// flat, so the slot before a subgroup (or after the last row, when that is a subgroup) named the
/// subgroup as a top-level sibling, a move the document refuses. Such a slot is the gap before the
/// next top-level row, or after the last one.
pub fn top_level_anchor(
    target: Target,
    siblings: &[String],
    nested: &BTreeSet<String>,
    moving: &BTreeSet<String>,
) -> Target {
    let Some(anchor) = target.before.as_ref().or(target.after.as_ref()) else { return target };
    if !nested.contains(anchor) {
        return target;
    }
    let staying: Vec<&String> = siblings.iter().filter(|id| !moving.contains(*id)).collect();
    let section = target.section.clone();
    if target.before.is_some()
        && let Some(start) = staying.iter().position(|id| *id == anchor)
        && let Some(next) = staying[start..].iter().find(|id| !nested.contains(**id))
    {
        return Target { section, before: Some((*next).clone()), ..Target::default() };
    }
    match staying.iter().rev().find(|id| !nested.contains(**id)) {
        Some(last) => Target { section, after: Some((*last).clone()), ..Target::default() },
        None => Target { section, index: Some(0), ..Target::default() },
    }
}

/// A workspace row a move sends: whether the document places it, and its adopt ref's session.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct Unplaced {
    #[serde(default)]
    pub placed: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub session: Option<String>,
}

/// Where Move to Top (or a list reorder) sends workspace rows the document does not place when
/// their list section has no document section here: `index` of that machine's section, which the
/// rows' adopt makes. `None` unless every moving row is a workspace of one session with no item,
/// outside a group.
pub fn unplaced_target(in_group: bool, index: i64, rows: &[Unplaced]) -> Option<Target> {
    if in_group || rows.is_empty() || rows.iter().any(|row| row.placed) {
        return None;
    }
    let sessions: BTreeSet<&String> = rows.iter().filter_map(|row| row.session.as_ref()).collect();
    let mut only = sessions.iter();
    let (Some(session), None) = (only.next(), only.next()) else { return None };
    if session.is_empty() || rows.iter().any(|row| row.session.is_none()) {
        return None;
    }
    Some(Target {
        section: format!("{MACHINE_SECTION_PREFIX}{session}"),
        index: Some(index),
        ..Target::default()
    })
}

/// A workspace row the filtered list shows (or one the move carries), in list order.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct Visible {
    /// The workspace.
    pub id: String,
    /// The document section of its list section, or none.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub section: Option<String>,
    /// Its document item, or none.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub item: Option<String>,
    /// The group its node is, or none for a loose row.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub group: Option<String>,
}

/// A keyboard move's drop: these items, at this anchor.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct KeyboardMove {
    pub items: Vec<String>,
    pub target: Target,
}

/// Keyboard reorder while the list is filtered: the selection moves next to its visible neighbour
/// above (`up`) or below. `visible` lists every shown or moving workspace row; `items` is each
/// moving workspace's document item. `None` when there is no neighbour or a row has no item.
pub fn keyboard_move(
    visible: &[Visible],
    moving: &[String],
    items: &[Option<String>],
    up: bool,
) -> Option<KeyboardMove> {
    let set: BTreeSet<&String> = moving.iter().collect();
    let first = visible.iter().position(|row| set.contains(&row.id))?;
    let last = visible.iter().rposition(|row| set.contains(&row.id))?;
    let neighbour = if up { visible[..first].last() } else { visible[last + 1..].first() }?;
    let section = neighbour.section.clone()?;
    let anchor = neighbour.item.clone()?;
    let items: Vec<String> = items.iter().flatten().cloned().collect();
    if items.len() != moving.len() {
        return None;
    }
    let parent = neighbour.group.clone();
    let target = if up {
        Target { section, parent, before: Some(anchor), ..Target::default() }
    } else {
        Target { section, parent, after: Some(anchor), ..Target::default() }
    };
    Some(KeyboardMove { items, target })
}

/// The group id a remote group of `machine` takes.
pub fn host_group_id(machine: &str) -> String {
    format!("{HOST_GROUP_PREFIX}{machine}")
}

/// The machine a remote group id stands for; `None` for every other group.
pub fn host_machine(id: &str) -> Option<&str> {
    id.strip_prefix(HOST_GROUP_PREFIX)
}

fn host(id: Option<&String>) -> Option<&str> {
    id.and_then(|id| host_machine(id))
}

/// A drop position in the list (`DropPosition`): `section` is the list's section id as the caller
/// writes it, `{"machine": ID}` for a machine's.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Position {
    pub section: Value,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub group: Option<String>,
    pub index: i64,
}

/// The intents `resolvingHostGroup` reads. `group_edit` stands for every group edit with no
/// machine meaning (rename, editor ended, color, ungroup, pin, icon, close, open, reorder group);
/// `other` for every other intent.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum Intent {
    /// A group's fold.
    ToggleCollapseGroup {
        group: String,
    },
    /// A machine section's fold.
    ToggleCollapseSection {
        section: Value,
    },
    NewWorkspace {
        #[serde(default, skip_serializing_if = "Option::is_none")]
        machine: Option<String>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        group: Option<String>,
    },
    Move {
        ids: Vec<String>,
        group: String,
    },
    Reorder {
        ids: Vec<String>,
        to: Position,
    },
    GroupEdit {
        group: String,
    },
    Other,
}

/// This intent as the daemon takes it when it names a remote group, which no document holds: a
/// fold folds the machine's section, + makes a workspace on the machine, a drop into it lands at
/// the section's top level, after its `ends[machine]` top-level rows. Group edits with no machine
/// meaning are dropped (`None`). Other intents come back as is.
pub fn resolving_host_group(intent: Intent, ends: &BTreeMap<String, i64>) -> Option<Intent> {
    match intent {
        Intent::ToggleCollapseGroup { group } => match host_machine(&group) {
            Some(machine) => {
                Some(Intent::ToggleCollapseSection { section: json!({"machine": machine}) })
            }
            None => Some(Intent::ToggleCollapseGroup { group }),
        },
        Intent::NewWorkspace { machine, group } => match host(group.as_ref()) {
            Some(owner) => Some(Intent::NewWorkspace {
                machine: Some(machine.unwrap_or_else(|| owner.to_owned())),
                group: None,
            }),
            None => Some(Intent::NewWorkspace { machine, group }),
        },
        Intent::Move { ids, group } => match host_machine(&group) {
            Some(machine) => Some(Intent::Reorder {
                ids,
                to: Position {
                    section: json!({"machine": machine}),
                    group: None,
                    index: ends.get(machine).copied().unwrap_or(0),
                },
            }),
            None => Some(Intent::Move { ids, group }),
        },
        Intent::Reorder { ids, mut to } => {
            if host(to.group.as_ref()).is_some() {
                to.group = None;
            }
            Some(Intent::Reorder { ids, to })
        }
        Intent::GroupEdit { group } => {
            host_machine(&group).is_none().then_some(Intent::GroupEdit { group })
        }
        other @ (Intent::ToggleCollapseSection { .. } | Intent::Other) => Some(other),
    }
}

/// A top-level node of a section as `documentNodeCount` reads it.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum HostNode {
    /// A loose workspace or item.
    Row,
    /// A group: `host` when it is the machine's own (wrapped) group.
    Group {
        #[serde(default)]
        host: bool,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        parent: Option<String>,
        #[serde(default)]
        members: i64,
    },
}

/// A wrapped remote group's top-level rows as the document holds them: its loose members and its
/// groups. An unwrapped section counts its nodes.
pub fn document_node_count(draws_as_group: bool, nodes: &[HostNode]) -> i64 {
    if !draws_as_group {
        return nodes.len() as i64;
    }
    nodes
        .iter()
        .map(|node| match node {
            HostNode::Row => 1,
            HostNode::Group { host: true, members, .. } => *members,
            HostNode::Group { parent, .. } => i64::from(host(parent.as_ref()).is_some()),
        })
        .sum()
}

/// A request to the `sidebar_doc_target` FFI op.
#[derive(Debug, Deserialize)]
#[serde(tag = "op", rename_all = "snake_case")]
pub enum Request {
    /// `{target}`; with `nested`, its anchor moved off a nested group (a top-level position).
    Target {
        section: String,
        #[serde(default)]
        parent: Option<String>,
        index: i64,
        siblings: Vec<String>,
        #[serde(default)]
        moving: BTreeSet<String>,
        #[serde(default)]
        nested: Option<BTreeSet<String>>,
    },
    /// `{target}` or `{target: null}`.
    UnplacedTarget {
        #[serde(default)]
        in_group: bool,
        index: i64,
        rows: Vec<Unplaced>,
    },
    /// `{move}` or `{move: null}`.
    KeyboardMove {
        visible: Vec<Visible>,
        moving: Vec<String>,
        items: Vec<Option<String>>,
        up: bool,
    },
    /// `{intent}` or `{intent: null}` (dropped).
    ResolvingHostGroup {
        intent: Intent,
        #[serde(default)]
        ends: BTreeMap<String, i64>,
    },
    /// `{count}`.
    DocumentNodeCount {
        #[serde(default)]
        draws_as_group: bool,
        nodes: Vec<HostNode>,
    },
}

/// The answer to one request.
pub fn respond(request: Request) -> Value {
    match request {
        Request::Target { section, parent, index, siblings, moving, nested } => {
            let found = target(&section, parent.as_deref(), index, &siblings, &moving);
            let found = match nested {
                Some(nested) => top_level_anchor(found, &siblings, &nested, &moving),
                None => found,
            };
            json!({"target": found})
        }
        Request::UnplacedTarget { in_group, index, rows } => {
            json!({"target": unplaced_target(in_group, index, &rows)})
        }
        Request::KeyboardMove { visible, moving, items, up } => {
            json!({"move": keyboard_move(&visible, &moving, &items, up)})
        }
        Request::ResolvingHostGroup { intent, ends } => {
            json!({"intent": resolving_host_group(intent, &ends)})
        }
        Request::DocumentNodeCount { draws_as_group, nodes } => {
            json!({"count": document_node_count(draws_as_group, &nodes)})
        }
    }
}

#[cfg(test)]
#[path = "sidebar_doc_target_tests.rs"]
mod tests;
