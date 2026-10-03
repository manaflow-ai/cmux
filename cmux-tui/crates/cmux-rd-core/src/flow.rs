//! Host-side frame flow control and damage coalescing. At most
//! `max_in_flight` frames are unacknowledged beyond the newest acknowledged
//! frame; while the gate is closed, new damage accumulates into one pending
//! region and becomes the next frame when the gate opens. The prototype showed
//! that without this gate frames queue in the send path and latency grows to
//! hundreds of milliseconds.

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
        let x1 = (self.x + self.width).max(other.x + other.width);
        let y1 = (self.y + self.height).max(other.y + other.height);
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
        Some(self.last_encode_us.map_or(0, |t| t + self.min_interval_us))
    }

    /// Re-evaluates the gate (call from the one-shot timer of
    /// [`Self::next_deadline_us`]).
    pub fn poll(&mut self, now_us: u64) -> FlowAction {
        let Some(damage) = self.pending else { return FlowAction::Wait };
        if self.in_flight() >= self.max_in_flight {
            return FlowAction::Wait;
        }
        if let Some(last) = self.last_encode_us
            && now_us < last + self.min_interval_us
        {
            return FlowAction::Wait;
        }
        self.pending = None;
        self.last_sent += 1;
        self.last_encode_us = Some(now_us);
        FlowAction::Encode { damage, frame: self.last_sent }
    }

    /// The viewer lost frames and asked for recovery: frames sent before the
    /// request no longer count as in flight, so the recovery frame can go out.
    pub fn clear_in_flight(&mut self) {
        self.acked = self.last_sent;
    }
}
