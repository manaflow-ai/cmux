//! Which rows one window's sidebar lists and how a set of its sections changed, moved from Swift's
//! `SidebarSection+Membership.swift`, `SidebarSection+LooseInsertion.swift` and
//! `SidebarWorkspaceOrder.swift`.
//!
//! The rules read a skeleton of the sections: each section's shell, and each node as a loose
//! workspace, a group (its parent, its pin and its member workspaces) or an item. `key` stands for
//! everything else a node or a shell holds: two nodes are equal when their skeletons are, keys
//! included, so the caller gives equal values equal keys. Swift rebuilds its sections from the
//! skeleton the rules answer.

use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, BTreeSet};

/// A workspace, group or section id.
pub type Id = String;

/// A workspace row: a loose one or a group's member.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct Workspace {
    pub id: Id,
    /// A placeholder row no daemon knows yet (a new workspace's stand-in).
    #[serde(default, skip_serializing_if = "is_false")]
    pub pending: bool,
    /// The rest of the row's content: equal rows carry equal keys.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub key: Option<String>,
}

/// A group and the workspaces it lists.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct Group {
    pub id: Id,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub parent: Option<Id>,
    #[serde(default, skip_serializing_if = "is_false")]
    pub pinned: bool,
    #[serde(default)]
    pub workspaces: Vec<Workspace>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub key: Option<String>,
}

/// One node of a section.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Node {
    Workspace(Workspace),
    Group(Group),
    Item {
        id: Id,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        key: Option<String>,
    },
}

impl Node {
    /// The workspaces this node lists: itself, a group's members, or none.
    fn workspaces(&self) -> &[Workspace] {
        match self {
            Node::Workspace(workspace) => std::slice::from_ref(workspace),
            Node::Group(group) => &group.workspaces,
            Node::Item { .. } => &[],
        }
    }

    /// The workspace of a loose workspace node; none for a group or an item.
    fn loose_workspace_id(&self) -> Option<&str> {
        match self {
            Node::Workspace(workspace) => Some(&workspace.id),
            _ => None,
        }
    }

    fn is_pinned_group(&self) -> bool {
        matches!(self, Node::Group(group) if group.pinned)
    }
}

/// A top-level section.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct Section {
    #[serde(default)]
    pub id: Id,
    /// The Pinned section (Swift's `.pinned` kind).
    #[serde(default, skip_serializing_if = "is_false")]
    pub pinned: bool,
    /// The rest of the section's shell (title, collapse, machine): equal shells carry equal keys.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub key: Option<String>,
    #[serde(default)]
    pub nodes: Vec<Node>,
}

impl Section {
    fn workspaces(&self) -> impl Iterator<Item = &Workspace> {
        self.nodes.iter().flat_map(Node::workspaces)
    }

    fn same_shell(&self, other: &Section) -> bool {
        self.id == other.id && self.pinned == other.pinned && self.key == other.key
    }

    /// This section with its pinned groups first, in their order; everything else keeps its order.
    fn pinned_groups_first(mut self) -> Section {
        if self.nodes.iter().any(Node::is_pinned_group) {
            let (pinned, rest): (Vec<Node>, Vec<Node>) =
                self.nodes.into_iter().partition(Node::is_pinned_group);
            self.nodes = pinned.into_iter().chain(rest).collect();
        }
        self
    }

    /// The section with each loose workspace `keep` refuses taken out and each group's members
    /// filtered the same way; items stay.
    fn keeping(mut self, keep: impl Fn(&Workspace) -> bool) -> Section {
        self.nodes.retain(|node| match node {
            Node::Workspace(workspace) => keep(workspace),
            _ => true,
        });
        for node in &mut self.nodes {
            if let Node::Group(group) = node {
                group.workspaces.retain(&keep);
            }
        }
        self
    }
}

fn is_false(value: &bool) -> bool {
    !*value
}

/// The groups for which `holds` is true, with every group above one.
fn holding<'a>(groups: &[&'a Group], holds: impl Fn(&Group) -> bool) -> BTreeSet<&'a str> {
    let mut parents: BTreeMap<&str, Option<&str>> = BTreeMap::new();
    for group in groups {
        parents.entry(group.id.as_str()).or_insert(group.parent.as_deref());
    }
    let mut result = BTreeSet::new();
    for group in groups.iter().filter(|group| holds(group)) {
        let mut id = Some(group.id.as_str());
        while let Some(current) = id {
            if !result.insert(current) {
                break;
            }
            id = parents.get(current).copied().flatten();
        }
    }
    result
}

/// `sections` with only `members`' workspaces. A group stays when it, or a group under it, holds a
/// member here, or when none of its tree holds a workspace at all; a group whose workspaces only
/// another window lists leaves. Section headers always stay.
pub fn filter(sections: Vec<Section>, members: &BTreeSet<Id>) -> Vec<Section> {
    let groups: Vec<&Group> = sections
        .iter()
        .flat_map(|section| &section.nodes)
        .filter_map(|node| match node {
            Node::Group(group) => Some(group),
            _ => None,
        })
        .collect();
    let anywhere: BTreeSet<Id> = holding(&groups, |group| !group.workspaces.is_empty())
        .into_iter()
        .map(Into::into)
        .collect();
    let here: BTreeSet<Id> =
        holding(&groups, |group| group.workspaces.iter().any(|ws| members.contains(&ws.id)))
            .into_iter()
            .map(Into::into)
            .collect();
    sections
        .into_iter()
        .map(|mut section| {
            section.nodes.retain(|node| match node {
                Node::Workspace(workspace) => members.contains(&workspace.id),
                Node::Group(group) => here.contains(&group.id) || !anywhere.contains(&group.id),
                Node::Item { .. } => true,
            });
            section.keeping(|workspace| members.contains(&workspace.id))
        })
        .collect()
}

/// `sections` with the `pinned` workspaces moved, in sidebar order, into a Pinned section at the
/// top (appended to the one there is). Groups stay in their section; a pinned group lists first in
/// its section. No pinned workspace, no Pinned section.
pub fn pinned_first(sections: Vec<Section>, pinned: &BTreeSet<Id>) -> Vec<Section> {
    let sections: Vec<Section> = sections.into_iter().map(Section::pinned_groups_first).collect();
    let moving: Vec<Node> = sections
        .iter()
        .flat_map(Section::workspaces)
        .filter(|ws| pinned.contains(&ws.id))
        .cloned()
        .map(Node::Workspace)
        .collect();
    if moving.is_empty() {
        return sections;
    }
    let mut result: Vec<Section> = sections
        .into_iter()
        .map(|section| section.keeping(|workspace| !pinned.contains(&workspace.id)))
        .collect();
    match result.iter_mut().find(|section| section.pinned) {
        Some(section) => section.nodes.extend(moving),
        None => result.insert(0, Section { pinned: true, nodes: moving, ..Section::default() }),
    }
    result
}

/// `sections` without the `hidden` workspaces (the top region shows them). Groups stay.
pub fn hiding(sections: Vec<Section>, hidden: &BTreeSet<Id>) -> Vec<Section> {
    if hidden.is_empty() {
        return sections;
    }
    sections.into_iter().map(|section| section.keeping(|ws| !hidden.contains(&ws.id))).collect()
}

/// `sections` without placeholder rows, which no daemon knows.
pub fn without_placeholders(sections: Vec<Section>) -> Vec<Section> {
    sections.into_iter().map(|section| section.keeping(|ws| !ws.pending)).collect()
}

/// The listed workspaces, top to bottom; a workspace listed twice counts once, at its first place.
pub fn workspace_order(sections: &[Section]) -> Vec<Id> {
    let mut seen = BTreeSet::new();
    sections
        .iter()
        .flat_map(Section::workspaces)
        .filter(|ws| seen.insert(ws.id.as_str()))
        .map(|ws| ws.id.clone())
        .collect()
}

/// `members` with the ones `order` lists put in its order, each in a slot a listed member held; a
/// member it does not list keeps its slot.
pub fn ordering(order: &[Id], members: &[Id]) -> Vec<Id> {
    let mut positions: BTreeMap<&str, usize> = BTreeMap::new();
    for (at, id) in order.iter().enumerate() {
        positions.entry(id.as_str()).or_insert(at);
    }
    let mut slots = Vec::new();
    let mut listed = Vec::new();
    for (slot, id) in members.iter().enumerate() {
        if let Some(position) = positions.get(id.as_str()) {
            slots.push(slot);
            listed.push((*position, id));
        }
    }
    listed.sort_by_key(|(position, _)| *position);
    let mut ordered = members.to_vec();
    for (slot, (_, id)) in slots.into_iter().zip(listed) {
        ordered[slot] = id.clone();
    }
    ordered
}

/// Where in `sections` one node sits: its section and node index.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
pub struct Place {
    pub section: usize,
    pub node: usize,
}

/// Where `new` adds one loose workspace node to `old` with nothing else changed. None for any other
/// change. One compare per node.
pub fn loose_insertion(old: &[Section], new: &[Section]) -> Option<Place> {
    if old.len() != new.len() {
        return None;
    }
    let mut found = None;
    for (s, (before, after)) in old.iter().zip(new).enumerate() {
        if before == after {
            continue;
        }
        if found.is_some()
            || after.nodes.len() != before.nodes.len() + 1
            || !before.same_shell(after)
        {
            return None;
        }
        let (before, after) = (&before.nodes, &after.nodes);
        // The first node that differs is the new one; every node after it is the old one before it.
        let k = (0..before.len()).find(|&i| before[i] != after[i]).unwrap_or(before.len());
        if !matches!(after[k], Node::Workspace(_)) || after[k + 1..] != before[k..] {
            return None;
        }
        found = Some(Place { section: s, node: k });
    }
    found
}

/// Where `new` takes one loose workspace node out of `old` with nothing else changed: its place in `old`.
pub fn loose_removal(old: &[Section], new: &[Section]) -> Option<Place> {
    loose_insertion(new, old)
}

/// One loose workspace node moved: the sections with it taken out, where it left `old` and where
/// it went in `new`.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub struct Move {
    pub middle: Vec<Section>,
    pub removal: Place,
    pub insertion: Place,
}

/// Where `new` moves one loose workspace node of `old` (in its section or to another), with nothing
/// else changed. None for any other change.
pub fn loose_move(old: &[Section], new: &[Section]) -> Option<Move> {
    if old.len() != new.len() {
        return None;
    }
    let changed: Vec<usize> = (0..old.len()).filter(|&s| old[s] != new[s]).collect();
    if changed.len() != 1 && changed.len() != 2 {
        return None;
    }
    for &s in changed.iter().filter(|&&s| old[s].nodes.len() >= new[s].nodes.len()) {
        let (before, after) = (&old[s].nodes, &new[s].nodes);
        // The moved node is where the nodes first differ (it moved down) or last differ (it moved up).
        let first = (0..before.len()).find(|&i| i >= after.len() || before[i] != after[i]);
        let (mut i, mut j) = (before.len() as isize - 1, after.len() as isize - 1);
        while i >= 0 && j >= 0 && before[i as usize] == after[j as usize] {
            i -= 1;
            j -= 1;
        }
        let last = (i >= 0).then_some(i as usize);
        let mut candidates: Vec<usize> = Vec::new();
        for k in [first, last].into_iter().flatten() {
            if !candidates.contains(&k) {
                candidates.push(k);
            }
        }
        for k in candidates {
            let Node::Workspace(moved) = &before[k] else { continue };
            let mut middle = old.to_vec();
            middle[s].nodes.remove(k);
            let Some(added) = loose_insertion(&middle, new) else { continue };
            let Node::Workspace(back) = &new[added.section].nodes[added.node] else { continue };
            if back.id != moved.id {
                continue;
            }
            return Some(Move { middle, removal: Place { section: s, node: k }, insertion: added });
        }
    }
    None
}

/// One changed section of a set of loose edits: the node indices taken out (in `old`) and added
/// (in `new`), ascending.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub struct Edit {
    pub section: usize,
    pub removed: Vec<usize>,
    pub inserted: Vec<usize>,
}

/// Where `new` only takes loose workspace nodes out of `old` and adds others, every other node equal
/// and in the same order. None for any other change, or when nothing changed.
pub fn loose_edits(old: &[Section], new: &[Section]) -> Option<Vec<Edit>> {
    if old.len() != new.len() {
        return None;
    }
    let mut edits = Vec::new();
    for (s, (old_section, new_section)) in old.iter().zip(new).enumerate() {
        if old_section == new_section {
            continue;
        }
        if !old_section.same_shell(new_section) {
            return None;
        }
        let (before, after) = (&old_section.nodes, &new_section.nodes);
        let before_ids: BTreeSet<&str> =
            before.iter().filter_map(Node::loose_workspace_id).collect();
        let after_ids: BTreeSet<&str> = after.iter().filter_map(Node::loose_workspace_id).collect();
        let (mut i, mut j) = (0, 0);
        let (mut removed, mut inserted) = (Vec::new(), Vec::new());
        while i < before.len() || j < after.len() {
            if i < before.len() && j < after.len() && before[i] == after[j] {
                i += 1;
                j += 1;
            } else if let Some(id) = before.get(i).and_then(Node::loose_workspace_id)
                && !after_ids.contains(id)
            {
                removed.push(i);
                i += 1;
            } else if let Some(id) = after.get(j).and_then(Node::loose_workspace_id)
                && !before_ids.contains(id)
            {
                inserted.push(j);
                j += 1;
            } else {
                return None;
            }
        }
        edits.push(Edit { section: s, removed, inserted });
    }
    (!edits.is_empty()).then_some(edits)
}

/// One `sidebar_sections` request, tagged by `op`.
#[derive(Debug, Deserialize)]
#[serde(tag = "op", rename_all = "snake_case")]
pub enum Request {
    /// `{sections}`.
    Filter { sections: Vec<Section>, members: BTreeSet<Id> },
    /// `{sections}`.
    PinnedFirst { sections: Vec<Section>, pinned: BTreeSet<Id> },
    /// `{sections}`.
    Hiding { sections: Vec<Section>, hidden: BTreeSet<Id> },
    /// `{sections}`.
    WithoutPlaceholders { sections: Vec<Section> },
    /// `{ids}`.
    WorkspaceOrder { sections: Vec<Section> },
    /// `{members}`: `members` in the order of `sections` (or of `order`, when given).
    Ordering {
        #[serde(default)]
        sections: Vec<Section>,
        #[serde(default)]
        order: Option<Vec<Id>>,
        members: Vec<Id>,
    },
    /// `{section, node}` or null.
    LooseInsertion { old: Vec<Section>, new: Vec<Section> },
    /// `{section, node}` or null.
    LooseRemoval { old: Vec<Section>, new: Vec<Section> },
    /// `{middle, removal, insertion}` or null.
    LooseMove { old: Vec<Section>, new: Vec<Section> },
    /// `{edits: [{section, removed, inserted}]}` or null.
    LooseEdits { old: Vec<Section>, new: Vec<Section> },
}

/// Answers one request.
pub fn respond(request: Request) -> serde_json::Value {
    use serde_json::json;
    match request {
        Request::Filter { sections, members } => json!({"sections": filter(sections, &members)}),
        Request::PinnedFirst { sections, pinned } => {
            json!({"sections": pinned_first(sections, &pinned)})
        }
        Request::Hiding { sections, hidden } => json!({"sections": hiding(sections, &hidden)}),
        Request::WithoutPlaceholders { sections } => {
            json!({"sections": without_placeholders(sections)})
        }
        Request::WorkspaceOrder { sections } => json!({"ids": workspace_order(&sections)}),
        Request::Ordering { sections, order, members } => {
            let order = order.unwrap_or_else(|| workspace_order(&sections));
            json!({"members": ordering(&order, &members)})
        }
        Request::LooseInsertion { old, new } => json!(loose_insertion(&old, &new)),
        Request::LooseRemoval { old, new } => json!(loose_removal(&old, &new)),
        Request::LooseMove { old, new } => json!(loose_move(&old, &new)),
        Request::LooseEdits { old, new } => match loose_edits(&old, &new) {
            Some(edits) => json!({"edits": edits}),
            None => serde_json::Value::Null,
        },
    }
}

#[cfg(test)]
#[path = "sidebar_sections_tests.rs"]
mod tests;
