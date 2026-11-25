//! Sans-I/O logic shared by the cmux iOS and Android apps.
//!
//! Bytes and events go in, state and effects come out; this crate does no
//! I/O, spawns no threads and owns no runtime, except [`read_store`], the
//! phone's own read-first store (plain `std::fs` on one directory the app
//! names). `cmux-mobile-ffi` binds it for
//! Swift and Kotlin with uniffi. Network effects belong in `cmux-mobile-net`.
//!
//! Slice 0 of plans/cmux-next/mobile-rust-core.md carries the shared terminal
//! sizing reducer; object-sync phase 1 (plans/cmux-next/object-sync/DESIGN.md)
//! adds the `cmux.wire/1` stream mirror. Later slices add the Home mirror and
//! the terminal frame codecs.

#![forbid(unsafe_code)]

/// The shared terminal sizing reducer and its wire types
/// (`docs/shared-terminal-sizing.md`).
pub use cmux_terminal_sizing as sizing;

/// The `cmux.wire/1` client: catalog wire types and the stream mirror with
/// its intent log (`StreamMirror`), the engine the Mac daemon uses too.
pub use cmux_cloud_wire as wire;

/// Background delta sync: the cursor each surface is answered by, and the
/// bounded requests of one wake (`cmux-next-ios/design/background-delta-sync.md`).
pub mod catch_up;

/// The phone's own read-first store: what a surface last showed, kept per
/// account, Mac and surface so a cold launch draws it before the Mac answers.
pub mod read_store;
