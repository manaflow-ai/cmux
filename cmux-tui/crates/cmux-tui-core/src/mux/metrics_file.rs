//! The daemon's crash-safe metrics file (p09-observability task 131,
//! `diagnostics/persist.rs`).

use std::path::Path;

use cmux_trace::metrics::MetricsOpen;

use super::Mux;
use crate::diagnostics::{DaemonMetrics, daemon_header, metrics_dir};

impl Mux {
    /// Moves the daemon's request, dispatch queue, registry lock and journal
    /// writer histograms into a [`DaemonMetrics`] store, so `server-stats`
    /// reads them from it, and with a state root maps
    /// `<state root>/metrics/metrics-daemon-<pid>.bin` on the one-shot
    /// `cmux-metrics-open` thread. An ephemeral session has no state root: its
    /// counters stay on the heap. Call it once, at startup: a second call
    /// binds nothing and maps no file (a second file of the same pid would
    /// replace the first). The store lives as long as the histograms bound
    /// to it, so the caller may drop what this returns.
    pub fn start_metrics_file(
        &self,
        state_root: Option<&Path>,
    ) -> (DaemonMetrics, Option<MetricsOpen>) {
        let metrics = DaemonMetrics::new(daemon_header());
        let first = self.request_stats.persist_into(&metrics);
        self.workspace_registry.stats().persist_into(&metrics, "registry");
        self.journal_ingress.stats().persist_into(&metrics);
        let open = state_root
            .filter(|_| first)
            .map(|root| metrics.store().open_in_background(metrics_dir(root)));
        (metrics, open)
    }
}
