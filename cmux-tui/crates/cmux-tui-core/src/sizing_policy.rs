//! Shared terminal sizing reducer, re-exported from `cmux-terminal-sizing`.
//!
//! The reducer lives in its own dependency-light crate so the mobile core
//! (`cmux-mobile-core`) links it without this crate's PTY, SQLite and Ghostty
//! dependencies. `crate::sizing_policy::*` paths stay valid.

pub use cmux_terminal_sizing::*;
