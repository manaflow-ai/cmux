//! The two ops the old layout had and the document did not: `reset` (the
//! old `layout.reset`) and `item.remove_ref` ("Remove from Sidebar").
//!
//! Reset builds the default sections from the old layout's defaults
//! ([`crate::sidebar_layout::defaults`], the one source of the default
//! look): `sec_top` with Home and the App Store, then an empty Pinned, then
//! one machine section per machine where the old `sec_workspaces` was, the
//! recent agent chats, and the account band at the bottom. It keeps the
//! user's workspaces and groups: those already in a machine section stay in
//! place, and those in Pinned or a removed section go to the end of their
//! machine section. Both ops scan the document once (they are rare user
//! actions, not per-frame work).

use std::collections::HashSet;

use super::migrate::{body_of_layout_ref, kind_of_layout_items_section, section_from_layout};
use super::model::*;
use super::order_key;
use super::reduce::{Tx, ensure_machine_section, place};
use crate::sidebar_layout::{self, Content};

/// The default sections, in display order, each with its default items;
/// the machine sections are named by session at the place of the old
/// workspaces section.
enum Default {
    Section(Box<Section>, Vec<Item>),
    Machines,
}

fn defaults() -> Vec<Default> {
    let mut out = Vec::new();
    for section in sidebar_layout::defaults().sections {
        match &section.content {
            Content::Workspaces => out.push(Default::Machines),
            Content::App => {
                let contribution = section.contribution.clone().unwrap_or_default();
                let new = section_from_layout(&section, SectionKind::App { contribution });
                out.push(Default::Section(Box::new(new), Vec::new()));
            }
            Content::Items | Content::Other(_) => {
                let kind = kind_of_layout_items_section(&section);
                let mut new = section_from_layout(&section, kind);
                new.keeps_closed = new.kind.keeps_closed_by_default();
                let items = section
                    .items
                    .iter()
                    .map(|item| {
                        let mut new_item =
                            Item::new(&item.id, &section.id, body_of_layout_ref(&item.reference));
                        new_item.shows_label = item.shows_label;
                        new_item.span = item.span;
                        new_item
                    })
                    .collect();
                let is_top = section.id == "sec_top";
                out.push(Default::Section(Box::new(new), items));
                if is_top {
                    out.push(Default::Section(Box::new(Section::pinned()), Vec::new()));
                }
            }
        }
    }
    out
}

pub(super) fn reset(tx: &mut Tx) -> Result<(), Refusal> {
    let defaults = defaults();
    // The machine sections in their current order.
    let mut machines: Vec<Section> =
        tx.doc.sections().iter().filter(|s| s.kind.machine().is_some()).cloned().collect();
    machines.sort_by(|a, b| {
        (a.region_rank(), &a.order, &a.id).cmp(&(b.region_rank(), &b.order, &b.id))
    });
    // The sections of the reset document, in order, with default items.
    let mut layout: Vec<(Section, Option<Vec<Item>>)> = Vec::new();
    for default in defaults {
        match default {
            Default::Section(section, items) => layout.push((*section, Some(items))),
            Default::Machines => {
                for old in &machines {
                    let session = old.kind.machine().unwrap_or_default().to_string();
                    let mut section = Section::machine(&session);
                    section.title = old.title.clone();
                    layout.push((section, None));
                }
            }
        }
    }
    // Order keys per region, in this order.
    let mut by_region: Vec<(Region, Vec<usize>)> = Vec::new();
    for (index, (section, _)) in layout.iter().enumerate() {
        match by_region.iter_mut().find(|(region, _)| *region == section.region) {
            Some((_, indexes)) => indexes.push(index),
            None => by_region.push((section.region.clone(), vec![index])),
        }
    }
    for (region, indexes) in &by_region {
        // Keep the current keys when the sections already stand in this
        // order (a reset of a default document changes nothing).
        let current: Option<Vec<String>> = indexes
            .iter()
            .map(|&index| {
                tx.doc
                    .section(&layout[index].0.id)
                    .filter(|existing| existing.region == *region)
                    .map(|existing| existing.order.clone())
            })
            .collect();
        let keys = match current {
            Some(keys) if keys.windows(2).all(|pair| pair[0] < pair[1]) => keys,
            _ => order_key::spread(indexes.len()),
        };
        for (&index, key) in indexes.iter().zip(keys) {
            layout[index].0.order = key;
        }
    }
    let kept: HashSet<SectionId> = layout.iter().map(|(section, _)| section.id.clone()).collect();
    // Sections whose items are cleared: every non-machine section, in
    // display order (Pinned first, so pinned workspaces come first).
    let mut cleared: Vec<Section> =
        tx.doc.sections().iter().filter(|s| s.kind.machine().is_none()).cloned().collect();
    cleared.sort_by(|a, b| {
        (a.region_rank(), &a.order, &a.id).cmp(&(b.region_rank(), &b.order, &b.id))
    });
    for (section, _) in &layout {
        if tx.doc.section(&section.id) != Some(section) {
            tx.put_section(section.clone());
        }
    }
    let first_machine = machines.first().and_then(|s| s.kind.machine()).map(str::to_string);
    for section in &cleared {
        let top: Vec<ItemId> = tx.doc.list(&section.id, None).map(|item| item.id.clone()).collect();
        for id in top {
            let Some(item) = tx.doc.item(&id) else { continue };
            let machine = match &item.body {
                Body::Workspace { reference } => Some(reference.session_id.clone()),
                Body::Group { .. } => tx.doc.item_machine(item).or_else(|| first_machine.clone()),
                _ => None,
            };
            match machine {
                Some(machine) => {
                    let target = ensure_machine_section(tx, &machine);
                    place(tx, std::slice::from_ref(&id), &Target::end(&target))?;
                }
                None if item.body.is_group() => {
                    // No machine section at all: the group stays in Pinned.
                    place(tx, std::slice::from_ref(&id), &Target::end(PINNED_SECTION_ID))?;
                }
                None => {
                    let children: Vec<ItemId> = tx
                        .doc
                        .list(&section.id, Some(id.as_str()))
                        .map(|child| child.id.clone())
                        .collect();
                    for child in children {
                        tx.remove_item(&child);
                    }
                    tx.remove_item(&id);
                }
            }
        }
        if !kept.contains(&section.id) {
            tx.remove_section(&section.id);
        }
    }
    // The default items (Home, App Store, the account), fresh.
    for (section, items) in &layout {
        let Some(items) = items else { continue };
        for (item, key) in items.iter().zip(order_key::spread(items.len())) {
            let mut item = item.clone();
            item.section = section.id.clone();
            item.order = key;
            if tx.doc.item(&item.id) != Some(&item) {
                tx.put_item(item);
            }
        }
    }
    Ok(())
}

/// Whether `body` shows the old layout ref `reference`.
fn shows(body: &Body, reference: &LayoutRef) -> bool {
    super::migrate::layout_ref_of_body(body)
        .is_some_and(|own| own.kind == reference.kind && own.value == reference.value)
}

pub(super) fn remove_ref(tx: &mut Tx, reference: &LayoutRef) -> Result<(), Refusal> {
    let workspace = (reference.kind == "workspace")
        .then(|| super::migrate::parse_layout_workspace(&reference.value))
        .flatten();
    let ids: Vec<ItemId> = match workspace {
        // A workspace is placed once: its index finds it.
        Some(workspace) => {
            tx.doc.workspace_item(&workspace).map(|item| vec![item.id.clone()]).unwrap_or_default()
        }
        None => tx
            .doc
            .items_unordered()
            .filter(|item| shows(&item.body, reference))
            .map(|item| item.id.clone())
            .collect(),
    };
    if ids.is_empty() {
        return Err(Refusal::UnknownItem);
    }
    for id in ids {
        tx.remove_item(&id);
    }
    Ok(())
}
