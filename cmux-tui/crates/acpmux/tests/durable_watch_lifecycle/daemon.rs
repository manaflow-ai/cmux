//! Real daemon processes, private homes and authenticated peers (remote_group_cli.rs).
#![cfg(unix)]
use super::daemon_env;
use acpmux::{
    client::Client,
    rpc::{Message, method},
};
use serde_json::{Value, json};
use std::os::unix::fs::PermissionsExt;
use std::{path::PathBuf, process::Stdio, sync::Arc, time::Duration};
use tokio::{
    io::{AsyncBufReadExt, BufReader},
    process::Child,
    sync::mpsc,
};

pub struct Daemon {
    pub dir: cmux_unix_socket::TestDir,
    child: Child,
    pub client: Arc<Client>,
    listen: String,
}
impl Daemon {
    pub async fn new() -> Self {
        let dir = cmux_unix_socket::short_test_dir("aw");
        std::fs::set_permissions(dir.path(), std::fs::Permissions::from_mode(0o700)).unwrap();
        let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
        std::fs::write(
            dir.path().join("config.json"),
            json!({
                "harnesses": {"fake": {"argv": ["python3", fake]}}, "defaultHarness": "fake",
                "permissionPolicy": "ask", "permissionGroups": {"enabled": false}, "webRoots": [dir.path()]
            })
            .to_string(),
        )
        .unwrap();
        std::fs::set_permissions(
            dir.path().join("config.json"),
            std::fs::Permissions::from_mode(0o600),
        )
        .unwrap();
        let (child, client, listen) = Self::start(dir.path()).await;
        Self { dir, child, client, listen }
    }
    pub async fn start(home: &std::path::Path) -> (Child, Arc<Client>, String) {
        let mut child = daemon_env::tokio_command(home, daemon_env::Agents::StandIn)
            .env("ACPMUX_HOME", home)
            .env("ACPMUX_LOGIN_ENV", "0")
            .env("ACPMUX_CATALOG_FETCH", "0")
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
            .stderr(Stdio::inherit())
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
        tokio::spawn(async move { while lines.next_line().await.ok().flatten().is_some() {} });
        let client =
            Client::connect(&PathBuf::from(ready["socket"].as_str().unwrap())).await.unwrap();
        (child, client, ready["listen"].as_str().unwrap().into())
    }
    pub async fn restart(&mut self) {
        self.child.kill().await.unwrap();
        (self.child, self.client, self.listen) = Self::start(self.dir.path()).await;
    }
    pub async fn call(&self, method: &str, params: Value) -> Value {
        tokio::time::timeout(Duration::from_secs(30), self.client.request(method, params))
            .await
            .expect(method)
            .unwrap()
    }
    pub async fn chat(&self, name: &str) -> String {
        let s = self
            .call(
                method::SESSION_NEW,
                json!({"cwd": self.dir.path(), "mcpServers": [],
            "_meta": {"acpmux": {"name": name}}}),
            )
            .await;
        s["sessionId"].as_str().unwrap().to_owned()
    }
    pub async fn peer(&self, b: &Daemon) {
        let token =
            std::fs::read_to_string(acpmux::server::peer_auth::token_path(b.dir.path())).unwrap();
        self.call(
            "_acpmux/peer_add",
            json!({"name": "b", "url": format!("ws://{}", b.listen),
            "token": "watch-test", "peerToken": token, "wait": true}),
        )
        .await;
    }
    pub async fn stop(&mut self) {
        let _ = self.client.request(method::MUX_SHUTDOWN, json!({"endAgents": true})).await;
        let _ = tokio::time::timeout(Duration::from_secs(20), self.child.wait()).await;
    }
}
pub async fn next_wake(notes: &mut mpsc::Receiver<Message>) -> String {
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
pub async fn observe(a: &Daemon, sink: &str) -> mpsc::Receiver<Message> {
    let notes = a.client.notifications().await.unwrap();
    a.call(
        method::MUX_ATTACH,
        json!({"sessionId": sink, "limit": 0, "eventStream": true, "visible": false}),
    )
    .await;
    notes
}

impl Daemon {
    pub async fn prompt(&self, session: &str, text: &str) {
        self.call(
            method::SESSION_PROMPT,
            json!({"sessionId": session,
            "prompt": [{"type": "text", "text": text}]}),
        )
        .await;
    }
    pub async fn send(&self, session: &str, text: &str) {
        self.call(
            method::MUX_SEND_QUEUE,
            json!({"request": {"sessionId": session,
            "prompt": [{"type": "text", "text": text}]}}),
        )
        .await;
    }
    pub async fn watch(
        &self,
        to: &str,
        sessions: Vec<String>,
        until: &str,
        once: bool,
        pattern: Option<&str>,
    ) -> Value {
        self.call(
            "_acpmux/watch_add",
            json!({"to": to, "sessions": sessions,
            "until": [until], "once": once, "match": pattern}),
        )
        .await
    }
    pub async fn list(&self) -> Value {
        self.call("_acpmux/watch_ls", json!({})).await
    }
    // Wait for actual persisted state changes, never a timer that polls sessions.
    pub async fn settled(&self, predicate: impl Fn(&Value) -> bool) -> Value {
        self.state_when("_acpmux/watch_ls", json!({}), predicate).await
    }
    pub async fn state_when(
        &self,
        method: &str,
        params: Value,
        predicate: impl Fn(&Value) -> bool,
    ) -> Value {
        use notify::Watcher;
        let (tx, mut rx) = mpsc::unbounded_channel();
        let mut watcher =
            notify::recommended_watcher(move |event: notify::Result<notify::Event>| {
                if event.is_ok_and(|e| e.kind.is_modify() || e.kind.is_create()) {
                    let _ = tx.send(());
                }
            })
            .unwrap();
        watcher.watch(self.dir.path(), notify::RecursiveMode::Recursive).unwrap();
        tokio::time::timeout(Duration::from_secs(30), async {
            loop {
                let state = self.call(method, params.clone()).await;
                if predicate(&state) {
                    return state;
                }
                rx.recv().await.expect("watch state change");
            }
        })
        .await
        .expect("watch state settled")
    }
    pub async fn wakes(&self, sink: &str) -> Vec<Value> {
        let page = self
            .call(method::MUX_EVENTS, json!({"sessionId": sink, "kinds": ["user_message"]}))
            .await;
        page["events"]
            .as_array()
            .unwrap()
            .iter()
            .filter(|e| e["msg"]["text"].as_str().is_some_and(|s| s.starts_with("acpmux watch ")))
            .cloned()
            .collect()
    }
    pub async fn disconnect(&mut self) {
        self.child.kill().await.unwrap();
    }
    pub async fn start_again(&mut self) {
        (self.child, self.client, self.listen) = Self::start(self.dir.path()).await;
    }
}
pub async fn quiet(notes: &mut mpsc::Receiver<Message>) {
    assert!(
        tokio::time::timeout(Duration::from_millis(500), next_wake(notes)).await.is_err(),
        "duplicate wake"
    );
}

impl Drop for Daemon {
    fn drop(&mut self) {
        let _ = self.child.start_kill();
        // Only terminate host/harness groups recorded under this test's private home.
        if let Ok(entries) = std::fs::read_dir(self.dir.path().join("hosts")) {
            for entry in entries.flatten() {
                if entry.path().extension().and_then(|s| s.to_str()) != Some("json") {
                    continue;
                }
                if let Ok(record) = serde_json::from_slice::<Value>(
                    &std::fs::read(entry.path()).unwrap_or_default(),
                ) {
                    for pid in [record["harness_pid"].as_i64(), record["host_pid"].as_i64()]
                        .into_iter()
                        .flatten()
                    {
                        // SAFETY: these process groups belong to our private daemon fixture.
                        unsafe {
                            libc::killpg(pid as i32, libc::SIGKILL);
                        }
                    }
                }
            }
        }
    }
}
