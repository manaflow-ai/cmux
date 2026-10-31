//! Test support (feature `test-support`): the read-only wrapper
//! [`crate::ReadyScreen`] reads a decoded READY through. A child of the
//! terminal module only to reach the wrapper's private state.

use std::ffi::c_void;
use std::ptr;
use std::sync::atomic::Ordering;

use super::{Callbacks, NEXT_TERMINAL_ID, Terminal, callbacks, configure_kitty_graphics, sys};
use crate::{Result, check};

impl Terminal {
    /// A wrapper that owns `raw` only to read it. Its parser-side trackers
    /// start fresh and do not match `raw`, so nothing may write through its
    /// `vt_write` methods: [`crate::ReadyScreen::read`] writes stream bytes
    /// to the raw handle directly and drops the wrapper before it returns.
    /// Frees `raw` on error.
    pub(crate) fn reader_over(raw: sys::GhosttyTerminal) -> Result<Self> {
        let size = |data| {
            let mut out = 0u16;
            // SAFETY: `raw` is live; COLS and ROWS are uint16_t outputs.
            check(unsafe {
                sys::ghostty_terminal_get(raw, data, (&mut out as *mut u16).cast::<c_void>())
            })
            .map(|()| out)
        };
        let built = size(sys::GHOSTTY_TERMINAL_DATA_COLS)
            .and_then(|cols| Ok((cols, size(sys::GHOSTTY_TERMINAL_DATA_ROWS)?)))
            .and_then(|(cols, rows)| Self::new(cols, rows, 0, Callbacks::default()));
        let mut reader = match built {
            Ok(reader) => reader,
            Err(error) => {
                // SAFETY: `raw` is owned here and freed once.
                unsafe { sys::ghostty_terminal_free(raw) };
                return Err(error);
            }
        };
        // Free the scratch terminal `new` made (as Drop does), then adopt `raw`.
        // SAFETY: `reader.raw` is the live scratch terminal and its anchor;
        // the trampolines are cleared before it is freed.
        unsafe {
            sys::ghostty_tracked_grid_ref_free(reader.history_anchor);
            reader.history_markers.release();
            callbacks::uninstall(reader.raw);
            sys::ghostty_terminal_free(reader.raw);
        }
        reader.history_anchor = ptr::null_mut();
        reader.raw = raw;
        reader.instance_id = NEXT_TERMINAL_ID.fetch_add(1, Ordering::Relaxed);
        // SAFETY: `hooks` is heap-pinned for the wrapper's lifetime, and Drop
        // uninstalls the trampolines before the terminal is freed.
        unsafe { callbacks::install(raw, &mut reader.hooks) };
        configure_kitty_graphics(raw)?;
        reader.reset_history_anchor();
        Ok(reader)
    }
}
