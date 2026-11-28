//! The drop acceptance table of one drag, computed once at drag begin: for
//! each visible row, whether the dragged items may land before it, into it
//! (a group or a section header) and after it, and the refusal shown when
//! none is allowed. Mouse moves only look rows up in this table.
//!
//! The rules are the reducer's (`place`): an app section takes nothing
//! (`provider_owned`), a group takes a group only while the tree stays within
//! [`MAX_GROUP_DEPTH`] levels (`nesting`), and a workspace or group of
//! machine A does not land in machine B's section or in a tree of machine
//! B's workspaces (`cross_machine`). A row that is dragged, or anything under
//! a dragged group, refuses with `self`.
//!
//! A dragged group lands beside a row only at its own level or above
//! (`nesting`): the gap after a group's last member row looks like the gap
//! after the group, so taking the member row's parent there nested a group
//! the user only meant to reorder. It goes into a group through that group's
//! header (`into`), the one drop that highlights the group taking it.
//!
//! The top region is its own tier for workspaces and groups, as pinned
//! workspaces are in classic cmux (`pinned`): a drag never pins or unpins. A
//! workspace or group in a top section (Pinned, or the Top section above it,
//! which Add to Top fills) lands only in a top section, and every other one
//! lands in none. A drag that holds both refuses everywhere. Pin, Unpin and
//! Add to Top are menu actions. Links, tabs and apps are not in the tier.

use std::collections::{BTreeMap, HashMap, HashSet};

use serde::{Deserialize, Serialize};

use super::doc::Doc;
use super::model::*;
use super::view::Row;

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Acceptance {
    pub before: bool,
    pub into: bool,
    pub after: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub refusal: Option<String>,
}

/// What is dragged: its machine, and the most levels of groups one
/// dragged item holds (0: no group).
struct Dragged {
    keys: HashSet<String>,
    machines: HashSet<String>,
    group_height: usize,
    /// The parents a dragged group may land beside a row of: its own parent and
    /// every group above it, and the top level (`None`). `None` when no group is
    /// dragged (a workspace or link lands beside any row it is allowed by).
    group_levels: Option<HashSet<Option<String>>>,
    /// Some dragged workspace or group is in a top section.
    top: bool,
    /// Some dragged workspace or group is not (an unplaced live workspace counts).
    below: bool,
}

/// Whether `item` sits in a section of the top region.
fn is_top(doc: &Doc, item: &Item) -> bool {
    doc.section(&item.section).is_some_and(|section| matches!(section.region, Region::Top))
}

fn dragged(doc: &Doc, rows: &[Row], items: &[String]) -> Dragged {
    let mut result = Dragged {
        keys: HashSet::new(),
        machines: HashSet::new(),
        group_height: 0,
        group_levels: None,
        top: false,
        below: false,
    };
    for key in items {
        result.keys.insert(key.clone());
        if let Some(item) = doc.item(key) {
            if item.body.is_group() || item.body.workspace().is_some() {
                if is_top(doc, item) {
                    result.top = true;
                } else {
                    result.below = true;
                }
            }
            if item.body.is_group() {
                result.group_height = result.group_height.max(doc.group_height(item));
                let mut levels: HashSet<Option<String>> =
                    doc.ancestors(item).into_iter().map(|group| Some(group.id.clone())).collect();
                levels.insert(None);
                result.group_levels = Some(match result.group_levels.take() {
                    Some(shared) => shared.intersection(&levels).cloned().collect(),
                    None => levels,
                });
                for child in doc.descendants(item) {
                    result.keys.insert(child.id.clone());
                }
            }
            if let Some(machine) = doc.item_machine(item) {
                result.machines.insert(machine);
            }
        } else {
            // An unplaced live workspace (its row has no item yet): never pinned, whether or not its row is found.
            result.below = true;
            if let Some(reference) =
                rows.iter().find(|row| row.key == *key).and_then(|row| row.reference.as_ref())
            {
                result.machines.insert(reference.session_id.clone());
            }
        }
    }
    result
}

/// The machine of each group tree one drag has asked about, by root id.
type TreeMachines<'a> = HashMap<&'a str, Option<&'a str>>;

/// The machine of a group's tree, from its first workspace that is not
/// dragged. Every row of a tree asks the same question, so the answer is
/// kept per root (`trees`): one walk per tree, not one per row (base: a drag
/// start walked a 100-member group once for each of its rows).
fn group_machine<'a>(
    doc: &'a Doc,
    dragged: &Dragged,
    group: &str,
    trees: &mut TreeMachines<'a>,
) -> Option<&'a str> {
    let root = doc.root(doc.item(group)?);
    *trees.entry(root.id.as_str()).or_insert_with(|| {
        doc.descendants(root)
            .into_iter()
            .filter(|child| !dragged.keys.contains(&child.id))
            .find_map(|child| child.body.workspace().map(|r| r.session_id.as_str()))
    })
}

/// Whether the dragged items may land among the children of `parent` (or at
/// the top level) of `section`.
fn can_place<'a>(
    doc: &'a Doc,
    dragged: &Dragged,
    section: &str,
    parent: Option<&str>,
    trees: &mut TreeMachines<'a>,
) -> Result<(), Refusal> {
    let Some(target) = doc.section(section) else {
        // A stand-in machine section (no stored section yet).
        return match section.strip_prefix(MACHINE_SECTION_PREFIX) {
            Some(_) if dragged.top => Err(Refusal::Pinned),
            Some(session) if dragged.machines.iter().all(|m| m == session) => Ok(()),
            Some(_) => Err(Refusal::CrossMachine),
            None => Err(Refusal::UnknownSection),
        };
    };
    if matches!(target.kind, SectionKind::App { .. }) {
        return Err(Refusal::ProviderOwned);
    }
    // The top tier: a workspace or group lands only in its own tier (see the module doc).
    let into_top = matches!(target.region, Region::Top);
    if (into_top && dragged.below) || (!into_top && dragged.top) {
        return Err(Refusal::Pinned);
    }
    if let Some(machine) = target.kind.machine()
        && dragged.machines.iter().any(|m| m != machine)
    {
        return Err(Refusal::CrossMachine);
    }
    if let Some(parent) = parent {
        if dragged.group_height > 0 {
            let level = doc.item(parent).map_or(MAX_GROUP_DEPTH, |group| doc.group_level(group));
            if level + dragged.group_height > MAX_GROUP_DEPTH {
                return Err(Refusal::Nesting);
            }
        }
        if dragged.machines.len() > 1 {
            return Err(Refusal::CrossMachine);
        }
        if let Some(group_machine) = group_machine(doc, dragged, parent, trees)
            && dragged.machines.iter().any(|m| m != group_machine)
        {
            return Err(Refusal::CrossMachine);
        }
    }
    Ok(())
}

/// Whether a dragged group may land beside a row whose parent is `parent`: only
/// at its own level or above, never one level in by a gap (see the module doc).
fn beside(dragged: &Dragged, parent: Option<&str>) -> Result<(), Refusal> {
    match &dragged.group_levels {
        Some(levels) if !levels.contains(&parent.map(str::to_string)) => Err(Refusal::Nesting),
        _ => Ok(()),
    }
}

/// The acceptance of every row for dragging `items` (item ids, or the row
/// keys of unplaced live workspaces).
pub fn drag_begin(doc: &Doc, rows: &[Row], items: &[String]) -> BTreeMap<String, Acceptance> {
    let dragged = dragged(doc, rows, items);
    let mut trees = TreeMachines::new();
    let mut table = BTreeMap::new();
    for row in rows {
        if dragged.keys.contains(&row.key)
            || row.parent.as_ref().is_some_and(|parent| dragged.keys.contains(parent))
        {
            table.insert(
                row.key.clone(),
                Acceptance {
                    before: false,
                    into: false,
                    after: false,
                    refusal: Some("self".into()),
                },
            );
            continue;
        }
        let (sides, into) = if row.kind == "section" {
            (Err(Refusal::InvalidTarget), can_place(doc, &dragged, &row.section, None, &mut trees))
        } else {
            let sides = beside(&dragged, row.parent.as_deref()).and_then(|()| {
                can_place(doc, &dragged, &row.section, row.parent.as_deref(), &mut trees)
            });
            let into = if row.kind == "group" && row.item.is_some() {
                can_place(doc, &dragged, &row.section, Some(&row.key), &mut trees)
            } else {
                Err(Refusal::InvalidTarget)
            };
            (sides, into)
        };
        let refusal = match (&sides, &into) {
            (Err(side), Err(inner)) => {
                let reason = if *side == Refusal::InvalidTarget { *inner } else { *side };
                Some(reason.as_str().to_string())
            }
            _ => None,
        };
        table.insert(
            row.key.clone(),
            Acceptance { before: sides.is_ok(), into: into.is_ok(), after: sides.is_ok(), refusal },
        );
    }
    table
}
