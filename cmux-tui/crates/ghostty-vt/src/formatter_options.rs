//! Formatter options as one value, for libghostty-vt 1.0.
//!
//! libghostty-vt 1.0 dropped the `GhosttyFormatterTerminalOptions` struct
//! that `ghostty_formatter_terminal_new` took: a new formatter starts with
//! defaults, and each option is set with `ghostty_formatter_set`. Its
//! defaults differ from the old zeroed struct (extras default to palette,
//! style and hyperlink, and trim to true), so [`FormatterTerminalOptions::new_formatter`]
//! sets every option, and an all-false extra means no extras, as before.

use std::ptr;

use crate::sys;
use crate::{Result, check};

/// The extras of the active screen (old `GhosttyFormatterScreenExtra`).
#[derive(Clone, Copy, Debug, Default)]
pub(crate) struct FormatterScreenExtra {
    pub cursor: bool,
    pub style: bool,
    pub hyperlink: bool,
    pub protection: bool,
    pub kitty_keyboard: bool,
    pub charsets: bool,
}

/// The extras of the terminal (old `GhosttyFormatterTerminalExtra`).
#[derive(Clone, Copy, Debug, Default)]
pub(crate) struct FormatterTerminalExtra {
    pub palette: bool,
    pub modes: bool,
    pub scrolling_region: bool,
    pub tabstops: bool,
    pub pwd: bool,
    pub keyboard: bool,
    pub screen: FormatterScreenExtra,
}

impl FormatterTerminalExtra {
    /// The `GHOSTTY_FORMATTER_EXTRA_*` bits these flags name (formatter.h;
    /// written out here because the header's macros are `1u << n`, which
    /// not every bindgen version translates).
    pub(crate) fn bits(&self) -> sys::GhosttyFormatterExtras {
        let mut bits: sys::GhosttyFormatterExtras = 0;
        for (bit, on) in [
            self.palette,
            self.modes,
            self.scrolling_region,
            self.tabstops,
            self.pwd,
            self.keyboard,
            self.screen.cursor,
            self.screen.style,
            self.screen.hyperlink,
            self.screen.protection,
            self.screen.kitty_keyboard,
            self.screen.charsets,
        ]
        .into_iter()
        .enumerate()
        {
            if on {
                bits |= 1 << bit;
            }
        }
        bits
    }
}

/// What the old `GhosttyFormatterTerminalOptions` held.
#[derive(Clone, Copy, Debug)]
pub(crate) struct FormatterTerminalOptions {
    pub emit: sys::GhosttyFormatterFormat,
    pub unwrap: bool,
    pub trim: bool,
    pub extra: FormatterTerminalExtra,
    /// Restricts the output to this selection; null formats the whole screen.
    /// It must stay valid until [`Self::new_formatter`] returns (the
    /// formatter keeps its own copy).
    pub selection: *const sys::GhosttySelection,
}

impl FormatterTerminalOptions {
    /// A formatter for `terminal` with every one of these options set. The
    /// caller frees it with `ghostty_formatter_free`.
    pub(crate) fn new_formatter(
        &self,
        terminal: sys::GhosttyTerminal,
    ) -> Result<sys::GhosttyFormatter> {
        let mut formatter: sys::GhosttyFormatter = ptr::null_mut();
        check(unsafe {
            sys::ghostty_formatter_terminal_new(ptr::null(), &mut formatter, terminal)
        })?;
        if let Err(error) = self.apply(formatter) {
            unsafe { sys::ghostty_formatter_free(formatter) };
            return Err(error);
        }
        Ok(formatter)
    }

    fn apply(&self, formatter: sys::GhosttyFormatter) -> Result<()> {
        let extras = self.extra.bits();
        let set = |option: sys::GhosttyFormatterOption, value: *const std::ffi::c_void| {
            check(unsafe { sys::ghostty_formatter_set(formatter, option, value) })
        };
        set(
            sys::GHOSTTY_FORMATTER_OPT_EMIT,
            (&self.emit as *const sys::GhosttyFormatterFormat).cast(),
        )?;
        set(sys::GHOSTTY_FORMATTER_OPT_UNWRAP, (&self.unwrap as *const bool).cast())?;
        set(sys::GHOSTTY_FORMATTER_OPT_TRIM, (&self.trim as *const bool).cast())?;
        set(
            sys::GHOSTTY_FORMATTER_OPT_EXTRAS,
            (&extras as *const sys::GhosttyFormatterExtras).cast(),
        )?;
        if !self.selection.is_null() {
            set(sys::GHOSTTY_FORMATTER_OPT_SELECTION, self.selection.cast())?;
        }
        Ok(())
    }
}
