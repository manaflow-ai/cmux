//! Scroll state of one columns screen and its reducer (Swift
//! `ColumnScrollState` and `ColumnScrollState.reduce`): the spring the view
//! presents, the strip it was computed for, the focus it follows, and a live
//! trackpad gesture. Changed only by [`ColumnScrollState::reduce`]; the view
//! steps the spring each display frame.

use super::geometry::{adjacent_snap, rubber_band, snap_target};
use super::strip::{Axis, ColumnStrip};
use super::view_offset::{self, Snap};
use super::{swift_max, swift_min, swift_min_by};
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
        let mut effects = ColumnScrollEffects::default();
        match event {
            ColumnScrollEvent::Sync { strip, focused, source, animated, reveals, anchor } => {
                let before = self.spring.target;
                let shift = self.sync(strip, focused, source, reveals, anchor);
                // A sync that leaves the target where the camera shift put it never snaps: a
                // fling or wheel spring in flight keeps moving while pane layout motion is off
                // (motion.md rule 9).
                let clamped =
                    self.strip.as_ref().map_or(self.spring.target, |s| s.clamp(self.spring.target));
                let moved = (clamped - (before + shift)).abs() > 0.25;
                self.finish(animated || !moved, &mut effects);
            }
            ColumnScrollEvent::Center { pane, animated } => {
                if self.gesture.is_some() {
                    return effects;
                }
                let Some(strip) = self.strip.as_ref() else { return effects };
                let Some(frame) = strip.index_of_pane(pane).and_then(|i| strip.frame_at(i)) else {
                    return effects;
                };
                self.spring.target = view_offset::center(frame, self.spring.target, strip);
                self.finish(animated, &mut effects);
            }
            ColumnScrollEvent::Reveal { pane, animated } => {
                if self.gesture.is_some() {
                    return effects;
                }
                let Some(strip) = self.strip.as_ref() else { return effects };
                let Some(index) = strip.index_of_pane(pane) else { return effects };
                self.spring.target = view_offset::target(
                    index,
                    Some(pane),
                    self.spring.target,
                    CenterFocusedColumn::Never,
                    None,
                    strip,
                );
                self.finish(animated, &mut effects);
            }
            ColumnScrollEvent::GestureBegan => {
                // The gesture takes over from the presented value: an automatic
                // scroll in flight stops where it is.
                self.gesture = Some(Gesture { raw: self.spring.value });
                self.samples.clear();
                self.spring.velocity = 0.;
                self.spring.target = self.spring.value;
            }
            ColumnScrollEvent::GestureChanged { delta_x, time } => {
                let Some(mut live) = self.gesture else { return effects };
                let Some(strip) = self.strip.as_ref() else { return effects };
                live.raw -= delta_x;
                self.samples.push(Sample { time, delta: -delta_x });
                self.samples.retain(|sample| kept_by_remove_all(time - sample.time));
                self.gesture = Some(live);
                self.spring.value =
                    rubber_band(live.raw, strip.content_width, strip.viewport_width);
                self.spring.target = self.spring.value;
            }
            ColumnScrollEvent::GestureEnded { time, animated } => {
                if self.gesture.take().is_none() {
                    return effects;
                }
                let mut velocity = 0.;
                // Swift: `recent.reduce(0) { $0 + $1.delta } / max(time - first.time, 1 / 120)`
                // when `recent` has more than one sample.
                let recent = || self.samples.iter().filter(|sample| time - sample.time <= 0.1);
                if let Some(first) = recent().next()
                    && recent().nth(1).is_some()
                {
                    let sum = recent().fold(0., |sum, sample| sum + sample.delta);
                    velocity = sum / super::swift_max(time - first.time, 1. / 120.);
                }
                self.samples.clear();
                let Some(strip) = self.strip.as_ref() else { return effects };
                view_offset::snaps_into(strip, self.mode, &mut self.snaps);
                self.offsets.clear();
                self.offsets.extend(self.snaps.iter().map(|snap| snap.offset));
                let target = snap_target(self.spring.value, velocity, &self.offsets);
                let forward = target >= self.spring.value;
                self.spring.target = target;
                self.spring.velocity = velocity;
                self.move_focus_after_scroll(target, forward, &mut effects);
                effects.report_on_settle = true;
                self.finish(animated, &mut effects);
            }
            ColumnScrollEvent::Page { to, animated } => {
                if self.gesture.is_some() {
                    return effects;
                }
                let Some(strip) = self.strip.as_ref() else { return effects };
                let target = strip.clamp(to);
                let forward = target >= self.spring.target;
                self.spring.target = target;
                view_offset::snaps_into(strip, self.mode, &mut self.snaps);
                self.move_focus_after_scroll(target, forward, &mut effects);
                effects.report_on_settle = true;
                self.finish(animated, &mut effects);
            }
            ColumnScrollEvent::Wheel { direction, animated } => {
                if self.gesture.is_some() {
                    return effects;
                }
                let Some(strip) = self.strip.as_ref() else { return effects };
                view_offset::snaps_into(strip, self.mode, &mut self.snaps);
                self.offsets.clear();
                self.offsets.extend(self.snaps.iter().map(|snap| snap.offset));
                self.spring.target = adjacent_snap(self.spring.target, direction, &self.offsets);
                self.move_focus_after_scroll(self.spring.target, direction > 0, &mut effects);
                effects.report_on_settle = true;
                self.finish(animated, &mut effects);
            }
        }
        effects
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
        self.focused_column = index.and_then(|i| new.id_at(i));
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
        //    Only as far as the new strip lets the camera rest there (a strip
        //    that fits, its ends): a shift given to the value alone, its target
        //    clamped back, would spring the camera back and slide the anchored
        //    column on after the change. A live gesture owns its target (no
        //    clamp) and takes the whole shift.
        let mut delta = 0.;
        if (new.keeps_order(old) || old.viewport_width != new.viewport_width)
            && let Some(anchor) = anchor_override.or(old_column)
            && let (Some(before), Some(after)) = (old.frame_of(anchor), new.frame_of(anchor))
        {
            delta = after.min_x() - before.min_x();
        }
        if self.gesture.is_none() {
            delta = anchor_shift(delta, self.spring.target, new.max_offset());
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
                && let Some(at) = new.frame_of(point.column)
            {
                self.spring.target = at.min_x() + point.relative_offset;
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
            && new.index_of(opened) == previous_index.checked_add(1)
            && let Some(previous_frame) = new.frame_at(previous_index)
        {
            self.restore = Some(RestorePoint {
                column: previous,
                opened,
                relative_offset: self.spring.target - previous_frame.min_x(),
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
            && let Some(before) = old_column.and_then(|c| old.frame_of(c))
            && (before.mid_x() - old.viewport_width / 2. - (self.spring.target - delta)).abs() > 1.
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
        let Some(column) = strip.id_at(next) else { return };
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

/// The part of an anchor's shift `delta` a camera whose target is `target` can
/// take in a strip with `max_offset` of room (Swift
/// `ColumnScrollState.anchorShift`): all of it while the shifted target stays
/// in the strip, up to the strip's end otherwise, and none that would take a
/// target already outside it further out (never a shift the other way).
fn anchor_shift(delta: f64, target: f64, max_offset: f64) -> f64 {
    if delta > 0. {
        swift_min(delta, swift_max(0., max_offset - target))
    } else {
        swift_max(delta, swift_min(0., -target))
    }
}

/// Swift's `samples.removeAll { time - $0.time > 0.1 }` keeps a sample whose
/// age is not more than 0.1 s, a NaN age included.
#[allow(clippy::neg_cmp_op_on_partial_ord)]
fn kept_by_remove_all(age: f64) -> bool {
    !(age > 0.1)
}
