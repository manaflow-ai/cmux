//! The debug cross-check of a scoped projection against the full one
//! (scoped_projection.rs): the rows both would write and the public values
//! each would publish, after the fields a live surface changes on its own.
//!
//! And the session check: one full projection, not committed, against what the journal states.
//! The worker of the restatement after a start runs it one time, after its last part
//! (`mux/startup_restore/restate_parts.rs`). After a start the fold is not complete, so the
//! cross-check of a scoped commit cannot tell for a value outside its scope that the fold does
//! not hold; this one compare reads each value of the session that the fold holds.

use std::time::{Duration, Instant};

use super::*;

/// What the journal states (by the registry's fold) against one full projection of the live
/// tree.
#[derive(Debug, Clone, Default)]
pub(crate) struct JournalCheck {
    /// Values of the full projection that the journal states as the projection does.
    pub(crate) equal: usize,
    /// Values of the full projection that the fold cannot tell about (it does not hold them and
    /// it is not complete; or it is lost).
    pub(crate) unknown: usize,
    /// The first value that the journal states in another way, or the first delete that the
    /// full projection has.
    pub(crate) difference: Option<String>,
    /// How long the compare held the registry and state locks.
    pub(crate) hold: Duration,
}

impl Mux {
    /// [`Self::session_journal_check`] in a build that runs the cross-check (a Debug build, or a
    /// daemon with `CMUX_TUI_PROJECTION_CROSSCHECK=1`); `None` in any other build. A compare
    /// that fails is a difference. One line on stderr for a difference.
    pub(crate) fn session_journal_crosscheck(&self) -> Option<JournalCheck> {
        if !scoped_projection::crosscheck_enabled() {
            return None;
        }
        let check = self.session_journal_check().unwrap_or_else(|error| JournalCheck {
            difference: Some(format!("the compare failed: {error:#}")),
            ..JournalCheck::default()
        });
        if let Some(difference) = check.difference.as_ref() {
            eprintln!(
                "cmux-tui: session restate: the journal differs from the full projection: \
                 {difference}"
            );
        }
        Some(check)
    }

    /// One full projection of the live tree against the journal, under the registry and state
    /// locks (one hold that grows with the session). It commits nothing and it does not count
    /// as a full projection in the projection stats. The reference rebuilds each index, so the
    /// indexes of the state are put back, as the cross-check of a scoped commit does.
    pub(crate) fn session_journal_check(&self) -> anyhow::Result<JournalCheck> {
        let mut registry =
            self.workspace_registry.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        let held = Instant::now();
        // The fold answers only at the journal head (`stated_topology_value`).
        registry.catch_up_public_fold();
        let mut state =
            self.lock_state_pinned(&registry).unwrap_or_else(std::sync::PoisonError::into_inner);
        let indexes = state.resource_indexes.clone();
        let result = Value::Object(Default::default());
        let full = self.full_projection_spans(&registry, &mut state, result);
        state.resource_indexes = indexes;
        let (full, _) = full?;
        let mut check = journal_difference(&registry, &full)?;
        check.hold = held.elapsed();
        Ok(check)
    }
}

/// What the journal states for one value that a full projection publishes.
enum Stated {
    /// The fold cannot tell.
    Unknown,
    /// The published value, in one of its 2 forms (see [`journal_states`]).
    Same,
    /// Another value, or none.
    Other(Option<Value>),
}

/// The journal states a value as its last restatement decorated it: with today's state rows (a
/// grouped tab, cx-d0d.61), or from before a state mutation that restates nothing (a screen
/// pinned after it was stated). So `decorated` and `value` both match.
fn journal_states(
    registry: &WorkspaceRegistry,
    resource: &str,
    id: &str,
    value: &Value,
    decorated: &Value,
) -> Stated {
    let Some(stated) = registry.stated_topology_value(resource, id) else {
        return Stated::Unknown;
    };
    let stated = stated.map(|value| stable_value(&json!({"resource":resource,"value":value})));
    if stated.as_ref() == Some(decorated) || stated.as_ref() == Some(value) {
        Stated::Same
    } else {
        Stated::Other(stated)
    }
}

/// The key of one public change: its kind, resource and id.
fn key_of(change: &Value) -> (String, String, String) {
    (
        change["kind"].as_str().unwrap_or_default().to_string(),
        change["resource"].as_str().unwrap_or_default().to_string(),
        change["id"].as_str().unwrap_or_default().to_string(),
    )
}

/// `full` against the journal: each upsert against the value that the fold holds, and a delete
/// (a row of the store that the live tree does not have) as a difference.
fn journal_difference(
    registry: &WorkspaceRegistry,
    full: &ResourceEffectProjection,
) -> anyhow::Result<JournalCheck> {
    let mut decorated = full.changes.clone();
    crate::state::values::decorate_changes(&registry.connection.get(), &mut decorated)?;
    let empty = Vec::new();
    let decorated_values = decorated
        .as_array()
        .unwrap_or(&empty)
        .iter()
        .map(|change| (key_of(change), stable_value(change)))
        .collect::<HashMap<_, _>>();
    let mut check = JournalCheck::default();
    for change in full.changes.as_array().unwrap_or(&empty) {
        let key = key_of(change);
        let value = stable_value(change);
        let decorated = decorated_values.get(&key).unwrap_or(&value);
        let (kind, resource, id) = &key;
        let difference = if kind == "delete" {
            Some(format!("the full projection deletes {resource} {id}"))
        } else {
            match journal_states(registry, resource, id, &value, decorated) {
                Stated::Unknown => {
                    check.unknown = check.unknown.saturating_add(1);
                    None
                }
                Stated::Same => {
                    check.equal = check.equal.saturating_add(1);
                    None
                }
                Stated::Other(stated) => Some(format!(
                    "{resource} {id}: the journal states {stated:?}, the full projection \
                     {decorated}"
                )),
            }
        };
        if check.difference.is_none() {
            check.difference = difference;
        }
    }
    Ok(check)
}

/// `None` when `scoped` commits what `full` would (the same rows after
/// unchanged-row pruning, the same public values for what it restates, and
/// the same deletes); otherwise the first difference.
pub(super) fn projection_difference(
    registry: &WorkspaceRegistry,
    scoped: &ResourceEffectProjection,
    full: &ResourceEffectProjection,
) -> anyhow::Result<Option<String>> {
    use crate::workspace_registry::resource_store::prune_unchanged_resource_changes;
    let db = registry.connection.get();
    let transaction = db.unchecked_transaction()?;
    let scoped_rows = prune_unchanged_resource_changes(&transaction, &scoped.patch)?.changes;
    let full_rows = prune_unchanged_resource_changes(&transaction, &full.patch)?.changes;
    // The journal states values decorated with the state rows (pins, tab
    // groups, zoom: state/values.rs), so an omitted upsert is compared to
    // the full projection's value decorated the same way.
    let mut decorated = full.changes.clone();
    crate::state::values::decorate_changes(&transaction, &mut decorated)?;
    drop(transaction);
    if let Some(change) = scoped_rows.iter().find(|change| !full_rows.contains(change)) {
        return Ok(Some(format!("only the scoped projection writes {change:?}")));
    }
    if let Some(change) = full_rows.iter().find(|change| !scoped_rows.contains(change)) {
        return Ok(Some(format!("only the full projection writes {change:?}")));
    }
    let empty = Vec::new();
    let full_changes = full.changes.as_array().unwrap_or(&empty);
    let scoped_changes = scoped.changes.as_array().unwrap_or(&empty);
    let full_values = full_changes
        .iter()
        .map(|change| (key_of(change), stable_value(change)))
        .collect::<HashMap<_, _>>();
    let decorated_values = decorated
        .as_array()
        .unwrap_or(&empty)
        .iter()
        .map(|change| (key_of(change), stable_value(change)))
        .collect::<HashMap<_, _>>();
    let scoped_values = scoped_changes
        .iter()
        .map(|change| (key_of(change), stable_value(change)))
        .collect::<HashMap<_, _>>();
    for (change_key, value) in &scoped_values {
        if full_values.get(change_key) != Some(value) {
            return Ok(Some(format!(
                "the full projection does not publish {change_key:?} {value}"
            )));
        }
    }
    for (change_key, value) in &full_values {
        if scoped_values.contains_key(change_key) {
            continue;
        }
        let (kind, resource, id) = change_key;
        if kind == "delete" {
            return Ok(Some(format!("the scoped projection omits the delete of {resource} {id}")));
        }
        // An upsert the scoped walk left out must be one the journal states
        // already (when the fold can tell), in one of its 2 forms.
        let decorated = decorated_values.get(change_key).unwrap_or(value);
        if let Stated::Other(stated) = journal_states(registry, resource, id, value, decorated) {
            return Ok(Some(format!(
                "the scoped projection omits a changed {resource} {id}: the journal states \
                 {stated:?}, the full projection {decorated}"
            )));
        }
    }
    Ok(None)
}

/// A published value without the fields that a live surface changes on its
/// own threads (output revision, title, size, directory, status): two walks
/// a moment apart may read different ones.
fn stable_value(change: &Value) -> Value {
    let mut value = change["value"].clone();
    let volatile: &[&str] = match change["resource"].as_str() {
        Some("terminal") => &["stream_revision", "title", "cols", "rows", "cwd", "extra"],
        Some("browser") => &["title", "loading", "status", "error", "frames_stalled", "size"],
        _ => &[],
    };
    if let Some(fields) = value.as_object_mut() {
        for field in volatile {
            fields.remove(*field);
        }
    }
    value
}
