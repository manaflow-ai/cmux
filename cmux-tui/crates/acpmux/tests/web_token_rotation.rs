//! The dashboard token stays saved (URL peers, dashboard links and remote
//! browsers keep it across launches; plans/cmux-next/identity.md section 4),
//! so it is kept owner-only and the user can rotate it at once:
//! `acpmux web --rotate-token` replaces it in the running listener and in
//! config.json, the old token stops working, and every connection that
//! authenticated with it as its only credential (Web, Peer) is closed.
#![cfg(unix)]

use futures::StreamExt;
use serde_json::{Value, json};
use std::io::{BufRead, BufReader, Read, Write};
use std::os::unix::fs::PermissionsExt;
use std::process::{Command, Stdio};
use std::time::Duration;

const OLD: &str = "old-dashboard-token-0123456789abcdef";

struct Daemon(Option<std::process::Child>, std::path::PathBuf);

impl Drop for Daemon {
    fn drop(&mut self) {
        if let Some(mut child) = self.0.take() {
            let _ = child.kill();
            let _ = child.wait();
        }
        let _ = std::fs::remove_dir_all(&self.1);
    }
}

fn home(tag: &str) -> std::path::PathBuf {
    let home = std::env::temp_dir().join(format!("awr-{tag}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&home);
    std::fs::create_dir_all(&home).unwrap();
    // A config another tool wrote with the umask's mode, holding the token.
    std::fs::write(
        home.join("config.json"),
        json!({"websocket": {"listen": "127.0.0.1:0", "token": OLD, "tokenRotated": 1}})
            .to_string(),
    )
    .unwrap();
    std::fs::set_permissions(home.join("config.json"), std::fs::Permissions::from_mode(0o644))
        .unwrap();
    home
}

fn start(home: &std::path::Path, extra: &[&str]) -> (Daemon, Value) {
    let mut child = Command::new(env!("CARGO_BIN_EXE_acpmux"))
        .args(["daemon", "run", "--memory", "--listen", "127.0.0.1:0", "--ready-fd", "1"])
        .args(["--log", "error"])
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
    let daemon = Daemon(Some(child), home.to_owned());
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

fn token_of(url: &str) -> String {
    url.split("token=").nth(1).unwrap().to_owned()
}

fn port_of(url: &str) -> u16 {
    let rest = url.split("://").nth(1).unwrap();
    let hostport = rest.split('/').next().unwrap();
    hostport.rsplit(':').next().unwrap().parse().unwrap()
}

fn mode(home: &std::path::Path) -> u32 {
    std::fs::metadata(home.join("config.json")).unwrap().permissions().mode() & 0o777
}

fn saved_token(home: &std::path::Path) -> String {
    let v: Value =
        serde_json::from_slice(&std::fs::read(home.join("config.json")).unwrap()).unwrap();
    v["websocket"]["token"].as_str().unwrap().to_owned()
}

/// The dashboard page's status code for `token`.
fn page_status(port: u16, token: &str) -> u16 {
    let mut s = std::net::TcpStream::connect(("127.0.0.1", port)).unwrap();
    s.set_read_timeout(Some(Duration::from_secs(5))).unwrap();
    write!(s, "GET /?token={token} HTTP/1.1\r\nHost: 127.0.0.1:{port}\r\n\r\n").unwrap();
    let mut buf = [0u8; 256];
    let n = s.read(&mut buf).unwrap();
    let head = String::from_utf8_lossy(&buf[..n]);
    head.split_whitespace().nth(1).unwrap().parse().unwrap()
}

/// `acpmux [--json] web …` against this home's daemon.
fn cli(home: &std::path::Path, args: &[&str]) -> std::process::Output {
    Command::new(env!("CARGO_BIN_EXE_acpmux"))
        .args(args)
        .env("ACPMUX_HOME", home)
        .env("ACPMUX_SOCKET", home.join("s.sock"))
        .env_remove("ACPMUX_LOGIN_ENV")
        .env_remove("XPC_SERVICE_NAME")
        .stdin(Stdio::null())
        .output()
        .unwrap()
}

#[tokio::test(flavor = "multi_thread")]
async fn rotate_token_replaces_the_live_and_saved_token_and_closes_web_connections() {
    let home = home("rot");
    let (_daemon, ready) = start(&home, &[]);
    let url = ready["webUrl"].as_str().unwrap().to_owned();
    assert_eq!(token_of(&url), OLD, "a kept token stays across launches");
    // Stored owner-only once the daemon runs, whatever mode it found.
    assert_eq!(mode(&home), 0o600, "config.json holds the token: 0600");
    let port = port_of(&url);
    assert_eq!(page_status(port, OLD), 200);

    // A remote-origin (Web) client on the old token.
    let (mut web, _) =
        tokio_tungstenite::connect_async(format!("ws://127.0.0.1:{port}/?token={OLD}"))
            .await
            .expect("the old token connects before the rotation");
    // It may not rotate the token itself.
    let req =
        json!({"jsonrpc": "2.0", "id": 7, "method": "_acpmux/web_token_rotate", "params": {}});
    futures::SinkExt::send(
        &mut web,
        tokio_tungstenite::tungstenite::Message::Text(req.to_string().into()),
    )
    .await
    .unwrap();
    let refused = loop {
        let frame = tokio::time::timeout(Duration::from_secs(10), web.next())
            .await
            .expect("a reply")
            .expect("open")
            .unwrap();
        if let tokio_tungstenite::tungstenite::Message::Text(t) = frame {
            let v: Value = serde_json::from_str(&t).unwrap();
            if v["id"] == json!(7) {
                break v;
            }
        }
    };
    assert!(refused.get("error").is_some(), "a Web connection rotated the token: {refused}");
    assert_eq!(saved_token(&home), OLD);

    // The user rotates it from the terminal.
    let out = cli(&home, &["--json", "web", "--rotate-token"]);
    assert!(out.status.success(), "{}", String::from_utf8_lossy(&out.stderr));
    let printed: Value = serde_json::from_slice(&out.stdout).unwrap();
    let new_url = printed["url"].as_str().unwrap();
    let new = token_of(new_url);
    assert_ne!(new, OLD);
    assert_eq!(new.len(), 48, "a fresh random token");
    assert_eq!(port_of(new_url), port, "same listener");
    assert_eq!(saved_token(&home), new, "config.json keeps the new token");
    assert_eq!(mode(&home), 0o600);

    // The old token stops working at once; the new one works.
    assert_eq!(page_status(port, OLD), 401);
    assert_eq!(page_status(port, &new), 200);
    assert!(
        tokio_tungstenite::connect_async(format!("ws://127.0.0.1:{port}/?token={OLD}"))
            .await
            .is_err(),
        "the old token still upgrades"
    );
    // The connection that authenticated with the old token is closed.
    let closed = tokio::time::timeout(Duration::from_secs(10), async {
        loop {
            match web.next().await {
                None | Some(Err(_)) => return,
                Some(Ok(tokio_tungstenite::tungstenite::Message::Close(_))) => return,
                Some(Ok(_)) => {}
            }
        }
    })
    .await;
    assert!(closed.is_ok(), "a Web connection on the old token stayed open");
    // `acpmux web` now prints the new link.
    let out = cli(&home, &["--json", "web"]);
    let printed: Value = serde_json::from_slice(&out.stdout).unwrap();
    assert_eq!(token_of(printed["url"].as_str().unwrap()), new);
}

#[test]
fn rotate_token_refuses_while_a_token_flag_serves() {
    let home = home("flag");
    let (_daemon, ready) = start(&home, &["--token", "flag-token-abcdef"]);
    assert_eq!(token_of(ready["webUrl"].as_str().unwrap()), "flag-token-abcdef");
    let out = cli(&home, &["web", "--rotate-token", "--no-open"]);
    assert!(!out.status.success(), "rotated while --token serves");
    assert!(String::from_utf8_lossy(&out.stderr).contains("--token"));
    assert_eq!(saved_token(&home), OLD, "nothing saved");
}
