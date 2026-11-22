//! Actual native owners, acpmux's Unix server and a loopback registry.
//! Registry sources are injected through the existing in-process owner seam;
//! the shipped daemon gains no caller-selected URL or test-only command.
#![cfg(unix)]

#[path = "../../acpmux/tests/support/daemon_env.rs"]
mod daemon_env;
mod journey_support;
const HERMETIC: daemon_env::Process = daemon_env::Process::deny();

use std::fs;
use std::io::{BufRead, BufReader, Write};
use std::os::unix::fs::PermissionsExt;
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use acpmux::config::{Config, ProfileSources, StoreMode};
use acpmux::harness_health::{Settings, latest::Sources};
use acpmux::hub::Hub;
use journey_support::Machine;
use serde_json::{Value, json};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt};
use tokio::net::TcpListener;
use tokio::task::JoinHandle;

fn native(root: &Path, name: &str, acpmux: &Path) -> Machine {
    let dir = root.join(name);
    fs::create_dir_all(dir.join("home")).unwrap();
    fs::create_dir_all(dir.join("acpmux")).unwrap();
    fs::write(dir.join("acpmux/config.json"), "{\"harnesses\":{}}").unwrap();
    let machine = Machine {
        socket: dir.join("mux.sock"),
        session: format!("inventory-refresh-{name}"),
        dir,
        env: vec![
            ("ACPMUX_SOCKET", acpmux.to_string_lossy().into_owned()),
            ("ACPMUX_CATALOG_FETCH", "0".into()),
            ("ACPMUX_HEALTH_FETCH", "0".into()),
            ("ACPMUX_REGISTRY_FETCH", "0".into()),
            ("ACPMUX_PROBE_HARNESSES", "".into()),
            ("CMUX_APPS_DEFAULT", "".into()),
        ],
    };
    let ensured = machine.server("ensure").output().unwrap();
    assert!(ensured.status.success(), "ensure: {}", String::from_utf8_lossy(&ensured.stderr));
    machine
}

fn owner(machine: &Machine) -> Value {
    let identity = machine.rpc(json!({"id":1,"cmd":"identify","machine_metadata":true}));
    assert_eq!(identity["ok"], true, "{identity}");
    assert!(
        identity["data"]["capabilities"]
            .as_array()
            .unwrap()
            .contains(&json!("agent-inventory-refresh-v1"))
    );
    let id = identity["data"]["machine_id"].clone();
    assert!(id.as_str().is_some_and(|id| id.starts_with("machine_") && id.len() == 40));
    id
}

fn reply(reader: &mut BufReader<UnixStream>) -> Value {
    loop {
        let mut line = String::new();
        assert_ne!(reader.read_line(&mut line).unwrap(), 0, "native owner closed");
        let value: Value = serde_json::from_str(&line).unwrap();
        if value.get("event").is_none() {
            return value;
        }
    }
}

struct Registry {
    url: String,
    good: Arc<AtomicBool>,
    asked: Arc<Mutex<Vec<String>>>,
    task: JoinHandle<()>,
}

impl Registry {
    async fn start() -> Self {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let url = format!("http://{}", listener.local_addr().unwrap());
        let good = Arc::new(AtomicBool::new(true));
        let asked = Arc::new(Mutex::new(Vec::new()));
        let answers = good.clone();
        let requests = asked.clone();
        let task = tokio::spawn(async move {
            loop {
                let (socket, _) = listener.accept().await.unwrap();
                let mut socket = tokio::io::BufReader::new(socket);
                let mut first = String::new();
                socket.read_line(&mut first).await.unwrap();
                requests.lock().unwrap().push(first.trim().to_owned());
                let mut total = first.len();
                loop {
                    let mut header = String::new();
                    let read = socket.read_line(&mut header).await.unwrap();
                    total += read;
                    assert!(total <= 8192);
                    if read == 0 || header == "\r\n" {
                        break;
                    }
                }
                let (status, body) = if answers.load(Ordering::SeqCst) {
                    ("200 OK", r#"{"version":"2.0.9"}"#)
                } else {
                    ("503 Unavailable", "{}")
                };
                let response = format!(
                    "HTTP/1.1 {status}\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
                    body.len()
                );
                socket.get_mut().write_all(response.as_bytes()).await.unwrap();
                socket.get_mut().shutdown().await.unwrap();
            }
        });
        Self { url, good, asked, task }
    }
}

impl Drop for Registry {
    fn drop(&mut self) {
        self.task.abort();
    }
}

struct AcpmuxOwner {
    socket: PathBuf,
    task: JoinHandle<anyhow::Result<()>>,
}

impl AcpmuxOwner {
    async fn start(root: &Path, registry: &Registry) -> Self {
        let config = root.join("hub.json");
        fs::write(&config, "{\"harnesses\":{}}").unwrap();
        let mut config = Config::load_from_with(&config, &ProfileSources::none()).unwrap();
        config.store.mode = StoreMode::Memory;
        let store = acpmux::store::open(&config.store, root).unwrap();
        // The cmux-tui binary installs acpmux's build id at start (main.rs); so
        // does this in-process hub, or it reports `unstamped`.
        acpmux::hub::install_build(acpmux_build_id::build());
        let hub = Hub::new(config, store);
        let program = root.join("claude");
        fs::write(
            &program,
            format!("#!/bin/sh\necho ran >> '{}'\necho 9.9.9\n", root.join("cli-ran").display()),
        )
        .unwrap();
        fs::set_permissions(&program, fs::Permissions::from_mode(0o755)).unwrap();
        let cache = root.join("health.json");
        fs::write(
            &cache,
            json!([{
                "id":"claude", "program":program, "path":program, "channel":"native",
                "package":"@anthropic-ai/claude-code", "version":"2.0.5", "latest":"2.0.6",
                "latestCheckedAt":1, "outdated":true, "auth":"unknown", "checkedAt":1,
                "authDetail":"private@example.test secret-token",
            }])
            .to_string(),
        )
        .unwrap();
        hub.health.attach(Settings {
            cache: Some(cache),
            home: root.join("home"),
            sources: Some(Sources {
                npm: format!("{}/npm", registry.url),
                brew: format!("{}/brew", registry.url),
            }),
            ..Settings::default()
        });
        let socket = root.join("acp.sock");
        let listener = acpmux::server::bind_unix(&socket).await.unwrap();
        let task = tokio::spawn(acpmux::server::serve_unix(hub, listener));
        Self { socket, task }
    }
}

impl Drop for AcpmuxOwner {
    fn drop(&mut self) {
        self.task.abort();
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn cmux_next_inventory_refresh_journey_registry_and_watch_stay_on_selected_owner() {
    let scratch = tempfile::Builder::new().prefix("cn-ir-").tempdir_in("/tmp").unwrap();
    let root = scratch.path().canonicalize().unwrap();
    let registry = Registry::start().await;
    let acp = AcpmuxOwner::start(&root, &registry).await;
    let selected = native(&root, "server", &acp.socket);
    let other = native(&root, "other", &root.join("absent.sock"));
    let machine = owner(&selected);
    assert_ne!(machine, owner(&other));

    let cached =
        selected.rpc(json!({"id":2,"cmd":"agent-inventory","expected_machine_id":machine}));
    assert_eq!(cached["data"]["harnesses"][0]["latest"], "2.0.6", "{cached}");
    let foreign =
        other.rpc(json!({"id":3,"cmd":"agent-inventory-refresh","expected_machine_id":machine}));
    assert_eq!(foreign["error_code"], "agent_inventory.owner_mismatch", "{foreign}");
    assert!(registry.asked.lock().unwrap().is_empty());

    let stream = UnixStream::connect(&selected.socket).unwrap();
    stream.set_read_timeout(Some(Duration::from_secs(10))).unwrap();
    let mut watch = BufReader::new(stream);
    writeln!(
        watch.get_mut(),
        "{}",
        json!({"id":4,"cmd":"agent-inventory-watch","expected_machine_id":machine,"enabled":true})
    )
    .unwrap();
    let admitted = reply(&mut watch);
    assert_eq!(admitted["ok"], true, "{admitted}");
    assert_eq!(admitted["data"]["machine"], machine);

    let refreshed =
        selected.rpc(json!({"id":5,"cmd":"agent-inventory-refresh","expected_machine_id":machine}));
    assert_eq!(refreshed["ok"], true, "{refreshed}");
    assert_eq!(refreshed["data"]["machine"], machine);
    assert_eq!(refreshed["data"]["cached"], true);
    let row = &refreshed["data"]["harnesses"][0];
    assert_eq!(row["latest"], "2.0.9");
    assert!(row["latestCheckedAt"].as_u64().is_some_and(|at| at > 1));
    assert_eq!(row["version"], "2.0.5");
    assert_eq!(row["checkedAt"], 1);
    let mut event = String::new();
    watch.read_line(&mut event).unwrap();
    let event: Value = serde_json::from_str(&event).unwrap();
    assert_eq!(event["event"], "agent-inventory-changed", "{event}");
    assert_eq!(event["machine"], machine);
    assert!(
        event["revision"].as_u64().expect("event revision")
            > admitted["data"]["revision"].as_u64().expect("admitted revision")
    );

    registry.good.store(false, Ordering::SeqCst);
    let older =
        selected.rpc(json!({"id":6,"cmd":"agent-inventory-refresh","expected_machine_id":machine}));
    assert_eq!(older["data"], refreshed["data"], "registry failure must retain older evidence");
    let after = selected.rpc(json!({"id":7,"cmd":"agent-inventory","expected_machine_id":machine}));
    assert_eq!(after["data"]["harnesses"], refreshed["data"]["harnesses"]);
    assert_eq!(
        registry.asked.lock().unwrap().as_slice(),
        [
            "GET /npm/@anthropic-ai%2Fclaude-code/latest HTTP/1.1",
            "GET /npm/@anthropic-ai%2Fclaude-code/latest HTTP/1.1",
        ]
    );
    for secret in ["private@example.test", "secret-token", "program", "path"] {
        assert!(!refreshed.to_string().contains(secret), "{refreshed}");
    }
    assert!(!root.join("cli-ran").exists(), "a CLI/auth probe or updater ran");
    drop(watch);
}
