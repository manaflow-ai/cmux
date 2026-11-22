//! The machine projection on this machine (cache only; contract 2.1). It is
//! filled from `cloud.machine.list` pages, op answers and the team wire
//! events (`cloud.machine.upsert`, `cloud.machine.removed`). The
//! [`super::Server`] is its only writer, and this type is the only source of
//! `cloud.machine.watch` events: every write that changes a record raises
//! the local revision once and queues one event per changed record, so pages
//! and the sidebar update right after a change without a timer.
//!
//! Every record carries its backend `revision`. A record, answer or event
//! older than what the projection holds (or than the removal it saw) is
//! dropped, so a late event never undoes a newer answer.

use crate::api::models::{Machine, Revision};
use serde::Serialize;
use std::collections::{BTreeMap, BTreeSet, VecDeque};

/// Removals kept to refuse older upserts of a removed machine.
const TOMBSTONES: usize = 1024;

/// One `cloud.machine.watch` event. Events of one projection change share
/// its revision; revisions only grow.
#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(tag = "type", rename_all = "lowercase")]
pub enum WatchEvent {
    /// The record is new or changed: the full record after the change.
    Upsert { revision: u64, machine: Box<Machine> },
    /// The record is gone (deleted, removed by an event, missing from a
    /// full listing, or signed out).
    Removed { revision: u64, id: String },
}

impl WatchEvent {
    pub fn revision(&self) -> u64 {
        match self {
            Self::Upsert { revision, .. } | Self::Removed { revision, .. } => *revision,
        }
    }
}

/// A listing that started at the first page and follows its cursors: when
/// it reaches the last page, machines it did not see are removed.
#[derive(Debug)]
struct Sweep {
    next_cursor: String,
    seen: BTreeSet<String>,
    /// The team revision of the first page: a machine newer than it may
    /// have been created after the listing began, so it is kept.
    at: Option<Revision>,
}

#[derive(Debug, Default)]
pub struct Projection {
    machines: BTreeMap<String, Machine>,
    revision: u64,
    events: Vec<WatchEvent>,
    /// Removed ids and the backend revision of the removal.
    tombstones: BTreeMap<String, Revision>,
    tombstone_order: VecDeque<String>,
    sweep: Option<Sweep>,
}

impl Projection {
    pub fn revision(&self) -> u64 {
        self.revision
    }

    pub fn get(&self, id: &str) -> Option<&Machine> {
        self.machines.get(id)
    }

    /// Machines in id order.
    pub fn machines(&self) -> impl Iterator<Item = &Machine> {
        self.machines.values()
    }

    pub fn len(&self) -> usize {
        self.machines.len()
    }

    pub fn is_empty(&self) -> bool {
        self.machines.is_empty()
    }

    pub(crate) fn take_events(&mut self) -> Vec<WatchEvent> {
        std::mem::take(&mut self.events)
    }

    /// True when `machine` is not older than the record the projection
    /// holds for its id, and newer than any removal it saw (a record at the
    /// removal's revision is the one that was removed).
    fn current(&self, machine: &Machine) -> bool {
        let known = self.machines.get(&machine.id).is_none_or(|m| machine.revision >= m.revision);
        let removed = self.tombstones.get(&machine.id).is_none_or(|r| machine.revision > *r);
        known && removed
    }

    /// Records a removal at `revision`; an older one never lowers it.
    fn tombstone(&mut self, id: &str, revision: Revision) {
        if let Some(known) = self.tombstones.get_mut(id) {
            if revision > *known {
                *known = revision;
            }
            return;
        }
        self.tombstones.insert(id.to_owned(), revision);
        self.tombstone_order.push_back(id.to_owned());
        if self.tombstone_order.len() > TOMBSTONES
            && let Some(oldest) = self.tombstone_order.pop_front()
        {
            self.tombstones.remove(&oldest);
        }
    }

    /// Applies one change: `removed` ids and `upserts` records. Raises the
    /// revision once when anything differs and queues one event per changed
    /// record (removals first, then upserts, each in id order).
    fn apply(&mut self, removed: Vec<String>, upserts: Vec<Machine>) {
        let removed: Vec<String> =
            removed.into_iter().filter(|id| self.machines.contains_key(id)).collect();
        let upserts: Vec<Machine> = upserts
            .into_iter()
            .filter(|m| self.current(m) && self.machines.get(&m.id) != Some(m))
            .collect();
        if removed.is_empty() && upserts.is_empty() {
            return;
        }
        self.revision += 1;
        let revision = self.revision;
        for id in removed {
            if let Some(gone) = self.machines.remove(&id) {
                self.tombstone(&id, gone.revision);
            }
            self.events.push(WatchEvent::Removed { revision, id });
        }
        for machine in upserts {
            self.tombstones.remove(&machine.id);
            self.machines.insert(machine.id.clone(), machine.clone());
            self.events.push(WatchEvent::Upsert { revision, machine: Box::new(machine) });
        }
    }

    /// One `cloud.machine.list` page. Its records are upserted. A listing
    /// that started at the first page (`cursor` none) and followed each
    /// `next_cursor` to the last page then removes the machines it never
    /// saw, unless they are newer than the first page.
    pub(crate) fn apply_page(
        &mut self,
        cursor: Option<&str>,
        machines: Vec<Machine>,
        next_cursor: Option<&str>,
        at: Option<Revision>,
    ) {
        let mut sweep = match (cursor, self.sweep.take()) {
            (None, _) => Some(Sweep { next_cursor: String::new(), seen: BTreeSet::new(), at }),
            (Some(c), Some(s)) if s.next_cursor == c => Some(s),
            // A page out of order: no removal can be proven from it.
            _ => None,
        };
        if let Some(s) = sweep.as_mut() {
            s.seen.extend(machines.iter().map(|m| m.id.clone()));
        }
        let removed = match (next_cursor, sweep) {
            (Some(next), Some(mut s)) => {
                s.next_cursor = next.to_owned();
                self.sweep = Some(s);
                Vec::new()
            }
            (None, Some(s)) => self
                .machines
                .values()
                .filter(|m| !s.seen.contains(&m.id))
                .filter(|m| s.at.as_ref().is_none_or(|at| m.revision <= *at))
                .map(|m| m.id.clone())
                .collect(),
            (_, None) => Vec::new(),
        };
        self.apply(removed, machines);
    }

    /// Empties the projection (signed out).
    pub(crate) fn clear(&mut self) {
        let removed = self.machines.keys().cloned().collect();
        self.sweep = None;
        self.apply(removed, Vec::new());
        self.tombstones.clear();
        self.tombstone_order.clear();
    }

    /// Writes one record unless it is older than the projection's.
    pub(crate) fn upsert(&mut self, machine: Machine) {
        self.apply(Vec::new(), vec![machine]);
    }

    /// Removes a machine the backend says is gone (deleted, or
    /// `cloud.machine.not_found`).
    pub(crate) fn remove(&mut self, id: &str) {
        self.apply(vec![id.to_owned()], Vec::new());
    }

    /// `cloud.machine.removed {machine, revision}`: removes the machine
    /// unless the projection holds a newer record.
    pub(crate) fn remove_at(&mut self, id: &str, revision: Revision) {
        if self.machines.get(id).is_some_and(|m| m.revision > revision) {
            return;
        }
        self.tombstone(id, revision);
        self.apply(vec![id.to_owned()], Vec::new());
    }
}
