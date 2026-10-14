//! The tools a chat has (cx-thur3): every session's summary and
//! `_acpmux/info` list cmux's own tools (`agent_tools.rs`) and, for Claude
//! Code, the MCP servers, skills and plugins its system/init reports, as
//! `tools` rows with `toolsMutable`. `_acpmux/set_tools` turns one MCP server
//! on or off through Claude Code's `mcp_toggle`; a harness that cannot change
//! its tools mid-session, or a row that cannot change, is refused.
//!
//! One test function: the tools are read from this process's environment,
//! which every test of a binary shares.

// Unix only until the Windows port runs the daemon (cmux::local_socket).
#![cfg(unix)]

use acpmux::config::{Config, StoreMode};
use acpmux::hub::Hub;
use acpmux::rpc::Message;
use acpmux::server::{Origin, serve_connection_with};
use serde_json::{Value, json};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::mpsc;

const FAKE: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
const FAKE_CLAUDE: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_claude.py");

/// What the fake Claude Code's system/init reports besides its own fields:
/// cmux's server (also given by acpmux), two of the user's servers (one
/// already off), cmux's plugin and skill, and one of the user's skills.
fn claude_init() -> Value {
    json!({
        "tools": ["Bash", "mcp__cmux__browser_open", "mcp__github__create_issue"],
        "mcp_servers": [
            {"name": "cmux", "status": "connected"},
            {"name": "github", "status": "connected"},
            {"name": "linear", "status": "disabled"},
        ],
        "plugins": [{"name": "cmux", "path": "/x"}, {"name": "reviewer", "path": "/y"}],
        "skills": ["cmux:cmux-browser", "pdf"],
    })
}

fn hub() -> Arc<Hub> {
    let mut cfg: Config = serde_json::from_value(json!({
        "harnesses": {
            "fake": {"argv": ["python3", FAKE]},
            "fakeclaude": {"argv": ["python3", FAKE_CLAUDE], "kind": "claude-stdio",
                           "env": {"FAKE_CLAUDE_INIT": claude_init().to_string()}},
        },
        "defaultHarness": "fake",
        "permissionPolicy": "approve-all",
    }))
    .unwrap();
    cfg.store.mode = StoreMode::Memory;
    let store = acpmux::store::open(&cfg.store, Path::new("/nonexistent")).unwrap();
    Hub::new(cfg, store)
}

struct Client(mpsc::Sender<String>, mpsc::Receiver<String>, i64);

fn client(hub: &Arc<Hub>, origin: Origin) -> Client {
    let (in_tx, in_rx) = mpsc::channel(64);
    let (out_tx, out_rx) = mpsc::channel(4096);
    tokio::spawn(serve_connection_with(hub.clone(), in_rx, out_tx, origin));
    Client(in_tx, out_rx, 0)
}

impl Client {
    /// The reply (Ok result or Err error object) and the text streamed before it.
    async fn call_text(&mut self, m: &str, params: Value) -> (Result<Value, Value>, String) {
        self.2 += 1;
        let id = self.2;
        self.0.send(Message::request(id, m, params).to_line()).await.unwrap();
        let mut text = String::new();
        loop {
            let line = tokio::time::timeout(Duration::from_secs(30), self.1.recv())
                .await
                .unwrap()
                .unwrap();
            let v: Value = serde_json::from_str(&line).unwrap();
            if v.get("id") == Some(&json!(id)) {
                return match v.get("error") {
                    Some(e) => (Err(e.clone()), text),
                    None => (Ok(v["result"].clone()), text),
                };
            }
            if let Some(t) = v.pointer("/params/update/content/text").and_then(Value::as_str) {
                text.push_str(t);
            }
        }
    }

    async fn call(&mut self, m: &str, params: Value) -> Result<Value, Value> {
        self.call_text(m, params).await.0
    }

    async fn new_session(&mut self, harness: &str) -> String {
        let params = json!({"cwd": std::env::temp_dir(), "mcpServers": [], "_meta": {"acpmux": {"harness": harness}}});
        let reply = self.call("session/new", params).await.expect("session/new");
        reply["sessionId"].as_str().unwrap().to_owned()
    }

    /// The agent's answer to one prompt.
    async fn ask(&mut self, session: &str, text: &str) -> String {
        let prompt = json!({"sessionId": session, "prompt": [{"type": "text", "text": text}]});
        let (reply, said) = self.call_text("session/prompt", prompt).await;
        reply.expect("session/prompt");
        said
    }

    /// The first `_acpmux/session_changed` of `kind` for `session`.
    async fn changed(&mut self, session: &str, kind: &str) -> Value {
        loop {
            let line = tokio::time::timeout(Duration::from_secs(30), self.1.recv())
                .await
                .expect("no session_changed")
                .unwrap();
            let v: Value = serde_json::from_str(&line).unwrap();
            if v["method"] == "_acpmux/session_changed"
                && v["params"]["sessionId"] == session
                && v["params"]["kind"] == kind
            {
                return v["params"].clone();
            }
        }
    }
}

fn fake_bin(dir: &Path, name: &str) -> PathBuf {
    use std::os::unix::fs::PermissionsExt;
    let path = dir.join(name);
    std::fs::write(&path, "#!/bin/sh\nexit 0\n").unwrap();
    std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o755)).unwrap();
    path
}

/// `(id, kind, source, enabled, canToggle)` of each row.
fn rows(tools: &Value) -> Vec<(String, String, String, bool, bool)> {
    tools
        .as_array()
        .unwrap_or_else(|| panic!("tools is a list: {tools}"))
        .iter()
        .map(|r| {
            assert!(r["name"].is_string(), "{r}");
            (
                r["id"].as_str().unwrap().to_owned(),
                r["kind"].as_str().unwrap().to_owned(),
                r["source"].as_str().unwrap().to_owned(),
                r["enabled"].as_bool().unwrap(),
                r["canToggle"].as_bool().unwrap(),
            )
        })
        .collect()
}

fn row(
    id: &str,
    kind: &str,
    source: &str,
    enabled: bool,
    toggle: bool,
) -> (String, String, String, bool, bool) {
    (id.into(), kind.into(), source.into(), enabled, toggle)
}

fn reason(e: &Value) -> &str {
    e.pointer("/data/reason").and_then(Value::as_str).unwrap_or_default()
}

#[tokio::test]
async fn chats_list_their_tools_and_claude_turns_mcp_servers_off() {
    let root =
        std::env::temp_dir().join(format!("acpmux-tool-inventory-it-{}", uuid::Uuid::now_v7()));
    let bin = root.join("bin");
    std::fs::create_dir_all(&bin).unwrap();
    fake_bin(&bin, "cmux-cua");
    fake_bin(&bin, "cmux");
    let cmux_json = root.join("cmux-next.json");
    std::fs::write(&cmux_json, r#"{"agents": {"chats": {"enabled": true}}}"#).unwrap();
    // SAFETY: the only test in this binary; set before any session starts.
    unsafe {
        std::env::set_var("CMUX_AGENT_TOOLS_BIN_DIR", &bin);
        std::env::set_var("CMUX_NEXT_CONFIG_FILE", &cmux_json);
        std::env::set_var("ACPMUX_HOME", root.join("home"));
        std::env::remove_var("ACPMUX_AGENT_TOOLS");
        std::env::remove_var("ACPMUX_SECRET_TOOLS");
    }
    let hub = hub();
    let mut local = client(&hub, Origin::Local);
    let mut watcher = client(&hub, Origin::Local);
    watcher.call("_acpmux/watch", json!({"enabled": true})).await.expect("watch");

    // initialize advertises the method and the feature.
    let init = local.call("initialize", json!({"protocolVersion": 1})).await.unwrap();
    let mux = &init["_meta"]["acpmux"];
    assert!(mux["features"].as_array().unwrap().contains(&json!("toolInventory")), "{mux}");
    assert!(mux["extensions"].as_array().unwrap().contains(&json!("_acpmux/set_tools")), "{mux}");

    // An ACP harness: cmux's MCP servers, fixed for the session (no skills:
    // only Claude Code takes the skills plugin).
    let acp = local.new_session("fake").await;
    let info = local.call("_acpmux/info", json!({"sessionId": acp})).await.unwrap();
    assert_eq!(info["toolsMutable"], json!(false), "{info}");
    let cmux_servers = vec![
        row("mcp:cmux-cua", "cmux", "cmux", true, false),
        row("mcp:cmux", "cmux", "cmux", true, false),
    ];
    assert_eq!(rows(&info["tools"]), cmux_servers, "{info}");
    let sessions = local.call("_acpmux/sessions", json!({})).await.unwrap();
    let summary = sessions["sessions"]
        .as_array()
        .unwrap()
        .iter()
        .find(|s| s["sessionId"] == json!(acp))
        .cloned()
        .expect("the session is listed");
    assert_eq!(rows(&summary["tools"]), cmux_servers, "{summary}");
    assert_eq!(summary["toolsMutable"], json!(false), "{summary}");
    // It cannot change them mid-session: refused, never a silent no-op.
    let refused = local
        .call("_acpmux/set_tools", json!({"sessionId": acp, "id": "mcp:cmux", "enabled": false}))
        .await
        .expect_err("an ACP harness cannot change its tools");
    assert_eq!(reason(&refused), "tools.immutable", "{refused}");

    // Claude Code: cmux's servers and skills, then what its init reports
    // (cmux's own server and skill and plugin once, the user's after them).
    let claude = local.new_session("fakeclaude").await;
    local.ask(&claude, "hi").await;
    let info = local.call("_acpmux/info", json!({"sessionId": claude})).await.unwrap();
    assert_eq!(info["toolsMutable"], json!(true), "{info}");
    assert_eq!(
        rows(&info["tools"]),
        vec![
            row("mcp:cmux-cua", "cmux", "cmux", true, true),
            row("mcp:cmux", "cmux", "cmux", true, true),
            row("skill:cmux:cmux-browser", "cmux", "cmux", true, false),
            row("skill:cmux:cmux-cua", "cmux", "cmux", true, false),
            row("mcp:github", "mcp", "claude", true, true),
            row("mcp:linear", "mcp", "claude", false, true),
            row("plugin:reviewer", "plugin", "claude", true, false),
            row("skill:pdf", "skill", "claude", true, false),
        ],
        "{info}"
    );

    // Turn the user's github server off: Claude Code gets mcp_toggle, the row
    // flips, and watchers hear it.
    let set = local
        .call(
            "_acpmux/set_tools",
            json!({"sessionId": claude, "id": "mcp:github", "enabled": false}),
        )
        .await
        .expect("set_tools");
    let github = |tools: &Value| rows(tools).into_iter().find(|r| r.0 == "mcp:github").unwrap();
    assert_eq!(github(&set["tools"]), row("mcp:github", "mcp", "claude", false, true), "{set}");
    let toggles: Value = serde_json::from_str(&local.ask(&claude, "toggles-probe").await).unwrap();
    assert_eq!(toggles, json!([{"serverName": "github", "enabled": false}]));
    // The first `tools` change is Claude Code's init; then the set's.
    while github(&watcher.changed(&claude, "tools").await["session"]["tools"]).3 {}
    let info = local.call("_acpmux/info", json!({"sessionId": claude})).await.unwrap();
    assert!(!github(&info["tools"]).3, "{info}");

    // A skill cannot be turned off mid-session, and an unknown id is not found.
    let fixed = local
        .call(
            "_acpmux/set_tools",
            json!({"sessionId": claude, "id": "skill:cmux:cmux-browser", "enabled": false}),
        )
        .await
        .expect_err("a skill is fixed");
    assert_eq!(reason(&fixed), "tools.fixed", "{fixed}");
    let unknown = local
        .call("_acpmux/set_tools", json!({"sessionId": claude, "id": "mcp:nope", "enabled": true}))
        .await
        .expect_err("no such tool");
    assert_eq!(unknown["code"], json!(-32002), "{unknown}");

    // The app's pane may set them; a remote browser may not (turning an MCP
    // server on runs the command it names on this machine).
    let on = json!({"sessionId": claude, "id": "mcp:github", "enabled": true});
    let remote = client(&hub, Origin::Web)
        .call("_acpmux/set_tools", on.clone())
        .await
        .expect_err("a remote browser cannot set tools");
    assert_eq!(reason(&remote), "tools.remote", "{remote}");
    let set = client(&hub, Origin::LocalApp)
        .call("_acpmux/set_tools", on)
        .await
        .expect("the app's pane turns it back on");
    assert!(github(&set["tools"]).3, "{set}");

    // The daemon's switch: a new session lists none of cmux's tools.
    // SAFETY: as above; no session is starting concurrently.
    unsafe { std::env::set_var("ACPMUX_AGENT_TOOLS", "0") };
    let off = local.new_session("fake").await;
    let info = local.call("_acpmux/info", json!({"sessionId": off})).await.unwrap();
    assert_eq!(info["tools"], json!([]), "{info}");

    let _ = std::fs::remove_dir_all(&root);
}
