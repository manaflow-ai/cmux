//! The document, its ops and its refusal codes (CONTRACT.md "Rust").
//!
//! Wire shapes: a section's `kind` and an item's `body` are objects tagged by
//! `type` (`{"type":"machine","session_id":"..."}`,
//! `{"type":"workspace","ref":{"session_id":"...","workspace_id":"..."}}`).
//! Sections, items and workspace refs carry forward-compatible data in an
//! explicit `extra` object (the catalog convention), so a newer client's
//! fields survive a round trip through an older daemon.

use serde::{Deserialize, Serialize};
use serde_json::{Map, Value};

pub use crate::sidebar_layout::{Alignment, ArrangementLayout, Look, Region};

pub type SectionId = String;
pub type ItemId = String;

/// `Item::extra` key: a group member pinned inside its group.
pub const PINNED_IN_GROUP_KEY: &str = "pinned";
/// `Item::extra` key: where a top-level item pinned to the Pinned band goes
/// back on Unpin (`{"section": id, "after": id or null}`).
pub const UNPIN_TO_KEY: &str = "unpin_to";
/// `Item::extra` key: an archived item (plans/cmux-next/archiving-DESIGN.md):
/// it lists after its unarchived siblings and draws dimmed.
pub const ARCHIVED_KEY: &str = "archived";
/// `Item::extra` key: where Unarchive puts an archived item back
/// (`{"after": sibling id or null}`, in its own sibling list).
pub const UNARCHIVE_TO_KEY: &str = "unarchive_to";
/// `Item::extra` key: why an archived group is archived. `"members"`: the
/// last of its members was archived (auto-archive-DESIGN.md "Groups").
pub const ARCHIVED_BY_KEY: &str = "archived_by";
/// [`ARCHIVED_BY_KEY`]'s value for a group that archived with its members.
pub const ARCHIVED_BY_MEMBERS: &str = "members";
/// `Item::extra` key of a group: its auto-archive rule
/// (auto-archive-DESIGN.md "Per-group rules"): `"never"`, or the hours a
/// member stays idle before it archives (1 to [`MAX_AUTO_ARCHIVE_HOURS`]).
/// Absent: the setting's default.
pub const AUTO_ARCHIVE_KEY: &str = "auto_archive";
/// The longest idle time a group's rule may name: ten years, in hours.
pub const MAX_AUTO_ARCHIVE_HOURS: i64 = 87_600;
/// The one Pinned section.
pub const PINNED_SECTION_ID: &str = "sec_pinned";
/// The prefix of a machine section id: `sec_m_<session_id>`.
pub const MACHINE_SECTION_PREFIX: &str = "sec_m_";
/// A key longer than this renumbers its siblings.
pub const MAX_ORDER_KEY_CHARS: usize = 32;
pub const MAX_TITLE_CHARS: usize = 80;
/// The most levels of groups one tree may have: a top-level group is level 1.
/// Deep enough that nesting reads as unlimited (Lawrence 2026-10-23: "i want
/// to see deeply nested groups"; it was 3, host > project > branch,
/// remote-groups-DESIGN.md R1), and still a bound, so a corrupt document's
/// walks stay finite and the view's `u8` depth never overflows. The sidebar
/// stops indenting after a few levels (`SidebarIndent`); nesting goes on.
pub const MAX_GROUP_DEPTH: usize = 16;
pub const MAX_SECTIONS: usize = 64;
pub const MAX_ITEMS: usize = 20_000;
/// The space between a section's rows or tiles, in points (as the old
/// layout's `arrangement.gap`).
pub const GAP_RANGE: std::ops::RangeInclusive<i64> = 0..=32;

/// The id of `session_id`'s machine section.
pub fn machine_section_id(session_id: &str) -> SectionId {
    format!("{MACHINE_SECTION_PREFIX}{session_id}")
}

/// The id of a workspace's item. Deterministic, so a client can name the
/// item of a workspace it adopts (`adopt` then `move` in one `sidebar.apply`)
/// and adopting twice is a no-op.
pub fn workspace_item_id(reference: &WorkspaceRef) -> ItemId {
    format!("itm_w_{}_{}", reference.session_id, reference.workspace_id)
}

/// The id of the item of an old personal workspace group.
pub fn group_item_id(group_id: &str) -> ItemId {
    format!("itm_g_{group_id}")
}

/// A workspace on one machine. `workspace_ref` (in `extra`) names a
/// workspace whose public id was not known when it was placed (another
/// machine's row from the old personal store, by the same reference a
/// `workspace_placement` snapshot carries); `adopt` resolves it.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct WorkspaceRef {
    pub session_id: String,
    pub workspace_id: String,
    #[serde(default, skip_serializing_if = "Map::is_empty")]
    pub extra: Map<String, Value>,
}

impl WorkspaceRef {
    pub fn new(session_id: &str, workspace_id: &str) -> Self {
        WorkspaceRef {
            session_id: session_id.into(),
            workspace_id: workspace_id.into(),
            extra: Map::new(),
        }
    }

    /// Same workspace (session and id; `extra` does not count).
    pub fn same(&self, other: &WorkspaceRef) -> bool {
        self.session_id == other.session_id && self.workspace_id == other.workspace_id
    }

    /// The placement reference of an item placed before its public id was
    /// known.
    pub fn placement_ref(&self) -> Option<&str> {
        self.extra.get("workspace_ref").and_then(Value::as_str)
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum SectionKind {
    Machine { session_id: String },
    Pinned,
    Custom,
    App { contribution: String },
    Builtin,
}

impl SectionKind {
    pub fn machine(&self) -> Option<&str> {
        match self {
            SectionKind::Machine { session_id } => Some(session_id),
            _ => None,
        }
    }

    /// Whether a closed workspace or an empty group stays in the section.
    pub fn keeps_closed_by_default(&self) -> bool {
        matches!(self, SectionKind::Pinned | SectionKind::Custom)
    }
}

fn yes() -> bool {
    true
}

fn middle() -> Region {
    Region::Middle
}

fn list_look() -> Look {
    Look::List
}

fn list_layout() -> ArrangementLayout {
    ArrangementLayout::List
}

fn leading() -> Alignment {
    Alignment::Leading
}

/// An `align` that may be null: leading (as the old layout reads it).
fn align_or_leading<'de, D: serde::Deserializer<'de>>(
    deserializer: D,
) -> Result<Alignment, D::Error> {
    Ok(Option::<Alignment>::deserialize(deserializer)?.unwrap_or(Alignment::Leading))
}

/// Whether a section stays visible (`fixed`: in the fixed stack at the top,
/// or at the bottom for the bottom region) or scrolls with the main list
/// (`flow`). DESIGN.md "Scrolling model".
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Scroll {
    Fixed,
    Flow,
}

impl Scroll {
    /// The default of a section of `kind` in `region`: built-in and Pinned
    /// sections are fixed, machine sections flow, custom and app sections
    /// are fixed in the top and bottom regions and flow in the middle.
    pub fn default_for(kind: &SectionKind, region: &Region) -> Scroll {
        match kind {
            SectionKind::Machine { .. } => Scroll::Flow,
            SectionKind::Pinned | SectionKind::Builtin => Scroll::Fixed,
            SectionKind::Custom | SectionKind::App { .. } => match region {
                Region::Top | Region::Bottom => Scroll::Fixed,
                Region::Middle | Region::Other(_) => Scroll::Flow,
            },
        }
    }
}

/// A section. `scroll` is always on the wire; a stored row or a client
/// that does not send it gets [`Scroll::default_for`] its kind and region.
/// `max_rows`: the section grows with its content up to this many rows (or
/// tile lines), then scrolls inside itself; absent grows without limit.
/// `align` (always on the wire, default `leading`) places an inline or grid
/// section's rows or tiles on their line; `gap` (0 to 32 points, absent =
/// the look's default spacing) is the space between them. Both are the old
/// layout's `arrangement.align` and `arrangement.gap`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(from = "SectionWire")]
pub struct Section {
    pub id: SectionId,
    pub kind: SectionKind,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub title: Option<String>,
    #[serde(default = "yes")]
    pub shows_title: bool,
    #[serde(default = "middle")]
    pub region: Region,
    #[serde(default = "list_look")]
    pub look: Look,
    #[serde(default = "list_layout")]
    pub arrangement: ArrangementLayout,
    #[serde(default = "leading")]
    pub align: Alignment,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub gap: Option<i64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub columns: Option<i64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub max_rows: Option<i64>,
    pub scroll: Scroll,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub room: Option<String>,
    #[serde(default)]
    pub order: String,
    #[serde(default)]
    pub keeps_closed: bool,
    /// A machine section made a remote group (remote-groups-DESIGN.md slice
    /// 4): it draws its header, the host's name and status, even when the
    /// sidebar is one list. Only a machine section can be one.
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub host_group: bool,
    /// A person explicitly removed this machine's remote-group header. This
    /// survives the false `host_group` value being omitted on older wires.
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub host_group_opt_out: bool,
    #[serde(default, skip_serializing_if = "Map::is_empty")]
    pub extra: Map<String, Value>,
}

/// [`Section`] as it reads: `scroll` may be absent.
#[derive(Deserialize)]
struct SectionWire {
    id: SectionId,
    kind: SectionKind,
    #[serde(default)]
    title: Option<String>,
    #[serde(default = "yes")]
    shows_title: bool,
    #[serde(default = "middle")]
    region: Region,
    #[serde(default = "list_look")]
    look: Look,
    #[serde(default = "list_layout")]
    arrangement: ArrangementLayout,
    #[serde(default = "leading", deserialize_with = "align_or_leading")]
    align: Alignment,
    #[serde(default)]
    gap: Option<i64>,
    #[serde(default)]
    columns: Option<i64>,
    #[serde(default)]
    max_rows: Option<i64>,
    #[serde(default)]
    scroll: Option<Scroll>,
    #[serde(default)]
    room: Option<String>,
    #[serde(default)]
    order: String,
    #[serde(default)]
    keeps_closed: bool,
    #[serde(default)]
    host_group: bool,
    #[serde(default)]
    host_group_opt_out: bool,
    #[serde(default)]
    extra: Map<String, Value>,
}

impl From<SectionWire> for Section {
    fn from(wire: SectionWire) -> Self {
        let scroll = wire.scroll.unwrap_or_else(|| Scroll::default_for(&wire.kind, &wire.region));
        Section {
            id: wire.id,
            kind: wire.kind,
            title: wire.title,
            shows_title: wire.shows_title,
            region: wire.region,
            look: wire.look,
            arrangement: wire.arrangement,
            align: wire.align,
            gap: wire.gap,
            columns: wire.columns,
            max_rows: wire.max_rows,
            scroll,
            room: wire.room,
            order: wire.order,
            keeps_closed: wire.keeps_closed,
            host_group: wire.host_group,
            host_group_opt_out: wire.host_group_opt_out,
            extra: wire.extra,
        }
    }
}

impl Section {
    /// A section of `kind` with the contract's defaults: Pinned and custom
    /// sections keep closed items, Pinned shows no title.
    pub fn new(id: &str, kind: SectionKind, region: Region) -> Self {
        let keeps_closed = kind.keeps_closed_by_default();
        let shows_title = !matches!(kind, SectionKind::Pinned);
        let scroll = Scroll::default_for(&kind, &region);
        Section {
            id: id.into(),
            kind,
            title: None,
            shows_title,
            region,
            look: Look::List,
            arrangement: ArrangementLayout::List,
            align: Alignment::Leading,
            gap: None,
            columns: None,
            max_rows: None,
            scroll,
            room: None,
            order: String::new(),
            keeps_closed,
            host_group: false,
            host_group_opt_out: false,
            extra: Map::new(),
        }
    }

    pub fn machine(session_id: &str) -> Self {
        Section::new(
            &machine_section_id(session_id),
            SectionKind::Machine { session_id: session_id.into() },
            Region::Middle,
        )
    }

    pub fn pinned() -> Self {
        let mut section = Section::new(PINNED_SECTION_ID, SectionKind::Pinned, Region::Top);
        section.look = Look::BuiltIn;
        section
    }

    pub fn region_rank(&self) -> u8 {
        match self.region {
            Region::Top => 0,
            Region::Middle => 1,
            Region::Bottom => 2,
            Region::Other(_) => 3,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum Body {
    Workspace {
        #[serde(rename = "ref")]
        reference: WorkspaceRef,
    },
    Group {
        name: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        color: Option<String>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        icon: Option<String>,
        #[serde(default)]
        collapsed: bool,
        /// The room (wire name `profile`) of an old personal group.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        profile: Option<String>,
    },
    Builtin {
        id: String,
    },
    App {
        id: String,
    },
    Url {
        url: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        title: Option<String>,
        /// The site's favicon, drawn as the row icon.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        icon_url: Option<String>,
    },
    Tab {
        #[serde(rename = "ref")]
        reference: String,
    },
    Room {
        id: String,
    },
    SavedGroup {
        id: String,
    },
    /// An old layout item ref of a kind this build does not know, kept
    /// verbatim.
    Ref {
        kind: String,
        value: String,
    },
}

impl Body {
    pub fn kind_name(&self) -> &'static str {
        match self {
            Body::Workspace { .. } => "workspace",
            Body::Group { .. } => "group",
            Body::Builtin { .. } => "builtin",
            Body::App { .. } => "app",
            Body::Url { .. } => "url",
            Body::Tab { .. } => "tab",
            Body::Room { .. } => "room",
            Body::SavedGroup { .. } => "saved_group",
            Body::Ref { .. } => "ref",
        }
    }

    pub fn workspace(&self) -> Option<&WorkspaceRef> {
        match self {
            Body::Workspace { reference } => Some(reference),
            _ => None,
        }
    }

    pub fn is_group(&self) -> bool {
        matches!(self, Body::Group { .. })
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Item {
    pub id: ItemId,
    pub section: SectionId,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub parent: Option<ItemId>,
    #[serde(default)]
    pub order: String,
    pub body: Body,
    #[serde(default = "yes")]
    pub shows_label: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub span: Option<i64>,
    #[serde(default, skip_serializing_if = "Map::is_empty")]
    pub extra: Map<String, Value>,
}

impl Item {
    pub fn new(id: &str, section: &str, body: Body) -> Self {
        Item {
            id: id.into(),
            section: section.into(),
            parent: None,
            order: String::new(),
            body,
            shows_label: true,
            span: None,
            extra: Map::new(),
        }
    }

    pub fn workspace(reference: WorkspaceRef, section: &str) -> Self {
        Item::new(&workspace_item_id(&reference), section, Body::Workspace { reference })
    }

    /// Whether this group member is pinned inside its group
    /// (`extra.pinned`): it lists first among the group's members.
    pub fn pinned_in_group(&self) -> bool {
        self.parent.is_some()
            && self.extra.get(PINNED_IN_GROUP_KEY).and_then(Value::as_bool) == Some(true)
    }

    /// Whether this item is archived (`extra.archived`): it lists after its
    /// unarchived siblings and draws dimmed, with its subtree.
    pub fn archived(&self) -> bool {
        self.extra.get(ARCHIVED_KEY).and_then(Value::as_bool) == Some(true)
    }

    /// A group's own auto-archive rule ([`AUTO_ARCHIVE_KEY`]); `None` when
    /// it follows the default.
    pub fn auto_archive(&self) -> Option<AutoArchiveRule> {
        AutoArchiveRule::read(self.extra.get(AUTO_ARCHIVE_KEY)?)
    }

    /// The label stored with the item (an old tile's workspace name), drawn
    /// while the workspace is closed.
    pub fn label(&self) -> Option<&str> {
        self.extra.get("label").and_then(Value::as_str)
    }

    /// Move an old `extra.icon_url` (written by clients before the url body
    /// had `icon_url`) into the body. Returns whether the item changed.
    pub fn lift_icon_url(&mut self) -> bool {
        lift_icon_url(&mut self.body, &mut self.extra)
    }
}

/// [`Item::lift_icon_url`] on a body and its `extra`.
pub fn lift_icon_url(body: &mut Body, extra: &mut Map<String, Value>) -> bool {
    let Body::Url { icon_url, .. } = body else { return false };
    let Some(old) = extra.remove("icon_url") else { return false };
    if icon_url.is_none()
        && let Some(text) = old.as_str().filter(|text| !text.is_empty())
    {
        *icon_url = Some(text.to_string());
    }
    true
}

/// Where a moved or added item lands: in `section`, under `parent` (a
/// group) or at its top level, before or after a sibling, or at an index
/// among the siblings (end when none is given).
#[derive(Debug, Clone, PartialEq, Eq, Default, Serialize, Deserialize)]
pub struct Target {
    pub section: SectionId,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub parent: Option<ItemId>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub before: Option<ItemId>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub after: Option<ItemId>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub index: Option<i64>,
}

impl Target {
    pub fn end(section: &str) -> Self {
        Target { section: section.into(), ..Target::default() }
    }
}

/// Where a section lands among its region's sections.
#[derive(Debug, Clone, PartialEq, Eq, Default, Serialize, Deserialize)]
pub struct SectionPlace {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub region: Option<Region>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub before: Option<SectionId>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub after: Option<SectionId>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub index: Option<i64>,
}

/// A field that may be absent (keep), null (clear) or set.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub enum Patch<T> {
    #[default]
    Keep,
    Clear,
    Set(T),
}

impl<'de, T: Deserialize<'de>> Deserialize<'de> for Patch<T> {
    fn deserialize<D: serde::Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        Ok(match Option::<T>::deserialize(deserializer)? {
            None => Patch::Clear,
            Some(value) => Patch::Set(value),
        })
    }
}

impl<T: Serialize> Serialize for Patch<T> {
    fn serialize<S: serde::Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        match self {
            Patch::Set(value) => value.serialize(serializer),
            _ => serializer.serialize_none(),
        }
    }
}

impl<T: Clone> Patch<T> {
    pub fn apply(&self, field: &mut Option<T>) {
        match self {
            Patch::Keep => {}
            Patch::Clear => *field = None,
            Patch::Set(value) => *field = Some(value.clone()),
        }
    }

    pub fn is_keep(&self) -> bool {
        matches!(self, Patch::Keep)
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Default, Serialize, Deserialize)]
pub struct SectionPatch {
    #[serde(default, skip_serializing_if = "Patch::is_keep")]
    pub title: Patch<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub shows_title: Option<bool>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub look: Option<Look>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub arrangement: Option<ArrangementLayout>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub align: Option<Alignment>,
    /// 0 to 32 points; null returns to the look's default spacing.
    #[serde(default, skip_serializing_if = "Patch::is_keep")]
    pub gap: Patch<i64>,
    #[serde(default, skip_serializing_if = "Patch::is_keep")]
    pub columns: Patch<i64>,
    #[serde(default, skip_serializing_if = "Patch::is_keep")]
    pub max_rows: Patch<i64>,
    #[serde(default, skip_serializing_if = "Patch::is_keep")]
    pub room: Patch<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub keeps_closed: Option<bool>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub scroll: Option<Scroll>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub host_group: Option<bool>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub host_group_opt_out: Option<bool>,
}

/// An item's own fields; a group's fields go through `group.update`.
#[derive(Debug, Clone, PartialEq, Eq, Default, Serialize, Deserialize)]
pub struct ItemPatch {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub shows_label: Option<bool>,
    #[serde(default, skip_serializing_if = "Patch::is_keep")]
    pub span: Patch<i64>,
    #[serde(default, skip_serializing_if = "Patch::is_keep")]
    pub label: Patch<String>,
    /// A url item's title.
    #[serde(default, skip_serializing_if = "Patch::is_keep")]
    pub title: Patch<String>,
    /// A url item's favicon.
    #[serde(default, skip_serializing_if = "Patch::is_keep")]
    pub icon_url: Patch<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Default, Serialize, Deserialize)]
pub struct GroupPatch {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub name: Option<String>,
    #[serde(default, skip_serializing_if = "Patch::is_keep")]
    pub color: Patch<String>,
    #[serde(default, skip_serializing_if = "Patch::is_keep")]
    pub icon: Patch<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub collapsed: Option<bool>,
    #[serde(default, skip_serializing_if = "Patch::is_keep")]
    pub profile: Patch<String>,
    /// The group's auto-archive rule ([`AUTO_ARCHIVE_KEY`]): `"never"` or
    /// hours; null goes back to the setting's default.
    #[serde(default, skip_serializing_if = "Patch::is_keep")]
    pub auto_archive: Patch<Value>,
}

/// A group's auto-archive rule ([`AUTO_ARCHIVE_KEY`]).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AutoArchiveRule {
    /// Its members never archive on their own.
    Never,
    /// A member idle this many hours archives.
    AfterHours(i64),
}

impl AutoArchiveRule {
    /// The rule a stored or sent value names; `None` for anything else.
    pub fn read(value: &Value) -> Option<AutoArchiveRule> {
        match value {
            Value::String(text) if text == "never" => Some(AutoArchiveRule::Never),
            Value::Number(number) => number
                .as_i64()
                .filter(|hours| (1..=MAX_AUTO_ARCHIVE_HOURS).contains(hours))
                .map(AutoArchiveRule::AfterHours),
            _ => None,
        }
    }

    /// The stored value.
    pub fn value(self) -> Value {
        match self {
            AutoArchiveRule::Never => Value::String("never".into()),
            AutoArchiveRule::AfterHours(hours) => Value::from(hours),
        }
    }
}

/// An item's ref as the old layout names it (`{kind, value}`).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct LayoutRef {
    pub kind: String,
    pub value: String,
}

/// A new item: its id (minted by the daemon when absent), body and fields.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct NewItem {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub id: Option<ItemId>,
    pub body: Body,
    #[serde(default = "yes")]
    pub shows_label: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub span: Option<i64>,
    #[serde(default, skip_serializing_if = "Map::is_empty")]
    pub extra: Map<String, Value>,
}

/// One change, tagged by `op`. The wire methods map onto these
/// (`sidebar.move` is `move`, `sidebar.item.add` is `item.add`, ...);
/// `sidebar.apply` takes a list of them, including the raw `*.put` and
/// `*.delete` ops an inverse is made of.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "op")]
pub enum Op {
    #[serde(rename = "move")]
    Move { items: Vec<ItemId>, to: Target },
    #[serde(rename = "pin")]
    Pin { items: Vec<ItemId> },
    #[serde(rename = "unpin")]
    Unpin { items: Vec<ItemId> },
    /// Mark `items` archived and move each to the end of its own sibling list
    /// (its group, or its section's top level); it draws dimmed.
    #[serde(rename = "archive")]
    Archive { items: Vec<ItemId> },
    /// Clear the archive mark and put each item back after the sibling it
    /// followed when it was archived, else last among the unarchived ones.
    #[serde(rename = "unarchive")]
    Unarchive { items: Vec<ItemId> },
    #[serde(rename = "item.add")]
    ItemAdd { item: NewItem, to: Target },
    #[serde(rename = "item.remove")]
    ItemRemove { id: ItemId },
    #[serde(rename = "item.update")]
    ItemUpdate { id: ItemId, patch: ItemPatch },
    /// Remove every item that shows `ref` (the old layout's "Remove from
    /// Sidebar", `item.remove_ref`): kind and value as the old layout ref
    /// names them (`workspace` `<session>:<workspace id>`, `url` the url,
    /// `app`, `built_in`, `tab`, `room`, `saved_group`, or an unknown kind).
    /// A group has no ref. `unknown_item` when no item shows it.
    #[serde(rename = "item.remove_ref")]
    ItemRemoveRef {
        #[serde(rename = "ref")]
        reference: LayoutRef,
    },
    #[serde(rename = "section.add")]
    SectionAdd {
        section: Section,
        #[serde(default)]
        place: SectionPlace,
    },
    #[serde(rename = "section.update")]
    SectionUpdate { id: SectionId, patch: SectionPatch },
    #[serde(rename = "section.move")]
    SectionMove { id: SectionId, place: SectionPlace },
    #[serde(rename = "section.remove")]
    SectionRemove { id: SectionId },
    #[serde(rename = "group.create")]
    GroupCreate {
        #[serde(default, skip_serializing_if = "Option::is_none")]
        id: Option<ItemId>,
        name: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        color: Option<String>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        icon: Option<String>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        profile: Option<String>,
        #[serde(default)]
        items: Vec<ItemId>,
        /// Where the group lands; default: the place of its first item.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        to: Option<Target>,
    },
    #[serde(rename = "group.update")]
    GroupUpdate { id: ItemId, patch: GroupPatch },
    #[serde(rename = "group.ungroup")]
    GroupUngroup { id: ItemId },
    /// Place live workspaces that have no item yet, at `to` (default: the
    /// end of each one's machine section); a new item's id is
    /// [`workspace_item_id`]. A ref whose `workspace_ref`
    /// matches an unresolved item resolves that item in place: it keeps
    /// its id (find it by its ref, not by `workspace_item_id`).
    #[serde(rename = "adopt")]
    Adopt {
        refs: Vec<WorkspaceRef>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        to: Option<Target>,
    },
    /// Workspaces that closed. In a section that does not keep closed items
    /// (a machine section) the item goes, and so does a group there that it
    /// leaves empty; in Pinned and custom sections it stays (drawn dimmed,
    /// reopened on click).
    #[serde(rename = "close")]
    Close { refs: Vec<WorkspaceRef> },
    /// The default sections again (the old layout's `layout.reset`): Home
    /// and App Store on top (`sec_top`), an empty Pinned, every machine
    /// section with its default look (its title, the machine name, stays),
    /// the recent agent chats and the account band at the bottom. Every
    /// other section goes. A workspace or a group outside its machine
    /// section moves to the end of it (a group with its items; an empty
    /// group to the first machine section); the workspaces and groups
    /// already in a machine section stay where they are; other items in the
    /// removed sections and in Pinned go.
    #[serde(rename = "reset")]
    Reset,
    #[serde(rename = "item.put")]
    ItemPut { item: Item },
    #[serde(rename = "item.delete")]
    ItemDelete { id: ItemId },
    #[serde(rename = "section.put")]
    SectionPut { section: Section },
    #[serde(rename = "section.delete")]
    SectionDelete { id: SectionId },
}

/// Why an op was refused; `as_str` is the wire reason
/// (`validation.invalid` with `details.reason`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Refusal {
    UnknownSection,
    UnknownItem,
    DuplicateId,
    DuplicateRef,
    CrossMachine,
    ProviderOwned,
    Nesting,
    InvalidTarget,
    MachineRequired,
    NoMachine,
    InvalidTitle,
    InvalidValue,
    TooMany,
}

impl Refusal {
    pub fn as_str(self) -> &'static str {
        match self {
            Refusal::UnknownSection => "unknown_section",
            Refusal::UnknownItem => "unknown_item",
            Refusal::DuplicateId => "duplicate_id",
            Refusal::DuplicateRef => "duplicate_ref",
            Refusal::CrossMachine => "cross_machine",
            Refusal::ProviderOwned => "provider_owned",
            Refusal::Nesting => "nesting",
            Refusal::InvalidTarget => "invalid_target",
            Refusal::MachineRequired => "machine_required",
            Refusal::NoMachine => "no_machine",
            Refusal::InvalidTitle => "invalid_title",
            Refusal::InvalidValue => "invalid_value",
            Refusal::TooMany => "too_many",
        }
    }
}

impl std::fmt::Display for Refusal {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(self.as_str())
    }
}
