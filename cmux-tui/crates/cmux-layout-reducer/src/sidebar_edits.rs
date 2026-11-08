//! The macOS sidebar's tree edits: what a structural intent (a drop, a
//! keyboard move, a pin, a new or closed group) does to the sections the
//! window shows, before the daemon's echo. The app runs them on its pending
//! edits (`SidebarPendingEdits`), a drag's in-place preview and the
//! standalone sidebar (`SidebarModel.apply` with no intent handler).
//!
//! The app sends a skeleton of its sections (ids, machines, a group's
//! members and flags) over `cmux_layout_reducer_json` op `sidebar_edits`
//! and rebuilds its rows from the reply by id; row content never crosses.
//! A group's `members` list its workspace and item rows in drawn order; an
//! item is named by the app's own `ref` (item ids need not be unique).
//!
//! A workspace's `creator` links it under the workspace that made it (an
//! agent's or a script's); `creator` keeps every edit inside that tree and
//! `tree` draws it (depth, guide lines, collapsed count).
//!
//! Also here: the keyboard reorder's next slot ([`keyboard_target`]), the
//! group ordering verbs' index ([`group_index`]), the named-group rules
//! (`names`) and one window's placement mapped to the daemon's order
//! (`placement`).

use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, HashSet};

mod creator;
#[cfg(test)]
mod creator_tests;
mod names;
mod order;
mod placement;
#[cfg(test)]
mod tests;
pub mod tree;

pub use names::{
    NamedGroup, NamedRow, group_named, predecessor, same_group_name, valid_group_name,
};
pub use order::{
    Direction, GroupMove, can_move, group_index, groups_toggled_by_collapsing_others,
    joinable_groups, keyboard_target,
};
pub use placement::{PersonalPlacement, global_index, personal_placements};

/// A section of the sidebar: Pinned, a machine's list, or a document section.
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum SectionId {
    Pinned,
    Machine { id: String },
    Custom { id: String },
}

impl SectionId {
    fn machine(&self) -> Option<&str> {
        match self {
            SectionId::Machine { id } => Some(id),
            SectionId::Pinned | SectionId::Custom { .. } => None,
        }
    }
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct Workspace {
    pub id: String,
    pub machine: String,
    /// The public id of the workspace that made this one: it lists right
    /// after that one's subtree, in its group or section.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub creator: Option<String>,
    /// Its children are hidden behind a count.
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub collapsed_children: bool,
}

/// A group member row: a workspace, or a link, tab or app item.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum Member {
    Workspace { workspace: Workspace },
    Item { r#ref: u32 },
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Group {
    pub id: String,
    #[serde(default)]
    pub name: String,
    #[serde(default)]
    pub parent: Option<String>,
    #[serde(default)]
    pub pinned: bool,
    #[serde(default)]
    pub collapsed: bool,
    #[serde(default)]
    pub members: Vec<Member>,
}

impl Group {
    fn workspaces(&self) -> impl Iterator<Item = &Workspace> {
        self.members.iter().filter_map(|member| match member {
            Member::Workspace { workspace } => Some(workspace),
            Member::Item { .. } => None,
        })
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum Node {
    Workspace { workspace: Workspace },
    Group { group: Group },
    Item { r#ref: u32 },
}

impl Node {
    fn group_id(&self) -> Option<&str> {
        match self {
            Node::Group { group } => Some(&group.id),
            Node::Workspace { .. } | Node::Item { .. } => None,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Section {
    pub id: SectionId,
    #[serde(default)]
    pub collapsed: bool,
    #[serde(default)]
    pub nodes: Vec<Node>,
}

impl Section {
    fn workspaces(&self) -> impl Iterator<Item = &Workspace> {
        self.nodes.iter().flat_map(|node| -> Box<dyn Iterator<Item = &Workspace> + '_> {
            match node {
                Node::Workspace { workspace } => Box::new(std::iter::once(workspace)),
                Node::Group { group } => Box::new(group.workspaces()),
                Node::Item { .. } => Box::new(std::iter::empty()),
            }
        })
    }
}

/// An insertion slot: a section's top level, or inside a group (its index
/// counts the group's member rows, items included).
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct Position {
    pub section: SectionId,
    #[serde(default)]
    pub group: Option<String>,
    pub index: i64,
}

/// The structural intents. A field-only intent (a rename, a color, an icon)
/// is the app's own write and never comes here.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum Intent {
    Reorder {
        ids: Vec<String>,
        position: Position,
    },
    Move {
        ids: Vec<String>,
        group: String,
    },
    ReorderGroup {
        group: String,
        index: i64,
    },
    CreateGroup {
        id: String,
        ids: Vec<String>,
        #[serde(default)]
        anchor: Option<String>,
        #[serde(default)]
        collapsed: bool,
        #[serde(default)]
        index: Option<i64>,
    },
    Ungroup {
        group: String,
    },
    CloseGroup {
        group: String,
    },
    Close {
        ids: Vec<String>,
    },
    SetPinned {
        ids: Vec<String>,
        pinned: bool,
    },
    SetGroupPinned {
        group: String,
        pinned: bool,
    },
    ToggleSection {
        section: SectionId,
    },
    ToggleGroup {
        group: String,
    },
    /// Breaks the creator links of `ids`; each lists after its old creator's subtree.
    Detach {
        ids: Vec<String>,
    },
    /// Links `ids` under `creator`, right after its subtree in its group or section.
    Attach {
        ids: Vec<String>,
        creator: String,
    },
    /// Hides or shows a creator's children.
    ToggleChildren {
        id: String,
    },
}

/// Where a workspace sits: its section, its node, and its index among a
/// group's workspaces (None for a loose workspace).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Location {
    pub section: usize,
    pub node: usize,
    pub child: Option<usize>,
}

/// One edit: `intent` on `sections`. `prunes` false keeps a group the move
/// empties (a drag's shown result: an emptied group is still a drop target).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct EditRequest {
    pub sections: Vec<Section>,
    pub intent: Intent,
    #[serde(default = "default_true")]
    pub prunes: bool,
}

fn default_true() -> bool {
    true
}

/// The edit's result. `changed`: the intent was accepted and changed the
/// tree (false for a refused one or one that leaves the tree as it was, as a
/// flag set to its own value; `changed` implies `sections`). `sections`: the new tree, or None when it is the
/// request's (a refused edit may still have changed it, as a pin that added
/// an empty Pinned section).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct EditReply {
    pub changed: bool,
    pub sections: Option<Vec<Section>>,
}

/// Runs one edit (`EditRequest`).
pub fn edit(request: &EditRequest) -> EditReply {
    let mut sections = request.sections.clone();
    let applied = apply_with(&request.intent, &mut sections, request.prunes);
    let sections = (sections != request.sections).then_some(sections);
    // An accepted intent that leaves the tree as it was (a flag set to its own value) changed nothing.
    EditReply { changed: applied && sections.is_some(), sections }
}

/// Applies an intent. False when it was refused or had no structural effect.
pub fn apply(intent: &Intent, sections: &mut Vec<Section>) -> bool {
    apply_with(intent, sections, true)
}

fn apply_with(intent: &Intent, sections: &mut Vec<Section>, prunes: bool) -> bool {
    let listed = creator::listed(sections);
    if !apply_intent(intent, sections, prunes) {
        return false;
    }
    creator::settle(sections, &listed, intent);
    true
}

fn apply_intent(intent: &Intent, sections: &mut Vec<Section>, prunes: bool) -> bool {
    match intent {
        Intent::Reorder { ids, position } => reorder(ids, position, sections, prunes),
        Intent::Move { ids, group } => move_to_group(ids, group, sections),
        Intent::ReorderGroup { group, index } => reorder_group(group, *index, sections),
        Intent::CreateGroup { id, ids, anchor, collapsed, index } => {
            if !create_group(id, ids, anchor.as_deref(), *index, sections) {
                return false;
            }
            if *collapsed {
                mutate_group(id, sections, |group| group.collapsed = true);
            }
            true
        }
        Intent::Ungroup { group } => ungroup(group, sections),
        Intent::CloseGroup { group } => close_group(group, sections),
        // Closing a member never closes its group; keep the header's identity and position.
        Intent::Close { ids } => {
            !remove_workspaces(&ids.iter().map(String::as_str).collect(), sections).is_empty()
        }
        Intent::SetPinned { ids, pinned } => set_pinned(ids, *pinned, sections),
        Intent::SetGroupPinned { group, pinned } => {
            mutate_group(group, sections, |group| group.pinned = *pinned)
        }
        Intent::ToggleSection { section } => {
            let Some(found) = sections.iter_mut().find(|candidate| &candidate.id == section) else {
                return false;
            };
            found.collapsed = !found.collapsed;
            true
        }
        Intent::ToggleGroup { group } => {
            mutate_group(group, sections, |group| group.collapsed = !group.collapsed)
        }
        Intent::Detach { ids } => creator::detach(ids, sections),
        Intent::Attach { ids, creator } => creator::attach(ids, creator, sections),
        Intent::ToggleChildren { id } => creator::toggle_children(id, sections),
    }
}

/// One `sidebar_edits` call (`cmux_layout_reducer_json`): an edit or one of
/// the step and name rules, tagged by `op`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "op", rename_all = "snake_case")]
pub enum Request {
    Edit(EditRequest),
    KeyboardTarget {
        sections: Vec<Section>,
        ids: Vec<String>,
        direction: Direction,
    },
    GroupIndex {
        sections: Vec<Section>,
        group: String,
        step: GroupMove,
    },
    GroupsToggledByCollapsingOthers {
        sections: Vec<Section>,
        keeping: String,
    },
    CanMove {
        sections: Vec<Section>,
        ids: Vec<String>,
        group: String,
    },
    JoinableGroups {
        sections: Vec<Section>,
        id: String,
    },
    GroupNamed {
        sections: Vec<Section>,
        name: String,
        id: String,
        #[serde(default)]
        machine: Option<String>,
    },
    Predecessor {
        name: String,
        group: String,
        sidebars: Vec<Vec<NamedGroup>>,
    },
    ValidGroupName {
        name: String,
    },
    GlobalIndex {
        local_index: i64,
        local: Vec<String>,
        global: Vec<String>,
    },
    PersonalPlacements {
        moving: Vec<String>,
        local_index: i64,
        shown: Vec<String>,
        rowed: Vec<String>,
    },
    /// The creator tree's rows ([`tree::rows`]); `indent` is the step in points.
    Tree {
        sections: Vec<Section>,
        #[serde(default = "tree::default_indent")]
        indent: u32,
    },
}

/// Answers one request as JSON: an [`EditReply`], a position or index (null
/// for none), a list of group ids, a bool, an index, a list of placements or
/// the tree's rows.
pub fn respond(request: &Request) -> serde_json::Result<Vec<u8>> {
    match request {
        Request::Edit(edit_request) => serde_json::to_vec(&edit(edit_request)),
        Request::KeyboardTarget { sections, ids, direction } => {
            serde_json::to_vec(&keyboard_target(ids, *direction, sections))
        }
        Request::GroupIndex { sections, group, step } => {
            serde_json::to_vec(&group_index(group, *step, sections))
        }
        Request::GroupsToggledByCollapsingOthers { sections, keeping } => {
            serde_json::to_vec(&groups_toggled_by_collapsing_others(keeping, sections))
        }
        Request::CanMove { sections, ids, group } => {
            serde_json::to_vec(&can_move(ids, group, sections))
        }
        Request::JoinableGroups { sections, id } => {
            serde_json::to_vec(&joinable_groups(id, sections))
        }
        Request::GroupNamed { sections, name, id, machine } => {
            serde_json::to_vec(&group_named(name, id, sections, machine.as_deref()))
        }
        Request::Predecessor { name, group, sidebars } => {
            serde_json::to_vec(&predecessor(name, group, sidebars))
        }
        Request::ValidGroupName { name } => serde_json::to_vec(&valid_group_name(name)),
        Request::GlobalIndex { local_index, local, global } => {
            serde_json::to_vec(&global_index(*local_index, local, global))
        }
        Request::PersonalPlacements { moving, local_index, shown, rowed } => {
            serde_json::to_vec(&personal_placements(moving, *local_index, shown, rowed))
        }
        Request::Tree { sections, indent } => {
            serde_json::to_vec(&tree::TreeReply { rows: tree::rows(sections, *indent) })
        }
    }
}

// MARK: Queries

/// The first place workspace `id` is listed.
pub fn locate(id: &str, sections: &[Section]) -> Option<Location> {
    for (s, section) in sections.iter().enumerate() {
        for (n, node) in section.nodes.iter().enumerate() {
            match node {
                Node::Workspace { workspace } if workspace.id == id => {
                    return Some(Location { section: s, node: n, child: None });
                }
                Node::Group { group } => {
                    if let Some(c) = group.workspaces().position(|ws| ws.id == id) {
                        return Some(Location { section: s, node: n, child: Some(c) });
                    }
                }
                Node::Workspace { .. } | Node::Item { .. } => {}
            }
        }
    }
    None
}

pub fn workspace<'a>(id: &str, sections: &'a [Section]) -> Option<&'a Workspace> {
    let at = locate(id, sections)?;
    match sections.get(at.section)?.nodes.get(at.node)? {
        Node::Workspace { workspace } => Some(workspace),
        Node::Group { group } => group.workspaces().nth(at.child?),
        Node::Item { .. } => None,
    }
}

/// Section index and node index of a group (its first listing).
pub fn locate_group(id: &str, sections: &[Section]) -> Option<(usize, usize)> {
    sections.iter().enumerate().find_map(|(s, section)| {
        section.nodes.iter().position(|node| node.group_id() == Some(id)).map(|n| (s, n))
    })
}

/// The slot workspace `id` occupies now, in "after removal" coordinates for
/// a block whose first item in tree order is `id`.
pub fn position_of(id: &str, sections: &[Section]) -> Option<Position> {
    let at = locate(id, sections)?;
    let section = sections.get(at.section)?;
    if at.child.is_some()
        && let Some(Node::Group { group }) = section.nodes.get(at.node)
    {
        // A group's index counts its member rows: workspaces and link, tab and app items.
        let member = group
            .members
            .iter()
            .position(
                |member| matches!(member, Member::Workspace { workspace } if workspace.id == id),
            )
            .unwrap_or(0);
        return Some(Position {
            section: section.id.clone(),
            group: Some(group.id.clone()),
            index: wire(member),
        });
    }
    Some(Position { section: section.id.clone(), group: None, index: wire(at.node) })
}

/// The given ids in visual (tree) order, without unknown ids.
pub fn tree_order(ids: &[String], sections: &[Section]) -> Vec<String> {
    let wanted: HashSet<&str> = ids.iter().map(String::as_str).collect();
    sections
        .iter()
        .flat_map(Section::workspaces)
        .filter(|ws| wanted.contains(ws.id.as_str()))
        .map(|ws| ws.id.clone())
        .collect()
}

/// Whether a workspace may live in a section: a machine's section holds only that machine's.
pub fn can_place(workspace: &Workspace, section: &Section) -> bool {
    section.id.machine().is_none_or(|machine| machine == workspace.machine)
}

// MARK: Edits

fn clamp(index: i64, count: usize) -> usize {
    usize::try_from(index.max(0)).unwrap_or(usize::MAX).min(count)
}

/// A count or index as the wire's integer.
pub(crate) fn wire(index: usize) -> i64 {
    i64::try_from(index).unwrap_or(i64::MAX)
}

fn reorder(ids: &[String], position: &Position, sections: &mut [Section], prunes: bool) -> bool {
    // A creator carries its children, as a group carries its subgroups.
    let (ids, position) = creator::carrying(ids, position, sections);
    let (ids, position) = (ids.as_slice(), &position);
    let Some(target) = sections.iter().find(|section| section.id == position.section) else {
        return false;
    };
    if position.group.is_some() && target.id.machine().is_none() {
        return false;
    }
    let ordered = tree_order(ids, sections);
    if ordered.is_empty() {
        return false;
    }
    let placeable =
        ordered.iter().filter_map(|id| workspace(id, sections)).all(|ws| can_place(ws, target));
    if !placeable {
        return false;
    }
    if let Some(group) = &position.group
        && !target.nodes.iter().any(|node| node.group_id() == Some(group))
    {
        return false;
    }
    let before = sections.to_vec();
    let removed = remove_workspaces(&ordered.iter().map(String::as_str).collect(), sections);
    insert(removed, position, sections);
    if prunes {
        prune_empty_groups(sections, position.group.as_deref(), &groups_with_members(&before));
    }
    sections != before.as_slice()
}

fn move_to_group(ids: &[String], group: &str, sections: &mut [Section]) -> bool {
    let Some((s, n)) = locate_group(group, sections) else { return false };
    let Some(section) = sections.get(s) else { return false };
    let Some(Node::Group { group: found }) = section.nodes.get(n) else { return false };
    let moving: HashSet<&str> = ids.iter().map(String::as_str).collect();
    let remaining = found
        .members
        .iter()
        .filter(|member| match member {
            Member::Workspace { workspace } => !moving.contains(workspace.id.as_str()),
            Member::Item { .. } => true,
        })
        .count();
    let position = Position {
        section: section.id.clone(),
        group: Some(group.to_owned()),
        index: wire(remaining),
    };
    reorder(ids, &position, sections, true)
}

/// Moves a group and its subgroups (listed flat after it) as one block.
/// `index` counts the section's rows with only the group itself taken out
/// (`group_index`'s coordinates), so its own subgroups before that slot
/// move the block up by their count.
fn reorder_group(group: &str, index: i64, sections: &mut [Section]) -> bool {
    let Some((s, n)) = locate_group(group, sections) else { return false };
    let Some(section) = sections.get_mut(s) else { return false };
    let mut subtree: HashSet<&str> = HashSet::from([group]);
    let mut moving = vec![false; section.nodes.len()];
    for (at, node) in section.nodes.iter().enumerate() {
        let Node::Group { group: listed } = node else { continue };
        let inside =
            at == n || listed.parent.as_deref().is_some_and(|parent| subtree.contains(parent));
        if inside && let Some(flag) = moving.get_mut(at) {
            subtree.insert(&listed.id);
            *flag = true;
        }
    }
    // The slot in the rows without the group, less the subgroups before it.
    let slot = clamp(index, section.nodes.len().saturating_sub(1));
    let staying_before = |at: usize| if at > n { at.saturating_sub(1) } else { at };
    let below = moving
        .iter()
        .enumerate()
        .filter(|(at, flag)| **flag && *at != n && staying_before(*at) < slot)
        .count();
    let before = section.nodes.clone();
    let mut block = Vec::new();
    let mut rest = Vec::new();
    for (node, flag) in std::mem::take(&mut section.nodes).into_iter().zip(moving) {
        if flag { block.push(node) } else { rest.push(node) }
    }
    let at = slot.saturating_sub(below).min(rest.len());
    rest.splice(at..at, block);
    section.nodes = rest;
    section.nodes != before
}

fn create_group(
    id: &str,
    ids: &[String],
    target: Option<&str>,
    index: Option<i64>,
    sections: &mut [Section],
) -> bool {
    let ordered = tree_order(&creator::with_subtrees(ids, sections), sections);
    // The group forms at `target` (an onto-drop's target row), else at the first workspace in tree order.
    let first = target
        .filter(|target| ordered.iter().any(|id| id == target))
        .or(ordered.first().map(String::as_str));
    let Some(first) = first else { return false };
    let Some(anchor) = locate(first, sections) else { return false };
    let s = anchor.section;
    let Some(home) = sections.get(s) else { return false };
    if home.id.machine().is_none() || locate_group(id, sections).is_some() {
        return false;
    }
    // Only workspaces from the anchor's section join. Loose members before the insertion point leave
    // it, so it moves up by their count (emptied groups stay until the prune below).
    let joining: HashSet<String> = ordered
        .iter()
        .filter(|id| locate(id, sections).map(|at| at.section) == Some(s))
        .cloned()
        .collect();
    let after = if anchor.child.is_none() { anchor.node } else { anchor.node.saturating_add(1) };
    let leaving = home
        .nodes
        .iter()
        .take(after)
        .filter(
            |node| matches!(node, Node::Workspace { workspace } if joining.contains(&workspace.id)),
        )
        .count();
    let insertion = after.saturating_sub(leaving);
    let held = groups_with_members(sections);
    let removed = remove_workspaces(&joining.iter().map(String::as_str).collect(), sections);
    let group = Group {
        id: id.to_owned(),
        name: String::new(),
        parent: None,
        pinned: false,
        collapsed: false,
        members: removed.into_iter().map(|workspace| Member::Workspace { workspace }).collect(),
    };
    let Some(home) = sections.get_mut(s) else { return false };
    let at = clamp(index.unwrap_or(wire(insertion)), home.nodes.len());
    home.nodes.insert(at, Node::Group { group });
    prune_empty_groups(sections, Some(id), &held);
    true
}

fn ungroup(id: &str, sections: &mut [Section]) -> bool {
    let Some((s, n)) = locate_group(id, sections) else { return false };
    let Some(section) = sections.get_mut(s) else { return false };
    let Node::Group { group } = section.nodes.remove(n) else { return false };
    let loose: Vec<Node> = group
        .members
        .into_iter()
        .filter_map(|member| match member {
            Member::Workspace { workspace } => Some(Node::Workspace { workspace }),
            Member::Item { .. } => None,
        })
        .collect();
    section.nodes.splice(n..n, loose);
    lift_orphans(section);
    true
}

fn close_group(id: &str, sections: &mut [Section]) -> bool {
    let Some((s, n)) = locate_group(id, sections) else { return false };
    let Some(section) = sections.get_mut(s) else { return false };
    let Some(Node::Group { group }) = section.nodes.get_mut(n) else { return false };
    if group.pinned {
        group.members.retain(|member| matches!(member, Member::Item { .. }));
        group.collapsed = true;
    } else {
        section.nodes.remove(n);
        lift_orphans(section);
    }
    true
}

fn set_pinned(ids: &[String], pinned: bool, sections: &mut Vec<Section>) -> bool {
    let ordered = tree_order(ids, sections);
    if ordered.is_empty() {
        return false;
    }
    if pinned {
        if !sections.iter().any(|section| section.id == SectionId::Pinned) {
            sections
                .insert(0, Section { id: SectionId::Pinned, collapsed: false, nodes: Vec::new() });
        }
        let Some(pinned) = sections.iter().find(|section| section.id == SectionId::Pinned) else {
            return false;
        };
        let moving: HashSet<&str> = ordered.iter().map(String::as_str).collect();
        let remaining = pinned
            .nodes
            .iter()
            .filter(|node| !matches!(node, Node::Workspace { workspace } if moving.contains(workspace.id.as_str())))
            .count();
        let position = Position { section: SectionId::Pinned, group: None, index: wire(remaining) };
        return reorder(&ordered, &position, sections, true);
    }
    let Some(pinned) = sections.iter().find(|section| section.id == SectionId::Pinned) else {
        return false;
    };
    let pinned_ids: HashSet<&str> = pinned.workspaces().map(|ws| ws.id.as_str()).collect();
    // Every pinned id resolves to its workspace; one that does not stays where it is.
    let mut by_machine: BTreeMap<String, Vec<String>> = BTreeMap::new();
    for id in ordered.iter().filter(|id| pinned_ids.contains(id.as_str())) {
        if let Some(ws) = workspace(id, sections) {
            by_machine.entry(ws.machine.clone()).or_default().push(id.clone());
        }
    }
    let mut changed = false;
    for (machine, ids) in by_machine {
        let position =
            Position { section: SectionId::Machine { id: machine }, group: None, index: 0 };
        changed = reorder(&ids, &position, sections, true) || changed;
    }
    changed
}

// MARK: Primitives

/// Removes workspaces and returns them in tree order. Emptied groups stay so
/// section-level indices computed before the removal stay valid.
pub fn remove_workspaces(ids: &HashSet<&str>, sections: &mut [Section]) -> Vec<Workspace> {
    let mut removed = Vec::new();
    for section in sections.iter_mut() {
        let nodes = std::mem::take(&mut section.nodes);
        for node in nodes {
            match node {
                Node::Workspace { workspace } if ids.contains(workspace.id.as_str()) => {
                    removed.push(workspace);
                }
                Node::Group { mut group } => {
                    // The link, tab and app members keep their rows.
                    let members = std::mem::take(&mut group.members);
                    for member in members {
                        match member {
                            Member::Workspace { workspace }
                                if ids.contains(workspace.id.as_str()) =>
                            {
                                removed.push(workspace);
                            }
                            other => group.members.push(other),
                        }
                    }
                    section.nodes.push(Node::Group { group });
                }
                other => section.nodes.push(other),
            }
        }
    }
    removed
}

/// Inserts workspaces at `position` (clamped); a missing section or group
/// takes them at the section's top level, as the app always did.
pub fn insert(workspaces: Vec<Workspace>, position: &Position, sections: &mut [Section]) {
    let Some(section) = sections.iter_mut().find(|section| section.id == position.section) else {
        return;
    };
    if let Some(group) = &position.group
        && let Some(Node::Group { group }) =
            section.nodes.iter_mut().find(|node| node.group_id() == Some(group.as_str()))
    {
        // The index counts member rows (workspaces and link, tab and app items).
        let at = clamp(position.index, group.members.len());
        group.members.splice(
            at..at,
            workspaces.into_iter().map(|workspace| Member::Workspace { workspace }),
        );
        return;
    }
    let at = clamp(position.index, section.nodes.len());
    section
        .nodes
        .splice(at..at, workspaces.into_iter().map(|workspace| Node::Workspace { workspace }));
}

/// Drops the groups a move or close left empty: those of `emptied_from` (the
/// groups that held a row before it) that hold none now. A group that was
/// already empty (a kept group with no open workspace) stays: its header is
/// still a row and a drop target (Leo 2026-10-20: collapsed groups vanished
/// while a row was dragged).
fn prune_empty_groups(
    sections: &mut [Section],
    keeping: Option<&str>,
    emptied_from: &HashSet<String>,
) {
    for section in sections.iter_mut() {
        section.nodes.retain(|node| match node {
            Node::Group { group } => {
                !(group.members.is_empty()
                    && !group.pinned
                    && Some(group.id.as_str()) != keeping
                    && emptied_from.contains(&group.id))
            }
            Node::Workspace { .. } | Node::Item { .. } => true,
        });
        lift_orphans(section);
    }
}

/// A subgroup whose parent left its section (pruned, closed or ungrouped)
/// lists at the top level, as the app's depth pass draws it
/// (`resolvingGroupDepths`), instead of naming a group that is gone.
fn lift_orphans(section: &mut Section) {
    let listed: HashSet<String> =
        section.nodes.iter().filter_map(|node| node.group_id().map(str::to_owned)).collect();
    for node in &mut section.nodes {
        if let Node::Group { group } = node
            && group.parent.as_ref().is_some_and(|parent| !listed.contains(parent))
        {
            group.parent = None;
        }
    }
}

/// The groups that list at least one row (a workspace or an item).
fn groups_with_members(sections: &[Section]) -> HashSet<String> {
    sections
        .iter()
        .flat_map(|section| &section.nodes)
        .filter_map(|node| match node {
            Node::Group { group } if !group.members.is_empty() => Some(group.id.clone()),
            _ => None,
        })
        .collect()
}

fn mutate_group(id: &str, sections: &mut [Section], body: impl FnOnce(&mut Group)) -> bool {
    let Some((s, n)) = locate_group(id, sections) else { return false };
    let Some(Node::Group { group }) =
        sections.get_mut(s).and_then(|section| section.nodes.get_mut(n))
    else {
        return false;
    };
    body(group);
    true
}
