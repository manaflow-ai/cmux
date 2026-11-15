//! Compaction of a live chat's sealed log segments (`hub/sealed_compaction.rs`).

use super::*;

/// [`Store::on_segment_sealed`]'s hook.
pub type SealHook = std::sync::Arc<dyn Fn(&str) + Send + Sync>;

/// Compacted copies of sealed segments, written beside them and not yet in place.
pub struct StagedSealed {
    stats: Compaction,
}

impl StagedSealed {
    /// What the commit would change.
    pub fn stats(&self) -> Compaction {
        self.stats
    }
}
