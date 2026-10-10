//! Sans-I/O logic shared by the cmux iOS and Android apps.
//!
//! Bytes and events go in, state and effects come out; this crate does no
//! I/O, spawns no threads and owns no runtime. `cmux-mobile-ffi` binds it for
//! Swift and Kotlin with uniffi. Network effects belong in `cmux-mobile-net`.
//!
//! Slice 0 of plans/cmux-next/mobile-rust-core.md carries the shared terminal
//! sizing reducer only. Later slices add the catalog wire client, the Home
//! mirror and the terminal frame codecs.

#![forbid(unsafe_code)]

/// The shared terminal sizing reducer and its wire types
/// (`docs/shared-terminal-sizing.md`).
pub use cmux_terminal_sizing as sizing;
