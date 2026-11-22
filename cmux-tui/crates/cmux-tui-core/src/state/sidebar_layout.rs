//! The pure reducer of the sidebar section layout (`sidebar-layout-v1`,
//! plans/cmux-next/sidebar-sections.md section 4). No I/O. It mirrors the
//! app's `SidebarLayoutReducer` (CmuxNextSidebar/Sections) exactly: same
//! JSON, same defaults, same index rules, same invariants L1-L6, same reject
//! reasons. The shared fixture
//! Packages/macOS/CmuxNext/Tests/CmuxNextSidebarTests/Fixtures/sidebar-layout-cases.json
//! keeps the two reducers equal.
//!
//! L5: values and keys from a newer client are kept verbatim. Enumerated
//! strings (region, look, content, arrangement layout and align) keep an
//! unknown value as `Other`, and sections, items, refs and arrangements keep
//! unknown keys in `extra`, so a stored document never loses what a newer
//! app wrote. The app decodes `region` and `content` strictly (one unknown
//! value would fail its whole document), so `Op::introduced_unknown_value`
//! lets the wire refuse an op that would store one; a stored row that holds
//! one (from a newer daemon) still reads.

use serde::{Deserialize, Serialize};
use serde_json::{Map, Value};

pub const MAX_SECTIONS: usize = 32;
pub const MAX_ITEMS: usize = 200;
pub const MAX_TITLE_CHARS: usize = 80;
pub const MAX_ROWS: std::ops::RangeInclusive<i64> = 1..=50;
pub const GAP_RANGE: std::ops::RangeInclusive<i64> = 0..=32;
/// Grid columns, and an item's grid span.
pub const COLUMNS_RANGE: std::ops::RangeInclusive<i64> = 1..=12;

/// A string enum whose unknown values survive a round trip (L5).
macro_rules! open_enum {
    ($(#[$meta:meta])* $name:ident { $($variant:ident => $text:literal),+ $(,)? }) => {
        $(#[$meta])*
        #[derive(Debug, Clone, PartialEq, Eq)]
        pub enum $name {
            $($variant,)+
            /// A value from a newer client, kept verbatim.
            Other(String),
        }

        impl $name {
            pub fn as_str(&self) -> &str {
                match self {
                    $($name::$variant => $text,)+
                    $name::Other(value) => value,
                }
            }
        }

        impl Serialize for $name {
            fn serialize<S: serde::Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
                serializer.serialize_str(self.as_str())
            }
        }

        impl<'de> Deserialize<'de> for $name {
            fn deserialize<D: serde::Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
                Ok(match String::deserialize(deserializer)?.as_str() {
                    $($text => $name::$variant,)+
                    other => $name::Other(other.to_string()),
                })
            }
        }
    };
}

open_enum!(
    /// Where a section sits. A newer region sorts after `bottom`.
    Region { Top => "top", Middle => "middle", Bottom => "bottom" }
);
open_enum!(
    /// How a section's rows look (the app reads an unknown look as list).
    Look { BuiltIn => "built_in", List => "list" }
);
open_enum!(
    /// What a section holds. A newer content kind holds no items here.
    Content { Items => "items", Workspaces => "workspaces", App => "app" }
);
open_enum!(
    ArrangementLayout { List => "list", Inline => "inline", Grid => "grid", Tiles => "tiles" }
);
open_enum!(
    Alignment { Leading => "leading", Center => "center", Trailing => "trailing", Fill => "fill" }
);

impl Region {
    fn rank(&self) -> u8 {
        match self {
            Region::Top => 0,
            Region::Middle => 1,
            Region::Bottom => 2,
            Region::Other(_) => 3,
        }
    }
}

/// An insertion index: any JSON integer (the app sends `Int.max` to append;
/// a JavaScript client may send it as a float), saturated to `i64` and
/// clamped by the reducer.
fn index<'de, D: serde::Deserializer<'de>>(deserializer: D) -> Result<i64, D::Error> {
    let value = serde_json::Number::deserialize(deserializer)?;
    if let Some(index) = value.as_i64() {
        return Ok(index);
    }
    if value.as_u64().is_some() {
        return Ok(i64::MAX);
    }
    match value.as_f64() {
        Some(float) if float.is_finite() && float.fract() == 0.0 => Ok(float as i64),
        _ => Err(serde::de::Error::custom("index must be an integer")),
    }
}

/// A value that may be null: its default.
fn default_if_null<'de, D: serde::Deserializer<'de>, T: Deserialize<'de> + Default>(
    deserializer: D,
) -> Result<T, D::Error> {
    Ok(Option::<T>::deserialize(deserializer)?.unwrap_or_default())
}

fn yes() -> bool {
    true
}

/// A boolean that may be absent or null: true.
fn true_unless_false<'de, D: serde::Deserializer<'de>>(deserializer: D) -> Result<bool, D::Error> {
    Ok(Option::<bool>::deserialize(deserializer)?.unwrap_or(true))
}

fn list() -> ArrangementLayout {
    ArrangementLayout::List
}

fn leading() -> Alignment {
    Alignment::Leading
}

fn layout_or_list<'de, D: serde::Deserializer<'de>>(
    deserializer: D,
) -> Result<ArrangementLayout, D::Error> {
    Ok(Option::<ArrangementLayout>::deserialize(deserializer)?.unwrap_or(ArrangementLayout::List))
}

fn align_or_leading<'de, D: serde::Deserializer<'de>>(
    deserializer: D,
) -> Result<Alignment, D::Error> {
    Ok(Option::<Alignment>::deserialize(deserializer)?.unwrap_or(Alignment::Leading))
}

/// `{layout, align, gap?, columns?}`; every key optional on input (layout
/// list, align leading).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Arrangement {
    #[serde(default = "list", deserialize_with = "layout_or_list")]
    pub layout: ArrangementLayout,
    #[serde(default = "leading", deserialize_with = "align_or_leading")]
    pub align: Alignment,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub gap: Option<i64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub columns: Option<i64>,
    #[serde(flatten)]
    pub extra: Map<String, Value>,
}

impl Default for Arrangement {
    fn default() -> Self {
        Arrangement::new(ArrangementLayout::List, Alignment::Leading)
    }
}

impl Arrangement {
    pub fn new(layout: ArrangementLayout, align: Alignment) -> Self {
        Arrangement { layout, align, gap: None, columns: None, extra: Map::new() }
    }

    pub fn is_valid(&self) -> bool {
        self.gap.is_none_or(|gap| GAP_RANGE.contains(&gap))
            && self.columns.is_none_or(|columns| COLUMNS_RANGE.contains(&columns))
    }
}

/// What an item points at; unknown kinds and built-in ids are kept
/// verbatim (L5). Two refs are the same reference when kind and value match.
/// A `workspace` value is the qualified public id `<session>:ws_...` and a
/// `tab` value `<session>:tab_...` (sidebar-sections.md 1); the store keeps
/// both opaque: it does not parse them, normalize them or check that the
/// target exists, so one local id on two sessions is two references.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ItemRef {
    pub kind: String,
    pub value: String,
    #[serde(flatten)]
    pub extra: Map<String, Value>,
}

impl ItemRef {
    pub fn new(kind: &str, value: &str) -> Self {
        ItemRef { kind: kind.into(), value: value.into(), extra: Map::new() }
    }

    /// L3 identity, like the app's `LayoutItemRef` equality.
    pub fn same(&self, other: &ItemRef) -> bool {
        self.kind == other.kind && self.value == other.value
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Item {
    pub id: String,
    #[serde(rename = "ref")]
    pub reference: ItemRef,
    #[serde(default = "yes", deserialize_with = "true_unless_false")]
    pub shows_label: bool,
    /// Columns the item takes on a grid line (1...12); absent = one tile.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub span: Option<i64>,
    #[serde(flatten)]
    pub extra: Map<String, Value>,
}

impl Item {
    fn new(id: &str, reference: ItemRef, shows_label: bool) -> Self {
        Item { id: id.into(), reference, shows_label, span: None, extra: Map::new() }
    }
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
    /// `<app id>#<section id>` for content `app`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub contribution: Option<String>,
    #[serde(default, deserialize_with = "default_if_null")]
    pub items: Vec<Item>,
    #[serde(flatten)]
    pub extra: Map<String, Value>,
}

impl Section {
    /// A section with no title, room, row limit, contribution or items.
    pub fn new(id: &str, region: Region, look: Look, content: Content) -> Self {
        Section {
            id: id.into(),
            title: None,
            shows_title: true,
            region,
            look,
            arrangement: Arrangement::default(),
            room: None,
            max_rows: None,
            content,
            contribution: None,
            items: Vec::new(),
            extra: Map::new(),
        }
    }

    /// The app that owns an app section: the id before `#`.
    pub fn owning_app_id(&self) -> Option<&str> {
        if self.content != Content::App {
            return None;
        }
        let (app, _) = self.contribution.as_deref()?.split_once('#')?;
        (!app.is_empty()).then_some(app)
    }
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
    SectionAdd {
        section: Section,
        #[serde(deserialize_with = "index")]
        index: i64,
    },
    #[serde(rename = "section.update")]
    SectionUpdate { id: String, patch: SectionPatch },
    #[serde(rename = "section.move")]
    SectionMove {
        id: String,
        region: Region,
        #[serde(deserialize_with = "index")]
        index: i64,
    },
    #[serde(rename = "section.remove")]
    SectionRemove { id: String },
    #[serde(rename = "item.add")]
    ItemAdd {
        item: Item,
        section: String,
        #[serde(deserialize_with = "index")]
        index: i64,
    },
    #[serde(rename = "item.move")]
    ItemMove {
        id: String,
        section: String,
        #[serde(deserialize_with = "index")]
        index: i64,
    },
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

impl Op {
    /// The region or content value this op would store that the app cannot
    /// decode (`SidebarRegion` and `SectionContent` are strict in the app),
    /// as `(field, value)`.
    pub fn introduced_unknown_value(&self) -> Option<(&'static str, &str)> {
        let (region, content) = match self {
            Op::SectionAdd { section, .. } => (&section.region, Some(&section.content)),
            Op::SectionMove { region, .. } => (region, None),
            _ => return None,
        };
        if let Region::Other(value) = region {
            return Some(("region", value));
        }
        match content {
            Some(Content::Other(value)) => Some(("content", value)),
            _ => None,
        }
    }
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
    InvalidContribution,
    ItemsNotAllowed,
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
            Reject::InvalidContribution => "invalid_contribution",
            Reject::ItemsNotAllowed => "items_not_allowed",
            Reject::TooMany => "too_many",
        }
    }
}

/// The section id of the recent agent chats (`SidebarLayoutDocument+Recents`).
pub const RECENTS_SECTION_ID: &str = "sec_recents";
pub const RECENTS_CONTRIBUTION: &str = "cmux/agent-chats#recents";

/// The app's `SidebarLayoutDocument.defaults`: on top Home and the App Store
/// as app rows; in the middle the workspaces, then the recent agent chats
/// (an app section); at the bottom one inline line, leading, with only the
/// account avatar (the profile control; Settings is in its menu,
/// SIDEBAR-FOOTER-AND-SPACE-MENU amendment 2). Fixed ids, so a
/// never-written layout is identical on every device.
pub fn defaults() -> Document {
    let mut top = Section::new("sec_top", Region::Top, Look::BuiltIn, Content::Items);
    top.items = vec![
        Item::new("itm_home", ItemRef::new("app", "cmux/home"), true),
        Item::new("itm_app_store", ItemRef::new("app", "cmux/app-store"), true),
    ];
    let workspaces =
        Section::new("sec_workspaces", Region::Middle, Look::List, Content::Workspaces);
    let mut recents = Section::new(RECENTS_SECTION_ID, Region::Middle, Look::List, Content::App);
    recents.contribution = Some(RECENTS_CONTRIBUTION.into());
    let mut bottom = Section::new("sec_bottom", Region::Bottom, Look::BuiltIn, Content::Items);
    bottom.arrangement = Arrangement::new(ArrangementLayout::Inline, Alignment::Leading);
    bottom.items = vec![Item::new("itm_account", ItemRef::new("built_in", "account"), false)];
    Document { revision: 0, sections: vec![top, workspaces, recents, bottom] }
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
            section.region = region.clone();
            let at = insertion_index(region, *index, &sections);
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
            if !sections.iter().any(|s| s.items.iter().any(|item| item.reference.same(reference))) {
                return Err(Reject::UnknownItem);
            }
            for section in &mut sections {
                section.items.retain(|item| !item.reference.same(reference));
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
fn insertion_index(region: &Region, index: i64, sections: &[Section]) -> usize {
    let in_region: Vec<usize> =
        (0..sections.len()).filter(|&s| &sections[s].region == region).collect();
    if in_region.is_empty() {
        return sections
            .iter()
            .rposition(|section| section.region.rank() <= region.rank())
            .map_or(0, |s| s + 1);
    }
    let slot = clamp(index, in_region.len());
    if slot == in_region.len() { in_region[in_region.len() - 1] + 1 } else { in_region[slot] }
}

fn ensure_items(section: &Section) -> Result<(), Reject> {
    match section.content {
        Content::Items => Ok(()),
        Content::Workspaces => Err(Reject::WorkspacesRequired),
        Content::App | Content::Other(_) => Err(Reject::ItemsNotAllowed),
    }
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

/// L4: an item's grid span is 1...12, like the arrangement's columns.
fn validate_span(span: Option<i64>) -> Result<(), Reject> {
    match span {
        Some(span) if !COLUMNS_RANGE.contains(&span) => Err(Reject::InvalidArrangement),
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
    // L1: exactly one workspaces section, and it holds no items. A content
    // kind from a newer client is kept as it came.
    match section.content {
        Content::Workspaces => return Err(Reject::WorkspacesRequired),
        Content::App if section.owning_app_id().is_none() || !section.items.is_empty() => {
            return Err(Reject::InvalidContribution);
        }
        Content::Items if section.contribution.is_some() => {
            return Err(Reject::InvalidContribution);
        }
        _ => {}
    }
    validate_title(section.title.as_ref())?;
    validate_max_rows(section.max_rows)?;
    if !section.arrangement.is_valid() {
        return Err(Reject::InvalidArrangement);
    }
    for item in &section.items {
        validate_span(item.span)?;
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
    let mut refs: Vec<(&str, &str)> = section
        .items
        .iter()
        .map(|item| (item.reference.kind.as_str(), item.reference.value.as_str()))
        .collect();
    refs.sort_unstable();
    refs.dedup();
    if refs.len() != section.items.len() {
        return Err(Reject::DuplicateRef);
    }
    if before + section.items.len() > MAX_ITEMS {
        return Err(Reject::TooMany);
    }
    let at = insertion_index(&section.region, index, sections);
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
    if let Some(look) = &patch.look {
        section.look = look.clone();
    }
    if let Some(shows_title) = patch.shows_title {
        section.shows_title = shows_title;
    }
    let mut arrangement = section.arrangement.clone();
    if let Some(layout) = &patch.layout {
        arrangement.layout = layout.clone();
    }
    if let Some(align) = &patch.align {
        arrangement.align = align.clone();
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
    ensure_items(&sections[s])?;
    validate_span(item.span)?;
    if locate(&item.id, sections).is_some()
        || sections.iter().any(|existing| existing.id == item.id)
    {
        return Err(Reject::DuplicateId);
    }
    // L3: pinning a reference twice into one section is a no-op.
    if sections[s].items.iter().any(|existing| existing.reference.same(&item.reference)) {
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
    ensure_items(&sections[t])?;
    let item = sections[s].items[i].clone();
    if t != s && sections[t].items.iter().any(|existing| existing.reference.same(&item.reference)) {
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
