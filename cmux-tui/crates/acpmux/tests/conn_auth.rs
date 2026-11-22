//! Every remote connection is authenticated (Lawrence, 2026-10-13: "remote
//! connection must be authed"). Through a real daemon and its WebSocket
//! listener: a connection without the listener token, or with a wrong one,
//! gets no session and no data (the upgrade is refused); one with the token
//! is served and says which proof it presented
//! (`_meta.acpmux.auth`, `server/conn_auth.rs`), which the mode rule reads.
#![cfg(unix)]

#[path = "support/daemon_env.rs"]
mod daemon_env;
// This process runs stand-in agents (the fake agents under tests/).
const HERMETIC: daemon_env::Process = daemon_env::Process::stand_in();

use futures_util::{SinkExt, StreamExt};
use serde_json::{Value, json};
use std::io::{BufRead, BufReader};
use std::path::PathBuf;
use std::process::{Child, Stdio};
use std::time::Duration;
use tokio_tungstenite::tungstenite::{Message, client::IntoClientRequest};

const FAKE: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
const PANE: &str = "cmux-agent://pane";

struct Daemon {
    child: Child,
    home: PathBuf,
    /// `ws://127.0.0.1:<port>/` and the listener token, from the ready line.
    ws: String,
    listener_token: String,
}

impl Daemon {
    fn start(tag: &str) -> Self {
        let home = std::env::temp_dir().join(format!("cauth-{tag}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&home);
        std::fs::create_dir_all(&home).unwrap();
        std::fs::write(
            home.join("config.json"),
            json!({"harnesses": {"fake": {"argv": ["python3", FAKE]}}, "defaultHarness": "fake",
                "permissionPolicy": "approve-all", "pool": {"debounceMs": 0}})
            .to_string(),
        )
        .unwrap();
        let mut child = daemon_env::command(&home, daemon_env::Agents::StandIn, &[])
            .args(["daemon", "run", "--listen", "127.0.0.1:0", "--ready-fd", "1", "--log", "error"])
            .env("ACPMUX_HOME", &home)
            .env("ACPMUX_SOCKET", home.join("s.sock"))
            .env("ACPMUX_LOGIN_ENV", "0")
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
        let (base, token) = url.split_once("/#token=").unwrap();
        Self {
            child,
            ws: format!("{}/", base.replace("http://", "ws://")),
            listener_token: token.to_owned(),
            home,
        }
    }

    fn local_app_token(&self) -> String {
        std::fs::read_to_string(self.home.join("run/localapp.token")).unwrap()
    }
}

impl Drop for Daemon {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
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

/// How a test client presents (or does not present) the listener token.
enum Token<'a> {
    None,
    Bearer(&'a str),
    /// In the URL query, which the listener never reads.
    Query(&'a str),
    /// As a browser does: `acpmux.v1, acpmux.token.<t>` subprotocols.
    Protocol(&'a str),
}

/// Open a WebSocket. Err: the HTTP status and body of a refused upgrade.
async fn open(d: &Daemon, token: Token<'_>, origin: Option<&str>) -> Result<Ws, (u16, String)> {
    let url = match token {
        Token::Query(t) => format!("{}?token={t}", d.ws),
        _ => d.ws.clone(),
    };
    let mut req = url.as_str().into_client_request().unwrap();
    if let Token::Bearer(t) = token {
        req.headers_mut().insert("authorization", format!("Bearer {t}").parse().unwrap());
    }
    if let Token::Protocol(t) = token {
        let offered = format!("acpmux.v1, acpmux.token.{t}");
        req.headers_mut().insert("sec-websocket-protocol", offered.parse().unwrap());
    }
    if let Some(o) = origin {
        req.headers_mut().insert("origin", o.parse().unwrap());
    }
    match tokio_tungstenite::connect_async(req).await {
        Ok((ws, _)) => Ok(ws),
        Err(tokio_tungstenite::tungstenite::Error::Http(resp)) => {
            let body = resp.body().as_ref().map(|b| String::from_utf8_lossy(b).into_owned());
            Err((resp.status().as_u16(), body.unwrap_or_default()))
        }
        Err(e) => panic!("upgrade failed without an HTTP answer: {e}"),
    }
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

async fn initialize(ws: &mut Ws, local_app_token: Option<&str>) -> Value {
    let mut meta = json!({});
    if let Some(t) = local_app_token {
        meta["localAppToken"] = json!(t);
    }
    call(
        ws,
        1,
        "initialize",
        json!({"protocolVersion": 1, "clientInfo": {"name": "conn-auth-test"},
            "_meta": {"acpmux": meta}}),
    )
    .await
}

fn auth_of(init: &Value) -> &str {
    init["result"]["_meta"]["acpmux"]["auth"].as_str().unwrap_or("absent")
}

fn lists(reply: &Value, id: &str) -> bool {
    reply["result"]["sessions"]
        .as_array()
        .is_some_and(|all| all.iter().any(|s| s["sessionId"] == json!(id)))
}

#[tokio::test(flavor = "multi_thread")]
async fn an_unauthenticated_remote_connection_gets_no_sessions_and_no_data() {
    let d = Daemon::start("refused");
    // A chat exists, so there is data a refused connection could leak.
    let mut app = open(&d, Token::Bearer(&d.listener_token), Some(PANE)).await.expect("app");
    let init = initialize(&mut app, Some(&d.local_app_token())).await;
    assert_eq!(auth_of(&init), "localApp", "{init}");
    let trust =
        call(&mut app, 2, "acp.trust.set", json!({"cwd": d.home, "level": "trusted"})).await;
    assert!(trust.get("error").is_none(), "{trust}");
    let new = call(&mut app, 3, "session/new", json!({"cwd": d.home, "mcpServers": []})).await;
    let id = new["result"]["sessionId"].as_str().unwrap_or_else(|| panic!("{new}")).to_owned();

    // No token, a wrong bearer token, a query token (wrong or right), a
    // wrong subprotocol token, and the LocalApp token in place of the
    // listener token: each upgrade is refused with
    // 401 and carries nothing but the refusal reason.
    let local = d.local_app_token();
    for (what, token, origin) in [
        ("no token", Token::None, None),
        ("no token from the app's page", Token::None, Some(PANE)),
        ("a wrong bearer token", Token::Bearer("wrong"), None),
        ("a wrong query token", Token::Query("wrong"), None),
        ("the listener token in the query", Token::Query(&d.listener_token), None),
        ("a wrong subprotocol token", Token::Protocol("wrong"), None),
        ("the LocalApp token as the listener token", Token::Bearer(local.trim()), Some(PANE)),
    ] {
        match open(&d, token, origin).await {
            Ok(_) => panic!("{what}: the upgrade was accepted"),
            Err((status, body)) => {
                assert_eq!(status, 401, "{what}: {body}");
                assert!(!body.contains(&id), "{what}: the refusal leaked a session id");
                assert!(!body.contains(&d.listener_token), "{what}: the refusal leaked the token");
            }
        }
    }
}

#[tokio::test(flavor = "multi_thread")]
async fn an_authenticated_remote_connection_is_served_and_says_its_proof() {
    let d = Daemon::start("served");
    let mut app = open(&d, Token::Bearer(&d.listener_token), Some(PANE)).await.expect("app");
    initialize(&mut app, Some(&d.local_app_token())).await;
    let trust =
        call(&mut app, 2, "acp.trust.set", json!({"cwd": d.home, "level": "trusted"})).await;
    assert!(trust.get("error").is_none(), "{trust}");
    let new = call(&mut app, 3, "session/new", json!({"cwd": d.home, "mcpServers": []})).await;
    let id = new["result"]["sessionId"].as_str().unwrap_or_else(|| panic!("{new}")).to_owned();

    // A remote client (no Origin header, as a relay, tunnel or paired
    // device sends) with the listener token, by header and by subprotocol.
    for (what, token) in [
        ("bearer", Token::Bearer(&d.listener_token)),
        ("subprotocol", Token::Protocol(&d.listener_token)),
    ] {
        let mut web = open(&d, token, None).await.unwrap_or_else(|e| panic!("{what}: {e:?}"));
        let init = initialize(&mut web, None).await;
        assert_eq!(init["result"]["_meta"]["acpmux"]["origin"], "remote", "{what}: {init}");
        assert_eq!(auth_of(&init), "listenerToken", "{what}: {init}");
        let seen = call(&mut web, 2, "_acpmux/watch", json!({})).await;
        assert!(lists(&seen, &id), "{what}: the authenticated connection sees the chat: {seen}");
    }
}

/// The protocol handler's own floor, for a transport that hands it a
/// connection no proof was checked for (`serve_connection_authed` with
/// `ConnAuth::None`): the first request gets the refusal, nothing else
/// arrives (no session list, no catalog or record notification), and the
/// connection ends.
#[tokio::test(flavor = "multi_thread")]
async fn a_connection_without_a_proof_gets_one_refusal_and_ends() {
    use acpmux::config::{Config, StoreMode};
    use acpmux::server::{ConnAuth, Origin, serve_connection_authed};
    let mut config = Config::default();
    config.store.mode = StoreMode::Memory;
    let store = acpmux::store::open(&config.store, std::path::Path::new("/nonexistent")).unwrap();
    let hub = acpmux::hub::Hub::new(config, store);
    let (in_tx, in_rx) = tokio::sync::mpsc::channel::<String>(8);
    let (out_tx, mut out_rx) = tokio::sync::mpsc::channel::<String>(8);
    let served =
        tokio::spawn(serve_connection_authed(hub, in_rx, out_tx, Origin::Web, ConnAuth::None));
    for (id, method) in [(1, "initialize"), (2, "_acpmux/watch"), (3, "session/list")] {
        let req = json!({"jsonrpc": "2.0", "id": id, "method": method, "params": {}});
        // The connection may end after the first refusal; later sends may fail.
        let _ = in_tx.send(req.to_string()).await;
    }
    let first = tokio::time::timeout(Duration::from_secs(10), out_rx.recv())
        .await
        .expect("an answer in time")
        .expect("a refusal");
    let reply: Value = serde_json::from_str(&first).unwrap();
    assert_eq!(reply["id"], json!(1), "{reply}");
    assert_eq!(
        reply["error"]["code"],
        json!(acpmux::server::conn_auth::UNAUTHENTICATED),
        "{reply}"
    );
    assert!(reply.get("result").is_none(), "{reply}");
    tokio::time::timeout(Duration::from_secs(10), served)
        .await
        .expect("the connection ends")
        .unwrap();
    assert!(out_rx.recv().await.is_none(), "nothing after the refusal");
}
