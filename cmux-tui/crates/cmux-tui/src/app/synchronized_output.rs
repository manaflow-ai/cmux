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
    pub(crate) fn frame<E>(
        &mut self,
        surface: SurfaceId,
        synchronized: bool,
        now: Instant,
        build: impl FnOnce() -> Result<Arc<SurfaceRenderFrame>, E>,
    ) -> Result<Arc<SurfaceRenderFrame>, E> {
        if let Some(pane) = self.panes.get_mut(&surface) {
            if !synchronized {
                pane.since = None;
                pane.released = false;
            } else {
                let since = *pane.since.get_or_insert(now);
                if !pane.released && now < since + SYNCHRONIZED_OUTPUT_HOLD {
                    return Ok(pane.last.clone());
                }
                pane.released = true;
            }
        }
        let frame = build()?;
        let pane = self.panes.entry(surface).or_insert_with(|| PaneFrame {
            last: frame.clone(),
            since: None,
            released: false,
        });
        pane.last = frame.clone();
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
mod tests {
    use super::*;
    use ghostty_vt::{Callbacks, RenderState, Rgb, Terminal};

    fn frame_of(text: &str) -> Arc<SurfaceRenderFrame> {
        let mut term = Terminal::new(10, 2, 0, Callbacks::default()).unwrap();
        term.vt_write(text.as_bytes());
        let mut state = RenderState::new().unwrap();
        state.update(&mut term).unwrap();
        Arc::new(SurfaceRenderFrame {
            frame: state.build_frame().unwrap(),
            content_generation: 1,
            scrollback_rows: 0,
            history_epoch: 0,
            pointer_semantics: term.pointer_semantic_snapshot(),
            palette_colors: [Rgb::default(); 256],
            palette_overridden: [false; 256],
        })
    }

    fn text(frame: &SurfaceRenderFrame) -> String {
        frame.frame.styled_row(0).unwrap().iter().map(|cell| cell.text.as_str()).collect()
    }

    fn draw(hold: &mut SynchronizedOutput, synchronized: bool, at: Instant, live: &str) -> String {
        let built = frame_of(live);
        text(&hold.frame::<()>(1, synchronized, at, || Ok(built)).unwrap())
    }

    #[test]
    fn a_synchronized_update_draws_as_one_frame() {
        let mut hold = SynchronizedOutput::default();
        let start = Instant::now();
        assert_eq!(draw(&mut hold, false, start, "before"), "before");
        assert_eq!(hold.deadline(), None);
        let ms = |n| start + Duration::from_millis(n);
        assert_eq!(draw(&mut hold, true, ms(10), "half"), "before", "a half-drawn update shows");
        assert_eq!(hold.deadline(), Some(ms(10) + SYNCHRONIZED_OUTPUT_HOLD));
        assert_eq!(draw(&mut hold, true, ms(500), "more"), "before");
        assert_eq!(draw(&mut hold, false, ms(600), "whole"), "whole", "the update ended");
        assert_eq!(hold.deadline(), None);
    }

    #[test]
    fn an_update_that_never_ends_is_drawn_after_the_hold() {
        let mut hold = SynchronizedOutput::default();
        let start = Instant::now();
        let ms = |n| start + Duration::from_millis(n);
        assert_eq!(draw(&mut hold, false, start, "before"), "before");
        assert_eq!(draw(&mut hold, true, ms(1), "stuck"), "before");
        let deadline = hold.deadline().unwrap();
        assert_eq!(draw(&mut hold, true, deadline, "stuck"), "stuck", "the hold ran out");
        assert_eq!(hold.deadline(), None, "no wake after the hold ran out");
        assert_eq!(draw(&mut hold, true, deadline + Duration::from_secs(5), "live"), "live");
        // A new update after the stuck one ended holds again.
        assert_eq!(draw(&mut hold, false, ms(7000), "after"), "after");
        assert_eq!(draw(&mut hold, true, ms(7001), "next"), "after");
    }

    #[test]
    fn a_hold_of_a_pane_no_longer_drawn_stops_waking_the_loop() {
        let mut hold = SynchronizedOutput::default();
        let start = Instant::now();
        assert_eq!(draw(&mut hold, false, start, "before"), "before");
        assert_eq!(draw(&mut hold, true, start, "held"), "before");
        let deadline = hold.deadline().unwrap();
        assert!(!hold.release_expired(deadline - Duration::from_millis(1)));
        assert!(hold.release_expired(deadline));
        assert_eq!(hold.deadline(), None, "a hidden pane's hold must not keep waking the loop");
        assert_eq!(draw(&mut hold, true, deadline, "live"), "live");
    }

    #[test]
    fn the_loop_wait_ends_at_a_hold_and_is_unchanged_without_one() {
        let mut hold = SynchronizedOutput::default();
        let start = Instant::now();
        let ms = Duration::from_millis;
        assert_eq!(hold.cap_wait(None, start), None, "no hold: an idle loop waits for an event");
        assert_eq!(hold.cap_wait(Some(ms(30)), start), Some(ms(30)));
        assert_eq!(draw(&mut hold, false, start, "before"), "before");
        assert_eq!(hold.cap_wait(None, start), None, "a drawn pane with no update holds nothing");
        assert_eq!(draw(&mut hold, true, start, "held"), "before");
        let at = start + ms(400);
        assert_eq!(hold.cap_wait(None, at), Some(SYNCHRONIZED_OUTPUT_HOLD - ms(400)));
        assert_eq!(hold.cap_wait(Some(ms(16)), at), Some(ms(16)));
        let late = start + SYNCHRONIZED_OUTPUT_HOLD + ms(5);
        assert_eq!(hold.cap_wait(None, late), Some(Duration::ZERO), "a passed hold wakes at once");
        assert!(hold.release_expired(late));
        assert_eq!(hold.cap_wait(None, late), None, "a released hold never wakes the loop again");
    }

    #[test]
    fn a_pane_never_drawn_before_draws_the_update_live() {
        let mut hold = SynchronizedOutput::default();
        assert_eq!(draw(&mut hold, true, Instant::now(), "first"), "first");
        hold.remove(&1);
        assert_eq!(hold.deadline(), None);
    }
}
