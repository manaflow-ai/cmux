//! Moves by step: the keyboard reorder (Cmd-Opt-Up/Down) of selected rows,
//! the group ordering verbs (Move Group to Top, Up, Down, to Bottom) and the
//! group choices of a workspace's Move to Group.

use serde::{Deserialize, Serialize};
use std::collections::HashSet;

use super::{
    Member, Node, Position, Section, can_place, creator, locate, locate_group, position_of,
    remove_workspaces, tree_order, wire, workspace,
};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Direction {
    Up,
    Down,
}

/// Where a group ordering verb sends a group among its section's rows.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum GroupMove {
    Top,
    Bottom,
    Up,
    Down,
}

/// The slot the keyboard reorder moves the block `ids` to: one slot up or
/// down among every place the block could be inserted in its own section.
/// Moving down past an expanded group enters it as the first child; moving
/// up from a group's first child leaves it. Collapsed groups are stepped
/// over, and so is another creator's subtree; a creator moves with its
/// children (`creator`). The block never leaves its section, so a keyboard move never pins,
/// unpins or crosses machines.
pub fn keyboard_target(
    ids: &[String],
    direction: Direction,
    sections: &[Section],
) -> Option<Position> {
    let ordered = tree_order(ids, sections);
    let first = ordered.first()?;
    let anchor = locate(first, sections)?;
    let head = workspace(first, sections)?;
    // Nothing precedes the anchor in tree order, so its indices already are "after removal" coordinates.
    let current = position_of(first, sections)?;
    // A creator steps with its children, and over another creator's subtree as one row.
    let moving = creator::with_subtrees(&ordered, sections);
    let mut remaining = sections.to_vec();
    remove_workspaces(&moving.iter().map(String::as_str).collect(), &mut remaining);
    let section = remaining.get(anchor.section)?;
    let slots: Vec<Position> = slots(section)
        .into_iter()
        .filter(|slot| *slot == current || creator::opens(slot, head, section))
        .collect();
    let i = slots.iter().position(|slot| *slot == current)?;
    let j = match direction {
        Direction::Up => i.checked_sub(1)?,
        Direction::Down => i.checked_add(1)?,
    };
    Some(creator::reorder_slot(slots.get(j)?, &ordered, &moving, sections))
}

/// Every insertion slot of a section, in visual order. Nested groups list
/// flat after their parent and draw inside it, after its members: a subgroup
/// has no top-level slot before it (that gap is inside its parent), and a
/// group under a collapsed one shows no slots.
pub(super) fn slots(section: &Section) -> Vec<Position> {
    let at = |group: Option<&str>, index: usize| Position {
        section: section.id.clone(),
        group: group.map(str::to_owned),
        index: wire(index),
    };
    let mut result = Vec::new();
    let mut hidden: HashSet<&str> = HashSet::new(); // collapsed groups and every group under one
    for (index, node) in section.nodes.iter().enumerate() {
        let Node::Group { group } = node else {
            result.push(at(None, index));
            continue;
        };
        if let Some(parent) = &group.parent {
            if hidden.contains(parent.as_str()) {
                hidden.insert(&group.id);
                continue;
            }
        } else {
            result.push(at(None, index));
        }
        if group.collapsed {
            hidden.insert(&group.id);
            continue;
        }
        // A group's index counts its member rows (items too).
        for child in 0..=group.members.len() {
            result.push(at(Some(&group.id), child));
        }
    }
    result.push(at(None, section.nodes.len()));
    result
}

/// The section-row index `reorder_group` takes to move `group` as `step`
/// says. The index counts the section's rows after the group is taken out.
/// A group steps over the top-level rows: a neighbour group moves with the
/// subgroups listed after it. None when the group is not listed, is a
/// subgroup (it moves with its parent), or is already where `step` sends it.
pub fn group_index(group: &str, step: GroupMove, sections: &[Section]) -> Option<i64> {
    let (section, node) = locate_group(group, sections)?;
    let mut staying = sections.get(section)?.nodes.clone();
    let Node::Group { group: moved } = staying.remove(node) else { return None };
    if moved.parent.is_some() {
        return None;
    }
    let top_level: Vec<usize> = staying
        .iter()
        .enumerate()
        .filter(|(_, node)| match node {
            Node::Group { group } => group.parent.is_none(),
            Node::Workspace { .. } | Node::Item { .. } => true,
        })
        .map(|(index, _)| index)
        .collect();
    let current = top_level.iter().filter(|index| **index < node).count();
    let count = top_level.len();
    let target = match step {
        GroupMove::Top => 0,
        GroupMove::Bottom => count,
        GroupMove::Up => current.checked_sub(1)?,
        GroupMove::Down => current.checked_add(1)?,
    };
    if target > count || target == current {
        return None;
    }
    Some(wire(top_level.get(target).map_or(staying.len(), |index| *index)))
}

/// The groups Collapse Other Groups toggles, in sidebar order: every other
/// expanded group, and `keeping` itself when it is collapsed (it opens).
pub fn groups_toggled_by_collapsing_others(keeping: &str, sections: &[Section]) -> Vec<String> {
    groups(sections)
        .filter(|group| if group.id == keeping { group.collapsed } else { !group.collapsed })
        .map(|group| group.id.clone())
        .collect()
}

fn groups(sections: &[Section]) -> impl Iterator<Item = &super::Group> {
    sections.iter().flat_map(|section| &section.nodes).filter_map(|node| match node {
        Node::Group { group } => Some(group),
        Node::Workspace { .. } | Node::Item { .. } => None,
    })
}

/// Whether every workspace `ids` names may join `group`: the group exists
/// and each may live in its section (a group holds one machine row's
/// workspaces). The one rule for a drag, the palette and the CLI.
pub fn can_move(ids: &[String], group: &str, sections: &[Section]) -> bool {
    let Some(home) = locate_group(group, sections).and_then(|(s, _)| sections.get(s)) else {
        return false;
    };
    !ids.is_empty()
        && ids.iter().all(|id| workspace(id, sections).is_some_and(|ws| can_place(ws, home)))
}

/// The groups a workspace's Move to Group lists, in sidebar order: every
/// group it may join (`can_move`), without the one it is in.
pub fn joinable_groups(id: &str, sections: &[Section]) -> Vec<String> {
    let ids = [id.to_owned()];
    groups(sections)
        .filter(|group| {
            !group.members.iter().any(
                |member| matches!(member, Member::Workspace { workspace } if workspace.id == id),
            ) && can_move(&ids, &group.id, sections)
        })
        .map(|group| group.id.clone())
        .collect()
}
