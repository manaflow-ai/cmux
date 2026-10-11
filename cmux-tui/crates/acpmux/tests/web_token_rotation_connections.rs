//! What a dashboard token rotation does to open connections (cx-1dtj):
//! Web and Peer connections, which presented the old token, are closed
//! through their own cleanup (their attachments end, so a session's attach
//! count drops by theirs); the app's LocalApp connection, which also proved
//! this launch's LocalApp token, stays open and keeps its attachment.
#![cfg(unix)]

use futures_util::{SinkExt, StreamExt};
use serde_json::{Value, json};
use std::io::{BufRead, BufReader, Write};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::time::Duration;
use tokio_tungstenite::tungstenite::{Message, client::IntoClientRequest};

const FAKE: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
const PANE: &str = "cmux-agent://pane";

struct Daemon {
    child: Option<Child>,
    home: PathBuf,
    ws: String,
    token: String,
}

impl Daemon {
    fn start() -> Self {
        let home = std::env::temp_dir().join(format!("awc-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&home);
        std::fs::create_dir_all(&home).unwrap();
        std::fs::write(
            home.join("config.json"),
            json!({"harnesses": {"fake": {"argv": ["python3", FAKE]}}, "defaultHarness": "fake",
                "permissionPolicy": "approve-all"})
            .to_string(),
        )
        .unwrap();
        let mut child = Command::new(env!("CARGO_BIN_EXE_acpmux"))
            .args(["daemon", "run", "--listen", "127.0.0.1:0", "--ready-fd", "1", "--log", "error"])
            .env("ACPMUX_HOME", &home)
            .env("ACPMUX_SOCKET", home.join("s.sock"))
            .env("ACPMUX_AGENT_HOSTS", "0")
            .env("ACPMUX_CATALOG_FETCH", "0")
            .env_remove("ACPMUX_LOGIN_ENV")
            .env_remove("XPC_SERVICE_NAME")
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::inherit())
            .spawn()
            .unwrap();
        let stdout = child.stdout.take().unwrap();
        let (tx, rx) = std::sync::mpsc::channel();
        std::thread::spawn(move || {
            let mut ready = String::new();
            let _ = BufReader::new(stdout).read_line(&mut ready);
            let _ = tx.send(ready);
        });
        let ready: Value =
            serde_json::from_str(&rx.recv_timeout(Duration::from_secs(20)).unwrap()).unwrap();
        let url = ready["webUrl"].as_str().unwrap();
        let (base, token) = url.split_once("/?token=").unwrap();
        let ws = format!("{}/", base.replace("http://", "ws://"));
        Self { child: Some(child), home, ws, token: token.to_owned() }
    }

    fn file(&self, rel: &str) -> String {
        std::fs::read_to_string(self.home.join(rel)).unwrap().trim().to_owned()
    }
}

impl Drop for Daemon {
    fn drop(&mut self) {
        if let Some(mut child) = self.child.take() {
            let _ = child.kill();
            let _ = child.wait();
        }
        let _ = std::fs::remove_dir_all(&self.home);
    }
}

/// One request over the daemon's unix socket.
fn unix_call(home: &Path, m: &str, params: Value) -> Value {
    let mut s = std::os::unix::net::UnixStream::connect(home.join("s.sock")).unwrap();
    s.set_read_timeout(Some(Duration::from_secs(20))).unwrap();
    let line = json!({"jsonrpc": "2.0", "id": 1, "method": m, "params": params});
    writeln!(s, "{line}").unwrap();
    let mut reader = BufReader::new(s);
    loop {
        let mut reply = String::new();
        reader.read_line(&mut reply).unwrap();
        let v: Value = serde_json::from_str(&reply).unwrap();
        if v.get("id") == Some(&json!(1)) {
            assert!(v.get("error").is_none(), "{m}: {v}");
            return v["result"].clone();
        }
    }
}

type Ws =
    tokio_tungstenite::WebSocketStream<tokio_tungstenite::MaybeTlsStream<tokio::net::TcpStream>>;

async fn answer(ws: &mut Ws, id: i64) -> Value {
    loop {
        let frame = tokio::time::timeout(Duration::from_secs(20), ws.next())
            .await
            .expect("an answer in time")
            .expect("open")
            .unwrap();
        if let Message::Text(t) = frame {
            let v: Value = serde_json::from_str(&t).unwrap();
            if v.get("id") == Some(&json!(id)) {
                return v;
            }
        }
    }
}

async fn call(ws: &mut Ws, id: i64, method: &str, params: Value) -> Value {
    let req = json!({"jsonrpc": "2.0", "id": id, "method": method, "params": params});
    ws.send(Message::Text(req.to_string().into())).await.unwrap();
    answer(ws, id).await
}

/// A client with the dashboard token, `headers`, and an `initialize`
/// carrying `local` as the LocalApp token; returns it and its origin.
async fn connect(d: &Daemon, headers: &[(&str, &str)], local: Option<&str>) -> (Ws, String) {
    let mut req = d.ws.as_str().into_client_request().unwrap();
    req.headers_mut().insert("authorization", format!("Bearer {}", d.token).parse().unwrap());
    for (k, v) in headers {
        let name = tokio_tungstenite::tungstenite::http::HeaderName::from_bytes(k.as_bytes());
        req.headers_mut().insert(name.unwrap(), v.parse().unwrap());
    }
    let (mut ws, _) = tokio_tungstenite::connect_async(req).await.expect("upgrade");
    let meta = local.map(|t| json!({"localAppToken": t})).unwrap_or_else(|| json!({}));
    let init = call(
        &mut ws,
        1,
        "initialize",
        json!({"protocolVersion": 1, "clientInfo": {"name": "test"}, "_meta": {"acpmux": meta}}),
    )
    .await;
    let origin =
        init["result"]["_meta"]["acpmux"]["origin"].as_str().unwrap_or("absent").to_owned();
    (ws, origin)
}

/// Whether `ws` is closed within 10 s.
async fn closes(ws: &mut Ws) -> bool {
    tokio::time::timeout(Duration::from_secs(10), async {
        loop {
            match ws.next().await {
                None | Some(Err(_)) | Some(Ok(Message::Close(_))) => return,
                Some(Ok(_)) => {}
            }
        }
    })
    .await
    .is_ok()
}

fn attached(home: &Path, id: &str) -> u64 {
    unix_call(home, "_acpmux/info", json!({"sessionId": id}))["attached"].as_u64().unwrap()
}

#[tokio::test(flavor = "multi_thread")]
async fn a_rotation_closes_web_and_peer_through_their_cleanup_and_keeps_local_app() {
    let d = Daemon::start();
    let home = d.home.clone();
    let made = tokio::task::spawn_blocking(move || {
        let cwd = home.display().to_string();
        unix_call(&home, "session/new", json!({"cwd": cwd, "mcpServers": []}))
    })
    .await
    .unwrap();
    let id = made["sessionId"].as_str().unwrap().to_owned();
    let before = attached(&d.home, &id);

    let local_token = d.file("run/localapp.token");
    let peer_token = d.file("run/peer.token");
    let (mut app, origin) = connect(&d, &[("origin", PANE)], Some(&local_token)).await;
    assert_eq!(origin, "local");
    let (mut peer, origin) = connect(&d, &[("x-acpmux-peer-token", &peer_token)], None).await;
    assert_eq!(origin, "peer");
    let (mut web, origin) = connect(&d, &[], None).await;
    assert_eq!(origin, "remote");
    for (n, ws) in [&mut app, &mut peer, &mut web].into_iter().enumerate() {
        let r = call(ws, 10 + n as i64, "_acpmux/attach", json!({"sessionId": id})).await;
        assert!(r.get("error").is_none(), "attach: {r}");
    }
    assert_eq!(attached(&d.home, &id), before + 3);

    let home = d.home.clone();
    tokio::task::spawn_blocking(move || unix_call(&home, "_acpmux/web_token_rotate", json!({})))
        .await
        .unwrap();

    assert!(closes(&mut web).await, "the Web connection stayed open");
    assert!(closes(&mut peer).await, "the Peer connection stayed open");
    // Their cleanup ran: only the app's attachment is left.
    let deadline = std::time::Instant::now() + Duration::from_secs(10);
    while attached(&d.home, &id) != before + 1 {
        assert!(
            std::time::Instant::now() < deadline,
            "attach count {} after the rotation, expected {}",
            attached(&d.home, &id),
            before + 1
        );
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    // The app's connection still answers.
    let status = call(&mut app, 20, "_acpmux/status", json!({})).await;
    assert!(status.get("error").is_none(), "{status}");
}
