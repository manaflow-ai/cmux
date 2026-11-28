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
    let fresh: Vec<usize> = reports
        .iter()
        .enumerate()
        .filter(|(_, report)| report.age_ms < stale_ms)
        .map(|(i, _)| i)
        .collect();
    let pool: Vec<usize> = if fresh.is_empty() { (0..reports.len()).collect() } else { fresh };
    let best = *pool.iter().max_by(|&&a, &&b| {
        let (Some(ra), Some(rb)) = (reports.get(a), reports.get(b)) else {
            return std::cmp::Ordering::Equal;
        };
        let a_dominates = ra.vv.dominates(&rb.vv) && ra.vv != rb.vv;
        let b_dominates = rb.vv.dominates(&ra.vv) && ra.vv != rb.vv;
        a_dominates
            .cmp(&b_dominates)
            .then(ra.vv.total().cmp(&rb.vv.total()))
            .then(rb.age_ms.cmp(&ra.age_ms))
            // Reverse so that among full ties the first listed wins.
            .then(b.cmp(&a))
    })?;
    let best_report = reports.get(best)?;
    let lacking = reports
        .iter()
        .enumerate()
        .filter(|(i, report)| *i != best && !best_report.vv.dominates(&report.vv))
        .map(|(i, _)| i)
        .collect();
    Some((best, lacking))
}

#[cfg(test)]
#[path = "truth_tests.rs"]
mod tests;
