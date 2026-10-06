//! ACP-REMOTE-GUARD follow-ups: a config.json entry naming a non-asking mode
//! is ignored with a warning, and Web control of a session ends when its
//! mode leaves the asking table (default deny on drift).

use acpmux::config::{Config, StoreMode};
use acpmux::hub::Hub;
use acpmux::rpc::Message;
use acpmux::server::{Origin, serve_connection_with};
use serde_json::{Value, json};
use std::io::{BufRead, BufReader};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::mpsc;

const FAKE: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");

fn dir(tag: &str) -> PathBuf {
    let d = std::env::temp_dir().join(format!("awd-{tag}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&d);
    std::fs::create_dir_all(d.join("work")).unwrap();
    std::fs::canonicalize(&d).unwrap()
}

fn config(d: &Path) -> Value {
    let profile = |family: &str| json!({"argv": ["python3", FAKE], "family": family});
    json!({
        "harnesses": {"fake": {"argv": ["python3", FAKE]}, "fcodex": profile("codex"), "fclaude": profile("claude")},
        "defaultHarness": "fake",
        "permissionPolicy": "ask",
        "webRoots": [d.join("work")],
        // A local typo: "agent" is Codex's non-asking default, and Codex is
        // a refused family; "acceptEdits" is Claude's, which never asks.
        "webAskingModes": {"codex": ["agent"], "claude": ["acceptEdits"]},
    })
}

fn hub(d: &Path) -> Arc<Hub> {
    let mut cfg: Config = serde_json::from_value(config(d)).unwrap();
    cfg.store.mode = StoreMode::Memory;
    let store = acpmux::store::open(&cfg.store, Path::new("/nonexistent")).unwrap();
    Hub::new(cfg, store)
}

struct Client(mpsc::Sender<String>, mpsc::Receiver<String>, i64);

impl Client {
    fn new(hub: &Arc<Hub>, origin: Origin) -> Self {
        let (in_tx, in_rx) = mpsc::channel(64);
        let (out_tx, out_rx) = mpsc::channel(4096);
        tokio::spawn(serve_connection_with(hub.clone(), in_rx, out_tx, origin));
        Client(in_tx, out_rx, 0)
    }

    async fn call(&mut self, m: &str, params: Value) -> Value {
        self.2 += 1;
        let id = self.2;
        self.0.send(Message::request(id, m, params).to_line()).await.unwrap();
        loop {
            let line = tokio::time::timeout(Duration::from_secs(20), self.1.recv())
                .await
                .unwrap()
                .unwrap();
            let v: Value = serde_json::from_str(&line).unwrap();
            if v.get("id") == Some(&json!(id)) {
                return v;
            }
        }
    }

    async fn prompt(&mut self, s: &str, text: &str) -> Value {
        self.call(
            "session/prompt",
            json!({"sessionId": s, "prompt": [{"type": "text", "text": text}]}),
        )
        .await
    }
}

fn new_params(d: &Path, harness: &str) -> Value {
    json!({"cwd": d.join("work"), "mcpServers": [], "_meta": {"acpmux": {"harness": harness}}})
}

#[tokio::test]
async fn a_config_entry_for_a_non_asking_mode_is_ignored() {
    let d = dir("cfg");
    let hub = hub(&d);
    let mut web = Client::new(&hub, Origin::Web);
    // Codex is refused for the Web whatever the config says.
    let r = web.call("session/new", new_params(&d, "fcodex")).await;
    assert!(
        r["error"]["message"].as_str().unwrap_or_default().contains("no reviewed asking mode"),
        "{r}"
    );
    let s = web.call("session/new", new_params(&d, "fclaude")).await;
    let s = s["result"]["sessionId"].as_str().unwrap_or_else(|| panic!("{s}")).to_owned();
    let r = web.call("session/set_mode", json!({"sessionId": s, "modeId": "acceptEdits"})).await;
    assert!(
        r["error"]["message"]
            .as_str()
            .unwrap_or_default()
            .contains("never from a remote WebSocket"),
        "{r}"
    );
    let _ = std::fs::remove_dir_all(&d);
}

#[test]
fn the_daemon_logs_the_merged_table_once_and_warns_about_the_ignored_entry() {
    let d = dir("log");
    std::fs::write(d.join("config.json"), config(&d).to_string()).unwrap();
    let mut child = Command::new(env!("CARGO_BIN_EXE_acpmux"))
        .args([
            "daemon",
            "run",
            "--memory",
            "--listen",
            "127.0.0.1:0",
            "--ready-fd",
            "1",
            "--log",
            "info",
        ])
        .env("ACPMUX_HOME", &d)
        .env("ACPMUX_SOCKET", d.join("s.sock"))
        .env_remove("ACPMUX_LOGIN_ENV")
        .env_remove("XPC_SERVICE_NAME")
        .env("NO_COLOR", "1")
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::inherit())
        .spawn()
        .unwrap();
    let stdout = child.stdout.take().unwrap();
    let (tx, rx) = std::sync::mpsc::channel();
    std::thread::spawn(move || {
        let mut seen = Vec::new();
        for line in BufReader::new(stdout).lines().map_while(Result::ok) {
            let ready = line.starts_with('{');
            seen.push(line);
            if ready {
                break;
            }
        }
        let _ = tx.send(seen);
    });
    let lines = rx.recv_timeout(Duration::from_secs(20)).expect("daemon ready");
    let _ = child.kill();
    let _ = child.wait();
    let text = lines.join("\n");
    let tables = lines.iter().filter(|l| l.contains("web asking modes:")).count();
    assert_eq!(tables, 1, "the merged table is logged once at start: {text}");
    assert!(text.contains("claude=[default,plan]"), "{text}");
    assert!(text.contains("refused=[codex,opencode]"), "{text}");
    assert!(!text.contains("codex=["), "{text}");
    for mode in ["agent", "acceptEdits"] {
        assert!(
            lines.iter().any(|l| l.contains("webAskingModes: ignoring") && l.contains(mode)),
            "the ignored entry {mode} is warned about: {text}"
        );
    }
    let _ = std::fs::remove_dir_all(&d);
}

#[tokio::test]
async fn web_control_ends_when_the_harness_leaves_the_asking_table_by_itself() {
    let d = dir("drift");
    let hub = hub(&d);
    let mut web = Client::new(&hub, Origin::Web);
    let mut local = Client::new(&hub, Origin::Local);
    let mut app = Client::new(&hub, Origin::LocalApp);
    // A Web Claude session starts in default.
    let s = web.call("session/new", new_params(&d, "fclaude")).await;
    let s = s["result"]["sessionId"].as_str().unwrap_or_else(|| panic!("{s}")).to_owned();
    assert!(web.prompt(&s, "hello").await.get("error").is_none());
    // The harness switches itself from default to bypassPermissions.
    assert!(local.prompt(&s, "set-mode: bypassPermissions").await.get("error").is_none());
    let info = local.call("_acpmux/info", json!({"sessionId": s})).await;
    assert_eq!(info["result"]["modes"]["currentModeId"], json!("bypassPermissions"), "{info}");
    // Web control ends at once, with a typed error.
    for (m, p) in [
        ("session/prompt", json!({"sessionId": s, "prompt": [{"type": "text", "text": "hi"}]})),
        ("session/set_mode", json!({"sessionId": s, "modeId": "default"})),
        ("session/set_config_option", json!({"sessionId": s, "configId": "model", "value": "m2"})),
        (
            "_acpmux/permission_respond",
            json!({"sessionId": s, "permissionId": "p1", "optionId": "allow"}),
        ),
        (
            "_acpmux/permission_group_respond",
            json!({"sessionId": s, "groupId": "g", "revision": 1, "decisionKey": "k", "decision": "deny"}),
        ),
    ] {
        let r = web.call(m, p).await;
        assert_eq!(
            r["error"]["data"]["reason"],
            json!("remote.mode_left_asking_table"),
            "{m}: {r}"
        );
        assert_eq!(r["error"]["data"]["mode"], json!("bypassPermissions"), "{m}: {r}");
    }
    // Web reads stay.
    for (m, p) in [
        ("_acpmux/attach", json!({"sessionId": s, "limit": 0})),
        ("_acpmux/events", json!({"sessionId": s})),
        ("_acpmux/info", json!({"sessionId": s})),
    ] {
        let r = web.call(m, p).await;
        assert!(r.get("error").is_none(), "{m}: {r}");
    }
    // The unix socket and the local app keep full control.
    assert!(local.prompt(&s, "still mine").await.get("error").is_none());
    assert!(app.prompt(&s, "mine too").await.get("error").is_none());
    // The harness going back to default by itself does not restore Web control.
    assert!(local.prompt(&s, "set-mode: default").await.get("error").is_none());
    let r = web.prompt(&s, "back?").await;
    assert_eq!(r["error"]["data"]["reason"], json!("remote.mode_left_asking_table"), "{r}");
    // The local user setting an asking mode does.
    assert!(
        local
            .call("session/set_mode", json!({"sessionId": s, "modeId": "default"}))
            .await
            .get("error")
            .is_none()
    );
    assert!(web.prompt(&s, "back").await.get("error").is_none());
    let _ = std::fs::remove_dir_all(&d);
}
