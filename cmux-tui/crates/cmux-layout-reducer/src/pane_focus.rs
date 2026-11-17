//! The rule of the focus keys: the pane that gets the focus when a key moves it left, right, up or down.
//!
//! The caller gives one row for each pane of the screen ([`FocusPane`]): its frame as the screen shows it, its
//! column, its place in the focus history, its place among the floating panes, and an order that is the last
//! tie-break. [`neighbor`] reads only these rows: it keeps no state and knows no pane id.
//!
//! **The tiled rule.** A candidate lies wholly past the edge of the source that the key points to
//! ([`EDGE_TOLERANCE`] allows a gap or an overlap of that many points). The adjacent candidates are the ones that
//! overlap the source on the other axis at the smallest distance. Among them the most recently focused one gets
//! the focus; with no history the one with the largest overlap, then the nearest centre, then the top-left one.
//! When no candidate overlaps the source: the nearest edge, then the nearest centre, then the top-left one. A key
//! to the left or to the right that goes into another column gives that column's most recently focused pane,
//! wherever it stands in the column.

use std::cmp::Ordering;

/// How far apart 2 edges can be and still meet, in the unit of the frames.
pub const EDGE_TOLERANCE: f64 = 1.5;

/// The frame of a pane: its top-left corner and its size.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct FocusFrame {
    pub x: f64,
    pub y: f64,
    pub w: f64,
    pub h: f64,
}

impl FocusFrame {
    /// Whether each value is a finite number and the size is not negative.
    pub fn is_valid(self) -> bool {
        [self.x, self.y, self.w, self.h].iter().all(|value| value.is_finite())
            && self.w >= 0.0
            && self.h >= 0.0
    }

    fn max_x(self) -> f64 {
        self.x + self.w
    }

    fn max_y(self) -> f64 {
        self.y + self.h
    }

    fn mid_x(self) -> f64 {
        self.x + self.w / 2.0
    }

    fn mid_y(self) -> f64 {
        self.y + self.h / 2.0
    }
}

/// One pane of a screen, as the focus keys read it.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct FocusPane {
    /// The frame the screen shows the pane at. A pane with no frame is never a source and never a candidate; it
    /// can be the pane that its column remembers.
    pub frame: Option<FocusFrame>,
    /// The column of the pane in a screen of columns.
    pub column: Option<u32>,
    /// The place of the pane in the focus history: 0 is the pane that had the focus last.
    pub recency: Option<u32>,
    /// The place of a floating pane among the floating panes, back to front. `None` for a tiled pane.
    pub floating: Option<u32>,
    /// The last tie-break between 2 panes that are equal in each other way: the smaller one first.
    pub order: u32,
}

/// The direction of a focus key.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FocusDirection {
    Left,
    Right,
    Up,
    Down,
}

impl FocusDirection {
    /// The direction of a wire code: 0 left, 1 right, 2 up, 3 down.
    pub fn from_code(code: u8) -> Option<FocusDirection> {
        match code {
            0 => Some(FocusDirection::Left),
            1 => Some(FocusDirection::Right),
            2 => Some(FocusDirection::Up),
            3 => Some(FocusDirection::Down),
            _ => None,
        }
    }

    /// The direction of the key that goes back.
    pub fn opposite(self) -> FocusDirection {
        match self {
            FocusDirection::Left => FocusDirection::Right,
            FocusDirection::Right => FocusDirection::Left,
            FocusDirection::Up => FocusDirection::Down,
            FocusDirection::Down => FocusDirection::Up,
        }
    }

    /// Whether the key moves along the x axis.
    pub fn is_horizontal(self) -> bool {
        matches!(self, FocusDirection::Left | FocusDirection::Right)
    }
}

/// Whether [`neighbor`] can read `panes`: each frame is valid, no 2 panes have the same `order`, and no 2 panes
/// have the same place in the focus history or among the floating panes.
pub fn is_valid(panes: &[FocusPane]) -> bool {
    fn each_once(mut values: Vec<u32>) -> bool {
        values.sort_unstable();
        values.windows(2).all(|pair| pair[0] != pair[1])
    }
    panes.iter().all(|pane| pane.frame.is_none_or(FocusFrame::is_valid))
        && each_once(panes.iter().map(|pane| pane.order).collect())
        && each_once(panes.iter().filter_map(|pane| pane.recency).collect())
        && each_once(panes.iter().filter_map(|pane| pane.floating).collect())
}

/// The index of the pane that `direction` gives from the pane at `source`, or `None`: no pane is on that side,
/// or the source has no row or no frame.
pub fn neighbor(panes: &[FocusPane], source: usize, direction: FocusDirection) -> Option<usize> {
    tiled_neighbor(panes, source, direction, &|index| frame_of(panes, index).is_some(), &|_| true)
}

fn frame_of(panes: &[FocusPane], index: usize) -> Option<FocusFrame> {
    panes.get(index).and_then(|pane| pane.frame)
}

/// 2 numbers in their order. Numbers that have no order (not a number) are equal.
fn in_order(first: f64, second: f64) -> Ordering {
    first.partial_cmp(&second).unwrap_or(Ordering::Equal)
}

/// 2 lists of numbers in their order: by the first place where they are different.
fn lists_in_order(first: &[f64], second: &[f64]) -> Ordering {
    first
        .iter()
        .zip(second)
        .map(|(first, second)| in_order(*first, *second))
        .find(|order| order.is_ne())
        .unwrap_or(Ordering::Equal)
}

/// A pane that lies wholly past the edge of the source.
struct Candidate {
    index: usize,
    frame: FocusFrame,
    order: u32,
    /// From the edge of the source to the facing edge of the pane.
    distance: f64,
    /// How much the pane and the source share on the axis that the key does not move on.
    overlap: f64,
    /// Between the 2 centres on that axis.
    center_offset: f64,
}

impl Candidate {
    fn past_edge(
        index: usize,
        pane: &FocusPane,
        frame: FocusFrame,
        source: FocusFrame,
        direction: FocusDirection,
    ) -> Option<Candidate> {
        let distance = match direction {
            FocusDirection::Left if frame.max_x() <= source.x + EDGE_TOLERANCE => {
                source.x - frame.max_x()
            }
            FocusDirection::Right if frame.x >= source.max_x() - EDGE_TOLERANCE => {
                frame.x - source.max_x()
            }
            FocusDirection::Up if frame.max_y() <= source.y + EDGE_TOLERANCE => {
                source.y - frame.max_y()
            }
            FocusDirection::Down if frame.y >= source.max_y() - EDGE_TOLERANCE => {
                frame.y - source.max_y()
            }
            _ => return None,
        };
        let (overlap, center_offset) = if direction.is_horizontal() {
            (
                frame.max_y().min(source.max_y()) - frame.y.max(source.y),
                (frame.mid_y() - source.mid_y()).abs(),
            )
        } else {
            (
                frame.max_x().min(source.max_x()) - frame.x.max(source.x),
                (frame.mid_x() - source.mid_x()).abs(),
            )
        };
        Some(Candidate { index, frame, order: pane.order, distance, overlap, center_offset })
    }

    /// The order of 2 adjacent panes with no history: the largest overlap, the nearest centre, then top-left.
    fn adjacent_order(&self, other: &Candidate) -> Ordering {
        lists_in_order(
            &[-self.overlap.round(), self.center_offset.round(), self.frame.y, self.frame.x],
            &[-other.overlap.round(), other.center_offset.round(), other.frame.y, other.frame.x],
        )
        .then(self.order.cmp(&other.order))
    }

    /// The order of 2 panes when no pane overlaps the source: the nearest edge, the nearest centre, then top-left.
    fn fallback_order(&self, other: &Candidate) -> Ordering {
        lists_in_order(
            &[self.distance.round(), self.center_offset, self.frame.y, self.frame.x],
            &[other.distance.round(), other.center_offset, other.frame.y, other.frame.x],
        )
        .then(self.order.cmp(&other.order))
    }
}

/// The pane of `members` that had the focus last.
fn most_recent(panes: &[FocusPane], members: impl Iterator<Item = usize>) -> Option<usize> {
    members
        .filter_map(|index| {
            let pane = panes.get(index)?;
            Some((pane.recency?, pane.order, index))
        })
        .min()
        .map(|(_, _, index)| index)
}

/// The tiled rule from `source` among the panes that `shows` names. A column remembers only the panes that
/// `in_column` names.
fn tiled_neighbor(
    panes: &[FocusPane],
    source: usize,
    direction: FocusDirection,
    shows: &dyn Fn(usize) -> bool,
    in_column: &dyn Fn(usize) -> bool,
) -> Option<usize> {
    let source_pane = panes.get(source)?;
    let source_frame = source_pane.frame.filter(|_| shows(source))?;
    let candidates = panes
        .iter()
        .enumerate()
        .filter(|(index, _)| *index != source && shows(*index))
        .filter_map(|(index, pane)| {
            Candidate::past_edge(index, pane, pane.frame?, source_frame, direction)
        })
        .collect::<Vec<_>>();
    let nearest = candidates
        .iter()
        .filter(|candidate| candidate.overlap > 0.0)
        .map(|candidate| candidate.distance)
        .min_by(|first, second| in_order(*first, *second));
    let chosen = match nearest {
        Some(nearest) => {
            let adjacent = candidates
                .iter()
                .filter(|candidate| {
                    candidate.overlap > 0.0 && candidate.distance <= nearest + EDGE_TOLERANCE
                })
                .collect::<Vec<_>>();
            most_recent(panes, adjacent.iter().map(|candidate| candidate.index)).or_else(|| {
                adjacent
                    .iter()
                    .min_by(|first, second| first.adjacent_order(second))
                    .map(|candidate| candidate.index)
            })
        }
        None => candidates
            .iter()
            .min_by(|first, second| first.fallback_order(second))
            .map(|candidate| candidate.index),
    }?;
    if direction.is_horizontal()
        && let Some(column) = panes.get(chosen).and_then(|pane| pane.column)
        && source_pane.column != Some(column)
    {
        let members = panes
            .iter()
            .enumerate()
            .filter(|(index, pane)| pane.column == Some(column) && in_column(*index))
            .map(|(index, _)| index);
        if let Some(remembered) = most_recent(panes, members) {
            return Some(remembered);
        }
    }
    Some(chosen)
}

#[cfg(test)]
#[path = "pane_focus_tests.rs"]
mod tests;
