//! The Kitty image generation of a terminal: libghostty-vt
//! `ghostty_terminal_kitty_image_generation`. GHOSTSNP carries the images
//! themselves (KITTY_IMAGE_STORAGE and KITTY_IMAGE_PAYLOAD records).

use ghostty_vt_sys as sys;

use crate::terminal::Terminal;
use crate::{Result, check};

impl Terminal {
    /// The Kitty image generation: it strictly increases at every change of
    /// the stored images or placements of either screen. Zero means the
    /// image storage never changed. Process-local value.
    pub fn kitty_image_generation(&self) -> Result<u64> {
        let mut generation = 0u64;
        // The out-pointer is valid for the call; the caller owns the
        // terminal (`&self`).
        check(unsafe {
            sys::ghostty_terminal_kitty_image_generation(self.raw(), &mut generation)
        })?;
        Ok(generation)
    }
}
