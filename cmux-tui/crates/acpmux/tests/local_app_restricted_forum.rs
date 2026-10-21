//! A restricted chat (`hub/restricted.rs`) gets no forum rules (`hub/forum.rs`). Its Claude
//! Code starts with no MCP server, cmux's tools included, so: its tool list shows none of
//! cmux's tools, no hidden rules block rides its prompts, and an urgent rule never starts a
//! turn in it (it takes prompts from the app's pane only). A trusted chat next to it gets all
//! three, so the test sees what the restricted one is spared.
//!
//! One test: the setting is one file in this process's home, and the tools are read from this
//! process's environment.

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

const FAKE_CLAUDE: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_claude.py");
const PERSON_KEY: &str = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
const ANNOUNCE: &str = "_acpmux/forum/announce";
const CONTEXT_TAG: &str = "cmux-rules-context";

fn dir(tag: &str) -> PathBuf {
    let d = std::env::temp_dir().join(format!("arf-{tag}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&d);
    for sub in ["work", "trusted", "home", "bin"] {
        std::fs::create_dir_all(d.join(sub)).unwrap();
    }
    std::fs::canonicalize(&d).unwrap()
}

fn paths(d: &Path) -> Paths {
    Paths {
        claude_json: d.join("home").join(".claude.json"),
        codex_config: d.join("home").join("config.toml"),
        record: d.join("home").join("trust.json"),
        agent_home: Some(d.join("agent-home")),
    }
}

fn hub(d: &Path) -> Arc<Hub> {
    let mut cfg: Config = serde_json::from_value(json!({
        "harnesses": {"fclaude": {"argv": ["python3", FAKE_CLAUDE], "kind": "claude-stdio"}},
        "defaultHarness": "fclaude",
        "permissionPolicy": "approve-all",
    }))
    .unwrap();
    cfg.store.mode = StoreMode::Memory;
    let store = acpmux::store::open(&cfg.store, Path::new("/nonexistent")).unwrap();
    let hub = Hub::new(cfg, store);
    hub.set_trust_gate(Some(paths(d)));
    let _ = hub.person.install_spawn_key(PERSON_KEY);
    hub
}

/// The cmux settings file this process's hub reads (`user_settings.rs`, under HOME).
fn set_restricted_chats(on: bool) {
    let home = PathBuf::from(std::env::var("HOME").expect("HOME"));
    let file = home.join(".config/cmux/cmux-next.json");
    std::fs::create_dir_all(file.parent().unwrap()).unwrap();
    let doc = json!({"agents": {"trust": {"restrictedChats": on}}});
    std::fs::write(&file, doc.to_string()).unwrap();
}

/// A stand-in `cmux-cua` in the tools' bin folder: every chat that gets cmux's tools lists it.
fn fake_cua(bin: &Path) {
    use std::os::unix::fs::PermissionsExt;
    let path = bin.join("cmux-cua");
    std::fs::write(&path, "#!/bin/sh\nexit 0\n").unwrap();
    std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o755)).unwrap();
}

struct Client(mpsc::Sender<String>, mpsc::Receiver<String>, i64);

impl Client {
    fn new(hub: &Arc<Hub>, origin: Origin) -> Self {
        let (in_tx, in_rx) = mpsc::channel(64);
        let (out_tx, out_rx) = mpsc::channel(4096);
        tokio::spawn(serve_connection_with(hub.clone(), in_rx, out_tx, origin));
        Client(in_tx, out_rx, 0)
    }

    /// The person: `initialize` on the unix socket, then the proof (`hub/person.rs`).
    async fn person(hub: &Arc<Hub>) -> Self {
        let mut c = Self::new(hub, Origin::Local);
        let init = c.ok("initialize", json!({"protocolVersion": 1})).await;
        let challenge = &init["_meta"]["acpmux"]["personChallenge"];
        let proof = acpmux::hub::person::person_proof(
            PERSON_KEY,
            acpmux::hub::person::TRANSPORT_UNIX,
            challenge["nonce"].as_str().unwrap(),
            challenge["connection"].as_str().unwrap(),
        )
        .unwrap();
        let r = c.ok("_acpmux/person_prove", json!({"proof": proof})).await;
        assert_eq!(r["person"], json!(true), "{r}");
        c
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

    async fn ok(&mut self, m: &str, params: Value) -> Value {
        let r = self.call(m, params).await;
        assert!(r.get("error").is_none(), "{m}: {r}");
        r["result"].clone()
    }

    /// A Claude Code chat in `cwd`, and whether it runs restricted.
    async fn new_session(&mut self, cwd: &Path) -> (String, bool) {
        let p = json!({"cwd": cwd, "mcpServers": [], "_meta": {"acpmux": {"harness": "fclaude"}}});
        let r = self.ok("session/new", p).await;
        let restricted = r["_meta"]["acpmux"]["restricted"] == json!(true);
        (r["sessionId"].as_str().unwrap_or_else(|| panic!("{r}")).to_owned(), restricted)
    }

    /// Prompts `text`; the agent's last reply (fake_claude.py).
    async fn ask(&mut self, s: &str, text: &str) -> String {
        let p = json!({"sessionId": s, "prompt": [{"type": "text", "text": text}]});
        self.ok("session/prompt", p).await;
        let events = self
            .ok(
                "_acpmux/events",
                json!({"sessionId": s, "kinds": ["agent_message_chunk"], "limit": 500}),
            )
            .await;
        events["events"]
            .as_array()
            .and_then(|e| e.last())
            .and_then(|e| e.pointer("/msg/params/update/content/text"))
            .and_then(Value::as_str)
            .unwrap_or_else(|| panic!("no reply to {text}: {events}"))
            .to_owned()
    }

    /// The text blocks the agent's next prompt arrives as (fake_claude.py "resource-probe"):
    /// the prompt's own, then any hidden block.
    async fn prompt_texts(&mut self, s: &str) -> String {
        let reply = self.ask(s, "resource-probe").await;
        let v: Value = serde_json::from_str(&reply).unwrap_or_else(|_| panic!("probe: {reply}"));
        v["texts"].to_string()
    }

    /// Who was told the current rule on `key`.
    async fn delivered(&mut self, key: &str) -> Vec<String> {
        let rules = self.ok("_acpmux/forum/rules", json!({})).await;
        let rule = rules["rules"].as_array().unwrap().iter().find(|r| r["key"] == key).cloned();
        let rule = rule.unwrap_or_else(|| panic!("no rule {key}: {rules}"));
        rule["delivered"]
            .as_array()
            .unwrap()
            .iter()
            .filter_map(|d| d["sessionId"].as_str().map(str::to_owned))
            .collect()
    }
}

/// Whether the chat's tool list has any of cmux's own tools.
fn cmux_tools(info: &Value) -> bool {
    let rows = info["tools"].as_array().unwrap_or_else(|| panic!("tools: {info}"));
    rows.iter().any(|r| r["source"] == "cmux")
}

#[tokio::test]
async fn a_restricted_chat_gets_no_forum_rules_tools_or_urgent_prompts() {
    let d = dir("restricted-forum");
    fake_cua(&d.join("bin"));
    // SAFETY: the only test in this binary; set before any session starts.
    unsafe { std::env::set_var("CMUX_AGENT_TOOLS_BIN_DIR", d.join("bin")) };
    set_restricted_chats(true);
    let hub = hub(&d);
    let mut person = Client::person(&hub).await;
    let mut app = Client::new(&hub, Origin::LocalApp);
    let (work, trusted) = (d.join("work"), d.join("trusted"));
    for (cwd, level) in [(&work, "untrusted"), (&trusted, "trusted")] {
        person.ok("acp.trust.set", json!({"cwd": cwd, "level": level})).await;
    }

    // Two live chats from the app's pane: restricted in the folder answered "Not now", and a
    // trusted one.
    let (s, restricted) = app.new_session(&work).await;
    assert!(restricted, "the Not now folder's chat runs restricted");
    let (t, restricted) = app.new_session(&trusted).await;
    assert!(!restricted, "the trusted folder's chat does not");
    app.ask(&s, "hello").await;
    app.ask(&t, "hello").await;

    // A rule: the next prompt of the trusted chat carries it, the restricted chat's does not,
    // and it is never recorded as told to the restricted chat.
    person
        .ok(
            ANNOUNCE,
            json!({"key": "builds", "body": "Builds run on the fleet.", "account": "leo"}),
        )
        .await;
    let told = app.prompt_texts(&t).await;
    assert!(told.contains(CONTEXT_TAG) && told.contains("Builds run on the fleet."), "{told}");
    let spared = app.prompt_texts(&s).await;
    assert!(!spared.contains(CONTEXT_TAG) && !spared.contains("fleet"), "{spared}");
    let delivered = person.delivered("builds").await;
    assert!(delivered.contains(&t) && !delivered.contains(&s), "{delivered:?}");

    // An urgent rule: a prompt to the trusted chat only, never a turn the person did not send.
    let u = person
        .ok(
            ANNOUNCE,
            json!({"key": "load", "body": "Stop building on cosmic-gray.", "urgent": true,
                   "account": "leo"}),
        )
        .await;
    assert_eq!(u["pushed"], json!([t.as_str()]), "{u}");
    assert_eq!(u["pending"], json!([]), "{u}");
    // Queued behind the pushed rule: once this is answered, the push ran.
    app.ask(&t, "after").await;
    let delivered = person.delivered("load").await;
    assert!(delivered.contains(&t) && !delivered.contains(&s), "{delivered:?}");
    let spared = app.prompt_texts(&s).await;
    assert!(!spared.contains(CONTEXT_TAG) && !spared.contains("cosmic-gray"), "{spared}");

    // Its tool list says what its Claude Code starts with: none of cmux's tools.
    let info = person.ok("_acpmux/info", json!({"sessionId": t})).await;
    assert!(cmux_tools(&info), "the trusted chat lists cmux's tools: {info}");
    let info = person.ok("_acpmux/info", json!({"sessionId": s})).await;
    assert!(!cmux_tools(&info), "the restricted chat lists none: {info}");

    set_restricted_chats(false);
    let _ = std::fs::remove_dir_all(&d);
}
