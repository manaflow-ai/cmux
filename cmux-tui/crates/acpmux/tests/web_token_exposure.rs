//! The WebSocket token never reaches a remote-origin (Web) connection, and a
//! saved token from a build that sent it there is rotated once.
#![cfg(unix)]

#[path = "support/daemon_env.rs"]
mod daemon_env;
// This process starts no agent.
const HERMETIC: daemon_env::Process = daemon_env::Process::deny();

use acpmux::config::{Config, PeerConfig, StoreMode, WebSocketConfig};
use acpmux::hub::Hub;
use acpmux::rpc::{Message, method};
use acpmux::server::{Origin, serve_connection_with};
use serde_json::{Value, json};
use std::io::{BufRead, BufReader};
use std::process::Stdio;
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
            token_rotated: 1,
        }),
        ..Default::default()
    };
    // A peer whose URL a user wrote with its token in the query.
    cfg.peers.insert(
        "p".into(),
        PeerConfig {
            url: format!("ws://127.0.0.1:1/?token={PEER_TOKEN}"),
            token: None,
            // A peer token kept for a ws:// peer never leaves either.
            peer_token: Some(PEER_TOKEN.into()),
            vm_boundary: false,
            github_broker: false,
        },
    );
    cfg.peers.insert(
        "q".into(),
        PeerConfig {
            url: format!("ws://user:{PEER_TOKEN}@127.0.0.1:2/"),
            token: None,
            peer_token: None,
            vm_boundary: false,
            github_broker: false,
        },
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
    call_with(c, id, m, json!({})).await
}

async fn call_with(
    c: &mut (mpsc::Sender<String>, mpsc::Receiver<String>),
    id: i64,
    m: &str,
    params: Value,
) -> String {
    c.0.send(Message::request(id, m, params).to_line()).await.unwrap();
    loop {
        let line =
            tokio::time::timeout(Duration::from_secs(10), c.1.recv()).await.unwrap().unwrap();
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
    let calls = [
        (1, method::INITIALIZE, json!({})),
        (2, method::MUX_STATUS, json!({})),
        (3, "_acpmux/peers", json!({})),
        // Each answers with every peer's listing.
        (4, "_acpmux/peer_reconnect", json!({"name": "p"})),
        (5, "_acpmux/peer_remove", json!({"name": "q"})),
    ];
    for (id, m, params) in calls {
        let reply = call_with(&mut web, id, m, params).await;
        assert!(!reply.contains(TOKEN), "{m} sent the listener token to a Web connection: {reply}");
        assert!(
            !reply.contains(PEER_TOKEN),
            "{m} sent a peer's token to a Web connection: {reply}"
        );
        assert!(!reply.contains("webUrl"), "{m} sent webUrl to a Web connection: {reply}");
        assert!(!reply.contains("argv"), "{m} sent the daemon's command line: {reply}");
    }
    // The local socket still gets the dashboard link (`acpmux web`, the app).
    let mut local = client(Origin::Local).await;
    let status = call(&mut local, 1, method::MUX_STATUS).await;
    assert!(status.contains(&format!("token={TOKEN}")), "{status}");
    // Who runs it (host enroll reads this instead of scanning processes):
    // its executable and whether it runs as `cmux-tui acp`, never its
    // command line, which may carry `--token`.
    let result = &serde_json::from_str::<Value>(&status).unwrap()["result"];
    assert!(result["exe"].as_str().is_some_and(|e| e.starts_with('/')), "{result}");
    assert_eq!(result["runsAsCmuxTuiAcp"], json!(false), "{result}");
    assert!(result.get("argv").is_none(), "{result}");
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
    let mut child = daemon_env::acpmux(home)
        .args([
            "daemon",
            "run",
            "--memory",
            "--listen",
            "127.0.0.1:0",
            "--ready-fd",
            "1",
            "--log",
            "error",
        ])
        .args(extra)
        .env("ACPMUX_HOME", home)
        .env("ACPMUX_SOCKET", home.join("s.sock"))
        .env("ACPMUX_LOGIN_ENV", "0")
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

/// One request over the daemon's unix socket.
fn unix_call(home: &std::path::Path, m: &str, params: Value) -> Value {
    use std::io::Write;
    let mut s = std::os::unix::net::UnixStream::connect(home.join("s.sock")).unwrap();
    s.set_read_timeout(Some(Duration::from_secs(10))).unwrap();
    let line = json!({"jsonrpc": "2.0", "id": 1, "method": m, "params": params});
    writeln!(s, "{line}").unwrap();
    let mut reader = BufReader::new(s);
    loop {
        let mut reply = String::new();
        reader.read_line(&mut reply).unwrap();
        let v: Value = serde_json::from_str(&reply).unwrap();
        if v.get("id") == Some(&json!(1)) {
            assert!(v.get("error").is_none(), "{m}: {v}");
            return v;
        }
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
    // --token still overrides the listener's token, and a save while it
    // runs (a policy change here) never writes it to config.json.
    let (child, flagged) = start(&home, &["--token", "flag-token-abc"]);
    unix_call(&home, "_acpmux/set_default_policy", json!({"policy": "ask"}));
    // Its status names its executable, never the command line holding --token.
    let status = unix_call(&home, method::MUX_STATUS, json!({}));
    assert!(status["result"]["exe"].is_string(), "{status}");
    assert_eq!(status["result"]["runsAsCmuxTuiAcp"], json!(false), "{status}");
    assert!(status["result"].get("argv").is_none(), "{status}");
    let flag_in_status = status.to_string().contains("flag-token-abc");
    let web_url = status["result"]["webUrl"].as_str().unwrap_or("").contains("flag-token-abc");
    assert!(!flag_in_status || web_url, "only the local dashboard link may hold it: {status}");
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

/// `daemon status` and `daemon start` print the Web UI link without its bearer token: a
/// terminal, a screen share or a pasted log is no place for it (ergo-walk2, 2026-10-25).
/// `--show-token` prints it, and `--json` keeps `webUrl` whole for the app and the scripts
/// that read it.
#[test]
fn daemon_status_prints_the_web_link_without_its_token_unless_asked() {
    let home = std::env::temp_dir().join(format!("ats-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&home);
    std::fs::create_dir_all(&home).unwrap();
    let (child, ready) = start(&home, &[]);
    let token = url_token(&ready);
    let cli = |args: &[&str]| {
        let out = daemon_env::acpmux(&home)
            .args(args)
            .env("ACPMUX_HOME", &home)
            .env("ACPMUX_SOCKET", home.join("s.sock"))
            .stdin(Stdio::null())
            .output()
            .unwrap();
        assert!(out.status.success(), "{args:?}: {}", String::from_utf8_lossy(&out.stderr));
        String::from_utf8(out.stdout).unwrap()
    };
    for args in [&["daemon", "status"][..], &["daemon", "start"]] {
        let plain = cli(args);
        let web =
            plain.lines().find(|l| l.starts_with("web:")).unwrap_or_else(|| panic!("{plain}"));
        assert!(!plain.contains(&token), "{args:?} printed the token: {plain}");
        assert!(web.contains("http://127.0.0.1:"), "{web}");
        assert!(web.contains("--show-token"), "{web}");
    }
    for args in [&["daemon", "status", "--show-token"][..], &["daemon", "start", "--show-token"]] {
        let shown = cli(args);
        assert!(shown.contains(&format!("/?token={token}")), "{args:?}: {shown}");
    }
    let json: Value = serde_json::from_str(&cli(&["--json", "daemon", "status"])).unwrap();
    assert_eq!(url_token(&json), token, "--json keeps webUrl whole");
    stop(child);
    let _ = std::fs::remove_dir_all(&home);
}

/// `acpmux web --no-open` prints the Web UI link without its bearer token, like `daemon
/// status` (ergo-walk4, 2026-10-26: "`acpmux web --no-open` human output still prints the
/// Web UI token in the URL"). `--show-token` prints it, and `--json` keeps `url` whole.
#[test]
fn web_no_open_prints_the_link_without_its_token_unless_asked() {
    let home = std::env::temp_dir().join(format!("atw-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&home);
    std::fs::create_dir_all(&home).unwrap();
    let (child, ready) = start(&home, &[]);
    let token = url_token(&ready);
    let cli = |args: &[&str]| {
        let out = daemon_env::acpmux(&home)
            .args(args)
            .env("ACPMUX_HOME", &home)
            .env("ACPMUX_SOCKET", home.join("s.sock"))
            .stdin(Stdio::null())
            .output()
            .unwrap();
        assert!(out.status.success(), "{args:?}: {}", String::from_utf8_lossy(&out.stderr));
        String::from_utf8(out.stdout).unwrap()
    };
    let plain = cli(&["web", "--no-open"]);
    assert!(!plain.contains(&token), "web --no-open printed the token: {plain}");
    assert!(plain.contains("http://127.0.0.1:"), "{plain}");
    assert!(plain.contains("--show-token"), "{plain}");
    let shown = cli(&["web", "--no-open", "--show-token"]);
    assert!(shown.contains(&format!("/?token={token}")), "{shown}");
    let json: Value = serde_json::from_str(&cli(&["--json", "web"])).unwrap();
    assert!(json["url"].as_str().unwrap().ends_with(&format!("/?token={token}")), "{json}");
    // Plain `acpmux web` hands the browser opener the whole link, and the opener's own
    // output (`xdg-open` with no browser prints the link) stays out of the terminal.
    use std::os::unix::fs::PermissionsExt;
    let bin = home.join("fake-bin");
    std::fs::create_dir_all(&bin).unwrap();
    let got = home.join("opened.txt");
    for name in ["open", "xdg-open"] {
        let script = bin.join(name);
        let g = got.display();
        let body = format!(
            "#!/bin/sh\necho \"opener: $1\"\necho \"opener: $1\" >&2\n\
             printf '%s' \"$1\" > {g}.tmp && mv {g}.tmp {g}\n"
        );
        std::fs::write(&script, body).unwrap();
        std::fs::set_permissions(&script, std::fs::Permissions::from_mode(0o755)).unwrap();
    }
    let mut opened = daemon_env::acpmux(&home);
    let path = format!("{}:{}", bin.display(), std::env::var("PATH").unwrap_or_default());
    let out = opened
        .arg("web")
        .env("ACPMUX_HOME", &home)
        .env("ACPMUX_SOCKET", home.join("s.sock"))
        .env("PATH", path)
        .stdin(Stdio::null())
        .output()
        .unwrap();
    assert!(out.status.success(), "{}", String::from_utf8_lossy(&out.stderr));
    let printed =
        format!("{}{}", String::from_utf8_lossy(&out.stdout), String::from_utf8_lossy(&out.stderr));
    assert!(!printed.contains(&token), "acpmux web printed the token: {printed}");
    let deadline = std::time::Instant::now() + Duration::from_secs(10);
    while !got.exists() {
        assert!(std::time::Instant::now() < deadline, "the opener never ran");
        std::thread::sleep(Duration::from_millis(50));
    }
    let url = std::fs::read_to_string(&got).unwrap();
    assert!(url.ends_with(&format!("/?token={token}")), "the browser gets the whole link: {url}");
    stop(child);
    let _ = std::fs::remove_dir_all(&home);
}

/// `daemon config` prints config.json without its bearer tokens: the listener's
/// `websocket.token` and a peer's `token` and `peerToken` (ergo-walk4, 2026-10-26: "`acpmux
/// daemon config` human output prints websocket.token in full"). `--show-token` prints the
/// file as it is, and `--json` keeps it whole for the scripts that read it.
#[test]
fn daemon_config_prints_the_file_without_its_tokens_unless_asked() {
    let home = std::env::temp_dir().join(format!("atc-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&home);
    std::fs::create_dir_all(&home).unwrap();
    const WS_PEER_TOKEN: &str = "ws-peer-bearer-token-55555";
    const URL_USER_TOKEN: &str = "url-userinfo-token-77777";
    const URL_QUERY_TOKEN: &str = "url-query-token-88888";
    let file = serde_json::to_string_pretty(&json!({
        "permissionPolicy": "ask",
        "websocket": {"listen": "127.0.0.1:0", "token": TOKEN, "tokenRotated": 1},
        "peers": {
            "box": {"url": "ssh://box", "peerToken": PEER_TOKEN},
            "web": {"url": "ws://10.0.0.2:47811", "token": WS_PEER_TOKEN},
            // A token a user wrote into a peer's URL.
            "typed": {"url": format!("wss://me:{URL_USER_TOKEN}@10.0.0.3/x?token={URL_QUERY_TOKEN}#f")},
        },
    }))
    .unwrap();
    std::fs::write(home.join("config.json"), &file).unwrap();
    let cli = |args: &[&str]| {
        let out = daemon_env::acpmux(&home)
            .args(args)
            .env("ACPMUX_HOME", &home)
            .env("ACPMUX_SOCKET", home.join("s.sock"))
            .stdin(Stdio::null())
            .output()
            .unwrap();
        assert!(out.status.success(), "{args:?}: {}", String::from_utf8_lossy(&out.stderr));
        String::from_utf8(out.stdout).unwrap()
    };
    let plain = cli(&["daemon", "config"]);
    for secret in [TOKEN, PEER_TOKEN, WS_PEER_TOKEN, URL_USER_TOKEN, URL_QUERY_TOKEN] {
        assert!(!plain.contains(secret), "daemon config printed {secret}: {plain}");
    }
    assert!(plain.contains("--show-token"), "{plain}");
    // Everything else stays as the file has it.
    assert!(plain.contains("\"listen\": \"127.0.0.1:0\""), "{plain}");
    assert!(plain.contains("wss://10.0.0.3/x (token hidden"), "{plain}");
    assert!(plain.contains("\"url\": \"ssh://box\""), "{plain}");
    assert!(plain.contains("\"tokenRotated\": 1"), "{plain}");
    let shown = cli(&["daemon", "config", "--show-token"]);
    assert!(shown.contains(&file), "--show-token prints the file as it is: {shown}");
    let json: Value = serde_json::from_str(&cli(&["--json", "daemon", "config"])).unwrap();
    assert_eq!(json["config"]["websocket"]["token"], TOKEN, "{json}");
    assert_eq!(json["config"]["peers"]["box"]["peerToken"], PEER_TOKEN, "{json}");
    // A token spelled with escapes serde_json does not write is hidden too.
    std::fs::write(
        home.join("config.json"),
        r#"{"websocket": {"listen": "127.0.0.1:0", "token": "\u0073aved-listener-token-0123456789"}}"#,
    )
    .unwrap();
    let escaped = cli(&["daemon", "config"]);
    assert!(!escaped.contains("aved-listener-token"), "{escaped}");
    assert!(escaped.contains("127.0.0.1:0"), "{escaped}");
    // Nor a token in a peer that a later duplicate key hides from the parsed config.
    std::fs::write(
        home.join("config.json"),
        format!(
            r#"{{"peers": {{"a": {{"url": "ssh://a", "peerToken": "{PEER_TOKEN}"}}, "a": {{"url": "ssh://a"}}}}}}"#
        ),
    )
    .unwrap();
    let duplicate = cli(&["daemon", "config"]);
    assert!(!duplicate.contains(PEER_TOKEN), "{duplicate}");
    assert!(duplicate.contains("ssh://a"), "{duplicate}");
    // A file that does not parse is not printed: it may hold a token.
    std::fs::write(home.join("config.json"), format!("{{\"websocket\": {{\"token\": \"{TOKEN}\""))
        .unwrap();
    let broken = cli(&["daemon", "config"]);
    assert!(!broken.contains(TOKEN), "{broken}");
    assert!(broken.contains("not valid JSON"), "{broken}");
    let _ = std::fs::remove_dir_all(&home);
}
