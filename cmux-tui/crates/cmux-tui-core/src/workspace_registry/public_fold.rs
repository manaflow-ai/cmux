//! Incremental public topology deltas.
//!
//! A full topology projection restates every live workspace, screen, pane,
//! tab, terminal, and browser in each commit's public `changes`. Journaling
//! and streaming all of them costs time and journal space proportional to
//! the session on every close. This fold is the topology state that the
//! journal's resource records already state (each `upsert` replaces a value,
//! each `delete` removes it, as the journal checkpoint reducer applies
//! them). A projection upsert whose value the fold already holds is a no-op
//! for every replaying consumer, so it is dropped before the journal append.
//!
//! The fold catches up from the journal before each use, so a commit by any
//! path keeps it exact. It starts empty (nothing is dropped) and is seeded
//! from the next full projection, whose upserts are the complete live set.
//! A journal gap or any read failure clears it, which only disables pruning.

use std::collections::HashMap;

use super::*;

const TRACKED_RESOURCES: [&str; 6] = ["workspace", "screen", "pane", "tab", "terminal", "browser"];

#[derive(Debug, Default)]
pub(super) struct PublicTopologyFold {
    revision: u64,
    values: HashMap<(String, String), Value>,
}

impl PublicTopologyFold {
    fn apply(&mut self, changes: &Value) {
        let Some(changes) = changes.as_array() else { return };
        for change in changes {
            let (Some(kind), Some(resource), Some(id)) =
                (change["kind"].as_str(), change["resource"].as_str(), change["id"].as_str())
            else {
                continue;
            };
            if !TRACKED_RESOURCES.contains(&resource) {
                continue;
            }
            let key = (resource.to_string(), id.to_string());
            match kind {
                "upsert" => {
                    self.values.insert(key, change["value"].clone());
                }
                "delete" => {
                    self.values.remove(&key);
                }
                _ => {}
            }
        }
    }

    fn states(&self, change: &Value) -> bool {
        change["kind"] == "upsert"
            && change["resource"]
                .as_str()
                .is_some_and(|resource| TRACKED_RESOURCES.contains(&resource))
            && match (change["resource"].as_str(), change["id"].as_str()) {
                (Some(resource), Some(id)) => self
                    .values
                    .get(&(resource.to_string(), id.to_string()))
                    .is_some_and(|value| value == &change["value"]),
                _ => false,
            }
    }
}

impl WorkspaceRegistry {
    /// Drop projection upserts that the journal already states with the same
    /// value, and renumber the remaining changes' `sequence`.
    pub(super) fn prune_stated_topology_deltas(&mut self, deltas: &Value) -> anyhow::Result<Value> {
        self.catch_up_public_fold();
        let Some(fold) = self.public_fold.as_ref() else { return Ok(deltas.clone()) };
        let changes = deltas.as_array().context("resource deltas are not an array")?;
        let mut kept = Vec::with_capacity(changes.len());
        for change in changes {
            if fold.states(change) {
                continue;
            }
            let mut change = change.clone();
            if let Some(object) = change.as_object_mut()
                && object.contains_key("sequence")
            {
                object.insert("sequence".into(), Value::from(kept.len()));
            }
            kept.push(change);
        }
        Ok(Value::Array(kept))
    }

    /// Record a committed resource revision whose journaled changes were
    /// `journaled`. When they are the unpruned changes of a full topology
    /// projection (`full_projection`), they are the complete live set and
    /// seed an empty fold.
    pub(super) fn record_public_fold(
        &mut self,
        previous_revision: u64,
        revision: u64,
        journaled: &Value,
        full_projection: bool,
    ) {
        match self.public_fold.as_mut() {
            Some(fold) if fold.revision == previous_revision => {
                fold.apply(journaled);
                fold.revision = revision;
            }
            Some(_) => self.public_fold = None,
            None if full_projection => {
                let mut fold = PublicTopologyFold { revision, ..Default::default() };
                fold.apply(journaled);
                self.public_fold = Some(fold);
            }
            None => {}
        }
    }

    /// Apply every resource record committed since the fold's revision, or
    /// clear the fold when the journal cannot supply them.
    fn catch_up_public_fold(&mut self) {
        let Some(mut fold) = self.public_fold.take() else { return };
        let caught_up = (|| -> anyhow::Result<bool> {
            loop {
                let head = current_resource_revision(&self.connection)?;
                if fold.revision == head {
                    return Ok(true);
                }
                if fold.revision > head {
                    return Ok(false);
                }
                let page = self.resource_events_after(fold.revision)?;
                if page.batches.is_empty() {
                    return Ok(false);
                }
                for batch in page.batches {
                    if batch.previous_revision != fold.revision {
                        return Ok(false);
                    }
                    fold.apply(&batch.changes);
                    fold.revision = batch.revision;
                }
            }
        })();
        if matches!(caught_up, Ok(true)) {
            self.public_fold = Some(fold);
        }
    }

    /// The value the journal states for one topology resource, after
    /// catching up; `None` while the fold is unseeded.
    #[cfg(test)]
    pub(crate) fn stated_topology_value_for_test(
        &mut self,
        resource: &str,
        id: &str,
    ) -> Option<Option<Value>> {
        self.catch_up_public_fold();
        let fold = self.public_fold.as_ref()?;
        Some(fold.values.get(&(resource.to_string(), id.to_string())).cloned())
    }
}
