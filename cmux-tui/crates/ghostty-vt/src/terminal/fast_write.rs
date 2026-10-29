//! The tracker pass of [`Terminal::vt_write_with_normalized`] and its
//! byte-at-a-time reference, kept apart from `terminal.rs`.

use std::borrow::Cow;

use super::{Terminal, byte_scan, sys};

impl Terminal {
    /// Feeds the accepted bytes to every tracker in one pass. The trackers
    /// never read one another, so stepping them byte by byte together equals
    /// running them one after another. While all of them are idle, a neutral
    /// run (see `byte_scan::neutral_run_end`) is skipped: it leaves every one
    /// idle and only clears the boundary tracker's pending bytes.
    /// `mux2-wrapcheck` compares this with the reference path.
    pub(super) fn feed_trackers(&mut self, data: &[u8]) -> bool {
        let mut mouse_modes_may_have_changed = false;
        let mut at = 0;
        while let Some(&byte) = data.get(at) {
            if self.trackers_idle() {
                let line_ends_neutral = !self.prompt_semantic.waits_for_line_end();
                let end = byte_scan::neutral_run_end(data, at, line_ends_neutral);
                if end > at {
                    self.vt_boundary.clear_pending();
                    at = end;
                    continue;
                }
            }
            self.kitty_inflight.step(byte);
            self.vt_boundary.step(byte);
            self.prompt_semantic.step(byte);
            self.cursor_override.step(byte);
            self.palette_override.step(byte);
            self.color_overrides.step(byte);
            mouse_modes_may_have_changed |= self.mouse_mode_change_detector.step(byte);
            at += 1;
        }
        mouse_modes_may_have_changed
    }

    fn trackers_idle(&self) -> bool {
        self.kitty_inflight.is_ground()
            && self.vt_boundary.is_safe()
            && self.prompt_semantic.is_ground()
            && self.cursor_override.is_ground()
            && self.palette_override.is_ground()
            && self.color_overrides.is_idle()
            && self.mouse_mode_change_detector.is_idle()
    }

    /// The original byte-at-a-time form of [`Self::vt_write_with_normalized`],
    /// kept so a check can feed the same bytes through both and require
    /// identical results. Not for production use.
    #[doc(hidden)]
    pub fn vt_write_with_normalized_reference<'a>(&mut self, data: &'a [u8]) -> Cow<'a, [u8]> {
        if data.is_empty() {
            return Cow::Borrowed(data);
        }
        self.ensure_history_anchor();
        let previous_history_rows = self.scrollback_rows();
        let history_anchor_missing = previous_history_rows > 0 && self.history_anchor.is_null();
        let normalized = self.c1_normalizer.normalize_reference(data);
        let normalized = self.empty_kitty_probe_filter.write_reference(normalized);
        self.kitty_inflight.write_reference(&normalized);
        self.vt_boundary.feed_reference(&normalized);
        self.prompt_semantic.feed_reference(&normalized);
        self.cursor_override.write_reference(&normalized);
        self.palette_override.write_reference(&normalized);
        self.color_overrides.write_reference(&normalized);
        let mouse_modes_may_have_changed =
            self.mouse_mode_change_detector.write_reference(&normalized);
        self.history_markers_before_write();
        // SAFETY: `self.raw` is this Terminal's live handle; `normalized` is
        // readable for `normalized.len()` bytes for the call.
        unsafe { sys::ghostty_terminal_vt_write(self.raw, normalized.as_ptr(), normalized.len()) };
        self.history_markers_after_write();
        let history_rows = self.scrollback_rows();
        let history_anchor_evicted = !self.history_anchor.is_null()
            // SAFETY: `history_anchor` is a non-null anchor this Terminal owns.
            && !unsafe { sys::ghostty_tracked_grid_ref_has_value(self.history_anchor) };
        if previous_history_rows != history_rows || history_anchor_missing || history_anchor_evicted
        {
            self.bump_history_epoch();
        }
        if history_rows == 0 || history_anchor_evicted {
            self.reset_history_anchor();
        } else if self.history_anchor.is_null() {
            self.ensure_history_anchor();
        }
        if mouse_modes_may_have_changed {
            self.refresh_mouse_mode_revision();
        }
        normalized
    }
}
