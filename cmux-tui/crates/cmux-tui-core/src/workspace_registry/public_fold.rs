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

    /// Whether decorating `change` could make the fold state it: an upsert of a resource decoration adds to
    /// (`state/values.rs` `decorate_value`: a workspace, tab or screen) whose held value differs from it only in
    /// what decoration sets (`content_kind`, `extra`). One that differs elsewhere (a tab whose index moved) is
    /// kept without a query.
    fn may_state_decorated(&self, change: &Value) -> bool {
        let (Some(resource), Some(id)) = (change["resource"].as_str(), change["id"].as_str())
        else {
            return false;
        };
        if change["kind"] != "upsert" || !matches!(resource, "workspace" | "tab" | "screen") {
            return false;
        }
        let Some(held) = self.values.get(&(resource.to_string(), id.to_string())) else {
            return false;
        };
        let (Some(held), Some(raw)) = (held.as_object(), change["value"].as_object()) else {
            return false;
        };
        let decorated_only = |key: &String| key == "content_kind" || key == "extra";
        held.iter()
            .filter(|(key, _)| !decorated_only(key))
            .all(|(key, value)| raw.get(key) == Some(value))
            && raw.keys().filter(|key| !decorated_only(key)).all(|key| held.contains_key(key))
    }

    fn states(&self, change: &Value) -> bool {
        change["kind"] == "upsert"
            && change["resource"]
                .as_str()
                .is_some_and(|resource| TRACKED_RESOURCES.contains(&resource))
            && match (change["resource"].as_str(), change["id"].as_str()) {
                (Some(resource), Some(id)) => {
                    self.values.get(&(resource.to_string(), id.to_string())).is_some_and(|value| {
                        value == &change["value"]
                            || (resource == "workspace"
                                && without_workspace_key(value) == change["value"])
                    })
                }
                _ => false,
            }
    }
}

/// Whether `stated` (a folded value) already says what the decorated upsert `value` says: equal, or equal
/// without `extra.key` (a raw projection value never carries it).
pub(crate) fn workspace_value_stated(stated: &Value, value: &Value) -> bool {
    stated == value || without_workspace_key(stated) == without_workspace_key(value)
}

/// A folded workspace value without `extra.key` (and without `extra` when
/// that was its only field). Every journaled workspace upsert carries its key
/// (state/values.rs), a projection's raw upsert never does, and a
/// workspace's key never changes, so the comparison leaves it out.
fn without_workspace_key(value: &Value) -> Value {
    let mut value = value.clone();
    if let Some(object) = value.as_object_mut()
        && let Some(extra) = object.get_mut("extra").and_then(Value::as_object_mut)
    {
        extra.remove("key");
        if extra.is_empty() {
            object.remove("extra");
        }
    }
    value
}

impl WorkspaceRegistry {
    /// Drop projection upserts that the journal already states with the same
    /// value, and renumber the remaining changes' `sequence`.
    pub(super) fn prune_stated_topology_deltas(&mut self, deltas: &Value) -> anyhow::Result<Value> {
        self.catch_up_public_fold();
        let Some(fold) = self.public_fold.as_ref() else { return Ok(deltas.clone()) };
        let changes = deltas.as_array().context("resource deltas are not an array")?;
        // The fold holds decorated values (`record_public_fold`), the projection raw ones: a raw upsert of a
        // decorated tab or screen (a chat tab, a frontend browser's profile, a pinned screen) never equals what
        // the fold holds, so it is compared decorated as the journal would write it. Without this, every chat
        // tab of a pane was journaled again on each create in it.
        let connection = self.connection.get();
        let decorate = crate::state::store::state_tables_ready(&connection)?;
        let mut kept = Vec::with_capacity(changes.len());
        for change in changes {
            if fold.states(change) {
                continue;
            }
            if decorate && fold.may_state_decorated(change) {
                let mut decorated = change.clone();
                let resource = change["resource"].as_str().unwrap_or_default();
                if let Some(value) = decorated.get_mut("value") {
                    crate::state::values::decorate_value(&connection, resource, value)?;
                }
                if fold.states(&decorated) {
                    continue;
                }
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

    /// The workspace values the journal states now (after catching up), keyed by public id, or `None` while the
    /// fold is unseeded or cannot catch up. A copy for a commit that prunes its workspace upserts against it
    /// inside its transaction (`WorkspaceCommitIntent`, which may run on the journal writer, away from the
    /// registry). The fold reads that commit back from the journal at its next catch-up, as it does every other
    /// commit.
    pub(crate) fn stated_workspaces(&mut self) -> Option<(u64, HashMap<String, Value>)> {
        self.catch_up_public_fold();
        let fold = self.public_fold.as_ref()?;
        let workspaces = fold
            .values
            .iter()
            .filter(|((resource, _), _)| resource == "workspace")
            .map(|((_, id), value)| (id.clone(), value.clone()))
            .collect();
        Some((fold.revision, workspaces))
    }

    /// Whether the fold holds a complete topology to prune against.
    pub(crate) fn public_fold_seeded(&self) -> bool {
        self.public_fold.is_some()
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
        // The fold holds what the journal states: the journal decorates every
        // upsert with the state rows (pins, groups, zoom; state/values.rs)
        // when it writes it, so the fold folds the same decorated values.
        // Folding the raw deltas made it state a pinned screen without its
        // pin after a restart reseeded it (#19079's cross-check).
        let mut decorated = journaled.clone();
        if let Err(error) =
            crate::state::values::decorate_changes(&self.connection.get(), &mut decorated)
        {
            eprintln!(
                "cmux-tui: public fold: decorating the journaled changes failed, reseeding: {error:#}"
            );
            self.public_fold = None;
            return;
        }
        let journaled = &decorated;
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
                let head = current_resource_revision(&self.connection.get())?;
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

    /// The value the journal states for one topology resource, or `None`
    /// when the fold is unseeded or behind the store (no catch-up: callers
    /// hold only a shared registry borrow).
    pub(crate) fn stated_topology_value(&self, resource: &str, id: &str) -> Option<Option<Value>> {
        let fold = self.public_fold.as_ref()?;
        let head = current_resource_revision(&self.connection.get()).ok()?;
        (fold.revision == head)
            .then(|| fold.values.get(&(resource.to_string(), id.to_string())).cloned())
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
