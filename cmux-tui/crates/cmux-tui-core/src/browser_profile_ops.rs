//! Browser profiles over `cmux.protocol/2` (plans/cmux-next/data-model.md
//! section 5), so an MCP client and the CLI use the one protocol:
//!
//! - `browser.tab.set_profile` (cx-d0d.85) moves a frontend browser tab to
//!   another browser profile in place. The tab's profile is its frontend
//!   browser record's (`update-frontend-browser-tab {profile_id}`, which
//!   resolves the profile by id or exact name in its own transaction); the
//!   app that shows the tab follows the record, makes the page in that
//!   profile's store and loads the same URL. Back/forward history stays with
//!   the old store.
//! - `browser.profile.list`, `browser.profile.create` and
//!   `browser.profile.open` (cx-2kl68) list the profile records (names and
//!   ids, never an import origin), create one, and open a frontend browser tab
//!   whose record names one. They do what the raw `list-personal`,
//!   `create-browser-profile` and `new-frontend-browser-tab {profile_id}`
//!   commands do, through the same registry calls.
//!
//! A profile's cookies, history and site data live in the app's engine
//! stores, keyed by the profile id; the daemon keeps only the records, and no
//! operation here reads a store. No agent verb deletes a profile: only a
//! person does, in the app.

use std::sync::Arc;

use serde_json::{Map, Value, json};
use sha2::{Digest, Sha256};

use crate::history_ops::ledger;
use crate::mux::FrontendTabPlacement;
use crate::resource::{ContentPublicId, ResourceError, ResourceOperation};
use crate::resource_router::ParsedResourceRequest;
use crate::workspace_registry::{BrowserProfileInput, FrontendBrowserRecord};
use crate::{Mux, PaneId, ResourceTarget};

/// Advertised in identify: the daemon answers `browser.tab.set_profile`
/// and shows `extra.browser_profile_id` on frontend browser tabs.
pub(crate) const CAPABILITY: &str = "browser-profile-agent-v1";

/// The setting that names the engine of a new browser tab
/// (`chromium` or `webkit`; the app's `cef` engine is Chromium).
const DEFAULT_ENGINE_SETTING: &str = "browser.defaultEngine";

const OPEN: &str = "browser.profile.open";

pub(crate) fn handles(operation: ResourceOperation) -> bool {
    matches!(
        operation,
        ResourceOperation::BrowserTabSetProfile
            | ResourceOperation::BrowserProfileList
            | ResourceOperation::BrowserProfileCreate
            | ResourceOperation::BrowserProfileOpen
    )
}

/// Answers one request. A mutation answers once per idempotency key (a
/// retry answers the first result); each one is idempotent by itself too,
/// so a retry after a crash between the change and its ledger entry finds
/// what the first attempt made instead of making a second.
pub(crate) fn dispatch(
    mux: &Arc<Mux>,
    request: ParsedResourceRequest,
) -> Result<Value, ResourceError> {
    debug_assert!(handles(request.envelope.operation));
    if request.envelope.operation == ResourceOperation::BrowserProfileList {
        return list(mux, &request);
    }
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
    let value = match request.envelope.operation {
        ResourceOperation::BrowserProfileCreate => create(mux, &request, key)?,
        ResourceOperation::BrowserProfileOpen => open(mux, &request, key)?,
        _ => set_profile(mux, &request)?,
    };
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

/// The fields of a profile record an agent sees. An allow list, so a field
/// the record gains later stays out until someone adds it here.
const PUBLIC_FIELDS: [&str; 6] = ["id", "name", "color", "icon", "index", "proxy"];

/// `browser.profile.list`: each record's id, name, color, icon, index and
/// proxy (#24432; it holds no secret, and an agent asserts its exit with it).
/// The import origin (a browser and its profile directory) stays out: it
/// names the person's other browsers and their files.
fn list(mux: &Arc<Mux>, request: &ParsedResourceRequest) -> Result<Value, ResourceError> {
    mux.resolve_resource_path(ResourceTarget::Session, &request.selectors)?;
    let snapshot = mux.personal_snapshot().map_err(|error| {
        ResourceError::operation_failed("browser.profile.list", error.to_string(), json!({}))
    })?;
    let rows =
        snapshot.browser_profiles.iter().map(public_profile).collect::<Result<Vec<_>, _>>()?;
    Ok(json!({"browser_profiles": rows}))
}

fn public_profile(profile: &impl serde::Serialize) -> Result<Value, ResourceError> {
    let failed =
        |reason: String| ResourceError::operation_failed("browser.profile", reason, json!({}));
    let Value::Object(mut fields) =
        serde_json::to_value(profile).map_err(|error| failed(error.to_string()))?
    else {
        return Err(failed("a browser profile record is not an object".into()));
    };
    fields.retain(|key, _| PUBLIC_FIELDS.contains(&key.as_str()));
    Ok(Value::Object(fields))
}

/// `browser.profile.create`. The new id is derived from the idempotency key,
/// so a retry that reaches the registry again finds the profile the first
/// attempt made (`changed` false) instead of making a second one.
fn create(
    mux: &Arc<Mux>,
    request: &ParsedResourceRequest,
    key: &str,
) -> Result<Value, ResourceError> {
    mux.resolve_resource_path(ResourceTarget::Session, &request.selectors)?;
    let fields = &request.fields;
    let index = match fields.get("index").and_then(Value::as_u64) {
        Some(index) => Some(
            usize::try_from(index)
                .map_err(|_| ResourceError::validation_invalid(Some("index"), "too large"))?,
        ),
        None => None,
    };
    let input = BrowserProfileInput {
        id: Some(profile_id_for_key(key)),
        name: string(fields, "name").unwrap_or_default(),
        color: string(fields, "color"),
        icon: string(fields, "icon"),
        index,
        source: None,
    };
    let (profile, changed) = mux
        .personal_mutation(|registry| registry.create_browser_profile(input))
        .map_err(|error| registry_error(error, "browser.profile.create", key))?;
    Ok(json!({"browser_profile": public_profile(&profile)?, "changed": changed}))
}

/// A lowercase version 4 UUID from the operation and the idempotency key.
fn profile_id_for_key(key: &str) -> String {
    let digest = Sha256::digest(format!("browser.profile.create\0{key}").as_bytes());
    let mut bytes = [0_u8; 16];
    for (byte, source) in bytes.iter_mut().zip(digest.iter()) {
        *byte = *source;
    }
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    let hex: String = bytes.iter().map(|byte| format!("{byte:02x}")).collect();
    format!("{}-{}-{}-{}-{}", &hex[..8], &hex[8..12], &hex[12..16], &hex[16..20], &hex[20..])
}

/// `browser.profile.open`: a frontend browser tab whose record names the
/// profile, made by the keyed creation `new-frontend-browser-tab` uses, so a
/// retry finds the tab the first attempt made.
fn open(
    mux: &Arc<Mux>,
    request: &ParsedResourceRequest,
    key: &str,
) -> Result<Value, ResourceError> {
    let fields = &request.fields;
    let url = string(fields, "url").unwrap_or_default();
    if !crate::resource_router::is_web_url(&url) {
        return Err(ResourceError::validation_invalid(
            Some("url"),
            "the URL must be an http or https URL with a host, at most 8192 bytes",
        ));
    }
    let pane = target_pane(mux, request)?;
    let profile = string(fields, "profile").unwrap_or_default();
    let profile_id = mux
        .workspace_registry
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
        .resolve_browser_profile_id(&profile)
        .map_err(|error| {
            let message = error.to_string();
            // An unknown or ambiguous name is the caller's; a store
            // failure is not.
            if message.starts_with("unknown browser profile")
                || message.starts_with("browser profile name is ambiguous")
            {
                ResourceError::validation_invalid(Some("profile"), message)
            } else {
                registry_error(error, OPEN, key)
            }
        })?;
    let record = FrontendBrowserRecord {
        engine: requested_or_default_engine(mux, string(fields, "engine").as_deref(), &url)?
            .to_string(),
        url,
        title: string(fields, "title"),
        favicon_url: None,
        profile_id: Some(profile_id.clone()),
        // The app that shows the tab claims the record; a caller never does.
        owner: None,
    };
    let activate = fields.get("activate").and_then(Value::as_bool).unwrap_or(true);
    let outcome = mux
        .new_frontend_browser_tab_keyed_as(
            &request.actor,
            pane,
            record,
            None,
            &tab_key(key),
            FrontendTabPlacement { activate, after: None, index: None },
        )
        .map_err(|error| registry_error(error, OPEN, key))?;
    let surface = &outcome.surface;
    let failed = |reason: &str| ResourceError::operation_failed(OPEN, reason, json!({}));
    let identity = surface.resource_identity().ok_or_else(|| failed("the new tab has no id"))?;
    let ContentPublicId::Browser(browser) = &identity.content_id else {
        return Err(failed("the new tab is not a browser"));
    };
    let pane_id = mux
        .with_state(|state| {
            let pane = state.pane_of(surface.id)?;
            state.resource_indexes.pane_ids.get(&pane).cloned()
        })
        .ok_or_else(|| failed("the new tab is in no pane"))?;
    Ok(json!({
        "tab_id": identity.tab_id.as_str(),
        "browser_id": browser.as_str(),
        "pane_id": pane_id.as_str(),
        "profile_id": profile_id,
    }))
}

/// The key of the tab `open` makes for `key`: a digest, so any key the
/// envelope accepts (up to 128 bytes) leaves room for the prefix.
fn tab_key(key: &str) -> String {
    let digest = Sha256::digest(key.as_bytes());
    let hex: String = digest.iter().map(|byte| format!("{byte:02x}")).collect();
    format!("{OPEN}:{hex}")
}

/// The person's `browser.defaultEngine` as a frontend engine: `webkit`,
/// else `cef` (the setting's default, `chromium`).
pub(crate) fn default_engine(mux: &Arc<Mux>) -> &'static str {
    let target = cmux_config::Target::Key(DEFAULT_ENGINE_SETTING.to_string());
    let value = mux.with_settings(|state| state.get(&target).row.and_then(|row| row.value));
    match value.as_ref().and_then(Value::as_str) {
        Some("webkit") => "webkit",
        _ => "cef",
    }
}

/// The engine of a tab for `url` that names none: the person's
/// `browser.siteEngines` rule for it (Spotify, Netflix and other
/// protected-media sites are WebKit by default), else `browser.defaultEngine`.
pub(crate) fn default_engine_for(mux: &Arc<Mux>, url: &str) -> &'static str {
    crate::browser_site_engines::site_engine_for(mux, url).unwrap_or_else(|| default_engine(mux))
}

/// The frontend engine tag a request names in its `engine` field
/// (`chromium`, `chrome` and `cef` are Chromium; `webkit` and `safari` are
/// WebKit), else the `browser.siteEngines` rule for `url`, else the person's
/// `browser.defaultEngine`. Every browser tab the daemon makes for the app
/// (`tab.create_browser` with no provider, `workspace.open_url`,
/// `browser.profile.open`) takes its engine here, so an agent's tab follows
/// the same settings as a tab the person opens.
pub(crate) fn requested_or_default_engine(
    mux: &Arc<Mux>,
    requested: Option<&str>,
    url: &str,
) -> Result<&'static str, ResourceError> {
    match requested.map(str::to_ascii_lowercase).as_deref() {
        None | Some("") => Ok(default_engine_for(mux, url)),
        Some("cef" | "chromium" | "chrome") => Ok("cef"),
        Some("webkit" | "safari") => Ok("webkit"),
        Some(other) => Err(ResourceError::validation_invalid(
            Some("engine"),
            format!("engine must be chromium or webkit, not {other:?}"),
        )),
    }
}

/// A registry or creation failure as the catalog error: the registry's
/// `bad request` checks are validation.invalid, a key that named another
/// request is idempotency.conflict, and the rest (the store, a pane that
/// closed meanwhile) are operation.failed.
fn registry_error(error: anyhow::Error, operation: &str, key: &str) -> ResourceError {
    if let Some(resource) = error.downcast_ref::<ResourceError>() {
        return resource.clone();
    }
    let message = error.to_string();
    if let Some(reason) = message.strip_prefix("bad request: ") {
        return ResourceError::validation_invalid(None, reason);
    }
    if message.starts_with("idempotency.conflict") {
        return ResourceError::idempotency_conflict(key, operation);
    }
    ResourceError::operation_failed(operation, message, json!({}))
}

/// The pane the selectors name, else none (the daemon's focused pane).
/// Workspace and screen only qualify a pane.
fn target_pane(
    mux: &Arc<Mux>,
    request: &ParsedResourceRequest,
) -> Result<Option<PaneId>, ResourceError> {
    let selectors = &request.selectors;
    if selectors.pane.is_none() {
        if selectors.workspace.is_some() || selectors.screen.is_some() {
            return Err(ResourceError::validation_invalid(
                Some("pane"),
                "workspace and screen only qualify a pane: name the pane, or none for the focused pane",
            ));
        }
        mux.resolve_resource_path(ResourceTarget::Session, selectors)?;
        return Ok(None);
    }
    let path = mux.resolve_resource_path(ResourceTarget::Pane, selectors)?;
    let public = path.pane.ok_or_else(|| ResourceError::not_found("pane", "pane"))?;
    mux.with_state(|state| state.pane_by_public_id(&public).map(|pane| pane.id))
        .map(Some)
        .ok_or_else(|| ResourceError::not_found("pane", public.as_str()))
}

fn string(fields: &Map<String, Value>, name: &str) -> Option<String> {
    fields.get(name).and_then(Value::as_str).map(str::to_string)
}
