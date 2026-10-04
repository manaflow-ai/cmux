//! The machine projection on this machine (cloud-app.md 1: cache only,
//! rebuilt from the Cloud API list). The [`super::Server`] is its only
//! writer, and this type is the only source of `cloud.machine.watch`
//! events: every write that changes a record raises the revision once and
//! queues one event per changed record from the same code path, so pages
//! and the sidebar update right after a change without a timer.

use crate::api::models::{Machine, MachineStatus};
use serde::Serialize;
use serde_json::Value;
use std::collections::BTreeMap;

/// One `cloud.machine.watch` event. Events of one projection change share
/// its revision; revisions only grow.
#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(tag = "type", rename_all = "lowercase")]
pub enum WatchEvent {
    /// The record is new or changed: the full record after the change.
    Upsert { revision: u64, machine: Machine },
    /// The record is gone (deleted, destroyed, missing from a refresh, or
    /// signed out).
    Removed { revision: u64, id: String },
}

impl WatchEvent {
    pub fn revision(&self) -> u64 {
        match self {
            Self::Upsert { revision, .. } | Self::Removed { revision, .. } => *revision,
        }
    }
}

#[derive(Debug, Default)]
pub struct Projection {
    machines: BTreeMap<String, Machine>,
    revision: u64,
    events: Vec<WatchEvent>,
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

    /// Applies one change: `removed` ids and `upserts` records. Raises the
    /// revision once when anything differs and queues one event per changed
    /// record (removals first, then upserts, each in id order).
    fn apply(&mut self, removed: Vec<String>, upserts: Vec<Machine>) {
        let removed: Vec<String> =
            removed.into_iter().filter(|id| self.machines.contains_key(id)).collect();
        let upserts: Vec<Machine> =
            upserts.into_iter().filter(|m| self.machines.get(&m.id) != Some(m)).collect();
        if removed.is_empty() && upserts.is_empty() {
            return;
        }
        self.revision += 1;
        let revision = self.revision;
        for id in removed {
            self.machines.remove(&id);
            self.events.push(WatchEvent::Removed { revision, id });
        }
        for machine in upserts {
            self.machines.insert(machine.id.clone(), machine.clone());
            self.events.push(WatchEvent::Upsert { revision, machine });
        }
    }

    /// Replaces every record with a fresh list, as a diff: records missing
    /// from the list are removed, new or changed ones upserted. Destroyed
    /// machines are not kept.
    pub(crate) fn replace_all(&mut self, list: Vec<Machine>) {
        let next: BTreeMap<String, Machine> = list
            .into_iter()
            .filter(|m| m.status != MachineStatus::Destroyed)
            .map(|m| (m.id.clone(), m))
            .collect();
        let removed = self.machines.keys().filter(|id| !next.contains_key(*id)).cloned().collect();
        self.apply(removed, next.into_values().collect());
    }

    /// Empties the projection (signed out).
    pub(crate) fn clear(&mut self) {
        let removed = self.machines.keys().cloned().collect();
        self.apply(removed, Vec::new());
    }

    /// The record a Cloud API answer describes: the answer's fields overlaid
    /// onto the known record (a rename answers only `id`, `displayName` and
    /// `slug`; a pause only `id` and `status`), or onto `base` when the
    /// projection does not know the machine. Writes nothing.
    pub(crate) fn overlay(&self, base: Option<&Value>, answer: &Value) -> Option<Machine> {
        let id = answer.get("id")?.as_str()?;
        let mut record = match (self.machines.get(id), base) {
            (Some(known), _) => serde_json::to_value(known).ok()?,
            (None, Some(base)) => base.clone(),
            (None, None) => Value::Object(Default::default()),
        };
        for (k, v) in answer.as_object()? {
            record[k] = v.clone();
        }
        serde_json::from_value(record).ok()
    }

    /// Writes one record. A destroyed machine is removed instead, like a
    /// refresh would.
    pub(crate) fn upsert(&mut self, machine: Machine) {
        if machine.status == MachineStatus::Destroyed {
            self.apply(vec![machine.id], Vec::new());
        } else {
            self.apply(Vec::new(), vec![machine]);
        }
    }

    pub(crate) fn remove(&mut self, id: &str) {
        self.apply(vec![id.to_owned()], Vec::new());
    }
}
