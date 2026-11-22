//! Effect receipt commits, on the request thread (`registry_intent`).
//!
//! Lock order: workspace registry -> registry connection -> state. The
//! caller holds the registry across the commit (topology writers stay
//! serialized, so a projected tree cannot go stale before its revision).

use super::*;
use crate::workspace_registry::{
    EffectCommitFinish, EffectCommitIntent, EffectCommitReceipt, RegistryIntent, RegistryReceipt,
};

impl Mux {
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

    /// Commit prepared effect intents in one transaction (all of them or
    /// none), then finish each in order
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
        registry.commit_registry_intent(intent)
    }
}
