//! The order of the app's Cloud machine record reads, so an answer that lands late never undoes a
//! newer one (moved from CloudService's `recordReads`, `recordReadsOutstanding`,
//! `recordReadApplied` and `deferredRecordRemovals`; the app keeps the sessions and acts on the
//! answers).
//!
//! Every read takes a ticket before it is sent ([`Reads::begin`]). A one-record read (Machine
//! Status) names its machine and stays outstanding until it finishes; a list read only orders.
//! A record is applied only when its ticket is newer than the one that machine's record came from
//! ([`Reads::admit`]). A list that omits a machine does not remove it at once: the removal waits
//! while a newer one-record read of that machine is outstanding, and a newer read that saw the
//! machine cancels it ([`Reads::omitted`], [`Reads::finish`]).

use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};

/// What a list changes: the machines to add, and the ones to remove.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize)]
pub struct Listed {
    pub add: Vec<String>,
    pub removals: Vec<String>,
}

/// The read tickets: the last one handed out, the one-record reads still in flight, the ticket
/// each machine's record came from, and the omissions waiting on a newer read.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Reads {
    /// The last ticket handed out (0: none yet).
    pub issued: i64,
    /// One-record reads in flight: ticket to the machine it reads.
    pub outstanding: BTreeMap<i64, String>,
    /// The ticket of the read each machine's applied record came from.
    pub applied: BTreeMap<String, i64>,
    /// Machines a list omitted, with that list's ticket, waiting on newer reads of them.
    pub deferred: BTreeMap<String, i64>,
}

impl Reads {
    /// Hands out the next ticket. A one-record read names `machine` and stays outstanding until
    /// [`Reads::finish`]; a list (`None`) never does.
    pub fn begin(&mut self, machine: Option<&str>) -> i64 {
        self.issued += 1;
        if let Some(machine) = machine {
            self.outstanding.insert(self.issued, machine.to_owned());
        }
        self.issued
    }

    /// Retires a finished or superseded one-record read; a list ticket changes nothing. Answers
    /// the machines whose omission no longer waits (empty while `disabled`: Cloud is off).
    pub fn finish(&mut self, read: i64, disabled: bool) -> Vec<String> {
        if self.outstanding.remove(&read).is_none() {
            return Vec::new();
        }
        self.settle(disabled)
    }

    /// Whether a record of `machine` from `read` is newer than the one it holds; when it is,
    /// that read becomes the machine's.
    pub fn admit(&mut self, machine: &str, read: i64) -> bool {
        if read <= self.applied_read(machine) {
            return false;
        }
        self.applied.insert(machine.to_owned(), read);
        true
    }

    /// The list from `read` omitted `machines` (sessions the app holds): each waits as a
    /// removal. Answers the machines to remove now.
    pub fn omitted(&mut self, machines: &[String], read: i64, disabled: bool) -> Vec<String> {
        for machine in machines {
            let waiting = self.deferred.entry(machine.clone()).or_insert(read);
            *waiting = (*waiting).max(read);
        }
        self.settle(disabled)
    }

    /// A list from `read` named `listed`, and the app holds sessions for `held`: answers the listed
    /// machines to add (no session yet, and newer than any read that removed them) and the held
    /// ones whose omission is released now.
    pub fn listed(
        &mut self,
        listed: &[String],
        held: &[String],
        read: i64,
        disabled: bool,
    ) -> Listed {
        let add = listed
            .iter()
            .filter(|machine| !held.contains(machine))
            .filter(|machine| self.admit(machine, read))
            .cloned()
            .collect();
        let omitted: Vec<String> =
            held.iter().filter(|machine| !listed.contains(machine)).cloned().collect();
        Listed { add, removals: self.omitted(&omitted, read, disabled) }
    }

    /// The app removed `machine` (a destroyed record, or an omission answered here): nothing
    /// waits on it.
    pub fn removed(&mut self, machine: &str) {
        self.deferred.remove(machine);
    }

    /// Whether no one-record read is in flight.
    pub fn is_idle(&self) -> bool {
        self.outstanding.is_empty()
    }

    fn applied_read(&self, machine: &str) -> i64 {
        self.applied.get(machine).copied().unwrap_or(0)
    }

    /// Releases the omissions no newer read holds back, in machine order.
    fn settle(&mut self, disabled: bool) -> Vec<String> {
        if disabled {
            return Vec::new();
        }
        let mut removals = Vec::new();
        let waiting: Vec<(String, i64)> =
            self.deferred.iter().map(|(machine, read)| (machine.clone(), *read)).collect();
        for (machine, read) in waiting {
            // A later read saw this machine, superseding the omission.
            if self.applied_read(&machine) >= read {
                self.deferred.remove(&machine);
                continue;
            }
            // A newer one-record read of this machine holds it; one of another machine does not.
            if self.outstanding.iter().any(|(ticket, reads)| *ticket > read && *reads == machine) {
                continue;
            }
            self.deferred.remove(&machine);
            let applied = self.applied_read(&machine).max(read);
            self.applied.insert(machine.clone(), applied);
            removals.push(machine);
        }
        removals
    }
}

#[cfg(test)]
mod tests;
