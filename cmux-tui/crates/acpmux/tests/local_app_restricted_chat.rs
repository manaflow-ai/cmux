//! A restricted chat instead of a dead end (`hub/restricted.rs`): with the cmux setting
//! `agents.trust.restrictedChats` on, Claude Code in a folder the person answered "Not now"
//! for starts and takes prompts from the app's pane, without the folder's settings, hooks and
//! MCP servers and asking before every tool. With the setting off the gate refuses the folder
//! as before (`local_app_trust_gate.rs`). Other harnesses keep the refusal. Nothing widens a
//! restricted chat, and trusting the folder lifts it at the next prompt.
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
    let d = std::env::temp_dir().join(format!("arc-{tag}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&d);
    std::fs::create_dir_all(d.join("work")).unwrap();
    std::fs::create_dir_all(d.join("home")).unwrap();
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
        "harnesses": {
            "fclaude": {"argv": ["python3", FAKE_CLAUDE], "kind": "claude-stdio"},
            "fcodex": {"argv": ["python3", FAKE], "family": "codex"},
        },
        "defaultHarness": "fclaude",
        // A restricted chat asks whatever the default says.
        "permissionPolicy": "approve-all",
    }))
    .unwrap();
    cfg.store.mode = StoreMode::Memory;
    let store = acpmux::store::open(&cfg.store, Path::new("/nonexistent")).unwrap();
    let hub = Hub::new(cfg, store);
    hub.set_trust_gate(Some(paths(d)));
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

    async fn new_session(&mut self, cwd: &Path, harness: &str) -> Value {
        let p = json!({"cwd": cwd, "mcpServers": [], "_meta": {"acpmux": {"harness": harness}}});
        self.call("session/new", p).await
    }

    async fn trust(&mut self, cwd: &Path, level: &str) {
        let r = self.call("acp.trust.set", json!({"cwd": cwd, "level": level})).await;
        assert!(r.get("error").is_none(), "trust.set {level}: {r}");
    }

    /// Prompts `text` and answers the agent's reply (fake_claude.py: a plain prompt answers its
    /// argv as JSON, `envs: A,B` those variables).
    async fn ask(&mut self, s: &str, text: &str) -> String {
        let p = json!({"sessionId": s, "prompt": [{"type": "text", "text": text}]});
        let r = self.call("session/prompt", p).await;
        assert!(r.get("error").is_none(), "prompt {text}: {r}");
        let events = self
            .call(
                "_acpmux/events",
                json!({"sessionId": s, "kinds": ["agent_message_chunk"], "limit": 500}),
            )
            .await;
        events["result"]["events"]
            .as_array()
            .and_then(|e| e.last())
            .and_then(|e| e.pointer("/msg/params/update/content/text"))
            .and_then(Value::as_str)
            .unwrap_or_else(|| panic!("no reply to {text}: {events}"))
            .to_owned()
    }
}

fn reason(v: &Value) -> &str {
    v["error"]["data"]["reason"].as_str().unwrap_or_default()
}

fn argv(reply: &str) -> Vec<String> {
    serde_json::from_str(reply).unwrap_or_else(|_| panic!("argv reply: {reply}"))
}

fn after<'a>(args: &'a [String], flag: &str) -> Option<&'a str> {
    let i = args.iter().position(|a| a == flag)?;
    args.get(i + 1).map(String::as_str)
}

fn restricted_flags(args: &[String]) {
    assert_eq!(after(args, "--setting-sources"), Some("user"), "{args:?}");
    assert!(args.iter().any(|a| a == "--strict-mcp-config"), "{args:?}");
    assert_eq!(after(args, "--mcp-config"), Some(r#"{"mcpServers":{}}"#), "{args:?}");
    assert!(args.iter().any(|a| a == "--disable-slash-commands"), "{args:?}");
    assert_eq!(after(args, "--permission-mode"), Some("default"), "{args:?}");
    assert!(!args.iter().any(|a| a.contains("skip-permissions")), "{args:?}");
    let settings: Value = serde_json::from_str(after(args, "--settings").expect("--settings"))
        .expect("inline settings");
    assert_eq!(settings["permissions"]["disableBypassPermissionsMode"], "disable", "{settings}");
    assert!(
        settings["permissions"]["ask"].as_array().is_some_and(|a| a.iter().any(|t| t == "Bash")),
        "{settings}"
    );
}

#[tokio::test]
async fn not_now_opens_a_restricted_claude_chat_only_with_the_setting_on() {
    let d = dir("restricted");
    let hub = hub(&d);
    let mut app = Client::new(&hub, Origin::LocalApp);
    let mut local = Client::new(&hub, Origin::Local);
    let work = d.join("work");
    app.trust(&work, "untrusted").await;

    // Off (the default): the folder refuses as before, and the trust read says nothing new.
    set_restricted_chats(false);
    let r = app.new_session(&work, "fclaude").await;
    assert_eq!(reason(&r), "trust.untrusted", "{r}");
    let read = app.call("acp.trust.get", json!({"cwd": work})).await;
    assert!(read["result"].get("restrictedChats").is_none(), "{read}");
    // A chat started over the unix socket is not restricted, and the pane's prompt is refused.
    let r = local.new_session(&work, "fclaude").await;
    let kept = r["result"]["sessionId"].as_str().unwrap_or_else(|| panic!("{r}")).to_owned();
    assert!(r["result"]["_meta"]["acpmux"].get("restricted").is_none(), "{r}");
    let p = json!({"sessionId": kept, "prompt": [{"type": "text", "text": "x"}]});
    assert_eq!(reason(&app.call("session/prompt", p).await), "trust.untrusted");

    // On: Claude Code starts restricted and asks; the trust read says so.
    set_restricted_chats(true);
    let read = app.call("acp.trust.get", json!({"cwd": work})).await;
    assert_eq!(read["result"]["restrictedChats"], json!(true), "{read}");
    let r = app.new_session(&work, "fclaude").await;
    assert!(r.get("error").is_none(), "restricted session/new: {r}");
    let summary = &r["result"]["_meta"]["acpmux"];
    assert_eq!(summary["restricted"], json!(true), "{r}");
    assert_eq!(summary["policy"], json!("ask"), "{r}");
    let s = r["result"]["sessionId"].as_str().unwrap().to_owned();
    restricted_flags(&argv(&app.ask(&s, "argv").await));
    let env: Value = serde_json::from_str(
        &app.ask(&s, "envs: GIT_CONFIG_COUNT, GIT_CONFIG_KEY_0, GIT_CONFIG_VALUE_0, GIT_CONFIG_KEY_1, GIT_CONFIG_VALUE_1")
            .await,
    )
    .unwrap();
    assert_eq!(
        env,
        json!({"GIT_CONFIG_COUNT": "2", "GIT_CONFIG_KEY_0": "core.fsmonitor",
               "GIT_CONFIG_VALUE_0": "false", "GIT_CONFIG_KEY_1": "core.hooksPath",
               "GIT_CONFIG_VALUE_1": "/dev/null"})
    );

    // Nothing widens it, from the pane or the unix socket. (A connection that is not the
    // person may be refused by the person rule first, `hub/person.rs`; the restricted rule holds
    // for the person too: its unit tests in `hub/restricted.rs`.)
    for (client, who) in [(&mut app, "app"), (&mut local, "unix socket")] {
        let m = json!({"sessionId": s, "modeId": "bypassPermissions"});
        assert!(client.call("session/set_mode", m).await.get("error").is_some(), "{who}");
        let p = json!({"sessionId": s, "policy": "approve-all"});
        assert!(client.call("_acpmux/set_policy", p).await.get("error").is_some(), "{who}");
        let t = json!({"sessionId": s, "on": ["x"]});
        assert_eq!(
            reason(&client.call("_acpmux/set_tools", t).await),
            "restricted.widening",
            "{who}"
        );
    }
    let info =
        app.call("_acpmux/events", json!({"sessionId": s, "kinds": ["policy", "mode"]})).await;
    assert!(!info.to_string().contains("approve-all"), "{info}");
    assert!(!info.to_string().contains("bypassPermissions"), "{info}");
    let plan = app.call("session/set_mode", json!({"sessionId": s, "modeId": "plan"})).await;
    assert!(plan.get("error").is_none(), "Plan asks too: {plan}");

    // Only the app's own pane runs a chat restricted: a peer forwarding for its pane is refused,
    // and the chat stays as it was.
    let mut peer = Client::new(&hub, Origin::Peer);
    let r = local.new_session(&work, "fclaude").await;
    let other = r["result"]["sessionId"].as_str().unwrap_or_else(|| panic!("{r}")).to_owned();
    let p = json!({"sessionId": other, "prompt": [{"type": "text", "text": "x"}],
                   "_meta": {"acpmux": {"via": "app"}}});
    assert_eq!(reason(&peer.call("session/prompt", p).await), "trust.untrusted");
    let marks =
        app.call("_acpmux/events", json!({"sessionId": other, "kinds": ["restricted"]})).await;
    assert!(marks["result"]["events"].as_array().is_some_and(Vec::is_empty), "{marks}");

    // Other harnesses keep the refusal.
    assert_eq!(reason(&app.new_session(&work, "fcodex").await), "trust.untrusted");

    // A chat that existed unrestricted becomes restricted at the pane's next prompt.
    restricted_flags(&argv(&app.ask(&kept, "argv").await));

    // Trust later: the next prompt starts Claude Code without the restrictions.
    app.trust(&work, "trusted").await;
    let args = argv(&app.ask(&s, "argv").await);
    assert!(!args.iter().any(|a| a == "--disable-slash-commands"), "{args:?}");
    assert!(after(&args, "--setting-sources").is_none(), "{args:?}");
    let lifted = app.call("_acpmux/events", json!({"sessionId": s, "kinds": ["restricted"]})).await;
    let last = lifted["result"]["events"].as_array().and_then(|e| e.last()).cloned();
    assert_eq!(last.map(|e| e["msg"]["restricted"].clone()), Some(json!(false)), "{lifted}");

    set_restricted_chats(false);
    let _ = std::fs::remove_dir_all(&d);
}
