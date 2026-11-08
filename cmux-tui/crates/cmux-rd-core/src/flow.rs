//! Host-side frame flow control and damage coalescing. At most
//! `max_in_flight` frames are unacknowledged beyond the newest acknowledged
//! frame; while the gate is closed, new damage accumulates into one pending
//! region and becomes the next frame when the gate opens. The prototype showed
//! that without this gate frames queue in the send path and latency grows to
//! hundreds of milliseconds. An input lifts the frame-rate cap for a short while
//! ([`FrameGate::input`]), so the frame that shows the input's effect goes out the
//! moment its damage arrives instead of on the next interval; the in-flight bound
//! still holds, and frames stay [`INPUT_FRAME_MIN_INTERVAL_US`] apart, or the cap's own
//! interval when that is shorter: the window never sends faster than the cap allows outside it.

/// How long after an input its frames skip the frame-rate cap: long enough for the app
/// and the window server to draw the effect and the capture to deliver it.
pub const INPUT_FRAME_WINDOW_US: u64 = 100_000;

/// The least time between frames inside an input's window (250 fps), unless the cap's own
/// interval is shorter (`--max-fps` above 250), which then holds inside the window as outside
/// it. ScreenCaptureKit delivers at most once per display refresh on its own; X damage has no
/// such bound, so without this floor a burst of damage after an input would encode a burst
/// of frames faster than the cap.
pub const INPUT_FRAME_MIN_INTERVAL_US: u64 = 4_000;

/// A damaged rectangle in stream pixels.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Rect {
    pub x: u32,
    pub y: u32,
    pub width: u32,
    pub height: u32,
}

impl Rect {
    /// The smallest rectangle that contains both.
    pub fn union(self, other: Rect) -> Rect {
        let x0 = self.x.min(other.x);
        let y0 = self.y.min(other.y);
        let x1 = self.x.saturating_add(self.width).max(other.x.saturating_add(other.width));
        let y1 = self.y.saturating_add(self.height).max(other.y.saturating_add(other.height));
        Rect { x: x0, y: y0, width: x1 - x0, height: y1 - y0 }
    }
}

/// What the host should do after an event.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FlowAction {
    /// Capture and encode a frame covering this damage now.
    Encode { damage: Rect, frame: u32 },
    /// Nothing to do yet.
    Wait,
}

/// Frame gate for one display stream.
#[derive(Debug, Clone)]
pub struct FrameGate {
    max_in_flight: u32,
    min_interval_us: u64,
    last_sent: u32,
    acked: u32,
    last_encode_us: Option<u64>,
    pending: Option<Rect>,
    /// When the newest input's window began (frames skip the frame-rate cap for
    /// [`INPUT_FRAME_WINDOW_US`] from then); cleared once the window has passed.
    input_at_us: Option<u64>,
}

impl FrameGate {
    /// `max_fps` bounds the frame rate; `max_in_flight` is 1 on reliable
    /// carriers and on datagrams.
    pub fn new(max_in_flight: u32, max_fps: u32) -> Self {
        Self {
            max_in_flight: max_in_flight.max(1),
            min_interval_us: 1_000_000 / u64::from(max_fps.max(1)),
            last_sent: 0,
            acked: 0,
            last_encode_us: None,
            pending: None,
            input_at_us: None,
        }
    }

    /// Changes the frame rate cap (quality ladder).
    pub fn set_max_fps(&mut self, max_fps: u32) {
        self.min_interval_us = 1_000_000 / u64::from(max_fps.max(1));
    }

    /// Frames sent and not yet acknowledged.
    pub fn in_flight(&self) -> u32 {
        self.last_sent.saturating_sub(self.acked)
    }

    /// Records an input injected now: for [`INPUT_FRAME_WINDOW_US`] frames wait only for
    /// the in-flight bound, not the frame-rate cap. The capture's own rate still bounds
    /// them, so a burst of input never uncaps more than the display delivers.
    pub fn input(&mut self, now_us: u64) {
        self.input_at_us = Some(now_us);
    }

    /// The end of the newest input's window, if there is one.
    fn input_until_us(&self) -> Option<u64> {
        self.input_at_us.map(|at| at.saturating_add(INPUT_FRAME_WINDOW_US))
    }

    /// The least time between frames inside an input's window: the floor, or the cap's interval
    /// when that is shorter (the window lifts a slow cap; it never spaces frames wider than the
    /// cap, nor closer than it allows outside the window).
    fn input_interval_us(&self) -> u64 {
        INPUT_FRAME_MIN_INTERVAL_US.min(self.min_interval_us)
    }

    /// Records damage reported by the capture source.
    pub fn damage(&mut self, rect: Rect, now_us: u64) -> FlowAction {
        self.pending = Some(self.pending.map_or(rect, |p| p.union(rect)));
        self.poll(now_us)
    }

    /// Records the viewer's newest decoded frame.
    pub fn ack(&mut self, frame: u32, now_us: u64) -> FlowAction {
        if frame > self.acked && frame <= self.last_sent {
            self.acked = frame;
        }
        self.poll(now_us)
    }

    /// The earliest time a pending frame may be encoded, if one waits only on
    /// the frame-rate cap (a one-shot timer, never a poll loop).
    pub fn next_deadline_us(&self) -> Option<u64> {
        if self.pending.is_none() || self.in_flight() >= self.max_in_flight {
            return None;
        }
        let Some(last) = self.last_encode_us else { return Some(0) };
        let capped = last + self.min_interval_us;
        // Inside an input's window the frame may go at the window's floor, however slow the
        // cap (an earlier wakeup than the cap, never a later one).
        let windowed = self.input_at_us.and_then(|at| {
            let fast = at.max(last + self.input_interval_us());
            (fast < self.input_until_us()?).then_some(fast)
        });
        Some(windowed.map_or(capped, |fast| fast.min(capped)))
    }

    /// Re-evaluates the gate (call from the one-shot timer of
    /// [`Self::next_deadline_us`]).
    pub fn poll(&mut self, now_us: u64) -> FlowAction {
        let Some(damage) = self.pending else { return FlowAction::Wait };
        if self.in_flight() >= self.max_in_flight {
            return FlowAction::Wait;
        }
        // A window that has passed is gone: the deadline is the cap's again.
        if self.input_until_us().is_some_and(|until| now_us >= until) {
            self.input_at_us = None;
        }
        let interval = if self.input_at_us.is_some_and(|at| now_us >= at) {
            self.input_interval_us()
        } else {
            self.min_interval_us
        };
        if let Some(last) = self.last_encode_us
            && now_us < last + interval
        {
            return FlowAction::Wait;
        }
        self.pending = None;
        // Frame numbers start at 1; at 60 fps u32 lasts over two years per session.
        self.last_sent = self.last_sent.saturating_add(1);
        self.last_encode_us = Some(now_us);
        FlowAction::Encode { damage, frame: self.last_sent }
    }

    /// The viewer lost frames and asked for recovery: frames sent before the
    /// request no longer count as in flight, so the recovery frame can go out.
    pub fn clear_in_flight(&mut self) {
        self.acked = self.last_sent;
    }
}
