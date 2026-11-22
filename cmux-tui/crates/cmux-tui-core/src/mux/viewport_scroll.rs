//! Protocol viewport scrolling: `scroll-surface` and
//! `terminal.viewport.scroll`.

use super::*;

impl Mux {
    /// Scroll for a protocol command (`scroll-surface`,
    /// `terminal.viewport.scroll`; spec/commands.md "scroll-surface").
    ///
    /// It moves the terminal's render viewport, the one every render attach
    /// of the terminal shows: a move announces `scroll-changed` to each,
    /// ordered before the frame with the moved rows, and to every placement
    /// on the event bus. Input snaps it back to the live bottom. Screen reads
    /// for automation (`read-screen`, `wait-for`, `terminal.wait`,
    /// `terminal.screen.read`, `copy`) read the live screen and do not follow
    /// it.
    ///
    /// It also moves the named placement's in-process view by the same delta
    /// ([`Surface::view_scroll_delta`]), the view an in-process TUI shows, so
    /// the command scrolls what that frontend shows too.
    pub fn scroll_surface_viewport(&self, surface: &Surface, delta: isize) -> anyhow::Result<()> {
        let terminal_moved = surface.scroll_delta_moved(delta)?;
        let view_before = surface.view_scrollbar();
        let view_after = surface.view_scroll_delta(delta)?;
        // A terminal move already told every placement. A view-only move
        // (the two positions differ after the in-process frontend scrolled on
        // its own) tells this placement.
        if !terminal_moved
            && view_after != view_before
            && let Some(scrollbar) = view_after
        {
            self.emit(MuxEvent::ScrollChanged {
                surface: surface.id,
                offset: scrollbar.offset,
                at_bottom: !scrollbar.scrolled_back(),
            });
        }
        Ok(())
    }
}
