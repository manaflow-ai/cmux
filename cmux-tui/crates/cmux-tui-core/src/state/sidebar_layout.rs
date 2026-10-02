//! The pure reducer of the sidebar section layout (`sidebar-layout-v1`,
//! plans/cmux-next/sidebar-sections.md section 4). No I/O. It mirrors the
//! app's `SidebarLayoutReducer` (CmuxNextSidebar/Sections) exactly: same
//! JSON, same index rules, same invariants L1-L6, same reject reasons.

use serde::{Deserialize, Serialize};

pub const MAX_SECTIONS: usize = 32;
pub const MAX_ITEMS: usize = 200;
pub const MAX_TITLE_CHARS: usize = 80;
pub const MAX_ROWS: std::ops::RangeInclusive<i64> = 1..=50;
pub const GAP_RANGE: std::ops::RangeInclusive<i64> = 0..=32;
pub const COLUMNS_RANGE: std::ops::RangeInclusive<i64> = 1..=12;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Region {
    Top,
    Middle,
    Bottom,
}

impl Region {
    fn rank(self) -> u8 {
        match self {
            Region::Top => 0,
            Region::Middle => 1,
            Region::Bottom => 2,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum Look {
    BuiltIn,
    List,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Content {
    Items,
    Workspaces,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Default)]
#[serde(rename_all = "snake_case")]
pub enum ArrangementLayout {
    #[default]
    List,
    Inline,
    Grid,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum Alignment {
    Leading,
    Center,
    Trailing,
    Fill,
}

/// Unknown values from a newer app read as the default (L5), like the
/// app's decoder, so a stored document never stops parsing.
macro_rules! lenient {
    ($name:ident, $default:ident, $($text:literal => $variant:ident),+) => {
        impl<'de> Deserialize<'de> for $name {
            fn deserialize<D: serde::Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
                Ok(match Option::<String>::deserialize(deserializer)?.as_deref() {
                    $(Some($text) => $name::$variant,)+
                    _ => $name::$default,
                })
            }
        }
    };
}

lenient!(Look, List, "built_in" => BuiltIn, "list" => List);
lenient!(ArrangementLayout, List, "list" => List, "inline" => Inline, "grid" => Grid);
lenient!(Alignment, Leading, "leading" => Leading, "center" => Center, "trailing" => Trailing, "fill" => Fill);

/// `{layout, align, gap?, columns?}`; every key optional on input (layout
/// list, align leading).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
pub struct Arrangement {
    pub layout: ArrangementLayout,
    pub align: Alignment,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub gap: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub columns: Option<i64>,
}

impl Default for Arrangement {
    fn default() -> Self {
        Arrangement {
            layout: ArrangementLayout::List,
            align: Alignment::Leading,
            gap: None,
            columns: None,
        }
    }
}

impl<'de> Deserialize<'de> for Arrangement {
    fn deserialize<D: serde::Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        #[derive(Deserialize)]
        struct Raw {
            #[serde(default)]
            layout: Option<ArrangementLayout>,
            #[serde(default)]
            align: Option<Alignment>,
            #[serde(default)]
            gap: Option<i64>,
            #[serde(default)]
            columns: Option<i64>,
        }
        let raw = Raw::deserialize(deserializer)?;
        Ok(Arrangement {
            layout: raw.layout.unwrap_or_default(),
            align: raw.align.unwrap_or(Alignment::Leading),
            gap: raw.gap,
            columns: raw.columns,
        })
    }
}

impl Arrangement {
    pub fn is_valid(&self) -> bool {
        self.gap.is_none_or(|gap| GAP_RANGE.contains(&gap))
            && self.columns.is_none_or(|columns| COLUMNS_RANGE.contains(&columns))
    }
}

/// What an item points at; unknown kinds are kept verbatim (L5).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ItemRef {
    pub kind: String,
    pub value: String,
}

fn yes() -> bool {
    true
}

/// A boolean that may be absent or null: true.
fn true_unless_false<'de, D: serde::Deserializer<'de>>(deserializer: D) -> Result<bool, D::Error> {
    Ok(Option::<bool>::deserialize(deserializer)?.unwrap_or(true))
}

/// A value that may be null: its default.
fn default_if_null<'de, D: serde::Deserializer<'de>, T: Deserialize<'de> + Default>(
    deserializer: D,
) -> Result<T, D::Error> {
    Ok(Option::<T>::deserialize(deserializer)?.unwrap_or_default())
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Item {
    pub id: String,
    #[serde(rename = "ref")]
    pub reference: ItemRef,
    #[serde(default = "yes", deserialize_with = "true_unless_false")]
    pub shows_label: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Section {
    pub id: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub title: Option<String>,
    #[serde(default = "yes", deserialize_with = "true_unless_false")]
    pub shows_title: bool,
    pub region: Region,
    pub look: Look,
    #[serde(default, deserialize_with = "default_if_null")]
    pub arrangement: Arrangement,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub room: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub max_rows: Option<i64>,
    pub content: Content,
    #[serde(default, deserialize_with = "default_if_null")]
    pub items: Vec<Item>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Document {
    pub revision: u64,
    pub sections: Vec<Section>,
}

/// A JSON field that may be absent (keep), null (clear) or set.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub enum Update<T> {
    #[default]
    Keep,
    Clear,
    Set(T),
}

impl<'de, T: Deserialize<'de>> Deserialize<'de> for Update<T> {
    fn deserialize<D: serde::Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        Ok(match Option::<T>::deserialize(deserializer)? {
            None => Update::Clear,
            Some(value) => Update::Set(value),
        })
    }
}

impl<T: Clone> Update<T> {
    fn apply(&self, field: &mut Option<T>) {
        match self {
            Update::Keep => {}
            Update::Clear => *field = None,
            Update::Set(value) => *field = Some(value.clone()),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Default, Deserialize)]
pub struct SectionPatch {
    #[serde(default)]
    pub title: Update<String>,
    #[serde(default)]
    pub look: Option<Look>,
    #[serde(default)]
    pub room: Update<String>,
    #[serde(default)]
    pub max_rows: Update<i64>,
    #[serde(default)]
    pub shows_title: Option<bool>,
    /// Arrangement fields, each patched alone (concurrent edits of
    /// different fields both apply).
    #[serde(default)]
    pub layout: Option<ArrangementLayout>,
    #[serde(default)]
    pub align: Option<Alignment>,
    #[serde(default)]
    pub gap: Update<i64>,
    #[serde(default)]
    pub columns: Update<i64>,
}

/// One change, tagged by `kind` like the app's `SidebarLayoutOp`.
#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
#[serde(tag = "kind")]
pub enum Op {
    #[serde(rename = "section.add")]
    SectionAdd { section: Section, index: i64 },
    #[serde(rename = "section.update")]
    SectionUpdate { id: String, patch: SectionPatch },
    #[serde(rename = "section.move")]
    SectionMove { id: String, region: Region, index: i64 },
    #[serde(rename = "section.remove")]
    SectionRemove { id: String },
    #[serde(rename = "item.add")]
    ItemAdd { item: Item, section: String, index: i64 },
    #[serde(rename = "item.move")]
    ItemMove { id: String, section: String, index: i64 },
    #[serde(rename = "item.remove")]
    ItemRemove { id: String },
    /// Remove every item with this ref ("Remove from Sidebar").
    #[serde(rename = "item.remove_ref")]
    ItemRemoveRef {
        #[serde(rename = "ref")]
        reference: ItemRef,
    },
    #[serde(rename = "item.update")]
    ItemUpdate { id: String, shows_label: bool },
    #[serde(rename = "layout.reset")]
    Reset,
}

/// Why the owner refused an op; `as_str` is the wire reason. (A reused
/// idempotency key is the commit path's `idempotency.conflict`.)
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Reject {
    WorkspacesRequired,
    UnknownSection,
    UnknownItem,
    DuplicateId,
    DuplicateRef,
    InvalidTitle,
    InvalidMaxRows,
    InvalidArrangement,
    TooMany,
}

impl Reject {
    pub fn as_str(self) -> &'static str {
        match self {
            Reject::WorkspacesRequired => "workspaces_required",
            Reject::UnknownSection => "unknown_section",
            Reject::UnknownItem => "unknown_item",
            Reject::DuplicateId => "duplicate_id",
            Reject::DuplicateRef => "duplicate_ref",
            Reject::InvalidTitle => "invalid_title",
            Reject::InvalidMaxRows => "invalid_max_rows",
            Reject::InvalidArrangement => "invalid_arrangement",
            Reject::TooMany => "too_many",
        }
    }
}

fn builtin(id: &str, value: &str, shows_label: bool) -> Item {
    Item {
        id: id.into(),
        reference: ItemRef { kind: "built_in".into(), value: value.into() },
        shows_label,
    }
}

/// Top: Home, then the App Store. Middle: workspaces. Bottom: Settings with its label at the
/// leading edge and the account avatar at the trailing edge, one line.
/// Fixed ids, so a never-written layout is identical on every device.
pub fn defaults() -> Document {
    let sticky = |id: &str, region, arrangement, items| Section {
        id: String::from(id),
        title: None,
        shows_title: true,
        region,
        look: Look::BuiltIn,
        arrangement,
        room: None,
        max_rows: None,
        content: Content::Items,
        items,
    };
    Document {
        revision: 0,
        sections: vec![
            sticky(
                "sec_top",
                Region::Top,
                Arrangement::default(),
                vec![
                    builtin("itm_home", "home", true),
                    builtin("itm_app_store", "app_store", true),
                ],
            ),
            Section {
                id: "sec_workspaces".into(),
                title: None,
                shows_title: true,
                region: Region::Middle,
                look: Look::List,
                arrangement: Arrangement::default(),
                room: None,
                max_rows: None,
                content: Content::Workspaces,
                items: vec![],
            },
            sticky(
                "sec_bottom",
                Region::Bottom,
                Arrangement {
                    layout: ArrangementLayout::Inline,
                    align: Alignment::Fill,
                    gap: None,
                    columns: None,
                },
                vec![
                    builtin("itm_settings", "settings", true),
                    builtin("itm_customize", "customize", false),
                    builtin("itm_account", "account", false),
                ],
            ),
        ],
    }
}

/// The new document, or the reject. A change bumps `revision` by one; a
/// no-op returns the document unchanged.
pub fn reduce(document: &Document, op: &Op) -> Result<Document, Reject> {
    let mut sections = document.sections.clone();
    match op {
        Op::SectionAdd { section, index } => add_section(section, *index, &mut sections)?,
        Op::SectionUpdate { id, patch } => update_section(id, patch, &mut sections)?,
        Op::SectionMove { id, region, index } => {
            let s = find_section(id, &sections)?;
            let mut section = sections.remove(s);
            section.region = *region;
            let at = insertion_index(*region, *index, &sections);
            sections.insert(at, section);
        }
        Op::SectionRemove { id } => {
            let s = find_section(id, &sections)?;
            if sections[s].content == Content::Workspaces {
                return Err(Reject::WorkspacesRequired);
            }
            sections.remove(s);
        }
        Op::ItemAdd { item, section, index } => add_item(item, section, *index, &mut sections)?,
        Op::ItemMove { id, section, index } => move_item(id, section, *index, &mut sections)?,
        Op::ItemRemove { id } => {
            let (s, i) = locate(id, &sections).ok_or(Reject::UnknownItem)?;
            sections[s].items.remove(i);
        }
        Op::ItemRemoveRef { reference } => {
            if !sections
                .iter()
                .any(|section| section.items.iter().any(|item| &item.reference == reference))
            {
                return Err(Reject::UnknownItem);
            }
            for section in &mut sections {
                section.items.retain(|item| &item.reference != reference);
            }
        }
        Op::ItemUpdate { id, shows_label } => {
            let (s, i) = locate(id, &sections).ok_or(Reject::UnknownItem)?;
            sections[s].items[i].shows_label = *shows_label;
        }
        Op::Reset => sections = defaults().sections,
    }
    if sections == document.sections {
        return Ok(document.clone());
    }
    Ok(Document { revision: document.revision + 1, sections })
}

fn find_section(id: &str, sections: &[Section]) -> Result<usize, Reject> {
    sections.iter().position(|section| section.id == id).ok_or(Reject::UnknownSection)
}

pub(crate) fn locate(id: &str, sections: &[Section]) -> Option<(usize, usize)> {
    sections.iter().enumerate().find_map(|(s, section)| {
        section.items.iter().position(|item| item.id == id).map(|i| (s, i))
    })
}

fn item_count(sections: &[Section]) -> usize {
    sections.iter().map(|section| section.items.len()).sum()
}

fn clamp(index: i64, count: usize) -> usize {
    index.clamp(0, count as i64) as usize
}

/// Document index for the `index`-th slot (clamped) among `region`'s
/// sections; an empty region goes after every section of an earlier region.
fn insertion_index(region: Region, index: i64, sections: &[Section]) -> usize {
    let in_region: Vec<usize> =
        (0..sections.len()).filter(|&s| sections[s].region == region).collect();
    if in_region.is_empty() {
        return sections
            .iter()
            .rposition(|section| section.region.rank() <= region.rank())
            .map_or(0, |s| s + 1);
    }
    let slot = clamp(index, in_region.len());
    if slot == in_region.len() { in_region[in_region.len() - 1] + 1 } else { in_region[slot] }
}

fn validate_title(title: Option<&String>) -> Result<(), Reject> {
    match title {
        // Unicode scalars, like the app's reducer (`unicodeScalars.count`).
        Some(title) if title.is_empty() || title.chars().count() > MAX_TITLE_CHARS => {
            Err(Reject::InvalidTitle)
        }
        _ => Ok(()),
    }
}

fn validate_max_rows(max_rows: Option<i64>) -> Result<(), Reject> {
    match max_rows {
        Some(rows) if !MAX_ROWS.contains(&rows) => Err(Reject::InvalidMaxRows),
        _ => Ok(()),
    }
}

fn add_section(section: &Section, index: i64, sections: &mut Vec<Section>) -> Result<(), Reject> {
    if sections.len() >= MAX_SECTIONS {
        return Err(Reject::TooMany);
    }
    // L2: ids are unique across sections and items.
    if sections.iter().any(|existing| existing.id == section.id)
        || locate(&section.id, sections).is_some()
    {
        return Err(Reject::DuplicateId);
    }
    if section
        .items
        .iter()
        .any(|item| item.id == section.id || sections.iter().any(|existing| existing.id == item.id))
    {
        return Err(Reject::DuplicateId);
    }
    // L1: exactly one workspaces section, and it holds no items.
    if section.content == Content::Workspaces {
        return Err(Reject::WorkspacesRequired);
    }
    validate_title(section.title.as_ref())?;
    validate_max_rows(section.max_rows)?;
    if !section.arrangement.is_valid() {
        return Err(Reject::InvalidArrangement);
    }
    let mut ids: Vec<&str> =
        sections.iter().flat_map(|s| s.items.iter().map(|item| item.id.as_str())).collect();
    let before = ids.len();
    ids.extend(section.items.iter().map(|item| item.id.as_str()));
    let mut unique = ids.clone();
    unique.sort_unstable();
    unique.dedup();
    if unique.len() != ids.len() {
        return Err(Reject::DuplicateId);
    }
    let mut refs: Vec<&ItemRef> = section.items.iter().map(|item| &item.reference).collect();
    refs.sort_by(|a, b| (&a.kind, &a.value).cmp(&(&b.kind, &b.value)));
    refs.dedup();
    if refs.len() != section.items.len() {
        return Err(Reject::DuplicateRef);
    }
    if before + section.items.len() > MAX_ITEMS {
        return Err(Reject::TooMany);
    }
    let at = insertion_index(section.region, index, sections);
    sections.insert(at, section.clone());
    Ok(())
}

fn update_section(id: &str, patch: &SectionPatch, sections: &mut [Section]) -> Result<(), Reject> {
    let s = find_section(id, sections)?;
    let section = &mut sections[s];
    if let Update::Set(title) = &patch.title {
        validate_title(Some(title))?;
    }
    patch.title.apply(&mut section.title);
    if let Some(look) = patch.look {
        section.look = look;
    }
    if let Some(shows_title) = patch.shows_title {
        section.shows_title = shows_title;
    }
    let mut arrangement = section.arrangement;
    if let Some(layout) = patch.layout {
        arrangement.layout = layout;
    }
    if let Some(align) = patch.align {
        arrangement.align = align;
    }
    patch.gap.apply(&mut arrangement.gap);
    patch.columns.apply(&mut arrangement.columns);
    if !arrangement.is_valid() {
        return Err(Reject::InvalidArrangement);
    }
    section.arrangement = arrangement;
    // L1: the workspace list shows in every room.
    if section.content == Content::Workspaces && matches!(patch.room, Update::Set(_)) {
        return Err(Reject::WorkspacesRequired);
    }
    patch.room.apply(&mut section.room);
    if let Update::Set(rows) = patch.max_rows {
        validate_max_rows(Some(rows))?;
    }
    patch.max_rows.apply(&mut section.max_rows);
    Ok(())
}

fn add_item(
    item: &Item,
    section: &str,
    index: i64,
    sections: &mut [Section],
) -> Result<(), Reject> {
    let s = find_section(section, sections)?;
    if sections[s].content != Content::Items {
        return Err(Reject::WorkspacesRequired);
    }
    if locate(&item.id, sections).is_some()
        || sections.iter().any(|existing| existing.id == item.id)
    {
        return Err(Reject::DuplicateId);
    }
    // L3: pinning a reference twice into one section is a no-op.
    if sections[s].items.iter().any(|existing| existing.reference == item.reference) {
        return Ok(());
    }
    if item_count(sections) >= MAX_ITEMS {
        return Err(Reject::TooMany);
    }
    let at = clamp(index, sections[s].items.len());
    sections[s].items.insert(at, item.clone());
    Ok(())
}

fn move_item(id: &str, target: &str, index: i64, sections: &mut [Section]) -> Result<(), Reject> {
    let (s, i) = locate(id, sections).ok_or(Reject::UnknownItem)?;
    let t = find_section(target, sections)?;
    if sections[t].content != Content::Items {
        return Err(Reject::WorkspacesRequired);
    }
    let item = sections[s].items[i].clone();
    if t != s && sections[t].items.iter().any(|existing| existing.reference == item.reference) {
        return Err(Reject::DuplicateRef);
    }
    sections[s].items.remove(i);
    let at = clamp(index, sections[t].items.len());
    sections[t].items.insert(at, item);
    Ok(())
}

#[cfg(test)]
#[path = "sidebar_layout_tests.rs"]
mod tests;
