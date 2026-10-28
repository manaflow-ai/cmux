//! Session lifecycle commands resolve once, retain the owning peer in the id, and
//! refuse a name that names more than one session.
#![cfg(unix)]

#[path = "support/daemon_env.rs"]
mod daemon_env;
const HERMETIC: daemon_env::Process = daemon_env::Process::stand_in()
    .with_env(&[("ACPMUX_AGENT_HOSTS", "0"), ("ACPMUX_LOGIN_ENV", "0")]);

use acpmux::config::{Config, StoreMode};
use acpmux::hub::Hub;
use acpmux::rpc::{Message, method};
use acpmux::server::{
    WsAuth, bind_unix, bind_ws, peer_auth::PeerAuth, serve_connection, serve_unix, serve_ws_with,
};
use futures_util::{SinkExt, StreamExt};
use serde_json::{Value, json};
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::mpsc;

const PERSON_KEY: &str = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";

fn config(root: &Path) -> Config {
    let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
    let mut cfg: Config = serde_json::from_value(json!({
        "harnesses": {"fake": {"argv": ["python3", fake]}},
        "defaultHarness": "fake",
        "webRoots": [root],
        "webAskingModes": {"fake": ["normal"]},
    }))
    .unwrap();
    cfg.store.mode = StoreMode::Memory;
    cfg
}

fn hub(root: &Path) -> Arc<Hub> {
    let cfg = config(root);
    let store = acpmux::store::open(&cfg.store, root).unwrap();
    Hub::new(cfg, store)
}

struct Rpc {
    tx: mpsc::Sender<String>,
    rx: mpsc::Receiver<String>,
    next: i64,
}

impl Rpc {
    async fn call(&mut self, method: &str, params: Value) -> Value {
        self.next += 1;
        let id = self.next;
        self.tx.send(Message::request(id, method, params).to_line()).await.unwrap();
        loop {
            let line = tokio::time::timeout(Duration::from_secs(20), self.rx.recv())
                .await
                .expect("rpc timeout")
                .expect("rpc closed");
            if let Message::Response { id: got, result, error } = Message::parse(&line).unwrap()
                && got == id
            {
                if let Some(error) = error {
                    panic!("{method} failed: {}", error.message);
                }
                return result.unwrap_or(Value::Null);
            }
        }
    }

    async fn send(&mut self, method: &str, params: Value) -> i64 {
        self.next += 1;
        let id = self.next;
        self.tx.send(Message::request(id, method, params).to_line()).await.unwrap();
        id
    }

    async fn wait(&mut self, method: &str, matches: impl Fn(&Value) -> bool) -> Value {
        loop {
            let line = tokio::time::timeout(Duration::from_secs(20), self.rx.recv())
                .await
                .expect("notification timeout")
                .expect("rpc closed");
            if let Message::Notification { method: got, params } = Message::parse(&line).unwrap() {
                let params = params.unwrap_or(Value::Null);
                if got == method && matches(&params) {
                    return params;
                }
            }
        }
    }
}

async fn client(hub: Arc<Hub>) -> Rpc {
    let _ = hub.person.install_spawn_key(PERSON_KEY);
    let (tx, rx) = mpsc::channel(64);
    let (out_tx, out_rx) = mpsc::channel(4096);
    tokio::spawn(serve_connection(hub, rx, out_tx));
    let mut client = Rpc { tx, rx: out_rx, next: 0 };
    let init = client
        .call(
            method::INITIALIZE,
            json!({
                "protocolVersion": 1,
                "clientInfo": {"name": "session-control-peer-cli"}
            }),
        )
        .await;
    let challenge = &init["_meta"]["acpmux"]["personChallenge"];
    let proof = acpmux::hub::person::person_proof(
        PERSON_KEY,
        acpmux::hub::person::TRANSPORT_UNIX,
        challenge["nonce"].as_str().unwrap(),
        challenge["connection"].as_str().unwrap(),
    )
    .unwrap();
    client.call("_acpmux/person_prove", json!({"proof": proof})).await;
    client.call(method::MUX_WATCH, json!({"enabled": true})).await;
    client
}

async fn listen_peer(
    hub: Arc<Hub>,
    root: &Path,
    tag: &str,
) -> (u16, String, tokio::task::JoinHandle<anyhow::Result<()>>) {
    let auth_root = root.join(tag);
    let auth = PeerAuth::create(&auth_root).unwrap();
    let peer_token =
        std::fs::read_to_string(acpmux::server::peer_auth::token_path(&auth_root)).unwrap();
    let listener = bind_ws("127.0.0.1:0").await.unwrap();
    let port = listener.local_addr().unwrap().port();
    let task = tokio::spawn(serve_ws_with(
        hub,
        listener,
        "test-token".into(),
        WsAuth { local_app: None, peer: Some(Arc::new(auth)) },
    ));
    (port, peer_token, task)
}

/// A tiny peer that deliberately reuses a local raw session id.
async fn lying_peer(session_id: &str) -> (u16, mpsc::UnboundedReceiver<String>) {
    use tokio_tungstenite::tungstenite::Message as Ws;
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = listener.local_addr().unwrap().port();
    let session_id = session_id.to_owned();
    let (calls, received) = mpsc::unbounded_channel();
    tokio::spawn(async move {
        while let Ok((tcp, _)) = listener.accept().await {
            let Ok(mut ws) = tokio_tungstenite::accept_async(tcp).await else { continue };
            let id = session_id.clone();
            let calls = calls.clone();
            tokio::spawn(async move {
                while let Some(Ok(Ws::Text(text))) = ws.next().await {
                    let Ok(Message::Request { id: request_id, method: m, .. }) =
                        Message::parse(&text)
                    else {
                        continue;
                    };
                    calls.send(m.clone()).unwrap();
                    let detail = json!({"sessionId": id, "name": "remote-name", "status": "idle", "policy": "ask", "harness": "fake", "queue": [], "turn": null});
                    let result = match m.as_str() {
                        method::INITIALIZE => {
                            json!({"protocolVersion": 1, "_meta": {"acpmux": {"version": "0", "build": "lying", "origin": "peer"}}})
                        }
                        method::MUX_WATCH => {
                            json!({"sessions": [{"sessionId": id, "name": "remote-name", "harness": "fake", "status": "idle"}]})
                        }
                        method::MUX_INFO | method::SESSION_NEW => detail,
                        _ => json!({}),
                    };
                    let line = Message::ok(request_id, result).to_line();
                    if ws.send(Ws::Text(line.trim_end().to_owned().into())).await.is_err() {
                        return;
                    }
                }
            });
        }
    });
    (port, received)
}

async fn new_session(client: &mut Rpc, root: &Path, name: &str) -> String {
    client
        .call(
            method::SESSION_NEW,
            json!({
                "cwd": root,
                "mcpServers": [],
                "_meta": {"acpmux": {"name": name}}
            }),
        )
        .await["sessionId"]
        .as_str()
        .unwrap()
        .to_owned()
}

async fn cli(root: &Path, socket: &Path, args: &[&str]) -> (bool, String, String) {
    let mut command = daemon_env::tokio_command(root, daemon_env::Agents::Deny);
    command
        .env("ACPMUX_SOCKET", socket)
        .env("PATH", format!("{}:{}", root.join("bin").display(), daemon_env::bare_path(&[])))
        .env("GROUP_CAPTURE", root.join("group-args"))
        .args(args);
    let out = tokio::time::timeout(Duration::from_secs(30), command.kill_on_drop(true).output())
        .await
        .expect("CLI command timeout")
        .unwrap();
    (
        out.status.success(),
        String::from_utf8_lossy(&out.stdout).into_owned(),
        String::from_utf8_lossy(&out.stderr).into_owned(),
    )
}

#[tokio::test]
async fn lifecycle_commands_use_peer_stable_ids_and_refuse_ambiguous_names() {
    let root = PathBuf::from("/tmp").join(format!("amx-scp-{}", std::process::id()));
    std::fs::create_dir_all(&root).unwrap();
    let b = hub(&root);
    let c = hub(&root);
    let mut cb = client(b.clone()).await;
    let mut cc = client(c.clone()).await;
    let stop_id = new_session(&mut cb, &root, "remote-stop").await;
    let resume_id = new_session(&mut cb, &root, "remote-resume").await;
    let resume_by_id = new_session(&mut cb, &root, "resume-by-id").await;
    let cancel_id = new_session(&mut cb, &root, "remote-cancel").await;
    let retry_id = new_session(&mut cb, &root, "remote-retry").await;
    let _same_local = new_session(&mut cb, &root, "local-ambiguous").await;
    let _peer_ambiguous = new_session(&mut cb, &root, "peer-ambiguous").await;
    let _ = new_session(&mut cc, &root, "peer-ambiguous").await;

    // Hold both queues before mirroring the peer rows: exercise real resume by name and id.
    for id in [&resume_id, &resume_by_id] {
        cb.send(
            method::SESSION_PROMPT,
            json!({"sessionId": id.as_str(), "prompt": [{"type": "text", "text": "until-cancel"}]}),
        )
        .await;
        cb.wait(method::SESSION_UPDATE, |p| p["update"]["content"]["text"] == "running").await;
        for (prompt_id, text) in [("p-f", "fail-streamed: boom"), ("p-a", "queued")] {
            cb.send(method::SESSION_PROMPT, json!({"sessionId": id.as_str(), "prompt": [{"type": "text", "text": text}], "_meta": {"acpmux": {"promptId": prompt_id}}})).await;
            cb.wait("_acpmux/prompt_accepted", |p| {
                p["promptId"] == prompt_id && p["queued"] == true
            })
            .await;
        }
        cb.send(method::SESSION_CANCEL, json!({"sessionId": id.as_str()})).await;
        cb.wait(method::MUX_EVENT, |p| {
            p["sessionId"] == id.as_str() && p["kind"] == "queue_paused"
        })
        .await;
        assert_eq!(
            cb.call(method::MUX_INFO, json!({"sessionId": id.as_str()})).await["queuePaused"],
            true
        );
    }
    cb.send(method::SESSION_PROMPT, json!({"sessionId": retry_id, "prompt": [{"type": "text", "text": "fail-once: retry"}], "_meta": {"acpmux": {"promptId": "retry"}}})).await;
    cb.wait(method::MUX_EVENT, |p| p["sessionId"] == retry_id && p["kind"] == "turn_error").await;

    let (port_b, token_b, b_server) = listen_peer(b.clone(), &root, "b").await;
    let (port_c, token_c, c_server) = listen_peer(c.clone(), &root, "c").await;
    let a = hub(&root);
    a.add_peer(
        "b",
        &format!("ws://127.0.0.1:{port_b}"),
        Some("test-token".into()),
        Some(token_b),
        true,
    )
    .await
    .unwrap();
    a.add_peer(
        "c",
        &format!("ws://127.0.0.1:{port_c}"),
        Some("test-token".into()),
        Some(token_c),
        true,
    )
    .await
    .unwrap();
    let local_id = {
        let mut ca = client(a.clone()).await;
        new_session(&mut ca, &root, "local-ambiguous").await
    };
    assert!(!local_id.is_empty());
    let socket = root.join("a.sock");
    let local_server = tokio::spawn(serve_unix(a.clone(), bind_unix(&socket).await.unwrap()));

    // `new --host` carries a permitted start policy to the target peer.
    let (ok, stdout, stderr) = cli(
        &root,
        &socket,
        &[
            "--json",
            "new",
            "--host",
            "b",
            "--name",
            "remote-start",
            "--model",
            "fake",
            "--policy",
            "ask",
        ],
    )
    .await;
    assert!(ok, "{stdout}{stderr}");
    let started: Value = serde_json::from_str(&stdout).unwrap();
    assert_eq!(started["policy"], "ask", "{started}");

    let (ok, stdout, stderr) = cli(
        &root,
        &socket,
        &[
            "--json",
            "new",
            "--host",
            "b",
            "--name",
            "remote-prompt",
            "--model",
            "fake",
            "--policy",
            "ask",
            "hello",
        ],
    )
    .await;
    assert!(ok, "{stdout}{stderr}");
    let prompted: Value = serde_json::from_str(&stdout).unwrap();
    assert_eq!(prompted["reply"], "echo: hello", "{prompted}");

    for key in ["remote-cancel", cancel_id.as_str()] {
        cb.send(
            method::SESSION_PROMPT,
            json!({"sessionId": cancel_id,
            "prompt": [{"type": "text", "text": "until-cancel"}]}),
        )
        .await;
        cb.wait(method::SESSION_UPDATE, |p| {
            p["sessionId"] == cancel_id && p["update"]["content"]["text"] == "running"
        })
        .await;
        let (ok, stdout, stderr) = cli(&root, &socket, &["--json", "session", "cancel", key]).await;
        assert!(ok, "{stdout}{stderr}");
        cb.wait(method::MUX_EVENT, |p| {
            p["sessionId"] == cancel_id
                && p["kind"] == "turn_result"
                && p["msg"]["stopReason"] == "cancelled"
        })
        .await;
    }

    let (ok, stdout, stderr) = cli(&root, &socket, &["--json", "session", "stop", &stop_id]).await;
    assert!(ok, "{stdout}{stderr}");
    let stopped = cb.call(method::MUX_INFO, json!({"sessionId": stop_id})).await;
    assert_eq!(stopped["status"], "closed");

    let (ok, stdout, stderr) =
        cli(&root, &socket, &["--json", "session", "resume", "remote-resume"]).await;
    assert!(ok, "{stdout}{stderr}");
    let resumed: Value = serde_json::from_str(&stdout).unwrap();
    assert_eq!(resumed["resumed"], true, "{stdout}{stderr}");
    cb.wait(method::MUX_EVENT, |p| p["sessionId"] == resume_id && p["kind"] == "queue_resumed")
        .await;
    assert_eq!(
        cb.call(method::MUX_INFO, json!({"sessionId": resume_id})).await["queuePaused"],
        false
    );

    // A stable id resumes another held queue on the same peer.
    let (ok, stdout, stderr) =
        cli(&root, &socket, &["--json", "session", "resume", &resume_by_id]).await;
    assert!(ok, "{stdout}{stderr}");
    let resumed: Value = serde_json::from_str(&stdout).unwrap();
    assert_eq!(resumed["resumed"], true, "{stdout}{stderr}");
    let (ok, stdout, stderr) =
        cli(&root, &socket, &["--json", "session", "stop", "remote-start"]).await;
    assert!(ok, "{stdout}{stderr}");
    let (ok, stdout, stderr) =
        cli(&root, &socket, &["--json", "session", "stop", "definitely-missing"]).await;
    assert!(!ok && format!("{stdout}{stderr}").contains("no_session"), "{stdout}{stderr}");

    let (ok, stdout, stderr) = cli(&root, &socket, &["--json", "retry", &retry_id]).await;
    assert!(ok, "{stdout}{stderr}");
    let retried: Value = serde_json::from_str(&stdout).unwrap();
    assert!(
        retried["promptId"].as_str().is_some_and(|id| id.contains("retry~resume-1")),
        "{stdout}{stderr}"
    );
    cb.wait(method::MUX_EVENT, |p| p["sessionId"] == retry_id && p["kind"] == "turn_result").await;

    // A local and a peer session with the same name, and two peers with the same
    // name, must both refuse a lifecycle operation rather than pick a winner.
    for name in ["local-ambiguous", "peer-ambiguous"] {
        let (ok, stdout, stderr) = cli(&root, &socket, &["--json", "session", "stop", name]).await;
        assert!(!ok, "{name}: {stdout}{stderr}");
        assert!(
            stdout.contains("matches")
                || stderr.contains("matches")
                || stdout.contains("ambiguous")
                || stderr.contains("ambiguous"),
            "{name}: {stdout}{stderr}"
        );
    }

    local_server.abort();
    b_server.abort();
    c_server.abort();
    b.end_agents_at_shutdown(Default::default()).unwrap();
    c.end_agents_at_shutdown(Default::default()).unwrap();
    a.end_agents_at_shutdown(Default::default()).unwrap();
    b.shutdown_all().await;
    c.shutdown_all().await;
    a.shutdown_all().await;
    std::fs::remove_dir_all(root).unwrap();
}

#[tokio::test]
async fn lifecycle_commands_keep_a_peer_owner_when_raw_ids_collide() {
    let root = PathBuf::from("/tmp").join(format!("amx-scp-collision-{}", std::process::id()));
    std::fs::create_dir_all(&root).unwrap();
    let a = hub(&root);
    let mut ca = client(a.clone()).await;
    let local_id = new_session(&mut ca, &root, "local-owner").await;
    let qualified = format!("lying/{local_id}");
    let shadow_id = new_session(&mut ca, &root, &qualified).await;
    let (port, mut calls) = lying_peer(&local_id).await;
    a.add_peer("lying", &format!("ws://127.0.0.1:{port}"), Some("tok".into()), None, true)
        .await
        .unwrap();
    let socket = root.join("a.sock");
    let server = tokio::spawn(serve_unix(a.clone(), bind_unix(&socket).await.unwrap()));
    std::fs::create_dir(root.join("bin")).unwrap();
    let cmux = root.join("bin/cmux");
    std::fs::write(&cmux, "#!/bin/sh\nprintf '%s\\n' \"$@\" > \"$GROUP_CAPTURE\"\n").unwrap();
    std::fs::set_permissions(&cmux, std::fs::Permissions::from_mode(0o700)).unwrap();

    let (ok, stdout, stderr) = cli(
        &root,
        &socket,
        &[
            "--json",
            "new",
            "--host",
            "lying",
            "--group",
            "test-group",
            "--detach",
            "--name",
            "remote-start",
            "--model",
            "fake",
            "--policy",
            "ask",
        ],
    )
    .await;
    assert!(ok, "{stdout}{stderr}");
    let started: Value = serde_json::from_str(&stdout).unwrap();
    assert_eq!(started["name"], "remote-name", "{started}");
    let opened = std::fs::read_to_string(root.join("group-args")).unwrap();
    assert_eq!(opened.lines().nth(2), Some(qualified.as_str()), "{opened}");

    let (ok, stdout, stderr) =
        cli(&root, &socket, &["--json", "session", "stop", "lying/remote-name"]).await;
    assert!(ok, "{stdout}{stderr}");
    let local = ca.call(method::MUX_INFO, json!({"sessionId": local_id})).await;
    assert_ne!(local["status"], "closed", "a peer stop killed the local owner: {local}");
    let shadow = ca.call(method::MUX_INFO, json!({"sessionId": shadow_id})).await;
    assert_ne!(shadow["status"], "closed", "a display name hijacked the peer id: {shadow}");
    tokio::time::timeout(Duration::from_secs(5), async {
        loop {
            if calls.recv().await.as_deref() == Some(method::MUX_KILL) {
                break;
            }
        }
    })
    .await
    .expect("the peer received stop");

    server.abort();
    a.end_agents_at_shutdown(Default::default()).unwrap();
    a.shutdown_all().await;
    std::fs::remove_dir_all(root).unwrap();
}
