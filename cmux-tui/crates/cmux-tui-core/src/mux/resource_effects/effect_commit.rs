//! Registry commits through the journal writer batch.
//!
//! Lock order: workspace registry -> registry connection -> state. The
//! caller holds the registry across the receipt wait (topology writers stay
//! serialized, so a projected tree cannot go stale before its revision) but
//! never the connection: the journal writer needs the connection to commit.
//! The writer takes neither the registry nor state
//! (`write_path.writer_registry_locks` in `server-stats` stays 0). The wait
//! is bounded (see `journal_ingress::effect_intents`): a writer error, a
//! dropped receipt or an expired deadline returns an error, and the caller's
//! registry guard drops with it.

use std::sync::Weak;

use super::*;
use crate::journal_ingress::EffectSend;
use crate::workspace_registry::{
    EffectCommitFinish, EffectCommitIntent, EffectCommitReceipt, RegistryIntent,
    RegistryIntentSink, RegistryReceipt,
};

/// The journal writer as the registry's intent sink. It holds the mux
/// weakly: the registry connection must not keep the mux alive.
pub(crate) struct MuxIntentSink(pub(crate) Weak<Mux>);

impl RegistryIntentSink for MuxIntentSink {
    fn accepts(&self) -> bool {
        self.0.upgrade().is_some_and(|mux| mux.journal_ingress.accepts_effects())
    }

    fn send(&self, intent: RegistryIntent) -> EffectSend {
        match self.0.upgrade() {
            Some(mux) => mux.journal_ingress.send_effect(intent),
            None => EffectSend::NotQueued(Box::new(intent)),
        }
    }
}

impl Mux {
    /// Send registry commits to the journal writer from now on (called when
    /// the writer starts).
    pub(crate) fn install_registry_intent_sink(self: &Arc<Self>) {
        self.registry_connection.install_intent_sink(Arc::new(MuxIntentSink(Arc::downgrade(self))));
    }

    /// Commit a prepared effect intent and finish it under `registry`.
    pub(crate) fn commit_effect_intent(
        &self,
        registry: &mut WorkspaceRegistry,
        intent: EffectCommitIntent,
        finish: EffectCommitFinish,
    ) -> anyhow::Result<EffectCommitReceipt> {
        let receipt = self.committed_registry_intent(registry, RegistryIntent::Effect(intent))?;
        registry.finish_effect_commit(finish, receipt.into_effect()?)
    }

    /// Commit prepared effect intents in one transaction (one journal
    /// writer savepoint: all of them or none), then finish each in order
    /// under `registry`.
    pub(crate) fn commit_effect_intents(
        &self,
        registry: &mut WorkspaceRegistry,
        intents: Vec<EffectCommitIntent>,
        finishes: Vec<EffectCommitFinish>,
    ) -> anyhow::Result<Vec<EffectCommitReceipt>> {
        let receipts = self
            .committed_registry_intent(registry, RegistryIntent::EffectGroup(intents))?
            .into_effect_group()?;
        anyhow::ensure!(
            receipts.len() == finishes.len(),
            "an effect group commit answered {} receipts for {} intents",
            receipts.len(),
            finishes.len()
        );
        finishes
            .into_iter()
            .zip(receipts)
            .map(|(finish, receipt)| registry.finish_effect_commit(finish, receipt))
            .collect()
    }

    fn committed_registry_intent(
        &self,
        registry: &mut WorkspaceRegistry,
        intent: RegistryIntent,
    ) -> anyhow::Result<RegistryReceipt> {
        registry.commit_registry_intent(intent).inspect_err(|error| {
            // An indeterminate receipt: the writer can still commit after
            // this request gives up. Wake journal subscribers, who read the
            // head. Any other error committed nothing.
            if error.downcast_ref::<crate::journal_ingress::JournalCommitIndeterminate>().is_some()
            {
                self.publish_journal_event();
            }
        })
    }

    /// Apply the receipts of earlier indeterminate registry commits that
    /// arrived since (cx-g1fa.3): each one's owed state update, then raise
    /// the in-memory revisions to what the journal committed. The caller
    /// holds the registry and `state`.
    pub(crate) fn settle_registry_receipts(&self, registry: &WorkspaceRegistry, state: &mut State) {
        let settled = registry.connection.take_settled_receipts();
        if settled.is_empty() {
            return;
        }
        for (receipt, settle) in settled {
            settle_one(state, &receipt, settle);
        }
        // Subscribers read the new head. Only the journal event: the
        // caller holds the registry and state, and publish_resource_event
        // also publishes pending terminal directories, which takes state
        // (a self-deadlock here) and then the registry. A directory still
        // pending is published by the terminal's next output or the next
        // committed graph change.
        self.publish_journal_event();
    }
}

fn settle_one(
    state: &mut State,
    receipt: &RegistryReceipt,
    settle: Option<crate::workspace_registry::SettleState>,
) {
    let (resource_revision, workspace_revision) =
        (state.resource_revision, state.workspace_revision);
    if let Some(settle) = settle {
        settle(state, receipt);
    }
    // A later commit may already have installed a higher revision.
    state.resource_revision = state
        .resource_revision
        .max(resource_revision)
        .max(receipt.resource_revision().unwrap_or(0));
    state.workspace_revision = state.workspace_revision.max(workspace_revision);
}
