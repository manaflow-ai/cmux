//! The `Mux` reads of `oracle-state` (`crate::oracle_state`): debug and
//! `--features oracle` builds only.

use super::Mux;
use crate::oracle_state::{SwitchArms, launch_switch_arms};

impl Mux {
    /// Live event subscriptions.
    pub(crate) fn live_event_subscriber_count(&self) -> usize {
        self.subscribers.live_subscriber_count()
    }

    /// The holders of this session that ended since this owner started.
    pub(crate) fn oracle_holder_exits(&self) -> u64 {
        self.oracle_holder_exits.load(std::sync::atomic::Ordering::Relaxed)
    }

    /// The daemon's refactor switch arms: the launch value, frozen at the
    /// first read, unless a test installed others before it.
    pub(crate) fn oracle_switches(&self) -> &SwitchArms {
        self.oracle_switches.get_or_init(launch_switch_arms)
    }

    /// The restore preview of the checkpoint `selector` names, reduced
    /// through `through` (a journal head an `oracle-state` reply gave, so
    /// the preview is that reply's cut) or the journal head, on a read-only
    /// journal reader of its own: no registry lock and no wait on the
    /// journal writer. `latest` is the latest checkpoint at or before
    /// `through`. `None` when the session has no such checkpoint.
    pub(crate) fn oracle_restore_preview(
        &self,
        selector: &str,
        through: Option<u64>,
    ) -> anyhow::Result<Option<serde_json::Value>> {
        let reader = self.journal_kernel.open_reader()?.ok_or_else(|| {
            anyhow::anyhow!("oracle restore preview requires a persistent session")
        })?;
        let Some(checkpoint) = reader.journal_checkpoint(selector, through)? else {
            return Ok(None);
        };
        if let Some(through) = through {
            anyhow::ensure!(
                checkpoint.source_sequence <= through,
                "journal checkpoint {selector:?} is after journal sequence {through}"
            );
        }
        crate::journal_checkpoint::restore_preview_on_reader(&checkpoint, reader, through).map(Some)
    }

    /// Install `arms` before the first [`Self::oracle_switches`] read.
    #[cfg(test)]
    pub(crate) fn install_oracle_switches_for_test(&self, arms: SwitchArms) {
        assert!(self.oracle_switches.set(arms).is_ok(), "switch arms already frozen");
    }
}
