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
    let client = reqwest::Client::builder()
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
mod tests {
    use super::*;
    use std::io::{BufRead, BufReader};
    use std::net::TcpListener;

    struct Home(std::path::PathBuf);
    impl Home {
        fn new() -> Self {
            let path = std::env::temp_dir().join(format!(
                "cmux-client-config-test-{}-{}",
                std::process::id(),
                crate::next_revision()
            ));
            fs::create_dir(&path).unwrap();
            Self(path)
        }
    }
    impl Drop for Home {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }

    fn config(origin: &str) -> ClientConfig {
        let mut configuration = Environment::Dev.configuration();
        configuration.api_origin = origin.into();
        ClientConfig {
            version: 1,
            configuration,
            capabilities: serde_json::json!({"machine_create": {"size": true}}),
            image_channel: "development".into(),
        }
    }

    #[test]
    fn create_capability_preflight_fails_closed_and_accepts_dynamic_flags() {
        let home = Home::new();
        let resolver = Resolver::new(crate::DEV_BUNDLE, &home.0).unwrap();
        let mut selection = resolver.resolve(Some("dev")).unwrap();
        selection.capabilities = serde_json::json!({
            "machine_create": {"size": true, "name": true, "bootstrap": false}
        });
        check_create_capabilities(&selection, &serde_json::json!({"image": "ubuntu"})).unwrap();
        check_create_capabilities(
            &selection,
            &serde_json::json!({"size": {"cpu": 2}, "name": "worker"}),
        )
        .unwrap();
        let named =
            check_create_capabilities(&selection, &serde_json::json!({"size_name": "large"}))
                .unwrap_err();
        assert!(named.contains("machine_create.size_name"));
        let refused = check_create_capabilities(&selection, &serde_json::json!({"bootstrap": "x"}))
            .unwrap_err();
        assert!(refused.contains("backend capability refused: machine_create.bootstrap"));
        let missing =
            check_create_capabilities(&selection, &serde_json::json!({"size_name": "large"}))
                .unwrap_err();
        assert!(
            missing
                .contains("backend capability not declared/unavailable: machine_create.size_name")
        );
        selection.capabilities["machine_create"]["size_name"] = serde_json::json!(true);
        check_create_capabilities(&selection, &serde_json::json!({"size_name": "large"})).unwrap();
    }

    #[tokio::test]
    async fn check_create_reads_the_backend_only_for_a_field_that_needs_a_capability() {
        // The app runs check-create before every Cloud create, on the create's path. A create that names no
        // advanced field needs no capability: it must answer without a client-config round trip. Against a
        // backend that takes the connection and never answers, any fetch waits out its 5 s timeout.
        let silent = TcpListener::bind("127.0.0.1:0").unwrap();
        silent.set_nonblocking(true).unwrap();
        let origin = format!("http://{}", silent.local_addr().unwrap());
        let home = Home::new();
        let resolver = Resolver::new(crate::DEV_BUNDLE, &home.0).unwrap();
        let selected = resolver.resolve(Some(&origin)).unwrap();
        let plain = serde_json::json!({
            "name": "chat",
            "size": {"cpu": 2, "memory_mb": 4096, "disk_mb": 16384},
            "size_name": null,
        });
        let started = std::time::Instant::now();
        let checked = resolver.check_create(selected.clone(), &plain).await;
        let elapsed = started.elapsed();
        assert!(checked.is_ok(), "{checked:?}");
        assert!(elapsed < Duration::from_secs(1), "{elapsed:?}");
        assert!(
            matches!(silent.accept(), Err(error) if error.kind() == std::io::ErrorKind::WouldBlock),
            "check-create of a plain create connected to the backend"
        );
        drop(silent);

        // A field that needs a capability still reads the backend's advertised capabilities, and fails closed.
        let (origin, server) =
            serve(|origin| http_json(&serde_json::to_string(&config(origin)).unwrap()));
        let selected = resolver.resolve(Some(&origin)).unwrap();
        let refused = resolver
            .check_create(selected, &serde_json::json!({"size_name": "large"}))
            .await
            .unwrap_err();
        server.join().unwrap();
        assert!(refused.contains("machine_create.size_name"), "{refused}");
    }

    #[test]
    fn project_change_isolates_historical_credentials() {
        let home = Home::new();
        let resolver = Resolver::new("com.cmuxterm.app", &home.0).unwrap();
        let mut selection = resolver.resolve(None).unwrap();
        assert!(selection.legacy_storage);
        let mut updated = config(crate::PRODUCTION_API);
        updated.configuration.stack_project_id = "replacement-project".into();
        apply(&mut selection, updated, ConfigSource::Backend);
        assert!(!selection.legacy_storage);
        assert_eq!(
            selection.auth_storage_namespace.as_deref(),
            Some(selection.auth_namespace.as_str())
        );
        assert_eq!(selection.stack_project_id, "replacement-project");
    }

    #[test]
    fn credential_origin_validation_rejects_embedded_and_insecure_destinations() {
        let valid = config(crate::DEVELOPMENT_API);
        validate(&valid, crate::DEVELOPMENT_API).unwrap();
        for origin in [
            "http://service.example",
            "https://user@cmux.com",
            "https://cmux.com/path",
            "https://cmux.com?redirect=evil",
            "http://localhost:3777",
        ] {
            let mut invalid = valid.clone();
            invalid.configuration.auth_web_origin = origin.into();
            assert!(validate(&invalid, crate::DEVELOPMENT_API).is_err(), "{origin}");
        }
        let mut dynamic = valid.clone();
        dynamic.configuration.share_room_origin = "https://links.cmux.dev".into();
        validate(&dynamic, crate::DEVELOPMENT_API).unwrap();
        dynamic.configuration.stack_origin = "https://api.stack-auth.com".into();
        validate(&dynamic, crate::DEVELOPMENT_API).unwrap();
        dynamic.configuration.stack_origin = "https://auth-service.example".into();
        assert!(validate(&dynamic, crate::DEVELOPMENT_API).is_err());
        let mut invalid = valid;
        invalid.configuration.api_origin = crate::PRODUCTION_API.into();
        assert!(validate(&invalid, crate::DEVELOPMENT_API).is_err());
    }

    #[test]
    fn absent_known_backend_uses_explicit_compatibility_source_but_invalid_cache_fails_closed() {
        let home = Home::new();
        let resolver = Resolver::new(crate::DEV_BUNDLE, &home.0).unwrap();
        let selected = resolver.resolve(Some("staging")).unwrap();
        let cache = home.0.join("cache.json");
        let fallback = cached_or_fallback(selected.clone(), &cache, crate::STAGING_API).unwrap();
        assert_eq!(fallback.config_source, ConfigSource::KnownOriginFallback);
        fs::write(&cache, "{bad").unwrap();
        assert!(cached_or_fallback(selected, &cache, crate::STAGING_API).is_err());
    }

    fn serve(
        response: impl FnOnce(&str) -> String + Send + 'static,
    ) -> (String, std::thread::JoinHandle<()>) {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let origin = format!("http://{}", listener.local_addr().unwrap());
        let server_origin = origin.clone();
        let server = std::thread::spawn(move || {
            let (mut socket, _) = listener.accept().unwrap();
            socket.set_read_timeout(Some(Duration::from_secs(5))).unwrap();
            let mut reader = BufReader::new(socket.try_clone().unwrap());
            let mut request = String::new();
            reader.read_line(&mut request).unwrap();
            assert_eq!(request, "GET /v1/client-config HTTP/1.1\r\n");
            loop {
                request.clear();
                reader.read_line(&mut request).unwrap();
                if request == "\r\n" {
                    break;
                }
            }
            socket.write_all(response(&server_origin).as_bytes()).unwrap();
        });
        (origin, server)
    }

    fn http_json(body: &str) -> String {
        format!(
            "HTTP/1.1 200 OK\r\nContent-Length: {}\r\nContent-Type: application/json\r\nConnection: close\r\n\r\n{body}",
            body.len()
        )
    }

    #[tokio::test]
    async fn fetch_validates_then_cache_survives_outage_and_stays_per_backend() {
        let (origin, server) =
            serve(|origin| http_json(&serde_json::to_string(&config(origin)).unwrap()));
        let home = Home::new();
        let resolver = Resolver::new(crate::DEV_BUNDLE, &home.0).unwrap();
        let selected = resolver.resolve(Some(&origin)).unwrap();
        let served = resolver.client_config(selected.clone()).await.unwrap();
        server.join().unwrap();
        assert_eq!(served.config_source, ConfigSource::Backend);
        assert_eq!(served.image_channel.as_deref(), Some("development"));
        assert_eq!(served.client_config_version, Some(1));
        let cached = resolver.client_config(selected).await.unwrap();
        assert_eq!(cached.config_source, ConfigSource::Cache);
        assert_eq!(served.configuration, cached.configuration);
        let other = resolver.resolve(Some("http://127.0.0.1:1")).unwrap();
        assert!(resolver.client_config(other).await.is_err());
    }

    #[test]
    fn a_public_stack_names_only_its_own_slots_services_and_no_one_else_names_a_public_stack() {
        let stack = "https://api.s7.wdev.cmux.dev";
        let mut own = config(stack);
        own.configuration.mobile_origin = "https://mobile.s7.wdev.cmux.dev".into();
        own.configuration.device_hub_origin = "https://hub.s7.wdev.cmux.dev".into();
        validate(&own, stack).unwrap();
        for other in [
            "https://mobile.s8.wdev.cmux.dev",
            "https://evil.s7.wdev.cmux.dev",
            "https://mobile.s7.wdev.cmux.dev:8443",
            "http://mobile.s7.wdev.cmux.dev",
            "http://hub.s7.wdev.cmux.dev",
        ] {
            let mut cross = config(stack);
            cross.configuration.mobile_origin = other.into();
            assert!(validate(&cross, stack).is_err(), "{other}");
        }
        // The shared development deployment never sends a token to a tag stack, though it is cmux.dev.
        let mut from_dev = config(crate::DEVELOPMENT_API);
        from_dev.configuration.mobile_origin = "https://mobile.s7.wdev.cmux.dev".into();
        assert!(validate(&from_dev, crate::DEVELOPMENT_API).is_err());
    }

    #[test]
    fn public_stack_origins_are_one_slots_api_host_only() {
        for good in ["https://api.s1.wdev.cmux.dev", "https://api.s123.wdev.cmux.dev/"] {
            let origin = bare_origin(good).unwrap();
            assert!(is_public_stack_origin(&origin), "{good}");
        }
        for bad in [
            "http://api.s1.wdev.cmux.dev",
            "https://api.s1.wdev.cmux.dev:8443",
            "https://mobile.s1.wdev.cmux.dev",
            "https://api.s1234.wdev.cmux.dev",
            "https://api.s.wdev.cmux.dev",
            "https://api.x1.wdev.cmux.dev",
            "https://api.s1.wdev.cmux.dev.attacker.example",
            "https://api.s1.wdev.cmux.dev.cmux.dev",
            "https://wdev.cmux.dev",
            "https://api.s1.other.cmux.dev",
        ] {
            assert!(!is_public_stack_origin(bad), "{bad}");
        }
    }

    #[test]
    fn a_tailnet_stack_may_name_its_own_host_only_and_no_one_else_may_name_a_tailnet_host() {
        let stack = "https://cmux-dev-backend-1.tail137216.ts.net:3850";
        let mut own = config(stack);
        own.configuration.platform_origin =
            "https://cmux-dev-backend-1.tail137216.ts.net:3851".into();
        validate(&own, stack).unwrap();
        let mut other = config(stack);
        other.configuration.platform_origin = "https://other-host.tail137216.ts.net".into();
        assert!(validate(&other, stack).is_err());
        let mut from_dev = config(crate::DEVELOPMENT_API);
        from_dev.configuration.platform_origin =
            "https://cmux-dev-backend-1.tail137216.ts.net:3851".into();
        assert!(validate(&from_dev, crate::DEVELOPMENT_API).is_err());
    }

    #[test]
    fn a_tailnet_launch_fetches_the_stacks_own_services_once_and_an_outage_falls_back_to_dev() {
        let stack = "https://cmux-dev-backend-1.tail137216.ts.net:3850";
        let home = Home::new();
        let resolver = Resolver::new("com.cmuxterm.app.debug.cnx-tag", &home.0).unwrap();
        let selected = resolver.resolve(Some(stack)).unwrap();
        // No cache yet: the launch asks the stack, whose client-config names its own mobile Worker
        // and device hub (never the development table's, which the tag's iPhone build does not use).
        assert!(without_fetch(&resolver, selected.clone()).is_none());
        // Once fetched, every later launch reads the stack's services from the cache, no network.
        let mut served = config(stack);
        served.configuration.mobile_origin =
            "https://cmux-dev-backend-1.tail137216.ts.net:3851".into();
        served.configuration.device_hub_origin =
            "https://cmux-dev-backend-1.tail137216.ts.net:3852".into();
        let path = cache_path(&resolver, stack).unwrap();
        atomic_cache(&path, &serde_json::to_vec(&served).unwrap()).unwrap();
        let launch = without_fetch(&resolver, selected.clone()).expect("cached: no fetch");
        assert_eq!(launch.config_source, ConfigSource::Cache);
        assert_eq!(launch.mobile_origin, served.configuration.mobile_origin);
        assert_eq!(launch.device_hub_origin, served.configuration.device_hub_origin);
        // A stack that never answered and left no cache: the development services, as before.
        fs::remove_file(&path).unwrap();
        let fallback = cached_or_fallback(selected, &path, stack).unwrap();
        assert_eq!(fallback.platform_origin, crate::DEVELOPMENT_PLATFORM);
    }

    #[tokio::test]
    async fn cache_first_reads_the_cache_or_a_known_deployment_without_the_network() {
        // A backend that takes the connection and never answers: any fetch waits out its timeout.
        let silent = TcpListener::bind("127.0.0.1:0").unwrap();
        let origin = format!("http://{}", silent.local_addr().unwrap());
        let home = Home::new();
        let resolver = Resolver::new(crate::DEV_BUNDLE, &home.0).unwrap();
        let selected = resolver.resolve(Some(&origin)).unwrap();
        let body = serde_json::to_vec(&config(&origin)).unwrap();
        atomic_cache(&cache_path(&resolver, &origin).unwrap(), &body).unwrap();
        let started = std::time::Instant::now();
        let cached = resolver.client_config_cache_first(selected).await.unwrap();
        assert_eq!(cached.config_source, ConfigSource::Cache);
        assert!(started.elapsed() < Duration::from_secs(1), "{:?}", started.elapsed());
        drop(silent);

        // A known deployment with no cache takes its built-in configuration, still without a fetch.
        let known = resolver
            .client_config_cache_first(resolver.resolve(Some("staging")).unwrap())
            .await
            .unwrap();
        assert_eq!(known.config_source, ConfigSource::KnownOriginFallback);

        // A custom origin with no cache is fetched.
        let (origin, server) =
            serve(|origin| http_json(&serde_json::to_string(&config(origin)).unwrap()));
        let fetched = resolver
            .client_config_cache_first(resolver.resolve(Some(&origin)).unwrap())
            .await
            .unwrap();
        server.join().unwrap();
        assert_eq!(fetched.config_source, ConfigSource::Backend);
    }

    #[test]
    fn an_older_fetch_never_replaces_a_newer_fetchs_cache() {
        let home = Home::new();
        let path = home.0.join("client-config").join("origin.json");
        assert!(fenced_cache(&path, b"second", 20).unwrap());
        // The first fetch's answer lands after the second's: it is not written.
        assert!(!fenced_cache(&path, b"first", 10).unwrap());
        assert_eq!(fs::read(&path).unwrap(), b"second");
        // A fetch that started later still replaces it.
        assert!(fenced_cache(&path, b"third", 30).unwrap());
        assert_eq!(fs::read(&path).unwrap(), b"third");
    }

    #[tokio::test]
    async fn malformed_success_never_becomes_fallback() {
        let (origin, server) = serve(|_| http_json("{bad"));
        let home = Home::new();
        let resolver = Resolver::new(crate::DEV_BUNDLE, &home.0).unwrap();
        let error =
            resolver.client_config(resolver.resolve(Some(&origin)).unwrap()).await.unwrap_err();
        server.join().unwrap();
        assert!(error.contains("invalid client-config"), "{error}");
    }

    #[tokio::test]
    async fn redirect_is_refused_without_following() {
        let (origin, server) = serve(|_| {
            "HTTP/1.1 302 Found\r\nLocation: http://127.0.0.1:1/should-not-request\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".into()
        });
        let home = Home::new();
        let resolver = Resolver::new(crate::DEV_BUNDLE, &home.0).unwrap();
        let error =
            resolver.client_config(resolver.resolve(Some(&origin)).unwrap()).await.unwrap_err();
        server.join().unwrap();
        assert!(error.contains("redirect refused"), "{error}");
    }
}
