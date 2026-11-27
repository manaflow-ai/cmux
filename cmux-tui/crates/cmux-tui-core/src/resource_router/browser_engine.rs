//! A daemon-rendered browser needs a cmux-browser provider (cx-r9ix): only a
//! provider publishes the CDP target such a tab attaches to, and the daemon
//! launches no browser (cx-2u5k). With none attached (a headless Cloud
//! session) a new tab would stay `starting` for good, so `tab.create_browser`
//! and a browser mutation on a starting tab fail at once with
//! `operation.failed`, `extra.code` `engine_unavailable`, before any receipt.
//! Frontend-rendered browsers and sessions with a provider are unchanged, and
//! a retry of a request that already has a receipt replays it.
//!
//! A frontend that renders browser tabs (the cmux app, which declares
//! `frontend-browser-tabs-v1` on its connection) is a browser engine too. So
//! a plain `tab.create_browser` with no provider attached becomes a frontend
//! browser tab whenever such a frontend is connected ([`route_to_frontend`]):
//! agents whose CLI talks to a session the app shows (a Chief session, not
//! the app's own daemon) used to get `engine_unavailable` here although the
//! app could render the tab.

use std::sync::Arc;

use serde_json::{Value, json};

use super::{ParsedResourceRequest, content, operation_name, resource_operation_error};
use crate::browser::BrowserStatus;
use crate::resource::{OperationClass, ResourceError, ResourceOperation};
use crate::server::FRONTEND_BROWSER_TABS_CAPABILITY;
use crate::state::frontend_browser_keys::KeyedFrontendBrowser;
use crate::workspace_registry::FrontendBrowserRecord;
use crate::{Mux, ResourceTarget};

/// Turns a plain `tab.create_browser` into a frontend browser tab when no
/// cmux-browser provider is attached and a connected frontend renders
/// browser tabs: the record is registered under the request's key first
/// (the keyed `new-frontend-browser-tab` path), and the request then carries
/// its `frontend_browser_id`. A retry under the same key reuses that id, so
/// the topology receipt replays. A request that was received before on the
/// daemon path keeps that path, so its receipt replays too.
pub(super) fn route_to_frontend(
    mux: &Arc<Mux>,
    request: &mut ParsedResourceRequest,
) -> Result<(), ResourceError> {
    if request.envelope.operation != ResourceOperation::TabCreateBrowser
        || request.fields.contains_key("frontend_browser_id")
    {
        return Ok(());
    }
    let Some(key) = request.envelope.idempotency_key.clone() else { return Ok(()) };
    let keyed = mux.has_frontend_browser_key(&key).map_err(resource_operation_error)?;
    if !keyed
        && (mux.browser_provider_snapshot().is_some()
            || !mux.control_clients.any_client_supports(FRONTEND_BROWSER_TABS_CAPABILITY)
            || received_before(mux, request))
    {
        return Ok(());
    }
    let url = request.fields.get("url").and_then(Value::as_str).unwrap_or_default().to_string();
    // The request's `engine`, else the person's `browser.siteEngines` rule
    // for the URL, else `browser.defaultEngine` (Chromium unless set to
    // WebKit): an agent's tab opens in the same engine as one the person opens.
    let engine = crate::browser_profile_ops::requested_or_default_engine(
        mux,
        request.fields.get("engine").and_then(Value::as_str),
        &url,
    )?;
    let record = FrontendBrowserRecord {
        engine: engine.to_string(),
        url,
        title: None,
        favicon_url: None,
        profile_id: None,
        owner: None,
    };
    let fingerprint = json!({
        "operation": "tab.create_browser",
        "params": request.envelope.params,
    });
    let browser = match mux
        .keyed_frontend_browser(&key, record, fingerprint, |id| Ok(id.clone()))
        .map_err(|error| {
        if error.to_string().starts_with("idempotency.conflict") {
            ResourceError::idempotency_conflict(&key, "tab.create_browser")
        } else {
            resource_operation_error(error)
        }
    })? {
        KeyedFrontendBrowser::Created(id) => id,
        KeyedFrontendBrowser::Placed(surface) => {
            mux.frontend_browser_id(&surface).ok_or_else(|| {
                ResourceError::operation_failed(
                    "tab.create_browser",
                    "the browser tab this key made is no longer rendered by the cmux app",
                    json!({}),
                )
            })?
        }
    };
    request.fields.insert("frontend_browser_id".to_string(), json!(browser.as_str()));
    Ok(())
}
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
    let correlation = request.fields.get("correlation_key").and_then(Value::as_str);
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
