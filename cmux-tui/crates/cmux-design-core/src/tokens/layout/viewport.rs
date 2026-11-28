//! `CloseFocus/ListViewport.swift`: the one-axis scroll rules of a list viewport (the sidebar's
//! workspace list; plans/cmux-next/close-focus.md, contract V1 to V6): clamp, full visibility,
//! the minimal reveal, the anchor that keeps what the user sees still, the settle after a change,
//! and a row's own move. [`ViewportRows`] is `ListViewportRows`, [`ListViewportChange`] the rule
//! read through it, [`ListViewport`] a plain list of items (Swift's `Indexed` reader).
//!
//! Swift's `max`/`min` (`y >= x ? y : x`, `y < x ? y : x`) are kept as written, NaN included.
//!
//! Ops (after `layout_`): `viewport_clamp`, `viewport_is_fully_visible`, `viewport_reveal`,
//! `viewport_anchor`, `viewport_anchored`, `viewport_settle`, `viewport_moved_by_itself`.

use crate::ops::{OpError, OpResult, parse, reply};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::collections::HashMap;
use std::hash::Hash;

/// `ListViewport.epsilon`: rounding slack for comparisons.
pub const EPSILON: f64 = 0.01;

/// Swift's `max(x, y)`.
fn smax(x: f64, y: f64) -> f64 {
    if y >= x { y } else { x }
}

/// Swift's `min(x, y)`.
fn smin(x: f64, y: f64) -> f64 {
    if y < x { y } else { x }
}

/// `ListViewport.Item`: one row's content-space extent.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Item<Id = String> {
    /// The row's id.
    pub id: Id,
    /// Its leading edge.
    pub start: f64,
    /// Its length.
    pub length: f64,
}

impl<Id> Item<Id> {
    /// `init(id:start:length:)`.
    pub fn new(id: Id, start: f64, length: f64) -> Self {
        Item { id, start, length }
    }

    /// `end`.
    pub fn end(&self) -> f64 {
        self.start + self.length
    }
}

/// A list's viewport and content lengths: the parts of `ListViewport` that read no item
/// (`clamp`, `isFullyVisible`, `reveal`).
#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Frame {
    /// The viewport's length.
    pub viewport: f64,
    /// The content's length.
    pub content: f64,
}

impl Frame {
    /// `maxOffset`.
    pub fn max_offset(&self) -> f64 {
        smax(0.0, self.content - self.viewport)
    }

    /// `clamp(_:)`: the offset in `0...maxOffset`.
    pub fn clamp(&self, offset: f64) -> f64 {
        smin(smax(offset, 0.0), self.max_offset())
    }

    /// `isFullyVisible(_:at:padding:)`: the item with `padding` on both sides (cut at the
    /// content's ends) lies inside the viewport, or the item covers it.
    pub fn is_fully_visible<Id>(&self, item: &Item<Id>, offset: f64, padding: f64) -> bool {
        let viewport = self.viewport;
        if item.length + padding * 2.0 >= viewport {
            return item.start <= offset + EPSILON && item.end() >= offset + viewport - EPSILON
                || (item.start >= offset - EPSILON && item.end() <= offset + viewport + EPSILON);
        }
        let lead = smax(0.0, item.start - padding);
        let trail = smin(self.content, item.end() + padding);
        lead >= offset - EPSILON && trail <= offset + viewport + EPSILON
    }

    /// `reveal(_:from:padding:)`: the least scroll that shows `item` fully. Clamped.
    pub fn reveal<Id>(&self, item: &Item<Id>, offset: f64, padding: f64) -> f64 {
        let current = self.clamp(offset);
        if self.is_fully_visible(item, current, padding) {
            return current;
        }
        if item.length + padding * 2.0 >= self.viewport {
            return self.clamp(item.start - smax(0.0, (self.viewport - item.length) / 2.0));
        }
        let to_leading = item.start - padding;
        let to_trailing = item.end() + padding - self.viewport;
        self.clamp(if (to_leading - current).abs() <= (to_trailing - current).abs() {
            to_leading
        } else {
            to_trailing
        })
    }
}

/// `ListViewportRows`: the rows of a list as the scroll rules read them.
pub trait ViewportRows {
    /// The row id.
    type Id: PartialEq + Clone;
    /// `rowCount`.
    fn row_count(&self) -> usize;
    /// `viewportRow(at:)`, in list order.
    fn viewport_row(&self, position: usize) -> Item<Self::Id>;
    /// `viewportPosition(of:)`: nil when the list does not hold `id`.
    fn viewport_position(&self, id: &Self::Id) -> Option<usize>;
    /// `viewportPositions(endingAfter:startingBefore:)`, in list order.
    fn viewport_positions(&self, lower: f64, upper: f64) -> Vec<usize>;
}

/// `ListViewport`: content-space extents by id, in list order, with the viewport and content.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ListViewport<Id = String> {
    /// The items in list order.
    #[serde(default = "Vec::new")]
    pub items: Vec<Item<Id>>,
    /// The viewport's length.
    pub viewport: f64,
    /// The content's length.
    pub content: f64,
}

impl<Id: Eq + Hash + Clone> ListViewport<Id> {
    /// `init(items:viewport:content:)`.
    pub fn new(items: Vec<Item<Id>>, viewport: f64, content: f64) -> Self {
        ListViewport { items, viewport, content }
    }

    /// The viewport and content.
    pub fn frame(&self) -> Frame {
        Frame { viewport: self.viewport, content: self.content }
    }

    /// `item(_:)`: the first item of `id`.
    pub fn item(&self, id: &Id) -> Option<&Item<Id>> {
        self.items.iter().find(|i| &i.id == id)
    }

    /// `maxOffset`.
    pub fn max_offset(&self) -> f64 {
        self.frame().max_offset()
    }

    /// `clamp(_:)`.
    pub fn clamp(&self, offset: f64) -> f64 {
        self.frame().clamp(offset)
    }

    /// `isFullyVisible(_:at:padding:)`.
    pub fn is_fully_visible(&self, item: &Item<Id>, offset: f64, padding: f64) -> bool {
        self.frame().is_fully_visible(item, offset, padding)
    }

    /// `reveal(_:from:padding:)`.
    pub fn reveal(&self, item: &Item<Id>, offset: f64, padding: f64) -> f64 {
        self.frame().reveal(item, offset, padding)
    }

    /// The change from `self` to `next`, each read through an index of its ids.
    pub fn change<'a>(
        &'a self,
        next: &'a ListViewport<Id>,
    ) -> ListViewportChange<Indexed<'a, Id>, Indexed<'a, Id>> {
        ListViewportChange::new(Indexed::new(self), self.frame(), Indexed::new(next), next.frame())
    }

    /// `anchor(at:next:)`: the item the user's eye rests on when the list changes to `next`.
    pub fn anchor(&self, offset: f64, next: &ListViewport<Id>) -> Option<Item<Id>> {
        self.change(next).anchor(offset)
    }

    /// `anchored(from:offset:)`: step 1 of `settle`, the offset that keeps the anchor in place.
    pub fn anchored(&self, old: &ListViewport<Id>, offset: f64) -> f64 {
        old.change(self).anchored(offset)
    }

    /// `settle(from:offset:focused:newFocus:padding:userMoved:extent:)`: the offset after the list
    /// changed from `old` (seen at `offset`) to `self`.
    #[allow(clippy::too_many_arguments)]
    pub fn settle(
        &self,
        old: &ListViewport<Id>,
        offset: f64,
        focused: Option<&Id>,
        new_focus: Option<&Id>,
        padding: f64,
        user_moved: bool,
        extent: Option<&Item<Id>>,
    ) -> f64 {
        old.change(self).settle(offset, None, focused, new_focus, padding, user_moved, extent)
    }

    /// `movedByItself(_:in:)`: among the items in both lists, `id` has a new neighbour on both sides.
    pub fn moved_by_itself(&self, id: &Id, next: &ListViewport<Id>) -> bool {
        self.change(next).moved_by_itself(id)
    }
}

/// `ListViewport.Indexed`: the items by position and by id (the first item of an id).
#[derive(Debug, Clone)]
pub struct Indexed<'a, Id> {
    items: &'a [Item<Id>],
    positions: HashMap<&'a Id, usize>,
}

impl<'a, Id: Eq + Hash> Indexed<'a, Id> {
    /// Indexes `list`.
    pub fn new(list: &'a ListViewport<Id>) -> Self {
        let mut positions = HashMap::with_capacity(list.items.len());
        for (index, item) in list.items.iter().enumerate() {
            positions.entry(&item.id).or_insert(index);
        }
        Indexed { items: &list.items, positions }
    }
}

impl<Id: Eq + Hash + Clone> ViewportRows for Indexed<'_, Id> {
    type Id = Id;
    fn row_count(&self) -> usize {
        self.items.len()
    }
    #[allow(
        clippy::indexing_slicing,
        reason = "Swift's viewportRow is preconditioned by the row count"
    )]
    fn viewport_row(&self, position: usize) -> Item<Id> {
        self.items[position].clone()
    }
    fn viewport_position(&self, id: &Id) -> Option<usize> {
        self.positions.get(id).copied()
    }
    // Any order of places: every item is read.
    fn viewport_positions(&self, lower: f64, upper: f64) -> Vec<usize> {
        self.items
            .iter()
            .enumerate()
            .filter_map(|(i, item)| (item.end() > lower && item.start < upper).then_some(i))
            .collect()
    }
}

/// `ListViewportChange`: the scroll rules for a list that changes from `old` to `new`.
#[derive(Debug, Clone)]
pub struct ListViewportChange<Old, New> {
    old: Old,
    new: New,
    old_frame: Frame,
    new_frame: Frame,
}

impl<Old, New> ListViewportChange<Old, New>
where
    Old: ViewportRows,
    New: ViewportRows<Id = Old::Id>,
{
    /// `init(from:content:viewport:to:content:viewport:)`.
    pub fn new(old: Old, old_frame: Frame, new: New, new_frame: Frame) -> Self {
        ListViewportChange { old, new, old_frame, new_frame }
    }

    /// `anchor(at:)`: the first partly visible item of `old` that `new` holds and that did not
    /// move by itself, else the first partly visible one that `new` holds.
    pub fn anchor(&self, offset: f64) -> Option<Item<Old::Id>> {
        let mut first_surviving: Option<Item<Old::Id>> = None;
        for position in self
            .old
            .viewport_positions(offset + EPSILON, offset + self.old_frame.viewport - EPSILON)
        {
            let item = self.old.viewport_row(position);
            let Some(now) = self.new.viewport_position(&item.id) else { continue };
            if first_surviving.is_none() {
                first_surviving = Some(item.clone());
            }
            if self.keeps_neighbour(position, now) {
                return Some(item);
            }
        }
        first_surviving
    }

    /// Whether the row at `was` in `old` and `now` in `new` keeps its surviving row before it or after it.
    fn keeps_neighbour(&self, was: usize, now: usize) -> bool {
        neighbour(was, -1, &self.old, &self.new) == neighbour(now, -1, &self.new, &self.old)
            || neighbour(was, 1, &self.old, &self.new) == neighbour(now, 1, &self.new, &self.old)
    }

    /// The row `id` of `new`.
    fn item(&self, id: &Old::Id) -> Option<Item<Old::Id>> {
        self.new.viewport_position(id).map(|p| self.new.viewport_row(p))
    }

    /// `anchored(offset:)`: step 1 of `settle`. Clamped.
    pub fn anchored(&self, offset: f64) -> f64 {
        let mut next = offset;
        if let Some(anchor) = self.anchor(offset)
            && let Some(moved) = self.item(&anchor.id)
        {
            next += moved.start - anchor.start;
        }
        self.new_frame.clamp(next)
    }

    /// `settle(offset:anchored:focused:newFocus:padding:userMoved:extent:)`: anchor, reveal
    /// `new_focus` when it must show, clamp.
    #[allow(clippy::too_many_arguments)]
    pub fn settle(
        &self,
        offset: f64,
        anchored: Option<f64>,
        focused: Option<&Old::Id>,
        new_focus: Option<&Old::Id>,
        padding: f64,
        user_moved: bool,
        extent: Option<&Item<Old::Id>>,
    ) -> f64 {
        let next = anchored.unwrap_or_else(|| self.anchored(offset));
        let Some(new_focus) = new_focus else { return next };
        let changed = Some(new_focus) != focused;
        let target =
            match (if changed { extent.cloned() } else { None }).or_else(|| self.item(new_focus)) {
                Some(target) => target,
                None => return next,
            };
        let was_visible = self
            .old
            .viewport_position(new_focus)
            .map(|p| self.old_frame.is_fully_visible(&self.old.viewport_row(p), offset, 0.0))
            .unwrap_or(false);
        if !(changed || user_moved || was_visible || self.moved_by_itself(new_focus)) {
            return next;
        }
        if self.new_frame.is_fully_visible(&target, next, 0.0) {
            return next;
        }
        self.new_frame.reveal(&target, next, padding)
    }

    /// `movedByItself(_:)`: among the items in both lists, `id` has a new neighbour on both sides.
    pub fn moved_by_itself(&self, id: &Old::Id) -> bool {
        let (Some(was), Some(now)) =
            (self.old.viewport_position(id), self.new.viewport_position(id))
        else {
            return false;
        };
        !self.keeps_neighbour(was, now)
    }
}

/// The first row before (`step` -1) or after (1) `position` in `rows` that `other` holds too.
fn neighbour<R, O>(position: usize, step: isize, rows: &R, other: &O) -> Option<R::Id>
where
    R: ViewportRows,
    O: ViewportRows<Id = R::Id>,
{
    let mut index = position as isize + step;
    while index >= 0 && (index as usize) < rows.row_count() {
        let id = rows.viewport_row(index as usize).id;
        if other.viewport_position(&id).is_some() {
            return Some(id);
        }
        index += step;
    }
    None
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct FrameRequest {
    viewport: f64,
    content: f64,
    offset: f64,
    #[serde(default)]
    item: Option<Item>,
    #[serde(default)]
    padding: f64,
}

impl FrameRequest {
    fn frame(&self) -> Frame {
        Frame { viewport: self.viewport, content: self.content }
    }

    fn item(&self) -> Result<&Item, OpError> {
        self.item.as_ref().ok_or_else(|| OpError::Invalid("missing field `item`".into()))
    }
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ChangeRequest {
    old: ListViewport,
    new: ListViewport,
    #[serde(default)]
    offset: f64,
    #[serde(default)]
    anchored: Option<f64>,
    #[serde(default)]
    focused: Option<String>,
    #[serde(default)]
    new_focus: Option<String>,
    #[serde(default)]
    padding: f64,
    #[serde(default)]
    user_moved: bool,
    #[serde(default)]
    extent: Option<Item>,
    #[serde(default)]
    id: Option<String>,
}

/// Runs the `viewport_*` ops (the name after `layout_`).
pub fn call(name: &str, request: &Value) -> OpResult {
    match name {
        "viewport_clamp" => {
            let r: FrameRequest = parse(request)?;
            let frame = r.frame();
            Ok(json!({ "offset": frame.clamp(r.offset), "maxOffset": frame.max_offset() }))
        }
        "viewport_is_fully_visible" => {
            let r: FrameRequest = parse(request)?;
            Ok(json!({ "visible": r.frame().is_fully_visible(r.item()?, r.offset, r.padding) }))
        }
        "viewport_reveal" => {
            let r: FrameRequest = parse(request)?;
            Ok(json!({ "offset": r.frame().reveal(r.item()?, r.offset, r.padding) }))
        }
        "viewport_anchor" => {
            let r: ChangeRequest = parse(request)?;
            reply(&r.old.anchor(r.offset, &r.new))
        }
        "viewport_anchored" => {
            let r: ChangeRequest = parse(request)?;
            Ok(json!({ "offset": r.new.anchored(&r.old, r.offset) }))
        }
        "viewport_settle" => {
            let r: ChangeRequest = parse(request)?;
            let offset = r.old.change(&r.new).settle(
                r.offset,
                r.anchored,
                r.focused.as_ref(),
                r.new_focus.as_ref(),
                r.padding,
                r.user_moved,
                r.extent.as_ref(),
            );
            Ok(json!({ "offset": offset }))
        }
        "viewport_moved_by_itself" => {
            let r: ChangeRequest = parse(request)?;
            let id = r.id.ok_or_else(|| OpError::Invalid("missing field `id`".into()))?;
            Ok(json!({ "moved": r.old.moved_by_itself(&id, &r.new) }))
        }
        _ => Err(OpError::Unknown),
    }
}
