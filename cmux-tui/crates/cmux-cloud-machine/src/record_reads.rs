//! The order of Cloud machine record reads: which answer may change a machine, when a machine a
//! list left out goes, and when a new one joins (the app's `CloudService` keeps a [`Reads`] and
//! does what the [`Step`]s say; the rules are here).
//!
//! Every read takes a ticket before it is sent ([`Reads::begin`]); a one-record read names its
//! machine and stays outstanding until it ends ([`Reads::finish`]), a list only orders. An answer
//! older than the one a machine holds changes nothing, so answers that land out of order run no
//! stale transition. A list that omits a machine does not remove it at once: the removal waits
//! while a newer one-record read of that machine is outstanding, and a newer read that saw the
//! machine cancels it. An omission is not proof the provider VM is gone (retired provider rows
//! can be filtered while the VM lives), so it is a removal, not a destruction; a record whose
//! status is `destroyed` is one.
//!
//! When Cloud is turned off by the organization (`disabled`), nothing joins, changes or goes, and
//! an ending read is only retired.

use std::collections::{BTreeMap, BTreeSet};

use serde::{Deserialize, Serialize};

/// The read tickets: the last one handed out, the one-record reads still running (ticket to
/// machine), the newest read each machine's record came from, and the removals a list asked for
/// that wait (machine to the list's ticket).
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Reads {
    pub issued: i64,
    pub outstanding: BTreeMap<i64, String>,
    pub applied: BTreeMap<String, i64>,
    pub deferred: BTreeMap<String, i64>,
}

/// What the app does, in order.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(tag = "do", rename_all = "camelCase")]
pub enum Step {
    /// Give the machine's session this read's record.
    Apply { machine: String },
    /// Add a session for this read's record of a machine the app does not hold.
    Add { machine: String },
    /// Remove the machine's session; `destroyed` when its record said so, not a list's omission.
    Remove { machine: String, destroyed: bool },
}

/// One machine of a list answer.
#[derive(Clone, Debug, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Listed {
    pub id: String,
    #[serde(default)]
    pub destroyed: bool,
}

impl Reads {
    fn applied(&self, machine: &str) -> i64 {
        self.applied.get(machine).copied().unwrap_or(0)
    }

    /// A ticket for a read about to be sent; `machine` for a one-record read.
    pub fn begin(&mut self, machine: Option<&str>) -> i64 {
        self.issued += 1;
        if let Some(machine) = machine {
            self.outstanding.insert(self.issued, machine.to_owned());
        }
        self.issued
    }

    /// Read `read` ended (answered, failed or superseded): a one-record read stops holding back
    /// the removals it delayed. A list's ticket changes nothing.
    pub fn finish(
        &mut self,
        read: i64,
        sessions: &mut BTreeSet<String>,
        disabled: bool,
    ) -> Vec<Step> {
        if self.outstanding.remove(&read).is_none() {
            return Vec::new();
        }
        self.process(sessions, disabled)
    }

    /// One machine's record from read `read`. `current`: the session the app gives it is the one it
    /// holds for that machine now. The read ends after, whatever it changed.
    pub fn apply(
        &mut self,
        machine: &str,
        destroyed: bool,
        read: i64,
        current: bool,
        sessions: &mut BTreeSet<String>,
        disabled: bool,
    ) -> Vec<Step> {
        let mut steps = Vec::new();
        if !disabled && current && sessions.contains(machine) && read > self.applied(machine) {
            self.applied.insert(machine.to_owned(), read);
            if destroyed {
                self.remove(machine, true, sessions, &mut steps);
            } else {
                steps.push(Step::Apply { machine: machine.to_owned() });
            }
        }
        steps.extend(self.finish(read, sessions, disabled));
        steps
    }

    /// A list answer from read `read`: each listed machine's record lands (a held one through
    /// [`Reads::apply`], a new one joins unless a newer read removed it), and each held machine
    /// it left out waits to go.
    pub fn reconcile(
        &mut self,
        list: &[Listed],
        read: i64,
        sessions: &mut BTreeSet<String>,
        disabled: bool,
    ) -> Vec<Step> {
        let mut steps = Vec::new();
        if disabled {
            return steps;
        }
        let visible: Vec<&Listed> = list.iter().filter(|machine| !machine.destroyed).collect();
        for machine in &visible {
            if sessions.contains(&machine.id) {
                steps.extend(self.apply(&machine.id, false, read, true, sessions, disabled));
            } else if read > self.applied(&machine.id) {
                self.applied.insert(machine.id.clone(), read);
                sessions.insert(machine.id.clone());
                steps.push(Step::Add { machine: machine.id.clone() });
            }
        }
        let ids: BTreeSet<&str> = visible.iter().map(|machine| machine.id.as_str()).collect();
        for session in sessions.iter().filter(|session| !ids.contains(session.as_str())) {
            let wait = self.deferred.entry(session.clone()).or_insert(0);
            *wait = (*wait).max(read);
        }
        steps.extend(self.process(sessions, disabled));
        steps
    }

    /// The waiting removals that may go now.
    fn process(&mut self, sessions: &mut BTreeSet<String>, disabled: bool) -> Vec<Step> {
        let mut steps = Vec::new();
        if disabled {
            return steps;
        }
        for (machine, read) in self.deferred.clone() {
            // A later read saw this machine: the omission is superseded.
            if self.applied(&machine) >= read {
                self.deferred.remove(&machine);
                continue;
            }
            // Only a newer read of this machine delays it.
            if self.outstanding.iter().any(|(ticket, of)| *ticket > read && *of == machine) {
                continue;
            }
            let applied = self.applied(&machine).max(read);
            self.applied.insert(machine.clone(), applied);
            self.remove(&machine, false, sessions, &mut steps);
        }
        steps
    }

    fn remove(
        &mut self,
        machine: &str,
        destroyed: bool,
        sessions: &mut BTreeSet<String>,
        steps: &mut Vec<Step>,
    ) {
        self.deferred.remove(machine);
        if sessions.remove(machine) {
            steps.push(Step::Remove { machine: machine.to_owned(), destroyed });
        }
    }
}

#[cfg(test)]
mod tests;
