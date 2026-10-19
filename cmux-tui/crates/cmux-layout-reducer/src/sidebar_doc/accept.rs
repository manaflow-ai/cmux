//! The drop acceptance table of one drag, computed once at drag begin: for
//! each visible row, whether the dragged items may land before it, into it
//! (a group or a section header) and after it, and the refusal shown when
//! none is allowed. Mouse moves only look rows up in this table.
//!
//! The rules are the reducer's (`place`): an app section takes nothing
//! (`provider_owned`), a group lands in a group only while the result is at
//! most [`MAX_GROUP_DEPTH`] group levels deep (`too_deep`), and a workspace
//! or group with a workspace of machine A does not land in machine B's
//! section (`cross_machine`). A group outside a machine section takes
//! workspaces of any machine. A row that is dragged, or any row under a
//! dragged group, refuses with `self`.

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

/// What is dragged: its machine and whether it is (or holds) a group.
struct Dragged {
    /// The dragged items and everything under them.
    keys: HashSet<String>,
    machines: HashSet<String>,
    /// The dragged groups.
    groups: HashSet<String>,
    /// The most group levels one dragged group takes (0: no group).
    height: usize,
}

fn dragged(doc: &Doc, rows: &[Row], items: &[String]) -> Dragged {
    let mut result = Dragged {
        keys: HashSet::new(),
        machines: HashSet::new(),
        groups: HashSet::new(),
        height: 0,
    };
    for key in items {
        result.keys.insert(key.clone());
        if let Some(item) = doc.item(key) {
            if item.body.is_group() {
                result.groups.insert(key.clone());
                result.height = result.height.max(doc.group_height(key));
                for child in doc.descendants(key) {
                    result.keys.insert(child.id.clone());
                }
            }
            result.machines.extend(doc.machines_of(key));
        } else if let Some(reference) =
            rows.iter().find(|row| row.key == *key).and_then(|row| row.reference.as_ref())
        {
            // An unplaced live workspace (its row has no item yet).
            result.machines.insert(reference.session_id.clone());
        }
    }
    result
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
    // A group lands in a group only where its levels still fit: the
    // groups above the target, the target, and the dragged group's own.
    let levels = match parent {
        Some(parent) => {
            if dragged.keys.contains(parent) {
                return Err(Refusal::Nesting);
            }
            doc.ancestors(parent).len() + 1
        }
        None => 0,
    };
    if levels + dragged.height > MAX_GROUP_DEPTH {
        return Err(Refusal::TooDeep);
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
            || dragged.groups.iter().any(|group| doc.is_within(&row.key, group))
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
