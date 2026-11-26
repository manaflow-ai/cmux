//! When a pane's live thumbnail (the picture a hover card shows) must be captured again.
//!
//! The macOS app captures; this crate decides when ([`schedule`]) and its C ABI ([`ffi`],
//! `include/cmux_pane_pictures.h`, Swift module `CCmuxPanePicturesFFI`) is linked through
//! cmux-app-ffi. No dependencies, no clock, no timers, no threads.

pub mod ffi;
pub mod schedule;
