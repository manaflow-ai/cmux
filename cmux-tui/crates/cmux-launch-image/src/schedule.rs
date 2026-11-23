//! When a window's image is due: one schedule per window, fed the window's events with the time,
//! asked when to capture. No timers and no clock: the app arms one timer at [`Schedule::due_at`]
//! and asks [`Schedule::take_due`] when it fires.
//!
//! A capture is due `debounce_ms` after the last change the launch record is rewritten for (frame,
//! theme, shown workspace or tab), and only while the window is shown and no transition (live
//! resize, full-screen, a workspace switch's animation) runs: a change inside a transition waits
//! for its end, then for the debounce. A burst of changes is one capture. At quit
//! ([`Schedule::take_quit`]) a shown, settled window captures when it changed since its last
//! capture or has none from this run.

/// A window event, as the C ABI numbers it.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u32)]
pub enum Event {
    /// The window's frame, theme, shown workspace or shown tab changed.
    Changed = 1,
    /// The window was hidden (ordered out, minimized, occluded): nothing is captured until shown.
    Hidden = 2,
    /// The window is on screen again.
    Shown = 3,
    /// A transition began (live resize, full-screen, an animation); they nest.
    TransitionBegan = 4,
    /// A transition ended.
    TransitionEnded = 5,
    /// A capture [`Schedule::take_due`] started wrote nothing: it is due again after the debounce.
    CaptureFailed = 6,
    /// A capture [`Schedule::take_due`] started was published and handed to the launch record.
    CaptureDone = 7,
}

impl Event {
    pub fn from_raw(raw: u32) -> Option<Self> {
        Some(match raw {
            1 => Self::Changed,
            2 => Self::Hidden,
            3 => Self::Shown,
            4 => Self::TransitionBegan,
            5 => Self::TransitionEnded,
            6 => Self::CaptureFailed,
            7 => Self::CaptureDone,
            _ => return None,
        })
    }
}

/// Debounce for a window's changes: 750 ms, past a typical drag, a tab-switch burst or a theme fade.
pub const DEFAULT_DEBOUNCE_MS: u64 = 750;

/// One window's capture schedule. A new window is hidden, unchanged and has no capture.
#[derive(Debug, Clone)]
pub struct Schedule {
    debounce_ms: u64,
    /// The time of the last change no capture has taken yet.
    dirty_since: Option<u64>,
    /// The time the window last became capturable (shown and settled); a due time is never before it
    /// plus the debounce, so a capture never lands on a transition's last frames.
    settled_at: u64,
    hidden: bool,
    transitions: u32,
    captured: bool,
    /// A capture was started ([`Self::take_due`], [`Self::take_quit`]) and has not reported
    /// [`Event::CaptureDone`] or [`Event::CaptureFailed`].
    in_flight: bool,
    /// Bumped when the window changes, its visibility flips or a transition begins or ends: a capture
    /// started at one epoch is stale once it moved ([`Self::is_current`]).
    epoch: u64,
}

impl Schedule {
    pub fn new(debounce_ms: u64) -> Self {
        Self {
            debounce_ms,
            dirty_since: None,
            settled_at: 0,
            hidden: true,
            transitions: 0,
            captured: false,
            in_flight: false,
            epoch: 0,
        }
    }

    fn capturable(&self) -> bool {
        !self.hidden && self.transitions == 0
    }

    /// Records `event` at `now_ms` and returns [`Self::due_at`].
    pub fn note(&mut self, event: Event, now_ms: u64) -> Option<u64> {
        let was_capturable = self.capturable();
        // A repeated hide or show (occlusion notifications repeat) is no change.
        let moves = match event {
            Event::Changed | Event::TransitionBegan => true,
            Event::TransitionEnded => self.transitions > 0,
            Event::Hidden => !self.hidden,
            Event::Shown => self.hidden,
            Event::CaptureFailed | Event::CaptureDone => false,
        };
        match event {
            Event::Changed => self.dirty_since = Some(now_ms),
            Event::CaptureFailed => {
                self.in_flight = false;
                self.dirty_since = Some(now_ms);
            }
            Event::CaptureDone => self.in_flight = false,
            Event::Hidden => self.hidden = true,
            Event::Shown => self.hidden = false,
            Event::TransitionBegan => self.transitions = self.transitions.saturating_add(1),
            Event::TransitionEnded => self.transitions = self.transitions.saturating_sub(1),
        }
        if moves {
            self.epoch = self.epoch.wrapping_add(1);
            // The capture in flight is stale now and will be dropped: its change is due again.
            if self.in_flight {
                self.in_flight = false;
                self.dirty_since.get_or_insert(now_ms);
            }
        }
        if self.capturable() && !was_capturable {
            self.settled_at = now_ms;
        }
        self.due_at()
    }

    /// When a capture is due, or `None` while nothing changed, the window is hidden or a transition
    /// runs.
    pub fn due_at(&self) -> Option<u64> {
        let since = self.dirty_since?;
        self.capturable().then(|| since.max(self.settled_at).saturating_add(self.debounce_ms))
    }

    /// The window's change epoch: read it when a capture starts, and publish the capture only while
    /// [`Self::is_current`] holds, so an image is never paired with a newer frame, theme, shown
    /// workspace or tab than the one it shows.
    pub fn epoch(&self) -> u64 {
        self.epoch
    }

    /// True when nothing happened to the window since `epoch` (no change, hide, show or transition)
    /// and it is still capturable. Check it after the capture and before publishing it: a stale
    /// capture is dropped, and the event that made it stale already armed the next one.
    pub fn is_current(&self, epoch: u64) -> bool {
        self.epoch == epoch && self.capturable()
    }

    /// True when a capture is due at `now_ms`: the caller captures now, and the change counts as
    /// taken (a capture that fails notes [`Event::CaptureFailed`]).
    pub fn take_due(&mut self, now_ms: u64) -> bool {
        if self.due_at().is_some_and(|due| now_ms >= due) {
            self.dirty_since = None;
            self.captured = true;
            self.in_flight = true;
            return true;
        }
        false
    }

    /// True when the quit should capture this window now: shown, settled, and changed since its last
    /// capture or never captured in this run. Takes the change like [`Self::take_due`].
    pub fn take_quit(&mut self) -> bool {
        if self.capturable() && (self.dirty_since.is_some() || !self.captured) {
            self.dirty_since = None;
            self.captured = true;
            self.in_flight = true;
            return true;
        }
        false
    }
}

impl Default for Schedule {
    fn default() -> Self {
        Self::new(DEFAULT_DEBOUNCE_MS)
    }
}
