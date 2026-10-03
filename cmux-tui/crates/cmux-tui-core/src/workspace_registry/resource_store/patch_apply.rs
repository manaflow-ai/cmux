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
    let patch = prune_unchanged_resource_changes(transaction, patch)?;
    // Closes by any path land in the closed history before their rows go.
    crate::state::closed_history_store::capture_closed(transaction, &patch)?;
    retarget_restarted_tabs(transaction, &patch)?;
    apply_effective_resource_patch(transaction, &patch, revision)?;
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
    let patch = prune_unchanged_resource_changes(transaction, patch)?;
    retarget_restarted_tabs(transaction, &patch)?;
    apply_effective_resource_patch(transaction, &patch, revision)?;
    Ok(patch)
}

/// Moves each restarted tab of `patch` to its new terminal. That is the only
/// content change the store allows: the stored content must be a terminal
/// whose host has exited, and the new content a terminal (`upsert_resource_tab`
/// then checks that it exists); every other content change is still refused
/// there. It runs before every other change of `patch`, so closing the dead
/// terminal in the same patch (`TombstoneTerminal`) leaves the tab alone.
fn retarget_restarted_tabs(
    transaction: &Transaction<'_>,
    patch: &ResourcePatch,
) -> anyhow::Result<()> {
    for change in &patch.changes {
        let ResourceChange::UpsertTab(tab) = change else { continue };
        let ContentPublicId::Terminal(new_terminal) = &tab.content_id else { continue };
        let stored = transaction
            .query_row(
                "SELECT content_kind, content_id FROM resource_tabs
                 WHERE public_id = ?1 AND deleted_revision IS NULL",
                [tab.public_id.as_str()],
                |row| Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?)),
            )
            .optional()?;
        let Some((kind, old_terminal)) = stored else { continue };
        if kind != "terminal" || old_terminal == new_terminal.as_str() {
            continue;
        }
        let old_host =
            live_resource_field(transaction, "resource_terminals", "terminal_id", &old_terminal)?;
        let exited = match old_host {
            Some(host) => read_terminal(transaction, &host)?
                .is_some_and(|terminal| terminal.lifecycle == TerminalLifecycle::Exited),
            None => false,
        };
        if !exited {
            // Left for upsert_resource_tab to refuse as a content change.
            continue;
        }
        transaction.execute(
            "UPDATE resource_tabs SET content_id = ?1
             WHERE public_id = ?2 AND deleted_revision IS NULL",
            params![new_terminal.as_str(), tab.public_id.as_str()],
        )?;
    }
    Ok(())
}
