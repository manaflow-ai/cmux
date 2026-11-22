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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn idle_input_is_immediate_and_bursts_are_coalesced() {
        let now = Instant::now();
        let mut frames = FrameSchedule::new(now);
        assert!(frames.ready(now));
        frames.presented(now);
        for _ in 0..10_000 {
            frames.request();
        }
        assert!(!frames.ready(now + Duration::from_millis(15)));
        assert!(frames.ready(now + Duration::from_millis(16)));
        frames.presented(now + Duration::from_millis(16));
        assert!(!frames.ready(now + Duration::from_secs(10)));
        frames.request();
        assert!(frames.ready(now + Duration::from_secs(10)));
    }
}
