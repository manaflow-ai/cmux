//! Render pacing: the render action an event needs and the terminal paint
//! pacer that coalesces output bursts.

use std::time::{Duration, Instant};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) enum RenderAction {
    None,
    Graphics,
    Paint,
    Draw,
}

pub(super) const TERMINAL_PAINT_CADENCE: Duration = Duration::from_millis(16);

/// Keep terminal parsing lossless while collapsing presentation-only wakes to
/// the host's frame cadence. Structural draws remain immediate.
pub(super) struct TerminalPaintPacer {
    pub(super) next_paint_at: Instant,
    pub(super) pending: bool,
}

impl TerminalPaintPacer {
    pub(super) fn after_paint(now: Instant) -> Self {
        Self { next_paint_at: now + TERMINAL_PAINT_CADENCE, pending: false }
    }

    pub(super) fn wait_timeout(&self, timeout: Duration, now: Instant) -> Duration {
        if self.pending {
            timeout.min(self.next_paint_at.saturating_duration_since(now))
        } else {
            timeout
        }
    }

    pub(super) fn schedule(&mut self, action: RenderAction, now: Instant) -> RenderAction {
        let action = if self.pending && now >= self.next_paint_at {
            action.merge(RenderAction::Paint)
        } else {
            action
        };
        match action {
            RenderAction::Paint if now < self.next_paint_at => {
                self.pending = true;
                RenderAction::None
            }
            RenderAction::Paint | RenderAction::Draw => {
                self.pending = false;
                self.next_paint_at = now + TERMINAL_PAINT_CADENCE;
                action
            }
            RenderAction::None | RenderAction::Graphics => action,
        }
    }

    pub(super) fn render_immediately(
        &mut self,
        action: RenderAction,
        now: Instant,
    ) -> RenderAction {
        let action = if self.pending { action.merge(RenderAction::Paint) } else { action };
        if matches!(action, RenderAction::Paint | RenderAction::Draw) {
            self.pending = false;
            self.next_paint_at = now + TERMINAL_PAINT_CADENCE;
        }
        action
    }
}

impl RenderAction {
    pub(super) fn rebuilds_pointer_route(self) -> bool {
        matches!(self, Self::Paint | Self::Draw)
    }
}

impl RenderAction {
    pub(super) fn merge(self, other: Self) -> Self {
        match (self, other) {
            (RenderAction::Draw, _) | (_, RenderAction::Draw) => RenderAction::Draw,
            (RenderAction::Paint, _) | (_, RenderAction::Paint) => RenderAction::Paint,
            (RenderAction::Graphics, _) | (_, RenderAction::Graphics) => RenderAction::Graphics,
            (RenderAction::None, RenderAction::None) => RenderAction::None,
        }
    }
}
