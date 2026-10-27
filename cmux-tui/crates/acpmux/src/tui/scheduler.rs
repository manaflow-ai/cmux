//! Ingest events immediately, coalesce their visual effects into bounded
//! frames. A quiet screen has no render timer; an idle keystroke draws now.
use std::time::{Duration, Instant};

const FRAME_INTERVAL: Duration = Duration::from_millis(16);

pub(super) struct FrameSchedule {
    pub dirty: bool,
    pub deadline: Instant,
}

impl FrameSchedule {
    pub fn new(now: Instant) -> Self {
        Self { dirty: true, deadline: now }
    }
    pub fn request(&mut self) {
        self.dirty = true;
    }
    pub fn ready(&self, now: Instant) -> bool {
        self.dirty && now >= self.deadline
    }
    pub fn presented(&mut self, now: Instant) {
        self.dirty = false;
        self.deadline = now + FRAME_INTERVAL;
    }
}

/// The step of what moves on screen: a running turn, a draft being created, a
/// selection drag held past the transcript's edge.
pub(super) const ANIMATION_STEP: Duration = Duration::from_millis(80);

/// How long a toast shows.
pub(super) const TOAST_FOR: Duration = Duration::from_millis(1800);

/// When the loop wakes with no input: the next animation step while something
/// moves, else the earliest expiry (a pending chord, a toast). A quiet screen
/// has no timer at all, like the frame schedule above. The step is fixed when
/// it is armed, so a continuous daemon stream cannot push it back.
#[derive(Default)]
pub(super) struct Ticker {
    step_at: Option<Instant>,
}

impl Ticker {
    pub fn due(
        &mut self,
        now: Instant,
        moving: bool,
        expiries: &[Option<Instant>],
    ) -> Option<Instant> {
        if !moving {
            self.step_at = None;
        } else if self.step_at.is_none() {
            self.step_at = Some(now + ANIMATION_STEP);
        }
        self.step_at.into_iter().chain(expiries.iter().flatten().copied()).min()
    }

    /// The wake fired at `now`: a step that came due is used; `due` arms the next one.
    pub fn fired(&mut self, now: Instant) {
        if self.step_at.is_some_and(|at| at <= now) {
            self.step_at = None;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_quiet_screen_has_no_wake() {
        let mut ticker = Ticker::default();
        assert_eq!(ticker.due(Instant::now(), false, &[None, None]), None);
    }

    #[test]
    fn moving_wakes_each_step_and_a_stream_does_not_push_the_step_back() {
        let mut ticker = Ticker::default();
        let start = Instant::now();
        assert_eq!(ticker.due(start, true, &[]), Some(start + ANIMATION_STEP));
        // Other events run the loop again before the step: the step stays where it was.
        let later = start + ANIMATION_STEP / 2;
        assert_eq!(ticker.due(later, true, &[]), Some(start + ANIMATION_STEP));
        let fired = start + ANIMATION_STEP;
        ticker.fired(fired);
        assert_eq!(ticker.due(fired, true, &[]), Some(fired + ANIMATION_STEP));
        // It stops moving: no step is left armed.
        assert_eq!(ticker.due(fired, false, &[]), None);
    }

    #[test]
    fn an_expiry_wakes_once_at_its_time() {
        let mut ticker = Ticker::default();
        let now = Instant::now();
        let toast = now + TOAST_FOR;
        let chord = now + Duration::from_millis(1000);
        assert_eq!(ticker.due(now, false, &[Some(toast), Some(chord)]), Some(chord));
        assert_eq!(ticker.due(now, false, &[Some(toast), None]), Some(toast));
    }
}
