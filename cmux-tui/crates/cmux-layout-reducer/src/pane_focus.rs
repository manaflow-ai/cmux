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
//!
//! **The rule with floating panes** (1 or more floating panes have a frame). The tiled rule stays the rule between
//! tiled panes, and a floating pane is a stop on the way. From a tiled pane the tiled rule gives the target; a
//! floating pane stands between when its centre is after the centre of the source and before the centre of the
//! target on the axis of the key, and it overlaps the source on the other axis: the nearest such pane gets the
//! focus. With no tiled target, the nearest floating pane after the source gets it. From a floating pane the same
//! key goes on: to the next floating pane between the tiled pane that had the focus before it and that pane's
//! target, then to that target, so a floating pane never keeps the focus. The opposite key goes back the same way.
//! Another key, or no tiled pane in the history, gives the nearest pane after the source by centres, one that
//! overlaps the source on the other axis first. A tiled pane that one floating pane covers wholly is never a
//! target: it does not show. A column then remembers only its panes that show: not a covered pane, and not a
//! pane with no frame.
//!
//! "After" is by the centres on the axis of the key, and at one centre a tiled pane is before a floating pane.
//! So a floating pane that has the centre of a tiled pane on the axis of a key is after that pane for the keys
//! right and down, and never for the keys left and up. With a floating pane in the middle of a tiled pane of the
//! full height: the key down gives the floating pane from the tiled pane and the key up gives the tiled pane from
//! the floating pane; the key up from the tiled pane and the key down from the floating pane do not give the
//! other one.
//!
//! **Rows that are not valid.** [`is_valid`] says whether the rows are ones a caller can give. [`neighbor`]
//! answers for each list of rows and never panics: it reads a frame that is not valid as no frame, so each
//! centre that the sort of a way compares is a number, and 2 rows with one `order`, one place in the focus
//! history or one place among the floating panes come out by the order of the rows.

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

    /// The centre on the axis that a key of `direction` moves on.
    fn centre(self, direction: FocusDirection) -> f64 {
        if direction.is_horizontal() { self.mid_x() } else { self.mid_y() }
    }

    /// How much the frame and `other` share on the axis that a key of `direction` does not move on.
    fn cross_overlap(self, other: FocusFrame, direction: FocusDirection) -> f64 {
        if direction.is_horizontal() {
            self.max_y().min(other.max_y()) - self.y.max(other.y)
        } else {
            self.max_x().min(other.max_x()) - self.x.max(other.x)
        }
    }

    /// Whether no part of `inner` is out of the frame.
    fn covers(self, inner: FocusFrame) -> bool {
        self.x <= inner.x
            && self.y <= inner.y
            && self.max_x() >= inner.max_x()
            && self.max_y() >= inner.max_y()
    }
}

/// One pane of a screen, as the focus keys read it.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct FocusPane {
    /// The frame the screen shows the pane at. A pane with no frame, or with a frame that is not valid, is never
    /// a source and never a candidate. On a screen with no floating pane it can be the pane that its column
    /// remembers.
    pub frame: Option<FocusFrame>,
    /// The column of the pane in a screen of columns.
    pub column: Option<u32>,
    /// The place of the pane in the focus history: 0 is the pane that had the focus last.
    pub recency: Option<u32>,
    /// The place of a floating pane among the floating panes, back to front. `None` for a tiled pane.
    pub floating: Option<u32>,
    /// The last tie-break between 2 panes that are equal in each other way: the smaller one first. A caller
    /// that breaks this tie by the pane ids as text gives the place of the pane's id among the ids in that order.
    pub order: u32,
}

impl FocusPane {
    /// The frame as the rule reads it: a frame that is not valid is no frame.
    fn read_frame(&self) -> Option<FocusFrame> {
        self.frame.filter(|frame| frame.is_valid())
    }
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
        values.iter().zip(values.iter().skip(1)).all(|(value, next)| value != next)
    }
    panes.iter().all(|pane| pane.frame.is_none_or(FocusFrame::is_valid))
        && each_once(panes.iter().map(|pane| pane.order).collect())
        && each_once(panes.iter().filter_map(|pane| pane.recency).collect())
        && each_once(panes.iter().filter_map(|pane| pane.floating).collect())
}

/// The index of the pane that `direction` gives from the pane at `source`, or `None`: no pane is on that side,
/// or the source has no row or no frame. It answers for rows that [`is_valid`] refuses too, and never panics.
pub fn neighbor(panes: &[FocusPane], source: usize, direction: FocusDirection) -> Option<usize> {
    match FloatingRule::of(panes) {
        Some(rule) => rule.neighbor(source, direction),
        None => tiled_neighbor(
            panes,
            source,
            direction,
            &|index| frame_of(panes, index).is_some(),
            &|_| true,
        ),
    }
}

fn frame_of(panes: &[FocusPane], index: usize) -> Option<FocusFrame> {
    panes.get(index).and_then(FocusPane::read_frame)
}

/// 2 numbers in their order. Numbers that have no order (not a number) are equal: a frame that the rule reads
/// has only finite numbers, so this is for a distance between 2 centres that are both past the largest number.
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
    let source_frame = source_pane.read_frame().filter(|_| shows(source))?;
    let candidates = panes
        .iter()
        .enumerate()
        .filter(|(index, _)| *index != source && shows(*index))
        .filter_map(|(index, pane)| {
            Candidate::past_edge(index, pane, pane.read_frame()?, source_frame, direction)
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

/// The rule of a screen that has floating panes.
struct FloatingRule<'a> {
    panes: &'a [FocusPane],
    /// The floating panes that have a frame, back to front.
    floating: Vec<usize>,
    /// For each row of a pane of `floating`: its place there.
    rank: Vec<Option<usize>>,
    /// For each row: whether the pane is a tiled pane that can get the focus. It has a frame, and no floating pane
    /// covers it wholly.
    shows: Vec<bool>,
}

impl<'a> FloatingRule<'a> {
    /// The rule of `panes`, or `None` when no floating pane has a frame: the tiled rule is then the whole rule.
    fn of(panes: &'a [FocusPane]) -> Option<FloatingRule<'a>> {
        let mut places = panes
            .iter()
            .enumerate()
            .filter_map(|(index, pane)| {
                Some((pane.floating?, pane.order, index, pane.read_frame()?))
            })
            .collect::<Vec<_>>();
        if places.is_empty() {
            return None;
        }
        places.sort_by_key(|(place, order, index, _)| (*place, *order, *index));
        let mut rank = vec![None; panes.len()];
        for (at, (_, _, index, _)) in places.iter().enumerate() {
            if let Some(slot) = rank.get_mut(*index) {
                *slot = Some(at);
            }
        }
        let shows = panes
            .iter()
            .zip(&rank)
            .map(|(pane, rank)| {
                rank.is_none()
                    && pane.read_frame().is_some_and(|frame| {
                        !places.iter().any(|(_, _, _, cover)| cover.covers(frame))
                    })
            })
            .collect();
        let floating = places.iter().map(|(_, _, index, _)| *index).collect();
        Some(FloatingRule { panes, floating, rank, shows })
    }

    fn frame(&self, index: usize) -> Option<FocusFrame> {
        frame_of(self.panes, index)
    }

    fn rank(&self, index: usize) -> Option<usize> {
        self.rank.get(index).copied().flatten()
    }

    fn shows(&self, index: usize) -> bool {
        self.shows.get(index).copied().unwrap_or(false)
    }

    /// The pane that `direction` gives from the pane at `pane`.
    fn neighbor(&self, pane: usize, direction: FocusDirection) -> Option<usize> {
        self.frame(pane)?;
        if self.rank(pane).is_none() {
            let (members, target) = self.way(pane, direction);
            return members.first().copied().or(target).or_else(|| {
                let after = self
                    .floating
                    .iter()
                    .copied()
                    .filter(|other| self.is_after(*other, pane, direction));
                after.min_by(|first, second| self.way_order(*first, *second, direction))
            });
        }
        let tiled = (0..self.panes.len()).filter(|other| *other != pane && self.shows(*other));
        if let Some(origin) = most_recent(self.panes, tiled) {
            let (members, target) = self.way(origin, direction);
            if let Some(at) = members.iter().position(|member| *member == pane) {
                let next = members.get(at + 1).copied();
                return next.or(target).or_else(|| self.nearest(pane, direction));
            }
            let (back, _) = self.way(origin, direction.opposite());
            if let Some(at) = back.iter().position(|member| *member == pane) {
                let before = at.checked_sub(1).and_then(|at| back.get(at)).copied();
                return Some(before.unwrap_or(origin));
            }
        }
        self.nearest(pane, direction)
    }

    /// The tiled target of `origin` in `direction`, and the floating panes that stand between the 2, the nearest
    /// to `origin` first. The origin is a source also when a floating pane covers it wholly.
    fn way(&self, origin: usize, direction: FocusDirection) -> (Vec<usize>, Option<usize>) {
        let Some(source) = self.frame(origin) else { return (Vec::new(), None) };
        let around = |index: usize| index == origin || self.shows(index);
        let target = tiled_neighbor(self.panes, origin, direction, &around, &around);
        let mut members = self
            .floating
            .iter()
            .copied()
            .filter(|pane| {
                self.is_after(*pane, origin, direction)
                    && self
                        .frame(*pane)
                        .is_some_and(|frame| frame.cross_overlap(source, direction) > 0.0)
                    && target.is_none_or(|target| self.is_after(target, *pane, direction))
            })
            .collect::<Vec<_>>();
        members.sort_by(|first, second| self.way_order(*first, *second, direction));
        (members, target)
    }

    /// The nearest pane after `pane` in `direction` by centres: one that overlaps it on the other axis first.
    fn nearest(&self, pane: usize, direction: FocusDirection) -> Option<usize> {
        let source = self.frame(pane)?;
        let beside = |other: usize| {
            self.frame(other).is_some_and(|frame| frame.cross_overlap(source, direction) > 0.0)
        };
        let candidates = (0..self.panes.len())
            .filter(|other| {
                *other != pane
                    && (self.shows(*other) || self.rank(*other).is_some())
                    && self.is_after(*other, pane, direction)
            })
            .collect::<Vec<_>>();
        let any_beside = candidates.iter().any(|other| beside(*other));
        candidates
            .iter()
            .copied()
            .filter(|other| !any_beside || beside(*other))
            .filter_map(|other| Some((self.nearness(other, source, direction)?, other)))
            .min_by(|(first, _), (second, _)| {
                lists_in_order(&first.0, &second.0).then(first.1.cmp(&second.1))
            })
            .map(|(_, other)| other)
    }

    /// How near the pane at `index` is to `source`: between the centres on the axis of the key, then on the other
    /// axis; then a tiled pane first, the floating panes back to front, and the order of the rows.
    fn nearness(
        &self,
        index: usize,
        source: FocusFrame,
        direction: FocusDirection,
    ) -> Option<([f64; 2], (usize, usize, u32))> {
        let frame = self.frame(index)?;
        let other_axis = if direction.is_horizontal() {
            (frame.mid_y() - source.mid_y()).abs()
        } else {
            (frame.mid_x() - source.mid_x()).abs()
        };
        let rank = self.rank(index);
        Some((
            [(frame.centre(direction) - source.centre(direction)).abs(), other_axis],
            (usize::from(rank.is_some()), rank.unwrap_or(0), self.panes.get(index)?.order),
        ))
    }

    /// The place of a pane in the order of a key: the centre on the axis of the key, then a floating pane after a
    /// tiled one, then the pane more to the front. No 2 panes with a frame are equal in it, but 2 tiled panes
    /// with one centre. A centre is never "not a number" (each frame here is valid), so the order is total and
    /// the sort of a way has one result. At one centre the tiled pane is first: see the module's text for what
    /// the keys then do.
    fn place(&self, index: usize, direction: FocusDirection) -> (f64, usize, usize) {
        let rank = self.rank(index);
        (
            self.frame(index).map_or(0.0, |frame| frame.centre(direction)),
            usize::from(rank.is_some()),
            rank.unwrap_or(0),
        )
    }

    /// Whether `first` is after `second` for a key of `direction`.
    fn is_after(&self, first: usize, second: usize, direction: FocusDirection) -> bool {
        let (first, second) = (self.place(first, direction), self.place(second, direction));
        let order =
            in_order(first.0, second.0).then(first.1.cmp(&second.1)).then(first.2.cmp(&second.2));
        match direction {
            FocusDirection::Right | FocusDirection::Down => order.is_gt(),
            FocusDirection::Left | FocusDirection::Up => order.is_lt(),
        }
    }

    /// 2 panes in the order that a key of `direction` reaches them: the pane that the other one is after first.
    fn way_order(&self, first: usize, second: usize, direction: FocusDirection) -> Ordering {
        if self.is_after(second, first, direction) {
            Ordering::Less
        } else if self.is_after(first, second, direction) {
            Ordering::Greater
        } else {
            Ordering::Equal
        }
    }
}

#[cfg(test)]
#[path = "pane_focus_tests.rs"]
mod tests;
