//! Part of `Hub`; see `hub/mod.rs`. `_acpmux/status_changed {}`: tells watching clients
//! that `_acpmux/status`'s host list (`peers`) or `webUrl` changed, so they read it again
//! instead of polling it. A peer added, reconnected, leased, connected, dropped or
//! removed, or a rotated web token, marks it. One watch value per daemon: marks made
//! before a connection reads it fold into one notification (`server/fanout.rs`).

use super::*;

/// The mark count; only its changes matter.
pub(crate) struct StatusFeed(tokio::sync::watch::Sender<u64>);

impl Default for StatusFeed {
    fn default() -> Self {
        Self(tokio::sync::watch::channel(0).0)
    }
}

impl Hub {
    /// Marks `_acpmux/status` changed for every watching connection.
    pub(crate) fn status_changed(&self) {
        self.status_feed.0.send_modify(|marks| *marks = marks.wrapping_add(1));
    }

    /// A connection's view of the marks: `changed()` resolves once for any number of
    /// marks since the last read.
    pub(crate) fn subscribe_status_changes(&self) -> tokio::sync::watch::Receiver<u64> {
        self.status_feed.0.subscribe()
    }
}

#[cfg(test)]
#[path = "status_feed_tests.rs"]
mod tests;
