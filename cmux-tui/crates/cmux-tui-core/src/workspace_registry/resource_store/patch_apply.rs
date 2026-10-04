use super::*;

/// Apply `patch` and return the changes that were actually written.
///
/// A full topology projection restates every live resource on each commit.
/// Changes whose target row already holds the same value are dropped first,
/// so a commit rewrites (and journals) only the rows it changes. Callers
/// journal the returned patch, not their input.
pub(crate) fn apply_resource_patch(
    transaction: &Transaction<'_>,
    patch: &ResourcePatch,
    revision: i64,
) -> anyhow::Result<ResourcePatch> {
    // Before pruning: a legacy registry rewrite may have written the name.
    crate::state::app_screens_store::note_companion_renames(transaction, patch)?;
    let patch = prune_unchanged_resource_changes(transaction, patch)?;
    // Closes by any path land in the closed history before their rows go.
    crate::state::closed_history_store::capture_closed(transaction, &patch)?;
    // `app-screens-v1`: the authoritative check, on the rows being committed.
    let apps = crate::state::app_commit_rules::before_patch(transaction)?;
    apply_effective_resource_patch(transaction, &patch, revision)?;
    crate::state::app_commit_rules::check_committed_patch(transaction, &patch, apps)?;
    Ok(patch)
}

/// A mutation whose result is the snapshot of the resource it changed
/// returns it with the state fields a fresh snapshot shows.
pub(super) fn decorate_snapshot_result(
    transaction: &Transaction<'_>,
    operation: &str,
    result: &mut Value,
) -> anyhow::Result<()> {
    // Topology results carry the committed value as `public_value`.
    let target = if result.get("public_value").is_some_and(Value::is_object) {
        &mut result["public_value"]
    } else {
        result
    };
    let Some(id) = target.get("id").and_then(Value::as_str) else { return Ok(()) };
    let resource = match (operation.split('.').next(), id.split('_').next()) {
        (Some("workspace"), Some("ws")) => "workspace",
        (Some("screen"), Some("screen")) => "screen",
        (Some("tab"), Some("tab")) => "tab",
        _ => return Ok(()),
    };
    if !crate::state::store::state_tables_ready(transaction)? {
        return Ok(());
    }
    crate::state::values::decorate_value(transaction, resource, target)
}

/// Apply a patch whose closes are not user closes (a terminal that exited
/// on its own), so they stay out of the closed history.
pub(crate) fn apply_resource_patch_unrecorded(
    transaction: &Transaction<'_>,
    patch: &ResourcePatch,
    revision: i64,
) -> anyhow::Result<ResourcePatch> {
    crate::state::app_screens_store::note_companion_renames(transaction, patch)?;
    let patch = prune_unchanged_resource_changes(transaction, patch)?;
    let apps = crate::state::app_commit_rules::before_patch(transaction)?;
    apply_effective_resource_patch(transaction, &patch, revision)?;
    crate::state::app_commit_rules::check_committed_patch(transaction, &patch, apps)?;
    Ok(patch)
}
