//! Part of `Hub`; see `hub/mod.rs`. When each live model list was last asked
//! for, so a read of `_acpmux/models` can ask again once a list is old.
//!
//! A CLI's model list changes without the CLI changing: Claude Code read
//! claude-fable-5-2 from its gateway on Nov 9 while the daemon, started days
//! before, still served the list its start-up probe got. A list older than
//! [`LIVE_MAX_AGE`] is probed again in the background on the next read.

use std::collections::{BTreeSet, HashMap};
use std::time::{Duration, Instant};

/// How old a live list may be before a read probes its CLI again.
pub(super) const LIVE_MAX_AGE: Duration = Duration::from_secs(15 * 60);

/// The time each harness's live probe last started, by profile name.
#[derive(Debug, Default)]
pub(crate) struct LiveAges {
    started: HashMap<String, Instant>,
}

impl LiveAges {
    /// Records that `harness`'s probe starts at `now`.
    pub(crate) fn started(&mut self, harness: &str, now: Instant) {
        self.started.insert(harness.to_owned(), now);
    }

    /// The harnesses of `names` whose last probe started `LIVE_MAX_AGE` or
    /// more before `now`, each marked as started now so concurrent reads start
    /// one probe. A harness never probed is left to the start-up probe.
    pub(crate) fn claim_due<'a>(
        &mut self,
        names: impl IntoIterator<Item = &'a str>,
        now: Instant,
    ) -> BTreeSet<String> {
        let mut due = BTreeSet::new();
        for name in names {
            let Some(at) = self.started.get_mut(name) else { continue };
            if now.saturating_duration_since(*at) >= LIVE_MAX_AGE {
                *at = now;
                due.insert(name.to_owned());
            }
        }
        due
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn an_old_list_is_due_once_and_a_fresh_or_unprobed_one_is_not() {
        let t0 = Instant::now();
        let mut ages = LiveAges::default();
        ages.started("claude", t0);
        ages.started("codex", t0 + Duration::from_secs(10 * 60));
        let later = t0 + LIVE_MAX_AGE + Duration::from_secs(1);
        let due = ages.claim_due(["claude", "codex", "never"], later);
        assert_eq!(due, BTreeSet::from(["claude".to_owned()]));
        // A second read while that probe runs starts no other.
        assert!(ages.claim_due(["claude"], later + Duration::from_secs(5)).is_empty());
        // Once it is old again, it is due again.
        let again = later + LIVE_MAX_AGE;
        assert_eq!(ages.claim_due(["claude"], again), BTreeSet::from(["claude".to_owned()]));
    }
}
