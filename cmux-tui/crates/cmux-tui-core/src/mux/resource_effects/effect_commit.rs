//! Effect receipt commits through the journal writer batch.
//!
//! Lock order: workspace registry -> registry connection -> state. The
//! caller holds the registry across the receipt wait (topology writers stay
//! serialized, so a projected tree cannot go stale before its revision) but
//! neither the connection nor state: the journal writer needs the
//! connection to commit, and state is never held across a writer fsync. The
//! writer takes only the connection lock (`write_path.writer_registry_locks`
//! in `server-stats` stays 0). The wait is bounded (see
//! `journal_ingress::effect_intents`): a writer error, a dropped receipt or
//! an expired deadline returns an error, and the caller's registry guard
//! drops with it.

use super::*;
use crate::journal_ingress::EffectSend;
use crate::workspace_registry::{EffectCommitFinish, EffectCommitIntent, EffectCommitReceipt};

impl Mux {
    /// Commit a prepared effect intent and finish it under `registry`.
    pub(super) fn commit_effect_intent(
        &self,
        registry: &mut WorkspaceRegistry,
        intent: EffectCommitIntent,
        finish: EffectCommitFinish,
    ) -> anyhow::Result<EffectCommitReceipt> {
        // A thread that still holds the connection (a pin, a guard) would
        // block the writer it waits for: commit locally instead. The
        // request_effect_commits counter makes any such caller visible.
        let receipt = if self.registry_connection.is_held_by_current_thread() {
            registry.commit_effect_intent_locally(&intent)?
        } else {
            match self.journal_ingress.send_effect(intent) {
                EffectSend::Sent(Ok(receipt)) => receipt,
                EffectSend::Sent(Err(error)) => {
                    // The receipt may be indeterminate: the writer can still
                    // commit after this request gives up. Drop the public
                    // fold and wake journal subscribers, who read the head.
                    registry.abandon_effect_commit();
                    self.publish_journal_event();
                    return Err(error);
                }
                EffectSend::NotQueued(intent) => registry.commit_effect_intent_locally(&intent)?,
            }
        };
        registry.finish_effect_commit(finish, receipt)
    }
}
