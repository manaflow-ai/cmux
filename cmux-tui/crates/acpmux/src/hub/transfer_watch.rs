//! Part of `Hub`; see `hub/mod.rs`. A move whose client went away (`transfer_out.rs`).

use super::*;

/// How long a move may go without its client before the source ends it.
pub(super) const TRANSFER_LEASE: std::time::Duration = std::time::Duration::from_secs(300);

impl Hub {
    /// How long a move may go without its client before the source ends it (tests shorten it).
    pub fn set_transfer_lease(&self, lease: std::time::Duration) {
        *self.transfer_lease.lock().unwrap_or_else(|e| e.into_inner()) = lease;
    }
}
