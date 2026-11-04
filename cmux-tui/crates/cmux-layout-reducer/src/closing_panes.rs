//! The rules of a springing pane close (FRAME OWNER S3c and S3d), ported from the app's Swift `ClosingPanesRules`
//! (`Packages/macOS/CmuxNext/Sources/CmuxNextLayout/Views/ClosingPanes+Rules.swift`) one operation at a time.
//!
//! A pane a springing close took out of a screen stays shown with only its own ground until the motion lands. It has no
//! motion of its own: each frame its rect is a function of its neighbours' frames and of its row column's scroll. Each
//! side a neighbour closes over sits on the slowest neighbour's facing edge on that side; a side keeps the gap it had to
//! its neighbours where the resize handle in that gap stays in the new layout, and covers that gap where the handle goes;
//! a side with no neighbour, opposite one that rides neighbours, travels to where that side rests by the share of the
//! motion that covers the pane's place (its neighbour's travel, else its row column's scroll travel), so the pane rests
//! at zero size. [`ClosingPanes::begin`] finds the neighbours and gaps from the layout the close left;
//! [`ClosingPanes::settle`] takes the row scroll travel and names the panes nothing moves over (they go at once);
//! [`ClosingPanes::rects`] places every closing pane each frame; [`ClosingPanes::remove`] gives where a taken-back close
//! starts and its sides' velocities.
//!
//! Panes, scroll areas and row columns are numbers the caller hands out (0: none). Every comparison and arithmetic step
//! is the Swift one: `Swift.min(x, y)` is `if y < x { y } else { x }`, `Swift.max(x, y)` is `if y >= x { y } else { x }`,
//! `Sequence.min()`/`max()` keep the first of equal values, so NaN and ties give the same answer. The test
//! `tests/closing_panes_corpus.rs` replays the corpus the Swift rules recorded, bit for bit.

use std::collections::{BTreeMap, BTreeSet};

/// A rect's sides as CoreGraphics reads them (`CGRect.minX`, `maxX`, `minY`, `maxY`).
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct Edges {
    pub min_x: f64,
    pub max_x: f64,
    pub min_y: f64,
    pub max_y: f64,
}

/// A rect the rules made: `x`, `y`, `width >= 0`, `height >= 0`.
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct Placed {
    pub x: f64,
    pub y: f64,
    pub width: f64,
    pub height: f64,
}

impl Edges {
    /// The sides of a rect the rules made (`CGRect(x:y:width:height:)` with `width, height >= 0`).
    pub fn of(rect: Placed) -> Edges {
        Edges {
            min_x: rect.x,
            max_x: rect.x + rect.width,
            min_y: rect.y,
            max_y: rect.y + rect.height,
        }
    }
}

/// One pane of the layout a close left. `area`, `row_column`: 0 for none.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct PaneFact {
    pub id: u64,
    pub edges: Edges,
    pub scrolls: bool,
    pub area: u64,
    pub row_column: u64,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum HandleKind {
    Split,
    ColumnEdge,
    RowEdge,
}

/// One resize handle of the layout a close left.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct HandleFact {
    pub kind: HandleKind,
    /// Its axis is horizontal (side by side; a row edge's is vertical).
    pub horizontal: bool,
    pub hit: Edges,
    pub mid_x: f64,
    pub mid_y: f64,
    /// The new layout has it.
    pub kept: bool,
    /// A split of the fixed (unscrolled) part.
    pub fixed_split: bool,
    /// A split's scroll area; 0 for none.
    pub area: u64,
    /// A column edge of a dock.
    pub docked: bool,
    /// A row edge's column.
    pub column: u64,
}

/// A live pane's frame this frame.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct FrameFact {
    pub id: u64,
    pub now: Edges,
    pub target: Edges,
    /// Its spring moves (not at its target, or a velocity is not 0).
    pub moving: bool,
    pub vx: f64,
    pub vy: f64,
    pub vw: f64,
    pub vh: f64,
}

/// Where a row column's scroll is and where it rests.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct RowTravel {
    pub column: u64,
    pub now: f64,
    pub target: f64,
}

/// Where a taken-back close starts, with its sides' velocities.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Taken {
    pub rect: Placed,
    pub vx: f64,
    pub vw: f64,
    pub vy: f64,
    pub vh: f64,
}

/// One side of a closing pane.
#[derive(Clone, Debug, PartialEq)]
pub struct Side {
    pub neighbours: Vec<u64>,
    pub gap: f64,
    pub fixed: f64,
    /// Where it stood in the first frame it was placed, or when its travel last started again.
    pub start: Option<f64>,
    /// A free side's travel end as of its start.
    pub end: Option<f64>,
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Travel {
    pub start: f64,
    pub target: f64,
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Shown {
    pub min_x: f64,
    pub max_x: f64,
}

/// One closing pane.
#[derive(Clone, Debug, PartialEq)]
pub struct Entry {
    pub min_x: Side,
    pub max_x: Side,
    pub min_y: Side,
    pub max_y: Side,
    pub scrolls: bool,
    pub row_column: u64,
    pub carried_shown: Option<Shown>,
    pub row_travel: Option<Travel>,
}

/// The closing panes of one screen.
#[derive(Clone, Debug, Default)]
pub struct ClosingPanes {
    entries: BTreeMap<u64, Entry>,
    /// The order the panes closed in.
    order: Vec<u64>,
    /// The panes this change began closing (they wait for the change's cameras).
    awaiting: BTreeSet<u64>,
    /// Reused per frame by [`ClosingPanes::rects`].
    shown: Vec<(u64, Placed)>,
    rests: Vec<(u64, Placed)>,
    placed: Vec<(u64, Placed)>,
    values: Vec<f64>,
}

/// `Swift.min(x, y)`.
pub fn swift_min(x: f64, y: f64) -> f64 {
    if y < x { y } else { x }
}

/// `Swift.max(x, y)`.
pub fn swift_max(x: f64, y: f64) -> f64 {
    if y >= x { y } else { x }
}

/// `Sequence.min()`.
pub fn least(values: &[f64]) -> Option<f64> {
    let (first, rest) = values.split_first()?;
    let mut result = *first;
    for &value in rest {
        if value < result {
            result = value;
        }
    }
    Some(result)
}

/// `Sequence.max()`.
pub fn most(values: &[f64]) -> Option<f64> {
    let (first, rest) = values.split_first()?;
    let mut result = *first;
    for &value in rest {
        if result < value {
            result = value;
        }
    }
    Some(result)
}

fn frame(id: u64, frames: &[FrameFact]) -> Option<&FrameFact> {
    frames.iter().find(|f| f.id == id)
}

fn row(column: u64, rows: &[RowTravel]) -> Option<RowTravel> {
    rows.iter().find(|r| r.column == column).copied()
}

fn lookup(id: u64, list: &[(u64, Placed)]) -> Option<Placed> {
    list.iter().find(|(pane, _)| *pane == id).map(|(_, rect)| *rect)
}

fn move_side(side: &mut Side, value: f64) {
    side.start = side.start.map(|start| start + value - side.fixed);
    side.end = side.end.map(|end| end + value - side.fixed);
    side.fixed = value;
}

/// A side with no neighbour, opposite one that rides neighbours: it travels from where it stood to where the rider
/// rests, by the share of the motion that covers the pane's place.
fn collapse(
    free: &mut Side,
    rider: &mut Side,
    rest: Option<f64>,
    travel: &mut Option<Travel>,
    scroll: Option<RowTravel>,
) {
    if !free.neighbours.is_empty() || rider.neighbours.is_empty() {
        return;
    }
    let end = rest.unwrap_or(rider.fixed);
    let rescrolled = match (*travel, scroll) {
        (Some(travel), Some(scroll)) => (scroll.target - travel.target).abs() >= 0.5,
        _ => false,
    };
    if rescrolled || free.end.map(|old| (old - end).abs() >= 0.5) == Some(true) {
        free.start = Some(free.fixed);
        rider.start = Some(rider.fixed);
        if let Some(scroll) = scroll
            && travel.is_some()
        {
            *travel = Some(Travel { start: scroll.now, target: scroll.target });
        }
    }
    free.end = Some(end);
    let Some(free_start) = free.start else { return };
    let mut done = None;
    match (rest, rider.start) {
        (Some(rest), Some(rider_start)) if (rest - rider_start).abs() >= 0.5 => {
            done = Some(swift_min(
                1.0,
                swift_max(0.0, (rider.fixed - rider_start) / (rest - rider_start)),
            ));
        }
        _ => {
            if let (Some(travel), Some(scroll)) = (*travel, scroll) {
                let length = travel.target - travel.start;
                done = Some(if length.abs() < 0.5 {
                    1.0
                } else {
                    swift_min(1.0, swift_max(0.0, (scroll.now - travel.start) / length))
                });
            }
        }
    }
    let Some(done) = done else { return };
    free.fixed = free_start + (end - free_start) * done;
}

/// Where `side` rests: where its neighbours rest, else, free opposite a rider, where the rider rests, else where it is.
fn resting(side: &Side, own: Option<f64>, opposite: &Side, other: Option<f64>) -> f64 {
    own.unwrap_or_else(|| {
        if side.neighbours.is_empty() && !opposite.neighbours.is_empty() {
            other.unwrap_or(opposite.fixed)
        } else {
            side.fixed
        }
    })
}

fn neighbours(entry: &Entry) -> impl Iterator<Item = u64> + '_ {
    entry
        .min_x
        .neighbours
        .iter()
        .chain(&entry.max_x.neighbours)
        .chain(&entry.min_y.neighbours)
        .chain(&entry.max_y.neighbours)
        .copied()
}

#[derive(Clone, Copy)]
enum Edge {
    MinX,
    MaxX,
    MinY,
    MaxY,
}

impl Edge {
    fn of(self, edges: Edges) -> f64 {
        match self {
            Edge::MinX => edges.min_x,
            Edge::MaxX => edges.max_x,
            Edge::MinY => edges.min_y,
            Edge::MaxY => edges.max_y,
        }
    }
}

impl ClosingPanes {
    pub fn new() -> ClosingPanes {
        ClosingPanes::default()
    }

    pub fn is_empty(&self) -> bool {
        self.entries.is_empty()
    }

    pub fn has_awaiting(&self) -> bool {
        !self.awaiting.is_empty()
    }

    pub fn entries(&self) -> &BTreeMap<u64, Entry> {
        &self.entries
    }

    pub fn order(&self) -> &[u64] {
        &self.order
    }

    pub fn awaiting(&self) -> &BTreeSet<u64> {
        &self.awaiting
    }

    /// The whole state as one string hashed (FNV-1a, 64 bits): every entry by pane (each side's neighbours, gap,
    /// place, travel start and end, whether it scrolls, its row column, the carry and the row travel), the close order
    /// and the panes awaiting the cameras. The corpus tests compare it after each call (the Swift
    /// `ClosingPanesCorpusTests.state` builds the same string).
    pub fn state_hash(&self) -> u64 {
        fn hex(value: f64) -> String {
            format!("{:x}", value.to_bits())
        }
        fn side(side: &Side) -> String {
            let neighbours: Vec<String> = side.neighbours.iter().map(u64::to_string).collect();
            [
                neighbours.join(","),
                hex(side.gap),
                hex(side.fixed),
                side.start.map_or_else(|| "-".to_owned(), hex),
                side.end.map_or_else(|| "-".to_owned(), hex),
            ]
            .join(";")
        }
        let mut text = String::new();
        for (pane, entry) in &self.entries {
            let carried = entry
                .carried_shown
                .map_or_else(|| "-".to_owned(), |c| format!("{},{}", hex(c.min_x), hex(c.max_x)));
            let travel = entry
                .row_travel
                .map_or_else(|| "-".to_owned(), |t| format!("{},{}", hex(t.start), hex(t.target)));
            let fields = [
                pane.to_string(),
                side(&entry.min_x),
                side(&entry.max_x),
                side(&entry.min_y),
                side(&entry.max_y),
                if entry.scrolls { "1" } else { "0" }.to_owned(),
                entry.row_column.to_string(),
                carried,
                travel,
            ];
            text += &fields.join("|");
            text.push('\n');
        }
        let order: Vec<String> = self.order.iter().map(u64::to_string).collect();
        let awaiting: Vec<String> = self.awaiting.iter().map(u64::to_string).collect();
        text += &format!("order:{}\nawait:{}\n", order.join(","), awaiting.join(","));
        let mut hash: u64 = 0xCBF2_9CE4_8422_2325;
        for byte in text.bytes() {
            hash ^= u64::from(byte);
            hash = hash.wrapping_mul(0x0000_0100_0000_01B3);
        }
        hash
    }

    /// Starts `pane` closing: `shown` is where it shows in the new layout's coordinates, `panes` the layout it left (the
    /// order its sides list their neighbours in), `handles` that layout's handles. Returns whether the pane was in that
    /// layout.
    pub fn begin(
        &mut self,
        pane: u64,
        shown: Edges,
        panes: &[PaneFact],
        handles: &[HandleFact],
        max_gap: f64,
        view_shift: Option<f64>,
    ) -> bool {
        let Some(own) = panes.iter().find(|p| p.id == pane) else { return false };
        let rest = own.edges;
        let (scrolls, area, row_column) = (own.scrolls, own.area, own.row_column);
        let (mut lead, mut trail, mut top, mut bottom) =
            (Vec::new(), Vec::new(), Vec::new(), Vec::new());
        for other in panes.iter().filter(|o| o.id != pane && o.scrolls == scrolls) {
            let was = other.edges;
            if swift_min(was.max_y, rest.max_y) - swift_max(was.min_y, rest.min_y) > 1.0
                && other.area == area
            {
                let gap_before = rest.min_x - was.max_x;
                let gap_after = was.min_x - rest.max_x;
                if gap_before >= -0.5 && gap_before <= max_gap {
                    lead.push((other.id, swift_max(0.0, gap_before)));
                }
                if gap_after >= -0.5 && gap_after <= max_gap {
                    trail.push((other.id, swift_max(0.0, gap_after)));
                }
            }
            if swift_min(was.max_x, rest.max_x) - swift_max(was.min_x, rest.min_x) > 1.0
                && other.row_column == row_column
            {
                let gap_above = rest.min_y - was.max_y;
                let gap_below = was.min_y - rest.max_y;
                if gap_above >= -0.5 && gap_above <= max_gap {
                    top.push((other.id, swift_max(0.0, gap_above)));
                }
                if gap_below >= -0.5 && gap_below <= max_gap {
                    bottom.push((other.id, swift_max(0.0, gap_below)));
                }
            }
        }
        let handle_stays = |lo: f64, hi: f64, horizontal: bool| -> Option<bool> {
            let mut stays = None;
            let across =
                if horizontal { (rest.min_y, rest.max_y) } else { (rest.min_x, rest.max_x) };
            for handle in handles {
                let eligible = match handle.kind {
                    HandleKind::Split => {
                        handle.fixed_split != scrolls
                            && (if handle.area != 0 { handle.area } else { area }) == area
                    }
                    HandleKind::ColumnEdge => handle.docked != scrolls,
                    HandleKind::RowEdge => handle.column == row_column,
                };
                if !eligible {
                    continue;
                }
                let along = if handle.horizontal { handle.mid_x } else { handle.mid_y };
                let cross = if handle.horizontal {
                    (handle.hit.min_y, handle.hit.max_y)
                } else {
                    (handle.hit.min_x, handle.hit.max_x)
                };
                if !(handle.horizontal == horizontal
                    && along >= lo - 0.5
                    && along <= hi + 0.5
                    && swift_min(cross.1, across.1) - swift_max(cross.0, across.0) > 1.0)
                {
                    continue;
                }
                stays = Some(stays == Some(true) || handle.kept);
            }
            stays
        };
        let widest = |found: &[(u64, f64)]| -> f64 {
            let gaps: Vec<f64> = found.iter().map(|f| f.1).collect();
            most(&gaps).unwrap_or(0.0)
        };
        let keeps_min_x = !lead.is_empty()
            && handle_stays(rest.min_x - widest(&lead), rest.min_x, true)
                .unwrap_or(!trail.is_empty());
        let keeps_max_x = !trail.is_empty()
            && handle_stays(rest.max_x, rest.max_x + widest(&trail), true).unwrap_or(false);
        let keeps_min_y = !top.is_empty()
            && handle_stays(rest.min_y - widest(&top), rest.min_y, false)
                .unwrap_or(!bottom.is_empty());
        let keeps_max_y = !bottom.is_empty()
            && handle_stays(rest.max_y, rest.max_y + widest(&bottom), false).unwrap_or(false);
        let side = |found: &[(u64, f64)], keeps_gap: bool, at: f64| -> Side {
            let gaps: Vec<f64> = found.iter().map(|f| f.1).collect();
            Side {
                neighbours: found.iter().map(|f| f.0).collect(),
                gap: if keeps_gap { least(&gaps).unwrap_or(0.0) } else { 0.0 },
                fixed: at,
                start: None,
                end: None,
            }
        };
        let carried_shown = view_shift.map(|shift| {
            if scrolls {
                Shown { min_x: shown.min_x + shift, max_x: shown.max_x + shift }
            } else {
                Shown { min_x: shown.min_x, max_x: shown.max_x }
            }
        });
        self.entries.insert(
            pane,
            Entry {
                min_x: side(&lead, keeps_min_x, shown.min_x),
                max_x: side(&trail, keeps_max_x, shown.max_x),
                min_y: side(&top, keeps_min_y, shown.min_y),
                max_y: side(&bottom, keeps_max_y, shown.max_y),
                scrolls,
                row_column,
                carried_shown,
                row_travel: None,
            },
        );
        self.order.retain(|&p| p != pane);
        self.order.push(pane);
        self.awaiting.insert(pane);
        true
    }

    /// The change's cameras are set: each pane it began closing in a row column takes that scroll's travel, when one y
    /// side has neighbours and the other none. Returns the panes nothing moves over (ascending).
    pub fn settle(&mut self, frames: &[FrameFact], rows: &[RowTravel]) -> Vec<u64> {
        let awaiting = std::mem::take(&mut self.awaiting);
        for pane in &awaiting {
            let Some(entry) = self.entries.get_mut(pane) else { continue };
            if entry.row_column == 0
                || entry.min_y.neighbours.is_empty() == entry.max_y.neighbours.is_empty()
            {
                continue;
            }
            let Some(travel) = row(entry.row_column, rows) else { continue };
            if (travel.target - travel.now).abs() < 0.5 {
                continue;
            }
            entry.row_travel = Some(Travel { start: travel.now, target: travel.target });
        }
        self.still(&awaiting, frames)
    }

    /// Where every closing pane shows this frame, in the order they were placed (the last to close first). The answer
    /// borrows the handle's buffer: it stays until the next call. No allocation once the buffers have grown.
    pub fn rects(&mut self, frames: &[FrameFact], rows: &[RowTravel]) -> &[(u64, Placed)] {
        self.shown.clear();
        self.rests.clear();
        self.placed.clear();
        for index in (0..self.order.len()).rev() {
            let pane = self.order[index];
            let (shown, rests, values) = (&self.shown, &self.rests, &mut self.values);
            let Some(entry) = self.entries.get_mut(&pane) else { continue };
            let facing = |neighbour: u64, edge: Edge| -> Option<f64> {
                frame(neighbour, frames)
                    .map(|f| edge.of(f.now))
                    .or_else(|| lookup(neighbour, shown).map(|r| edge.of(Edges::of(r))))
            };
            let resting_edge = |neighbour: u64, edge: Edge| -> Option<f64> {
                frame(neighbour, frames)
                    .map(|f| edge.of(f.target))
                    .or_else(|| lookup(neighbour, rests).map(|r| edge.of(Edges::of(r))))
            };
            let mut place = |side: &mut Side,
                             slowest: fn(&[f64]) -> Option<f64>,
                             edge: Edge,
                             sign: f64|
             -> Option<f64> {
                values.clear();
                values.extend(side.neighbours.iter().filter_map(|&n| facing(n, edge)));
                if let Some(value) = slowest(values.as_slice()) {
                    side.fixed = value + sign * side.gap;
                }
                if side.start.is_none() {
                    side.start = Some(side.fixed);
                }
                values.clear();
                values.extend(side.neighbours.iter().filter_map(|&n| resting_edge(n, edge)));
                slowest(values.as_slice()).map(|v| v + sign * side.gap)
            };
            let rest_min_x = place(&mut entry.min_x, least, Edge::MaxX, 1.0);
            let rest_max_x = place(&mut entry.max_x, most, Edge::MinX, -1.0);
            let rest_min_y = place(&mut entry.min_y, least, Edge::MaxY, 1.0);
            let rest_max_y = place(&mut entry.max_y, most, Edge::MinY, -1.0);
            let scroll = if entry.row_column != 0 { row(entry.row_column, rows) } else { None };
            let mut none = None;
            let Entry { min_x, max_x, min_y, max_y, row_travel, .. } = &mut *entry;
            collapse(max_x, min_x, rest_min_x, &mut none, None);
            collapse(min_x, max_x, rest_max_x, &mut none, None);
            collapse(max_y, min_y, rest_min_y, row_travel, scroll);
            collapse(min_y, max_y, rest_max_y, row_travel, scroll);
            let rect = Placed {
                x: entry.min_x.fixed,
                y: entry.min_y.fixed,
                width: swift_max(0.0, entry.max_x.fixed - entry.min_x.fixed),
                height: swift_max(0.0, entry.max_y.fixed - entry.min_y.fixed),
            };
            let x0 = resting(&entry.min_x, rest_min_x, &entry.max_x, rest_max_x);
            let x1 = resting(&entry.max_x, rest_max_x, &entry.min_x, rest_min_x);
            let y0 = resting(&entry.min_y, rest_min_y, &entry.max_y, rest_max_y);
            let y1 = resting(&entry.max_y, rest_max_y, &entry.min_y, rest_min_y);
            let rest = Placed {
                x: x0,
                y: y0,
                width: swift_max(0.0, x1 - x0),
                height: swift_max(0.0, y1 - y0),
            };
            self.shown.push((pane, rect));
            self.placed.push((pane, rect));
            self.rests.push((pane, rest));
        }
        &self.placed
    }

    /// A new layout carried the strip by `drift`; `view_shift` is the new layout's view shift (none: nothing carried).
    pub fn carry(&mut self, drift: f64, view_shift: Option<f64>) {
        for entry in self.entries.values_mut() {
            if entry.scrolls && drift != 0.0 {
                let (min_x, max_x) = (entry.min_x.fixed + drift, entry.max_x.fixed + drift);
                move_side(&mut entry.min_x, min_x);
                move_side(&mut entry.max_x, max_x);
            }
            entry.carried_shown = view_shift.map(|shift| {
                if entry.scrolls {
                    Shown { min_x: entry.min_x.fixed + shift, max_x: entry.max_x.fixed + shift }
                } else {
                    Shown { min_x: entry.min_x.fixed, max_x: entry.max_x.fixed }
                }
            });
        }
    }

    /// The camera took its place for the new layout: each closing pane's x sides show where they showed before.
    pub fn settle_carried(&mut self, strip_shift: f64) {
        for entry in self.entries.values_mut() {
            let Some(shown) = entry.carried_shown else { continue };
            let offset = if entry.scrolls { strip_shift } else { 0.0 };
            move_side(&mut entry.min_x, shown.min_x - offset);
            move_side(&mut entry.max_x, shown.max_x - offset);
            entry.carried_shown = None;
        }
    }

    /// A row column stopped scrolling: its closing panes keep where they show.
    pub fn shift_y(&mut self, column: u64, delta: f64) {
        for entry in self.entries.values_mut().filter(|e| e.row_column == column) {
            let (min_y, max_y) = (entry.min_y.fixed + delta, entry.max_y.fixed + delta);
            move_side(&mut entry.min_y, min_y);
            move_side(&mut entry.max_y, max_y);
        }
    }

    /// Takes `pane` out (its close was taken back): where it shows now, with its sides' velocities.
    pub fn remove(&mut self, pane: u64, frames: &[FrameFact]) -> Option<Taken> {
        let entry = self.entries.remove(&pane)?;
        self.order.retain(|&p| p != pane);
        self.awaiting.remove(&pane);
        let rect = Placed {
            x: entry.min_x.fixed,
            y: entry.min_y.fixed,
            width: swift_max(0.0, entry.max_x.fixed - entry.min_x.fixed),
            height: swift_max(0.0, entry.max_y.fixed - entry.min_y.fixed),
        };
        let edges = Edges::of(rect);
        let speed = |side: &Side, at: f64, edge: Edge, velocity: fn(&FrameFact) -> f64| -> f64 {
            let mut best: Option<&FrameFact> = None;
            for live in side.neighbours.iter().filter_map(|&n| frame(n, frames)) {
                // `Sequence.min(by:)`: a later frame replaces the best only when it is strictly closer.
                let closer = best
                    .is_none_or(|b| (edge.of(live.now) - at).abs() < (edge.of(b.now) - at).abs());
                if closer {
                    best = Some(live);
                }
            }
            best.map_or(0.0, velocity)
        };
        let v_min_x =
            speed(&entry.min_x, edges.min_x - entry.min_x.gap, Edge::MaxX, |f| f.vx + f.vw);
        let v_max_x = speed(&entry.max_x, edges.max_x + entry.max_x.gap, Edge::MinX, |f| f.vx);
        let v_min_y =
            speed(&entry.min_y, edges.min_y - entry.min_y.gap, Edge::MaxY, |f| f.vy + f.vh);
        let v_max_y = speed(&entry.max_y, edges.max_y + entry.max_y.gap, Edge::MinY, |f| f.vy);
        Some(Taken { rect, vx: v_min_x, vw: v_max_x - v_min_x, vy: v_min_y, vh: v_max_y - v_min_y })
    }

    /// Drops a pane whose host went.
    pub fn drop_pane(&mut self, pane: u64) {
        self.entries.remove(&pane);
        self.order.retain(|&p| p != pane);
        self.awaiting.remove(&pane);
    }

    /// The panes of `closing` nothing moves over (ascending).
    fn still(&self, closing: &BTreeSet<u64>, frames: &[FrameFact]) -> Vec<u64> {
        let mut covered: BTreeSet<u64> = self
            .entries
            .iter()
            .filter(|(pane, entry)| {
                !closing.contains(pane)
                    || entry.row_travel.is_some()
                    || neighbours(entry).any(|n| frame(n, frames).is_some_and(|f| f.moving))
            })
            .map(|(pane, _)| *pane)
            .collect();
        let mut grew = true;
        while grew {
            grew = false;
            for (pane, entry) in &self.entries {
                if !covered.contains(pane) && neighbours(entry).any(|n| covered.contains(&n)) {
                    covered.insert(*pane);
                    grew = true;
                }
            }
        }
        closing.iter().copied().filter(|p| !covered.contains(p)).collect()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn e(min_x: f64, max_x: f64, min_y: f64, max_y: f64) -> Edges {
        Edges { min_x, max_x, min_y, max_y }
    }

    fn pane(id: u64, edges: Edges) -> PaneFact {
        PaneFact { id, edges, scrolls: true, area: 0, row_column: 0 }
    }

    fn live(id: u64, now: Edges, target: Edges) -> FrameFact {
        FrameFact { id, now, target, moving: now != target, vx: 0.0, vy: 0.0, vw: 0.0, vh: 0.0 }
    }

    /// p1 | p2 | p3 with 4 pt gaps: closing p2 with the divider x (p2 | p3) kept and the one before it gone.
    fn three() -> (ClosingPanes, [PaneFact; 3]) {
        let panes = [
            pane(1, e(0.0, 100.0, 0.0, 300.0)),
            pane(2, e(104.0, 200.0, 0.0, 300.0)),
            pane(3, e(204.0, 300.0, 0.0, 300.0)),
        ];
        let gone = HandleFact {
            kind: HandleKind::Split,
            horizontal: true,
            hit: e(98.0, 106.0, 0.0, 300.0),
            mid_x: 102.0,
            mid_y: 150.0,
            kept: false,
            fixed_split: false,
            area: 0,
            docked: false,
            column: 0,
        };
        let kept =
            HandleFact { hit: e(198.0, 206.0, 0.0, 300.0), mid_x: 202.0, kept: true, ..gone };
        let mut closing = ClosingPanes::new();
        assert!(closing.begin(2, panes[1].edges, &panes, &[gone, kept], 9.0, None));
        (closing, panes)
    }

    #[test]
    fn a_side_keeps_the_gap_of_a_kept_handle_and_covers_a_gone_one() {
        let (closing, _) = three();
        let entry = &closing.entries()[&2];
        assert_eq!((entry.min_x.neighbours.as_slice(), entry.min_x.gap), (&[1][..], 0.0));
        assert_eq!((entry.max_x.neighbours.as_slice(), entry.max_x.gap), (&[3][..], 4.0));
        assert!(entry.min_y.neighbours.is_empty() && entry.max_y.neighbours.is_empty());
    }

    #[test]
    fn a_pane_rides_its_neighbours_and_rests_at_zero_size() {
        let (mut closing, _) = three();
        let frames = [
            live(1, e(0.0, 150.0, 0.0, 300.0), e(0.0, 200.0, 0.0, 300.0)),
            live(3, e(204.0, 300.0, 0.0, 300.0), e(204.0, 300.0, 0.0, 300.0)),
        ];
        assert!(closing.settle(&frames, &[]).is_empty(), "p1 springs over it");
        let placed = closing.rects(&frames, &[]).to_vec();
        assert_eq!(placed, vec![(2, Placed { x: 150.0, y: 0.0, width: 50.0, height: 300.0 })]);
        let rest = [live(1, e(0.0, 200.0, 0.0, 300.0), e(0.0, 200.0, 0.0, 300.0)), frames[1]];
        assert_eq!(
            closing.rects(&rest, &[]),
            &[(2, Placed { x: 200.0, y: 0.0, width: 0.0, height: 300.0 })]
        );
    }

    #[test]
    fn a_pane_nothing_moves_over_goes_at_once() {
        let (mut closing, panes) = three();
        let frames =
            [live(1, panes[0].edges, panes[0].edges), live(3, panes[2].edges, panes[2].edges)];
        assert_eq!(closing.settle(&frames, &[]), vec![2]);
        assert!(!closing.has_awaiting());
    }

    #[test]
    fn a_taken_back_close_starts_with_its_neighbours_speed() {
        let (mut closing, _) = three();
        let mut moving = live(1, e(0.0, 150.0, 0.0, 300.0), e(0.0, 200.0, 0.0, 300.0));
        moving.vw = 30.0;
        let frames = [moving, live(3, e(204.0, 300.0, 0.0, 300.0), e(204.0, 300.0, 0.0, 300.0))];
        closing.rects(&frames, &[]);
        let taken = closing.remove(2, &frames).expect("closing");
        assert_eq!((taken.rect.x, taken.vx, taken.vw), (150.0, 30.0, -30.0));
        assert!(closing.is_empty() && closing.order().is_empty());
        assert_eq!(closing.remove(2, &frames), None);
    }

    #[test]
    fn swift_min_and_max_keep_swift_s_answer_on_a_tie_and_nan() {
        // On a tie Swift's min keeps its first argument and max its second.
        assert_eq!(swift_min(0.0, -0.0).to_bits(), 0.0f64.to_bits());
        assert_eq!(swift_min(-0.0, 0.0).to_bits(), (-0.0f64).to_bits());
        assert_eq!(swift_max(-0.0, 0.0).to_bits(), 0.0f64.to_bits());
        assert_eq!(swift_max(0.0, -0.0).to_bits(), (-0.0f64).to_bits());
        assert!(swift_min(f64::NAN, 1.0).is_nan());
        assert_eq!(swift_max(0.0, f64::NAN), 0.0);
        assert_eq!(least(&[2.0, f64::NAN, 1.0]), Some(1.0));
        assert_eq!(most(&[]), None);
    }
}
