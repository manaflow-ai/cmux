//! Test support (feature `test-support`): the read-only wrapper
//! [`crate::ReadyScreen`] reads a decoded READY through. A child of the cold
//! codec module only to reach the wrapper's private state; no codec here.

use std::ffi::c_void;
use std::sync::atomic::Ordering;

use super::{Callbacks, NEXT_TERMINAL_ID, Terminal, callbacks, configure_kitty_graphics, sys};
use crate::{Result, check};

impl Terminal {
    /// A wrapper that owns `raw` only to read it: the read methods take the
    /// libghostty state, which is `raw`'s. Its parser-side trackers (C1
    /// normalizer, VT boundary, mouse modes) start fresh and do not match
    /// `raw`, so nothing may write through it; [`crate::ReadyScreen::read`] drops it
    /// before it returns. Frees `raw` on error.
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
            // The scratch handle `new` makes is freed below; only its hooks,
            // sized like `raw`, stay.
            .and_then(|(cols, rows)| Self::new(cols, rows, 0, Callbacks::default()));
        let mut reader = match built {
            Ok(reader) => reader,
            Err(error) => {
                // SAFETY: `raw` is owned here and freed once.
                unsafe { sys::ghostty_terminal_free(raw) };
                return Err(error);
            }
        };
        reader.release_raw();
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
