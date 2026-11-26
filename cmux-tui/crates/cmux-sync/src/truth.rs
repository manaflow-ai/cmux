//! Which replica the phone believes: "the phone sees whichever is most truthful" (Leo, 2026-11-24,
//! on AutoCloud: a chat that starts on the Mac while its Cloud VM warms, then runs on the VM).
//!
//! The most truthful replica of an object is the one whose state covers the most: a version vector
//! that dominates every other one wins outright. When vectors are concurrent (each holds edits the
//! other lacks, as when the Mac was offline), neither is the whole truth, so the phone reads from
//! the one with more edits and freshest heartbeat and asks the other for its delta, which merging
//! makes the whole truth on the phone itself. A replica not heard from within `stale_ms` is only
//! picked when nothing fresher is left.

use serde::{Deserialize, Serialize};

use crate::vv::Vv;

/// One replica as the phone sees it.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Report {
    /// The replica's name, as the host shows it (`mac`, `vm:abc`).
    pub replica: String,
    pub vv: Vv,
    /// Milliseconds since the phone last heard from it.
    pub age_ms: u64,
}

/// The index of the most truthful report, and the indexes of the others holding edits it lacks
/// (to pull deltas from). `None` when `reports` is empty.
pub fn most_truthful(reports: &[Report], stale_ms: u64) -> Option<(usize, Vec<usize>)> {
    let fresh: Vec<usize> = (0..reports.len()).filter(|&i| reports[i].age_ms < stale_ms).collect();
    let pool: Vec<usize> = if fresh.is_empty() { (0..reports.len()).collect() } else { fresh };
    let best = *pool.iter().max_by(|&&a, &&b| {
        let (ra, rb) = (&reports[a], &reports[b]);
        let a_dominates = ra.vv.dominates(&rb.vv) && ra.vv != rb.vv;
        let b_dominates = rb.vv.dominates(&ra.vv) && ra.vv != rb.vv;
        a_dominates
            .cmp(&b_dominates)
            .then(ra.vv.total().cmp(&rb.vv.total()))
            .then(rb.age_ms.cmp(&ra.age_ms))
            // Reverse so that among full ties the first listed wins.
            .then(b.cmp(&a))
    })?;
    let lacking = (0..reports.len())
        .filter(|&i| i != best && !reports[best].vv.dominates(&reports[i].vv))
        .collect();
    Some((best, lacking))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn rep(name: &str, vv: Vv, age_ms: u64) -> Report {
        Report { replica: name.to_owned(), vv, age_ms }
    }

    #[test]
    fn the_vm_that_took_over_the_chat_is_the_truth_once_it_covers_the_mac() {
        let reports = [
            rep("mac", Vv::from([("mac", 10)]), 100),
            rep("vm", Vv::from([("mac", 10), ("vm", 4)]), 200),
        ];
        assert_eq!(most_truthful(&reports, 30_000), Some((1, vec![])));
    }

    #[test]
    fn concurrent_replicas_pick_the_bigger_and_name_the_other_to_pull_from() {
        let reports = [
            rep("mac", Vv::from([("mac", 12), ("vm", 1)]), 100),
            rep("vm", Vv::from([("mac", 10), ("vm", 9)]), 100),
        ];
        assert_eq!(most_truthful(&reports, 30_000), Some((1, vec![0])));
    }

    #[test]
    fn a_stale_replica_loses_to_a_fresh_one_even_with_more_edits() {
        let reports =
            [rep("vm", Vv::from([("vm", 50)]), 120_000), rep("mac", Vv::from([("mac", 3)]), 50)];
        assert_eq!(most_truthful(&reports, 30_000), Some((1, vec![0])));
        assert_eq!(most_truthful(&[], 30_000), None);
    }
}
