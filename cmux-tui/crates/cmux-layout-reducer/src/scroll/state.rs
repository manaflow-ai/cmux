//! Scroll state of one columns screen and its reducer (Swift
//! `ColumnScrollState` and `ColumnScrollState.reduce`): the spring the view
//! presents, the strip it was computed for, the focus it follows, and a live
//! trackpad gesture. Changed only by [`ColumnScrollState::reduce`]; the view
//! steps the spring each display frame.

use super::geometry::{adjacent_snap, rubber_band, snap_target};
use super::strip::{Axis, ColumnStrip};
use super::swift_min_by;
use super::view_offset::{self, Snap};
use crate::{ColumnId, PaneId};

/// Column centering mode, cmux.json `layout.centerFocusedColumn`.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Hash)]
pub enum CenterFocusedColumn {
    /// Scroll the least amount that makes the focused column fully visible.
    #[default]
    Never,
    /// Always center the focused column (clamped at the strip ends).
    Always,
    /// Center only when the focused column and the column focus came from do
    /// not fit on screen together; otherwise scroll the least amount.
    OnOverflow,
}

/// What moved the focus. A pointer click never centers: the column under the
/// pointer only scrolls far enough to be fully visible, so content does not
/// slide away under the click (also in `Always` mode).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum ColumnFocusSource {
    Keyboard,
    Pointer,
    /// Focus decided elsewhere (CLI, daemon, a new pane): same as keyboard.
    Programmatic,
    /// Focus the scroll itself moved (end of a trackpad gesture or a wheel
    /// notch): the column is already visible, nothing scrolls.
    Scroll,
}

/// One scalar driven by a damped spring toward `target` (Swift
/// `SpringValue`); cmux-motion steps it.
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct Spring {
    pub value: f64,
    pub velocity: f64,
    pub target: f64,
}

impl Spring {
    pub const fn new(value: f64) -> Self {
        Self { value, velocity: 0., target: value }
    }

    /// Jumps to the target and stops.
    pub fn snap(&mut self) {
        self.value = self.target;
        self.velocity = 0.;
    }
}

/// A live trackpad gesture: the unbanded offset accumulated from the deltas.
/// Its samples are [`ColumnScrollState::samples`].
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Gesture {
    pub raw: f64,
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Sample {
    pub time: f64,
    pub delta: f64,
}

/// Restore point: a column opened right of the focused one and focused;
/// closing it returns to this offset.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct RestorePoint {
    /// The column focused before the new one opened.
    pub column: ColumnId,
    /// The column that opened right of it.
    pub opened: ColumnId,
    /// Target offset then, relative to `column`'s leading edge.
    pub relative_offset: f64,
}

/// One input to the reducer.
#[derive(Clone, Debug, PartialEq)]
pub enum ColumnScrollEvent {
    /// A model snapshot: layout, geometry (viewport) or focus changed.
    /// `source` says what moved the focus when it changed. `reveals: false`
    /// (a divider or column-edge drag in progress) only anchors the camera;
    /// the reveal runs at the next sync that allows it. `anchor` is the
    /// column the camera keeps in place instead of the focused one: the
    /// column under a resize drag, whose leading edge must stay put so its
    /// edge follows the pointer (cx-ww20).
    Sync {
        strip: ColumnStrip,
        focused: Option<PaneId>,
        source: ColumnFocusSource,
        animated: bool,
        reveals: bool,
        anchor: Option<ColumnId>,
    },
    /// Center the column holding the pane once.
    Center {
        pane: PaneId,
        animated: bool,
    },
    /// Scroll the column holding the pane into view once, the least that
    /// shows it, without focusing it: a tab opened beside a chat that keeps
    /// focus (cx-27j7).
    Reveal {
        pane: PaneId,
        animated: bool,
    },
    GestureBegan,
    GestureChanged {
        delta_x: f64,
        time: f64,
    },
    GestureEnded {
        time: f64,
        animated: bool,
    },
    /// One discrete mouse-wheel notch, +1 forward (offset increases).
    Wheel {
        direction: i32,
        animated: bool,
    },
    /// Scroll to an offset chosen by the strip scrollbar (a track click's
    /// page target); focus follows like a wheel notch.
    Page {
        to: f64,
        animated: bool,
    },
}

/// What the view does after a reduce.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct ColumnScrollEffects {
    /// The spring moves: run the display link.
    pub needs_frames: bool,
    /// The scroll moved focus to this pane (gesture end, wheel notch).
    pub focus: Option<PaneId>,
    /// Report the settled leading column when the spring rests.
    pub report_on_settle: bool,
    /// The offset jumped to a new target without frames (animation off or
    /// Reduce Motion), where a spring would have scrolled.
    pub snapped: bool,
}

#[derive(Clone, Debug, Default)]
pub struct ColumnScrollState {
    /// `value` is presented, `target` is where it settles.
    pub spring: Spring,
    pub strip: Option<ColumnStrip>,
    pub focused_pane: Option<PaneId>,
    pub focused_column: Option<ColumnId>,
    pub mode: CenterFocusedColumn,
    pub gesture: Option<Gesture>,
    /// The live gesture's deltas of the last 0.1 s (empty with no gesture).
    pub samples: Vec<Sample>,
    pub restore: Option<RestorePoint>,
    /// Last focused pane per column, for focus moved by a scroll.
    pub remembered: Vec<(ColumnId, PaneId)>,
    /// A sync skipped its reveal (live resize drag); the next one reveals.
    pub reveal_deferred: bool,
    /// The strip the last sync replaced, kept for its buffers.
    spare: Option<ColumnStrip>,
    snaps: Vec<Snap>,
    offsets: Vec<f64>,
}

impl ColumnScrollState {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn is_gesture_active(&self) -> bool {
        self.gesture.is_some()
    }

    /// The pane remembered for `column`.
    pub fn remembered_pane(&self, column: ColumnId) -> Option<PaneId> {
        self.remembered.iter().find(|(c, _)| *c == column).map(|(_, p)| *p)
    }

    /// An empty strip for the next sync, reusing the buffers of the strip
    /// the last sync replaced.
    pub fn take_spare_strip(&mut self) -> ColumnStrip {
        let mut strip = self.spare.take().unwrap_or_default();
        strip.reset(0., 0., 0.);
        strip
    }

    pub fn reduce(&mut self, event: ColumnScrollEvent) -> ColumnScrollEffects {
        // RED: rule not ported yet.
        let _ = event;
        ColumnScrollEffects::default()
    }

    fn finish(&mut self, animated: bool, effects: &mut ColumnScrollEffects) {
        if self.gesture.is_none()
            && let Some(strip) = self.strip.as_ref()
        {
            self.spring.target = strip.clamp(self.spring.target);
        }
        if !animated && self.gesture.is_none() {
            // The spring's rest epsilon: less than this would not have stepped.
            effects.snapped = (self.spring.target - self.spring.value).abs() > 0.25;
            self.spring.snap();
        }
        effects.needs_frames =
            self.spring.value != self.spring.target || self.spring.velocity != 0.;
    }

    /// Takes the new strip; returns the camera shift it applied to the value
    /// and the target (step 1).
    fn sync(
        &mut self,
        new: ColumnStrip,
        focused: Option<PaneId>,
        source: ColumnFocusSource,
        reveals: bool,
        anchor: Option<ColumnId>,
    ) -> f64 {
        let old = self.strip.take();
        let delta = self.sync_against(&new, old.as_ref(), focused, source, reveals, anchor);
        self.strip = Some(new);
        self.spare = old;
        delta
    }

    fn sync_against(
        &mut self,
        new: &ColumnStrip,
        old: Option<&ColumnStrip>,
        focused: Option<PaneId>,
        source: ColumnFocusSource,
        reveals: bool,
        anchor_override: Option<ColumnId>,
    ) -> f64 {
        let old_pane = self.focused_pane;
        let old_column = self.focused_column;
        self.focused_pane = focused;
        let index = focused.and_then(|pane| new.index_of_pane(pane));
        self.focused_column = index.map(|i| new.columns[i].id);
        if let (Some(focused), Some(column)) = (focused, self.focused_column) {
            match self.remembered.iter_mut().find(|(c, _)| *c == column) {
                Some(entry) => entry.1 = focused,
                None => self.remembered.push((column, focused)),
            }
        }
        self.remembered.retain(|(column, _)| new.index_of(*column).is_some());

        let Some(old) = old else {
            // First strip: place the focused column, no animation.
            if let Some(index) = index {
                self.spring.target =
                    view_offset::target(index, focused, self.spring.target, self.mode, None, new);
            }
            self.spring.snap();
            return 0.;
        };

        // 1. Camera: keep the previously focused column (or the column under
        //    a resize drag) where it is on screen across insertions, removals,
        //    width and window changes. A reorder (move column) keeps the camera
        //    itself.
        let mut delta = 0.;
        if (new.keeps_order(old) || old.viewport_width != new.viewport_width)
            && let Some(anchor) = anchor_override.or(old_column)
            && let (Some(before), Some(after)) = (old.index_of(anchor), new.index_of(anchor))
        {
            delta = new.columns[after].frame.min_x() - old.columns[before].frame.min_x();
        }
        self.spring.value += delta;
        self.spring.target += delta;
        if let Some(gesture) = self.gesture.as_mut() {
            gesture.raw += delta;
        }

        // 2. Restore after closing a column that was just opened to the right.
        let removed =
            |column: ColumnId| old.index_of(column).is_some() && new.index_of(column).is_none();
        let any_removed = old.columns.iter().any(|c| new.index_of(c.id).is_none());
        let mut restored = false;
        if let Some(point) = self.restore {
            // Only when the opened column was focused and its close moved
            // focus back: an unfocused close (the user went back first, or
            // the CLI closed it) must not scroll the focused column away
            // (close-focus.md, found by ColumnScrollCloseModelCheckTests S3).
            if removed(point.opened)
                && old_column == Some(point.opened)
                && self.focused_column == Some(point.column)
                && let Some(at) = new.index_of(point.column)
            {
                self.spring.target = new.columns[at].frame.min_x() + point.relative_offset;
                restored = true;
                self.restore = None;
            } else if removed(point.column)
                || removed(point.opened)
                || (self.focused_column != Some(point.opened)
                    && self.focused_column != Some(point.column))
            {
                self.restore = None;
            }
        }
        // Swift's `added` is a set: exactly one new column id (repeats count once).
        let mut added = new.columns.iter().map(|c| c.id).filter(|id| old.index_of(*id).is_none());
        let single_added = added.next().filter(|first| added.all(|id| id == *first));
        if let Some(opened) = single_added
            && self.focused_column == Some(opened)
            && let Some(previous) = old_column
            && let Some(previous_index) = new.index_of(previous)
            && new.index_of(opened) == Some(previous_index + 1)
        {
            self.restore = Some(RestorePoint {
                column: previous,
                opened,
                relative_offset: self.spring.target - new.columns[previous_index].frame.min_x(),
            });
        }

        // A removed column cannot leave the camera past the new strip. The view carries the
        // panes horizontally from where they showed; row cameras keep their vertical spring.
        // Only a velocity out of the strip from where the camera now rests stops: one back into
        // it (a center or fling that was already coming back) goes on, so the close takes the
        // camera at the speed it shows. A strip that now fits has no inside to go back to: it
        // stops at 0.
        if new.axis == Axis::Horizontal && any_removed {
            let clamped = new.clamp(self.spring.value);
            if clamped != self.spring.value
                && ((clamped >= new.max_offset() && self.spring.velocity > 0.)
                    || (clamped <= 0. && self.spring.velocity < 0.))
            {
                self.spring.velocity = 0.;
            }
            self.spring.value = clamped;
            self.spring.target = new.clamp(self.spring.target);
            if let Some(gesture) = self.gesture.as_mut() {
                gesture.raw = new.clamp(gesture.raw);
            }
        }

        // 3. Reveal. A live gesture owns the target; its end keeps the
        //    focused column visible.
        if self.gesture.is_some() {
            return delta;
        }
        if !reveals {
            self.reveal_deferred = true;
            return delta;
        }
        let deferred = self.reveal_deferred;
        self.reveal_deferred = false;
        let Some(index) = index else { return delta };
        let column_changed = self.focused_column != old_column;
        if focused == old_pane && old == new && !restored && !deferred {
            return delta;
        }
        let mut effective_mode =
            if matches!(source, ColumnFocusSource::Pointer | ColumnFocusSource::Scroll) {
                CenterFocusedColumn::Never
            } else {
                self.mode
            };
        if !column_changed
            && focused == old_pane
            && effective_mode == CenterFocusedColumn::Always
            && let Some(before) = old_column.and_then(|c| old.index_of(c))
            && (old.columns[before].frame.mid_x()
                - old.viewport_width / 2.
                - (self.spring.target - delta))
                .abs()
                > 1.
        {
            // A layout-only change keeps a column that was not centered
            // (clicked into view) where fitting puts it.
            effective_mode = CenterFocusedColumn::Never;
        }
        let previous = if column_changed { old_column.and_then(|c| new.index_of(c)) } else { None };
        self.spring.target =
            view_offset::target(index, focused, self.spring.target, effective_mode, previous, new);
        delta
    }

    /// Moves focus after a scroll to `target`; reads the snaps in `self.snaps`.
    fn move_focus_after_scroll(
        &mut self,
        target: f64,
        forward: bool,
        effects: &mut ColumnScrollEffects,
    ) {
        let Some(strip) = self.strip.as_ref() else { return };
        let snap_column = swift_min_by(self.snaps.iter().copied(), |a, b| {
            (a.offset - target).abs() < (b.offset - target).abs()
        })
        .map_or(0, |snap| snap.column);
        let focused_index = self.focused_column.and_then(|c| strip.index_of(c));
        let Some(next) =
            view_offset::focus_after_scroll(focused_index, snap_column, target, forward, strip)
        else {
            return;
        };
        let column = strip.columns[next].id;
        let Some(pane) = self.remembered_pane(column).or_else(|| strip.first_pane(next)) else {
            return;
        };
        // Recorded now, so the model's echo of this focus is not a change.
        self.focused_pane = Some(pane);
        self.focused_column = Some(column);
        self.restore = None;
        effects.focus = Some(pane);
    }
}

/// Swift's `samples.removeAll { time - $0.time > 0.1 }` keeps a sample whose
/// age is not more than 0.1 s, a NaN age included.
#[allow(clippy::neg_cmp_op_on_partial_ord)]
fn kept_by_remove_all(age: f64) -> bool {
    !(age > 0.1)
}
