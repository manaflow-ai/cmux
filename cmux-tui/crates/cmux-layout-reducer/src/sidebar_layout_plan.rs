//! The section layout's planners: user commands and one-time migrations
//! turned into ordinary layout ops ([`sidebar_layout::Op`]) against the
//! document a window shows. Pure; the caller sends the ops, and the owner's
//! reducer ([`sidebar_layout::reduce`]) stays the only judge. The app calls
//! them through `cmux_layout_reducer_json` op `sidebar_layout_plan`
//! ([`respond`]); they replace the app's Swift copies
//! (`SidebarLayoutDocument+Pins`, `+RailMigration`, `+RetiredItems`,
//! `+Projection`, `SidebarLayoutPlanner`, `SidebarRegionReorder.op`).
//!
//! Ids are minted by the caller (`itm_…`, `sec_…`) and passed in, so a plan
//! is a pure function of its request.

use serde::{Deserialize, Serialize};
use serde_json::Value;
use unicode_segmentation::UnicodeSegmentation;

use crate::sidebar_layout::{
    self, Alignment, Arrangement, ArrangementLayout, Content, Document, Item, ItemRef, Look, Op,
    Region, Section, SectionPatch, Update,
};

pub const TOP_SECTION_ID: &str = "sec_top";
pub const WORKSPACES_SECTION_ID: &str = "sec_workspaces";
pub const BOTTOM_SECTION_ID: &str = "sec_bottom";
/// Pinned (PINNED-ITEMS-END-TO-END): a top section under `sec_top` that the
/// first pin adds.
pub const PINNED_SECTION_ID: &str = "sec_pinned";
/// Longest stored item label (characters), like the app's `LayoutItem.maxLabelLength`.
pub const MAX_LABEL_CHARS: usize = 200;
/// Built-ins that are first-party apps now (R63/R64).
pub const FIRST_PARTY_APPS: [(&str, &str); 2] =
    [("home", "cmux/home"), ("app_store", "cmux/app-store")];
/// Built-ins that are no longer sidebar items (S1, DOGFOOD-CALL-2026-10-06).
pub const RETIRED_BUILT_INS: [&str; 2] = ["new_workspace", "import_sync"];

const APPEND: i64 = i64::MAX;

/// A list position as a wire index.
fn slot(position: usize) -> i64 {
    i64::try_from(position).unwrap_or(APPEND)
}

// MARK: lookups

fn section<'a>(document: &'a Document, id: &str) -> Option<&'a Section> {
    document.sections.iter().find(|section| section.id == id)
}

fn first_item<'a>(document: &'a Document, reference: &ItemRef) -> Option<&'a Item> {
    document
        .sections
        .iter()
        .flat_map(|section| &section.items)
        .find(|item| item.reference.same(reference))
}

/// Sections of `region` that show in every room (room nil), in order.
fn shared_sections<'a>(
    document: &'a Document,
    region: &'a Region,
) -> impl Iterator<Item = &'a Section> {
    document
        .sections
        .iter()
        .filter(move |section| &section.region == region && section.room.is_none())
}

fn is_pinned(document: &Document, reference: &ItemRef) -> bool {
    section(document, PINNED_SECTION_ID)
        .is_some_and(|pinned| pinned.items.iter().any(|item| item.reference.same(reference)))
}

/// Whether `reference` shows in the top region in any room (a tile or a top row).
pub fn is_on_top(document: &Document, reference: &ItemRef) -> bool {
    document.sections.iter().any(|section| {
        section.region == Region::Top
            && section.items.iter().any(|item| item.reference.same(reference))
    })
}

/// The label the app stores with an item: at most 200 characters (grapheme
/// clusters, Swift's `String.prefix`), none when empty.
fn labelled(mut item: Item, label: Option<&str>) -> Item {
    if let Some(label) = label {
        let label: String = label.graphemes(true).take(MAX_LABEL_CHARS).collect();
        if !label.is_empty() {
            item.extra.insert("label".into(), Value::String(label));
        }
    }
    item
}

/// `document` with `ops` applied by the reducer; `document` itself when one is refused.
pub fn applying(document: &Document, ops: &[Op]) -> Document {
    let mut result = document.clone();
    for op in ops {
        match sidebar_layout::reduce(&result, op) {
            Ok(next) => result = next,
            Err(_) => return document.clone(),
        }
    }
    result
}

// MARK: pins (SidebarLayoutDocument+Pins)

/// The Pinned section holding `items`: top, built-in look, list.
pub fn pinned_section(items: Vec<Item>) -> Section {
    let mut section = Section::new(PINNED_SECTION_ID, Region::Top, Look::BuiltIn, Content::Items);
    section.items = items;
    section
}

/// Pins `reference` as the last tile, adding `sec_pinned` (under `sec_top`,
/// else last in the top region) when it is missing. None when it is pinned
/// already. `label` (the workspace's name now) is stored with the tile.
pub fn pin_op(
    document: &Document,
    reference: &ItemRef,
    label: Option<&str>,
    new_item: &str,
) -> Option<Op> {
    if is_pinned(document, reference) {
        return None;
    }
    let item = labelled(Item::new(new_item, reference.clone(), true), label);
    if section(document, PINNED_SECTION_ID).is_some() {
        return Some(Op::ItemAdd { item, section: PINNED_SECTION_ID.into(), index: APPEND });
    }
    let index = shared_sections(document, &Region::Top)
        .position(|section| section.id == TOP_SECTION_ID)
        .map_or(APPEND, |top| slot(top).saturating_add(1));
    Some(Op::SectionAdd { section: pinned_section(vec![item]), index })
}

/// Unpins `reference` (its tile only; a top row of the same ref stays).
pub fn unpin_op(document: &Document, reference: &ItemRef) -> Option<Op> {
    let pinned = section(document, PINNED_SECTION_ID)?;
    let item = pinned.items.iter().find(|item| item.reference.same(reference))?;
    Some(Op::ItemRemove { id: item.id.clone() })
}

/// One ref of a multi-pin: the ref, its label, and the item id a pin mints.
#[derive(Debug, Clone, PartialEq, Eq, Deserialize, Serialize)]
pub struct PinRef {
    #[serde(rename = "ref")]
    pub reference: ItemRef,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub label: Option<String>,
    pub new_item: String,
}

/// The ops that pin (or unpin) every ref, each planned against the document
/// the earlier ones leave, so they apply in order as one change. Refs
/// already in the asked state add no op.
pub fn pin_ops(document: &Document, refs: &[PinRef], pinned: bool) -> Vec<Op> {
    let mut document = document.clone();
    let mut ops = Vec::new();
    for pin in refs {
        let op = if pinned {
            pin_op(&document, &pin.reference, pin.label.as_deref(), &pin.new_item)
        } else {
            unpin_op(&document, &pin.reference)
        };
        let Some(op) = op else { continue };
        let Ok(next) = sidebar_layout::reduce(&document, &op) else { continue };
        ops.push(op);
        document = next;
    }
    ops
}

/// One-time move of legacy pinned workspaces (`workspace-pin-v1`) into
/// tiles: like [`pin_ops`], skipping refs the top region already shows
/// (a tile or a top row). Lossless: nothing is removed.
pub fn legacy_pin_migration_ops(document: &Document, refs: &[PinRef]) -> Vec<Op> {
    let mut document = document.clone();
    let mut ops = Vec::new();
    for pin in refs {
        if is_on_top(&document, &pin.reference) {
            continue;
        }
        let Some(op) = pin_op(&document, &pin.reference, pin.label.as_deref(), &pin.new_item)
        else {
            continue;
        };
        let Ok(next) = sidebar_layout::reduce(&document, &op) else { continue };
        ops.push(op);
        document = next;
    }
    ops
}

/// Removes `reference` from the top rows ("Remove from Top"; tiles stay).
pub fn remove_from_top_op(document: &Document, reference: &ItemRef) -> Option<Op> {
    let holder = document.sections.iter().find(|section| {
        section.region == Region::Top
            && section.id != PINNED_SECTION_ID
            && section.items.iter().any(|item| item.reference.same(reference))
    })?;
    let item = holder.items.iter().find(|item| item.reference.same(reference))?;
    Some(Op::ItemRemove { id: item.id.clone() })
}

/// Adds `reference` as the last row of `sec_top` ("Add to Top"), else of the
/// first shared top items section other than Pinned, else in a new top
/// section. None when a top row already shows it (its tile does not count).
pub fn add_to_top_op(
    document: &Document,
    reference: &ItemRef,
    label: Option<&str>,
    new_item: &str,
    new_section: &str,
) -> Option<Op> {
    if remove_from_top_op(document, reference).is_some() {
        return None;
    }
    let item = labelled(Item::new(new_item, reference.clone(), true), label);
    let target =
        section(document, TOP_SECTION_ID).map(|section| section.id.clone()).or_else(|| {
            shared_sections(document, &Region::Top)
                .find(|section| {
                    section.content == Content::Items && section.id != PINNED_SECTION_ID
                })
                .map(|section| section.id.clone())
        });
    if let Some(target) = target {
        return Some(Op::ItemAdd { item, section: target, index: APPEND });
    }
    let mut section = Section::new(new_section, Region::Top, Look::BuiltIn, Content::Items);
    section.items = vec![item];
    Some(Op::SectionAdd { section, index: 0 })
}

/// The op that undoes `op` applied to `document` (RECOVERABLE-BY-DEFAULT,
/// P4): a removed item (by id, or by a ref only one item has) comes back
/// with its id at its section and index; an added item (alone, or the only
/// item of an added section) is removed. None for other ops, or when `op`
/// changes nothing.
pub fn inverse(document: &Document, op: &Op) -> Option<Op> {
    let restore = |s: usize, i: usize| {
        let section = document.sections.get(s)?;
        Some(Op::ItemAdd {
            item: section.items.get(i)?.clone(),
            section: section.id.clone(),
            index: slot(i),
        })
    };
    match op {
        Op::ItemRemove { id } => {
            let (s, i) = sidebar_layout::locate(id, &document.sections)?;
            restore(s, i)
        }
        Op::ItemAdd { item, section: target, .. } => {
            let target = section(document, target)?;
            if target.items.iter().any(|existing| existing.reference.same(&item.reference)) {
                return None;
            }
            Some(Op::ItemRemove { id: item.id.clone() })
        }
        Op::ItemRemoveRef { reference } => {
            let mut holders = document.sections.iter().enumerate().flat_map(|(s, section)| {
                section
                    .items
                    .iter()
                    .enumerate()
                    .filter(|(_, item)| item.reference.same(reference))
                    .map(move |(i, _)| (s, i))
            });
            let first = holders.next()?;
            if holders.next().is_some() {
                return None;
            }
            restore(first.0, first.1)
        }
        Op::SectionAdd { section: added, .. } => {
            let [only] = added.items.as_slice() else { return None };
            if section(document, &added.id).is_some() {
                return None;
            }
            Some(Op::ItemRemove { id: only.id.clone() })
        }
        _ => None,
    }
}

// MARK: add and remove from the sidebar (SidebarLayoutPlanner)

/// Adds `reference` to the first items section of `region` that shows in
/// every room: first in the top region, last elsewhere. With no such
/// section, adds one (no title, `look`) holding the item. None when the
/// layout already holds `reference` anywhere.
pub fn add_op(
    document: &Document,
    reference: &ItemRef,
    region: &Region,
    look: &Look,
    shows_label: bool,
    new_item: &str,
    new_section: &str,
) -> Option<Op> {
    if first_item(document, reference).is_some() {
        return None;
    }
    let item = Item::new(new_item, reference.clone(), shows_label);
    let index = if *region == Region::Top { 0 } else { APPEND };
    if let Some(target) =
        shared_sections(document, region).find(|section| section.content == Content::Items)
    {
        return Some(Op::ItemAdd { item, section: target.id.clone(), index });
    }
    let mut section = Section::new(new_section, region.clone(), look.clone(), Content::Items);
    section.items = vec![item];
    Some(Op::SectionAdd { section, index })
}

/// Removes every item with `reference` ("Remove Home from Sidebar"); None
/// when the layout holds none.
pub fn remove_op(document: &Document, reference: &ItemRef) -> Option<Op> {
    first_item(document, reference)?;
    Some(Op::ItemRemoveRef { reference: ItemRef::new(&reference.kind, &reference.value) })
}

// MARK: hidden rows (SidebarLayoutDocument+Projection)

/// An insertion slot in the visible layout (`projected`) as an index in the
/// saved layout (`stored`). Moves exclude their own item; drop-to-pin
/// insertions exclude nothing. Hidden rows stay saved while the insertion
/// follows a visible neighbour.
pub fn stored_insertion_index(
    stored: &Document,
    index: i64,
    section_id: &str,
    projected: &Document,
    excluding: Option<&str>,
) -> i64 {
    let (Some(visible), Some(full)) = (section(projected, section_id), section(stored, section_id))
    else {
        return index;
    };
    let keep = |item: &&Item| Some(item.id.as_str()) != excluding;
    let visible_rest: Vec<&Item> = visible.items.iter().filter(keep).collect();
    let full_rest: Vec<&Item> = full.items.iter().filter(keep).collect();
    if visible_rest.len() == full_rest.len() {
        return index;
    }
    let position = |id: &str| full_rest.iter().position(|item| item.id == id);
    if let Some(next) = usize::try_from(index).ok().and_then(|slot| visible_rest.get(slot))
        && let Some(position) = position(&next.id)
    {
        return slot(position);
    }
    if let Some(position) = visible_rest.last().and_then(|last| position(&last.id)) {
        return slot(position).saturating_add(1);
    }
    slot(full_rest.len())
}

/// A visible row move as a move in the saved layout's index space.
pub fn translating_hidden_item_index(op: &Op, projected: &Document, stored: &Document) -> Op {
    match op {
        Op::ItemMove { id, section, index } => Op::ItemMove {
            id: id.clone(),
            section: section.clone(),
            index: stored_insertion_index(stored, *index, section, projected, Some(id)),
        },
        other => other.clone(),
    }
}

// MARK: region reorder (SidebarRegionReorder)

/// What a region drag moves: one item, or a section by its header.
#[derive(Debug, Clone, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum DragSubject {
    Item(String),
    Section(String),
}

/// The layout op that gives the document the order of `shown` (the sections
/// the region shows, with the move applied and hidden items left out):
/// `subject` goes before the shown neighbour that follows it, or last.
pub fn region_move_op(subject: &DragSubject, shown: &[Section], document: &Document) -> Option<Op> {
    match subject {
        DragSubject::Item(id) => {
            let (t, p) = sidebar_layout::locate(id, shown)?;
            let shown_section = shown.get(t)?;
            let target = section(document, &shown_section.id)?;
            let rest: Vec<&Item> = target.items.iter().filter(|item| &item.id != id).collect();
            let next = shown_section
                .items
                .iter()
                .skip(p.saturating_add(1))
                .find_map(|item| rest.iter().position(|kept| kept.id == item.id));
            Some(Op::ItemMove {
                id: id.clone(),
                section: target.id.clone(),
                index: slot(next.unwrap_or(rest.len())),
            })
        }
        DragSubject::Section(id) => {
            let p = shown.iter().position(|section| &section.id == id)?;
            let region = &shown.get(p)?.region;
            let rest: Vec<&Section> = document
                .sections
                .iter()
                .filter(|section| &section.region == region && &section.id != id)
                .collect();
            let next = shown
                .iter()
                .skip(p.saturating_add(1))
                .filter(|section| &section.region == region)
                .find_map(|section| rest.iter().position(|kept| kept.id == section.id));
            Some(Op::SectionMove {
                id: id.clone(),
                region: region.clone(),
                index: slot(next.unwrap_or(rest.len())),
            })
        }
    }
}

/// The document move for an app section dropped in a pinned band's shown
/// order, before `before` (or last). Hidden sections keep their document
/// positions. None for a section that is not an app section, or a region
/// other than top or bottom.
pub fn app_section_move_op(
    id: &str,
    region: &Region,
    before: Option<&str>,
    shown: &[Section],
    document: &Document,
) -> Option<Op> {
    let mut moved = section(document, id)?.clone();
    if moved.content != Content::App || !matches!(region, Region::Top | Region::Bottom) {
        return None;
    }
    moved.region = region.clone();
    let mut sections: Vec<Section> =
        shown.iter().filter(|section| section.id != id).cloned().collect();
    let index = before
        .and_then(|next| sections.iter().position(|section| section.id == next))
        .unwrap_or(sections.len());
    sections.insert(index, moved);
    region_move_op(&DragSubject::Section(id.into()), &sections, document)
}

// MARK: migrations (SidebarLayoutDocument+RailMigration, +RetiredItems)

fn item(id: &str, kind: &str, value: &str, shows_label: bool, span: Option<i64>) -> Item {
    let mut item = Item::new(id, ItemRef::new(kind, value), shows_label);
    item.span = span;
    item
}

fn bottom_section(
    layout: ArrangementLayout,
    align: Alignment,
    columns: Option<i64>,
    items: Vec<Item>,
) -> Section {
    let mut section =
        Section::new(BOTTOM_SECTION_ID, Region::Bottom, Look::BuiltIn, Content::Items);
    section.arrangement = Arrangement { columns, ..Arrangement::new(layout, align) };
    section.items = items;
    section
}

fn top_section(max_rows: Option<i64>, items: Vec<Item>) -> Section {
    let mut section = Section::new(TOP_SECTION_ID, Region::Top, Look::BuiltIn, Content::Items);
    section.max_rows = max_rows;
    section.items = items;
    section
}

fn workspaces_section() -> Section {
    Section::new(WORKSPACES_SECTION_ID, Region::Middle, Look::List, Content::Workspaces)
}

/// SIDEBAR-FOOTER-MINIMAL's footer (the avatar, then the gear, icons only,
/// leading), the default until amendment 2, only to recognize it.
pub fn minimal_bottom_section() -> Section {
    bottom_section(
        ArrangementLayout::Inline,
        Alignment::Leading,
        None,
        vec![
            item("itm_account", "built_in", "account", false, None),
            item("itm_settings", "built_in", "settings", false, None),
        ],
    )
}

/// R53's bottom row (Settings with its label over 7 of 8 columns, the
/// account over the last), only to recognize it.
pub fn grid_bottom_section() -> Section {
    bottom_section(
        ArrangementLayout::Grid,
        Alignment::Fill,
        Some(8),
        vec![
            item("itm_settings", "built_in", "settings", true, Some(7)),
            item("itm_account", "built_in", "account", false, Some(1)),
        ],
    )
}

/// The sections default before R53 (one inline bottom line with Settings
/// leading and the account trailing), only to recognize it.
pub fn inline_bottom_defaults() -> Vec<Section> {
    vec![
        top_section(
            None,
            vec![
                item("itm_home", "built_in", "home", true, None),
                item("itm_app_store", "built_in", "app_store", true, None),
                item("itm_app_coderouter", "app", "cmux/coderouter", true, None),
            ],
        ),
        workspaces_section(),
        bottom_section(
            ArrangementLayout::Inline,
            Alignment::Fill,
            None,
            vec![
                item("itm_settings", "built_in", "settings", true, None),
                item("itm_account", "built_in", "account", false, None),
            ],
        ),
    ]
}

/// The window rail's default layout as it was stored (Leo, 2026-10-03,
/// #17153), only to recognize it.
pub fn rail_defaults() -> Vec<Section> {
    vec![
        top_section(
            Some(4),
            vec![
                item("itm_home", "built_in", "home", true, None),
                item("itm_app_store", "built_in", "app_store", true, None),
                item("itm_history", "built_in", "history", true, None),
                item("itm_notifications", "built_in", "notifications", true, None),
                item("itm_settings", "built_in", "settings", true, None),
                item("itm_customize", "built_in", "customize", true, None),
                item("itm_app_coderouter", "app", "cmux/coderouter", true, None),
            ],
        ),
        workspaces_section(),
        bottom_section(
            ArrangementLayout::Inline,
            Alignment::Fill,
            None,
            vec![item("itm_account", "built_in", "account", false, None)],
        ),
    ]
}

fn remove(id: &str) -> Op {
    Op::ItemRemove { id: id.into() }
}

/// The ops that move a layout equal to an older default to the current
/// one, or none; a layout the user changed is theirs and never migrates.
/// The revision does not matter. Settings and the account keep their ids.
pub fn sections_migration_ops(document: &Document) -> Vec<Op> {
    // The profile control footer: the avatar alone, icon only, on one
    // leading line (SIDEBAR-FOOTER-AND-SPACE-MENU amendment 2). Items are
    // re-added to drop a span and a label.
    let profile_footer = || {
        vec![
            Op::SectionUpdate {
                id: BOTTOM_SECTION_ID.into(),
                patch: SectionPatch {
                    layout: Some(ArrangementLayout::Inline),
                    align: Some(Alignment::Leading),
                    columns: Update::Clear,
                    ..SectionPatch::default()
                },
            },
            remove("itm_settings"),
            remove("itm_account"),
            Op::ItemAdd {
                item: item("itm_account", "built_in", "account", false, None),
                section: BOTTOM_SECTION_ID.into(),
                index: 0,
            },
        ]
    };
    let bottom = section(document, BOTTOM_SECTION_ID);
    if document.sections == inline_bottom_defaults() || bottom == Some(&grid_bottom_section()) {
        return profile_footer();
    }
    // SIDEBAR-FOOTER-MINIMAL's untouched footer (avatar, then gear) loses the gear.
    if bottom == Some(&minimal_bottom_section()) {
        return vec![remove("itm_settings")];
    }
    if document.sections != rail_defaults() {
        return Vec::new();
    }
    let mut ops = vec![
        remove("itm_history"),
        remove("itm_notifications"),
        remove("itm_customize"),
        Op::SectionUpdate {
            id: TOP_SECTION_ID.into(),
            patch: SectionPatch { max_rows: Update::Clear, ..SectionPatch::default() },
        },
    ];
    ops.extend(profile_footer());
    ops
}

/// The ops that turn built-in Home and App Store items into app items
/// (R63/R64). Each item keeps its id, place and every other field (label
/// visibility, span, label, keys from a newer client); only its ref changes.
pub fn app_ref_migration_ops(document: &Document) -> Vec<Op> {
    let mut ops = Vec::new();
    for section in &document.sections {
        for (index, old) in section.items.iter().enumerate() {
            if old.reference.kind != "built_in" {
                continue;
            }
            let Some((_, app)) =
                FIRST_PARTY_APPS.iter().find(|(built_in, _)| *built_in == old.reference.value)
            else {
                continue;
            };
            let mut moved = old.clone();
            moved.reference.kind = "app".into();
            moved.reference.value = (*app).into();
            ops.push(remove(&old.id));
            ops.push(Op::ItemAdd { item: moved, section: section.id.clone(), index: slot(index) });
        }
    }
    ops
}

/// One removal per item, in any section, whose ref is a retired built-in.
pub fn retired_item_ops(document: &Document) -> Vec<Op> {
    document
        .sections
        .iter()
        .flat_map(|section| &section.items)
        .filter(|item| {
            item.reference.kind == "built_in"
                && RETIRED_BUILT_INS.contains(&item.reference.value.as_str())
        })
        .map(|item| remove(&item.id))
        .collect()
}

/// Every migration in order (sections, then app refs, then retired items),
/// as one op list that applies to `document`. The All chats section is no
/// longer offered (cx-n0i9), so no migration adds it.
pub fn layout_migration_ops(document: &Document) -> Vec<Op> {
    let mut ops = sections_migration_ops(document);
    ops.extend(app_ref_migration_ops(&applying(document, &ops)));
    let retired = retired_item_ops(&applying(document, &ops));
    ops.extend(retired);
    ops
}

// MARK: the wire

/// The app's request (`cmux_layout_reducer_json` op `sidebar_layout_plan`),
/// tagged by `plan`.
#[derive(Debug, Deserialize)]
#[serde(tag = "plan", rename_all = "snake_case")]
pub enum Request {
    Pin {
        document: Document,
        #[serde(rename = "ref")]
        reference: ItemRef,
        #[serde(default)]
        label: Option<String>,
        new_item: String,
    },
    Unpin {
        document: Document,
        #[serde(rename = "ref")]
        reference: ItemRef,
    },
    /// `pin_ops`: `{"pins": [...], "pinned": bool}`.
    PinAll {
        document: Document,
        pins: Vec<PinRef>,
        pinned: bool,
    },
    LegacyPins {
        document: Document,
        pins: Vec<PinRef>,
    },
    AddToTop {
        document: Document,
        #[serde(rename = "ref")]
        reference: ItemRef,
        #[serde(default)]
        label: Option<String>,
        new_item: String,
        new_section: String,
    },
    RemoveFromTop {
        document: Document,
        #[serde(rename = "ref")]
        reference: ItemRef,
    },
    Inverse {
        document: Document,
        op: Op,
    },
    Add {
        document: Document,
        #[serde(rename = "ref")]
        reference: ItemRef,
        region: Region,
        look: Look,
        shows_label: bool,
        new_item: String,
        new_section: String,
    },
    Remove {
        document: Document,
        #[serde(rename = "ref")]
        reference: ItemRef,
    },
    StoredIndex {
        stored: Document,
        projected: Document,
        section: String,
        index: i64,
        #[serde(default)]
        excluding: Option<String>,
    },
    TranslateHiddenIndex {
        op: Op,
        projected: Document,
        stored: Document,
    },
    RegionMove {
        subject: DragSubject,
        shown: Vec<Section>,
        document: Document,
    },
    AppSectionMove {
        id: String,
        region: Region,
        #[serde(default)]
        before: Option<String>,
        shown: Vec<Section>,
        document: Document,
    },
    Migrate {
        document: Document,
    },
}

/// `{"op": ...}` (absent: nothing to do), `{"ops": [...]}` or `{"index": n}`.
#[derive(Debug, Default, PartialEq, Serialize)]
pub struct Reply {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub op: Option<Op>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub ops: Option<Vec<Op>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub index: Option<i64>,
}

pub fn respond(request: &Request) -> Reply {
    let op = |op: Option<Op>| Reply { op, ..Reply::default() };
    let ops = |ops: Vec<Op>| Reply { ops: Some(ops), ..Reply::default() };
    match request {
        Request::Pin { document, reference, label, new_item } => {
            op(pin_op(document, reference, label.as_deref(), new_item))
        }
        Request::Unpin { document, reference } => op(unpin_op(document, reference)),
        Request::PinAll { document, pins, pinned } => ops(pin_ops(document, pins, *pinned)),
        Request::LegacyPins { document, pins } => ops(legacy_pin_migration_ops(document, pins)),
        Request::AddToTop { document, reference, label, new_item, new_section } => {
            op(add_to_top_op(document, reference, label.as_deref(), new_item, new_section))
        }
        Request::RemoveFromTop { document, reference } => {
            op(remove_from_top_op(document, reference))
        }
        Request::Inverse { document, op: undone } => op(inverse(document, undone)),
        Request::Add { document, reference, region, look, shows_label, new_item, new_section } => {
            op(add_op(document, reference, region, look, *shows_label, new_item, new_section))
        }
        Request::Remove { document, reference } => op(remove_op(document, reference)),
        Request::StoredIndex { stored, projected, section, index, excluding } => Reply {
            index: Some(stored_insertion_index(
                stored,
                *index,
                section,
                projected,
                excluding.as_deref(),
            )),
            ..Reply::default()
        },
        Request::TranslateHiddenIndex { op: moved, projected, stored } => {
            op(Some(translating_hidden_item_index(moved, projected, stored)))
        }
        Request::RegionMove { subject, shown, document } => {
            op(region_move_op(subject, shown, document))
        }
        Request::AppSectionMove { id, region, before, shown, document } => {
            op(app_section_move_op(id, region, before.as_deref(), shown, document))
        }
        Request::Migrate { document } => ops(layout_migration_ops(document)),
    }
}

#[cfg(test)]
#[path = "sidebar_layout_plan_tests.rs"]
mod tests;
