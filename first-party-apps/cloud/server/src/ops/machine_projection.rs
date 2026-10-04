//! The machine projection on this machine (cloud-app.md 1: cache only,
//! rebuilt from the Cloud API list). The [`super::Server`] is its only
//! writer; every change bumps the revision and queues one event for the
//! host, so pages and the sidebar update right after a mutation without a
//! timer.

use crate::api::models::Machine;
use serde::Serialize;
use serde_json::Value;
use std::collections::BTreeMap;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum Change {
    /// The whole list was replaced (refresh or sign-out).
    Reset,
    Upsert,
    Remove,
}

/// `cloud.machine.changed` for the host.
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct ProjectionEvent {
    pub revision: u64,
    pub change: Change,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub machine: Option<String>,
}

#[derive(Debug, Default)]
pub struct Projection {
    machines: BTreeMap<String, Machine>,
    revision: u64,
    events: Vec<ProjectionEvent>,
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

    pub(crate) fn take_events(&mut self) -> Vec<ProjectionEvent> {
        std::mem::take(&mut self.events)
    }

    fn bump(&mut self, change: Change, machine: Option<&str>) {
        self.revision += 1;
        self.events.push(ProjectionEvent {
            revision: self.revision,
            change,
            machine: machine.map(str::to_owned),
        });
    }

    /// Replaces every record with a fresh list. Destroyed machines are not kept.
    pub(crate) fn replace_all(&mut self, list: Vec<Machine>) {
        use crate::api::models::MachineStatus;
        let next: BTreeMap<String, Machine> = list
            .into_iter()
            .filter(|m| m.status != MachineStatus::Destroyed)
            .map(|m| (m.id.clone(), m))
            .collect();
        if next != self.machines {
            self.machines = next;
            self.bump(Change::Reset, None);
        }
    }

    /// Empties the projection (signed out).
    pub(crate) fn clear(&mut self) {
        if !self.machines.is_empty() {
            self.machines.clear();
            self.bump(Change::Reset, None);
        }
    }

    /// Overlays the fields a Cloud API answer carries onto the known record
    /// (a rename answers only `id`, `displayName` and `slug`; a pause only
    /// `id` and `status`) and returns the merged record. `None` when the
    /// answer is not a machine.
    pub(crate) fn merge(&mut self, answer: &Value) -> Option<Machine> {
        let id = answer.get("id")?.as_str()?.to_owned();
        let mut record = match self.machines.get(&id) {
            Some(known) => serde_json::to_value(known).ok()?,
            None => Value::Object(Default::default()),
        };
        for (k, v) in answer.as_object()? {
            record[k] = v.clone();
        }
        let merged: Machine = serde_json::from_value(record).ok()?;
        if self.machines.get(&id) != Some(&merged) {
            self.machines.insert(id.clone(), merged.clone());
            self.bump(Change::Upsert, Some(&id));
        }
        Some(merged)
    }

    pub(crate) fn remove(&mut self, id: &str) {
        if self.machines.remove(id).is_some() {
            self.bump(Change::Remove, Some(id));
        }
    }
}
