//! Where a new workspace goes, decided in the sidebar document
//! (`sidebar-doc-v1`), the one workspace order.
//!
//! Before this module a create picked its slot in the old personal order
//! (`top`: the ordinal right after the home row) and the document followed
//! by a neighbor guess (`sidebar_doc_sync::sync_row`: right after the item
//! of the old-order neighbor when that item is a sibling, else the end of
//! the section). The two orders agree only while Home is the first row and
//! every neighbor is a live top-level item. With rows above Home, `top` put
//! the new workspace in the middle of the list (right below Home); with a
//! neighbor that has no sibling item (closed, pinned, grouped) it went last.
//!
//! Now the create commit names the place in the document itself and adopts
//! the workspace there; its personal row follows the document
//! (`sidebar_doc_sync::write_back`, as after every `sidebar.*` change). One
//! owner decides, one direction derives.
//!
//! The rule, for `workspaces.newPlacement`:
//! - `top`: first in this machine's section; right below Home only when
//!   Home is the first item of that section.
//! - `afterCurrent`: right after the item of the active workspace (an agent
//!   or script create: after its creator and the creator's earlier
//!   children), in its group; `top` when that workspace is Home, is one of
//!   the new ones, or has no item in this machine's section (pinned, a
//!   custom section, closed), or its group shows in another room than the
//!   new workspace's.
//! - `bottom`: not decided here. The old order appends the row and the
//!   document follows (after the last loose row, before trailing groups).

use cmux_layout_reducer::sidebar_doc::reduce::Batch;
use cmux_layout_reducer::sidebar_doc::{Body, Doc, Op, Target, WorkspaceRef};
use rusqlite::Transaction;

use super::sidebar_doc_store as store;
use super::sidebar_doc_sync as sync;
use super::values::workspace_public_id_for_key;
use crate::user_settings::NewWorkspacePlacement;
use crate::workspace_registry::personal_store::{DEFAULT_PROFILE_ID, read_pins};

/// The workspaces a new one can be placed after, by workspace key.
pub(crate) struct Anchors<'a> {
    /// The session's active workspace before the create.
    pub(crate) current: Option<&'a str>,
    /// The live workspace that made it, when the create places by creator.
    pub(crate) creator: Option<&'a str>,
    /// An agent or script create: `afterCurrent` means after `creator`.
    pub(crate) by_creator: bool,
}

/// Adopt the new workspaces `placed` (keys, in creation order; each has its
/// personal row, appended last) into the document at the `placement` slot,
/// and move their personal rows to match. Returns whether the document took
/// them; when it refuses, the rows stay dirty and the old-order sync that
/// follows places them.
pub(crate) fn place(
    transaction: &Transaction<'_>,
    local: &str,
    placed: &[String],
    placement: NewWorkspacePlacement,
    anchors: &Anchors<'_>,
) -> anyhow::Result<bool> {
    // `bottom` stays with the old order: its end is before the trailing
    // groups, which the document's end of section is not.
    if matches!(placement, NewWorkspacePlacement::Bottom) {
        return Ok(false);
    }
    let mut refs = Vec::with_capacity(placed.len());
    for key in placed {
        if let Some(id) = workspace_public_id_for_key(transaction, key)? {
            refs.push(WorkspaceRef::new(local, &id));
        }
    }
    if refs.is_empty() {
        return Ok(false);
    }
    store::with_doc_mut(transaction, |doc| {
        // A workspace the document still holds by its key (an unresolved
        // placement) is resolved by the old-order sync, not adopted again.
        if placed.iter().any(|key| doc.placement_item(local, key).is_some()) {
            return Ok(false);
        }
        let to = target(transaction, doc, local, placed, placement, anchors)?;
        let previous_revision = doc.revision;
        let mut batch = Batch::new(doc);
        sync::try_apply(&mut batch, Op::Adopt { refs, to });
        let applied = batch.finish();
        if applied.changes.is_empty() {
            return Ok(false);
        }
        sync::commit_applied(transaction, previous_revision, doc.revision, &applied)?;
        // The personal rows follow the document (and the dirty marks of the
        // new rows are cleared: the old-order sync must not place them again).
        sync::write_back(transaction, doc, &applied)?;
        Ok(true)
    })
}

/// Move the new group `group` (an old group id, just created with no place
/// of its own) to the top of its machine section in the document, as a new
/// workspace under `top`; its old slot follows the document. Nothing without
/// the document, or when the group is not at a machine section's top level.
pub(crate) fn place_group_at_top(transaction: &Transaction<'_>, group: &str) -> anyhow::Result<()> {
    if !store::is_migrated(transaction)? {
        return Ok(());
    }
    // The old write first: it makes the group's item.
    sync::sync_from_legacy(transaction)?;
    let local = super::values::local_registry_id(transaction)?;
    store::with_doc_mut(transaction, |doc| {
        let Some(item) = sync::group_item(doc, group).cloned() else { return Ok(()) };
        let in_machine =
            doc.section(&item.section).is_some_and(|section| section.kind.machine().is_some());
        if item.parent.is_some() || !in_machine {
            return Ok(());
        }
        let to = top(transaction, doc, &local, &item.section)?;
        let before = doc
            .list(&item.section, None)
            .take_while(|sibling| sibling.id != item.id)
            .last()
            .map(|sibling| sibling.id.clone());
        if before == to.after {
            return Ok(());
        }
        let previous_revision = doc.revision;
        let mut batch = Batch::new(doc);
        sync::try_apply(&mut batch, Op::Move { items: vec![item.id], to });
        let applied = batch.finish();
        if applied.changes.is_empty() {
            return Ok(());
        }
        sync::commit_applied(transaction, previous_revision, doc.revision, &applied)?;
        sync::write_back(transaction, doc, &applied)?;
        Ok(())
    })
}

/// The document place of a new workspace; `None`: the end of this machine's
/// section (a machine with no section yet).
fn target(
    transaction: &Transaction<'_>,
    doc: &Doc,
    local: &str,
    placed: &[String],
    placement: NewWorkspacePlacement,
    anchors: &Anchors<'_>,
) -> anyhow::Result<Option<Target>> {
    let Some(section) = doc.machine_section(local).map(|section| section.id.clone()) else {
        return Ok(None);
    };
    // `top` from inside a group: first in that group, never loose above every
    // group (Leo 2026-11-16: "I make a new space. Getting sent out of the
    // group that I'm"). The app's `top` slot is the same (Lawrence
    // 2026-10-28: Cmd-N in a group keeps the new one in it, at its top).
    if placement == NewWorkspacePlacement::Top
        && !anchors.by_creator
        && let Some(current) = anchors.current
        && let Some(in_group) = after_anchor(transaction, doc, local, placed, current, false)?
        && in_group.parent.is_some()
    {
        return Ok(Some(Target { after: None, index: Some(0), ..in_group }));
    }
    let anchor = match placement {
        NewWorkspacePlacement::Bottom => return Ok(None), // not reached: `place`
        NewWorkspacePlacement::Top => None,
        NewWorkspacePlacement::AfterCurrent if anchors.by_creator => {
            anchors.creator.map(|creator| (creator, true))
        }
        NewWorkspacePlacement::AfterCurrent => anchors.current.map(|current| (current, false)),
    };
    let after = match anchor {
        Some((key, subtree)) => after_anchor(transaction, doc, local, placed, key, subtree)?,
        None => None,
    };
    match after {
        Some(target) => Ok(Some(target)),
        None => Ok(Some(top(transaction, doc, local, &section)?)),
    }
}

/// `top`: first in `section`; right below Home only when Home leads it.
fn top(
    transaction: &Transaction<'_>,
    doc: &Doc,
    local: &str,
    section: &str,
) -> anyhow::Result<Target> {
    let home = super::home_store::live_home(transaction)?
        .and_then(|(id, _)| doc.workspace_item(&WorkspaceRef::new(local, &id)));
    let first = doc.list(section, None).next();
    Ok(match (home, first) {
        (Some(home), Some(first)) if home.id == first.id => {
            Target { section: section.into(), after: Some(home.id.clone()), ..Target::default() }
        }
        _ => Target { section: section.into(), index: Some(0), ..Target::default() },
    })
}

/// Right after the item of workspace `anchor` (with `subtree`, after the
/// siblings below it that `anchor` made, directly or through its children),
/// in its group. `None` when the module doc's `top` fallback applies.
fn after_anchor(
    transaction: &Transaction<'_>,
    doc: &Doc,
    local: &str,
    placed: &[String],
    anchor: &str,
    subtree: bool,
) -> anyhow::Result<Option<Target>> {
    if placed.iter().any(|key| key == anchor) {
        return Ok(None);
    }
    if super::home_store::live_home(transaction)?.is_some_and(|(_, home)| home == anchor) {
        return Ok(None);
    }
    let Some(id) = workspace_public_id_for_key(transaction, anchor)? else { return Ok(None) };
    let Some(item) = doc.workspace_item(&WorkspaceRef::new(local, &id)) else { return Ok(None) };
    if doc.section(&item.section).and_then(|section| section.kind.machine()) != Some(local) {
        return Ok(None);
    }
    let mut last = item;
    if subtree {
        let below = doc
            .list(&item.section, item.parent.as_deref())
            .skip_while(|sibling| sibling.id != item.id)
            .skip(1);
        for sibling in below {
            let Some(reference) = sibling.body.workspace() else { break };
            if reference.session_id != local {
                break;
            }
            let Some(key) = sync::item_key(transaction, local, reference)? else { break };
            if !super::created_by::descends_from(transaction, &key, anchor)? {
                break;
            }
            last = sibling;
        }
    }
    // Into the group only when the new workspace shows in the group's room:
    // a workspace pinned to another room (the app pins before it creates)
    // goes to the top instead.
    if let Some(parent) = item.parent.as_deref() {
        let room = doc.item(parent).and_then(|group| match &group.body {
            Body::Group { profile, .. } => {
                Some(profile.clone().unwrap_or_else(|| DEFAULT_PROFILE_ID.into()))
            }
            _ => None,
        });
        let pins = read_pins(transaction)?;
        let elsewhere = placed.iter().any(|key| {
            pins.iter().any(|pin| {
                pin.session_id == local
                    && pin.workspace_key == *key
                    && room.as_ref().is_some_and(|room| *room != pin.profile)
            })
        });
        if elsewhere {
            return Ok(None);
        }
    }
    Ok(Some(Target {
        section: item.section.clone(),
        parent: item.parent.clone(),
        after: Some(last.id.clone()),
        ..Target::default()
    }))
}
