//! Trackpad mode: one finger on the screen read as a laptop trackpad reads
//! it, the cursor's acceleration, and double-tap snapping.

use super::Point;

/// What the view sends the Mac for a touch.
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum TrackpadAction {
    /// Move the cursor by the finger's travel (points) over `dt` seconds.
    Move {
        dx: f64,
        dy: f64,
        dt: f64,
    },
    Press,
    Release,
}

#[derive(Clone, Copy, Debug)]
struct Touch {
    start: f64,
    last_move: f64,
    travel: f64,
    pending: (f64, f64),
    moved: bool,
    /// This touch began inside a tap's drag window (the button is down).
    after_tap: bool,
    /// A long press pressed the button.
    long_pressed: bool,
}

impl Touch {
    fn new(time: f64, after_tap: bool) -> Self {
        Self {
            start: time,
            last_move: time,
            travel: 0.0,
            pending: (0.0, 0.0),
            moved: false,
            after_tap,
            long_pressed: false,
        }
    }

    fn holds(&self) -> bool {
        self.after_tap || self.long_pressed
    }

    fn may_long_press(&self) -> bool {
        !self.moved && !self.after_tap && !self.long_pressed
    }
}

#[derive(Clone, Copy, Debug)]
enum State {
    Idle,
    Touching(Touch),
    /// A tap pressed the button; it releases at `until` unless a touch begins.
    TapHeld {
        until: f64,
    },
}

/// One finger in trackpad mode: moving moves the cursor, a tap clicks, tap
/// then touch again and drag (tap-and-a-half) drags, and a long press
/// without moving drags too.
///
/// A tap presses the button at once and releases it only after
/// `drag_window`, so a second touch inside the window continues the same
/// press as a drag. A second quick tap releases, then clicks again: the Mac
/// counts a double click.
#[derive(Clone, Copy, Debug)]
pub struct TrackpadGesture {
    /// Longest touch that counts as a tap.
    pub tap_duration: f64,
    /// Travel (points) before a touch moves the cursor instead of tapping.
    pub slop: f64,
    /// A still touch held this long starts a drag.
    pub long_press_duration: f64,
    /// After a tap, how long a new touch may start to continue it.
    pub drag_window: f64,
    state: State,
}

impl Default for TrackpadGesture {
    fn default() -> Self {
        Self {
            tap_duration: 0.3,
            slop: 8.0,
            long_press_duration: 0.45,
            drag_window: 0.25,
            state: State::Idle,
        }
    }
}

impl TrackpadGesture {
    pub fn new() -> Self {
        Self::default()
    }

    /// The button is down (a tap's window, a drag).
    pub fn button_held(&self) -> bool {
        match self.state {
            State::Idle => false,
            State::TapHeld { .. } => true,
            State::Touching(touch) => touch.holds(),
        }
    }

    /// When [`Self::advance`] next has something to do (a long press, the
    /// end of a tap's window); `None` when nothing is waiting.
    pub fn deadline(&self) -> Option<f64> {
        match self.state {
            State::Idle => None,
            State::TapHeld { until } => Some(until),
            State::Touching(touch) => {
                touch.may_long_press().then_some(touch.start + self.long_press_duration)
            }
        }
    }

    pub fn touch_down(&mut self, time: f64) -> Vec<TrackpadAction> {
        let mut actions = Vec::new();
        let mut after_tap = false;
        match self.state {
            State::TapHeld { until } => {
                if time <= until {
                    after_tap = true;
                } else {
                    actions.push(TrackpadAction::Release);
                }
            }
            State::Touching(touch) if touch.holds() => actions.push(TrackpadAction::Release),
            _ => {}
        }
        self.state = State::Touching(Touch::new(time, after_tap));
        actions
    }

    pub fn touch_moved(&mut self, dx: f64, dy: f64, time: f64) -> Vec<TrackpadAction> {
        let State::Touching(mut touch) = self.state else { return Vec::new() };
        touch.travel += (dx * dx + dy * dy).sqrt();
        let actions = if touch.moved {
            let dt = time - touch.last_move;
            touch.last_move = time;
            vec![TrackpadAction::Move { dx, dy, dt }]
        } else {
            touch.pending.0 += dx;
            touch.pending.1 += dy;
            if touch.travel > self.slop {
                // Past the slop: the cursor catches up with the whole stroke so far.
                touch.moved = true;
                let dt = time - touch.start;
                touch.last_move = time;
                vec![TrackpadAction::Move { dx: touch.pending.0, dy: touch.pending.1, dt }]
            } else {
                Vec::new()
            }
        };
        self.state = State::Touching(touch);
        actions
    }

    pub fn touch_up(&mut self, time: f64) -> Vec<TrackpadAction> {
        use TrackpadAction::{Press, Release};
        let State::Touching(touch) = self.state else { return Vec::new() };
        let is_tap = !touch.moved && time - touch.start <= self.tap_duration;
        if touch.after_tap {
            self.state = State::Idle;
            // A second tap: finish the first click and click again (a double
            // click); anything else was a drag that ends here.
            return if is_tap { vec![Release, Press, Release] } else { vec![Release] };
        }
        if touch.long_pressed {
            self.state = State::Idle;
            return vec![Release];
        }
        if is_tap {
            self.state = State::TapHeld { until: time + self.drag_window };
            return vec![Press];
        }
        self.state = State::Idle;
        Vec::new()
    }

    /// The touch ended without a gesture (a second finger arrived, the
    /// system took it): a held button releases.
    pub fn cancel(&mut self) -> Vec<TrackpadAction> {
        let held = self.button_held();
        self.state = State::Idle;
        if held { vec![TrackpadAction::Release] } else { Vec::new() }
    }

    /// Time passed: a still touch becomes a long-press drag, and a tap
    /// whose window ran out releases its click.
    pub fn advance(&mut self, time: f64) -> Vec<TrackpadAction> {
        match self.state {
            State::TapHeld { until } if time >= until => {
                self.state = State::Idle;
                vec![TrackpadAction::Release]
            }
            State::Touching(mut touch)
                if touch.may_long_press() && time - touch.start >= self.long_press_duration =>
            {
                touch.long_pressed = true;
                self.state = State::Touching(touch);
                vec![TrackpadAction::Press]
            }
            _ => Vec::new(),
        }
    }
}

/// Pointer acceleration for trackpad mode: slow strokes move the cursor as
/// far as the finger went (precise), fast ones up to `maximum_gain` times
/// further, eased in between.
#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct PointerAcceleration {
    pub minimum_gain: f64,
    pub maximum_gain: f64,
    /// At or below this speed (points per second) the gain is the minimum.
    pub slow_speed: f64,
    /// At or above this speed the gain is the maximum.
    pub fast_speed: f64,
}

impl Default for PointerAcceleration {
    fn default() -> Self {
        Self { minimum_gain: 1.0, maximum_gain: 3.0, slow_speed: 120.0, fast_speed: 1400.0 }
    }
}

impl PointerAcceleration {
    pub fn gain(&self, speed: f64) -> f64 {
        let t = ((speed - self.slow_speed) / (self.fast_speed - self.slow_speed)).clamp(0.0, 1.0);
        let eased = t * t * (3.0 - 2.0 * t);
        self.minimum_gain + (self.maximum_gain - self.minimum_gain) * eased
    }

    /// The cursor's travel in framebuffer pixels for a finger's travel in
    /// points over `dt` seconds, with `pixels_per_point` framebuffer pixels
    /// under one point of the view (1 / zoom scale).
    pub fn delta(&self, dx: f64, dy: f64, dt: f64, pixels_per_point: f64) -> (f64, f64) {
        let speed = (dx * dx + dy * dy).sqrt() / dt.max(1.0 / 240.0);
        let scale = self.gain(speed) * pixels_per_point;
        (dx * scale, dy * scale)
    }
}

/// Makes a double tap a double click at one point: a tap soon after the
/// last one and close to it clicks exactly where that one did.
#[derive(Clone, Copy, Debug)]
pub struct ClickSnap {
    /// The Mac's default double-click interval.
    pub interval: f64,
    last: Option<(Point, f64)>,
}

impl Default for ClickSnap {
    fn default() -> Self {
        Self { interval: 0.5, last: None }
    }
}

impl ClickSnap {
    pub fn new() -> Self {
        Self::default()
    }

    /// Where a tap at `point` (at `time`) clicks; `radius` is in the point's units.
    pub fn point(&mut self, point: Point, time: f64, radius: f64) -> Point {
        if let Some((last, last_time)) = self.last
            && time - last_time <= self.interval
            && (point.x - last.x).hypot(point.y - last.y) <= radius
        {
            self.last = Some((last, time));
            return last;
        }
        self.last = Some((point, time));
        point
    }
}

#[cfg(test)]
mod tests {
    //! Ported from CmuxScreenKitTests/ScreenInputTests.swift.
    use super::TrackpadAction::{Move, Press, Release};
    use super::*;

    #[test]
    fn a_tap_presses_at_once_and_releases_after_the_drag_window() {
        let mut g = TrackpadGesture::new();
        assert!(g.touch_down(10.0).is_empty());
        assert_eq!(g.touch_up(10.1), [Press]);
        assert!(g.button_held());
        assert_eq!(g.deadline(), Some(10.1 + g.drag_window));
        assert!(g.advance(10.2).is_empty(), "still inside the window");
        assert_eq!(g.advance(10.4), [Release]);
        assert!(!g.button_held() && g.deadline().is_none());
    }

    #[test]
    fn a_double_tap_is_two_clicks() {
        let mut g = TrackpadGesture::new();
        g.touch_down(0.0);
        assert_eq!(g.touch_up(0.08), [Press]);
        assert!(g.touch_down(0.2).is_empty(), "the press carries on into the second touch");
        assert_eq!(g.touch_up(0.28), [Release, Press, Release]);
        assert!(!g.button_held());
    }

    #[test]
    fn tap_and_a_half_drags_with_the_taps_press() {
        let mut g = TrackpadGesture::new();
        g.touch_down(0.0);
        g.touch_up(0.1);
        g.touch_down(0.25);
        assert!(g.deadline().is_none(), "no long press or window while dragging");
        assert!(g.touch_moved(4.0, 0.0, 0.27).is_empty(), "inside the slop");
        assert_eq!(g.touch_moved(6.0, 0.0, 0.3), [Move { dx: 10.0, dy: 0.0, dt: 0.3 - 0.25 }]);
        assert_eq!(g.touch_moved(5.0, 5.0, 0.32), [Move { dx: 5.0, dy: 5.0, dt: 0.32 - 0.3 }]);
        assert!(g.button_held());
        assert_eq!(g.touch_up(0.6), [Release]);
    }

    #[test]
    fn a_still_touch_becomes_a_long_press_drag() {
        let mut g = TrackpadGesture::new();
        g.touch_down(1.0);
        assert_eq!(g.deadline(), Some(1.0 + g.long_press_duration));
        assert!(g.advance(1.2).is_empty());
        assert_eq!(g.advance(1.5), [Press]);
        assert!(g.button_held());
        assert_eq!(g.touch_moved(20.0, 0.0, 1.6).len(), 1);
        assert_eq!(g.touch_up(2.0), [Release]);
    }

    #[test]
    fn moving_moves_without_clicking() {
        let mut g = TrackpadGesture::new();
        g.touch_down(0.0);
        assert_eq!(g.touch_moved(30.0, 40.0, 0.05), [Move { dx: 30.0, dy: 40.0, dt: 0.05 }]);
        assert!(g.deadline().is_none(), "a moving touch never long-presses");
        assert!(g.advance(5.0).is_empty());
        assert!(g.touch_up(0.1).is_empty());
        g.touch_down(10.0);
        assert!(g.touch_up(10.4).is_empty());
    }

    #[test]
    fn a_second_finger_releases_a_held_button() {
        let mut g = TrackpadGesture::new();
        g.touch_down(0.0);
        g.touch_up(0.1);
        assert_eq!(g.cancel(), [Release]);
        g.touch_down(1.0);
        assert!(g.cancel().is_empty(), "nothing was pressed");
    }

    #[test]
    fn a_late_touch_after_the_window_starts_afresh() {
        let mut g = TrackpadGesture::new();
        g.touch_down(0.0);
        g.touch_up(0.1);
        assert_eq!(g.touch_down(0.9), [Release]);
        assert_eq!(g.touch_up(0.95), [Press]);
    }

    #[test]
    fn a_touch_down_during_a_drag_releases_it_first() {
        let mut g = TrackpadGesture::new();
        g.touch_down(0.0);
        g.advance(0.5);
        assert!(g.button_held());
        assert_eq!(g.touch_down(0.6), [Release], "a long-press drag that never saw its touch up");
        assert!(!g.button_held());
    }

    #[test]
    fn acceleration_is_precise_when_slow_and_faster_when_fast() {
        let a = PointerAcceleration::default();
        assert_eq!(a.gain(0.0), 1.0);
        assert_eq!(a.gain(100.0), 1.0);
        assert_eq!(a.gain(10000.0), 3.0);
        let mid = a.gain(700.0);
        assert!(mid > 1.0 && mid < 3.0);
        assert!(a.gain(500.0) < a.gain(900.0), "monotonic");
        assert_eq!(a.delta(1.0, 0.0, 0.1, 4.0), (4.0, 0.0));
        let (dx, dy) = a.delta(30.0, 40.0, 0.01, 2.0);
        assert!((dx - 180.0).abs() < 0.001 && (dy - 240.0).abs() < 0.001);
    }

    #[test]
    fn a_double_tap_clicks_twice_at_one_point() {
        let mut snap = ClickSnap::new();
        let first = snap.point(Point::new(100.0, 100.0), 0.0, 20.0);
        assert_eq!(first, Point::new(100.0, 100.0));
        assert_eq!(
            snap.point(Point::new(108.0, 95.0), 0.3, 20.0),
            first,
            "the second tap lands on the first"
        );
        assert_eq!(
            snap.point(Point::new(140.0, 100.0), 0.5, 20.0),
            Point::new(140.0, 100.0),
            "too far: a new point"
        );
        assert_eq!(
            snap.point(Point::new(141.0, 100.0), 1.5, 20.0),
            Point::new(141.0, 100.0),
            "too late: a new point"
        );
    }
}
