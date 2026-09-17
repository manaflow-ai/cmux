//! Raw FFI bindings to libghostty-vt.
//!
//! The static library is compiled from the `ghostty/` submodule at build
//! time (see build.rs) and the bindings are generated with bindgen from
//! `ghostty/include/ghostty/vt.h`.

#![allow(non_upper_case_globals)]
#![allow(non_camel_case_types)]
#![allow(non_snake_case)]
#![allow(unsafe_op_in_unsafe_fn)]
#![allow(clippy::all)]

include!(concat!(env!("OUT_DIR"), "/bindings.rs"));

/// Reimplementation of the `ghostty_mode_new` static inline helper from
/// `modes.h` (bindgen does not emit static inline functions).
#[inline]
pub const fn ghostty_mode_new(value: u16, ansi: bool) -> GhosttyMode {
    (value & 0x7FFF) | ((ansi as u16) << 15)
}
