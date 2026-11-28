//! The sidebar drag's per-move drop geometry (sidebar-v2 S5), moved from
//! the app's `SidebarDragGeometry.swift`: pure geometry over the slots the
//! sidebar drew and the acceptance table the reducer gave at the drag's
//! begin. A list row is found by binary search over the slots' y ranges, a
//! tile by binary search over its line and then over that line's tiles; the
//! drop is one move ([`Target`]).
//!
//! The app builds a [`Geometry`] once per drag (the FFI keeps it, see
//! `cmux-layout-reducer-ffi`'s `sidebar_geometry` ops) and asks it on every
//! mouse move, so a move costs the same at any number of rows.

use serde::{Deserialize, Serialize};
use std::collections::{HashMap, HashSet};

/// The middle band of a group header that drops into the group.
pub const INTO_BAND: (f64, f64) = (0.25, 0.75);
/// The share of a row's height a turning-back row drag must pass its middle by ([`Geometry::edge_y`]).
pub const HYSTERESIS_FRACTION: f64 = 0.2;
/// The most a turning-back row drag must pass a row's middle by, in points.
pub const MAX_HYSTERESIS: f64 = 8.0;
/// Two tiles whose tops differ by less than this share a flowed line.
const SAME_LINE: f64 = 0.5;
/// Two bottoms closer than this are the same edge (a block ends at a row).
const SAME_EDGE: f64 = 0.5;

/// A slot's frame in the list's flipped coordinates (y grows down).
#[derive(Clone, Copy, Debug, Default, PartialEq, Deserialize, Serialize)]
pub struct Frame {
    pub x: f64,
    pub y: f64,
    pub width: f64,
    pub height: f64,
}

impl Frame {
    pub fn new(x: f64, y: f64, width: f64, height: f64) -> Self {
        Self { x, y, width, height }
    }
    fn min_x(&self) -> f64 {
        self.x.min(self.x + self.width)
    }
    fn mid_x(&self) -> f64 {
        self.x + self.width / 2.0
    }
    fn min_y(&self) -> f64 {
        self.y.min(self.y + self.height)
    }
    fn max_y(&self) -> f64 {
        self.y.max(self.y + self.height)
    }
    fn mid_y(&self) -> f64 {
        self.y + self.height / 2.0
    }
    fn height(&self) -> f64 {
        self.height.abs()
    }
}

/// What a slot is.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Deserialize, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum Kind {
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
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize)]
pub struct Slot {
    /// The acceptance table's key (the view row key).
    pub key: String,
    /// The document item this slot draws; none for a section slot.
    #[serde(default)]
    pub item: Option<String>,
    pub section: String,
    /// The group the slot's item sits in.
    #[serde(default)]
    pub parent: Option<String>,
    pub frame: Frame,
    pub kind: Kind,
    /// A group header whose group is collapsed (it may still show a kept member row under it).
    #[serde(default)]
    pub collapsed: bool,
}

/// What a drop next to (or into) one row may do, from `drag_begin`.
#[derive(Clone, Debug, Default, PartialEq, Eq, Deserialize, Serialize)]
pub struct Acceptance {
    #[serde(default)]
    pub before: bool,
    #[serde(default)]
    pub into: bool,
    #[serde(default)]
    pub after: bool,
    /// Why nothing is accepted (`cross_machine`, `provider_owned`...).
    #[serde(default)]
    pub refusal: Option<String>,
}

/// Where in a slot the pointer is.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Deserialize, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum Zone {
    Before,
    Into,
    After,
}

/// Where a move puts its items: a section, optionally a group in it, and an
/// anchor item (`before` / `after`) or an index (the app's `SidebarDocTarget`).
#[derive(Clone, Debug, Default, PartialEq, Eq, Hash, Deserialize, Serialize)]
pub struct Target {
    pub section: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub parent: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub before: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub after: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub index: Option<u32>,
}

/// What the pointer is over and what a drop there does.
#[derive(Clone, Debug, PartialEq, Serialize)]
pub struct Hit {
    /// The slot's place in the slots the geometry was built from.
    pub slot: usize,
    pub zone: Zone,
    /// The move a drop makes; none when the reducer refuses it.
    pub target: Option<Target>,
    /// The reducer's refusal (`cross_machine`, ...), for the refused lift.
    pub refusal: Option<String>,
}

fn default_minimum_label_width() -> f64 {
    150.0
}
fn default_max_visual_levels() -> i32 {
    6
}

/// The one rule for how far a sidebar row moves in for its group level (the
/// app's `SidebarIndent`): the part the drop's outliner rule reads.
#[derive(Clone, Copy, Debug, PartialEq, Deserialize, Serialize)]
pub struct Indent {
    /// One level's step.
    pub step: f64,
    /// The label width a row keeps at its deepest drawn level.
    #[serde(default = "default_minimum_label_width")]
    pub minimum_label_width: f64,
    /// Steps past this never move in more, whatever the width.
    #[serde(default = "default_max_visual_levels")]
    pub max_visual_levels: i32,
    /// Every level L sits at L steps (the plain folder look); false keeps level 1 on level 0's x.
    #[serde(default)]
    pub indents_top_level: bool,
}

impl Indent {
    pub fn new(step: f64) -> Self {
        Self {
            step,
            minimum_label_width: default_minimum_label_width(),
            max_visual_levels: default_max_visual_levels(),
            indents_top_level: false,
        }
    }

    /// How many steps in the deepest drawn level may go, for a row `width` wide at level 0.
    fn visual_cap(&self, width: f64) -> f64 {
        if self.step.partial_cmp(&0.0) != Some(std::cmp::Ordering::Greater) {
            return 0.0;
        }
        let fits = f64::from(self.max_visual_levels)
            .min(0f64.max(((width - self.minimum_label_width) / self.step).floor()));
        // A NaN width (never drawn) counts as no room, like the app's Int conversion of 0.
        1f64.max(if fits.is_nan() { 0.0 } else { fits })
    }

    /// The level a pointer at `x` (from the list's leading inset) points at, in `low...high`: a drop at a
    /// block's bottom edge goes to the level its x picks, like an outliner.
    pub fn level_at_x(&self, x: f64, width: f64, low: i32, high: i32) -> i32 {
        if self.step.partial_cmp(&0.0) != Some(std::cmp::Ordering::Greater) {
            return low;
        }
        let cap = self.visual_cap(width);
        // Level L >= 1 sits at (L - 1) steps, level 0 shares level 1's x: a pointer in the first half step
        // picks 0, the rest of that step 1, then each step one level deeper. With `indents_top_level` each
        // level has its own x, L steps in: the pointer picks the nearest one.
        let picked = if self.indents_top_level {
            (x / self.step + 0.5).floor()
        } else if x < self.step / 2.0 {
            0.0
        } else {
            (x / self.step).floor() + 1.0
        };
        let steps = if self.indents_top_level { picked } else { picked - 1.0 };
        // Past the cap every level shares one x: the deepest allowed one wins there.
        let level = if steps >= cap { f64::from(high) } else { picked };
        let clamped = f64::from(high).min(f64::from(low).max(level));
        if clamped.is_nan() {
            return low;
        }
        (low..=high).find(|candidate| f64::from(*candidate) >= clamped).unwrap_or(high)
    }
}

/// The outliner rule's indent: at the bottom edge of a nested block the pointer's x picks the level the
/// drop goes to.
#[derive(Clone, Copy, Debug, PartialEq, Deserialize, Serialize)]
pub struct Outline {
    pub indent: Indent,
    pub leading: f64,
    pub width: f64,
}

/// A dragged list card's edges, for [`Geometry::edge_y`].
#[derive(Clone, Debug, Default, PartialEq, Deserialize, Serialize)]
pub struct Edge {
    /// The card's top and bottom, in display coordinates.
    pub top: f64,
    pub bottom: f64,
    /// The pointer's x (the outliner rule reads it).
    pub x: f64,
    pub moving_up: bool,
    /// The open gap's top; none when no gap is open.
    #[serde(default)]
    pub gap_y: Option<f64>,
    #[serde(default)]
    pub gap_height: f64,
    /// The drop the drag shows now.
    #[serde(default)]
    pub current: Option<Target>,
    /// The last change of the drop came the other way.
    #[serde(default)]
    pub reversing: bool,
}

/// The drop geometry of one drag.
#[derive(Clone, Debug, Default)]
pub struct Geometry {
    slots: Vec<Slot>,
    /// The slots by line, in y then x order (a flowed line holds its tiles).
    lines: Vec<Vec<usize>>,
    acceptance: HashMap<String, Acceptance>,
    /// Each group header slot, by its key.
    group_headers: HashMap<String, usize>,
    /// Each group's block (its header and the member rows under it), by the group's key.
    group_blocks: HashMap<String, (f64, f64)>,
    /// Each group item's parent group item (none at the top), from the header slots.
    group_parent: HashMap<String, Option<String>>,
    /// Each group item's header slot.
    group_slot: HashMap<String, usize>,
    /// The bottom of each group item's whole subtree.
    subtree_bottom: HashMap<String, f64>,
    /// Each open group's first member slot, by the group's key. A collapsed group has none.
    first_member: HashMap<String, usize>,
    /// The outliner rule; none keeps the y-only rule.
    outline: Option<Outline>,
}

impl Geometry {
    /// `slots` in any order; `acceptance` from the drag's begin (empty: every place is accepted).
    pub fn new(slots: Vec<Slot>, acceptance: HashMap<String, Acceptance>) -> Self {
        let mut sorted: Vec<usize> = (0..slots.len()).collect();
        sorted.sort_by(|a, b| match (slots.get(*a), slots.get(*b)) {
            (Some(a), Some(b)) => a
                .frame
                .min_y()
                .total_cmp(&b.frame.min_y())
                .then(a.frame.min_x().total_cmp(&b.frame.min_x())),
            _ => std::cmp::Ordering::Equal,
        });
        let mut lines: Vec<Vec<usize>> = Vec::new();
        for &index in &sorted {
            let Some(slot) = slots.get(index) else { continue };
            let joins = lines
                .last()
                .and_then(|line| line.last())
                .and_then(|last| slots.get(*last))
                .is_some_and(|last| {
                    slot.kind == Kind::Tile
                        && last.kind == Kind::Tile
                        && (last.frame.min_y() - slot.frame.min_y()).abs() < SAME_LINE
                });
            match lines.last_mut() {
                Some(line) if joins => line.push(index),
                _ => lines.push(vec![index]),
            }
        }
        let mut headers: HashMap<String, usize> = HashMap::new();
        for (index, slot) in slots.iter().enumerate() {
            if slot.kind == Kind::Group {
                headers.insert(slot.key.clone(), index);
            }
        }
        let mut blocks: HashMap<String, (f64, f64)> = HashMap::new();
        for slot in &slots {
            // A slot widens its own group's block and every enclosing group's: a subgroup sits in its parent's.
            let mut group =
                if slot.kind == Kind::Group { Some(&slot.key) } else { slot.parent.as_ref() };
            let mut seen: HashSet<&String> = HashSet::new();
            let (low, high) = (slot.frame.min_y(), slot.frame.max_y());
            while let Some(id) = group {
                let Some(header) = headers.get(id).and_then(|index| slots.get(*index)) else {
                    break;
                };
                if !seen.insert(id) {
                    break;
                }
                blocks
                    .entry(id.clone())
                    .and_modify(|block| *block = (block.0.min(low), block.1.max(high)))
                    .or_insert((low, high));
                group = header.parent.as_ref();
            }
        }
        let mut first_member: HashMap<String, usize> = HashMap::new();
        for &index in &sorted {
            let Some(slot) = slots.get(index) else { continue };
            if slot.kind != Kind::Row && slot.kind != Kind::Group {
                continue;
            }
            let Some(parent) = &slot.parent else { continue };
            let open = headers
                .get(parent)
                .and_then(|header| slots.get(*header))
                .is_some_and(|header| !header.collapsed);
            if open {
                first_member.entry(parent.clone()).or_insert(index);
            }
        }
        let mut group_parent: HashMap<String, Option<String>> = HashMap::new();
        let mut group_slot: HashMap<String, usize> = HashMap::new();
        for (index, slot) in slots.iter().enumerate() {
            if slot.kind != Kind::Group {
                continue;
            }
            let Some(item) = &slot.item else { continue };
            group_parent.insert(item.clone(), slot.parent.clone());
            group_slot.insert(item.clone(), index);
        }
        let mut subtree_bottom: HashMap<String, f64> = HashMap::new();
        for slot in &slots {
            if slot.kind == Kind::Section {
                continue;
            }
            let mut current =
                if slot.kind == Kind::Group { slot.item.as_ref() } else { slot.parent.as_ref() };
            let mut seen: HashSet<&String> = HashSet::new();
            while let Some(id) = current {
                let Some(parent) = group_parent.get(id) else { break };
                if !seen.insert(id) {
                    break;
                }
                let bottom = slot.frame.max_y();
                subtree_bottom
                    .entry(id.clone())
                    .and_modify(|value| *value = value.max(bottom))
                    .or_insert(bottom);
                current = parent.as_ref();
            }
        }
        Self {
            slots,
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

    /// The same geometry with the outliner rule on (or off, with none).
    pub fn with_outline(mut self, outline: Option<Outline>) -> Self {
        self.outline = outline;
        self
    }

    /// The slots the geometry was built from, in the order given.
    pub fn slots(&self) -> &[Slot] {
        &self.slots
    }

    fn parent_of_group(&self, id: &str) -> Option<&String> {
        self.group_parent.get(id).and_then(Option::as_ref)
    }

    /// The level a slot draws at: a header at its tree level, a member one level under its group.
    pub fn level(&self, slot: &Slot) -> i32 {
        let mut level: i32 = if slot.kind == Kind::Group || slot.parent.is_none() { 0 } else { 1 };
        let mut current = if slot.kind == Kind::Group {
            slot.parent.as_ref()
        } else {
            slot.parent.as_ref().and_then(|parent| self.parent_of_group(parent))
        };
        let mut seen: HashSet<&String> = HashSet::new();
        while let Some(id) = current {
            if !seen.insert(id) {
                break;
            }
            level = level.saturating_add(1);
            current = self.parent_of_group(id);
        }
        level
    }

    /// The level a drop of `hit` lands at: a member of the group it goes into, else its slot's level.
    pub fn drop_level(&self, hit: &Hit) -> i32 {
        let Some(slot) = self.slots.get(hit.slot) else { return 0 };
        let level = self.level(slot);
        if hit.zone == Zone::Into { level.saturating_add(1) } else { level }
    }

    /// The outliner rule: a drop after the last row of a nested block, with the pointer left of that row's
    /// level, goes after the ancestor group whose level the pointer's x picks (drag out of a group). Only
    /// ancestors whose whole subtree ends at this row qualify: a drop never lands inside a block above.
    fn outlined(&self, hit: Hit, x: f64) -> Hit {
        let Some(outline) = self.outline else { return hit };
        let Some(slot) = self.slots.get(hit.slot) else { return hit };
        if hit.zone != Zone::After || slot.kind == Kind::Section || slot.kind == Kind::Tile {
            return hit;
        }
        // A group header's own "after" is inside its block when it is open: only a closed one (or a member
        // row) ends it.
        if slot.kind == Kind::Group
            && let Some(item) = &slot.item
            && self.subtree_bottom.get(item).copied().unwrap_or(slot.frame.max_y())
                > slot.frame.max_y() + SAME_EDGE
        {
            return hit;
        }
        // The chain of places a drop at this bottom edge may go, deepest first.
        let mut chain: Vec<(usize, i32)> = vec![(hit.slot, self.level(slot))];
        let mut current = if slot.kind == Kind::Group {
            slot.item.as_ref().and_then(|item| self.parent_of_group(item))
        } else {
            slot.parent.as_ref()
        };
        let mut seen: HashSet<&String> = HashSet::new();
        while let Some(id) = current {
            let Some((index, header)) = self
                .group_slot
                .get(id)
                .and_then(|index| self.slots.get(*index).map(|header| (*index, header)))
            else {
                break;
            };
            let bottom = self.subtree_bottom.get(id).copied().unwrap_or(header.frame.max_y());
            if (bottom - slot.frame.max_y()).abs() >= SAME_EDGE || !seen.insert(id) {
                break;
            }
            chain.push((index, self.level(header)));
            current = self.parent_of_group(id);
        }
        if chain.len() < 2 {
            return hit;
        }
        let (Some(&(_, deepest)), Some(&(_, shallowest))) = (chain.first(), chain.last()) else {
            return hit;
        };
        let picked =
            outline.indent.level_at_x(x - outline.leading, outline.width, shallowest, deepest);
        let Some(&(place, _)) = chain.iter().find(|(_, level)| *level <= picked) else {
            return hit;
        };
        let Some(place_slot) = self.slots.get(place) else { return hit };
        if place_slot == slot || !self.allows(place_slot, Zone::After) {
            return hit;
        }
        Hit {
            slot: place,
            zone: Zone::After,
            target: Some(target(place_slot, Zone::After)),
            refusal: None,
        }
    }

    /// The slot under `(x, y)` (or the nearest one above or below the slots), its zone and the move a drop
    /// there makes.
    ///
    /// A drop a group's rows refuse (a dragged group lands beside rows only at its own level or above; a
    /// workspace of another machine) goes before or after the whole group instead, by which half of the
    /// group's block holds the point: over its header or any of its member rows, climbing to the nearest
    /// enclosing group that takes it.
    pub fn hit(&self, x: f64, y: f64) -> Option<Hit> {
        let line = self.line_at(y)?;
        let index = self.slot_in(line, x)?;
        let slot = self.slots.get(index)?;
        if slot.kind == Kind::Group
            && !self.allows(slot, Zone::Into)
            && let Some(around) = self.around(&slot.key, y)
        {
            return Some(around);
        }
        let zone = zone(slot, x, y);
        // An open header's bottom quarter sits right over its first member: a drop there goes before that
        // member, first in the group (Leo 2026-11-05, "the proper, you know, dragging correctness kind of
        // things").
        if slot.kind == Kind::Group
            && zone == Zone::After
            && let Some(&first) = self.first_member.get(&slot.key)
            && let Some(first_slot) = self.slots.get(first)
            && self.allows(first_slot, Zone::Before)
        {
            return Some(Hit {
                slot: first,
                zone: Zone::Before,
                target: Some(target(first_slot, Zone::Before)),
                refusal: None,
            });
        }
        if self.allows(slot, zone) {
            let hit = Hit { slot: index, zone, target: Some(target(slot, zone)), refusal: None };
            return Some(self.outlined(hit, x));
        }
        if let Some(parent) = &slot.parent
            && let Some(around) = self.around(parent, y)
        {
            return Some(around);
        }
        let refusal = self
            .table(slot)
            .and_then(|table| table.refusal.clone())
            .unwrap_or_else(|| "refused".into());
        Some(Hit { slot: index, zone, target: None, refusal: Some(refusal) })
    }

    /// A drop right before or after the slot keyed `key` (a section's slot: first in it), if accepted there.
    ///
    /// A dragged group's slots use it: the drop goes beside a whole top-level block's first row, never into
    /// a group or beside one of its members, whatever the acceptance table would take there.
    pub fn beside(&self, key: &str, after: bool) -> Option<Hit> {
        let index = self
            .lines
            .iter()
            .flatten()
            .copied()
            .find(|index| self.slots.get(*index).is_some_and(|slot| slot.key == key))?;
        let slot = self.slots.get(index)?;
        let zone = if slot.kind == Kind::Section {
            Zone::Into
        } else if after {
            Zone::After
        } else {
            Zone::Before
        };
        if !self.allows(slot, zone) {
            return None;
        }
        Some(Hit { slot: index, zone, target: Some(target(slot, zone)), refusal: None })
    }

    fn table(&self, slot: &Slot) -> Option<&Acceptance> {
        self.acceptance
            .get(&slot.key)
            .or_else(|| slot.item.as_ref().and_then(|item| self.acceptance.get(item)))
    }

    /// Whether a drop at `zone` of `slot` is accepted.
    fn allows(&self, slot: &Slot, zone: Zone) -> bool {
        let Some(table) = self.table(slot) else {
            // A header the table lacks (one machine draws none) takes the drop.
            return self.acceptance.is_empty() || slot.kind == Kind::Section;
        };
        match zone {
            Zone::Before => table.before,
            Zone::Into => table.into,
            Zone::After => table.after,
        }
    }

    /// A drop before (upper half of the block) or after (lower half) the whole group `group`, if accepted
    /// there, else around the group that holds it (a subgroup's block sits inside its parent's).
    fn around(&self, group: &str, y: f64) -> Option<Hit> {
        let mut current = Some(group);
        let mut seen: HashSet<&str> = HashSet::new();
        while let Some(id) = current {
            let index = *self.group_headers.get(id)?;
            let header = self.slots.get(index)?;
            let block = self.group_blocks.get(id)?;
            if !seen.insert(id) {
                return None;
            }
            let zone = if y < (block.0 + block.1) / 2.0 { Zone::Before } else { Zone::After };
            if self.allows(header, zone) {
                return Some(Hit {
                    slot: index,
                    zone,
                    target: Some(target(header, zone)),
                    refusal: None,
                });
            }
            current = header.parent.as_deref();
        }
        None
    }

    /// The line whose y range holds `y` (binary search), else the nearest.
    fn line_at(&self, y: f64) -> Option<&Vec<usize>> {
        let starts_above = self.lines.partition_point(|line| {
            line.first()
                .and_then(|first| self.slots.get(*first))
                .map_or(0.0, |slot| slot.frame.min_y())
                <= y
        });
        self.lines.get(starts_above.saturating_sub(1))
    }

    /// The tile under `x` on a flowed line (binary search), else the line's only slot.
    fn slot_in(&self, line: &[usize], x: f64) -> Option<usize> {
        let starts_left = line.partition_point(|index| {
            self.slots.get(*index).is_some_and(|slot| slot.frame.min_x() <= x)
        });
        line.get(starts_left.saturating_sub(1)).copied()
    }

    /// The base y a dragged list card's drop is hit-tested at, from the card's `top` and `bottom` (display
    /// coordinates, the gap open at `gap_y`); none keeps `current`.
    ///
    /// The midpoint rule (Lawrence 2026-10-20): moving up, the card's top decides; moving down, its bottom
    /// decides. A drag that turns back (`reversing`) must pass the middle by [`hysteresis`] of the row it
    /// crosses before the drop changes, so a pointer held at the threshold never flips the rows.
    pub fn edge_y(&self, edge: &Edge) -> Option<f64> {
        let Edge { top, bottom, x, moving_up, gap_y, gap_height, ref current, reversing } = *edge;
        let y = base_y(if moving_up { top } else { bottom }, gap_y, gap_height);
        if !reversing {
            return Some(y);
        }
        let Some(current) = current.as_ref() else { return Some(y) };
        let Some(candidate) = self.hit(x, y) else { return Some(y) };
        if candidate.target.as_ref() == Some(current) {
            return Some(y);
        }
        let height = self.slots.get(candidate.slot).map_or(0.0, |slot| slot.frame.height());
        let margin = hysteresis(height);
        let probe = if moving_up { y + margin } else { y - margin };
        (self.hit(x, probe).and_then(|hit| hit.target) == candidate.target).then_some(y)
    }
}

/// Where in `slot` the point `(x, y)` is.
pub fn zone(slot: &Slot, x: f64, y: f64) -> Zone {
    let frame = &slot.frame;
    match slot.kind {
        Kind::Section | Kind::EmptyGroup => Zone::Into,
        Kind::Tile => {
            if x < frame.mid_x() {
                Zone::Before
            } else {
                Zone::After
            }
        }
        Kind::Group => {
            let height = frame.height();
            let fraction = if height > 0.0 { (y - frame.min_y()) / height } else { 0.5 };
            if (INTO_BAND.0..=INTO_BAND.1).contains(&fraction) {
                Zone::Into
            } else if fraction < INTO_BAND.0 {
                Zone::Before
            } else {
                Zone::After
            }
        }
        Kind::Row => {
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
    let section = slot.section.clone();
    let Some(item) = slot.item.clone().filter(|_| slot.kind != Kind::Section) else {
        return Target { section, index: Some(0), ..Target::default() };
    };
    match zone {
        Zone::Before => {
            Target { section, parent: slot.parent.clone(), before: Some(item), ..Target::default() }
        }
        Zone::After => {
            Target { section, parent: slot.parent.clone(), after: Some(item), ..Target::default() }
        }
        Zone::Into => Target { section, parent: Some(item), ..Target::default() },
    }
}

/// The margin past a row's middle that turns a row drag back, for a row `height` tall.
pub fn hysteresis(height: f64) -> f64 {
    MAX_HYSTERESIS.min(0f64.max(height) * HYSTERESIS_FRACTION)
}

/// The display y of `y` in a layout drawn without the open gap (`gap_y`, `gap_height`): rows below the gap
/// were pushed down by it. A y inside the gap reads as the gap's top.
pub fn base_y(y: f64, gap_y: Option<f64>, gap_height: f64) -> f64 {
    match gap_y {
        Some(gap_y) if y >= gap_y => gap_y.max(y - gap_height),
        _ => y,
    }
}

#[cfg(test)]
#[path = "sidebar_drop_geometry_tests.rs"]
mod tests;
