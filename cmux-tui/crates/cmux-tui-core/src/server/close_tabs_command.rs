//! Raw `close-tabs`: many placements and the terminals they end close in
//! one durable commit (`batch-close-v1`). With `close-reason-v1` an optional
//! `reason`: `session_end` (a browser session closing the tabs it opened for
//! itself) commits the same way but leaves no closed-history record.

use super::{
    MAX_CLOSE_TABS_SURFACES, MutationRequest, Mux, TabRef, batch_close_terminals_json,
    resolve_tab_refs, validate_client_transaction, workspace_mutation,
};
use crate::mux::CloseReason;
use serde_json::{Value, json};

pub(crate) const CLOSE_REASON_CAPABILITY: &str = "close-reason-v1";

pub(super) fn run(
    mux: &Mux,
    surfaces: &[TabRef],
    end_terminals: bool,
    transaction: Option<String>,
    reason: Option<String>,
    mutation: &MutationRequest,
) -> anyhow::Result<Value> {
    validate_client_transaction(transaction.as_deref())?;
    let reason = reason.as_deref().map(CloseReason::parse).transpose()?;
    let workspace_mutation = workspace_mutation(mutation)?;
    anyhow::ensure!(
        mutation.expected_generation.is_none() && mutation.expected_revision.is_none(),
        "close-tabs does not take expected_generation or expected_revision"
    );
    anyhow::ensure!(
        surfaces.len() <= MAX_CLOSE_TABS_SURFACES,
        "close-tabs takes at most {MAX_CLOSE_TABS_SURFACES} surfaces"
    );
    let surfaces = resolve_tab_refs(mux, surfaces)?;
    let outcome = mux.close_tabs_for(surfaces, end_terminals, reason, &workspace_mutation)?;
    let mut reply = json!({
        "closed": outcome.closed(),
        "terminals": batch_close_terminals_json(&outcome),
        "resource_revision": outcome.resource_revision,
        "replayed": outcome.replayed,
    });
    if let Some(transaction) = transaction {
        reply["transaction"] = json!(transaction);
    }
    Ok(reply)
}

#[cfg(test)]
#[path = "close_reason_tests.rs"]
mod tests;
