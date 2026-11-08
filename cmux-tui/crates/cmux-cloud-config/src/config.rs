//! Which Cloud a build talks to: the app's `CloudConfiguration`, made from the runtime selection
//! the bundled CLI resolves (`cmux cloud env get`, cmux-cloud-environment).
//!
//! The selection is authoritative for every origin and the Stack project; the build adds only its
//! sign-in callback scheme (from the bundle id, the build kind and the bundle's `LSEnvironment`)
//! and the names of its token store, which [`from_selection`] derives here.

use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};

use crate::origin;

/// The signed NEXT DEV channel: a signed Release compile, not a Debug build.
pub const NEXT_DEV_BUNDLE_ID: &str = "com.cmuxterm.app.debug.next";
/// cmux NIGHTLY, whose session a signed NEXT DEV build on the NIGHTLY account adopts.
pub const NIGHTLY_BUNDLE_ID: &str = "com.cmuxterm.app.nightly";
/// The placeholder configuration's bundle id (`CloudConfiguration.unavailable`): a test or capture
/// composition root that builds services before the runtime bootstrap. Its token store is its own,
/// so it never restores a real bundle's credentials.
pub const UNAVAILABLE_BUNDLE_ID: &str = "com.cmuxterm.app.cloud-unavailable";
/// The cmux VM API (workers/cmux-vm): production's and staging's.
pub const PRODUCTION_VM_API: &str = "https://vm.cmux.dev";
pub const STAGING_VM_API: &str = "https://vm-staging.cmux.dev";

/// Where the build's Cloud is.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", content = "url", rename_all = "camelCase")]
pub enum Backend {
    /// A production selection.
    Production,
    /// A non-production selection, at its API origin.
    Development(String),
    /// A loopback origin: `scripts/reload.sh` local backend mode.
    LocalOnly(String),
}

/// The runtime selection's facts the configuration reads (the app's `CloudRuntimeSelection`, sent
/// camelCase; fields it does not read are ignored).
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Selection {
    pub name: String,
    pub api_origin: String,
    pub auth_web_origin: String,
    pub stack_origin: String,
    pub stack_project_id: String,
    pub stack_client_key: String,
    pub bundle_id: String,
    pub auth_namespace: String,
    #[serde(default)]
    pub auth_storage_namespace: Option<String>,
    pub legacy_storage: bool,
}

/// What [`from_selection`] reads.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Inputs {
    pub selection: Selection,
    /// The running bundle's id; the selection's when absent.
    #[serde(default)]
    pub bundle_id: Option<String>,
    /// The bundle's `LSEnvironment`; it wins over `process`.
    #[serde(default)]
    pub bundled: BTreeMap<String, String>,
    #[serde(default)]
    pub process: BTreeMap<String, String>,
    pub is_debug_build: bool,
}

/// One build's token store names.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct StorageNames {
    /// The Stack token Keychain service (`<bundle id>.auth`, scoped by the storage project).
    pub keychain_service: String,
    /// The file-fallback token store under the home folder:
    /// `Library/Application Support/cmux/<bundle id>[/<project>]`. This build's own namespace,
    /// which predates the per-build state roots; moving it would sign every build out.
    pub credentials_subpath: Vec<String>,
    /// The suffix of every `cmux.auth.*` defaults key (`<key>.<project>`), when scoped.
    pub defaults_key_suffix: Option<String>,
}

/// The store a build used for this legacy default before the namespaced store (#36384 read
/// `<bundle id>.auth.<namespace>`): a session signed in there is adopted once.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct LegacyStore {
    pub keychain_service: String,
    pub credentials_subpath: Vec<String>,
}

/// One build's Cloud.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Configuration {
    pub backend: Backend,
    pub api_base_url: String,
    /// Origin of the web sign-in pages (`handler/native-sign-in`).
    pub auth_web_origin: String,
    pub stack_base_url: String,
    pub stack_project_id: String,
    pub stack_publishable_client_key: String,
    pub is_production_auth: bool,
    pub callback_scheme: String,
    pub bundle_id: String,
    pub is_debug_build: bool,
    pub storage: StorageNames,
    pub namespaced_legacy_store: Option<LegacyStore>,
    /// A signed NEXT DEV production launch adopts the running NIGHTLY's session in memory.
    pub adopts_nightly_session: bool,
}

/// The configuration of a build running `inputs.selection` (the app's `CloudConfiguration.from`).
pub fn from_selection(inputs: &Inputs) -> Configuration {
    let selection = &inputs.selection;
    let value = |key: &str| -> Option<String> {
        let raw = inputs.bundled.get(key).or_else(|| inputs.process.get(key))?;
        let trimmed = raw.trim();
        (!trimmed.is_empty()).then(|| trimmed.to_owned())
    };
    let bundle_id = inputs.bundle_id.clone().unwrap_or_else(|| selection.bundle_id.clone());
    let callback_scheme = callback_scheme(
        value("CMUX_AUTH_CALLBACK_SCHEME").as_deref(),
        &bundle_id,
        value("CMUX_TAG").as_deref(),
        inputs.is_debug_build,
    );
    let production = selection.name == "prod";
    // A selected local backend (`name: local`, a loopback origin) is development, never `LocalOnly`:
    // the person chose it, so it is reachable (the app's CloudRuntimeSelectionTests before this move:
    // "a selected local backend is available"). `LocalOnly` is only the placeholder configuration's.
    Configuration {
        backend: if production {
            Backend::Production
        } else {
            Backend::Development(selection.api_origin.clone())
        },
        api_base_url: selection.api_origin.clone(),
        auth_web_origin: selection.auth_web_origin.clone(),
        stack_base_url: selection.stack_origin.clone(),
        stack_project_id: selection.stack_project_id.clone(),
        stack_publishable_client_key: selection.stack_client_key.clone(),
        is_production_auth: production,
        callback_scheme,
        storage: storage_names(Some(&bundle_id), Some(selection)),
        namespaced_legacy_store: namespaced_legacy_store(&bundle_id, selection),
        adopts_nightly_session: !inputs.is_debug_build
            && bundle_id == NEXT_DEV_BUNDLE_ID
            && production,
        bundle_id,
        is_debug_build: inputs.is_debug_build,
    }
}

/// The namespace that keeps a build's tokens apart: the selection's storage namespace for a legacy
/// default (signed NEXT DEV's staging project, so its first staging launch reads no production
/// token and primes no cached user), else the selection's own namespace. Without a selection only
/// the placeholder is scoped.
fn storage_project(bundle_id: Option<&str>, selection: Option<&Selection>) -> Option<String> {
    match selection {
        None => {
            (bundle_id == Some(UNAVAILABLE_BUNDLE_ID)).then(|| "bootstrap-unavailable".to_owned())
        }
        Some(selection) if selection.legacy_storage => selection.auth_storage_namespace.clone(),
        Some(selection) => Some(selection.auth_namespace.clone()),
    }
}

fn credentials_subpath(bundle_id: Option<&str>) -> Vec<String> {
    vec![
        "Library".to_owned(),
        "Application Support".to_owned(),
        "cmux".to_owned(),
        bundle_id.unwrap_or("cmux").to_owned(),
    ]
}

/// The token store names of `bundle_id` running `selection` (none: the placeholder configuration).
pub fn storage_names(bundle_id: Option<&str>, selection: Option<&Selection>) -> StorageNames {
    let bundle_id = bundle_id.filter(|id| !id.is_empty());
    let project = storage_project(bundle_id, selection);
    let service =
        bundle_id.map_or_else(|| "com.cmuxterm.app.auth".to_owned(), |id| format!("{id}.auth"));
    let mut subpath = credentials_subpath(bundle_id);
    subpath.extend(project.clone());
    StorageNames {
        keychain_service: match &project {
            Some(project) if bundle_id.is_some() => format!("{service}.{project}"),
            _ => service,
        },
        credentials_subpath: subpath,
        defaults_key_suffix: project,
    }
}

/// The namespaced store an untouched legacy default used before #36384; none for every other
/// selection, whose own store is already namespaced or project-scoped.
fn namespaced_legacy_store(bundle_id: &str, selection: &Selection) -> Option<LegacyStore> {
    if !selection.legacy_storage
        || selection.auth_storage_namespace.is_some()
        || bundle_id.is_empty()
    {
        return None;
    }
    let mut subpath = credentials_subpath(Some(bundle_id));
    subpath.push(selection.auth_namespace.clone());
    Some(LegacyStore {
        keychain_service: format!("{bundle_id}.auth.{}", selection.auth_namespace),
        credentials_subpath: subpath,
    })
}

/// The hosted sign-in entry: `handler/native-sign-in` wraps Stack sign-in and returns to
/// `<scheme>://auth-callback` (with `cmux_auth_state` when a state is given) through
/// `handler/after-sign-in`. Each nested URL is one percent-encoded query value.
pub fn sign_in_url(auth_web_origin: &str, callback_scheme: &str, state: Option<&str>) -> String {
    let origin = auth_web_origin.trim_end_matches('/');
    let mut callback = format!("{callback_scheme}://auth-callback");
    if let Some(state) = state {
        callback = format!("{callback}?cmux_auth_state={}", encode_component(state));
    }
    let after = format!(
        "{origin}/handler/after-sign-in?native_app_return_to={}",
        encode_component(&callback)
    );
    format!("{origin}/handler/native-sign-in?after_auth_return_to={}", encode_component(&after))
}

/// Percent-encodes everything but RFC 3986's unreserved characters.
pub fn encode_component(raw: &str) -> String {
    let mut out = String::with_capacity(raw.len());
    for byte in raw.bytes() {
        if byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'_' | b'.' | b'~') {
            out.push(char::from(byte));
        } else {
            out.push_str(&format!("%{byte:02X}"));
        }
    }
    out
}

/// The cmux VM API for this build's Cloud: production's for production, staging's for a
/// development stack. There is no override: the app sends its Stack session only there.
pub fn vm_api_base_url(backend: &Backend) -> &'static str {
    match backend {
        Backend::Production => PRODUCTION_VM_API,
        Backend::Development(_) | Backend::LocalOnly(_) => STAGING_VM_API,
    }
}

/// The release channel's sign-in callback scheme.
/// The URL scheme a build registers and signs in through (its Info.plist `CMUX_AUTH_CALLBACK_SCHEME`): the
/// bundle's override when it can form `<scheme>://auth-callback` (a bad one trapped at sign-in), else NEXT
/// DEV's `cmux-next-dev`, a Debug build's `cmux-dev` (`cmux-dev-<tag>` when tagged), or the channel's own.
pub fn callback_scheme(
    configured: Option<&str>,
    bundle_id: &str,
    tag: Option<&str>,
    is_debug_build: bool,
) -> String {
    if let Some(scheme) = configured
        .map(str::trim)
        .filter(|scheme| origin::parse(&format!("{scheme}://auth-callback")).is_some())
    {
        return scheme.to_owned();
    }
    if bundle_id == NEXT_DEV_BUNDLE_ID {
        "cmux-next-dev".to_owned()
    } else if is_debug_build {
        let tag = tag.and_then(sanitized_scheme_tag);
        tag.map_or_else(|| "cmux-dev".to_owned(), |tag| format!("cmux-dev-{tag}"))
    } else {
        default_scheme(Some(bundle_id)).to_owned()
    }
}

pub fn default_scheme(bundle_id: Option<&str>) -> &'static str {
    match bundle_id {
        Some(NIGHTLY_BUNDLE_ID) => "cmux-nightly",
        Some("com.cmuxterm.app.rc") => "cmux-rc",
        _ => "cmux",
    }
}

/// `[a-z0-9]` runs joined by single hyphens, as the old app registered.
pub fn sanitized_scheme_tag(raw: &str) -> Option<String> {
    let mut result = String::new();
    let mut last_hyphen = false;
    for c in raw.to_lowercase().chars() {
        if c.is_ascii_lowercase() || c.is_ascii_digit() {
            result.push(c);
            last_hyphen = false;
        } else if !last_hyphen {
            result.push('-');
            last_hyphen = true;
        }
    }
    let trimmed = result.trim_matches('-');
    (!trimmed.is_empty()).then(|| trimmed.to_owned())
}

#[cfg(test)]
#[path = "config_tests.rs"]
mod tests;
