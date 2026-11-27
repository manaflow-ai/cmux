//! Viewport animation: animation timing, the per-frame projection work
//! counter, viewport geometry and motion.

#[cfg(test)]
use std::cell::Cell;
use std::time::{Duration, Instant};

use cmux_tui_core::PaneId;

use crate::pty_input::PTY_OPERATION_QUEUE_CAPACITY;

pub(super) const VIEWPORT_ANIMATION_DURATION: Duration = Duration::from_millis(180);
// Animated prefetch is optional work on the same 512-entry ordered lane as
// terminal input. Keep it to one eighth of that lane so a focus jump cannot
// crowd out its destination or subsequent input.
pub(super) const VIEWPORT_ANIMATION_SYNC_OPERATION_BUDGET: usize = PTY_OPERATION_QUEUE_CAPACITY / 8;

#[cfg(test)]
thread_local! {
    static PANE_AREA_PROJECTION_WORK: Cell<usize> = const { Cell::new(0) };
}

#[cfg(test)]
pub(super) fn reset_pane_area_projection_work() {
    PANE_AREA_PROJECTION_WORK.set(0);
}

#[cfg(test)]
pub(super) fn record_pane_area_projection_work(amount: usize) {
    PANE_AREA_PROJECTION_WORK.set(PANE_AREA_PROJECTION_WORK.get().saturating_add(amount));
}

#[cfg(test)]
pub(super) fn pane_area_projection_work() -> usize {
    PANE_AREA_PROJECTION_WORK.get()
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) struct ViewportGeometry {
    pub(super) active_span: Option<(u64, u64)>,
    pub(super) viewport_x: u64,
    pub(super) viewport_width: u16,
    pub(super) virtual_width: u64,
}

#[derive(Debug)]
pub(super) struct ViewportMotion {
    pub(super) current: f64,
    pub(super) start: f64,
    pub(super) target: f64,
    pub(super) started_at: Instant,
    pub(super) last_active_pane: Option<PaneId>,
    pub(super) last_geometry: Option<ViewportGeometry>,
}

impl ViewportMotion {
    pub(super) fn new(now: Instant) -> Self {
        Self {
            current: 0.0,
            start: 0.0,
            target: 0.0,
            started_at: now,
            last_active_pane: None,
            last_geometry: None,
        }
    }

    pub(super) fn update(&mut self, now: Instant) -> bool {
        if (self.current - self.target).abs() < f64::EPSILON {
            return false;
        }
        let progress = (now.saturating_duration_since(self.started_at).as_secs_f64()
            / VIEWPORT_ANIMATION_DURATION.as_secs_f64())
        .clamp(0.0, 1.0);
        let eased = 1.0 - (1.0 - progress).powi(3);
        let previous = self.current;
        self.current = self.start + (self.target - self.start) * eased;
        if progress >= 1.0 {
            self.current = self.target;
        }
        (self.current - previous).abs() >= 0.01
    }

    pub(super) fn retarget(&mut self, target: u64, animate: bool, now: Instant) {
        let target = target as f64;
        let _ = self.update(now);
        if (self.target - target).abs() < f64::EPSILON {
            if !animate {
                self.current = target;
                self.start = target;
            }
            return;
        }
        if animate {
            self.start = self.current;
            self.target = target;
            self.started_at = now;
        } else {
            self.current = target;
            self.start = target;
            self.target = target;
            self.started_at = now;
        }
    }

    pub(super) fn animating(&self) -> bool {
        (self.current - self.target).abs() >= 0.01
    }

    pub(super) fn offset(&self) -> u64 {
        self.current.round().clamp(0.0, u64::MAX as f64) as u64
    }
}
