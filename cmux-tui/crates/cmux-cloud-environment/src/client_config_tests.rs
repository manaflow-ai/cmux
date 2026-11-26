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
fn a_mac_applied_field_reads_the_backends_create_block() {
    // Production since cmux-platform #1703: the op takes none of these (`machine_create` false), and the
    // backend lets the Mac apply them (`create` true). A repo create's bootstrap must pass.
    let home = Home::new();
    let resolver = Resolver::new(crate::DEV_BUNDLE, &home.0).unwrap();
    let mut selection = resolver.resolve(Some("dev")).unwrap();
    selection.capabilities = serde_json::json!({
        "machine_create": {"size_name": false, "idle_seconds": false, "name": true, "bootstrap": false,
                           "machine_config_base64": false},
        "create": {"size": true, "idlePause": true, "name": true, "bootstrap": true}
    });
    let mac_applied =
        serde_json::json!({"bootstrap": {"kind": "shell"}, "idle_seconds": 0, "size_name": "md"});
    check_create_capabilities(&selection, &mac_applied).unwrap();
    // A field the backend's create block does not name still reads machine_create.
    let config =
        check_create_capabilities(&selection, &serde_json::json!({"machine_config_base64": "x"}))
            .unwrap_err();
    assert!(config.contains("backend capability refused: machine_create.machine_config_base64"));
    // A backend that does not let the Mac apply it refuses by its create block's name.
    selection.capabilities["create"]["bootstrap"] = serde_json::json!(false);
    let refused =
        check_create_capabilities(&selection, &serde_json::json!({"bootstrap": "x"})).unwrap_err();
    assert!(refused.contains("backend capability refused: create.bootstrap"));
}

#[test]
fn a_named_size_sent_as_its_size_object_needs_no_capability_of_its_own() {
    // 2026-11-25 on air-blue: `cmux vm new --size small` (vm --help's Quick Start) refused
    // "backend capability refused: machine_create.size_name". The Mac sends the size as the `size`
    // object the op always takes, so the name alone is no reason to refuse it.
    let home = Home::new();
    let resolver = Resolver::new(crate::DEV_BUNDLE, &home.0).unwrap();
    let mut selection = resolver.resolve(Some("dev")).unwrap();
    let sized = serde_json::json!({
        "size": {"cpu": 2, "memory_mb": 4096, "disk_mb": 16384}, "size_name": "small",
    });
    let configs = [
        // A cache from before the backend's create block.
        serde_json::json!({"machine_create": {"size_name": false, "name": true}}),
        // The known-origin fallback.
        serde_json::json!({"machine_create": {"size": true, "name": true}}),
        // No capabilities at all.
        serde_json::json!({}),
        // Production today.
        serde_json::json!({
            "machine_create": {"size_name": false, "idle_seconds": false, "name": true},
            "create": {"size": true, "idlePause": true, "name": true, "bootstrap": true}
        }),
    ];
    for capabilities in configs {
        selection.capabilities = capabilities.clone();
        check_create_capabilities(&selection, &sized)
            .unwrap_or_else(|error| panic!("{capabilities}: {error}"));
        // The name with no size object still needs the backend's word.
        if capabilities.get("create").is_none() {
            let named =
                check_create_capabilities(&selection, &serde_json::json!({"size_name": "small"}))
                    .unwrap_err();
            assert!(named.contains("machine_create.size_name"), "{capabilities}: {named}");
        }
    }
    // A size that is not an object is no size sent.
    selection.capabilities = serde_json::json!({"machine_create": {"size_name": false}});
    let odd = check_create_capabilities(
        &selection,
        &serde_json::json!({"size": "small", "size_name": "small"}),
    )
    .unwrap_err();
    assert!(odd.contains("backend capability refused: machine_create.size_name"), "{odd}");
    // A backend that says no to a named size still refuses it, size object or not.
    selection.capabilities = serde_json::json!({"create": {"size": false}});
    let refused = check_create_capabilities(&selection, &sized).unwrap_err();
    assert!(refused.contains("backend capability refused: create.size"), "{refused}");
    // Another advanced field next to the size is still checked.
    selection.capabilities = serde_json::json!({"machine_create": {"bootstrap": false}});
    let mut both = sized.clone();
    both["bootstrap"] = serde_json::json!("x");
    let refused = check_create_capabilities(&selection, &both).unwrap_err();
    assert!(refused.contains("machine_create.bootstrap"), "{refused}");
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
    own.configuration.platform_origin = "https://cmux-dev-backend-1.tail137216.ts.net:3851".into();
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
fn a_tailnet_launch_fetches_the_stacks_own_services_once_and_an_outage_never_uses_dev() {
    let stack = "https://cmux-dev-backend-1.tail137216.ts.net:3850";
    let home = Home::new();
    let resolver = Resolver::new("com.cmuxterm.app.debug.cnx-tag", &home.0).unwrap();
    let selected = resolver.resolve(Some(stack)).unwrap();
    // No cache yet: the launch asks the stack, whose client-config names its own mobile Worker
    // and device hub (never the development table's, which the tag's iPhone build does not use).
    assert!(without_fetch(&resolver, selected.clone()).is_none());
    // Once fetched, every later launch reads the stack's services from the cache, no network.
    let mut served = config(stack);
    served.configuration.mobile_origin = "https://cmux-dev-backend-1.tail137216.ts.net:3851".into();
    served.configuration.device_hub_origin =
        "https://cmux-dev-backend-1.tail137216.ts.net:3852".into();
    let path = cache_path(&resolver, stack).unwrap();
    atomic_cache(&path, &serde_json::to_vec(&served).unwrap()).unwrap();
    let launch = without_fetch(&resolver, selected.clone()).expect("cached: no fetch");
    assert_eq!(launch.config_source, ConfigSource::Cache);
    assert_eq!(launch.mobile_origin, served.configuration.mobile_origin);
    assert_eq!(launch.device_hub_origin, served.configuration.device_hub_origin);
    // A stack that never answered and left no cache fails closed: the development table would
    // put the Mac on the shared mobile Worker, where the tag's iPhone never finds it.
    fs::remove_file(&path).unwrap();
    let error = cached_or_fallback(selected, &path, stack).unwrap_err();
    assert!(error.contains("no cache"), "{error}");
    // Its public origin too.
    let public = "https://api.s7.wdev.cmux.dev";
    let selected = resolver.resolve(Some(public)).unwrap();
    let path = cache_path(&resolver, public).unwrap();
    assert!(cached_or_fallback(selected, &path, public).is_err());
}

/// The egress gate (enforced for a DEV app's Rust children) passes a tag stack's tailnet origin:
/// refused, the launch's client-config fetch failed and the Mac app ran on the development table.
#[test]
fn the_egress_gate_passes_a_tailnet_stack() {
    for origin in
        ["https://cmux-dev-backend-1.tail137216.ts.net:4693", "https://api.s7.wdev.cmux.dev"]
    {
        assert_ne!(cmux_egress::verdict(origin), cmux_egress::Verdict::Unlisted, "{origin}");
    }
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
