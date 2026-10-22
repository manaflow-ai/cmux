//! A restricted chat (`hub/restricted.rs`) that hits a usage limit moves only onto a fallback
//! that runs restricted too: Claude Code, with the restricted command line. A fallback of any
//! other harness would start with the folder's own config, and the trust gate lets a restricted
//! chat's prompts through, so the failover is refused: the limit error stands, with why the
//! chat stayed, and the fallback never starts.
//!
//! One test: the setting is one file in this process's home, so its phases run in order.

// Unix only until the Windows port runs the daemon (cmux::local_socket).
#![cfg(unix)]

#[path = "support/daemon_env.rs"]
mod daemon_env;
// This process runs stand-in agents (the fake agents under tests/).
const HERMETIC: daemon_env::Process = daemon_env::Process::stand_in();

use acpmux::config::{Config, StoreMode};
use acpmux::hub::Hub;
use acpmux::rpc::Message;
use acpmux::server::{Origin, serve_connection_with};
use acpmux::trust::Paths;
use serde_json::{Value, json};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::mpsc;

const FAKE: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
const FAKE_CLAUDE: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_claude.py");

fn dir(tag: &str) -> PathBuf {
    let d = std::env::temp_dir().join(format!("arf-{tag}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&d);
    std::fs::create_dir_all(d.join("work")).unwrap();
    std::fs::create_dir_all(d.join("home")).unwrap();
    std::fs::canonicalize(&d).unwrap()
}

/// Two Claude Code harnesses out of usage: `climit` falls back to the Codex-family `fcodex`
/// (which logs every session it starts to `codex.log`), `climit2` to Claude Code `cok`.
fn hub(d: &Path) -> Arc<Hub> {
    let limit = json!({"FAKE_CLAUDE_LIMIT": "1"});
    let mut cfg: Config = serde_json::from_value(json!({
        "harnesses": {
            "climit": {"argv": ["python3", FAKE_CLAUDE], "kind": "claude-stdio", "env": limit,
                       "fallback": "fcodex"},
            "fcodex": {"argv": ["python3", FAKE], "family": "codex",
                       "env": {"FAKE_CWD_LOG": d.join("codex.log")}},
            "climit2": {"argv": ["python3", FAKE_CLAUDE], "kind": "claude-stdio", "env": limit,
                        "fallback": "cok"},
            "cok": {"argv": ["python3", FAKE_CLAUDE], "kind": "claude-stdio"},
        },
        "defaultHarness": "climit",
        "permissionPolicy": "approve-all",
    }))
    .unwrap();
    cfg.store.mode = StoreMode::Memory;
    let store = acpmux::store::open(&cfg.store, Path::new("/nonexistent")).unwrap();
    let hub = Hub::new(cfg, store);
    hub.set_trust_gate(Some(Paths {
        claude_json: d.join("home").join(".claude.json"),
        codex_config: d.join("home").join("config.toml"),
        record: d.join("home").join("trust.json"),
        agent_home: Some(d.join("agent-home")),
        cmux_worktrees: None,
    }));
    hub
}

/// The cmux settings file this process's hub reads (`user_settings.rs`: under HOME, which the
/// hermetic environment makes this process's own).
fn set_restricted_chats(on: bool) {
    let home = PathBuf::from(std::env::var("HOME").expect("HOME"));
    let file = home.join(".config/cmux/cmux-next.json");
    std::fs::create_dir_all(file.parent().unwrap()).unwrap();
    let doc = json!({"agents": {"trust": {"restrictedChats": on}}});
    std::fs::write(&file, doc.to_string()).unwrap();
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

    /// A restricted chat of `harness` in `cwd`, which the person answered Not now for.
    async fn restricted_chat(&mut self, cwd: &Path, harness: &str) -> String {
        let p = json!({"cwd": cwd, "mcpServers": [], "_meta": {"acpmux": {"harness": harness}}});
        let r = self.call("session/new", p).await;
        assert_eq!(r["result"]["_meta"]["acpmux"]["restricted"], json!(true), "{r}");
        r["result"]["sessionId"].as_str().unwrap().to_owned()
    }

    async fn prompt(&mut self, s: &str, text: &str) -> Value {
        let p = json!({"sessionId": s, "prompt": [{"type": "text", "text": text}]});
        self.call("session/prompt", p).await
    }

    /// The `kind` records of `s`'s log.
    async fn records(&mut self, s: &str, kind: &str) -> Vec<Value> {
        let r = self.call("_acpmux/events", json!({"sessionId": s, "kinds": [kind]})).await;
        let events = r["result"]["events"].as_array().unwrap_or_else(|| panic!("{r}"));
        events.iter().map(|e| e["msg"].clone()).collect()
    }
}

fn after<'a>(args: &'a [String], flag: &str) -> Option<&'a str> {
    let i = args.iter().position(|a| a == flag)?;
    args.get(i + 1).map(String::as_str)
}

#[tokio::test]
async fn a_restricted_chat_never_fails_over_to_a_harness_that_cannot_run_restricted() {
    let d = dir("failover");
    let hub = hub(&d);
    let mut app = Client::new(&hub, Origin::LocalApp);
    let work = d.join("work");
    let r = app.call("acp.trust.set", json!({"cwd": work, "level": "untrusted"})).await;
    assert!(r.get("error").is_none(), "trust.set: {r}");
    set_restricted_chats(true);

    // The fallback is Codex: the limit error stands, says why the chat stayed, and Codex never
    // starts in the folder.
    let s = app.restricted_chat(&work, "climit").await;
    let r = app.prompt(&s, "hello").await;
    let error = r["error"]["message"].as_str().unwrap_or_else(|| panic!("no error: {r}"));
    assert!(error.contains("usage limit"), "{r}");
    assert!(error.contains("can't switch to fcodex in a folder you haven't trusted"), "{r}");
    assert!(app.records(&s, "failover").await.is_empty(), "no failover");
    let refused = app.records(&s, "failover_refused").await;
    assert_eq!(refused.len(), 1, "{refused:?}");
    assert_eq!(
        (&refused[0]["from"], &refused[0]["to"], &refused[0]["reason"]),
        (&json!("climit"), &json!("fcodex"), &json!("restricted")),
        "{refused:?}"
    );
    assert!(!d.join("codex.log").exists(), "the Codex fallback started a session");

    // The fallback is Claude Code: the turn moves there, and it runs restricted too.
    let s = app.restricted_chat(&work, "climit2").await;
    let r = app.prompt(&s, "argv").await;
    assert!(r.get("error").is_none(), "the Claude Code fallback answers: {r}");
    let moved = app.records(&s, "failover").await;
    assert_eq!(moved.len(), 1, "{moved:?}");
    assert_eq!(moved[0]["to"], json!("cok"), "{moved:?}");
    assert!(app.records(&s, "failover_refused").await.is_empty());
    let chunks = app.records(&s, "agent_message_chunk").await;
    let reply = chunks
        .last()
        .and_then(|c| c.pointer("/params/update/content/text"))
        .and_then(Value::as_str)
        .unwrap_or_else(|| panic!("no reply: {chunks:?}"));
    let args: Vec<String> = serde_json::from_str(reply).unwrap_or_else(|_| panic!("{reply}"));
    assert_eq!(after(&args, "--setting-sources"), Some("user"), "{args:?}");
    assert!(args.iter().any(|a| a == "--strict-mcp-config"), "{args:?}");

    set_restricted_chats(false);
    let _ = std::fs::remove_dir_all(&d);
}
