//! The backend owns client configuration. Build-time values are an origin
//! allowlist and a temporary fallback for deployments predating this endpoint.

use crate::{Configuration, Environment, Resolver, Selection, namespace};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::fs::{self, OpenOptions};
use std::io::Write;
#[cfg(unix)]
use std::os::unix::fs::OpenOptionsExt;
use std::path::Path;
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
        let advertised = selection
            .capabilities
            .get("machine_create")
            .and_then(Value::as_object)
            .and_then(|capabilities| capabilities.get(*field));
        match advertised {
            Some(Value::Bool(true)) => {}
            Some(Value::Bool(false)) => {
                return Err(format!(
                    "backend capability refused: machine_create.{field} (backend {})",
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
/// configuration. None (fetch) for a custom origin with no cache or any unreadable cache.
pub(crate) fn without_fetch(resolver: &Resolver, mut selection: Selection) -> Option<Selection> {
    match cached(resolver, selection.clone()) {
        Ok(Some(cached)) => Some(cached),
        Ok(None)
            if !matches!(
                Environment::parse(&selection.api_origin),
                Ok(Environment::LocalOrigin(_)) | Err(_)
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
    let client = reqwest::Client::builder()
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
            // local API must expose its actual configuration.
            if matches!(Environment::parse(origin)?, Environment::LocalOrigin(_)) {
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

fn allowed_origin(value: &str, selected: &str) -> Result<(), String> {
    let origin = bare_origin(value)?;
    if is_loopback_origin(&origin) {
        return if is_loopback_origin(selected) {
            Ok(())
        } else {
            Err(format!("remote client-config cannot name a loopback origin: {value}"))
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
    let Ok(url) = url::Url::parse(origin) else { return false };
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
fn fetch_stamp() -> u128 {
    SystemTime::now().duration_since(UNIX_EPOCH).map_or(0, |since| since.as_millis())
}

/// Writes a fetched client-config unless a fetch that started later already wrote one, and answers
/// whether it wrote. Two processes can fetch at once (a launch's refresh still running when the next
/// launch's starts, a `cloud env get` beside them), and their answers land in any order: without
/// this an older answer could replace a newer one. Each write keeps its fetch's start beside the
/// cache (`.started`), checked and written under an exclusive lock on `.lock`.
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

#[cfg(test)]
mod tests;
