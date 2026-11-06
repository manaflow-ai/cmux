//! A Pause, Resume or Kill of a Cloud machine, from the click until its record says where it
//! went (the app's `CloudMachineChanges` keeps a [`Changes`] and its timers; the rules are here).
//!
//! The cmux-next backend answers a pause or resume at once and runs the provider call after
//! (backend `domains/cloud-power.ts`), so the record reads `pausing`, `starting` or `deleting`
//! meanwhile, and a failed call puts the machine back with the record's `error`. A mutation the
//! API accepted stays tracked apart from the decoded record, so a stale read never drops the
//! optimistic transition while the provider request is still in flight; reads continue only
//! while one is pending (successful lists every [`SETTLE_DELAY_MS`], failed reads backing off to
//! [`MAX_DELAY_MS`], with no client deadline for an unbounded provider operation).

use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};

use crate::record::{ChangeFailure, Machine, Status};

/// The wait before a settle read after a list.
pub const SETTLE_DELAY_MS: u64 = 3_000;
/// The longest wait between failed settle reads.
pub const MAX_DELAY_MS: u64 = 30_000;

/// One accepted (or still sent) mutation.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Mutation {
    pub id: String,
    pub status: Status,
    #[serde(default)]
    pub baseline_updated_at: Option<f64>,
    #[serde(default)]
    pub baseline_server_revision: Option<String>,
    #[serde(default)]
    pub baseline_failure: Option<ChangeFailure>,
    /// The ordered read ticket issued when the accepted request returned.
    #[serde(default)]
    pub request_returned_read: Option<i64>,
}

/// The mutations of every machine, and the highest read ticket handed out.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Changes {
    pub latest_issued_read: i64,
    pub mutations: BTreeMap<String, Vec<Mutation>>,
}

/// What a holder shows for a machine: its newest pending change and that change's id.
#[derive(Clone, Debug, Default, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Shown {
    pub pending_change: Option<Status>,
    #[serde(rename = "pendingMutationID")]
    pub pending_mutation_id: Option<String>,
}

impl Changes {
    /// What `machine` shows now.
    pub fn shown(&self, machine: &str) -> Shown {
        let last = self.mutations.get(machine).and_then(|mutations| mutations.last());
        Shown {
            pending_change: last.map(|mutation| mutation.status),
            pending_mutation_id: last.map(|mutation| mutation.id.clone()),
        }
    }

    /// A mutation `id` of `machine` to `change` is sent; `baseline` is the record it was sent
    /// over, so a response from before it cannot settle it.
    pub fn begin(
        &mut self,
        machine: &str,
        change: Status,
        id: &str,
        baseline: Option<&Machine>,
    ) -> Shown {
        self.mutations.entry(machine.to_owned()).or_default().push(Mutation {
            id: id.to_owned(),
            status: change,
            baseline_updated_at: baseline.and_then(|record| record.updated_at),
            baseline_server_revision: baseline.and_then(|record| record.server_revision.clone()),
            baseline_failure: baseline.and_then(|record| record.last_change_failure.clone()),
            request_returned_read: None,
        });
        self.shown(machine)
    }

    /// The API accepted mutation `id`: only a read issued after now may settle it.
    pub fn returned(&mut self, machine: &str, id: &str) {
        let read = self.latest_issued_read;
        if let Some(mutation) = self.mutation(machine, id) {
            mutation.request_returned_read = Some(read);
        }
    }

    /// The API refused mutation `id`: it goes, and the holder shows what is left. False when it
    /// was already gone (a list settled it, or a stop cleared it): nothing rolls back then.
    pub fn rolled_back(&mut self, machine: &str, id: &str) -> bool {
        let Some(mutations) = self.mutations.get_mut(machine) else { return false };
        let Some(index) = mutations.iter().position(|mutation| mutation.id == id) else {
            return false;
        };
        mutations.remove(index);
        if mutations.is_empty() {
            self.mutations.remove(machine);
        }
        true
    }

    fn mutation(&mut self, machine: &str, id: &str) -> Option<&mut Mutation> {
        self.mutations.get_mut(machine)?.iter_mut().find(|mutation| mutation.id == id)
    }

    /// Records a read ticket before its request is sent.
    pub fn read_issued(&mut self, read: i64) {
        self.latest_issued_read = self.latest_issued_read.max(read);
    }

    /// `record` (read with ticket `read`, when it had one) with the pending overlay applied: the
    /// newest pending operation drives presentation, older ones stay tracked until their own
    /// terminal record arrives, and a failed newer request exposes the older one.
    pub fn apply(&mut self, record: &Machine, read: Option<i64>) -> Machine {
        if let Some(read) = read {
            self.read_issued(read);
        }
        let mut shown = record.clone();
        shown.failed_mutation_id = self.settle(record, read);
        let now = self.shown(&record.id);
        shown.pending_change = now.pending_change;
        shown.pending_mutation_id = now.pending_mutation_id;
        shown
    }

    fn settle(&mut self, record: &Machine, read: Option<i64>) -> Option<String> {
        let mut outstanding = self.mutations.remove(&record.id)?;
        if record.status == Status::Destroyed {
            return None;
        }
        let mut failed = None;
        // A provider error has no operation id: attribute a new terminal error only to the newest
        // acknowledged operation. Never let one failure retire every older mutation.
        if let Some(last) = outstanding.last()
            && let Some(returned) = last.request_returned_read
            && read.is_none_or(|read| read > returned)
            && !record.status.is_changing()
            && let Some(failure) = &record.last_change_failure
            && !ChangeFailure::same_option(Some(failure), last.baseline_failure.as_ref())
        {
            failed = outstanding.pop().map(|mutation| mutation.id);
            for mutation in &mut outstanding {
                mutation.baseline_failure = Some(failure.clone());
            }
        }
        outstanding.retain(|mutation| {
            let Some(returned) = mutation.request_returned_read else { return true };
            // Completion needs a read issued after acknowledgement, but older app servers need
            // not supply a revision. Only an opposite terminal state (supersession) requires
            // explicit server freshness as well as an ordered read.
            if read.is_some_and(|read| read <= returned) {
                return true;
            }
            let newer = newer_revision(
                record.server_revision.as_deref(),
                mutation.baseline_server_revision.as_deref(),
            ) || match (record.updated_at, mutation.baseline_updated_at) {
                (None, _) => false,
                (Some(_), None) => true,
                (Some(current), Some(baseline)) => current > baseline,
            };
            let superseded = read.is_some() && newer;
            let settled = match mutation.status {
                Status::Pausing => {
                    record.status == Status::Paused
                        || (record.status == Status::Running && superseded)
                }
                Status::Starting => {
                    record.status == Status::Running
                        || (record.status == Status::Paused && superseded)
                }
                _ => false,
            };
            !settled
        });
        if !outstanding.is_empty() {
            self.mutations.insert(record.id.clone(), outstanding);
        }
        failed
    }

    /// A list omitted `machine` (including an authoritative delete confirmation).
    pub fn removed(&mut self, machine: &str) {
        self.mutations.remove(machine);
    }

    /// The machines a list leaves unsettled: changing ones and ones with a tracked mutation,
    /// except those whose record is pushed (`pushed`), which settle from their push.
    pub fn unsettled(&self, list: &[Machine], pushed: &[String]) -> Vec<String> {
        let mut machines: Vec<String> = list
            .iter()
            .filter(|machine| machine.status.is_changing())
            .map(|machine| machine.id.clone())
            .chain(self.mutations.keys().cloned())
            .filter(|machine| !pushed.contains(machine))
            .collect();
        machines.sort();
        machines.dedup();
        machines
    }
}

/// Whether unsigned decimal revision `current` is newer than `previous`, without truncation,
/// overflow or lexical digit-count mistakes. Anything not all digits compares as not newer.
pub fn newer_revision(current: Option<&str>, previous: Option<&str>) -> bool {
    fn normalized(value: Option<&str>) -> Option<&str> {
        let value = value
            .filter(|value| !value.is_empty() && value.bytes().all(|byte| byte.is_ascii_digit()))?;
        let digits = value.trim_start_matches('0');
        Some(if digits.is_empty() { "0" } else { digits })
    }
    let (Some(current), Some(previous)) = (normalized(current), normalized(previous)) else {
        return false;
    };
    if current.len() == previous.len() {
        current > previous
    } else {
        current.len() > previous.len()
    }
}

/// The wait before the next settle read: the settle delay again when a list landed since the
/// last read (`listed`), else twice `delay_ms`, at most [`MAX_DELAY_MS`].
pub fn next_delay(delay_ms: u64, listed: bool) -> u64 {
    if listed { SETTLE_DELAY_MS } else { delay_ms.saturating_mul(2).min(MAX_DELAY_MS) }
}

#[cfg(test)]
mod tests;
