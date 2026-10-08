//! REMOTE-SANDBOX (decisions.md D-R): a remote chain's Claude Code runs in
//! the macOS Seatbelt sandbox (`sandbox/remote-chain.sb`), after a canary
//! proved the sandbox at spawn; its settings ask before every acting tool.
//! Its Bash (any child) cannot write outside the allowed folders or reach a
//! loopback port. Off macOS a remote chain does not run Claude Code at all.
//! A local session's Claude spawns as before.

use acpmux::config::{Config, StoreMode};
use acpmux::hub::Hub;
use acpmux::rpc::Message;
use acpmux::server::{Origin, serve_connection_with};
use serde_json::{Value, json};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::mpsc;

const FAKE_CLAUDE: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_claude.py");

fn dir(tag: &str) -> PathBuf {
    let d = std::env::temp_dir().join(format!("ars-{tag}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&d);
    std::fs::create_dir_all(d.join("work")).unwrap();
    std::fs::canonicalize(&d).unwrap()
}

fn hub(d: &Path) -> Arc<Hub> {
    let mut cfg: Config = serde_json::from_value(json!({
        "harnesses": {"fakeclaude": {"argv": ["python3", FAKE_CLAUDE], "kind": "claude-stdio"}},
        "defaultHarness": "fakeclaude",
        "permissionPolicy": "ask",
        "webRoots": [d.join("work")],
    }))
    .unwrap();
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
            let line = tokio::time::timeout(Duration::from_secs(30), self.1.recv())
                .await
                .unwrap()
                .unwrap();
            let v: Value = serde_json::from_str(&line).unwrap();
            if v.get("id") == Some(&json!(id)) {
                return v;
            }
        }
    }

    /// A new session in `d/work` and one prompt; the error of whichever
    /// failed, else the text the agent streamed for the prompt.
    async fn run(&mut self, d: &Path, text: &str) -> Result<String, Value> {
        let r = self.call("session/new", json!({"cwd": d.join("work"), "mcpServers": []})).await;
        let Some(s) = r["result"]["sessionId"].as_str().map(str::to_owned) else {
            return Err(r);
        };
        let p = json!({"sessionId": s, "prompt": [{"type": "text", "text": text}]});
        let r = self.call("session/prompt", p).await;
        if r.get("error").is_some() {
            return Err(r);
        }
        let e = self.call("_acpmux/events", json!({"sessionId": s, "limit": 1000})).await;
        Ok(e["result"]["events"]
            .as_array()
            .into_iter()
            .flatten()
            .filter(|e| {
                e.pointer("/msg/params/update/sessionUpdate") == Some(&json!("agent_message_chunk"))
            })
            .filter_map(|e| e.pointer("/msg/params/update/content/text").and_then(Value::as_str))
            .collect())
    }
}

#[tokio::test]
async fn a_local_session_spawns_claude_without_the_remote_settings() {
    let d = dir("local");
    let hub = hub(&d);
    let mut local = Client::new(&hub, Origin::Local);
    let argv = local.run(&d, "argv").await.unwrap_or_else(|e| panic!("{e}"));
    assert!(!argv.contains("--settings"), "{argv}");
    let _ = std::fs::remove_dir_all(&d);
}

#[cfg(not(target_os = "macos"))]
#[tokio::test]
async fn off_macos_a_remote_chain_never_runs_claude_code() {
    let d = dir("nomac");
    let hub = hub(&d);
    let mut web = Client::new(&hub, Origin::Web);
    let r = web.run(&d, "argv").await;
    let e = r.expect_err("a remote chain ran Claude Code without the Seatbelt sandbox");
    assert!(e.to_string().contains("Seatbelt"), "{e}");
    let _ = std::fs::remove_dir_all(&d);
}

#[cfg(target_os = "macos")]
#[tokio::test]
async fn a_remote_chain_runs_claude_with_settings_that_ask_before_it_acts() {
    let d = dir("settings");
    let hub = hub(&d);
    let mut web = Client::new(&hub, Origin::Web);
    let argv: Vec<String> =
        serde_json::from_str(&web.run(&d, "argv").await.unwrap_or_else(|e| panic!("{e}"))).unwrap();
    let at = argv.iter().position(|a| a == "--settings").expect("--settings");
    let settings: Value = serde_json::from_str(&argv[at + 1]).unwrap();
    // Claude's own sandbox cannot nest in the profile: off; every acting
    // tool asks, over the user's allow rules.
    assert_eq!(settings["sandbox"]["enabled"], json!(false), "{settings}");
    assert_eq!(settings["sandbox"]["autoAllowBashIfSandboxed"], json!(false), "{settings}");
    let ask = settings["permissions"]["ask"].as_array().expect("ask rules");
    assert!(ask.contains(&json!("Bash")), "{settings}");
    let _ = std::fs::remove_dir_all(&d);
}

#[cfg(target_os = "macos")]
#[tokio::test]
async fn a_remote_chain_cannot_write_outside_its_folders_or_reach_a_loopback_port() {
    let d = dir("probe");
    let hub = hub(&d);
    let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    listener.set_nonblocking(true).unwrap();
    let port = listener.local_addr().unwrap().port();
    // Outside the session folder and the temporary folders.
    let home = std::fs::canonicalize(dirs_home()).unwrap();
    let outside = home.join(format!(".acpmux-test-probe-{}", std::process::id()));
    let _ = std::fs::remove_file(&outside);
    let probe = format!("sandbox-probe {} {port}", outside.display());
    // The control: a local session's agent may do all three.
    let mut local = Client::new(&hub, Origin::Local);
    let seen: Value =
        serde_json::from_str(&local.run(&d, &probe).await.unwrap_or_else(|e| panic!("{e}")))
            .unwrap();
    assert_eq!(seen, json!({"outside": "allowed", "loopback": "allowed", "cwd": "allowed"}));
    let _ = std::fs::remove_file(&outside);
    // A remote chain's agent: only its folder.
    let mut web = Client::new(&hub, Origin::Web);
    let seen: Value =
        serde_json::from_str(&web.run(&d, &probe).await.unwrap_or_else(|e| panic!("{e}"))).unwrap();
    assert_eq!(seen, json!({"outside": "denied", "loopback": "denied", "cwd": "allowed"}));
    assert!(!outside.exists(), "the sandboxed agent wrote {}", outside.display());
    let _ = std::fs::remove_dir_all(&d);
}

#[cfg(target_os = "macos")]
fn dirs_home() -> PathBuf {
    PathBuf::from(std::env::var("HOME").expect("HOME"))
}

#[cfg(target_os = "macos")]
#[tokio::test]
async fn a_remote_chain_cannot_query_the_keychain() {
    let d = dir("keychain");
    let hub = hub(&d);
    // The control: a local session's agent may.
    let mut local = Client::new(&hub, Origin::Local);
    let seen: Value = serde_json::from_str(
        &local.run(&d, "keychain-probe").await.unwrap_or_else(|e| panic!("{e}")),
    )
    .unwrap();
    assert_eq!(seen, json!({"keychain": "allowed"}));
    let mut web = Client::new(&hub, Origin::Web);
    let seen: Value = serde_json::from_str(
        &web.run(&d, "keychain-probe").await.unwrap_or_else(|e| panic!("{e}")),
    )
    .unwrap();
    assert_eq!(seen, json!({"keychain": "denied"}));
    let _ = std::fs::remove_dir_all(&d);
}
