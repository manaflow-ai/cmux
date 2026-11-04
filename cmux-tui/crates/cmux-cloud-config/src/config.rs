//! Which Cloud a build talks to: the app's `CloudConfiguration` rules.
//!
//! The app reads its bundle id, the bundle's `LSEnvironment` (`bundled`, what
//! `scripts/reload.sh` bakes into tagged builds) and the process environment,
//! and asks [`resolve`]. Release builds use production except the signed NEXT
//! DEV channel (bundle [`NEXT_DEV_BUNDLE_ID`]), which uses the development
//! Worker and staging sign-in. A Debug build built without `--direct-backend`
//! points at a loopback origin with no server; [`Backend::LocalOnly`] says so,
//! so Cloud actions can explain how to fix the build instead of timing out.

use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};

use crate::origin;

/// The signed NEXT DEV channel: a signed Release compile, not a Debug build.
pub const NEXT_DEV_BUNDLE_ID: &str = "com.cmuxterm.app.debug.next";

pub const PRODUCTION_ORIGIN: &str = "https://cmux.com";
/// The staging web app: the hosted sign-in pages (`handler/native-sign-in`), the team API
/// (`/api/teams`) and the classic machine routes a development build still calls.
pub const STAGING_WEB_ORIGIN: &str = "https://cmux-staging.vercel.app";
/// The development owner API Worker (`/v1/read`, `/v1/ops`, `/v1/auth/*`, `/v1/cloud/*`), which
/// accepts staging Stack tokens.
pub const DEVELOPMENT_WORKER_ORIGIN: &str = "https://cmux-api-development.debussy.workers.dev";
pub const PRODUCTION_OWNER_API: &str = "https://cloud-api.cmux.dev";
pub const STAGING_OWNER_API: &str = "https://cloud-api-staging.cmux.dev";
pub const STACK_ORIGIN: &str = "https://api.stack-auth.com";
pub const LOCAL_DEVELOPMENT_ORIGIN: &str = "http://localhost:3777";
pub const DEVELOPMENT_PROJECT_ID: &str = "454ecd03-1db2-4050-845e-4ce5b0cd9895";
pub const DEVELOPMENT_CLIENT_KEY: &str = "pck_xb63160bwe9699vtxfzfj6emmxpafg5mkjrtp6ehzxv5g";
pub const PRODUCTION_PROJECT_ID: &str = "9790718f-14cd-4f7e-824d-eaf527a82b82";
/// Empty on purpose: the production project does not require a publishable key, and a shipped
/// key would break sign-in once its key set is revoked.
pub const PRODUCTION_CLIENT_KEY: &str = "";
/// The cmux VM API (workers/cmux-vm): production's and staging's.
pub const PRODUCTION_VM_API: &str = "https://vm.cmux.dev";
pub const STAGING_VM_API: &str = "https://vm-staging.cmux.dev";
pub const PRODUCTION_PLATFORM: &str = "https://cmux-platform.debussy.workers.dev";
pub const STAGING_PLATFORM: &str = "https://cmux-platform-staging.debussy.workers.dev";
pub const DEVELOPMENT_PLATFORM: &str = "https://cmux-platform-development.debussy.workers.dev";
/// The cmux APIs a share room takes tokens from (cmux-tui `platform::share_owner_api`).
pub const SHARE_API_HOSTS: [&str; 3] = [
    "cloud-api.cmux.dev",
    "cloud-api-staging.cmux.dev",
    "cmux-api-development.debussy.workers.dev",
];
const CAPTURE_BUNDLE_PREFIX: &str = "com.cmuxterm.app.debug.cap";

/// Where the build's Cloud is.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", content = "url", rename_all = "camelCase")]
pub enum Backend {
    /// Production (`https://cmux.com`).
    Production,
    /// The tag's shared development stack (`--direct-backend`), or the signed DEV channel's.
    Development(String),
    /// A loopback origin: `scripts/reload.sh` local backend mode.
    LocalOnly(String),
}

/// Where a Cloud machine's link socket comes from.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum LinkSource {
    /// The classic `/api/vm` attach endpoint and a `cmux-tui remote connect` process.
    Legacy,
    /// The Cloud app server: the machine list, create and the `cloud.machine.connect` carrier
    /// socket, all on the owner API Worker.
    AppServer,
}

/// What [`resolve`] reads.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Inputs {
    pub bundle_id: Option<String>,
    /// The bundle's `LSEnvironment`; it wins over `process`, so a launch from a shell cannot
    /// redirect a tagged build to another backend.
    #[serde(default)]
    pub bundled: BTreeMap<String, String>,
    #[serde(default)]
    pub process: BTreeMap<String, String>,
    pub is_debug_build: bool,
}

/// One build's Cloud.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Configuration {
    pub backend: Backend,
    /// The web API origin: the team API, account, billing, CodeRouter, Stack's `apiBaseURL`, and
    /// Sandboxed runs (`/api/runs`) until they move to cmux-platform's hand-offs.
    pub api_base_url: String,
    /// The Cloud API base the app's machine client (`CloudAPIClient`) talks to. Production keeps
    /// `cmux.com`; DEV, NEXT DEV and every other development build use the development owner API
    /// Worker (NEXT Cloud, which forwards to cmux-platform), never the classic staging web app
    /// (Leo, 2026-11-04: "were doing new cloud with cmux-platform and stuff"). A debug build that
    /// names an origin (`CMUX_VM_API_BASE_URL`, `CMUX_API_BASE_URL`, `CMUX_DEV_BACKEND_URL`, local
    /// mode) keeps it.
    pub cloud_api_base_url: String,
    /// Origin of the web sign-in pages (`handler/native-sign-in`).
    pub auth_web_origin: String,
    pub stack_base_url: String,
    pub stack_project_id: String,
    pub stack_publishable_client_key: String,
    pub is_production_auth: bool,
    pub callback_scheme: String,
    pub bundle_id: Option<String>,
    pub is_debug_build: bool,
    pub link_source: LinkSource,
}

/// The facts the derived names read; a test may change them after [`resolve`].
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Identity {
    pub bundle_id: Option<String>,
    pub is_debug_build: bool,
    pub is_production_auth: bool,
    #[serde(default)]
    pub stack_project_id: String,
    #[serde(default)]
    pub link_source: Option<LinkSource>,
}

impl Configuration {
    pub fn identity(&self) -> Identity {
        Identity {
            bundle_id: self.bundle_id.clone(),
            is_debug_build: self.is_debug_build,
            is_production_auth: self.is_production_auth,
            stack_project_id: self.stack_project_id.clone(),
            link_source: Some(self.link_source),
        }
    }
}

fn is_next_dev(bundle_id: Option<&str>, is_debug_build: bool) -> bool {
    !is_debug_build && bundle_id == Some(NEXT_DEV_BUNDLE_ID)
}

/// The pure resolution (the app's `CloudConfiguration.resolve`).
pub fn resolve(inputs: &Inputs) -> Configuration {
    let bundle_id = inputs.bundle_id.clone();
    let is_debug_build = inputs.is_debug_build;
    // NEXT DEV is a signed Release compile. Its Worker accepts staging Stack tokens. Its
    // endpoints are fixed so inherited environment variables cannot redirect its credentials.
    if is_next_dev(bundle_id.as_deref(), is_debug_build) {
        return Configuration {
            backend: Backend::Development(DEVELOPMENT_WORKER_ORIGIN.to_owned()),
            api_base_url: STAGING_WEB_ORIGIN.to_owned(),
            cloud_api_base_url: DEVELOPMENT_WORKER_ORIGIN.to_owned(),
            auth_web_origin: STAGING_WEB_ORIGIN.to_owned(),
            stack_base_url: STACK_ORIGIN.to_owned(),
            stack_project_id: DEVELOPMENT_PROJECT_ID.to_owned(),
            stack_publishable_client_key: DEVELOPMENT_CLIENT_KEY.to_owned(),
            is_production_auth: false,
            callback_scheme: "cmux-next-dev".to_owned(),
            bundle_id,
            is_debug_build: false,
            link_source: LinkSource::AppServer,
        };
    }
    let value = |key: &str| -> Option<String> {
        let raw = inputs.bundled.get(key).or_else(|| inputs.process.get(key))?;
        let trimmed = raw.trim();
        (!trimmed.is_empty()).then(|| trimmed.to_owned())
    };
    let production = !is_debug_build
        || value("CMUX_AUTH_ENVIRONMENT").is_some_and(|v| v.eq_ignore_ascii_case("production"));
    let tag = value("CMUX_TAG").and_then(|tag| sanitized_scheme_tag(&tag));
    // A scheme that cannot form `<scheme>://auth-callback` is ignored (it trapped at sign-in).
    let scheme = value("CMUX_AUTH_CALLBACK_SCHEME")
        .filter(|scheme| origin::parse(&format!("{scheme}://auth-callback")).is_some())
        .unwrap_or_else(|| {
            if is_debug_build {
                tag.map_or_else(|| "cmux-dev".to_owned(), |tag| format!("cmux-dev-{tag}"))
            } else {
                default_scheme(bundle_id.as_deref()).to_owned()
            }
        });
    let stack_base = value("CMUX_STACK_BASE_URL").unwrap_or_else(|| STACK_ORIGIN.to_owned());
    // CMUX_NEXT_CLOUD_LINK survives the launch (the app keeps CMUX_NEXT_* variables);
    // CMUX_CLOUD_LINK works only when baked into the bundle's LSEnvironment. The app-server
    // link is the default everywhere; `legacy` keeps the classic one as the escape hatch.
    let link_source = match value("CMUX_NEXT_CLOUD_LINK").or_else(|| value("CMUX_CLOUD_LINK")) {
        Some(link) if link.eq_ignore_ascii_case("legacy") => LinkSource::Legacy,
        _ => LinkSource::AppServer,
    };
    if production {
        return Configuration {
            backend: Backend::Production,
            api_base_url: PRODUCTION_ORIGIN.to_owned(),
            cloud_api_base_url: PRODUCTION_ORIGIN.to_owned(),
            auth_web_origin: PRODUCTION_ORIGIN.to_owned(),
            stack_base_url: stack_base,
            stack_project_id: PRODUCTION_PROJECT_ID.to_owned(),
            stack_publishable_client_key: PRODUCTION_CLIENT_KEY.to_owned(),
            is_production_auth: true,
            callback_scheme: scheme,
            bundle_id,
            is_debug_build,
            link_source,
        };
    }
    // Every non-production build signs in on staging and uses the new cloud with no launch
    // environment. Tagged builds bake loopback origins for a local web server that is usually
    // not running, so a loopback value is taken only when the launch asks for it
    // (`CMUX_NEXT_CLOUD_BACKEND=local`); any other origin still overrides.
    let wants_local = inputs
        .process
        .get("CMUX_NEXT_CLOUD_BACKEND")
        .is_some_and(|v| v.eq_ignore_ascii_case("local"));
    let origin_of = |key: &str| value(key).filter(|url| wants_local || !origin::is_loopback(url));
    let dev_backend = origin_of("CMUX_DEV_BACKEND_URL");
    let named = origin_of("CMUX_VM_API_BASE_URL")
        .or_else(|| origin_of("CMUX_API_BASE_URL"))
        .or_else(|| dev_backend.clone())
        .or_else(|| {
            wants_local.then(|| {
                format!(
                    "http://localhost:{}",
                    value("CMUX_PORT").unwrap_or_else(|| "3777".to_owned())
                )
            })
        });
    let api = named.clone().unwrap_or_else(|| STAGING_WEB_ORIGIN.to_owned());
    let cloud_api = named.unwrap_or_else(|| DEVELOPMENT_WORKER_ORIGIN.to_owned());
    let web = origin_of("CMUX_AUTH_WWW_ORIGIN")
        .or_else(|| dev_backend.clone())
        .unwrap_or_else(|| api.clone());
    let backend = if origin::is_loopback(&cloud_api) && dev_backend.is_none() {
        Backend::LocalOnly(cloud_api.clone())
    } else {
        Backend::Development(cloud_api.clone())
    };
    Configuration {
        backend,
        api_base_url: api,
        cloud_api_base_url: cloud_api,
        auth_web_origin: web,
        stack_base_url: stack_base,
        stack_project_id: value("CMUX_STACK_PROJECT_ID")
            .unwrap_or_else(|| DEVELOPMENT_PROJECT_ID.to_owned()),
        stack_publishable_client_key: value("CMUX_STACK_PUBLISHABLE_CLIENT_KEY")
            .unwrap_or_else(|| DEVELOPMENT_CLIENT_KEY.to_owned()),
        is_production_auth: false,
        callback_scheme: scheme,
        bundle_id,
        is_debug_build,
        link_source,
    }
}

/// The namespace that keeps signed NEXT DEV's staging tokens apart from its old production
/// session: its first staging launch must not read production tokens or prime its cached user
/// and team, and later launches keep their staging sign-in. `None` for every other build.
pub fn auth_storage_project(identity: &Identity) -> Option<String> {
    (is_next_dev(identity.bundle_id.as_deref(), identity.is_debug_build)
        && !identity.is_production_auth
        && identity.stack_project_id == DEVELOPMENT_PROJECT_ID)
        .then(|| identity.stack_project_id.clone())
}

/// The Stack token Keychain service (`<bundle id>.auth`, scoped by [`auth_storage_project`]).
pub fn keychain_service(identity: &Identity) -> String {
    let Some(bundle_id) = identity.bundle_id.as_deref().filter(|id| !id.is_empty()) else {
        return "com.cmuxterm.app.auth".to_owned();
    };
    match auth_storage_project(identity) {
        Some(project) => format!("{bundle_id}.auth.{project}"),
        None => format!("{bundle_id}.auth"),
    }
}

/// The file-fallback token store, under the home folder: `Library/Application Support/cmux/<bundle id>[/<project>]`.
pub fn credentials_subpath(identity: &Identity) -> Vec<String> {
    let mut parts = vec![
        "Library".to_owned(),
        "Application Support".to_owned(),
        "cmux".to_owned(),
        identity.bundle_id.clone().unwrap_or_else(|| "cmux".to_owned()),
    ];
    parts.extend(auth_storage_project(identity));
    parts
}

/// A `cmux.auth.*` defaults key, scoped like the token store.
pub fn auth_defaults_key(identity: &Identity, key: &str) -> String {
    match auth_storage_project(identity) {
        Some(project) => format!("{key}.{project}"),
        None => key.to_owned(),
    }
}

/// The owner API Worker (`/v1/read`, `/v1/ops`, `/v1/auth/*`): production auth uses
/// cloud-api.cmux.dev, signed NEXT DEV and every other development build the development Worker.
/// `CMUX_NEXT_FEED_API_URL` is honored in debug builds only, so a release build never sends a
/// credential to another origin.
pub fn owner_api_base_url(identity: &Identity, environment: &BTreeMap<String, String>) -> String {
    if is_next_dev(identity.bundle_id.as_deref(), identity.is_debug_build) {
        return DEVELOPMENT_WORKER_ORIGIN.to_owned();
    }
    if identity.is_debug_build
        && let Some(raw) = environment.get("CMUX_NEXT_FEED_API_URL")
        && !raw.is_empty()
    {
        return raw.clone();
    }
    if identity.is_production_auth {
        PRODUCTION_OWNER_API.to_owned()
    } else {
        // Non-production builds sign in on staging, whose Stack tokens the development Worker accepts.
        DEVELOPMENT_WORKER_ORIGIN.to_owned()
    }
}

/// The API a guest link's owner token comes from when the daemon does not name its room's: a
/// debug build signed in to staging mints from the development Worker unless
/// `CMUX_NEXT_FEED_API_URL` names the owner API; every other build uses its owner API.
pub fn share_api_base_url(identity: &Identity, environment: &BTreeMap<String, String>) -> String {
    if identity.is_debug_build
        && !identity.is_production_auth
        && !environment.contains_key("CMUX_NEXT_FEED_API_URL")
    {
        DEVELOPMENT_WORKER_ORIGIN.to_owned()
    } else {
        owner_api_base_url(identity, environment)
    }
}

/// Whether a guest link's owner token may come from `api`, the API the daemon's share room
/// names. Only a bare https origin; a release build takes only a cmux API.
pub fn accepts_share_api(identity: &Identity, api: &str) -> bool {
    origin::is_bare_https_origin(api)
        && (identity.is_debug_build
            || origin::host(api).is_some_and(|host| SHARE_API_HOSTS.contains(&host.as_str())))
}

/// The cmux VM API for this build's Cloud: production's for production, staging's for a
/// development stack. There is no override: the app sends its Stack session only there.
pub fn vm_api_base_url(backend: &Backend) -> &'static str {
    match backend {
        Backend::Production => PRODUCTION_VM_API,
        Backend::Development(_) | Backend::LocalOnly(_) => STAGING_VM_API,
    }
}

/// Preview ingress, served directly by cmux-platform: only the staging and development owners
/// have one (until production ingress is ready). A debug build signed in to staging on the app
/// link may name its own (`CMUX_NEXT_PLATFORM_PREVIEW_API_URL`, a bare https origin).
pub fn platform_preview_api_base_url(
    identity: &Identity,
    environment: &BTreeMap<String, String>,
) -> Option<String> {
    if identity.link_source != Some(LinkSource::AppServer)
        || !identity.is_debug_build
        || identity.is_production_auth
    {
        return None;
    }
    if let Some(raw) = environment.get("CMUX_NEXT_PLATFORM_PREVIEW_API_URL") {
        let named = origin::parse(raw).is_some_and(|parts| {
            parts.scheme == "https"
                && !parts.host.is_empty()
                && parts.user.is_none()
                && parts.password.is_none()
                && parts.query.is_none()
                && parts.fragment.is_none()
                && (parts.path.is_empty() || parts.path == "/")
        });
        return named.then(|| raw.clone());
    }
    match origin::host(&owner_api_base_url(identity, environment)).as_deref() {
        Some("cloud-api-staging.cmux.dev") => Some(STAGING_PLATFORM.to_owned()),
        Some("cmux-api-development.debussy.workers.dev") => Some(DEVELOPMENT_PLATFORM.to_owned()),
        _ => None,
    }
}

/// The cmux-platform origin of the Artifacts page: production's for production auth; a debug
/// build may name a platform origin (`CMUX_NEXT_ARTIFACTS_API_URL`).
pub fn artifacts_api_base_url(
    identity: &Identity,
    environment: &BTreeMap<String, String>,
) -> String {
    if identity.is_debug_build
        && let Some(raw) = environment.get("CMUX_NEXT_ARTIFACTS_API_URL")
        && is_platform_origin(raw)
    {
        return raw.clone();
    }
    if identity.is_production_auth {
        return PRODUCTION_PLATFORM.to_owned();
    }
    platform_preview_api_base_url(identity, environment)
        .unwrap_or_else(|| DEVELOPMENT_PLATFORM.to_owned())
}

fn is_platform_origin(raw: &str) -> bool {
    let Some(parts) = origin::parse(raw) else { return false };
    if parts.host.is_empty()
        || parts.user.is_some()
        || parts.password.is_some()
        || parts.query.is_some()
        || parts.fragment.is_some()
    {
        return false;
    }
    match parts.scheme.as_str() {
        "https" => parts.host.ends_with(".debussy.workers.dev") && parts.port.is_none(),
        "http" => matches!(parts.host.as_str(), "localhost" | "127.0.0.1" | "::1"),
        _ => false,
    }
}

/// Whether this is a PR capture's Release build: the bench configuration (`CMUX_BENCH_HOOKS`,
/// never in a shipped app) of the tag `cap<sha10>`. Its Cloud is configured as a Debug build's.
pub fn is_capture_build(bundle_id: Option<&str>, bench_hooks: bool) -> bool {
    let Some(tag) = bundle_id.and_then(|id| id.strip_prefix(CAPTURE_BUNDLE_PREFIX)) else {
        return false;
    };
    bench_hooks
        && tag.len() == 10
        && tag.bytes().all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
}

/// The release channel's sign-in callback scheme.
pub fn default_scheme(bundle_id: Option<&str>) -> &'static str {
    match bundle_id {
        Some("com.cmuxterm.app.nightly") => "cmux-nightly",
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
