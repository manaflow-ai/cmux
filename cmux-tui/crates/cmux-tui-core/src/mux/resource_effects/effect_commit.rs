//! Effect receipts committed on the request thread (registry_intent).
//!
//! Lock order: workspace registry -> registry connection -> state. The
//! caller holds the registry across the commit (topology writers stay
//! serialized, so a projected tree cannot go stale before its revision).
//! The journal writer takes neither the registry nor state
//! (`write_path.writer_registry_locks` in `server-stats` stays 0).

use super::*;
use crate::workspace_registry::{
    EffectCommitFinish, EffectCommitIntent, EffectCommitReceipt, RegistryIntent,
};

impl Mux {
    /// Commit a prepared effect intent and finish it under `registry`.
    pub(crate) fn commit_effect_intent(
        &self,
        registry: &mut WorkspaceRegistry,
        intent: EffectCommitIntent,
        finish: EffectCommitFinish,
    ) -> anyhow::Result<EffectCommitReceipt> {
        let receipt =
            registry.commit_registry_intent(RegistryIntent::Effect(intent))?.into_effect()?;
        registry.finish_effect_commit(finish, receipt)
    }
}
