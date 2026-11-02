//! The host's CPU and RAM budget (cmuxterm-hq#2995): the formula, the verdict,
//! the sampler and the [`Meter`] live in the `cmux-host-budget` crate, which
//! the macOS app links too (cmux-app-ffi), so the daemon and the app judge the
//! host with one implementation. This daemon's `daemon status` `host_pressure`
//! and the warning on a turn's acceptance read [`Meter::shared`]
//! (`hub/views/host_load.rs`). Warns only: nothing is refused, queued or held.

pub use cmux_host_budget::*;
