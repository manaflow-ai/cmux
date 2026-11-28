//! A daemon-rendered browser needs a cmux-browser provider (cx-r9ix): only a
//! provider publishes the CDP target such a tab attaches to, and the daemon
//! launches no browser (cx-2u5k). With none attached (a headless Cloud
//! session) a new tab would stay `starting` for good, so `tab.create_browser`
//! and a browser mutation on a starting tab fail at once with
//! `operation.failed`, `extra.code` `engine_unavailable`, before any receipt.
//! Frontend-rendered browsers and sessions with a provider are unchanged, and
//! a retry of a request that already has a receipt replays it.

use std::sync::Arc;

use super::{ParsedResourceRequest, content, operation_name};
use crate::browser::BrowserStatus;
use crate::resource::{OperationClass, ResourceError, ResourceOperation};
use crate::{Mux, ResourceTarget};

pub(super) fn refuse_without_provider(
    mux: &Arc<Mux>,
    request: &ParsedResourceRequest,
) -> Result<(), ResourceError> {
    let operation = request.envelope.operation;
    let name = operation_name(operation);
    let daemon_rendered = match operation {
        ResourceOperation::TabCreateBrowser => !request.fields.contains_key("frontend_browser_id"),
        ResourceOperation::BrowserClose => false,
        _ if name.starts_with("browser.") && operation.class() == OperationClass::Mutation => {
            starting_daemon_browser(mux, request)
        }
        _ => false,
    };
    match daemon_rendered.then(|| mux.browser_engine_unavailable(&name)).flatten() {
        Some(error) if !received_before(mux, request) => Err(error),
        _ => Ok(()),
    }
}

/// A retry of a request that was already received replays its receipt
/// instead: refusing it would orphan the tab its original created.
fn received_before(mux: &Arc<Mux>, request: &ParsedResourceRequest) -> bool {
    let Some(key) = request.envelope.idempotency_key.as_deref() else { return false };
    let correlation = request.fields.get("correlation_key").and_then(serde_json::Value::as_str);
    let registry = mux.workspace_registry.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
    // A failed lookup refuses: the request is new as far as the gate can tell.
    registry.has_resource_receipt(key, correlation).unwrap_or(false)
}

/// The request's browser is daemon-rendered and has no live session yet. A
/// selector that does not resolve is left to the operation's own error.
fn starting_daemon_browser(mux: &Arc<Mux>, request: &ParsedResourceRequest) -> bool {
    let Ok(path) = mux.resolve_resource_path(ResourceTarget::Browser, &request.selectors) else {
        return false;
    };
    let Some((_, surface)) = path.browser.and_then(|id| content::browser_surface_for_id(mux, &id))
    else {
        return false;
    };
    surface.browser_source().is_none()
        && surface.browser_status().is_none_or(|status| status == BrowserStatus::Starting)
        && !mux.is_frontend_browser_surface(&surface)
}
