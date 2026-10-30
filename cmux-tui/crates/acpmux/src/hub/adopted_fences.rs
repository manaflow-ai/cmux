//! Part of `Hub`; see `hub/mod.rs`. The fences of the lines a previous daemon handed an agent
//! host, held again at adoption (#23322 a3 fence, the residual risk of #26241): a host logs a
//! line before its stdin writer writes it, so a family line may still wait for a harness that
//! reads nothing when the daemon restarts. Held again under the family gate, an MDM off push
//! waits for each, then cuts it by ending its host, as for a line this daemon sent.

use super::full_access_bound::{FAMILY_WRITE_BUDGET, FamilyHold};
use super::hosts::OpenWork;
use super::*;
use crate::agent_host;

impl Hub {
    /// [`Self::hold_until_written`] for `fences` already made: one hold for all of them (a
    /// restart's, `hold_unwritten`, or an adoption's, `adopt_one`), so no push takes the gate between two of them.
    pub(super) fn hold_fences(
        session_id: &str,
        hold: FamilyHold,
        fences: Vec<crate::agent::Fence>,
    ) {
        if fences.is_empty() {
            return;
        }
        let FamilyHold { gate, bound, mut cut } = hold;
        let id = session_id.to_owned();
        // task-owner: ends once every message settles (every carrier settles it) or is cut;
        // each try to end its writer below is bounded.
        tokio::spawn(async move {
            let settled = futures::future::join_all(fences.iter().map(|f| f.settled()));
            tokio::select! {
                biased;
                _ = settled => {}
                _ = cut.changed() => {
                    for held in &fences {
                        while !held.cut_or_end(FAMILY_WRITE_BUDGET).await {
                            tracing::warn!(session = %id, checked_at = bound.generation, "an MDM off push cut a family message whose agent did not end in time; trying again");
                            tokio::time::sleep(FAMILY_WRITE_BUDGET).await;
                        }
                    }
                }
            }
            drop(gate);
        });
    }

    /// The residual risk of #26241 (#23322 a3 fence): a host logs a line before its stdin writer
    /// writes it, so a fenced line the previous daemon handed over may still wait for a harness
    /// that reads nothing, with no fence in this daemon. Each one its log names and does not
    /// prove written (`OpenWork::unwritten`) is held again under the family gate, so an off
    /// push waits for it and then ends its host (`link::adopt_receipt`). `told`: the log names
    /// them (protocol 3, replay complete, every note read); otherwise none can be ruled out
    /// (fail closed), and one hold settles only with its host (`link::adopt_untold`): an off
    /// push then ends that host, as it ends a protocol-1 host with a family line in flight
    /// (#26176).
    pub(super) fn hold_unwritten(
        session: &Session,
        hold: FamilyHold,
        record: &agent_host::HostRecord,
        told: bool,
        work: &OpenWork,
    ) {
        let fences = if told && !work.receipts_unproven {
            work.unwritten.iter().map(|&r| agent_host::link::adopt_receipt(record, r)).collect()
        } else {
            vec![agent_host::link::adopt_untold(record)]
        };
        Self::hold_fences(&session.id, hold, fences);
    }

    /// Hosts of `session` (of every session: `None`) this adoption could not resolve: a record
    /// it can not read, records it could not list, or an end at adoption that failed. Held until
    /// an off push proves none of them lives (`Fence::unresolved`), so it never returns while
    /// one may still write a line the previous daemon handed it.
    pub(super) async fn hold_unresolved(&self, session: Option<&str>) {
        let hold = self.family_hold().await;
        let fence = crate::agent::Fence::unresolved(session.map(str::to_owned));
        Self::hold_fences(session.unwrap_or("every session"), hold, vec![fence]);
    }
}
