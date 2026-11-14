//! A pane draws a synchronized update (DEC private mode 2026, `CSI ? 2026 h`
//! ... `CSI ? 2026 l`) as one frame, as the daemon's render viewers get it
//! (cmux-tui-core `surface::frame_producer`): while the program holds the
//! mode, the pane keeps drawing the last frame it drew before the update, and
//! the first draw after the update ends shows all of it. A program that never
//! ends the mode is drawn live again after [`SYNCHRONIZED_OUTPUT_HOLD`], so a
//! crash mid-update never freezes the pane; the event loop wakes for that
//! moment ([`SynchronizedOutput::deadline`]).

use std::collections::HashMap;
use std::sync::Arc;
use std::time::{Duration, Instant};

use cmux_tui_core::{SurfaceId, SurfaceRenderFrame};

/// The longest a synchronized update holds a pane's frame: the daemon's
/// bound (`surface::frame_producer::SYNCHRONIZED_OUTPUT_HOLD`), Ghostty's own
/// (termio `sync_reset_ms`).
pub(super) const SYNCHRONIZED_OUTPUT_HOLD: Duration = Duration::from_millis(1000);

/// DEC private mode 2026, synchronized output.
pub(crate) const SYNCHRONIZED_OUTPUT_MODE: u16 = 2026;

struct PaneFrame {
    /// The last frame the pane drew.
    last: Arc<SurfaceRenderFrame>,
    /// When the pane first saw the terminal in the update that holds now.
    since: Option<Instant>,
    /// The hold ran out and the pane drew the update live: no more wake.
    released: bool,
    /// The terminal's synchronized update start count when the pane last
    /// saw it in an update ([`ghostty_vt::Terminal::synchronized_update_starts`]).
    /// Another count means a new update began since, even when the last
    /// one ended and the next began between two draws.
    starts: u64,
    /// The hold that runs (or ran out) began because a new update started
    /// after an expired one, and the pane has not drawn live since. Such a
    /// hold ends with a live draw before another new update can hold again,
    /// so a program that starts updates nonstop is drawn at least every
    /// other hold.
    restarted: bool,
}

/// Each drawn terminal's last frame and its synchronized update, if any. One
/// entry per terminal the TUI draws, removed with its render state.
#[derive(Default)]
pub(crate) struct SynchronizedOutput {
    panes: HashMap<SurfaceId, PaneFrame>,
}

impl SynchronizedOutput {
    /// The frame to draw for `surface` now: the last drawn frame while a
    /// synchronized update holds it, else `build()`'s (kept as the last).
    /// `update`: the update the terminal holds open now, by its start count
    /// (`SurfaceHandle::synchronized_update`); `None` when it holds none.
    pub(crate) fn frame<E>(
        &mut self,
        surface: SurfaceId,
        update: Option<u64>,
        now: Instant,
        build: impl FnOnce() -> Result<Arc<SurfaceRenderFrame>, E>,
    ) -> Result<Arc<SurfaceRenderFrame>, E> {
        if let Some(pane) = self.panes.get_mut(&surface) {
            match update {
                None => {
                    pane.since = None;
                    pane.released = false;
                    pane.restarted = false;
                }
                Some(starts) => {
                    // An update that began after the one whose hold ran out
                    // holds again, even when the program ended the old one
                    // and began this one since the last draw, unless that
                    // hold itself was such a restart and has not drawn live
                    // yet. One that began while a hold runs keeps that
                    // hold's end.
                    let expired = pane.released
                        || pane.since.is_some_and(|since| since + SYNCHRONIZED_OUTPUT_HOLD <= now);
                    if expired && pane.starts != starts && !pane.restarted {
                        pane.since = None;
                        pane.released = false;
                        pane.restarted = true;
                    }
                    pane.starts = starts;
                    let since = *pane.since.get_or_insert(now);
                    if !pane.released && now < since + SYNCHRONIZED_OUTPUT_HOLD {
                        return Ok(pane.last.clone());
                    }
                    pane.released = true;
                }
            }
        }
        let frame = build()?;
        let pane = self.panes.entry(surface).or_insert_with(|| PaneFrame {
            last: frame.clone(),
            since: None,
            released: false,
            starts: update.unwrap_or_default(),
            restarted: false,
        });
        pane.last = frame.clone();
        pane.restarted = false;
        Ok(frame)
    }

    /// When the next held update runs out, for the event loop's wait.
    pub(crate) fn deadline(&self) -> Option<Instant> {
        self.panes
            .values()
            .filter(|pane| !pane.released)
            .filter_map(|pane| pane.since)
            .map(|since| since + SYNCHRONIZED_OUTPUT_HOLD)
            .min()
    }

    /// The event loop's wait `timeout` (`None`: until an event), cut short
    /// to end at the next held update's deadline. With no hold it is
    /// `timeout` unchanged, so an idle loop never wakes for this.
    pub(crate) fn cap_wait(&self, timeout: Option<Duration>, now: Instant) -> Option<Duration> {
        let held = self.deadline().map(|until| until.saturating_duration_since(now));
        [timeout, held].into_iter().flatten().min()
    }

    /// Ends every hold that ran out by `now`, whether or not its pane is
    /// drawn again; whether one did. A shown pane then draws live; a hidden
    /// one no longer wakes the event loop.
    pub(crate) fn release_expired(&mut self, now: Instant) -> bool {
        let mut released = false;
        for pane in self.panes.values_mut().filter(|pane| !pane.released) {
            if pane.since.is_some_and(|since| since + SYNCHRONIZED_OUTPUT_HOLD <= now) {
                pane.released = true;
                released = true;
            }
        }
        released
    }

    pub(crate) fn remove(&mut self, surface: &SurfaceId) {
        self.panes.remove(surface);
    }

    pub(crate) fn clear(&mut self) {
        self.panes.clear();
    }
}

#[cfg(test)]
mod tests;
