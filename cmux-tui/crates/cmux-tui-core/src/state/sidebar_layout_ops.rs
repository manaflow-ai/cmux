//! `sidebar_layout.update`: one reducer op on the state commit path (row,
//! replay record and one `session.events` batch with a `state_upsert` of
//! resource `sidebar_layout`, id `user`), plus `personal-changed` for raw
//! clients. The `sec_pinned` tiles are the sidebar document's Pinned items
//! (sidebar-doc-v1): an op reduces on that projection, and a tile it adds,
//! removes or reorders is a Pinned op on the document in the same commit.
//! A section's `align` or `gap` follows into the document's section (every
//! machine section for the old workspaces section), and `layout.reset` is the
//! document's `reset`.

use serde_json::json;

use crate::mux::*;
use crate::state::commit::StateEffects;
use crate::state::prelude::*;
use crate::state::sidebar_doc_legacy::{
    mint_item_id, pinned_ops, project_layout, section_field_ops,
};
use crate::state::sidebar_doc_store as doc_store;
use crate::state::sidebar_layout::{self, Op};
use crate::state::sidebar_layout_store::{self as store, ID, RESOURCE};
use crate::state::store::{StateChanges, StateCommit, state_upsert};
use crate::workspace_registry::personal_store::commit_personal;
use cmux_layout_reducer::sidebar_doc::{Op as DocOp, reduce};

/// The largest op a client may send (a section with its items).
const MAX_OP_BYTES: usize = 64 * 1024;

impl Mux {
    /// Apply `op` (the wire JSON of a sidebar layout op) under `mutation`'s
    /// idempotency key. A reducer reject is `validation.invalid` with the
    /// reason (`workspaces_required`, `unknown_item`, ...) and writes
    /// nothing; a no-op commits with no change.
    #[track_caller]
    pub(crate) fn state_sidebar_layout_update(
        &self,
        mutation: &WorkspaceMutation,
        op: &Value,
    ) -> anyhow::Result<StateCommit> {
        anyhow::ensure!(
            serde_json::to_string(op)?.len() <= MAX_OP_BYTES,
            "bad request: op exceeds {MAX_OP_BYTES} bytes"
        );
        let parsed: Op = serde_json::from_value(op.clone())
            .map_err(|error| anyhow::anyhow!("bad request: op: {error}"))?;
        if let Some((field, value)) = parsed.introduced_unknown_value() {
            anyhow::bail!("bad request: op: unknown {field} {value:?}");
        }
        let fingerprint = json!({"operation": "sidebar_layout.update", "op": op});
        self.commit_state(
            mutation,
            "sidebar_layout.update",
            &fingerprint,
            None,
            StateEffects::EVENTS_ONLY,
            |transaction, _| {
                // The client reduced on the projection (its sec_pinned tiles
                // are the sidebar document's Pinned items, sidebar-doc-v1).
                let stored = store::document(transaction)?;
                // An unmigrated store (its migration failed at open and is
                // retried at the next) keeps the old behavior: the stored
                // tiles, no document ops.
                let migrated = doc_store::is_migrated(transaction)?;
                doc_store::with_doc_mut(transaction, |doc| {
                    let current =
                        if migrated { project_layout(&stored, doc) } else { stored.clone() };
                    let reduced = sidebar_layout::reduce(&current, &parsed)
                        .map_err(|reject| anyhow::anyhow!("bad request: {}", reject.as_str()))?;
                    let layout_changed = reduced.revision != current.revision;
                    // The document's reset runs also when the old layout is
                    // already the defaults (the document may still differ).
                    let doc_reset = migrated && matches!(parsed, Op::Reset);
                    if !layout_changed && !doc_reset {
                        return Ok(StateChanges::new(store::snapshot_value(&current)?, Vec::new()));
                    }
                    let mut ops = if !migrated {
                        Vec::new()
                    } else if matches!(parsed, Op::Reset) {
                        vec![DocOp::Reset]
                    } else {
                        let mut ops = pinned_ops(&current, &reduced, doc);
                        ops.extend(section_field_ops(&current, &reduced, doc));
                        ops
                    };
                    crate::state::sidebar_doc_ops::closes_for_reset(transaction, doc, &mut ops)?;
                    let mut events = Vec::new();
                    let mut doc_changed = false;
                    if !ops.is_empty() {
                        let previous_revision = doc.revision;
                        let mut mint = mint_item_id;
                        let applied =
                            reduce::apply_in_place(doc, &ops, &mut mint).map_err(|refusal| {
                                anyhow::anyhow!("bad request: {}", refusal.as_str())
                            })?;
                        doc_changed = !applied.changes.is_empty();
                        if doc_changed {
                            events = doc_store::write_changes(
                                transaction,
                                previous_revision,
                                doc.revision,
                                &applied.changes,
                                Some(&mutation.id),
                            )?;
                        }
                        crate::state::sidebar_doc_sync::write_back(transaction, doc, &applied)?;
                    }
                    if !layout_changed && !doc_changed {
                        return Ok(StateChanges::new(store::snapshot_value(&current)?, Vec::new()));
                    }
                    let next = if layout_changed {
                        let mut next = reduced;
                        next.revision = stored.revision + 1;
                        store::write_document(transaction, &next)?;
                        next
                    } else {
                        stored.clone()
                    };
                    let shown = if migrated { project_layout(&next, doc) } else { next.clone() };
                    let value = store::snapshot_value(&shown)?;
                    // Raw-protocol clients (the Mac app) follow personal
                    // state through `personal-changed`; bump
                    // `personal_revision` so they refetch the layout (v2
                    // clients read the state_upsert).
                    commit_personal(
                        transaction,
                        "personal.sidebar_layout.updated",
                        Vec::new(),
                        &json!({"revision": next.revision}),
                    )?;
                    events.push(state_upsert(RESOURCE, ID, value.clone()));
                    Ok(StateChanges::new(value, events))
                })
            },
        )
    }
}
