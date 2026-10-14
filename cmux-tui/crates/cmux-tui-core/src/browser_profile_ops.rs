//! `browser.tab.set_profile` of `cmux.protocol/2` (cx-d0d.85,
//! plans/cmux-next/data-model.md section 5): move a frontend browser tab to
//! another browser profile in place, so an MCP client and the CLI use the one
//! protocol. The tab's profile is its frontend browser record's
//! (`update-frontend-browser-tab {profile_id}`, which resolves the profile by
//! id or exact name in its own transaction); the app that shows the tab
//! follows the record, makes the page in that profile's store and loads the
//! same URL. Back/forward history stays with the old store.
//!
//! The raw `cmux browser profile list|create|move|open` verbs list, create,
//! order and open profiles. No agent verb deletes one: only a person does.

use std::sync::Arc;

use serde_json::{Value, json};

use crate::history_ops::ledger;
use crate::resource::{ResourceError, ResourceOperation};
use crate::resource_router::ParsedResourceRequest;
use crate::{Mux, ResourceTarget};

/// Advertised in identify: the daemon answers `browser.tab.set_profile`
/// and shows `extra.browser_profile_id` on frontend browser tabs.
pub(crate) const CAPABILITY: &str = "browser-profile-agent-v1";

pub(crate) fn handles(operation: ResourceOperation) -> bool {
    operation == ResourceOperation::BrowserTabSetProfile
}

/// Answers one request, once per idempotency key (a retry answers the first
/// result; the move itself is idempotent too).
pub(crate) fn dispatch(
    mux: &Arc<Mux>,
    request: ParsedResourceRequest,
) -> Result<Value, ResourceError> {
    debug_assert!(handles(request.envelope.operation));
    let operation = request.envelope.operation.wire_name();
    let key = request.envelope.idempotency_key.as_deref().ok_or_else(|| {
        ResourceError::validation_invalid(Some("idempotency_key"), "mutations need a key")
    })?;
    let mut fingerprint_fields = request.fields.clone();
    fingerprint_fields.insert("selectors".into(), json!(request.selectors));
    let fingerprint = ledger::fingerprint(operation, &fingerprint_fields);
    if ledger::seen(mux, key, operation)? {
        return ledger::commit(mux, key, operation, &fingerprint, &Value::Null, &request.actor);
    }
    let value = set_profile(mux, &request)?;
    ledger::commit(mux, key, operation, &fingerprint, &value, &request.actor)
}

/// The tab keeps its id and place; its record names the profile.
fn set_profile(mux: &Arc<Mux>, request: &ParsedResourceRequest) -> Result<Value, ResourceError> {
    let profile = request.fields.get("profile").and_then(Value::as_str).unwrap_or_default();
    let path = mux.resolve_resource_path(ResourceTarget::Tab, &request.selectors)?;
    let tab = path.tab.ok_or_else(|| ResourceError::not_found("tab", "tab"))?;
    let surface = mux
        .with_state(|state| state.surface_by_tab_public_id(&tab).map(|surface| surface.id))
        .ok_or_else(|| ResourceError::not_found("tab", tab.as_str()))?;
    let (record, changed) = mux
        .update_frontend_browser_tab_with_owner_and_profile_as(
            &request.actor,
            surface,
            None,
            None,
            None,
            Some(Some(profile.to_string())),
            None,
        )
        .map_err(|error| {
            // An unknown or ambiguous profile, or a tab that is not a
            // frontend browser: the caller's input, not a daemon failure.
            ResourceError::validation_invalid(Some("profile"), error.to_string())
        })?;
    Ok(json!({"tab_id": tab.as_str(), "profile_id": record.profile_id, "changed": changed}))
}
