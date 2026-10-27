//! Prototype from the cmux remote transport plan
//! (`docs/remote-transport/PLAN.md`): gzip-compressed, cursor-paginated
//! transcript pages.
//!
//! A transcript stream is meant to open as a new `Service` through the
//! existing `ServiceControl::Open` in `cmux-remote-protocol`; this crate only
//! owns the page codec, sans-I/O, so the daemon, the app FFI and tests share it.

#![forbid(unsafe_code)]

mod transcript;

pub use transcript::*;
