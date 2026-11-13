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
//! path keeps it exact: it holds a value only when the journal states that
//! value now. It need not hold every live resource. A daemon start, a commit
//! whose receipt did not come, a journal gap and a read failure lose it; the
//! next use starts it again empty at the journal head. An empty fold drops
//! nothing, and each later commit adds the values its own record states, so
//! no commit waits for a full projection before it may be scoped. (Before,
//! a lost fold sent the next create or close to the full projection, which
//! wrote one journal value for each live resource of the session.)
//!
//! The fold holds a workspace WHOLE when it holds each live value of that
//! workspace: a commit stated the workspace again from the live tree (not
//! only the values it changed) and the fold folded that record. A scoped
//! commit asks this for the workspaces of its scope
//! ([`WorkspaceRegistry::workspace_is_whole`]); one that is not whole is
//! stated again in that commit, and marked
//! ([`WorkspaceRegistry::mark_workspaces_whole`]). A fold that starts again
//! holds no workspace whole. After a daemon start, a worker states the
//! workspaces again in parts while the daemon serves
//! (`mux/startup_restore/restate_parts.rs`).
//!
//! A full projection makes the fold complete (it then holds every live
//! resource, so each workspace whole). Only the debug cross-check reads
//! that: a complete fold can say that the journal does not state a
//! resource, a partial one cannot.

use std::collections::{HashMap, HashSet};

use super::*;

const TRACKED_RESOURCES: [&str; 6] = ["workspace", "screen", "pane", "tab", "terminal", "browser"];

#[derive(Debug, Default)]
pub(super) struct PublicTopologyFold {
    revision: u64,
    /// The revision at which the fold started, empty: it folded each record after it and none
    /// before it.
    since: u64,
    values: HashMap<(String, String), Value>,
    /// Whether `values` holds every live topology resource (a full projection was folded since
    /// the fold started). Read through [`Self::holds_every_resource`] only.
    complete: bool,
    /// The public ids of the workspaces that the fold holds whole (see the module text).
    whole: HashSet<String>,
}

#[cfg(test)]
thread_local! {
    /// Reads of [`PublicTopologyFold::holds_every_resource`] on this thread.
    static COMPLETE_READS: Cell<u64> = const { Cell::new(0) };
}

impl PublicTopologyFold {
    /// Whether the fold holds every live topology resource, so a resource it does not hold is
    /// one the journal does not state. No commit path may depend on this: pruning needs only
    /// the values the fold holds. The debug cross-check is its one reader, and
    /// `complete_reads_for_test` counts each read.
    fn holds_every_resource(&self) -> bool {
        #[cfg(test)]
        COMPLETE_READS.with(|reads| reads.set(reads.get() + 1));
        self.complete
    }

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
                    if resource == "workspace" {
                        self.whole.remove(id);
                    }
                }
                _ => {}
            }
        }
    }

    /// A full projection was folded: the fold holds every live resource, so each workspace
    /// that it holds is whole.
    fn completed(&mut self) {
        self.complete = true;
        let workspaces = self
            .values
            .keys()
            .filter(|(resource, _)| resource == "workspace")
            .map(|(_, id)| id.clone())
            .collect::<Vec<_>>();
        self.whole.extend(workspaces);
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
                                && equal_without_workspace_key(value, &change["value"]))
                    })
                }
                _ => false,
            }
    }
}

/// Whether `stated` (a folded value) already says what the decorated upsert `value` says: equal, or equal
/// without `extra.key` (a raw projection value never carries it).
pub(crate) fn workspace_value_stated(stated: &Value, value: &Value) -> bool {
    stated == value || equal_without_workspace_key(stated, value)
}

/// A workspace value's `extra` object: `Some(None)` when absent, `None` when not an object.
fn workspace_extra(
    object: &serde_json::Map<String, Value>,
) -> Option<Option<&serde_json::Map<String, Value>>> {
    match object.get("extra") {
        None => Some(None),
        Some(Value::Object(extra)) => Some(Some(extra)),
        Some(_) => None,
    }
}

/// `without_workspace_key(a) == without_workspace_key(b)`, compared in place:
/// the fold checks every workspace of a projection, and a copy of each per
/// check was a create's cost growing with the session.
fn equal_without_workspace_key(a: &Value, b: &Value) -> bool {
    let (Some(a), Some(b)) = (a.as_object(), b.as_object()) else { return a == b };
    let others_equal = |x: &serde_json::Map<String, Value>, y: &serde_json::Map<String, Value>| {
        x.iter()
            .filter(|(field, _)| *field != "extra")
            .all(|(field, value)| y.get(field) == Some(value))
    };
    let (Some(extra_a), Some(extra_b)) = (workspace_extra(a), workspace_extra(b)) else {
        return without_workspace_key(&Value::Object(a.clone()))
            == without_workspace_key(&Value::Object(b.clone()));
    };
    let without_key_len = |extra: Option<&serde_json::Map<String, Value>>| {
        extra.map_or(0, |extra| extra.len() - usize::from(extra.contains_key("key")))
    };
    let extras_equal = without_key_len(extra_a) == without_key_len(extra_b)
        && extra_a.is_none_or(|extra_a| {
            extra_a
                .iter()
                .filter(|(name, _)| *name != "key")
                .all(|(name, value)| extra_b.and_then(|extra_b| extra_b.get(name)) == Some(value))
        });
    a.len() - usize::from(a.contains_key("extra")) == b.len() - usize::from(b.contains_key("extra"))
        && others_equal(a, b)
        && extras_equal
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

    /// The workspace values the fold holds now (after catching up), keyed by public id: each is what the journal
    /// states for that workspace, and a workspace that is absent is one the fold cannot speak for. `None` when
    /// the journal head cannot be read. A copy for a commit that prunes its workspace upserts against it
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

    /// Whether the fold holds every live topology resource (a full projection was folded).
    #[cfg(test)]
    pub(crate) fn public_fold_complete_for_test(&self) -> bool {
        self.public_fold.as_ref().is_some_and(|fold| fold.complete)
    }

    /// Reads of the fold's `complete` flag on this thread (see
    /// `PublicTopologyFold::holds_every_resource`).
    #[cfg(test)]
    pub(crate) fn complete_reads_for_test() -> u64 {
        COMPLETE_READS.with(Cell::get)
    }

    /// Record a committed resource revision whose journaled changes were
    /// `journaled`. When they are the changes of a full topology projection
    /// (`full_projection`), the fold holds every live resource after them:
    /// each upsert of the projection is one the fold held with that value
    /// (pruned) or one that `journaled` states. That needs the prune and
    /// this call to see the same fold: each commit path runs both in one
    /// hold of the registry.
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
        self.record_journaled_public_fold(previous_revision, revision, &decorated, full_projection);
    }

    /// [`Self::record_public_fold`] for changes that are already what the journal record of the
    /// revision states (`journal_resource_record` gives them): they are folded as they are, with
    /// no second read of the state rows. A commit that states many workspaces (a workspace close
    /// states each workspace after the closed one) read the state fields of each one two times.
    pub(super) fn record_journaled_public_fold(
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
                if full_projection {
                    fold.completed();
                }
            }
            // Not at this commit's base: lost. The next use starts it again at the journal head.
            Some(_) => self.public_fold = None,
            // Lost, and not started again when this commit pruned (the journal head could not
            // be read): the record's own values are what the journal states at `revision`.
            // Whether they are every live resource is not known here, so it is not complete,
            // and it holds no workspace whole (`since` is this revision).
            None => {
                let mut fold =
                    PublicTopologyFold { revision, since: revision, ..Default::default() };
                fold.apply(journaled);
                self.public_fold = Some(fold);
            }
        }
    }

    /// `deltas` without the projection upserts the journal already states,
    /// or `None` when the fold is lost and cannot start again (the journal
    /// head cannot be read): nothing to prune against.
    pub(crate) fn prune_stated_projection_deltas(
        &mut self,
        deltas: &Value,
    ) -> anyhow::Result<Option<Value>> {
        self.catch_up_public_fold();
        if self.public_fold.is_none() {
            return Ok(None);
        }
        self.prune_stated_topology_deltas(deltas).map(Some)
    }

    /// A resource patch commit at `revision` journaled the changes of a full
    /// topology projection (`Mux::commit_resource_mutation_plan` and
    /// `Mux::commit_full_resource_projection_locked`, which record no other
    /// way): the fold holds every live resource after it. `journaled` is
    /// what the record states, pruned or not.
    pub(crate) fn record_full_projection_fold(&mut self, revision: u64, journaled: &Value) {
        match self.public_fold.as_ref().map(|fold| fold.revision) {
            // Held before this commit: it reads the commit back from the journal. Each upsert
            // of the projection is then one it held with that value (pruned) or one the record
            // states.
            Some(held) if held < revision => {
                if self.catch_up_public_fold()
                    && let Some(fold) = self.public_fold.as_mut()
                {
                    fold.completed();
                }
            }
            // Started again at the head after this commit: it does not hold the record's values.
            Some(_) => {}
            // Lost, and not started again when the commit pruned: start it from the record.
            None => {
                self.record_public_fold(revision.saturating_sub(1), revision, journaled, true);
            }
        }
    }

    /// Apply every resource record committed since the fold's revision. A fold that is lost, or
    /// that the journal cannot bring to its head (a gap, a read failure), starts again empty at
    /// the head: it then drops nothing, which is exact at any revision. Returns whether the fold
    /// held before the call is the one held after it.
    fn catch_up_public_fold(&mut self) -> bool {
        let held = self.public_fold.take().and_then(|fold| self.caught_up(fold));
        let kept = held.is_some();
        self.public_fold = held.or_else(|| {
            let revision = current_resource_revision(&self.connection.get()).ok()?;
            Some(PublicTopologyFold { revision, since: revision, ..Default::default() })
        });
        kept
    }

    /// Whether the fold holds each live value of `workspace` (see the module text). No catch-up
    /// (a shared borrow): a fold that is behind the journal still holds the workspace whole,
    /// because each record that it has yet to fold states its own values. A commit path may
    /// read this; it does not read the `complete` flag.
    pub(crate) fn workspace_is_whole(
        &self,
        workspace: &crate::resource::WorkspacePublicId,
    ) -> bool {
        self.public_fold.as_ref().is_some_and(|fold| fold.whole.contains(workspace.as_str()))
    }

    /// The commit at `revision` stated `workspaces` again from the live tree: each live value
    /// of each one was in its changes, and the commit dropped only the ones that this fold held
    /// with that value. So the fold holds them whole once it has folded that record. A fold
    /// that started at or after `revision` did not fold it and marks none: the next scoped
    /// commit in such a workspace states it again.
    pub(crate) fn mark_workspaces_whole(
        &mut self,
        revision: u64,
        workspaces: &[crate::resource::WorkspacePublicId],
    ) {
        if workspaces.is_empty() {
            return;
        }
        self.catch_up_public_fold();
        let Some(fold) = self.public_fold.as_mut() else { return };
        if fold.since >= revision || fold.revision < revision {
            return;
        }
        for workspace in workspaces {
            let id = workspace.to_string();
            // A workspace that a later record deleted is not held.
            if fold.values.contains_key(&("workspace".to_string(), id.clone())) {
                fold.whole.insert(id);
            }
        }
    }

    /// How many workspaces the fold holds whole.
    #[cfg(test)]
    pub(crate) fn whole_workspaces_for_test(&self) -> usize {
        self.public_fold.as_ref().map_or(0, |fold| fold.whole.len())
    }

    /// `fold` with every resource record after its revision applied, or `None` when the journal
    /// cannot supply them.
    fn caught_up(&self, mut fold: PublicTopologyFold) -> Option<PublicTopologyFold> {
        loop {
            let head = current_resource_revision(&self.connection.get()).ok()?;
            if fold.revision == head {
                return Some(fold);
            }
            if fold.revision > head {
                return None;
            }
            let page = self.resource_events_after(fold.revision).ok()?;
            if page.batches.is_empty() {
                return None;
            }
            for batch in page.batches {
                if batch.previous_revision != fold.revision {
                    return None;
                }
                fold.apply(&batch.changes);
                fold.revision = batch.revision;
            }
        }
    }

    /// What the journal states for one topology resource: `Some(Some(value))`, `Some(None)` when
    /// it states none, or `None` when the fold cannot tell (it is lost, behind the store, or
    /// does not hold the resource and is not complete). No catch-up: callers hold only a shared
    /// registry borrow. The debug cross-check is the one caller.
    pub(crate) fn stated_topology_value(&self, resource: &str, id: &str) -> Option<Option<Value>> {
        let fold = self.public_fold.as_ref()?;
        let head = current_resource_revision(&self.connection.get()).ok()?;
        if fold.revision != head {
            return None;
        }
        match fold.values.get(&(resource.to_string(), id.to_string())) {
            Some(value) => Some(Some(value.clone())),
            None => fold.holds_every_resource().then_some(None),
        }
    }

    /// The value the fold holds for one topology resource, after catching
    /// up; `None` when the fold is lost and cannot start again.
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

#[cfg(test)]
mod workspace_key_comparison_tests {
    use super::{equal_without_workspace_key, without_workspace_key};
    use serde_json::json;

    /// The in-place comparison answers as the copying one did.
    #[test]
    fn the_comparison_in_place_matches_the_copies() {
        let values = [
            json!({"id": "w", "name": "a"}),
            json!({"id": "w", "name": "b"}),
            json!({"id": "w", "name": "a", "extra": {}}),
            json!({"id": "w", "name": "a", "extra": {"key": "k"}}),
            json!({"id": "w", "name": "a", "extra": {"key": "k2"}}),
            json!({"id": "w", "name": "a", "extra": {"key": "k", "title": "t"}}),
            json!({"id": "w", "name": "a", "extra": {"title": "t"}}),
            json!({"id": "w", "name": "a", "extra": {"title": "u"}}),
            json!({"id": "w", "name": "a", "extra": {"title": "t", "color": "c"}}),
            json!({"id": "w", "name": "a", "focused": true}),
            json!({"id": "w", "extra": {"key": "k"}}),
            json!({"id": "w", "name": "a", "extra": "odd"}),
            json!("not an object"),
        ];
        for a in &values {
            for b in &values {
                assert_eq!(
                    equal_without_workspace_key(a, b),
                    without_workspace_key(a) == without_workspace_key(b),
                    "{a} vs {b}"
                );
            }
        }
    }
}
