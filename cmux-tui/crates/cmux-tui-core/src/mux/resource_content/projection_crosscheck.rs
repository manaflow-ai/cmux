//! The debug cross-check of a scoped projection against the full one
//! (scoped_projection.rs): the rows both would write and the public values
//! each would publish, after the fields a live surface changes on its own.

use super::*;

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
    let key = |change: &Value| {
        (
            change["kind"].as_str().unwrap_or_default().to_string(),
            change["resource"].as_str().unwrap_or_default().to_string(),
            change["id"].as_str().unwrap_or_default().to_string(),
        )
    };
    let empty = Vec::new();
    let full_changes = full.changes.as_array().unwrap_or(&empty);
    let scoped_changes = scoped.changes.as_array().unwrap_or(&empty);
    let full_values = full_changes
        .iter()
        .map(|change| (key(change), stable_value(change)))
        .collect::<HashMap<_, _>>();
    let decorated_values = decorated
        .as_array()
        .unwrap_or(&empty)
        .iter()
        .map(|change| (key(change), stable_value(change)))
        .collect::<HashMap<_, _>>();
    let scoped_values = scoped_changes
        .iter()
        .map(|change| (key(change), stable_value(change)))
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
        // already (when the fold can tell).
        if let Some(stated) = registry.stated_topology_value(resource, id) {
            let stated =
                stated.map(|value| stable_value(&json!({"resource":resource,"value":value})));
            let value = decorated_values.get(change_key).unwrap_or(value);
            if stated.as_ref() != Some(value) {
                return Ok(Some(format!(
                    "the scoped projection omits a changed {resource} {id}: the journal states \
                     {stated:?}, the full projection {value}"
                )));
            }
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
