//! Part of `Hub`; see `hub/mod.rs`. Harness profile hot reload (slice 2b).

use super::*;

impl Hub {
    /// Watches the harness profile sources and reloads the catalog on a change.
    pub fn start_harness_watch(self: &Arc<Self>) {}
}
