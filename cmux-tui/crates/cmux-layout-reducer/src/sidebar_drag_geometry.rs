//! The sidebar drag engine's per-move geometry (sidebar-v2 S5), moved from the
//! app's `SidebarDragGeometry` (CmuxNextSidebar) with the same inputs and
//! outputs, and the indent rule it reads (`SidebarIndent`).
//!
//! Pure geometry over the slots the sidebar drew and the acceptance table the
//! reducer gave at the drag's begin (`SidebarMirror.acceptance`): a list row is
//! found by binary search over the slots' y ranges, a tile by binary search
//! over its line and then over that line's tiles. The drop is one move
//! ([`Target`]). The app asks over `cmux_layout_reducer_json` op
//! `sidebar_drag_geometry` ([`respond`]).

use serde::{Deserialize, Serialize};
use std::collections::{HashMap, HashSet};

/// A slot's frame in the list's coordinates (`CGRect`).
#[derive(Debug, Clone, Copy, PartialEq, Default, Serialize, Deserialize)]
pub struct Rect {
    pub x: f64,
    pub y: f64,
    pub width: f64,
    pub height: f64,
}

impl Rect {
    pub fn min_x(&self) -> f64 {
        self.x.min(self.x + self.width)
    }
    pub fn mid_x(&self) -> f64 {
        self.x + self.width / 2.0
    }
    pub fn min_y(&self) -> f64 {
        self.y.min(self.y + self.height)
    }
    pub fn mid_y(&self) -> f64 {
        self.y + self.height / 2.0
    }
    pub fn max_y(&self) -> f64 {
        self.y.max(self.y + self.height)
    }
    /// The standardized height (`CGRect.height`).
    pub fn abs_height(&self) -> f64 {
        self.height.abs()
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum SlotKind {
    /// A list row (top half before, bottom half after).
    Row,
    /// A group header: the middle band drops into the group.
    Group,
    /// A tile or chip on a flowed line (left half before, right half after).
    Tile,
    /// A section's header or its empty drop zone: the drop goes first in it.
    Section,
    /// An open empty group's row: the drop goes into the group.
    EmptyGroup,
}

/// One place the pointer can be over.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Slot {
    /// The acceptance table's key (the view row key).
    pub key: String,
    /// The document item this slot draws; none for a section slot.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub item: Option<String>,
    pub section: String,
    /// The group the slot's item sits in.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub parent: Option<String>,
    pub frame: Rect,
    pub kind: SlotKind,
    /// A group header whose group is collapsed.
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub collapsed: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Zone {
    Before,
    Into,
    After,
}

/// What a drop next to (or into) one row may do, from `drag_begin`.
#[derive(Debug, Clone, PartialEq, Eq, Default, Serialize, Deserialize)]
pub struct Acceptance {
    #[serde(default)]
    pub before: bool,
    #[serde(default)]
    pub into: bool,
    #[serde(default)]
    pub after: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub refusal: Option<String>,
}

/// Where a move puts its items (`SidebarDocTarget`).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Target {
    pub section: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub parent: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub before: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub after: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub index: Option<i64>,
}

/// What the pointer is over and what a drop there does.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Hit {
    pub slot: Slot,
    pub zone: Zone,
    /// The move a drop makes; none when the reducer refuses it.
    pub target: Option<Target>,
    /// The reducer's refusal (`cross_machine`, ...), for the refused lift.
    pub refusal: Option<String>,
}

/// The middle band of a group header that drops into the group.
pub const INTO_BAND: (f64, f64) = (0.25, 0.75);
/// The share of a row's height a turning-back row drag must pass its middle by.
pub const HYSTERESIS_FRACTION: f64 = 0.2;
/// The most a turning-back row drag must pass a row's middle by, in points.
pub const MAX_HYSTERESIS: f64 = 8.0;

/// The one rule for how far a sidebar row moves in for its group level
/// (`SidebarIndent`, nested-groups prototype).
#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
pub struct Indent {
    /// One level's step.
    pub step: f64,
    /// The label width a row keeps at its deepest drawn level.
    #[serde(default = "Indent::default_minimum_label_width")]
    pub minimum_label_width: f64,
    /// Steps past this never move in more, whatever the width.
    #[serde(default = "Indent::default_max_visual_levels")]
    pub max_visual_levels: i64,
    /// A top-level group's members move in one step too (the plain folder look).
    #[serde(default)]
    pub indents_top_level: bool,
}

impl Indent {
    fn default_minimum_label_width() -> f64 {
        150.0
    }
    fn default_max_visual_levels() -> i64 {
        6
    }

    /// How many steps in the deepest drawn level may go, for a row `width` wide at level 0.
    pub fn visual_cap(&self, width: f64) -> i64 {
        if self.step <= 0.0 || self.step.is_nan() {
            return 0;
        }
        let fits = (self.max_visual_levels as f64)
            .min(0f64.max(((width - self.minimum_label_width) / self.step).floor()));
        1.max(saturating_int(fits))
    }

    /// The x offset of a row at `level`, from the list's leading inset.
    pub fn offset(&self, level: i64, width: f64) -> f64 {
        let steps = 0.max(if self.indents_top_level { level } else { level - 1 });
        (steps.min(self.visual_cap(width)) as f64) * self.step
    }

    /// The level a pointer at `x` (from the list's leading inset) points at, in `low..=high`.
    pub fn level_at_x(&self, x: f64, width: f64, low: i64, high: i64) -> i64 {
        if self.step <= 0.0 || self.step.is_nan() {
            return low;
        }
        let cap = self.visual_cap(width);
        let picked = if self.indents_top_level {
            saturating_int((x / self.step + 0.5).floor())
        } else if x < self.step / 2.0 {
            0
        } else {
            saturating_int((x / self.step).floor()).saturating_add(1)
        };
        let reach = if self.indents_top_level { picked } else { picked.saturating_sub(1) };
        let level = if reach >= cap { high } else { picked };
        high.min(low.max(level))
    }
}

/// `Int(value)` for a value already rounded, without Swift's trap on a value
/// out of range (NaN reads as 0).
fn saturating_int(value: f64) -> i64 {
    value as i64
}

/// The outliner rule's indent: at the bottom edge of a nested block the
/// pointer's x picks the level the drop goes to.
#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
pub struct Outline {
    pub indent: Indent,
    pub leading: f64,
    pub width: f64,
}

/// The slots of one drag's base layout and its acceptance table.
#[derive(Debug, Clone, Default)]
pub struct Geometry {
    lines: Vec<Vec<Slot>>,
    acceptance: HashMap<String, Acceptance>,
    group_headers: HashMap<String, Slot>,
    group_blocks: HashMap<String, (f64, f64)>,
    group_parent: HashMap<String, Option<String>>,
    group_slot: HashMap<String, Slot>,
    subtree_bottom: HashMap<String, f64>,
    first_member: HashMap<String, Slot>,
    pub outline: Option<Outline>,
}

impl Geometry {
    /// `slots` in any order; `acceptance` from the drag's begin (empty: every
    /// place is accepted, as for a mirror without the table).
    pub fn new(slots: &[Slot], acceptance: HashMap<String, Acceptance>) -> Self {
        let mut sorted: Vec<&Slot> = slots.iter().collect();
        sorted.sort_by(|a, b| {
            let (ay, by) = (a.frame.min_y(), b.frame.min_y());
            if ay != by { ay.total_cmp(&by) } else { a.frame.min_x().total_cmp(&b.frame.min_x()) }
        });
        let mut lines: Vec<Vec<Slot>> = Vec::new();
        for slot in &sorted {
            let joins = lines.last().and_then(|line| line.last()).is_some_and(|last| {
                slot.kind == SlotKind::Tile
                    && last.kind == SlotKind::Tile
                    && (last.frame.min_y() - slot.frame.min_y()).abs() < 0.5
            });
            match lines.last_mut() {
                Some(line) if joins => line.push((*slot).clone()),
                _ => lines.push(vec![(*slot).clone()]),
            }
        }
        let mut headers: HashMap<String, Slot> = HashMap::new();
        for slot in slots.iter().filter(|s| s.kind == SlotKind::Group) {
            headers.insert(slot.key.clone(), slot.clone());
        }
        let mut blocks: HashMap<String, (f64, f64)> = HashMap::new();
        for slot in slots {
            // A slot widens its own group's block and every enclosing group's.
            let mut group = if slot.kind == SlotKind::Group {
                Some(slot.key.clone())
            } else {
                slot.parent.clone()
            };
            let mut seen = HashSet::new();
            let range = (slot.frame.min_y(), slot.frame.max_y());
            while let Some(id) = group {
                if !seen.insert(id.clone()) {
                    break;
                }
                let Some(header) = headers.get(&id) else { break };
                let widened = match blocks.get(&id) {
                    Some(&(low, high)) => (low.min(range.0), high.max(range.1)),
                    None => range,
                };
                blocks.insert(id, widened);
                group = header.parent.clone();
            }
        }
        let mut first_member: HashMap<String, Slot> = HashMap::new();
        for slot in sorted.iter().filter(|s| matches!(s.kind, SlotKind::Row | SlotKind::Group)) {
            if let Some(parent) = &slot.parent
                && headers.get(parent).is_some_and(|h| !h.collapsed)
                && !first_member.contains_key(parent)
            {
                first_member.insert(parent.clone(), (*slot).clone());
            }
        }
        let mut group_parent: HashMap<String, Option<String>> = HashMap::new();
        let mut group_slot: HashMap<String, Slot> = HashMap::new();
        for slot in slots.iter().filter(|s| s.kind == SlotKind::Group) {
            let Some(item) = &slot.item else { continue };
            group_parent.insert(item.clone(), slot.parent.clone());
            group_slot.insert(item.clone(), slot.clone());
        }
        let mut subtree_bottom: HashMap<String, f64> = HashMap::new();
        for slot in slots.iter().filter(|s| s.kind != SlotKind::Section) {
            let mut current =
                if slot.kind == SlotKind::Group { slot.item.clone() } else { slot.parent.clone() };
            let mut seen = HashSet::new();
            while let Some(id) = current {
                if !seen.insert(id.clone()) {
                    break;
                }
                let Some(parent) = group_parent.get(&id) else { break };
                let bottom = subtree_bottom.get(&id).copied().unwrap_or(f64::NEG_INFINITY);
                subtree_bottom.insert(id.clone(), bottom.max(slot.frame.max_y()));
                current = parent.clone();
            }
        }
        Self {
            lines,
            acceptance,
            group_headers: headers,
            group_blocks: blocks,
            group_parent,
            group_slot,
            subtree_bottom,
            first_member,
            outline: None,
        }
    }

    /// The parent group item of group item `id`, if `id` is a group item.
    fn parent_of(&self, id: &str) -> Option<String> {
        self.group_parent.get(id).cloned().flatten()
    }

    /// The level a slot draws at: a header at its tree level, a member one level under its group.
    pub fn level(&self, slot: &Slot) -> i64 {
        let is_group = slot.kind == SlotKind::Group;
        let mut level = if is_group || slot.parent.is_none() { 0 } else { 1 };
        let mut current = if is_group {
            slot.parent.clone()
        } else {
            slot.parent.as_deref().and_then(|p| self.parent_of(p))
        };
        let mut seen = HashSet::new();
        while let Some(id) = current {
            if !seen.insert(id.clone()) {
                break;
            }
            level += 1;
            current = self.parent_of(&id);
        }
        level
    }

    /// The outliner rule: a drop after the last row of a nested block, with the
    /// pointer left of that row's level, goes after the ancestor group whose
    /// level the pointer's x picks (drag out of a group).
    fn outlined(&self, hit: Hit, x: f64) -> Hit {
        let Some(outline) = self.outline else { return hit };
        if hit.zone != Zone::After || matches!(hit.slot.kind, SlotKind::Section | SlotKind::Tile) {
            return hit;
        }
        let is_group = hit.slot.kind == SlotKind::Group;
        let mut chain: Vec<(Slot, i64)> = vec![(hit.slot.clone(), self.level(&hit.slot))];
        let mut current = if is_group {
            hit.slot.item.as_deref().and_then(|i| self.parent_of(i))
        } else {
            hit.slot.parent.clone()
        };
        let max_y = hit.slot.frame.max_y();
        // An open header's own "after" is inside its block: only a closed one (or a member row) ends it.
        if is_group
            && let Some(item) = &hit.slot.item
            && self.subtree_bottom.get(item).copied().unwrap_or(max_y) > max_y + 0.5
        {
            return hit;
        }
        let mut seen = HashSet::new();
        while let Some(id) = current {
            if !seen.insert(id.clone()) {
                break;
            }
            let Some(header) = self.group_slot.get(&id) else { break };
            let bottom = self.subtree_bottom.get(&id).copied().unwrap_or(header.frame.max_y());
            if (bottom - max_y).abs() >= 0.5 {
                break;
            }
            chain.push((header.clone(), self.level(header)));
            current = self.parent_of(&id);
        }
        let (Some(deepest), Some(shallowest)) = (chain.first(), chain.last()) else { return hit };
        if chain.len() <= 1 || shallowest.1 > deepest.1 {
            return hit;
        }
        let picked =
            outline.indent.level_at_x(x - outline.leading, outline.width, shallowest.1, deepest.1);
        match chain.iter().find(|(_, level)| *level <= picked) {
            Some((place, _)) if *place != hit.slot && self.allows(place, Zone::After) => Hit {
                slot: place.clone(),
                zone: Zone::After,
                target: Some(target(place, Zone::After)),
                refusal: None,
            },
            _ => hit,
        }
    }

    /// The level a drop of `hit` lands at: a member of the group it goes into, else its slot's level.
    pub fn drop_level(&self, hit: &Hit) -> i64 {
        self.level(&hit.slot) + i64::from(hit.zone == Zone::Into)
    }

    /// The slot under `(x, y)` (or the nearest one above or below the slots),
    /// its zone and the move a drop there makes. A drop a group's rows refuse
    /// goes before or after the whole group instead, by which half of the
    /// group's block holds the point, climbing to the nearest enclosing group
    /// that takes it.
    pub fn hit(&self, x: f64, y: f64) -> Option<Hit> {
        let line = self.line_at(y)?;
        let slot = slot_in(line, x)?;
        if slot.kind == SlotKind::Group
            && !self.allows(slot, Zone::Into)
            && let Some(around) = self.around(&slot.key, y)
        {
            return Some(around);
        }
        let zone = zone(slot, x, y);
        // An open header's bottom quarter sits right over its first member: a drop there goes before that member.
        if slot.kind == SlotKind::Group
            && zone == Zone::After
            && let Some(first) = self.first_member.get(&slot.key)
            && self.allows(first, Zone::Before)
        {
            return Some(Hit {
                slot: first.clone(),
                zone: Zone::Before,
                target: Some(target(first, Zone::Before)),
                refusal: None,
            });
        }
        if self.allows(slot, zone) {
            let hit =
                Hit { slot: slot.clone(), zone, target: Some(target(slot, zone)), refusal: None };
            return Some(self.outlined(hit, x));
        }
        if let Some(parent) = &slot.parent
            && let Some(around) = self.around(parent, y)
        {
            return Some(around);
        }
        let refusal = self
            .table(slot)
            .and_then(|t| t.refusal.clone())
            .unwrap_or_else(|| "refused".to_owned());
        Some(Hit { slot: slot.clone(), zone, target: None, refusal: Some(refusal) })
    }

    /// A drop right before or after the slot keyed `key` (a section's slot:
    /// first in it), if accepted there.
    pub fn beside(&self, key: &str, after: bool) -> Option<Hit> {
        let slot = self.lines.iter().flatten().find(|s| s.key == key)?;
        let zone = if slot.kind == SlotKind::Section {
            Zone::Into
        } else if after {
            Zone::After
        } else {
            Zone::Before
        };
        if !self.allows(slot, zone) {
            return None;
        }
        Some(Hit { slot: slot.clone(), zone, target: Some(target(slot, zone)), refusal: None })
    }

    fn table(&self, slot: &Slot) -> Option<&Acceptance> {
        self.acceptance
            .get(&slot.key)
            .or_else(|| slot.item.as_ref().and_then(|i| self.acceptance.get(i)))
    }

    /// Whether a drop at `zone` of `slot` is accepted.
    fn allows(&self, slot: &Slot, zone: Zone) -> bool {
        let Some(table) = self.table(slot) else {
            // A header the table lacks (one machine draws none) takes the drop.
            return self.acceptance.is_empty() || slot.kind == SlotKind::Section;
        };
        match zone {
            Zone::Before => table.before,
            Zone::Into => table.into,
            Zone::After => table.after,
        }
    }

    /// A drop before (upper half of the block) or after (lower half) the whole
    /// group `group`, if accepted there, else around the group that holds it.
    fn around(&self, group: &str, y: f64) -> Option<Hit> {
        let mut current = Some(group.to_owned());
        let mut seen = HashSet::new();
        while let Some(id) = current {
            if !seen.insert(id.clone()) {
                return None;
            }
            let (Some(header), Some(&(low, high))) =
                (self.group_headers.get(&id), self.group_blocks.get(&id))
            else {
                return None;
            };
            let zone = if y < (low + high) / 2.0 { Zone::Before } else { Zone::After };
            if self.allows(header, zone) {
                return Some(Hit {
                    slot: header.clone(),
                    zone,
                    target: Some(target(header, zone)),
                    refusal: None,
                });
            }
            current = header.parent.clone();
        }
        None
    }

    /// The line whose y range holds `y` (binary search), else the nearest.
    fn line_at(&self, y: f64) -> Option<&Vec<Slot>> {
        if self.lines.is_empty() {
            return None;
        }
        let (mut low, mut high) = (0usize, self.lines.len() - 1);
        while low < high {
            let mid = (low + high).div_ceil(2);
            let top = self.lines.get(mid).and_then(|l| l.first()).map_or(0.0, |s| s.frame.min_y());
            if top <= y {
                low = mid;
            } else {
                high = mid - 1;
            }
        }
        self.lines.get(low)
    }

    /// The base y a dragged list card's drop is hit-tested at, from the card's
    /// `top` and `bottom` (display coordinates, the gap open at `gap_y`); none
    /// keeps `current`. The midpoint rule (Lawrence 2026-10-20) with the
    /// turning-back hysteresis.
    #[allow(clippy::too_many_arguments)]
    pub fn edge_y(
        &self,
        top: f64,
        bottom: f64,
        x: f64,
        moving_up: bool,
        gap_y: Option<f64>,
        gap_height: f64,
        current: Option<&Target>,
        reversing: bool,
    ) -> Option<f64> {
        let y = base_y(if moving_up { top } else { bottom }, gap_y, gap_height);
        let Some(current) = current.filter(|_| reversing) else { return Some(y) };
        let Some(candidate) = self.hit(x, y) else { return Some(y) };
        if candidate.target.as_ref() == Some(current) {
            return Some(y);
        }
        let margin = hysteresis(candidate.slot.frame.abs_height());
        let past = self.hit(x, if moving_up { y + margin } else { y - margin });
        (past.and_then(|h| h.target) == candidate.target).then_some(y)
    }
}

/// The tile under `x` on a flowed line (binary search), else the line's only slot.
fn slot_in(line: &[Slot], x: f64) -> Option<&Slot> {
    if line.len() <= 1 {
        return line.first();
    }
    let (mut low, mut high) = (0usize, line.len() - 1);
    while low < high {
        let mid = (low + high).div_ceil(2);
        if line.get(mid).is_some_and(|s| s.frame.min_x() <= x) {
            low = mid;
        } else {
            high = mid - 1;
        }
    }
    line.get(low)
}

/// The zone of `slot` that `(x, y)` is in.
pub fn zone(slot: &Slot, x: f64, y: f64) -> Zone {
    let frame = &slot.frame;
    match slot.kind {
        SlotKind::Section | SlotKind::EmptyGroup => Zone::Into,
        SlotKind::Tile => {
            if x < frame.mid_x() {
                Zone::Before
            } else {
                Zone::After
            }
        }
        SlotKind::Group => {
            let height = frame.abs_height();
            let fraction = if height > 0.0 { (y - frame.min_y()) / height } else { 0.5 };
            if (INTO_BAND.0..=INTO_BAND.1).contains(&fraction) {
                Zone::Into
            } else if fraction < INTO_BAND.0 {
                Zone::Before
            } else {
                Zone::After
            }
        }
        SlotKind::Row => {
            if y < frame.mid_y() {
                Zone::Before
            } else {
                Zone::After
            }
        }
    }
}

/// The move a drop at `zone` of `slot` makes.
pub fn target(slot: &Slot, zone: Zone) -> Target {
    let empty = Target {
        section: slot.section.clone(),
        parent: None,
        before: None,
        after: None,
        index: None,
    };
    let Some(item) = slot.item.clone().filter(|_| slot.kind != SlotKind::Section) else {
        return Target { index: Some(0), ..empty };
    };
    match zone {
        Zone::Before => Target { parent: slot.parent.clone(), before: Some(item), ..empty },
        Zone::After => Target { parent: slot.parent.clone(), after: Some(item), ..empty },
        Zone::Into => Target { parent: Some(item), ..empty },
    }
}

/// The margin past a row's middle that turns a row drag back, for a row `height` tall.
pub fn hysteresis(height: f64) -> f64 {
    MAX_HYSTERESIS.min(0f64.max(height) * HYSTERESIS_FRACTION)
}

/// The display y of `y` in a layout drawn without the open gap (`gap_y`,
/// `gap_height`): rows below the gap were pushed down by it.
pub fn base_y(y: f64, gap_y: Option<f64>, gap_height: f64) -> f64 {
    match gap_y {
        Some(gap) if y >= gap => gap.max(y - gap_height),
        _ => y,
    }
}

/// One question to a drag's geometry.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "ask", rename_all = "snake_case")]
pub enum Query {
    /// `hit(point)`, with the drop level of the hit.
    Hit { x: f64, y: f64 },
    /// `beside(key, after:)`.
    Beside { key: String, after: bool },
    /// `edgeY(top:bottom:x:movingUp:gapY:gapHeight:current:reversing:)`.
    EdgeY {
        top: f64,
        bottom: f64,
        x: f64,
        moving_up: bool,
        #[serde(default)]
        gap_y: Option<f64>,
        #[serde(default)]
        gap_height: f64,
        #[serde(default)]
        current: Option<Target>,
        #[serde(default)]
        reversing: bool,
    },
    /// The level the slot keyed `key` draws at (`level(of:)`).
    Level { key: String },
}

/// One answer, in the order of the queries.
#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(untagged)]
pub enum Answer {
    Hit {
        hit: Option<Hit>,
        #[serde(skip_serializing_if = "Option::is_none")]
        drop_level: Option<i64>,
    },
    EdgeY {
        edge_y: Option<f64>,
    },
    Level {
        level: Option<i64>,
    },
}

/// A drag's slots, acceptance table and outline, and the questions to answer.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
pub struct Request {
    #[serde(default)]
    pub slots: Vec<Slot>,
    #[serde(default)]
    pub acceptance: HashMap<String, Acceptance>,
    #[serde(default)]
    pub outline: Option<Outline>,
    #[serde(default)]
    pub queries: Vec<Query>,
}

#[derive(Debug, Clone, Default, PartialEq, Serialize)]
pub struct Reply {
    pub answers: Vec<Answer>,
}

/// Answers every query of `request` over one geometry.
pub fn respond(request: &Request) -> Reply {
    let mut geometry = Geometry::new(&request.slots, request.acceptance.clone());
    geometry.outline = request.outline;
    let answers = request
        .queries
        .iter()
        .map(|query| match query {
            Query::Hit { x, y } => {
                let hit = geometry.hit(*x, *y);
                let drop_level = hit.as_ref().map(|h| geometry.drop_level(h));
                Answer::Hit { hit, drop_level }
            }
            Query::Beside { key, after } => {
                let hit = geometry.beside(key, *after);
                let drop_level = hit.as_ref().map(|h| geometry.drop_level(h));
                Answer::Hit { hit, drop_level }
            }
            Query::EdgeY { top, bottom, x, moving_up, gap_y, gap_height, current, reversing } => {
                Answer::EdgeY {
                    edge_y: geometry.edge_y(
                        *top,
                        *bottom,
                        *x,
                        *moving_up,
                        *gap_y,
                        *gap_height,
                        current.as_ref(),
                        *reversing,
                    ),
                }
            }
            Query::Level { key } => Answer::Level {
                level: geometry
                    .lines
                    .iter()
                    .flatten()
                    .find(|s| s.key == *key)
                    .map(|s| geometry.level(s)),
            },
        })
        .collect();
    Reply { answers }
}

#[cfg(test)]
#[path = "sidebar_drag_geometry_tests.rs"]
mod tests;
