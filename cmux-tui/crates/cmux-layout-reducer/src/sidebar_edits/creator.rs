//! The creator link (`Workspace.creator`): a workspace an agent or a script
//! made lists right after the subtree of the workspace that made it, in the
//! same container (a section's top level or a group's members). Rows stay
//! flat; the tree is derived from the links and the order, and every edit
//! keeps each child inside its creator's subtree:
//!
//! - Moving a creator carries its children, as a group move carries its
//!   subgroups; the keyboard steps over a whole subtree.
//! - Moving a child out of its creator's subtree, group or section breaks
//!   its link, as `Detach` does.
//! - Closing a creator breaks its children's links, as a gone parent group
//!   lifts its subgroups (`lift_orphans`).
//! - A link whose creator lists elsewhere (another group, or a window that
//!   does not show it) is kept but draws flat; one that loops draws as a root.
//!
//! A creator is the workspace with the creator id on the child's own machine:
//! ids may repeat across machines (Pinned and custom sections hold several),
//! and a workspace's creator runs on its machine.

use super::{
    Intent, Location, Member, Node, Position, Section, SectionId, Workspace, can_place,
    remove_workspaces, tree_order, wire, workspace,
};
use std::collections::{HashMap, HashSet};

/// A container row: its workspace, or None for a group or an item.
pub(super) type Link<'a> = Option<&'a Workspace>;

/// A section's top-level node or a group's member.
pub(super) trait Row {
    fn workspace(&self) -> Option<&Workspace>;
    fn workspace_mut(&mut self) -> Option<&mut Workspace>;
}

impl Row for Node {
    fn workspace(&self) -> Option<&Workspace> {
        match self {
            Node::Workspace { workspace } => Some(workspace),
            Node::Group { .. } | Node::Item { .. } => None,
        }
    }

    fn workspace_mut(&mut self) -> Option<&mut Workspace> {
        match self {
            Node::Workspace { workspace } => Some(workspace),
            Node::Group { .. } | Node::Item { .. } => None,
        }
    }
}

impl Row for Member {
    fn workspace(&self) -> Option<&Workspace> {
        match self {
            Member::Workspace { workspace } => Some(workspace),
            Member::Item { .. } => None,
        }
    }

    fn workspace_mut(&mut self) -> Option<&mut Workspace> {
        match self {
            Member::Workspace { workspace } => Some(workspace),
            Member::Item { .. } => None,
        }
    }
}

fn links<R: Row>(rows: &[R]) -> Vec<Link<'_>> {
    rows.iter().map(Row::workspace).collect()
}

/// Whether `ws` is the creator `child` names.
fn creates(ws: &Workspace, child: &Workspace) -> bool {
    child.creator.as_deref() == Some(ws.id.as_str()) && ws.machine == child.machine
}

/// Each row's parent in its container: its creator's row when the creator
/// lists there too. A row on a loop of links has none.
pub(super) fn parents(links: &[Link<'_>]) -> Vec<Option<usize>> {
    let mut index: HashMap<(&str, &str), usize> = HashMap::new();
    for (at, ws) in links.iter().enumerate() {
        if let Some(ws) = ws {
            index.entry((ws.id.as_str(), ws.machine.as_str())).or_insert(at);
        }
    }
    let mut parents: Vec<Option<usize>> = links
        .iter()
        .map(|ws| {
            let ws = (*ws)?;
            index.get(&(ws.creator.as_deref()?, ws.machine.as_str())).copied()
        })
        .collect();
    // 0: not walked; 1: on the current walk; 2: settled.
    let mut state = vec![0u8; links.len()];
    for start in 0..links.len() {
        let mut path = Vec::new();
        let mut at = Some(start);
        while let Some(row) = at {
            if state.get(row).copied() != Some(0) {
                break;
            }
            if let Some(flag) = state.get_mut(row) {
                *flag = 1;
            }
            path.push(row);
            at = parents.get(row).copied().flatten();
        }
        // The walk came back to a row of its own: those rows form a loop, and each is a root.
        if let Some(row) = at
            && state.get(row).copied() == Some(1)
            && let Some(from) = path.iter().position(|&walked| walked == row)
        {
            for &looped in path.get(from..).unwrap_or_default() {
                if let Some(parent) = parents.get_mut(looped) {
                    *parent = None;
                }
            }
        }
        for &walked in &path {
            if let Some(flag) = state.get_mut(walked) {
                *flag = 2;
            }
        }
    }
    parents
}

/// How a container's rows nest as listed: a row sits under its creator only
/// while the creator's subtree runs on to it.
pub(super) struct Nesting {
    /// Each workspace row's depth (None for a group or an item).
    pub depth: Vec<Option<usize>>,
    /// The row after each row's subtree.
    pub end: Vec<usize>,
}

pub(super) fn nesting(links: &[Link<'_>], parents: &[Option<usize>]) -> Nesting {
    let count = links.len();
    let mut depth: Vec<Option<usize>> = vec![None; count];
    let mut end: Vec<usize> = vec![count; count];
    let mut open: Vec<usize> = Vec::new();
    for (at, (link, parent)) in links.iter().zip(parents).enumerate() {
        // Rows stay open while the next one lists under them; a group or an item closes all.
        let keep = match (link, parent) {
            (Some(_), Some(parent)) => {
                open.iter().rposition(|row| row == parent).map_or(0, |p| p + 1)
            }
            _ => 0,
        };
        for closed in open.drain(keep..) {
            if let Some(row_end) = end.get_mut(closed) {
                *row_end = at;
            }
        }
        if link.is_some() {
            if let Some(row_depth) = depth.get_mut(at) {
                *row_depth = Some(open.len());
            }
            open.push(at);
        }
    }
    Nesting { depth, end }
}

fn children(parents: &[Option<usize>]) -> Vec<Vec<usize>> {
    let mut children = vec![Vec::new(); parents.len()];
    for (row, parent) in parents.iter().enumerate() {
        if let Some(list) = parent.and_then(|parent| children.get_mut(parent)) {
            list.push(row);
        }
    }
    children
}

/// The rows under `root`, in their listed order (pre-order), without it.
fn subtree(root: usize, children: &[Vec<usize>]) -> Vec<usize> {
    let mut out = Vec::new();
    let mut stack: Vec<usize> =
        children.get(root).map(|list| list.iter().rev().copied().collect()).unwrap_or_default();
    while let Some(row) = stack.pop() {
        out.push(row);
        stack.extend(children.get(row).into_iter().flatten().rev());
    }
    out
}

/// The container's order with every child right after its creator's
/// subtree: roots keep their order, children theirs among their siblings.
fn tree_sorted(parents: &[Option<usize>]) -> Vec<usize> {
    let children = children(parents);
    let mut order = Vec::with_capacity(parents.len());
    for root in (0..parents.len()).filter(|&row| parents.get(row) == Some(&None)) {
        order.push(root);
        order.extend(subtree(root, &children));
    }
    order
}

/// Every container of the tree: each section's top level and each group's
/// members.
fn containers(sections: &[Section]) -> Vec<Vec<Link<'_>>> {
    let mut out = Vec::new();
    for section in sections {
        out.push(links(&section.nodes));
        for node in &section.nodes {
            if let Node::Group { group } = node {
                out.push(links(&group.members));
            }
        }
    }
    out
}

/// The container a slot names: a section's top level or a group's members.
fn container<'a>(
    sections: &'a [Section],
    section: &SectionId,
    group: Option<&str>,
) -> Vec<Link<'a>> {
    let Some(section) = sections.iter().find(|candidate| &candidate.id == section) else {
        return Vec::new();
    };
    let Some(group) = group else { return links(&section.nodes) };
    section
        .nodes
        .iter()
        .find_map(|node| match node {
            Node::Group { group: found } if found.id == group => Some(links(&found.members)),
            _ => None,
        })
        .unwrap_or_default()
}

/// Every listed workspace, as (id, machine).
pub(super) fn listed(sections: &[Section]) -> HashSet<(String, String)> {
    sections
        .iter()
        .flat_map(Section::workspaces)
        .map(|ws| (ws.id.clone(), ws.machine.clone()))
        .collect()
}

/// The rows each of `named` carries along: its subtree in its container,
/// those `keep` accepts, without the named ones, in tree order.
fn carried(
    named: &HashSet<&str>,
    sections: &[Section],
    keep: impl Fn(&Workspace) -> bool,
) -> Vec<String> {
    let mut out: Vec<String> = Vec::new();
    let mut seen: HashSet<&str> = HashSet::new();
    for links in containers(sections) {
        let children = children(&parents(&links));
        for (row, link) in links.iter().enumerate() {
            if !link.is_some_and(|ws| named.contains(ws.id.as_str())) {
                continue;
            }
            for under in subtree(row, &children) {
                if let Some(Some(ws)) = links.get(under)
                    && !named.contains(ws.id.as_str())
                    && keep(ws)
                    && seen.insert(ws.id.as_str())
                {
                    out.push(ws.id.clone());
                }
            }
        }
    }
    out
}

/// `ids` with the subtrees they carry (a creator's children).
pub(super) fn with_subtrees(ids: &[String], sections: &[Section]) -> Vec<String> {
    let named: HashSet<&str> = ids.iter().map(String::as_str).collect();
    let mut out = ids.to_vec();
    out.extend(carried(&named, sections, |_| true));
    out
}

/// A reorder's ids with the children they carry, and its position less the
/// carried rows before it. The index counts the target's rows without the
/// named ones (the drag's coordinates); the carried rows leave too.
pub(super) fn carrying(
    ids: &[String],
    position: &Position,
    sections: &[Section],
) -> (Vec<String>, Position) {
    let target = sections.iter().find(|section| section.id == position.section);
    let named: HashSet<&str> = ids.iter().map(String::as_str).collect();
    let carried = carried(&named, sections, |ws| target.is_none_or(|target| can_place(ws, target)));
    if carried.is_empty() {
        return (ids.to_vec(), position.clone());
    }
    let leaving: HashSet<&str> = carried.iter().map(String::as_str).collect();
    let slot = usize::try_from(position.index.max(0)).unwrap_or(usize::MAX);
    let before = container(sections, &position.section, position.group.as_deref())
        .into_iter()
        .filter(|link| !link.is_some_and(|ws| named.contains(ws.id.as_str())))
        .take(slot)
        .filter(|link| link.is_some_and(|ws| leaving.contains(ws.id.as_str())))
        .count();
    let mut position = position.clone();
    position.index = position.index.saturating_sub(wire(before));
    let mut ids = ids.to_vec();
    ids.extend(carried);
    (ids, position)
}

/// Whether the keyboard may put a block headed by `head` at `slot` of
/// `section` (the block taken out). The slot right before a child is inside
/// its creator's subtree: only that creator's other children may stop there,
/// anything else would be listed after the subtree again.
pub(super) fn opens(slot: &Position, head: &Workspace, section: &Section) -> bool {
    let links = container(std::slice::from_ref(section), &slot.section, slot.group.as_deref());
    let parents = parents(&links);
    let row = usize::try_from(slot.index).unwrap_or(usize::MAX);
    match parents.get(row).copied().flatten() {
        Some(parent) => links.get(parent).copied().flatten().is_some_and(|ws| creates(ws, head)),
        None => true,
    }
}

/// A slot counted without the whole moving block (`moving`, named and
/// carried) in the coordinates a reorder of `named` takes: its rows without
/// the named ones, carried rows included.
pub(super) fn reorder_slot(
    slot: &Position,
    named: &[String],
    moving: &[String],
    sections: &[Section],
) -> Position {
    let mut remaining = sections.to_vec();
    remove_workspaces(&named.iter().map(String::as_str).collect(), &mut remaining);
    let moving: HashSet<&str> = moving.iter().map(String::as_str).collect();
    let rows = container(&remaining, &slot.section, slot.group.as_deref());
    let wanted = usize::try_from(slot.index.max(0)).unwrap_or(usize::MAX);
    let (mut at, mut staying) = (0, 0);
    while staying < wanted && at < rows.len() {
        if !rows.get(at).copied().flatten().is_some_and(|ws| moving.contains(ws.id.as_str())) {
            staying += 1;
        }
        at += 1;
    }
    Position { index: wire(at), ..slot.clone() }
}

/// The ids an intent names to move, whose links it breaks when they land
/// outside their creator's subtree.
fn named_moves(intent: &Intent) -> &[String] {
    match intent {
        Intent::Reorder { ids, .. }
        | Intent::Move { ids, .. }
        | Intent::SetPinned { ids, .. }
        | Intent::CreateGroup { ids, .. } => ids,
        _ => &[],
    }
}

/// After an accepted edit: break the links to creators it closed
/// (`listed_before` but no longer listed) and of the rows it named that left
/// their listed creator's subtree, then list every child right after its
/// creator's subtree. A link to a creator this window doesn't list is kept.
pub(super) fn settle(
    sections: &mut [Section],
    listed_before: &HashSet<(String, String)>,
    intent: &Intent,
) {
    let listed_now = listed(sections);
    let gone: HashSet<&(String, String)> = listed_before.difference(&listed_now).collect();
    let named: HashSet<&str> = named_moves(intent).iter().map(String::as_str).collect();
    for section in sections.iter_mut() {
        for node in &mut section.nodes {
            if let Node::Group { group } = node {
                settle_container(&mut group.members, &gone, &named, &listed_now);
            }
        }
        settle_container(&mut section.nodes, &gone, &named, &listed_now);
    }
}

fn settle_container<R: Row>(
    rows: &mut Vec<R>,
    gone: &HashSet<&(String, String)>,
    named: &HashSet<&str>,
    listed_now: &HashSet<(String, String)>,
) {
    let strays: Vec<usize> = {
        let links = links(rows);
        let nesting = nesting(&links, &parents(&links));
        links
            .iter()
            .enumerate()
            .filter_map(|(row, ws)| {
                let ws = (*ws)?;
                let creator = ws.creator.clone()?;
                let key = (creator, ws.machine.clone());
                if gone.contains(&key) {
                    return Some(row);
                }
                // A named row stays linked only inside its listed creator's subtree.
                let inside = nesting.depth.get(row).copied().flatten().is_some_and(|d| d > 0);
                (named.contains(ws.id.as_str()) && !inside && listed_now.contains(&key))
                    .then_some(row)
            })
            .collect()
    };
    for row in strays {
        if let Some(ws) = rows.get_mut(row).and_then(Row::workspace_mut) {
            ws.creator = None;
        }
    }
    let order = tree_sorted(&parents(&links(rows)));
    if order.iter().enumerate().all(|(at, &row)| at == row) {
        return;
    }
    let mut slots: Vec<Option<R>> = std::mem::take(rows).into_iter().map(Some).collect();
    rows.extend(order.into_iter().filter_map(|row| slots.get_mut(row).and_then(Option::take)));
}

fn node_workspaces(node: &mut Node) -> Box<dyn Iterator<Item = &mut Workspace> + '_> {
    match node {
        Node::Workspace { workspace } => Box::new(std::iter::once(workspace)),
        Node::Group { group } => Box::new(group.members.iter_mut().filter_map(Row::workspace_mut)),
        Node::Item { .. } => Box::new(std::iter::empty()),
    }
}

fn workspaces_mut(sections: &mut [Section]) -> impl Iterator<Item = &mut Workspace> {
    sections.iter_mut().flat_map(|section| &mut section.nodes).flat_map(node_workspaces)
}

/// `Detach`: breaks the links of `ids`; `settle` lists each after its old
/// creator's subtree.
pub(super) fn detach(ids: &[String], sections: &mut [Section]) -> bool {
    let named: HashSet<&str> = ids.iter().map(String::as_str).collect();
    let mut changed = false;
    for ws in workspaces_mut(sections) {
        if named.contains(ws.id.as_str()) && ws.creator.take().is_some() {
            changed = true;
        }
    }
    changed
}

/// `ToggleChildren`: hides or shows a creator's children. A row with none
/// has nothing to hide.
pub(super) fn toggle_children(id: &str, sections: &mut [Section]) -> bool {
    if carried(&HashSet::from([id]), sections, |_| true).is_empty() {
        return false;
    }
    let Some(ws) = workspaces_mut(sections).find(|ws| ws.id == id) else { return false };
    ws.collapsed_children = !ws.collapsed_children;
    true
}

/// Where the workspace `id` on `machine` lists first.
fn locate_on(id: &str, machine: &str, sections: &[Section]) -> Option<Location> {
    for (s, section) in sections.iter().enumerate() {
        for (n, node) in section.nodes.iter().enumerate() {
            match node {
                Node::Workspace { workspace }
                    if workspace.id == id && workspace.machine == machine =>
                {
                    return Some(Location { section: s, node: n, child: None });
                }
                Node::Group { group } => {
                    let at = group.workspaces().position(|ws| ws.id == id && ws.machine == machine);
                    if let Some(c) = at {
                        return Some(Location { section: s, node: n, child: Some(c) });
                    }
                }
                Node::Workspace { .. } | Node::Item { .. } => {}
            }
        }
    }
    None
}

/// `Attach`: links `ids` under `creator` (on their machine) and lists them,
/// with the children they carry, right after its subtree, in its group or
/// section. Refused for an unlisted creator, a link that would loop, a
/// creator's section that may not hold them, or a moving id that another
/// machine's row shares (the removal matches ids alone); a no-op for rows
/// already its children there.
pub(super) fn attach(ids: &[String], creator: &str, sections: &mut [Section]) -> bool {
    let ordered = tree_order(ids, sections);
    if ordered.is_empty() || ordered.iter().any(|id| id == creator) {
        return false;
    }
    let Some(machine) =
        ordered.first().and_then(|id| workspace(id, sections)).map(|ws| ws.machine.clone())
    else {
        return false;
    };
    let Some(home) = locate_on(creator, &machine, sections) else { return false };
    let named: HashSet<&str> = ordered.iter().map(String::as_str).collect();
    // A loop: the creator is (by its stored links) under one of the ids.
    let up: HashMap<&str, &str> = sections
        .iter()
        .flat_map(Section::workspaces)
        .filter(|ws| ws.machine == machine)
        .filter_map(|ws| ws.creator.as_deref().map(|creator| (ws.id.as_str(), creator)))
        .collect();
    let mut at = up.get(creator).copied();
    let mut steps = 0;
    while let Some(row) = at
        && steps <= up.len()
    {
        if named.contains(row) {
            return false;
        }
        at = up.get(row).copied();
        steps += 1;
    }
    let Some(section) = sections.get(home.section) else { return false };
    if already_children(&named, creator, &home, section) {
        return false;
    }
    let moving = with_subtrees(&ordered, sections);
    let moving_ids: HashSet<&str> = moving.iter().map(String::as_str).collect();
    let shared = sections
        .iter()
        .flat_map(Section::workspaces)
        .any(|ws| moving_ids.contains(ws.id.as_str()) && ws.machine != machine);
    if shared {
        return false;
    }
    let placeable =
        moving.iter().filter_map(|id| workspace(id, sections)).all(|ws| can_place(ws, section));
    if !placeable {
        return false;
    }
    let before = sections.to_vec();
    let mut removed = remove_workspaces(&moving.iter().map(String::as_str).collect(), sections);
    for ws in &mut removed {
        if named.contains(ws.id.as_str()) {
            ws.creator = Some(creator.to_owned());
        }
    }
    let Some(position) = after_subtree(creator, &machine, sections) else {
        sections.clone_from_slice(&before);
        return false;
    };
    super::insert(removed, &position, sections);
    // A group the move empties goes, as after a reorder.
    super::prune_empty_groups(sections, None, &super::groups_with_members(&before));
    sections != before.as_slice()
}

/// Whether every named row already lists under `creator`, found at `home`.
fn already_children(
    named: &HashSet<&str>,
    creator: &str,
    home: &Location,
    section: &Section,
) -> bool {
    let links = match (home.child, section.nodes.get(home.node)) {
        (Some(_), Some(Node::Group { group })) => links(&group.members),
        _ => links(&section.nodes),
    };
    let parents = parents(&links);
    let nesting = nesting(&links, &parents);
    let mut found = 0;
    for (row, ws) in links.iter().enumerate() {
        let Some(ws) = ws else { continue };
        if !named.contains(ws.id.as_str()) {
            continue;
        }
        let under =
            parents.get(row).copied().flatten().and_then(|p| links.get(p).copied().flatten());
        let inside = nesting.depth.get(row).copied().flatten().is_some_and(|d| d > 0);
        if !(inside && under.is_some_and(|under| under.id == creator && creates(under, ws))) {
            return false;
        }
        found += 1;
    }
    found == named.len()
}

/// The slot right after the subtree of `creator` (on `machine`) in its container.
fn after_subtree(creator: &str, machine: &str, sections: &[Section]) -> Option<Position> {
    let at = locate_on(creator, machine, sections)?;
    let section = sections.get(at.section)?;
    let (group, links) = match (at.child, section.nodes.get(at.node)?) {
        (Some(_), Node::Group { group }) => (Some(group.id.clone()), links(&group.members)),
        _ => (None, links(&section.nodes)),
    };
    let row = links
        .iter()
        .position(|link| link.is_some_and(|ws| ws.id == creator && ws.machine == machine))?;
    let children = children(&parents(&links));
    let last = subtree(row, &children).into_iter().max().unwrap_or(row);
    Some(Position { section: section.id.clone(), group, index: wire(last + 1) })
}
