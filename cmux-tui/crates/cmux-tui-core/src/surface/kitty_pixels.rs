//! What the process Kitty share (`mux/kitty_share.rs`) asks
//! of one terminal: releasing its decoded pixel copies under critical memory
//! pressure.

use std::sync::PoisonError;

use super::*;

impl Surface {
    /// Free the decoded Kitty pixel copies this terminal rebuilds on demand:
    /// the replay encoder's always, and the renderer's (with the frames
    /// holding its pixels) while no render viewer needs them. Nothing
    /// libghostty stores is lost; a cold terminal holds neither copy and
    /// stays cold.
    pub(crate) fn release_kitty_pixel_caches(&self) {
        let Some(pty) = self.as_pty() else { return };
        // The terminal, then the render hub: the order of a limits change.
        let _ = self.try_with_hot_terminal(|terminal| {
            terminal.clear_kitty_replay_pixel_cache();
            let mut render = pty.render.lock().unwrap_or_else(PoisonError::into_inner);
            if render.taps.is_empty() {
                render.state.clear_kitty_graphics_cache();
                render.latest = None;
                render.initial_graphics = None;
                render.final_initial = None;
                // The next render read or attach builds a frame again.
                render.built_generation = 0;
            }
        });
    }

    /// Parse `bytes` as output and mark the frame stale, as the reader does.
    #[cfg(test)]
    pub(crate) fn write_rendered_output_for_test(&self, bytes: &[u8]) {
        let pty = self.as_pty().expect("a PTY surface");
        let mut term = pty.term.lock().unwrap();
        term.vt_write(bytes);
        pty.render_generation.fetch_add(1, Ordering::AcqRel);
    }

    /// Decoded pixel bytes the renderer's cache holds.
    #[cfg(test)]
    pub(crate) fn kitty_render_pixel_bytes_for_test(&self) -> usize {
        self.as_pty().map_or(0, |pty| pty.render.lock().unwrap().state.kitty_pixel_cache_bytes())
    }
}
