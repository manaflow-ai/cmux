//! The creator link (`Workspace.creator`): a workspace an agent or a script
//! made lists right after the subtree of the workspace that made it, in the
//! same container (a section's top level or a group's members). Rows stay
//! flat; the tree is derived from the links and the order, and every edit
//! keeps each child inside its creator's subtree:
//!
//! - Moving a creator carries its children, as a group move carries its
//!   subgroups.
//! - Moving a child out of its creator's subtree, group or section breaks
//!   its link, as `Detach` does.
//! - Closing a creator breaks its children's links, as a gone parent group
//!   lifts its subgroups (`lift_orphans`).
//! - A link whose creator lists elsewhere (another group, or a window that
//!   does not show it) is kept but draws flat; one that loops draws as a root.

use super::{
    Group, Intent, Member, Node, Position, Section, can_place, locate, remove_workspaces,
    tree_order, wire, workspace,
};
use std::collections::{HashMap, HashSet};

/// A container row: a workspace's id and its creator, or None for a group
/// or an item.
pub(super) type Link<'a> = Option<(&'a str, Option<&'a str>)>;

/// A section's top-level node or a group's member.
pub(super) trait Row {
    fn workspace(&self) -> Option<&super::Workspace>;
    fn workspace_mut(&mut self) -> Option<&mut super::Workspace>;

    fn link(&self) -> Link<'_> {
        self.workspace().map(|ws| (ws.id.as_str(), ws.creator.as_deref()))
    }
}

impl Row for Node {
    fn workspace(&self) -> Option<&super::Workspace> {
        match self {
            Node::Workspace { workspace } => Some(workspace),
            Node::Group { .. } | Node::Item { .. } => None,
        }
    }

    fn workspace_mut(&mut self) -> Option<&mut super::Workspace> {
        match self {
            Node::Workspace { workspace } => Some(workspace),
            Node::Group { .. } | Node::Item { .. } => None,
        }
    }
}

impl Row for Member {
    fn workspace(&self) -> Option<&super::Workspace> {
        match self {
            Member::Workspace { workspace } => Some(workspace),
            Member::Item { .. } => None,
        }
    }

    fn workspace_mut(&mut self) -> Option<&mut super::Workspace> {
        match self {
            Member::Workspace { workspace } => Some(workspace),
            Member::Item { .. } => None,
        }
    }
}

/// Each row's parent in its container: its creator's row when the creator
/// lists there too. A row on a loop of links has none.
pub(super) fn parents(links: &[Link<'_>]) -> Vec<Option<usize>> {
    let mut index: HashMap<&str, usize> = HashMap::new();
    for (at, link) in links.iter().enumerate() {
        if let Some((id, _)) = *link {
            index.entry(id).or_insert(at);
        }
    }
    let mut parents: Vec<Option<usize>> = links
        .iter()
        .map(|link| link.and_then(|(_, creator)| creator).and_then(|c| index.get(c).copied()))
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
            state[row] = 1;
            path.push(row);
            at = parents.get(row).copied().flatten();
        }
        // The walk came back to a row of its own: those rows form a loop, and each is a root.
        if let Some(row) = at
            && state.get(row).copied() == Some(1)
            && let Some(from) = path.iter().position(|&walked| walked == row)
        {
            for &looped in path.get(from..).unwrap_or_default() {
                parents[looped] = None;
            }
        }
        for &walked in &path {
            state[walked] = 2;
        }
    }
    parents
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
fn for_each_container(
    sections: &mut [Section],
    mut nodes: impl FnMut(&mut Vec<Node>),
    mut members: impl FnMut(&mut Vec<Member>),
) {
    for section in sections.iter_mut() {
        for node in &mut section.nodes {
            if let Node::Group { group } = node {
                members(&mut group.members);
            }
        }
        nodes(&mut section.nodes);
    }
}

fn containers(sections: &[Section]) -> Vec<Vec<Link<'_>>> {
    let mut out = Vec::new();
    for section in sections {
        out.push(section.nodes.iter().map(Row::link).collect());
        for node in &section.nodes {
            if let Node::Group { group } = node {
                out.push(group.members.iter().map(Row::link).collect());
            }
        }
    }
    out
}

/// Every listed workspace id.
pub(super) fn listed(sections: &[Section]) -> HashSet<String> {
    sections.iter().flat_map(Section::workspaces).map(|ws| ws.id.clone()).collect()
}

/// The rows each of `named` carries along: its subtree in its container,
/// those `keep` accepts, without the named ones, in tree order.
fn carried(
    named: &HashSet<&str>,
    sections: &[Section],
    keep: impl Fn(&str) -> bool,
) -> Vec<String> {
    let mut out: Vec<String> = Vec::new();
    for links in containers(sections) {
        let children = children(&parents(&links));
        for (row, link) in links.iter().enumerate() {
            if !link.is_some_and(|(id, _)| named.contains(id)) {
                continue;
            }
            for under in subtree(row, &children) {
                if let Some(Some((id, _))) = links.get(under)
                    && !named.contains(id)
                    && keep(*id)
                    && !out.iter().any(|seen| seen.as_str() == *id)
                {
                    out.push((*id).to_owned());
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
    let carried = carried(&named, sections, |id| {
        let placeable = workspace(id, sections);
        target.is_none_or(|target| placeable.is_some_and(|ws| can_place(ws, target)))
    });
    if carried.is_empty() {
        return (ids.to_vec(), position.clone());
    }
    let leaving: HashSet<&str> = carried.iter().map(String::as_str).collect();
    let rows: Vec<Link<'_>> = match (target, &position.group) {
        (Some(section), None) => section.nodes.iter().map(Row::link).collect(),
        (Some(section), Some(group)) => section
            .nodes
            .iter()
            .find_map(|node| match node {
                Node::Group { group: found } if &found.id == group => {
                    Some(found.members.iter().map(Row::link).collect())
                }
                _ => None,
            })
            .unwrap_or_default(),
        (None, _) => Vec::new(),
    };
    let slot = usize::try_from(position.index.max(0)).unwrap_or(usize::MAX);
    let before = rows
        .iter()
        .filter(|link| !link.is_some_and(|(id, _)| named.contains(id)))
        .take(slot)
        .filter(|link| link.is_some_and(|(id, _)| leaving.contains(id)))
        .count();
    let mut position = position.clone();
    position.index = position.index.saturating_sub(wire(before));
    let mut ids = ids.to_vec();
    ids.extend(carried);
    (ids, position)
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
/// their creator's subtree, then list every child right after its creator's
/// subtree.
pub(super) fn settle(sections: &mut [Section], listed_before: &HashSet<String>, intent: &Intent) {
    let listed_now = listed(sections);
    let gone: HashSet<&str> =
        listed_before.iter().filter(|id| !listed_now.contains(*id)).map(String::as_str).collect();
    let named: HashSet<&str> = named_moves(intent).iter().map(String::as_str).collect();
    for_each_container(
        sections,
        |rows| settle_container(rows, &gone, &named),
        |rows| settle_container(rows, &gone, &named),
    );
}

fn settle_container<R: Row>(rows: &mut Vec<R>, gone: &HashSet<&str>, named: &HashSet<&str>) {
    let strays: Vec<usize> = {
        let links: Vec<Link<'_>> = rows.iter().map(Row::link).collect();
        let parents = parents(&links);
        let under = |row: usize, root: usize| {
            let mut at = parents.get(row).copied().flatten();
            while let Some(parent) = at {
                if parent == root {
                    return true;
                }
                at = parents.get(parent).copied().flatten();
            }
            false
        };
        links
            .iter()
            .enumerate()
            .filter_map(|(row, link)| {
                let (id, creator) = (*link)?;
                let creator = creator?;
                if gone.contains(creator) {
                    return Some(row);
                }
                if !named.contains(id) {
                    return None;
                }
                // A named row stays linked only inside its creator's subtree.
                let inside = parents.get(row).copied().flatten().is_some_and(|parent| {
                    parent < row && (parent + 1..row).all(|between| under(between, parent))
                });
                (!inside).then_some(row)
            })
            .collect()
    };
    for row in strays {
        if let Some(ws) = rows.get_mut(row).and_then(Row::workspace_mut) {
            ws.creator = None;
        }
    }
    let order = {
        let links: Vec<Link<'_>> = rows.iter().map(Row::link).collect();
        tree_sorted(&parents(&links))
    };
    if order.iter().enumerate().all(|(at, &row)| at == row) {
        return;
    }
    let mut slots: Vec<Option<R>> = std::mem::take(rows).into_iter().map(Some).collect();
    rows.extend(order.into_iter().filter_map(|row| slots.get_mut(row).and_then(Option::take)));
}

/// `Detach`: breaks the links of `ids`; `settle` lists each after its old
/// creator's subtree.
pub(super) fn detach(ids: &[String], sections: &mut [Section]) -> bool {
    let named: HashSet<&str> = ids.iter().map(String::as_str).collect();
    let mut changed = false;
    let mut clear = |ws: &mut super::Workspace| {
        if named.contains(ws.id.as_str()) && ws.creator.take().is_some() {
            changed = true;
        }
    };
    for section in sections.iter_mut() {
        for node in &mut section.nodes {
            match node {
                Node::Workspace { workspace } => clear(workspace),
                Node::Group { group } => group.members.iter_mut().for_each(|member| {
                    if let Some(ws) = member.workspace_mut() {
                        clear(ws);
                    }
                }),
                Node::Item { .. } => {}
            }
        }
    }
    changed
}

/// `ToggleChildren`: hides or shows a creator's children.
pub(super) fn toggle_children(id: &str, sections: &mut [Section]) -> bool {
    let Some(ws) = workspace_mut(id, sections) else { return false };
    ws.collapsed_children = !ws.collapsed_children;
    true
}

fn workspace_mut<'a>(id: &str, sections: &'a mut [Section]) -> Option<&'a mut super::Workspace> {
    let at = locate(id, sections)?;
    match sections.get_mut(at.section)?.nodes.get_mut(at.node)? {
        Node::Workspace { workspace } => Some(workspace),
        Node::Group { group } => {
            group.members.iter_mut().filter_map(Row::workspace_mut).nth(at.child?)
        }
        Node::Item { .. } => None,
    }
}

/// `Attach`: links `ids` under `creator` and lists them (with the children
/// they carry) right after its subtree, in its group or section. Refused
/// for an unlisted creator, a link that would loop or a creator's section
/// that may not hold them.
pub(super) fn attach(ids: &[String], creator: &str, sections: &mut [Section]) -> bool {
    let Some(home) = locate(creator, sections) else { return false };
    let ordered = tree_order(ids, sections);
    if ordered.is_empty() || ordered.iter().any(|id| id == creator) {
        return false;
    }
    // A loop: the creator is (by its stored links) under one of the ids.
    let links: HashMap<&str, &str> = sections
        .iter()
        .flat_map(Section::workspaces)
        .filter_map(|ws| ws.creator.as_deref().map(|creator| (ws.id.as_str(), creator)))
        .collect();
    let named: HashSet<&str> = ordered.iter().map(String::as_str).collect();
    let mut at = links.get(creator).copied();
    let mut steps = 0;
    while let Some(up) = at
        && steps <= links.len()
    {
        if named.contains(up) {
            return false;
        }
        at = links.get(up).copied();
        steps += 1;
    }
    let Some(section) = sections.get(home.section) else { return false };
    let moving = with_subtrees(&ordered, sections);
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
    let Some(position) = after_subtree(creator, sections) else {
        sections.clone_from_slice(&before);
        return false;
    };
    super::insert(removed, &position, sections);
    // A group the move empties goes, as after a reorder.
    super::prune_empty_groups(sections, None, &super::groups_with_members(&before));
    sections != before.as_slice()
}

/// The slot right after `creator`'s subtree in its container.
fn after_subtree(creator: &str, sections: &[Section]) -> Option<Position> {
    let at = locate(creator, sections)?;
    let section = sections.get(at.section)?;
    let (group, links): (Option<&Group>, Vec<Link<'_>>) =
        match (at.child, section.nodes.get(at.node)?) {
            (Some(_), Node::Group { group }) => {
                (Some(group), group.members.iter().map(Row::link).collect())
            }
            _ => (None, section.nodes.iter().map(Row::link).collect()),
        };
    let row = links.iter().position(|link| link.is_some_and(|(id, _)| id == creator))?;
    let children = children(&parents(&links));
    let last = subtree(row, &children).into_iter().max().unwrap_or(row);
    Some(Position {
        section: section.id.clone(),
        group: group.map(|group| group.id.clone()),
        index: wire(last + 1),
    })
}
