//! `sidebar_layout.update`: one reducer op on the state commit path (rows,
//! replay record and one `session.events` batch with a `state_upsert` of
//! resource `sidebar_layout`, id `user`).

use serde_json::json;

use crate::mux::*;
use crate::state::commit::StateEffects;
use crate::state::prelude::*;
use crate::state::sidebar_layout::{self, Op};
use crate::state::sidebar_layout_store::{self as store, ID, RESOURCE};
use crate::state::store::{StateChanges, StateCommit, state_upsert};

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
        let parsed: Op = serde_json::from_value(op.clone())
            .map_err(|error| anyhow::anyhow!("bad request: op: {error}"))?;
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
                Ok(StateChanges::new(value.clone(), vec![state_upsert(RESOURCE, ID, value)]))
            },
        )
    }
}
