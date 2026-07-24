//! This module provides platform related functions.

#[cfg(unix)]
pub(crate) use self::unix::{
    disable_raw_mode, enable_raw_mode, is_raw_mode_enabled, size, window_size,
};
#[cfg(unix)]
#[cfg(feature = "events")]
pub use self::unix::{query_keyboard_enhancement_flags, supports_keyboard_enhancement};
#[cfg(all(windows, test))]
pub(crate) use self::windows::temp_screen_buffer;
#[cfg(windows)]
pub(crate) use self::windows::{
    clear, disable_raw_mode, enable_raw_mode, is_raw_mode_enabled, scroll_down, scroll_up,
    set_size, set_window_title, size, window_size,
};
#[cfg(windows)]
#[cfg(feature = "events")]
pub use self::windows::{query_keyboard_enhancement_flags, supports_keyboard_enhancement};

#[cfg(windows)]
mod windows;

#[cfg(unix)]
pub mod file_descriptor;
#[cfg(unix)]
mod unix;
