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
    let named = check_create_capabilities(&selection, &serde_json::json!({"size_name": "large"}))
        .unwrap_err();
    assert!(named.contains("machine_create.size_name"));
    let refused =
        check_create_capabilities(&selection, &serde_json::json!({"bootstrap": "x"})).unwrap_err();
    assert!(refused.contains("backend capability refused: machine_create.bootstrap"));
    let missing = check_create_capabilities(&selection, &serde_json::json!({"size_name": "large"}))
        .unwrap_err();
    assert!(
        missing.contains("backend capability not declared/unavailable: machine_create.size_name")
    );
    selection.capabilities["machine_create"]["size_name"] = serde_json::json!(true);
    check_create_capabilities(&selection, &serde_json::json!({"size_name": "large"})).unwrap();
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
    let fetched =
        resolver.client_config_cache_first(resolver.resolve(Some(&origin)).unwrap()).await.unwrap();
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
    let error = resolver.client_config(resolver.resolve(Some(&origin)).unwrap()).await.unwrap_err();
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
    let error = resolver.client_config(resolver.resolve(Some(&origin)).unwrap()).await.unwrap_err();
    server.join().unwrap();
    assert!(error.contains("redirect refused"), "{error}");
}
