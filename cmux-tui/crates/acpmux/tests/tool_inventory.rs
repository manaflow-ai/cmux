//! The tools a chat has (cx-thur3): per-session reads and attachments
//! list cmux's own tools (`agent_tools.rs`) and, for Claude
//! Code, the MCP servers, skills and plugins its system/init reports, as
//! `tools` rows with `toolsMutable`. `_acpmux/set_tools` records the chat's
//! choice for one MCP server: Claude Code then starts with
//! `--disallowedTools mcp__<server>` for each server that is off (restarted
//! and resumed now when no turn runs), at every later start too. It never
//! sends `mcp_toggle`, which Claude Code writes into `~/.claude.json` for
//! every session in the folder. A harness that cannot change its tools, or a
//! row that cannot change, is refused.
//!
//! One test function: the tools are read from this process's environment,
//! which every test of a binary shares.

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
use serde_json::{Value, json};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::mpsc;

const FAKE: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
const FAKE_CLAUDE: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_claude.py");

/// What the fake Claude Code's system/init reports besides its own fields:
/// cmux's server (also given by acpmux), two of the user's servers (one
/// already off), a claude.ai connector, cmux's plugin and skill, and one of
/// the user's skills.
fn claude_init() -> Value {
    json!({
        "tools": ["Bash", "mcp__cmux__browser_open", "mcp__github__create_issue"],
        "mcp_servers": [
            {"name": "cmux", "status": "connected"},
            {"name": "github", "status": "connected"},
            {"name": "linear", "status": "disabled"},
            {"name": "claude.ai Foo  (Beta)", "status": "connected"},
        ],
        "plugins": [{"name": "cmux", "path": "/x"}, {"name": "reviewer", "path": "/y"}],
        "skills": ["cmux:cmux-browser", "pdf"],
    })
}

fn hub(control_log: &Path) -> Arc<Hub> {
    let mut cfg: Config = serde_json::from_value(json!({
        "harnesses": {
            "fake": {"argv": ["python3", FAKE]},
            "fakeclaude": {"argv": ["python3", FAKE_CLAUDE], "kind": "claude-stdio",
                           "env": {"FAKE_CLAUDE_INIT": claude_init().to_string(),
                                   "FAKE_CLAUDE_CONTROL_LOG": control_log}},
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

    /// The text streamed for request `id` (sent raw) until its reply.
    async fn reply(&mut self, id: i64) -> String {
        let mut text = String::new();
        loop {
            let line = tokio::time::timeout(Duration::from_secs(30), self.1.recv())
                .await
                .expect("no reply")
                .unwrap();
            let v: Value = serde_json::from_str(&line).unwrap();
            if v.get("id") == Some(&json!(id)) {
                assert!(v.get("error").is_none(), "{v}");
                return text;
            }
            if let Some(t) = v.pointer("/params/update/content/text").and_then(Value::as_str) {
                text.push_str(t);
            }
        }
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

fn assert_summary_without_tools(summary: &Value) {
    assert!(summary.get("tools").is_none(), "summary carries tools: {summary}");
    assert!(summary.get("toolsMutable").is_none(), "summary carries toolsMutable: {summary}");
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

/// The fake Claude Code's argv, which it replies with.
fn argv(said: &str) -> Vec<String> {
    serde_json::from_str(said).unwrap_or_else(|e| panic!("{e}: {said}"))
}

/// The values of each `--disallowedTools`, sorted.
fn disallowed(args: &[String]) -> Vec<String> {
    let mut out: Vec<String> =
        args.windows(2).filter(|w| w[0] == "--disallowedTools").map(|w| w[1].clone()).collect();
    out.sort();
    out
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
    let control_log = root.join("claude-controls.log");
    let hub = hub(&control_log);
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
    // Owner Chief turns use approve-all. A folded coordinator send is allowed
    // by that policy without adding it to the Chief's unconditional tool grants.
    let said =
        local.ask(&acp, "tool-ask: mcp__cmux__acpmux_send coordinator check the build").await;
    assert_eq!(said, "chose yes");
    let info = local.call("_acpmux/info", json!({"sessionId": acp})).await.unwrap();
    assert_eq!(info["toolsMutable"], json!(false), "{info}");
    let cmux_servers = vec![
        row("mcp:cmux-cua", "cmux", "cmux", true, false),
        row("mcp:cmux-subsessions", "cmux", "cmux", true, false),
        row("mcp:cmux-forum", "cmux", "cmux", true, false),
        row("mcp:acpmux", "cmux", "cmux", true, false),
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
    assert_summary_without_tools(&summary);
    let acp_list = local.call("session/list", json!({})).await.unwrap();
    let acp_row = acp_list["sessions"]
        .as_array()
        .unwrap()
        .iter()
        .find(|s| s["sessionId"] == json!(acp))
        .expect("the ACP list includes the session");
    assert_eq!(rows(&acp_row["_meta"]["acpmux"]["tools"]), cmux_servers, "{acp_row}");
    assert_eq!(acp_row["_meta"]["acpmux"]["toolsMutable"], false, "{acp_row}");
    // It cannot change them mid-session: refused, never a silent no-op.
    let refused = local
        .call("_acpmux/set_tools", json!({"sessionId": acp, "id": "mcp:cmux", "enabled": false}))
        .await
        .expect_err("an ACP harness cannot change its tools");
    assert_eq!(reason(&refused), "tools.immutable", "{refused}");
    // Refused from the harness alone: an idle ACP chat is not started for it.
    local.call("session/close", json!({"sessionId": acp})).await.expect("close");
    let refused = local
        .call("_acpmux/set_tools", json!({"sessionId": acp, "id": "mcp:cmux", "enabled": false}))
        .await
        .expect_err("an idle ACP chat cannot change its tools either");
    assert_eq!(reason(&refused), "tools.immutable", "{refused}");
    let info = local.call("_acpmux/info", json!({"sessionId": acp})).await.unwrap();
    assert_eq!(info["status"], json!("closed"), "not started to be refused: {info}");

    // Closed sessions stay listed. Whole lists, pages and the initial watch all
    // omit only the tool inventory; the one-session read keeps every tool.
    assert_eq!(rows(&info["tools"]), cmux_servers);
    for method in ["_acpmux/sessions", "_acpmux/watch"] {
        for params in [json!({}), json!({"limit": 1})] {
            let result = watcher.call(method, params).await.unwrap();
            let listed = result["sessions"].as_array().unwrap();
            assert_eq!(listed.len(), 1);
            assert_eq!(listed[0]["sessionId"], acp);
            assert_eq!(listed[0]["status"], "closed");
            assert_summary_without_tools(&listed[0]);
        }
    }

    // Even trusted peers get compact rows by default. A peer daemon opts in to
    // inventories because its per-session wait cache must keep them up to date.
    let mut peer = client(&hub, Origin::Peer);
    for method in ["_acpmux/sessions", "_acpmux/watch"] {
        let compact = peer.call(method, json!({})).await.unwrap();
        assert_summary_without_tools(&compact["sessions"][0]);
        for params in [json!({"withTools": true}), json!({"withTools": true, "limit": 1})] {
            let full = peer.call(method, params).await.unwrap();
            assert_eq!(rows(&full["sessions"][0]["tools"]), cmux_servers);
            assert_eq!(full["sessions"][0]["toolsMutable"], false);
        }
    }

    // Claude Code: cmux's servers and skills, then what its init reports
    // (cmux's own server and skill and plugin once, the user's after them).
    // linear is off in the user's own Claude config: cmux cannot turn it on.
    let claude = local.new_session("fakeclaude").await;
    assert!(!argv(&local.ask(&claude, "hi").await).contains(&"--disallowedTools".to_owned()));
    let info = local.call("_acpmux/info", json!({"sessionId": claude})).await.unwrap();
    assert_eq!(info["toolsMutable"], json!(true), "{info}");
    assert_eq!(
        rows(&info["tools"]),
        vec![
            row("mcp:cmux-cua", "cmux", "cmux", true, true),
            row("mcp:cmux-subsessions", "cmux", "cmux", true, true),
            row("mcp:cmux-forum", "cmux", "cmux", true, true),
            row("mcp:acpmux", "cmux", "cmux", true, true),
            row("mcp:cmux", "cmux", "cmux", true, true),
            row("skill:cmux:cmux-browser", "cmux", "cmux", true, false),
            row("skill:cmux:cmux-cua", "cmux", "cmux", true, false),
            row("skill:cmux:acpmux", "cmux", "cmux", true, false),
            row("mcp:github", "mcp", "claude", true, true),
            row("mcp:linear", "mcp", "claude", false, false),
            row("mcp:claude.ai Foo  (Beta)", "mcp", "claude", true, true),
            row("plugin:reviewer", "plugin", "claude", true, false),
            row("skill:pdf", "skill", "claude", true, false),
        ],
        "{info}"
    );

    // A per-session attachment keeps the inventory even while the same connection
    // watches the census. Census-only notices omit it.
    let mut census = client(&hub, Origin::Local);
    census.call("_acpmux/watch", json!({})).await.unwrap();
    let attached = watcher.call("_acpmux/attach", json!({"sessionId": claude})).await.unwrap();
    assert_eq!(attached["session"]["tools"], info["tools"]);
    assert_eq!(attached["session"]["toolsMutable"], info["toolsMutable"]);
    let discovered = peer.changed(&claude, "tools").await;
    assert_eq!(discovered["session"]["tools"], info["tools"]);

    // Turn the user's github server off in an idle chat: the row flips,
    // watchers hear it, and Claude Code restarts now (resumed) without it.
    let set = local
        .call(
            "_acpmux/set_tools",
            json!({"sessionId": claude, "id": "mcp:github", "enabled": false}),
        )
        .await
        .expect("set_tools");
    assert_eq!(set["applied"], json!("now"), "{set}");
    assert_summary_without_tools(&census.changed(&claude, "tools").await["session"]);
    let tool = |tools: &Value, id: &str| rows(tools).into_iter().find(|r| r.0 == id).unwrap();
    assert_eq!(tool(&set["tools"], "mcp:github"), row("mcp:github", "mcp", "claude", false, true));
    // The opted-in peer receives the new inventory even without attaching.
    while tool(&peer.changed(&claude, "tools").await["session"]["tools"], "mcp:github").3 {}
    // The first `tools` change is Claude Code's init; then the set's.
    while tool(&watcher.changed(&claude, "tools").await["session"]["tools"], "mcp:github").3 {}
    let args = argv(&local.ask(&claude, "hi").await);
    assert_eq!(disallowed(&args), ["mcp__github"], "{args:?}");
    assert!(args.contains(&"--resume".to_owned()), "the chat resumes: {args:?}");
    // The new process's init reports github connected: the chat's choice stays.
    let info = local.call("_acpmux/info", json!({"sessionId": claude})).await.unwrap();
    assert!(!tool(&info["tools"], "mcp:github").3, "{info}");

    // cmux's computer use server runs behind the cmux server (code mode):
    // turned off, it leaves that server's CMUX_MCP_UPSTREAMS too, since
    // `--disallowedTools mcp__cmux-cua` names no tool there. Then back on.
    let upstreams = |args: &[String]| -> Vec<String> {
        let at = args.iter().position(|a| a == "--mcp-config").expect("--mcp-config");
        let config: Value =
            serde_json::from_str(&std::fs::read_to_string(&args[at + 1]).unwrap()).unwrap();
        let list = config["mcpServers"]["cmux"]["env"]["CMUX_MCP_UPSTREAMS"].as_str().unwrap();
        let list: Value = serde_json::from_str(list).unwrap();
        list.as_array().unwrap().iter().map(|s| s["name"].as_str().unwrap().to_owned()).collect()
    };
    assert!(upstreams(&args).contains(&"cmux-cua".to_owned()), "{args:?}");
    for enabled in [false, true] {
        let set = local
            .call(
                "_acpmux/set_tools",
                json!({"sessionId": claude, "id": "mcp:cmux-cua", "enabled": enabled}),
            )
            .await
            .expect("set_tools");
        assert_eq!(set["applied"], json!("now"), "{set}");
        while tool(&watcher.changed(&claude, "tools").await["session"]["tools"], "mcp:cmux-cua").3
            != enabled
        {}
        let args = argv(&local.ask(&claude, "hi").await);
        let has = upstreams(&args).contains(&"cmux-cua".to_owned());
        assert_eq!(has, enabled, "{args:?}");
    }

    // A skill, or a server the user's own config turned off, cannot be
    // changed here, and an unknown id is not found.
    for id in ["skill:cmux:cmux-browser", "mcp:linear"] {
        let fixed = local
            .call("_acpmux/set_tools", json!({"sessionId": claude, "id": id, "enabled": true}))
            .await
            .expect_err("a fixed row");
        assert_eq!(reason(&fixed), "tools.fixed", "{id}: {fixed}");
    }
    let unknown = local
        .call("_acpmux/set_tools", json!({"sessionId": claude, "id": "mcp:nope", "enabled": true}))
        .await
        .expect_err("no such tool");
    assert_eq!(unknown["code"], json!(-32002), "{unknown}");

    // During a turn the choice is recorded and applies when the turn ends.
    let mut app = client(&hub, Origin::LocalApp);
    let gate = root.join("turn-gate");
    let hold = format!("hold: {}", gate.display());
    let held = json!({"sessionId": claude, "prompt": [{"type": "text", "text": hold}]});
    local.0.send(Message::request(900, "session/prompt", held).to_line()).await.unwrap();
    while app.call("_acpmux/info", json!({"sessionId": claude})).await.unwrap()["turn"].is_null() {
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    let set = app
        .call("_acpmux/set_tools", json!({"sessionId": claude, "id": "mcp:cmux", "enabled": false}))
        .await
        .expect("set_tools during a turn");
    assert_eq!(set["applied"], json!("afterTurn"), "{set}");
    assert!(!tool(&set["tools"], "mcp:cmux").3, "{set}");
    std::fs::write(&gate, "").unwrap();
    let said = local.reply(900).await;
    assert_eq!(disallowed(&argv(&said)), ["mcp__github"], "the turn's process ran on: {said}");
    let args = argv(&local.ask(&claude, "hi").await);
    assert_eq!(
        disallowed(&args),
        ["mcp__cmux", "mcp__github"],
        "the next turn restarted: {args:?}"
    );

    // Both choices survive a respawn.
    local.call("session/close", json!({"sessionId": claude})).await.expect("close");
    let args = argv(&local.ask(&claude, "hi").await);
    assert_eq!(disallowed(&args), ["mcp__cmux", "mcp__github"], "{args:?}");
    let info = local.call("_acpmux/info", json!({"sessionId": claude})).await.unwrap();
    assert!(!tool(&info["tools"], "mcp:cmux").3 && !tool(&info["tools"], "mcp:github").3);

    // The app's pane may set them; a remote browser may not (turning an MCP
    // server on runs the command it names on this machine).
    let on = json!({"sessionId": claude, "id": "mcp:github", "enabled": true});
    let remote = client(&hub, Origin::Web)
        .call("_acpmux/set_tools", on.clone())
        .await
        .expect_err("a remote browser cannot set tools");
    assert_eq!(reason(&remote), "tools.remote", "{remote}");
    let set = app.call("_acpmux/set_tools", on).await.expect("the app's pane turns it back on");
    assert_eq!(set["applied"], json!("now"), "{set}");
    assert!(tool(&set["tools"], "mcp:github").3, "{set}");
    let args = argv(&local.ask(&claude, "hi").await);
    assert_eq!(disallowed(&args), ["mcp__cmux"], "{args:?}");

    // A claude.ai connector, in Claude Code's spelling of its name: other
    // characters become `_`, then runs of `_` collapse and the ends trim.
    let connector =
        json!({"sessionId": claude, "id": "mcp:claude.ai Foo  (Beta)", "enabled": false});
    let set = app.call("_acpmux/set_tools", connector).await.expect("turn the connector off");
    assert_eq!(set["applied"], json!("now"), "{set}");
    let args = argv(&local.ask(&claude, "hi").await);
    assert_eq!(disallowed(&args), ["mcp__claude_ai_Foo_Beta", "mcp__cmux"], "{args:?}");

    // Claude Code was never sent mcp_toggle (it persists to ~/.claude.json).
    let controls = std::fs::read_to_string(&control_log).unwrap();
    assert!(controls.lines().any(|c| c == "initialize"), "{controls}");
    assert!(!controls.lines().any(|c| c == "mcp_toggle"), "{controls}");

    // The daemon's switch: a new session lists none of cmux's tools.
    // SAFETY: as above; no session is starting concurrently.
    unsafe { std::env::set_var("ACPMUX_AGENT_TOOLS", "0") };
    let off = local.new_session("fake").await;
    let info = local.call("_acpmux/info", json!({"sessionId": off})).await.unwrap();
    assert_eq!(info["tools"], json!([]), "{info}");

    let _ = std::fs::remove_dir_all(&root);
}
