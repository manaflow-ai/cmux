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
    let closing = closing_browsers(transaction, &patch)?;
    apply_effective_resource_patch(transaction, &patch, revision)?;
    delete_closed_browser_rows(transaction, &closing)?;
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
    let closing = closing_browsers(transaction, &patch)?;
    apply_effective_resource_patch(transaction, &patch, revision)?;
    delete_closed_browser_rows(transaction, &closing)?;
    Ok(patch)
}

/// The browser contents `patch` may close: tombstoned browsers and the
/// content of tabs it closes with their content (read before the patch
/// applies, while the tab rows are live).
fn closing_browsers(
    transaction: &Transaction<'_>,
    patch: &ResourcePatch,
) -> anyhow::Result<Vec<String>> {
    let mut browsers = Vec::new();
    for change in &patch.changes {
        match change {
            ResourceChange::TombstoneBrowser { public_id } => {
                browsers.push(public_id.as_str().to_string());
            }
            ResourceChange::TombstoneTab { tab_id, close_content: true } => {
                let content = transaction
                    .query_row(
                        "SELECT content_id FROM resource_tabs
                         WHERE public_id = ?1 AND content_kind = 'browser'
                           AND deleted_revision IS NULL",
                        [tab_id.as_str()],
                        |row| row.get::<_, String>(0),
                    )
                    .optional()?;
                browsers.extend(content);
            }
            _ => {}
        }
    }
    Ok(browsers)
}

/// Closed browser content leaves no frontend or conversation record behind
/// (the closed history captured what reopen needs before the patch applied).
/// Only content the patch actually tombstoned is touched.
fn delete_closed_browser_rows(
    transaction: &Transaction<'_>,
    browsers: &[String],
) -> anyhow::Result<()> {
    for browser in browsers {
        let closed = transaction
            .query_row(
                "SELECT 1 FROM resource_browsers
                 WHERE public_id = ?1 AND deleted_revision IS NOT NULL",
                [browser],
                |_| Ok(()),
            )
            .optional()?
            .is_some();
        if closed {
            crate::state::conversation_tabs_store::delete_closed_browser_rows(
                transaction,
                browser,
            )?;
        }
    }
    Ok(())
}
