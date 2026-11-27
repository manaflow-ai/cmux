//! The row index's rules, moved from Swift's `SidebarRowIndex.swift`: which section keeps its header in the one-list
//! sidebar, which parts of a machine's label a row names, which band looks changed, and where a patched row's copy
//! of a workspace sits. The app keeps the index itself (built once per structural change, read on every row patch),
//! the label's words and the views.

use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::collections::{BTreeMap, BTreeSet};

/// Whether a section keeps its header (and its fold) in the one-list sidebar (`keepsHeaderInOneList`): only a remote
/// group the person made that does not draw as one sidebar group.
pub fn keeps_header(is_host_group: bool, draws_as_group: bool) -> bool {
    is_host_group && !draws_as_group
}

/// A machine's kind (`SidebarMachine.Kind`).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum MachineKind {
    Local,
    Cloud,
    Ssh,
    Server,
}

/// The parts of the label a workspace row names for its machine (`machineLabel`): its name, its status, or both
/// (the app joins them); none: no label.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct Label {
    pub name: bool,
    pub status: bool,
}

/// The label a row of a section on `kind` names: never this Mac (nor a section with no machine, nor any while the
/// list does not flatten machines); a Cloud row only a status the person must act on; any other its name, with its
/// status when it has one.
pub fn machine_label(flattens: bool, kind: Option<MachineKind>, has_status: bool) -> Option<Label> {
    let kind = kind.filter(|kind| flattens && *kind != MachineKind::Local)?;
    match kind {
        MachineKind::Cloud => has_status.then_some(Label { name: false, status: true }),
        _ => Some(Label { name: true, status: has_status }),
    }
}

/// The items whose look `new` adds, changes or drops from `old` (`changedItemInfo`); a look is the app's value,
/// compared as given. Added and changed first, by id, then dropped, by id.
pub fn changed(old: &BTreeMap<String, Value>, new: &BTreeMap<String, Value>) -> Vec<String> {
    let mut ids: Vec<String> = new
        .iter()
        .filter(|(id, look)| old.get(*id) != Some(*look))
        .map(|(id, _)| id.clone())
        .collect();
    ids.extend(old.keys().filter(|id| !new.contains_key(*id)).cloned());
    ids
}

/// A row of the index's sections: a loose workspace, a group with its workspace members, or an item.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Node {
    Workspace(String),
    Group(Vec<String>),
    Item,
}

/// A workspace row's place: its section, its node and its slot in that node's group (none: a loose row).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Path {
    pub section: usize,
    pub node: usize,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub member: Option<usize>,
}

/// Every place each workspace is listed, in list order (a launch can list a saved row beside its live one).
pub fn paths(sections: &[Vec<Node>]) -> BTreeMap<String, Vec<Path>> {
    let mut paths: BTreeMap<String, Vec<Path>> = BTreeMap::new();
    for (section, nodes) in sections.iter().enumerate() {
        for (node, row) in nodes.iter().enumerate() {
            match row {
                Node::Workspace(id) => {
                    paths.entry(id.clone()).or_default().push(Path { section, node, member: None });
                }
                Node::Group(members) => {
                    for (member, id) in members.iter().enumerate() {
                        paths.entry(id.clone()).or_default().push(Path {
                            section,
                            node,
                            member: Some(member),
                        });
                    }
                }
                Node::Item => {}
            }
        }
    }
    paths
}

/// Whether `nodes[node]` lists workspace `id` at `member` (`lists`): the same place in another copy of the rows. The
/// app checks the node's identity first.
pub fn lists(id: &str, node: usize, member: Option<usize>, nodes: &[Node]) -> bool {
    match (nodes.get(node), member) {
        (Some(Node::Workspace(listed)), None) => listed == id,
        (Some(Node::Group(members)), Some(member)) => {
            members.get(member).is_some_and(|listed| listed == id)
        }
        _ => false,
    }
}

/// The workspaces a patch with `rows` rewrites in `sections` (`patching`): each listed row whose id it carries.
pub fn patched(rows: &BTreeSet<String>, sections: &[Vec<Node>]) -> Vec<Path> {
    let mut out = Vec::new();
    for (id, places) in paths(sections) {
        if rows.contains(&id) {
            out.extend(places);
        }
    }
    out.sort_by_key(|path| (path.section, path.node, path.member));
    out
}

/// A request to the `sidebar_row_index` FFI op.
#[derive(Debug, Deserialize)]
#[serde(tag = "op", rename_all = "snake_case")]
pub enum Request {
    /// `{keeps}`.
    KeepsHeader {
        #[serde(default)]
        is_host_group: bool,
        #[serde(default)]
        draws_as_group: bool,
    },
    /// `{label}` (null: none).
    MachineLabel {
        #[serde(default)]
        flattens: bool,
        #[serde(default)]
        kind: Option<MachineKind>,
        #[serde(default)]
        has_status: bool,
    },
    /// `{ids}`.
    Changed {
        #[serde(default)]
        old: BTreeMap<String, Value>,
        #[serde(default)]
        new: BTreeMap<String, Value>,
    },
    /// `{paths}`.
    Paths {
        #[serde(default)]
        sections: Vec<Vec<Node>>,
    },
    /// `{lists}`.
    Lists {
        id: String,
        node: usize,
        #[serde(default)]
        member: Option<usize>,
        #[serde(default)]
        nodes: Vec<Node>,
    },
    /// `{paths}`.
    Patched {
        #[serde(default)]
        rows: BTreeSet<String>,
        #[serde(default)]
        sections: Vec<Vec<Node>>,
    },
}

/// The answer to one request.
pub fn respond(request: Request) -> Value {
    match request {
        Request::KeepsHeader { is_host_group, draws_as_group } => {
            json!({"keeps": keeps_header(is_host_group, draws_as_group)})
        }
        Request::MachineLabel { flattens, kind, has_status } => {
            json!({"label": machine_label(flattens, kind, has_status)})
        }
        Request::Changed { old, new } => json!({"ids": changed(&old, &new)}),
        Request::Paths { sections } => json!({"paths": paths(&sections)}),
        Request::Lists { id, node, member, nodes } => {
            json!({"lists": lists(&id, node, member, &nodes)})
        }
        Request::Patched { rows, sections } => json!({"paths": patched(&rows, &sections)}),
    }
}

#[cfg(test)]
#[path = "sidebar_row_index_tests.rs"]
mod tests;
