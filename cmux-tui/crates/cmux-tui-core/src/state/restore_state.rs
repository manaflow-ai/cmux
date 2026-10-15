//! `tab.restore_state.put` and the close ops' `restore_state` map
//! (plans/cmux-next/reopen-closed.md 3.0). The owner of state the daemon
//! cannot own pushes it ahead of a close, or the closer sends the freshest
//! copy inline; the capture keeps the inline payload, else the pushed row,
//! else only what the daemon owns. Payloads are opaque JSON of at most
//! [`MAX_PAYLOAD_BYTES`], stored with their web URLs stripped of secret
//! query keys; an incognito tab stores nothing. Rows live in
//! [`super::restore_state_store`].

use serde_json::{Map, Value, json};

use super::restore_state_store::{self as store, MAX_PAYLOAD_BYTES, RestoreState};
use crate::Mux;
use crate::resource::ResourceOperation;
use crate::resource_router::ParsedResourceRequest;
use crate::state::commit::{StateEffects, state_not_found};
use crate::state::prelude::*;
use crate::state::store::{StateChanges, StateCommit};

const OPERATION: &str = "tab.restore_state.put";

/// The close ops that take an inline `restore_state` map.
fn takes_inline(operation: ResourceOperation) -> bool {
    use ResourceOperation as Op;
    matches!(
        operation,
        Op::TabClose
            | Op::PaneClose
            | Op::ScreenClose
            | Op::WorkspaceClose
            | Op::TabGroupClose
            | Op::LayoutBulk
            | Op::BrowserClose
            | Op::TerminalClose
    )
}

impl RestoreState {
    /// A put's fields or one inline entry, checked: the payload is at most
    /// [`MAX_PAYLOAD_BYTES`] of compact JSON. Web URLs in it are stripped.
    pub(crate) fn from_fields(fields: &Map<String, Value>) -> Result<Self, ResourceError> {
        let provider = fields.get("provider").and_then(Value::as_str).unwrap_or_default();
        if provider.trim().is_empty() || provider.len() > 128 {
            return Err(ResourceError::validation_invalid(
                Some("provider"),
                "provider must be 1 to 128 bytes",
            ));
        }
        let version = fields.get("version").and_then(Value::as_u64).ok_or_else(|| {
            ResourceError::validation_invalid(
                Some("version"),
                "version must be an unsigned integer",
            )
        })?;
        let mut payload = fields.get("payload").cloned().unwrap_or(Value::Null);
        let bytes = serde_json::to_string(&payload).map_or(usize::MAX, |text| text.len());
        if bytes > MAX_PAYLOAD_BYTES {
            return Err(ResourceError::validation_invalid(
                Some("payload"),
                format!("payload is {bytes} bytes; at most {MAX_PAYLOAD_BYTES}"),
            ));
        }
        super::closed_history_privacy::strip_payload(&mut payload);
        Ok(Self { provider: provider.to_string(), version, payload })
    }
}

/// Take a close request's inline `restore_state` map out of its fields and
/// store each entry as its tab's row, before the close captures it. A tab
/// that is gone (a retried close) or incognito is skipped.
pub(crate) fn take_inline(
    mux: &Mux,
    request: &mut ParsedResourceRequest,
) -> Result<(), ResourceError> {
    if !takes_inline(request.envelope.operation) {
        return Ok(());
    }
    let Some(map) = request.fields.remove("restore_state") else { return Ok(()) };
    let entries = map
        .as_object()
        .into_iter()
        .flatten()
        .map(|(tab, entry)| {
            let fields = entry.as_object().cloned().unwrap_or_default();
            RestoreState::from_fields(&fields).map(|state| (tab.clone(), state))
        })
        .collect::<Result<Vec<_>, _>>()?;
    if entries.is_empty() {
        return Ok(());
    }
    let now = crate::workspace_registry::unix_epoch_ms()
        .map_err(crate::resource_router::resource_operation_error)?;
    // A side write under the registry lock: the rows are not journaled.
    mux.read_registry_state(|connection| {
        let transaction = connection.unchecked_transaction()?;
        for (tab, state) in &entries {
            if store::storable(&transaction, tab)? == Some(true) {
                store::upsert(&transaction, tab, state, now)?;
            }
        }
        transaction.commit()?;
        Ok(())
    })
    .map_err(crate::resource_router::resource_operation_error)
}

/// `tab.restore_state.put`.
pub(crate) fn put(mux: &Mux, request: &ParsedResourceRequest) -> Result<Value, ResourceError> {
    let restore = RestoreState::from_fields(&request.fields)?;
    let mutation = request.mutation().map_err(crate::resource_router::resource_operation_error)?;
    let expected = crate::resource_router::expected_revision(&request.fields)?;
    let commit = mux
        .state_restore_state_put(&mutation, expected, &request.selectors, restore)
        .map_err(crate::resource_router::resource_operation_error)?;
    crate::resource_router::mutation_result(mux, commit.result, commit.revision, commit.replayed)
}

impl Mux {
    /// Upsert the restore state of the tab `selectors` name. Answers
    /// `{stored}`: false for an incognito tab, which stores nothing.
    pub(crate) fn state_restore_state_put(
        &self,
        mutation: &WorkspaceMutation,
        expected_revision: Option<u64>,
        selectors: &crate::ResourceSelectors,
        restore: RestoreState,
    ) -> anyhow::Result<StateCommit> {
        let fingerprint = json!({
            "operation": OPERATION,
            "selectors": selectors,
            "provider": restore.provider,
            "version": restore.version,
            "payload": restore.payload,
        });
        let now = crate::workspace_registry::unix_epoch_ms()?;
        self.commit_state(
            mutation,
            OPERATION,
            &fingerprint,
            expected_revision,
            StateEffects::EVENTS_ONLY,
            |transaction, state| {
                let resolved =
                    self.resolve_in_state(state, crate::ResourceTarget::Tab, selectors)?;
                let surface = resolved.tab.context("tab selector resolved no tab")?;
                let tab = crate::mux::tab_groups::tab_public_id(state, surface)?;
                let stored = match store::storable(transaction, &tab)? {
                    None => return Err(state_not_found("tab", &tab)),
                    Some(stored) => stored,
                };
                if stored {
                    store::upsert(transaction, &tab, &restore, now)?;
                }
                Ok(StateChanges::new(json!({"stored": stored}), Vec::new()))
            },
        )
    }
}
