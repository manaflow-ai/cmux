//! The LocalApp origin through a real daemon and WebSocket clients: only the
//! app's pane (loopback, its page origin, this launch's token in the first
//! frame) is served as local, the session pool serves it, and the token
//! never comes back in any reply. A paired or relayed device's hello (no
//! Origin header, or another page) stays remote-origin even with the token.
#![cfg(unix)]

use futures_util::{SinkExt, StreamExt};
use serde_json::{Value, json};
use std::io::{BufRead, BufReader};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::time::Duration;
use tokio_tungstenite::tungstenite::{Message, client::IntoClientRequest};

const FAKE: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
const PANE: &str = "cmux-agent://pane";

struct Daemon {
    child: Option<Child>,
    home: PathBuf,
    /// `ws://127.0.0.1:<port>/` and the listener token, from the ready line.
    ws: String,
    listener_token: String,
}

impl Daemon {
    fn start(tag: &str) -> Self {
        let home = std::env::temp_dir().join(format!("ala-{tag}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&home);
        std::fs::create_dir_all(&home).unwrap();
        std::fs::write(
            home.join("config.json"),
            json!({"harnesses": {"fake": {"argv": ["python3", FAKE]}}, "defaultHarness": "fake",
                "permissionPolicy": "approve-all", "pool": {"debounceMs": 0}})
            .to_string(),
        )
        .unwrap();
        let mut d = Self { child: None, home, ws: String::new(), listener_token: String::new() };
        d.launch();
        d
    }

    fn launch(&mut self) {
        let mut child = Command::new(env!("CARGO_BIN_EXE_acpmux"))
            .args(["daemon", "run", "--listen", "127.0.0.1:0", "--ready-fd", "1", "--log", "error"])
            .env("ACPMUX_HOME", &self.home)
            .env("ACPMUX_SOCKET", self.home.join("s.sock"))
            .env_remove("ACPMUX_AGENT_HOSTS")
            .env_remove("ACPMUX_LOGIN_ENV")
            .env_remove("XPC_SERVICE_NAME")
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::inherit())
            .spawn()
            .unwrap();
        let stdout = child.stdout.take().unwrap();
        self.child = Some(child);
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
        self.ws = format!("{}/", base.replace("http://", "ws://"));
        self.listener_token = token.to_owned();
    }

    fn stop(&mut self) {
        if let Some(mut child) = self.child.take() {
            // SAFETY: this test's own child.
            unsafe { libc::kill(child.id() as i32, libc::SIGTERM) };
            let _ = child.wait();
        }
    }

    fn local_token(&self) -> String {
        std::fs::read_to_string(self.home.join("run/localapp.token")).unwrap()
    }
}

impl Drop for Daemon {
    fn drop(&mut self) {
        if let Some(mut child) = self.child.take() {
            let _ = child.kill();
            let _ = child.wait();
        }
        for dir in [self.home.join("hosts"), self.home.join("hosts/pool")] {
            for r in std::fs::read_dir(dir).into_iter().flatten().flatten() {
                if let Ok(v) =
                    serde_json::from_slice::<Value>(&std::fs::read(r.path()).unwrap_or_default())
                {
                    for pid in
                        [v["harness_pid"].as_i64(), v["host_pid"].as_i64()].into_iter().flatten()
                    {
                        // SAFETY: process groups this test's daemon created.
                        unsafe { libc::killpg(pid as i32, libc::SIGKILL) };
                    }
                }
            }
        }
        let _ = std::fs::remove_dir_all(&self.home);
    }
}

type Ws =
    tokio_tungstenite::WebSocketStream<tokio_tungstenite::MaybeTlsStream<tokio::net::TcpStream>>;

/// A WebSocket client with the listener token, `origin` (None: no header),
/// and a first frame `initialize` carrying `local_token`.
async fn hello(d: &Daemon, origin: Option<&str>, local_token: Option<&str>) -> (Ws, Value) {
    let mut req = d.ws.as_str().into_client_request().unwrap();
    let h = req.headers_mut();
    h.insert("authorization", format!("Bearer {}", d.listener_token).parse().unwrap());
    if let Some(o) = origin {
        h.insert("origin", o.parse().unwrap());
    }
    let (mut ws, _) = tokio_tungstenite::connect_async(req).await.expect("upgrade");
    let mut meta = json!({});
    if let Some(t) = local_token {
        meta["localAppToken"] = json!(t);
    }
    let init = json!({"jsonrpc": "2.0", "id": 1, "method": "initialize",
        "params": {"protocolVersion": 1, "clientInfo": {"name": "test"}, "_meta": {"acpmux": meta}}});
    ws.send(Message::Text(init.to_string().into())).await.unwrap();
    let reply = answer(&mut ws, 1).await;
    (ws, reply)
}

async fn answer(ws: &mut Ws, id: i64) -> Value {
    loop {
        let frame = tokio::time::timeout(Duration::from_secs(30), ws.next())
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

fn origin_of(init: &Value) -> &str {
    init["result"]["_meta"]["acpmux"]["origin"].as_str().unwrap_or("absent")
}

#[tokio::test(flavor = "multi_thread")]
async fn the_app_pane_is_local_and_the_pool_serves_it() {
    let d = Daemon::start("app");
    let token = d.local_token();
    let (mut ws, init) = hello(&d, Some(PANE), Some(&token)).await;
    assert_eq!(origin_of(&init), "local", "{init}");
    let trust = call(&mut ws, 2, "acp.trust.set", json!({"cwd": d.home, "level": "trusted"})).await;
    assert!(trust.get("error").is_none(), "{trust}");
    let warmed = call(
        &mut ws,
        3,
        "_acpmux/prewarm",
        json!({"harness": "fake", "cwd": d.home, "wait": true}),
    )
    .await;
    assert_eq!(warmed["result"]["accepted"], true, "{warmed}");
    let status = call(&mut ws, 4, "_acpmux/status", json!({})).await;
    let text = status.to_string();
    assert!(!text.contains(&token), "the LocalApp token came back");
    assert!(!text.contains(&d.listener_token), "the listener token came back");
    assert!(status["result"].get("webUrl").is_none());
}

#[tokio::test(flavor = "multi_thread")]
async fn a_paired_or_relayed_hello_with_the_token_stays_remote() {
    let d = Daemon::start("relay");
    let token = d.local_token();
    // Peers, ssh tunnels and relays send no Origin header.
    let (mut ws, init) = hello(&d, None, Some(&token)).await;
    assert_eq!(origin_of(&init), "remote", "{init}");
    let refused = call(&mut ws, 2, "_acpmux/prewarm", json!({"harness": "fake"})).await;
    assert!(refused.get("error").is_some(), "the pool refuses a remote origin: {refused}");
    // The dashboard page (the listener's own origin) is not the app either.
    let own = d.ws.replace("ws://", "http://");
    let (_, init) = hello(&d, Some(own.trim_end_matches('/')), Some(&token)).await;
    assert_eq!(origin_of(&init), "remote", "{init}");
    // The app's page without the token.
    let (_, init) = hello(&d, Some(PANE), None).await;
    assert_eq!(origin_of(&init), "remote", "{init}");
}

#[tokio::test(flavor = "multi_thread")]
async fn the_token_is_new_at_every_launch_private_and_never_in_a_reply() {
    use std::os::unix::fs::PermissionsExt;
    let mut d = Daemon::start("launch");
    let first = d.local_token();
    let mode = std::fs::metadata(d.home.join("run/localapp.token")).unwrap().permissions().mode();
    assert_eq!(mode & 0o777, 0o600);
    // Not in the saved config, and not in the unix socket's status either.
    assert!(!std::fs::read_to_string(d.home.join("config.json")).unwrap().contains(&first));
    let status = unix_status(&d.home);
    assert!(!status.contains(&first), "status over the unix socket carried it");
    d.stop();
    assert!(!d.home.join("run/localapp.token").exists(), "removed when the daemon stops");
    d.launch();
    let second = d.local_token();
    assert_ne!(first, second);
    let (_, init) = hello(&d, Some(PANE), Some(&first)).await;
    assert_eq!(origin_of(&init), "remote", "the previous launch's token opens nothing");
    let (_, init) = hello(&d, Some(PANE), Some(&second)).await;
    assert_eq!(origin_of(&init), "local");
}

fn unix_status(home: &Path) -> String {
    use std::io::Write;
    let mut s = std::os::unix::net::UnixStream::connect(home.join("s.sock")).unwrap();
    s.set_read_timeout(Some(Duration::from_secs(10))).unwrap();
    writeln!(s, "{}", json!({"jsonrpc": "2.0", "id": 1, "method": "_acpmux/status", "params": {}}))
        .unwrap();
    let mut line = String::new();
    BufReader::new(s).read_line(&mut line).unwrap();
    line
}
