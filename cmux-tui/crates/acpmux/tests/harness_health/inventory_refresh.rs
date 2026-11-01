//! Explicit registry refresh is a read of cached installation evidence,
//! never a health probe, catalog rescan, login or automatic update.

use super::*;

const REFRESH: &str = "_acpmux/harness/inventory/refresh";

struct Fixture {
    root: PathBuf,
    hub: Arc<Hub>,
    asked: Arc<Mutex<Vec<String>>>,
    ran: PathBuf,
}

impl Fixture {
    fn new(name: &str, populated: bool, registry: bool) -> Self {
        let root = scratch(name);
        let home = root.join("home");
        let user = root.join("profiles");
        let real = home.join(".local/share/claude/versions/current");
        let cli = home.join(".local/bin/claude");
        let ran = root.join("cli-was-run");
        program(&real, &cli, "9.9.9 (Claude Code)");
        std::fs::write(
            &real,
            format!("#!/bin/sh\necho ran >> '{}'\necho '9.9.9 (Claude Code)'\n", ran.display()),
        )
        .unwrap();
        profile(
            &user,
            "claude",
            &format!("protocol = \"claude-stdio\"\ncommand = \"{}\"\n", cli.display()),
        );
        let row = json!({
            "id":"claude", "program":cli, "path":real, "channel":"native",
            "package":"@anthropic-ai/claude-code", "version":"2.0.5", "latest":"2.0.6",
            "latestCheckedAt":1, "outdated":true, "auth":"unknown", "checkedAt":1,
            "authDetail":"private@example.test secret-token", "autoUpdate":true,
            "update":{"argv":[cli,"update"],"command":"private update command","elevated":false}
        });
        let cache = root.join("health.json");
        let rows = if populated { json!([row]) } else { json!([]) };
        std::fs::write(&cache, rows.to_string()).unwrap();
        let preference = root.join("auto-update.json");
        std::fs::write(&preference, "[\"claude\"]").unwrap();
        let answers = if registry {
            vec![("/npm/@anthropic-ai%2Fclaude-code/latest", json!({"version":"2.0.9"}))]
        } else {
            vec![]
        };
        let (port, asked) = latest_server(answers);
        let hub = hub_for(&root, &user, &home);
        hub.health.attach(Settings {
            sources: Some(Sources {
                npm: format!("http://127.0.0.1:{port}/npm"),
                brew: format!("http://127.0.0.1:{port}/brew"),
            }),
            cache: Some(cache),
            home,
            auto_update: Some(preference),
            ..Settings::default()
        });
        Self { root, hub, asked, ran }
    }

    fn assert_no_program(&self) {
        assert!(!self.ran.exists(), "inventory refresh ran a CLI, auth check or updater");
    }

    fn use_registry(&self, port: u16) {
        self.hub.health.attach(Settings {
            sources: Some(Sources {
                npm: format!("http://127.0.0.1:{port}/npm"),
                brew: format!("http://127.0.0.1:{port}/brew"),
            }),
            cache: Some(self.root.join("health.json")),
            home: self.root.join("home"),
            auto_update: Some(self.root.join("auto-update.json")),
            ..Settings::default()
        });
    }
}

impl Drop for Fixture {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.root);
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn cmux_next_harness_inventory_refresh_changes_only_registry_observations() {
    let f = Fixture::new("inventory-refresh-registry", true, true);
    let mut client = Client::open(&f.hub, Origin::Local);
    let refreshed = client.call(REFRESH, json!({})).await.expect("explicit registry refresh");
    assert_eq!(refreshed["view"], "inventory", "{refreshed}");
    assert_eq!(refreshed["cached"], true, "installation/auth evidence remains cached");
    let observed = row(&refreshed, "claude");
    assert_eq!(observed["version"], "2.0.5", "installed version must not be probed again");
    assert_eq!(observed["checkedAt"], 1, "installed/auth observation time stays unchanged");
    assert_eq!(observed["latest"], "2.0.9");
    assert!(observed["latestCheckedAt"].as_u64().is_some_and(|at| at > 1));
    assert_eq!(observed["outdated"], true);
    assert_eq!(observed["auth"], "unknown");
    let text = refreshed.to_string();
    for private in ["private@example.test", "secret-token", "argv", "command", "path"] {
        assert!(!text.contains(private), "private health diagnostics escaped: {refreshed}");
    }
    let cached =
        client.call(method::MUX_HARNESS_HEALTH, json!({"view":"inventory"})).await.unwrap();
    assert_eq!(cached, refreshed, "the owner commits the refreshed cache before replying");
    assert_eq!(f.asked.lock().unwrap().len(), 1);
    let health = &f.hub.health.rows()[0];
    assert!(health.auto_update, "the refresh must not turn off the user's auto-update choice");
    f.assert_no_program();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn cmux_next_harness_inventory_refresh_empty_cache_does_not_discover_or_probe() {
    let f = Fixture::new("inventory-refresh-empty", false, true);
    let mut client = Client::open(&f.hub, Origin::Local);
    let refreshed = client.call(REFRESH, json!({})).await.expect("empty cached inventory");
    assert_eq!(refreshed, json!({"view":"inventory","cached":true,"harnesses":[]}));
    assert!(f.asked.lock().unwrap().is_empty());
    f.assert_no_program();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn cmux_next_harness_inventory_refresh_rejects_controls_and_selectors() {
    let f = Fixture::new("inventory-refresh-params", true, true);
    let mut client = Client::open(&f.hub, Origin::Local);
    for params in [
        Value::Null,
        json!([]),
        json!(false),
        json!(42),
        json!({"view":"inventory"}),
        json!({"checkLatest":true}),
        json!({"autoUpdate":{"id":"claude","on":false}}),
        json!({"sessionId":"foreign/session"}),
        json!({"command":"echo should-not-run"}),
    ] {
        let error = client.call(REFRESH, params).await.expect_err("strict empty params");
        assert_eq!(error["code"], -32602, "{error}");
    }
    assert!(f.asked.lock().unwrap().is_empty());
    f.assert_no_program();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn cmux_next_harness_inventory_refresh_requires_the_local_socket() {
    let f = Fixture::new("inventory-refresh-origins", true, true);
    for origin in [Origin::LocalApp, Origin::Web, Origin::Peer] {
        let mut client = Client::open(&f.hub, origin);
        let error = client.call(REFRESH, json!({})).await.expect_err("local socket only");
        assert_eq!(error["code"], -32602, "{error}");
    }
    assert!(f.asked.lock().unwrap().is_empty());
    f.assert_no_program();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn cmux_next_harness_inventory_refresh_is_negotiated_before_use() {
    let f = Fixture::new("inventory-refresh-capability", true, true);
    let mut client = Client::open(&f.hub, Origin::Local);
    let initialized = client.call(method::INITIALIZE, json!({"protocolVersion":1})).await.unwrap();
    assert!(
        initialized
            .pointer("/_meta/acpmux/extensions")
            .unwrap()
            .as_array()
            .unwrap()
            .contains(&json!(REFRESH)),
        "{initialized}"
    );
    assert!(
        initialized
            .pointer("/_meta/acpmux/features")
            .unwrap()
            .as_array()
            .unwrap()
            .contains(&json!("harnessInventoryRefresh")),
        "{initialized}"
    );
    f.assert_no_program();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn cmux_next_harness_inventory_refresh_failed_registry_keeps_prior_evidence() {
    let f = Fixture::new("inventory-refresh-offline", true, false);
    let mut client = Client::open(&f.hub, Origin::Local);
    let refreshed = client.call(REFRESH, json!({})).await.expect("partial cached evidence");
    let observed = row(&refreshed, "claude");
    assert_eq!(observed["latest"], "2.0.6");
    assert_eq!(observed["latestCheckedAt"], 1, "a failed read cannot stamp old evidence fresh");
    assert_eq!(observed["checkedAt"], 1);
    assert_eq!(f.asked.lock().unwrap().len(), 1);
    f.assert_no_program();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn cmux_next_harness_inventory_refresh_ordinary_cache_reads_still_do_no_work() {
    let f = Fixture::new("inventory-refresh-cache-control", true, true);
    let mut client = Client::open(&f.hub, Origin::Local);
    let cached =
        client.call(method::MUX_HARNESS_HEALTH, json!({"view":"inventory"})).await.unwrap();
    assert_eq!(row(&cached, "claude")["latest"], "2.0.6");
    assert_eq!(row(&cached, "claude")["checkedAt"], 1);
    assert!(f.asked.lock().unwrap().is_empty());
    f.assert_no_program();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn cmux_next_harness_inventory_refresh_refuses_overlap_and_preserves_a_live_choice() {
    let f = Fixture::new("inventory-refresh-overlap", true, true);
    let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    f.use_registry(listener.local_addr().unwrap().port());
    let (entered, waiting) = tokio::sync::oneshot::channel();
    let (release, held) = std::sync::mpsc::channel();
    let server = std::thread::spawn(move || {
        let (mut socket, _) = listener.accept().unwrap();
        let mut reader = BufReader::new(socket.try_clone().unwrap());
        let mut line = String::new();
        loop {
            reader.read_line(&mut line).unwrap();
            if line.trim().is_empty() {
                break;
            }
            line.clear();
        }
        let _ = entered.send(());
        if held.recv().is_err() {
            return;
        }
        let body = r#"{"version":"2.0.9"}"#;
        write!(
            socket,
            "HTTP/1.1 200 OK\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
            body.len()
        )
        .unwrap();
    });
    let mut first = Client::open(&f.hub, Origin::Local);
    let pending = tokio::spawn(async move { first.call(REFRESH, json!({})).await });
    tokio::time::timeout(Duration::from_secs(2), waiting).await.unwrap().unwrap();
    // A preference has its own writer and may change while the network waits.
    f.hub.health.set_auto_update("claude", false).unwrap();
    let mut second = Client::open(&f.hub, Origin::Local);
    let error = tokio::time::timeout(Duration::from_secs(2), second.call(REFRESH, json!({})))
        .await
        .expect("a concurrent refresh must refuse immediately, never queue")
        .expect_err("only one registry refresh/check may run");
    assert_eq!(error["data"]["reason"], "harness_inventory.busy", "{error}");
    release.send(()).unwrap();
    let refreshed = pending.await.unwrap().unwrap();
    assert_eq!(row(&refreshed, "claude")["latest"], "2.0.9");
    assert!(!f.hub.health.rows()[0].auto_update, "the old row clone overwrote the live choice");
    f.assert_no_program();
    server.join().unwrap();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn cmux_next_harness_inventory_refresh_invalid_versions_do_not_replace_known_evidence() {
    for (index, invalid) in [
        "not-a-version".to_owned(),
        format!("1.2.3-{}", "a".repeat(65)),
        "1.2.3-💥".to_owned(),
        "18446744073709551616.0.0".to_owned(),
    ]
    .into_iter()
    .enumerate()
    {
        let f = Fixture::new(&format!("inventory-refresh-invalid-{index}"), true, true);
        let (port, asked) = latest_server(vec![(
            "/npm/@anthropic-ai%2Fclaude-code/latest",
            json!({"version":invalid}),
        )]);
        f.use_registry(port);
        let mut client = Client::open(&f.hub, Origin::Local);
        let refreshed = client.call(REFRESH, json!({})).await.unwrap();
        assert_eq!(row(&refreshed, "claude")["latest"], "2.0.6");
        assert_eq!(row(&refreshed, "claude")["latestCheckedAt"], 1);
        assert_eq!(asked.lock().unwrap().len(), 1);
        f.assert_no_program();
    }
}
