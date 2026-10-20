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

use std::collections::{BTreeMap, HashSet};

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
}

fn dragged(doc: &Doc, rows: &[Row], items: &[String]) -> Dragged {
    let mut result = Dragged { keys: HashSet::new(), machines: HashSet::new(), group_height: 0 };
    for key in items {
        result.keys.insert(key.clone());
        if let Some(item) = doc.item(key) {
            if item.body.is_group() {
                result.group_height = result.group_height.max(doc.group_height(item));
                for child in doc.descendants(item) {
                    result.keys.insert(child.id.clone());
                }
            }
            if let Some(machine) = doc.item_machine(item) {
                result.machines.insert(machine);
            }
        } else if let Some(reference) =
            rows.iter().find(|row| row.key == *key).and_then(|row| row.reference.as_ref())
        {
            // An unplaced live workspace (its row has no item yet).
            result.machines.insert(reference.session_id.clone());
        }
    }
    result
}

/// The machine of a group's tree, from its first workspace that is not
/// dragged.
fn group_machine<'a>(doc: &'a Doc, dragged: &Dragged, group: &str) -> Option<&'a str> {
    let root = doc.root(doc.item(group)?);
    doc.descendants(root)
        .into_iter()
        .filter(|child| !dragged.keys.contains(&child.id))
        .find_map(|child| child.body.workspace().map(|r| r.session_id.as_str()))
}

/// Whether the dragged items may land among the children of `parent` (or at
/// the top level) of `section`.
fn can_place(
    doc: &Doc,
    dragged: &Dragged,
    section: &str,
    parent: Option<&str>,
) -> Result<(), Refusal> {
    let Some(target) = doc.section(section) else {
        // A stand-in machine section (no stored section yet).
        return match section.strip_prefix(MACHINE_SECTION_PREFIX) {
            Some(session) if dragged.machines.iter().all(|m| m == session) => Ok(()),
            Some(_) => Err(Refusal::CrossMachine),
            None => Err(Refusal::UnknownSection),
        };
    };
    if matches!(target.kind, SectionKind::App { .. }) {
        return Err(Refusal::ProviderOwned);
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
        if let Some(group_machine) = group_machine(doc, dragged, parent)
            && dragged.machines.iter().any(|m| m != group_machine)
        {
            return Err(Refusal::CrossMachine);
        }
    }
    Ok(())
}

/// The acceptance of every row for dragging `items` (item ids, or the row
/// keys of unplaced live workspaces).
pub fn drag_begin(doc: &Doc, rows: &[Row], items: &[String]) -> BTreeMap<String, Acceptance> {
    let dragged = dragged(doc, rows, items);
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
            (Err(Refusal::InvalidTarget), can_place(doc, &dragged, &row.section, None))
        } else {
            let sides = can_place(doc, &dragged, &row.section, row.parent.as_deref());
            let into = if row.kind == "group" && row.item.is_some() {
                can_place(doc, &dragged, &row.section, Some(&row.key))
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
