//! Part of `Hub`; see `hub/mod.rs`. The model call of surge triage (`crate::surge_triage`):
//! one batch, one headless completion on the harness's small model (`complete_own`: Claude's
//! Haiku, Codex's small model), its answer read only as per-message picks. A failed call
//! leaves every message `needYou`, so a model outage never hides a message from its owner.

use super::Hub;
use crate::surge_triage::{self, Batch, Disposition};
use std::sync::Arc;
use std::time::Duration;

impl Hub {
    /// The dispositions of `batch`, through `harness` (None: the default harness). The caller
    /// (the surge holder) appends [`surge_triage::triaged_record`] and posts
    /// [`surge_triage::forum_inputs`] to the batch's own recipient.
    #[allow(dead_code, reason = "the surge holder (forum-surge-inbox root lane) calls it")]
    pub(crate) async fn surge_triage_batch(
        self: &Arc<Self>,
        harness: Option<&str>,
        batch: &Batch,
    ) -> Vec<Disposition> {
        if batch.messages.is_empty() {
            return Vec::new();
        }
        let prompt = surge_triage::prompt(batch);
        let timeout = Duration::from_millis(surge_triage::TIMEOUT_MS);
        let answer =
            match self.complete_own(harness, prompt, surge_triage::MAX_TOKENS, timeout).await {
                Ok(text) => Some(text),
                Err(e) => {
                    tracing::info!(
                        recipient = %batch.recipient,
                        batch = %batch.batch_id,
                        reason = e.reason(),
                        "surge triage: no model answer; every message reaches its owner"
                    );
                    None
                }
            };
        surge_triage::dispositions(batch, answer.as_deref())
    }
}
