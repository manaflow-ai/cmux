//! Owned lifecycle transitions. The core has no transport or runtime dependency.
//!
//! Each adapter supplies authoritative observations and performs I/O; the core
//! keeps the ordering of those operations explicit in its types.

pub mod vm;
