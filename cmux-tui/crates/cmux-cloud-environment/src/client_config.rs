//! The backend owns client configuration. Build-time values are an origin
//! allowlist and a temporary fallback for deployments predating this endpoint.

use crate::{Configuration, Environment, Resolver, Selection, namespace};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::fs;
#[cfg(feature = "fetch")]
use std::fs::OpenOptions;
#[cfg(feature = "fetch")]
use std::io::Write;
#[cfg(all(unix, feature = "fetch"))]
use std::os::unix::fs::OpenOptionsExt;
#[cfg(feature = "fetch")]
use std::path::Path;
#[cfg(feature = "fetch")]
use std::time::{Duration, SystemTime, UNIX_EPOCH};

#[derive(Clone, Copy, Debug, Default, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum ConfigSource {
    Backend,
    Cache,
    #[default]
    KnownOriginFallback,
}

/// Public non-secret contract returned by GET /v1/client-config. The outer
/// selected origin is never replaced by the response; all other credential
/// destinations must be bare HTTPS origins (HTTP loopback for local only).
#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
pub struct ClientConfig {
    #[serde(alias = "schema_version")]
    pub version: u32,
    #[serde(flatten)]
    pub configuration: Configuration,
    pub capabilities: Value,
    pub image_channel: String,
}

/// Create parameters whose meaning is only safe when the selected backend
/// advertises the corresponding capability. The legacy size object and name
/// are supported by the compatibility path; named sizes are backend-specific.
pub const ADVANCED_CREATE_FIELDS: &[&str] =
    &["size_name", "idle_seconds", "bootstrap", "machine_config_base64"];

/// The Mac applies these fields itself once the machine exists (bootstrap, idle pause, named size); the create op
/// never receives them. The backend's `capabilities.create` block answers whether it lets the Mac apply each,
/// while `capabilities.machine_create` answers whether the create op itself takes it (cmux-platform
/// CreateOptions.ts, #1703), which is false for all of them. So a field with a key here is read from `create`,
/// and from `machine_create` only when the backend's `create` does not name it.
const MAC_APPLIED_CREATE_KEYS: &[(&str, &str)] =
    &[("size_name", "size"), ("idle_seconds", "idlePause"), ("bootstrap", "bootstrap")];

/// Fail closed before a machine-create request is sent when a parameter needs
/// a backend capability that was not advertised by `/v1/client-config`.
/// `null` values are equivalent to an omitted optional field.
pub fn check_create_capabilities(selection: &Selection, params: &Value) -> Result<(), String> {
    let object = params
        .as_object()
        .ok_or_else(|| "machine create parameters must be a JSON object".to_owned())?;
    for field in ADVANCED_CREATE_FIELDS {
        if object.get(*field).is_none_or(Value::is_null) {
            continue;
        }
        let read = |group: &str, key: &str| {
            selection
                .capabilities
                .get(group)
                .and_then(Value::as_object)
                .and_then(|capabilities| capabilities.get(key))
                .map(|value| (format!("{group}.{key}"), value))
        };
        let mac_applied = MAC_APPLIED_CREATE_KEYS
            .iter()
            .find(|(name, _)| name == field)
            .and_then(|(_, key)| read("create", key));
        // A named size goes out as the `size` object the op always takes (`memory_mb`; the server's ladder
        // picks the vCPUs), so the name needs no capability of its own when that object rides along. Only
        // a backend whose create block says no to it (`create.size: false`) refuses it. A cache or
        // fallback configuration from before the create block (2026-11-25: `cmux vm new --size small`,
        // vm --help's own example, refused "machine_create.size_name") still takes it.
        if *field == "size_name"
            && object.get("size").is_some_and(Value::is_object)
            && !matches!(mac_applied, Some((_, Value::Bool(false))))
        {
            continue;
        }
        let advertised = mac_applied.or_else(|| read("machine_create", field));
        match advertised {
            Some((_, Value::Bool(true))) => {}
            Some((name, Value::Bool(false))) => {
                return Err(format!(
                    "backend capability refused: {name} (backend {})",
                    selection.api_origin
                ));
            }
            _ => {
                return Err(format!(
                    "backend capability not declared/unavailable: machine_create.{field} (backend {})",
                    selection.api_origin
                ));
            }
        }
    }
    Ok(())
}

/// Whether a create's parameters name a field whose meaning needs a backend capability
/// (check_create_capabilities). `null` is an omitted field.
#[cfg(feature = "fetch")]
pub(crate) fn create_needs_capabilities(params: &Value) -> Result<bool, String> {
    let object = params
        .as_object()
        .ok_or_else(|| "machine create parameters must be a JSON object".to_owned())?;
    Ok(ADVANCED_CREATE_FIELDS
        .iter()
        .any(|field| object.get(*field).is_some_and(|value| !value.is_null())))
}

pub(crate) fn cached(
    resolver: &Resolver,
    mut selection: Selection,
) -> Result<Option<Selection>, String> {
    let origin = selection.api_origin.clone();
    Environment::parse(&origin)?;
    let path = cache_path(resolver, &origin)?;
    let body = match fs::read(&path) {
        Ok(body) => body,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(error) => return Err(format!("read cached client-config for {origin}: {error}")),
    };
    let config: ClientConfig = serde_json::from_slice(&body)
        .map_err(|error| format!("invalid cached client-config for {origin}: {error}"))?;
    validate(&config, &origin)?;
    apply(&mut selection, config, ConfigSource::Cache);
    Ok(Some(selection))
}

/// The launch answer that needs no fetch: a valid cache, else a known deployment's built-in
/// configuration. None (fetch) for a custom origin with no cache or any unreadable cache. A tailnet
/// stack is custom too: it serves its own mobile and device hub origins, and a first launch on the
/// development table instead would register the Mac with the shared mobile service while the
/// tag's iPhone build, on the stack's, looks for it there (scripts/cmux-next/cloud-dev-stack).
pub(crate) fn without_fetch(resolver: &Resolver, mut selection: Selection) -> Option<Selection> {
    match cached(resolver, selection.clone()) {
        Ok(Some(cached)) => Some(cached),
        Ok(None)
            if !matches!(
                Environment::parse(&selection.api_origin),
                Ok(Environment::LocalOrigin(_) | Environment::Tailnet(_)) | Err(_)
            ) =>
        {
            selection.config_source = ConfigSource::KnownOriginFallback;
            Some(selection)
        }
        Ok(None) | Err(_) => None,
    }
}

fn cache_path(resolver: &Resolver, origin: &str) -> Result<std::path::PathBuf, String> {
    Ok(resolver
        .state_path()
        .parent()
        .ok_or("cloud state has no parent")?
        .join("client-config")
        .join(format!("{}.json", namespace(origin))))
}

#[cfg(feature = "fetch")]
pub(crate) async fn resolve(
    resolver: &Resolver,
    mut selection: Selection,
) -> Result<Selection, String> {
    let origin = selection.api_origin.clone();
    // The selected origin itself must pass the same check even when a Rust
    // caller constructs Selection or Environment without the CLI parser.
    Environment::parse(&origin)?;
    let _ = rustls::crypto::ring::default_provider().install_default();
    // Short bounded fetches keep launch responsive; cache or the known-origin
    // fallback covers backend outages without mixing sign-in credentials.
    let client = cmux_egress::client_builder("cmux_cloud_environment::client_config")
        .default_headers(cmux_build_space::headers().map_err(|error| error.to_string())?)
        .redirect(reqwest::redirect::Policy::none())
        .connect_timeout(Duration::from_secs(2))
        .timeout(Duration::from_secs(5))
        .build()
        .map_err(|error| format!("create client-config HTTP client: {error}"))?;
    // The fence for this fetch's cache write: a fetch that started earlier never replaces it.
    let started = fetch_stamp();
    let response = client.get(format!("{origin}/v1/client-config")).send().await;
    let path = cache_path(resolver, &origin)?;
    match response {
        Ok(response) if response.status() == reqwest::StatusCode::OK => {
            let body = match response.bytes().await {
                Ok(body) => body,
                Err(_) => return cached_or_fallback(selection, &path, &origin),
            };
            // A malformed success is a protocol/security error. Never hide it
            // behind a stale cache or fallback configuration.
            let config: ClientConfig = serde_json::from_slice(&body)
                .map_err(|error| format!("invalid client-config from {origin}: {error}"))?;
            validate(&config, &origin)?;
            fenced_cache(&path, &body, started)?;
            apply(&mut selection, config, ConfigSource::Backend);
            Ok(selection)
        }
        Ok(response) if response.status().is_redirection() => {
            Err(format!("client-config redirect refused from {origin}"))
        }
        Ok(response)
            if response.status().is_client_error()
                && response.status() != reqwest::StatusCode::NOT_FOUND =>
        {
            Err(format!("client-config refused by {origin}: HTTP {}", response.status()))
        }
        Ok(response) if response.status().is_success() => Err(format!(
            "unexpected client-config success status from {origin}: {}",
            response.status()
        )),
        Ok(_) | Err(_) => cached_or_fallback(selection, &path, &origin),
    }
}

#[cfg(feature = "fetch")]
fn cached_or_fallback(
    mut selection: Selection,
    path: &Path,
    origin: &str,
) -> Result<Selection, String> {
    match fs::read(path) {
        Ok(body) => {
            let config: ClientConfig = serde_json::from_slice(&body)
                .map_err(|error| format!("invalid cached client-config for {origin}: {error}"))?;
            validate(&config, origin)?;
            apply(&mut selection, config, ConfigSource::Cache);
        }
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
            // Temporary compatibility only for known deployments. A custom
            // local API must expose its actual configuration, and so must a tag
            // stack: the development table would register the Mac with the shared
            // mobile service and device hub while the tag's iPhone build, on the
            // stack's, looks for it there (the launch then has no cloud, and says why).
            if matches!(
                Environment::parse(origin)?,
                Environment::LocalOrigin(_) | Environment::Tailnet(_)
            ) {
                return Err(format!("client-config unavailable and no cache for {origin}"));
            }
            selection.config_source = ConfigSource::KnownOriginFallback;
        }
        Err(error) => return Err(format!("read cached client-config for {origin}: {error}")),
    }
    Ok(selection)
}

fn apply(selection: &mut Selection, config: ClientConfig, source: ConfigSource) {
    let name = selection.configuration.name.clone();
    // Historical credentials belong to the historical Stack project. A
    // backend moving projects must restore from its isolated storage instead.
    if selection.legacy_storage
        && selection.configuration.stack_project_id != config.configuration.stack_project_id
    {
        selection.legacy_storage = false;
        selection.auth_storage_namespace = Some(selection.auth_namespace.clone());
    }
    selection.configuration = config.configuration;
    selection.configuration.name = name;
    selection.config_source = source;
    selection.client_config_version = Some(config.version);
    selection.capabilities = config.capabilities;
    selection.image_channel = Some(config.image_channel);
}

pub(crate) fn bare_origin(value: &str) -> Result<String, String> {
    let url = url::Url::parse(value).map_err(|error| format!("invalid origin {value}: {error}"))?;
    if !matches!(url.scheme(), "http" | "https")
        || url.host_str().is_none()
        || !url.username().is_empty()
        || url.password().is_some()
        || url.path() != "/"
        || url.query().is_some()
        || url.fragment().is_some()
    {
        return Err(format!("expected a bare HTTP(S) origin: {value}"));
    }
    Ok(url.origin().ascii_serialization())
}

pub(crate) fn is_loopback_origin(value: &str) -> bool {
    url::Url::parse(value).is_ok_and(|url| {
        url.scheme() == "http"
            && matches!(url.host_str(), Some("localhost" | "127.0.0.1" | "[::1]"))
    })
}

/// A tailnet backend: `https://<machine>.tail137216.ts.net[:port]` ([`TEAM_TAILNET_SUFFIX`]), the
/// name Tailscale Serve gives a dev VM's per-tag stack on the team's tailnet. HTTPS only (Serve's
/// certificate); another tailnet's name, a bare `ts.net` or an IP never matches.
pub(crate) fn is_tailnet_origin(value: &str) -> bool {
    url::Url::parse(value).is_ok_and(|url| {
        url.scheme() == "https"
            && matches!(url.host(), Some(url::Host::Domain(_)))
            && url.host_str().is_some_and(|host| {
                host.strip_suffix(TEAM_TAILNET_SUFFIX).is_some_and(|machine| {
                    !machine.is_empty()
                        && machine.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-')
                })
            })
    })
}

/// The team's tailnet (its MagicDNS suffix): a tailnet origin is one machine of it,
/// `https://<machine>.tail137216.ts.net[:port]`. Any other `*.ts.net` name is refused: a Tailscale
/// Funnel name of another tailnet is public, so it is no dev stack of ours.
pub(crate) const TEAM_TAILNET_SUFFIX: &str = ".tail137216.ts.net";

/// The public suffix of a tag stack's origins (scripts/cmux-next/cloud-dev-stack/gateway).
const PUBLIC_STACK_SUFFIX: &str = ".wdev.cmux.dev";

/// A tag stack's public slot (`s<N>`, 1-3 digits) in a host `<svc>.s<N>.wdev.cmux.dev`, or None.
fn public_stack_slot(host: &str) -> Option<(&str, &str)> {
    let (service, rest) = host.strip_suffix(PUBLIC_STACK_SUFFIX)?.split_once('.')?;
    let digits = rest.strip_prefix('s')?;
    (!digits.is_empty() && digits.len() <= 3 && digits.bytes().all(|b| b.is_ascii_digit()))
        .then_some((service, rest))
}

/// A tag stack's public API origin: `https://api.s<N>.wdev.cmux.dev`, HTTPS on the default port, the
/// one host the gateway answers for a slot's API. Its mobile and hub siblings are never a backend.
pub(crate) fn is_public_stack_origin(value: &str) -> bool {
    url::Url::parse(value).is_ok_and(|url| {
        url.scheme() == "https"
            && url.port().is_none()
            && url
                .host_str()
                .and_then(public_stack_slot)
                .is_some_and(|(service, _)| service == "api")
    })
}

fn host(value: &str) -> Option<String> {
    url::Url::parse(value).ok()?.host_str().map(str::to_owned)
}

fn allowed_origin(value: &str, selected: &str) -> Result<(), String> {
    let origin = bare_origin(value)?;
    if is_loopback_origin(&origin) {
        return if is_loopback_origin(selected) {
            Ok(())
        } else {
            Err(format!("remote client-config cannot name a loopback origin: {value}"))
        };
    }
    // A public stack may name its own other services (the same slot's mobile and hub); no other
    // backend may send credentials to a tag stack's public host, though it is under cmux.dev.
    if let Some((service, slot)) = host(&origin).as_deref().and_then(public_stack_slot) {
        let own_slot = is_public_stack_origin(selected)
            && host(selected)
                .as_deref()
                .and_then(public_stack_slot)
                .is_some_and(|(_, selected_slot)| selected_slot == slot);
        return if own_slot
            && matches!(service, "api" | "mobile" | "hub")
            && url::Url::parse(&origin).is_ok_and(|u| u.scheme() == "https" && u.port().is_none())
        {
            Ok(())
        } else {
            Err(format!("client-config cannot name another tag stack's public host: {value}"))
        };
    }
    // A tailnet stack may name its own other services (same host, any port); no other backend
    // may send credentials to a tailnet host.
    if is_tailnet_origin(&origin) {
        return if is_tailnet_origin(selected) && host(&origin) == host(selected) {
            Ok(())
        } else {
            Err(format!("client-config cannot name another tailnet host: {value}"))
        };
    }
    if approved_remote_host(&origin) {
        Ok(())
    } else {
        Err(format!("client-config service origin is outside the approved host policy: {value}"))
    }
}

/// Client-config is backend-owned, but it is also allowed to name credential
/// destinations. Keep that data constrained to domains operated by cmux (and
/// Stack's documented API) so a compromised response cannot exfiltrate tokens.
fn approved_remote_host(origin: &str) -> bool {
    let Ok(url) = url::Url::parse(origin) else {
        return false;
    };
    if url.scheme() != "https" || url.host_str().is_none() {
        return false;
    }
    let host = url.host_str().unwrap_or_default();
    host == "api.stack-auth.com"
        || host == "cmux.com"
        || host.ends_with(".cmux.com")
        || host == "cmux.dev"
        || host.ends_with(".cmux.dev")
        || host == "cmux-staging.vercel.app"
        || host.ends_with(".debussy.workers.dev")
}

fn validate(config: &ClientConfig, selected: &str) -> Result<(), String> {
    if config.version != 1 {
        return Err(format!("unsupported client-config version: {}", config.version));
    }
    if bare_origin(&config.configuration.api_origin)? != selected {
        return Err("client-config API origin differs from the selected backend".into());
    }
    for origin in [
        &config.configuration.api_origin,
        &config.configuration.auth_web_origin,
        &config.configuration.vm_origin,
        &config.configuration.platform_origin,
        &config.configuration.mobile_origin,
        &config.configuration.device_hub_origin,
        &config.configuration.share_room_origin,
        &config.configuration.share_api_origin,
        &config.configuration.stack_origin,
    ] {
        allowed_origin(origin, selected)?;
    }
    if config.configuration.stack_project_id.is_empty() {
        return Err("client-config Stack project is empty".into());
    }
    if !config.capabilities.is_object() || config.image_channel.is_empty() {
        return Err("invalid client-config capabilities or image channel".into());
    }
    Ok(())
}

/// When a fetch started, in ms since the epoch: what its cache write is fenced by.
#[cfg(feature = "fetch")]
fn fetch_stamp() -> u128 {
    SystemTime::now().duration_since(UNIX_EPOCH).map_or(0, |since| since.as_millis())
}

/// Writes a fetched client-config unless a fetch that started later already wrote one, and answers
/// whether it wrote. Two processes can fetch at once (a launch's refresh still running when the next
/// launch's starts, a `cloud env get` beside them), and their answers land in any order: without
/// this an older answer could replace a newer one. Each write keeps its fetch's start beside the
/// cache (`.started`), checked and written under an exclusive lock on `.lock`.
#[cfg(feature = "fetch")]
fn fenced_cache(path: &Path, body: &[u8], started: u128) -> Result<bool, String> {
    let stamp = path.with_extension("json.started");
    let lock_path = path.with_extension("json.lock");
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)
            .map_err(|error| format!("create client-config cache: {error}"))?;
    }
    let mut options = OpenOptions::new();
    options.write(true).create(true).truncate(false);
    #[cfg(unix)]
    options.mode(0o600);
    let lock =
        options.open(&lock_path).map_err(|error| format!("open client-config lock: {error}"))?;
    lock.lock().map_err(|error| format!("lock client-config cache: {error}"))?;
    let newer = fs::read_to_string(&stamp)
        .ok()
        .and_then(|text| text.trim().parse::<u128>().ok())
        .is_some_and(|written| written > started);
    if newer {
        return Ok(false);
    }
    atomic_cache(path, body)?;
    atomic_cache(&stamp, started.to_string().as_bytes())?;
    Ok(true)
}

#[cfg(feature = "fetch")]
fn atomic_cache(path: &Path, body: &[u8]) -> Result<(), String> {
    let parent = path.parent().ok_or("client-config cache has no parent")?;
    fs::create_dir_all(parent).map_err(|error| format!("create client-config cache: {error}"))?;
    let temporary = crate::temp_path(parent);
    let mut options = OpenOptions::new();
    options.write(true).create_new(true);
    #[cfg(unix)]
    options.mode(0o600);
    let mut file =
        options.open(&temporary).map_err(|error| format!("create client-config cache: {error}"))?;
    let result = (|| {
        file.write_all(body).map_err(|error| format!("write client-config cache: {error}"))?;
        file.sync_all().map_err(|error| format!("sync client-config cache: {error}"))?;
        drop(file);
        fs::rename(&temporary, path)
            .map_err(|error| format!("replace client-config cache: {error}"))?;
        crate::sync_directory(parent)
    })();
    let _ = fs::remove_file(temporary);
    result
}

#[cfg(feature = "fetch")]
#[cfg(test)]
#[path = "client_config_tests.rs"]
mod tests;
