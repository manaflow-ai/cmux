//! Archiving (plans/cmux-next/archiving-DESIGN.md). An archived item stays
//! in its own sibling list (its group, or its section's top level), lists
//! after the unarchived siblings and draws dimmed, with its subtree. Every
//! move keeps the two runs apart ([`archived_side`]), so a new or dropped
//! item never lands below an archived one. Unarchive puts the item back after
//! the sibling it followed when it was archived, while that sibling is still
//! there and not archived; else last among the unarchived siblings.

use std::collections::HashSet;

use serde_json::Value;

use super::doc::{Doc, ListEntry};
use super::model::*;
use super::reduce::{Tx, neighbors, place};

/// Archive `ids`: mark each, remember the sibling before it, and move it to
/// the end of its own list. An item pinned in its group is unpinned there.
/// Every sibling before is read before anything moves, so items archived
/// together come back in their order.
pub(super) fn archive(tx: &mut Tx, ids: &[ItemId]) -> Result<(), Refusal> {
    let mut befores = Vec::with_capacity(ids.len());
    for id in in_list_order(tx.doc, ids)? {
        let item = tx.doc.item(&id).ok_or(Refusal::UnknownItem)?;
        if item.archived() {
            continue;
        }
        let after = tx
            .doc
            .list_entries(&item.section, item.parent.as_deref())
            .and_then(|set| {
                Doc::entry_before(set, &(item.order.clone(), item.id.clone()), &|_| false)
            })
            .map_or(Value::Null, |(_, id)| Value::String(id.clone()));
        befores.push((id, after));
    }
    for (id, after) in befores {
        let id = &id;
        let item = tx.doc.item(id).ok_or(Refusal::UnknownItem)?;
        let (section, parent) = (item.section.clone(), item.parent.clone());
        tx.edit_item(id, |item| {
            item.extra.remove(PINNED_IN_GROUP_KEY);
            item.extra.insert(ARCHIVED_KEY.into(), Value::Bool(true));
            item.extra.insert(UNARCHIVE_TO_KEY.into(), serde_json::json!({ "after": after }));
            Ok(())
        })?;
        let to = Target { section, parent, ..Target::default() };
        place(tx, std::slice::from_ref(id), &to)?;
    }
    Ok(())
}

/// Unarchive `ids`: clear the mark and put each back where it was archived
/// from (see the module docs). Items that are not archived are skipped.
/// In list order, so each one's remembered sibling is back before it is.
pub(super) fn unarchive(tx: &mut Tx, ids: &[ItemId]) -> Result<(), Refusal> {
    for id in &in_list_order(tx.doc, ids)? {
        let item = tx.doc.item(id).ok_or(Refusal::UnknownItem)?;
        if !item.archived() {
            continue;
        }
        let (section, parent) = (item.section.clone(), item.parent.clone());
        let remembered = item.extra.get(UNARCHIVE_TO_KEY).map(|place| place.get("after").cloned());
        let to = match remembered {
            // It was first in its list.
            Some(Some(Value::Null)) => {
                Target { section, parent, index: Some(0), ..Target::default() }
            }
            Some(Some(Value::String(after)))
                if tx.doc.item(&after).is_some_and(|anchor| {
                    anchor.id != *id
                        && anchor.section == section
                        && anchor.parent == parent
                        && !anchor.archived()
                }) =>
            {
                Target { section, parent, after: Some(after), ..Target::default() }
            }
            // Nowhere (still) remembered: last among the unarchived siblings.
            _ => Target { section, parent, ..Target::default() },
        };
        tx.edit_item(id, |item| {
            item.extra.remove(ARCHIVED_KEY);
            item.extra.remove(UNARCHIVE_TO_KEY);
            Ok(())
        })?;
        place(tx, std::slice::from_ref(id), &to)?;
    }
    Ok(())
}

/// `ids` without repeats, in the order the sidebar lists them within each
/// sibling list (the order keys); lists keep the order they first appear in.
fn in_list_order(doc: &Doc, ids: &[ItemId]) -> Result<Vec<ItemId>, Refusal> {
    type List = ((SectionId, Option<ItemId>), Vec<ListEntry>);
    let mut lists: Vec<List> = Vec::new();
    for id in ids {
        let item = doc.item(id).ok_or(Refusal::UnknownItem)?;
        let list = (item.section.clone(), item.parent.clone());
        let entry = (item.order.clone(), item.id.clone());
        match lists.iter_mut().find(|(key, _)| *key == list) {
            Some((_, entries)) if !entries.contains(&entry) => entries.push(entry),
            Some(_) => {}
            None => lists.push((list, vec![entry])),
        }
    }
    Ok(lists
        .into_iter()
        .flat_map(|(_, mut entries)| {
            entries.sort();
            entries.into_iter().map(|(_, id)| id)
        })
        .collect())
}

/// `to` moved to the archived (or unarchived) side of its sibling list: the
/// archived run is the list's tail.
pub(super) fn archived_side(
    doc: &Doc,
    to: &Target,
    moved: &HashSet<ItemId>,
    archived: bool,
) -> Result<Target, Refusal> {
    let siblings: Vec<&ListEntry> = doc
        .list_entries(&to.section, to.parent.as_deref())
        .map(|set| set.iter().filter(|(_, id)| !moved.contains(id)).collect())
        .unwrap_or_default();
    let tail = siblings.iter().filter(|(_, id)| doc.item(id).is_some_and(Item::archived)).count();
    let start = siblings.len() - tail;
    let (_, high) = neighbors(doc, to, moved)?;
    let at = high
        .as_ref()
        .and_then(|high| siblings.iter().position(|entry| *entry == high))
        .unwrap_or(siblings.len());
    let clamped = if archived { at.max(start) } else { at.min(start) };
    if clamped == at {
        return Ok(to.clone());
    }
    Ok(Target {
        section: to.section.clone(),
        parent: to.parent.clone(),
        index: Some(i64::try_from(clamped).unwrap_or(i64::MAX)),
        ..Target::default()
    })
}
