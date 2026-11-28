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
