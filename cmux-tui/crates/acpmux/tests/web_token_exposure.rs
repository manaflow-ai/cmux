//! The WebSocket token never reaches a remote-origin (Web) connection, and a
//! saved token from a build that sent it there is rotated once.
#![cfg(unix)]

use acpmux::config::{Config, PeerConfig, StoreMode, WebSocketConfig};
use acpmux::hub::Hub;
use acpmux::rpc::{Message, method};
use acpmux::server::{Origin, serve_connection_with};
use serde_json::{Value, json};
use std::io::{BufRead, BufReader};
use std::process::{Command, Stdio};
use std::time::Duration;
use tokio::sync::mpsc;

const TOKEN: &str = "saved-listener-token-0123456789";
const PEER_TOKEN: &str = "peer-secret-token-9876543210";

async fn client(origin: Origin) -> (mpsc::Sender<String>, mpsc::Receiver<String>) {
    let mut cfg = Config {
        websocket: Some(WebSocketConfig {
            listen: "127.0.0.1:1".into(),
            token: Some(TOKEN.into()),
            allowed_origins: Vec::new(),
            allowed_hosts: Vec::new(),
        }),
        ..Default::default()
    };
    // A peer whose URL a user wrote with its token in the query.
    cfg.peers.insert(
        "p".into(),
        PeerConfig { url: format!("ws://127.0.0.1:1/?token={PEER_TOKEN}"), token: None },
    );
    cfg.store.mode = StoreMode::Memory;
    let store = acpmux::store::open(&cfg.store, std::path::Path::new("/nonexistent")).unwrap();
    let hub = Hub::new(cfg, store);
    let (in_tx, in_rx) = mpsc::channel(64);
    let (out_tx, out_rx) = mpsc::channel(4096);
    tokio::spawn(serve_connection_with(hub, in_rx, out_tx, origin));
    (in_tx, out_rx)
}

async fn call(c: &mut (mpsc::Sender<String>, mpsc::Receiver<String>), id: i64, m: &str) -> String {
    c.0.send(Message::request(id, m, json!({})).to_line()).await.unwrap();
    loop {
        let line = tokio::time::timeout(Duration::from_secs(10), c.1.recv()).await.unwrap().unwrap();
        if let Message::Response { id: rid, .. } = Message::parse(&line).unwrap()
            && rid == json!(id)
        {
            return line;
        }
    }
}

#[tokio::test]
async fn a_web_connection_never_gets_the_token_or_the_web_url() {
    let mut web = client(Origin::Web).await;
    for (id, m) in [(1, method::INITIALIZE), (2, method::MUX_STATUS), (3, "_acpmux/peers")] {
        let reply = call(&mut web, id, m).await;
        assert!(!reply.contains(TOKEN), "{m} sent the listener token to a Web connection: {reply}");
        assert!(!reply.contains(PEER_TOKEN), "{m} sent a peer's token to a Web connection: {reply}");
        assert!(!reply.contains("webUrl"), "{m} sent webUrl to a Web connection: {reply}");
    }
    // The local socket still gets the dashboard link (`acpmux web`, the app).
    let mut local = client(Origin::Local).await;
    let status = call(&mut local, 1, method::MUX_STATUS).await;
    assert!(status.contains(&format!("token={TOKEN}")), "{status}");
}

/// A daemon this test started; killed if the test ends early.
struct Daemon(Option<std::process::Child>);

impl Drop for Daemon {
    fn drop(&mut self) {
        if let Some(mut child) = self.0.take() {
            let _ = child.kill();
            let _ = child.wait();
        }
    }
}

fn start(home: &std::path::Path, extra: &[&str]) -> (Daemon, Value) {
    let mut child = Command::new(env!("CARGO_BIN_EXE_acpmux"))
        .args(["daemon", "run", "--memory", "--listen", "127.0.0.1:0", "--ready-fd", "1", "--log", "error"])
        .args(extra)
        .env("ACPMUX_HOME", home)
        .env("ACPMUX_SOCKET", home.join("s.sock"))
        .env_remove("ACPMUX_LOGIN_ENV")
        .env_remove("XPC_SERVICE_NAME")
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::inherit())
        .spawn()
        .unwrap();
    let stdout = child.stdout.take().unwrap();
    let daemon = Daemon(Some(child));
    // A daemon that never gets ready fails the test instead of hanging it.
    let (tx, rx) = std::sync::mpsc::channel();
    std::thread::spawn(move || {
        let mut ready = String::new();
        let _ = BufReader::new(stdout).read_line(&mut ready);
        let _ = tx.send(ready);
    });
    let ready = rx.recv_timeout(Duration::from_secs(20)).expect("daemon ready within 20 s");
    let value = serde_json::from_str(&ready).unwrap_or_else(|_| panic!("ready line: {ready:?}"));
    (daemon, value)
}

fn stop(mut daemon: Daemon) {
    let mut child = daemon.0.take().unwrap();
    // SAFETY: this test's own child.
    unsafe { libc::kill(child.id() as i32, libc::SIGTERM) };
    let deadline = std::time::Instant::now() + Duration::from_secs(20);
    while child.try_wait().unwrap().is_none() {
        assert!(std::time::Instant::now() < deadline, "daemon did not stop on SIGTERM");
        std::thread::sleep(Duration::from_millis(50));
    }
}

fn url_token(ready: &Value) -> String {
    let url = ready["webUrl"].as_str().unwrap();
    url.split("token=").nth(1).unwrap().to_owned()
}

fn saved(home: &std::path::Path) -> Value {
    serde_json::from_slice(&std::fs::read(home.join("config.json")).unwrap()).unwrap()
}

#[test]
fn a_saved_token_from_before_the_fix_rotates_once() {
    use std::os::unix::fs::PermissionsExt;
    let home = std::env::temp_dir().join(format!("atr-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&home);
    std::fs::create_dir_all(&home).unwrap();
    std::fs::write(
        home.join("config.json"),
        json!({"websocket": {"listen": "127.0.0.1:0", "token": TOKEN}}).to_string(),
    )
    .unwrap();
    let (child, ready) = start(&home, &[]);
    stop(child);
    let rotated = url_token(&ready);
    assert_ne!(rotated, TOKEN, "the token a remote connection may have seen is replaced");
    assert_eq!(rotated.len(), 48, "a fresh random token");
    let cfg = saved(&home);
    assert_eq!(cfg["websocket"]["token"], rotated.as_str(), "config.json keeps the new token");
    assert!(cfg["websocket"]["tokenRotated"].as_u64().unwrap_or(0) >= 1, "marked: {cfg}");
    let mode = std::fs::metadata(home.join("config.json")).unwrap().permissions().mode();
    assert_eq!(mode & 0o777, 0o600);
    // Once: the next launch keeps it.
    let (child, again) = start(&home, &[]);
    stop(child);
    assert_eq!(url_token(&again), rotated);
    // --token still overrides the listener's token.
    let (child, flagged) = start(&home, &["--token", "flag-token-abc"]);
    stop(child);
    assert_eq!(url_token(&flagged), "flag-token-abc");
    assert_eq!(saved(&home)["websocket"]["token"], rotated.as_str());
    let _ = std::fs::remove_dir_all(&home);
}

#[test]
fn a_first_run_token_is_new_and_never_rotated_again() {
    let home = std::env::temp_dir().join(format!("atn-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&home);
    std::fs::create_dir_all(&home).unwrap();
    let (child, first) = start(&home, &[]);
    stop(child);
    let (child, second) = start(&home, &[]);
    stop(child);
    assert_eq!(url_token(&first), url_token(&second));
    let _ = std::fs::remove_dir_all(&home);
}
