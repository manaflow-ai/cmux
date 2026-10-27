//! Ranked locks shared by acpmux and the cmux-tui daemon.
//!
//! p10-stability-101 adds this crate to the workspace and to its consumers'
//! manifests so the lock file does not change again; p10-stability-187 moves
//! `RankedMutex` and the rank checks here from `cmux-tui-core::lock_rank`.

#![forbid(unsafe_code)]
