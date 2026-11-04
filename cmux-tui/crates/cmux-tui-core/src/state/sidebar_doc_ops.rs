//! The `sidebar.*` wire methods (`sidebar-doc-v1`, CONTRACT.md "Wire"): each
//! mutation is one list of reducer ops committed on the state commit path
//! (rows, replay record and one `session.events` batch with a
//! `state_upsert`/`state_delete` per changed `sidebar_item` and
//! `sidebar_section`, plus the `sidebar_doc` change `{revision,
//! previous_revision, idempotency_key}`). The result is `{revision,
//! inverse}`; `sidebar.apply {ops: inverse}` undoes it (and returns the
//! redo). A refusal is `validation.invalid` with the reducer's reason
//! (`cross_machine`, `provider_owned`, `nesting`, ...) and writes nothing.
//!
//! When Pinned changes, the batch also restates the old `sidebar_layout`
//! (its `sec_pinned` tiles are the Pinned items). The changed items are
//! written back to the old personal rows and groups
//! ([`crate::state::sidebar_doc_sync::write_back`]) and `personal_revision`
//! advances, so clients of `sidebar-layout-v1` and `profiles-v1` follow.
//!
//! `reset` and `unpin` also close this machine's placed workspaces that are
//! no longer open ([`closes_for_reset`]): Pinned and custom sections kept
//! them, and the machine sections a reset or an unpin moves them into do
//! not. The close removes the groups it empties there, as closing the last
//! workspace does.

use std::collections::HashSet;

use rusqlite::Connection;
use serde_json::{Map, json};

use cmux_layout_reducer::sidebar_doc::reduce::{self, Applied};
use cmux_layout_reducer::sidebar_doc::{Doc, Item, Op, PINNED_SECTION_ID, WorkspaceRef};

use crate::mux::*;
use crate::state::commit::StateEffects;
use crate::state::prelude::*;
use crate::state::sidebar_doc_legacy::{mint_item_id, project_layout};
use crate::state::sidebar_doc_store as store;
use crate::state::sidebar_layout_store as layout_store;
use crate::state::store::{StateChanges, StateCommit, state_upsert};
use crate::workspace_registry::personal_store::commit_personal;

/// The largest request a client may send.
const MAX_OPS_BYTES: usize = 256 * 1024;
const MAX_OPS: usize = 500;

/// The reducer ops of one `sidebar.*` mutation's fields.
pub(crate) fn ops_of(operation: &str, fields: &Map<String, Value>) -> anyhow::Result<Vec<Op>> {
    anyhow::ensure!(
        serde_json::to_string(fields)?.len() <= MAX_OPS_BYTES,
        "bad request: request exceeds {MAX_OPS_BYTES} bytes"
    );
    if operation == "sidebar.apply" {
        let ops = fields.get("ops").cloned().unwrap_or_default();
        let ops: Vec<Op> = serde_json::from_value(ops)
            .map_err(|error| anyhow::anyhow!("bad request: ops: {error}"))?;
        anyhow::ensure!(ops.len() <= MAX_OPS, "bad request: too_many");
        return Ok(ops);
    }
    let tag = operation.strip_prefix("sidebar.").context("not a sidebar operation")?;
    let mut object = fields.clone();
    object.insert("op".into(), Value::String(tag.into()));
    let op: Op = serde_json::from_value(Value::Object(object))
        .map_err(|error| anyhow::anyhow!("bad request: {error}"))?;
    Ok(vec![op])
}

/// When `ops` hold a `reset` or an `unpin`, append a `close` of this machine's placed
/// workspaces that are not open (a reset or an unpin moves them from Pinned
/// or a custom section into their machine section, which does not keep
/// closed items).
pub(crate) fn closes_for_reset(
    connection: &Connection,
    doc: &Doc,
    ops: &mut Vec<Op>,
) -> anyhow::Result<()> {
    if !returns_closed_items(ops) || !crate::state::store::state_tables_ready(connection)? {
        return Ok(());
    }
    let local = crate::state::values::local_registry_id(connection)?;
    let open: HashSet<String> = {
        let mut statement = connection
            .prepare("SELECT public_id FROM resource_workspaces WHERE deleted_revision IS NULL")?;
        statement.query_map([], |row| row.get::<_, String>(0))?.collect::<Result<_, _>>()?
    };
    let refs: Vec<WorkspaceRef> = doc
        .items_unordered()
        .filter_map(|item| item.body.workspace())
        .filter(|reference| {
            reference.session_id == local && !open.contains(&reference.workspace_id)
        })
        .cloned()
        .collect();
    if !refs.is_empty() {
        ops.push(Op::Close { refs });
    }
    Ok(())
}

/// Whether `ops` can move closed workspaces out of a section that keeps them
/// (Pinned, custom) into a machine section, which does not.
fn returns_closed_items(ops: &[Op]) -> bool {
    ops.iter().any(|op| matches!(op, Op::Reset | Op::Unpin { .. }))
}

/// Whether a commit changed what Pinned shows (an item that is in Pinned,
/// or was at its top level), so the old `sidebar_layout` projection must be
/// restated.
fn touches_pinned(applied: &Applied) -> bool {
    let was_pinned = |item: &Item| item.section == PINNED_SECTION_ID && item.parent.is_none();
    applied.changes.items.iter().any(|item| item.section == PINNED_SECTION_ID)
        || applied.previous_items.values().flatten().any(was_pinned)
        || applied.changes.sections.iter().any(|section| section.id == PINNED_SECTION_ID)
        || applied.changes.deleted_sections.iter().any(|id| id == PINNED_SECTION_ID)
}

impl Mux {
    /// Commit `ops` of `operation` under `mutation`'s idempotency key.
    pub(crate) fn state_sidebar_apply(
        &self,
        mutation: &WorkspaceMutation,
        operation: &str,
        fields: &Map<String, Value>,
    ) -> anyhow::Result<StateCommit> {
        let ops = ops_of(operation, fields)?;
        let fingerprint = json!({"operation": operation, "fields": fields});
        self.commit_sidebar_ops(mutation, operation, &fingerprint, |_, _| Ok(ops))
    }

    /// Commit the reducer ops `ops_for` gives for the current document (read
    /// in the commit's transaction, after the old writes are synced) under
    /// `mutation`'s idempotency key and `fingerprint`: the rows, the
    /// `session.events` batch and the write-back to the old personal rows,
    /// as every `sidebar.*` mutation does. The result is `{revision, inverse}`.
    pub(crate) fn commit_sidebar_ops(
        &self,
        mutation: &WorkspaceMutation,
        operation: &str,
        fingerprint: &Value,
        ops_for: impl FnOnce(&rusqlite::Transaction<'_>, &Doc) -> anyhow::Result<Vec<Op>>,
    ) -> anyhow::Result<StateCommit> {
        let key = mutation.id.clone();
        self.commit_state(
            mutation,
            operation,
            fingerprint,
            None,
            StateEffects::EVENTS_ONLY,
            |transaction, _| {
                // Old writes first (normally none are pending).
                crate::state::sidebar_doc_sync::sync_from_legacy(transaction)?;
                // A migration that failed at open (logged, retried at the
                // next open) leaves no document to change.
                anyhow::ensure!(
                    store::is_migrated(transaction)?,
                    "sidebar document unavailable: its migration did not complete"
                );
                store::with_doc_mut(transaction, |doc| {
                    let mut ops = ops_for(transaction, doc)?;
                    closes_for_reset(transaction, doc, &mut ops)?;
                    anyhow::ensure!(
                        !reduce::changes_app_kind(doc, &ops),
                        "bad request: {}",
                        cmux_layout_reducer::sidebar_doc::Refusal::InvalidValue.as_str()
                    );
                    let previous_revision = doc.revision;
                    let mut mint = mint_item_id;
                    let applied = reduce::apply_in_place(doc, &ops, &mut mint)
                        .map_err(|refusal| anyhow::anyhow!("bad request: {}", refusal.as_str()))?;
                    let result = json!({
                        "revision": doc.revision.to_string(),
                        "inverse": applied.inverse,
                    });
                    if applied.changes.is_empty() {
                        return Ok(StateChanges::new(result, Vec::new()));
                    }
                    let mut events = store::write_changes(
                        transaction,
                        previous_revision,
                        doc.revision,
                        &applied.changes,
                        Some(&key),
                    )?;
                    let pinned = touches_pinned(&applied);
                    if pinned {
                        let layout = project_layout(&layout_store::document(transaction)?, doc);
                        let value = layout_store::snapshot_value(&layout)?;
                        events.push(state_upsert(layout_store::RESOURCE, layout_store::ID, value));
                    }
                    // Old readers (the TUI, iOS) follow through the personal
                    // rows and `personal-changed`.
                    let wrote =
                        crate::state::sidebar_doc_sync::write_back(transaction, doc, &applied)?;
                    if wrote || pinned {
                        commit_personal(
                            transaction,
                            "personal.sidebar_doc.updated",
                            Vec::new(),
                            &json!({"revision": doc.revision}),
                        )?;
                    }
                    Ok(StateChanges::new(result, events))
                })
            },
        )
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Unpin moves a pinned tree, closed members and all, back into its machine
    /// section; the close that follows removes them and the groups they empty,
    /// as closing the last workspace does there (a283, pinning-DESIGN.md).
    #[test]
    fn unpin_and_reset_close_what_is_not_open() {
        assert!(returns_closed_items(&[Op::Reset]));
        assert!(returns_closed_items(&[Op::Unpin { items: vec!["g".into()] }]));
        assert!(!returns_closed_items(&[Op::Pin { items: vec!["g".into()] }]));
    }
}
