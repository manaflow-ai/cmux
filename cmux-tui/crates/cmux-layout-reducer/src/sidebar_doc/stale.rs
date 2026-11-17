//! A stale op applies to the document as it is now, never refused for being
//! stale. An op is written against the document its sender saw; by the time
//! it applies, an item may have closed, a group may have been deleted, a
//! space's items may have moved (auto-archive's pass plans from the rows it
//! saw, an agent's CLI names an item it listed a moment ago, Delete Space's
//! follow-up runs after the delete, a retried change replays). Leo, 2026-11-14,
//! on the refusals that came of it: "the daemon shouldn't even refuse those".
//!
//! [`rebase`] runs before each op, against the document the ops before it in
//! the batch left:
//! - an item that is gone drops out of the op; an op left with nothing to act
//!   on (no items, a gone item, group or section) is a no-op;
//! - a target whose group is gone (or is no longer a group of that section)
//!   falls back to the section's top level; an anchor (`before`, `after`)
//!   that is gone, not a sibling there, or one of the moved items falls back
//!   to the end of the list;
//! - a target section that is gone makes a move or pin a no-op (the items
//!   stay where they are).
//!
//! What is left to refuse is a change that is impossible on the document as
//! it is: another machine's section (`cross_machine`), an app section
//! (`provider_owned`), a group into its own subtree or too deep (`nesting`,
//! `invalid_target`), a bad name or value.

use std::borrow::Cow;

use super::doc::Doc;
use super::model::*;

/// `op` rebased onto `doc`: unchanged when nothing it names is stale, a
/// rebased copy when some of it is, `None` when nothing is left to do.
pub(super) fn rebase<'a>(doc: &Doc, op: &'a Op) -> Option<Cow<'a, Op>> {
    let present = |items: &[ItemId]| -> Option<Vec<ItemId>> {
        let kept: Vec<ItemId> = items.iter().filter(|id| doc.item(id).is_some()).cloned().collect();
        (!kept.is_empty()).then_some(kept)
    };
    let item_op = |id: &str| doc.item(id).is_some().then_some(Cow::Borrowed(op));
    let section_op = |id: &str| doc.section(id).is_some().then_some(Cow::Borrowed(op));
    match op {
        Op::Move { items, to } => {
            doc.section(&to.section)?;
            let kept = present(items)?;
            let to_now = target(doc, to, &kept);
            if kept.len() == items.len() && to_now == *to {
                return Some(Cow::Borrowed(op));
            }
            Some(Cow::Owned(Op::Move { items: kept, to: to_now }))
        }
        Op::Pin { items } => kept_items(op, items, present(items)?, |items| Op::Pin { items }),
        Op::Unpin { items } => kept_items(op, items, present(items)?, |items| Op::Unpin { items }),
        Op::Archive { items } => {
            kept_items(op, items, present(items)?, |items| Op::Archive { items })
        }
        Op::Unarchive { items } => {
            kept_items(op, items, present(items)?, |items| Op::Unarchive { items })
        }
        Op::ItemRemove { id } | Op::ItemDelete { id } => item_op(id),
        Op::ItemUpdate { id, .. } | Op::GroupUpdate { id, .. } | Op::GroupUngroup { id } => {
            item_op(id)
        }
        Op::SectionUpdate { id, .. } | Op::SectionRemove { id } => section_op(id),
        Op::SectionMove { id, place } => {
            doc.section(id)?;
            let gone = |anchor: &Option<SectionId>| {
                anchor.as_ref().is_some_and(|anchor| doc.section(anchor).is_none() || anchor == id)
            };
            if !gone(&place.before) && !gone(&place.after) {
                return Some(Cow::Borrowed(op));
            }
            let place = SectionPlace { before: None, after: None, ..place.clone() };
            Some(Cow::Owned(Op::SectionMove { id: id.clone(), place }))
        }
        Op::ItemAdd { item, to } => {
            let to_now = target(doc, to, &[]);
            if to_now == *to {
                return Some(Cow::Borrowed(op));
            }
            Some(Cow::Owned(Op::ItemAdd { item: item.clone(), to: to_now }))
        }
        Op::GroupCreate { id, name, color, icon, profile, items, to } => {
            let kept: Vec<ItemId> =
                items.iter().filter(|item| doc.item(item).is_some()).cloned().collect();
            // A group made from items that are all gone, with no place of its own: nothing to make.
            if to.is_none() && kept.is_empty() {
                return None;
            }
            let to_now = to.as_ref().map(|to| target(doc, to, &kept));
            if kept.len() == items.len() && to_now == *to {
                return Some(Cow::Borrowed(op));
            }
            Some(Cow::Owned(Op::GroupCreate {
                id: id.clone(),
                name: name.clone(),
                color: color.clone(),
                icon: icon.clone(),
                profile: profile.clone(),
                items: kept,
                to: to_now,
            }))
        }
        _ => Some(Cow::Borrowed(op)),
    }
}

fn kept_items<'a>(
    op: &'a Op,
    items: &[ItemId],
    kept: Vec<ItemId>,
    make: impl FnOnce(Vec<ItemId>) -> Op,
) -> Option<Cow<'a, Op>> {
    Some(if kept.len() == items.len() { Cow::Borrowed(op) } else { Cow::Owned(make(kept)) })
}

/// `to` with a gone parent or anchor let go: a parent that is not a group of
/// `to.section` now falls back to the top level, an anchor that is not a
/// sibling there (or is one of `moving`) to the end of the list.
fn target(doc: &Doc, to: &Target, moving: &[ItemId]) -> Target {
    let mut to = to.clone();
    if let Some(parent) = &to.parent
        && !doc
            .item(parent)
            .is_some_and(|group| group.body.is_group() && group.section == to.section)
    {
        to.parent = None;
    }
    let sibling = |anchor: &ItemId| {
        !moving.contains(anchor)
            && doc
                .item(anchor)
                .is_some_and(|item| item.section == to.section && item.parent == to.parent)
    };
    if to.before.as_ref().is_some_and(|anchor| !sibling(anchor)) {
        to.before = None;
    }
    if to.after.as_ref().is_some_and(|anchor| !sibling(anchor)) {
        to.after = None;
    }
    to
}
