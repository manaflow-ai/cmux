//! A coordinator on A watches a local chat and B's chat without a CLI waiter.
#![cfg(unix)]
#[path = "support/daemon_env.rs"]
mod daemon_env;
const HERMETIC: daemon_env::Process = daemon_env::Process::stand_in();
use acpmux::{
    client::Client,
    rpc::{Message, method},
};
use serde_json::{Value, json};
use std::{path::PathBuf, process::Stdio, sync::Arc, time::Duration};
use tokio::{
    io::{AsyncBufReadExt, BufReader},
    process::Child,
    sync::mpsc,
};

struct Daemon {
    dir: cmux_unix_socket::TestDir,
    child: Child,
    client: Arc<Client>,
    listen: String,
}
impl Daemon {
    async fn new() -> Self {
        let dir = cmux_unix_socket::short_test_dir("aw");
        let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
        std::fs::write(
            dir.path().join("config.json"),
            json!({
                "harnesses": {"fake": {"argv": ["python3", fake]}}, "defaultHarness": "fake",
                "permissionPolicy": "ask", "webRoots": [dir.path()]
            })
            .to_string(),
        )
        .unwrap();
        let (child, client, listen) = Self::start(dir.path()).await;
        Self { dir, child, client, listen }
    }
    async fn start(home: &std::path::Path) -> (Child, Arc<Client>, String) {
        let mut child = daemon_env::tokio_command(home, daemon_env::Agents::StandIn)
            .env("ACPMUX_HOME", home)
            .env("ACPMUX_LOGIN_ENV", "0")
            .args([
                "daemon",
                "run",
                "--listen",
                "127.0.0.1:0",
                "--token",
                "watch-test",
                "--ready-fd",
                "1",
            ])
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .kill_on_drop(true)
            .spawn()
            .unwrap();
        let mut lines = BufReader::new(child.stdout.take().unwrap()).lines();
        let ready: Value = tokio::time::timeout(Duration::from_secs(20), async {
            loop {
                let line = lines.next_line().await.unwrap().expect("daemon ready");
                if let Ok(v) = serde_json::from_str::<Value>(&line)
                    && v["ready"] == true
                {
                    break v;
                }
            }
        })
        .await
        .unwrap();
        let client =
            Client::connect(&PathBuf::from(ready["socket"].as_str().unwrap())).await.unwrap();
        (child, client, ready["listen"].as_str().unwrap().into())
    }
    async fn restart(&mut self) {
        self.child.kill().await.unwrap();
        (self.child, self.client, self.listen) = Self::start(self.dir.path()).await;
    }
    async fn call(&self, method: &str, params: Value) -> Value {
        self.client.request(method, params).await.unwrap()
    }
    async fn chat(&self, name: &str) -> String {
        let s = self
            .call(
                method::SESSION_NEW,
                json!({"cwd": self.dir.path(), "mcpServers": [],
            "_meta": {"acpmux": {"name": name}}}),
            )
            .await;
        let id = s["sessionId"].as_str().unwrap().to_owned();
        self.call(
            method::SESSION_PROMPT,
            json!({"sessionId": id,
            "prompt": [{"type": "text", "text": format!("reply from {name}")}]}),
        )
        .await;
        id
    }
    async fn peer(&self, b: &Daemon) {
        let token =
            std::fs::read_to_string(acpmux::server::peer_auth::token_path(b.dir.path())).unwrap();
        self.call(
            "_acpmux/peer_add",
            json!({"name": "b", "url": format!("ws://{}", b.listen),
            "token": "watch-test", "peerToken": token, "wait": true}),
        )
        .await;
    }
    async fn stop(&mut self) {
        let _ = self.client.request(method::MUX_SHUTDOWN, json!({"endAgents": true})).await;
        let _ = tokio::time::timeout(Duration::from_secs(20), self.child.wait()).await;
    }
}
async fn next_wake(notes: &mut mpsc::Receiver<Message>) -> String {
    tokio::time::timeout(Duration::from_secs(20), async {
        loop {
            let note = notes.recv().await.expect("notification stream closed");
            if let Message::Notification { method: m, params: Some(p) } = note
                && m == method::MUX_EVENT
                && p["kind"] == "user_message"
                && let Some(text) = p["msg"]["text"].as_str()
                && text.starts_with("acpmux watch ")
            {
                break text.to_owned();
            }
        }
    })
    .await
    .expect("wake delivered as a normal prompt")
}
async fn observe(a: &Daemon, sink: &str) -> mpsc::Receiver<Message> {
    let notes = a.client.notifications().await.unwrap();
    a.call(
        method::MUX_ATTACH,
        json!({"sessionId": sink, "limit": 0, "eventStream": true, "visible": false}),
    )
    .await;
    notes
}
#[tokio::test]
async fn durable_watch_two_chats_restart_and_one_peer_offline_notice() {
    let mut a = Daemon::new().await;
    let mut b = Daemon::new().await;
    let sink = a.chat("coordinator").await;
    let local = a.chat("local-job").await;
    let remote = b.chat("peer-job").await;
    a.peer(&b).await;
    let mut notes = observe(&a, &sink).await;
    let once = a
        .call(
            method::MUX_WATCH_ADD,
            json!({"to": sink, "sessions": [local, format!("b/{remote}")], "once": true}),
        )
        .await;
    let batch = next_wake(&mut notes).await;
    assert!(batch.contains(&local) && batch.contains(&remote), "{batch}");
    a.call(method::MUX_WATCH_RM, json!({"id": once["id"]})).await;
    let watch = a
        .call(
            method::MUX_WATCH_ADD,
            json!({"to": sink,
        "sessions": ["local-job", "b/peer-job"], "until": ["closed"], "once": false}),
        )
        .await;
    a.restart().await;
    let listed = a.call(method::MUX_WATCH_LS, json!({})).await;
    assert_eq!(listed["watches"][0]["id"], watch["id"]);
    // Re-adding waits for the handshake, without polling inventory.
    a.peer(&b).await;
    let mut notes = observe(&a, &sink).await;
    a.call(method::MUX_KILL, json!({"sessionId": local})).await;
    let wake = next_wake(&mut notes).await;
    assert!(
        wake.contains(&local)
            && wake.contains("is closed")
            && wake.contains("reply from local-job"),
        "{wake}"
    );
    b.call(method::MUX_KILL, json!({"sessionId": remote})).await;
    let wake = next_wake(&mut notes).await;
    assert!(wake.contains(&format!("b/{remote}")) && wake.contains("is closed"), "{wake}");
    assert!(wake.contains("acpmux history b/") && wake.contains("acpmux pending"), "{wake}");
    b.child.kill().await.unwrap();
    let offline = next_wake(&mut notes).await;
    assert!(offline.contains("Peer b is offline") && !offline.contains("is closed"), "{offline}");
    assert!(
        tokio::time::timeout(Duration::from_millis(500), next_wake(&mut notes)).await.is_err(),
        "duplicate wake"
    );
    a.restart().await;
    let mut notes = observe(&a, &sink).await;
    a.call("_acpmux/peer_reconnect", json!({"name": "b", "wait": true})).await;
    assert!(
        tokio::time::timeout(Duration::from_millis(500), next_wake(&mut notes)).await.is_err(),
        "restart repeated offline notice"
    );
    a.call(method::MUX_WATCH_RM, json!({"id": watch["id"]})).await;
    assert!(
        a.client.request(method::MUX_WATCH_ADD, json!({"to": sink, "sessions": []})).await.is_err()
    );
    a.stop().await;
}
