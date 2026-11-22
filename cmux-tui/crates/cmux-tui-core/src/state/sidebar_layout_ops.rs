//! `sidebar_layout.update`: one reducer op on the state commit path (row,
//! replay record and one `session.events` batch with a `state_upsert` of
//! resource `sidebar_layout`, id `user`), plus `personal-changed` for raw
//! clients.

use serde_json::json;

use crate::mux::*;
use crate::state::commit::StateEffects;
use crate::state::prelude::*;
use crate::state::sidebar_layout::{self, Op};
use crate::state::sidebar_layout_store::{self as store, ID, RESOURCE};
use crate::state::store::{StateChanges, StateCommit, state_upsert};
use crate::workspace_registry::personal_store::commit_personal;

/// The largest op a client may send (a section with its items).
const MAX_OP_BYTES: usize = 64 * 1024;

impl Mux {
    /// Apply `op` (the wire JSON of a sidebar layout op) under `mutation`'s
    /// idempotency key. A reducer reject is `validation.invalid` with the
    /// reason (`workspaces_required`, `unknown_item`, ...) and writes
    /// nothing; a no-op commits with no change.
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
                let current = store::document(transaction)?;
                let next = sidebar_layout::reduce(&current, &parsed)
                    .map_err(|reject| anyhow::anyhow!("bad request: {}", reject.as_str()))?;
                let value = store::snapshot_value(&next)?;
                if next.revision == current.revision {
                    return Ok(StateChanges::new(value, Vec::new()));
                }
                store::write_document(transaction, &next)?;
                // Raw-protocol clients (the Mac app) follow personal state
                // through `personal-changed`; bump `personal_revision` so they
                // refetch the layout (v2 clients read the state_upsert).
                commit_personal(
                    transaction,
                    "personal.sidebar_layout.updated",
                    Vec::new(),
                    &json!({"revision": next.revision}),
                )?;
                Ok(StateChanges::new(value.clone(), vec![state_upsert(RESOURCE, ID, value)]))
            },
        )
    }
}
