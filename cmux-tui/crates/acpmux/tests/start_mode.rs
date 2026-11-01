//! A new agent chat starts in the harness's full-access mode (Claude Code
//! `bypassPermissions`, the Codex bridge `agent-full-access`) unless the
//! setting `defaultPermissionMode` chooses another; a mode picked in a chat
//! holds for that chat only, also after a daemon restart (Leo 2026-10-21); a
//! Web chat never starts in full access, and an unauthenticated connection
//! gets nothing (cx-wx93i; Lawrence 2026-10-14).
//! Driven through the protocol handler, as the app pane, the unix socket and
//! the Web connect.

// Unix only until the Windows port runs the daemon (cmux::local_socket).
#![cfg(unix)]

#[path = "support/daemon_env.rs"]
mod daemon_env;
// This process runs stand-in agents (the fake agents under tests/).
const HERMETIC: daemon_env::Process = daemon_env::Process::stand_in();

use acpmux::config::{Config, ProfileSources, StoreMode};
use acpmux::hub::Hub;
use acpmux::rpc::Message;
use acpmux::server::{ConnAuth, Origin, serve_connection_authed};
use serde_json::{Value, json};
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::mpsc;

/// 32 bytes as hex: the person key the app makes at each launch.
const KEY: &str = "5e1f0c2a9b8d7e6f5a4b3c2d1e0f9a8b7c6d5e4f3a2b1c0d9e8f7a6b5c4d3e2f";

const FAKE_AGENT: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
const FAKE_CLAUDE: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_claude.py");
const FAKE_APP_SERVER: &str =
    concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_codex_app_server.py");

/// A home with three harnesses: `claude` (Claude Code over stdio, the fake),
/// `codex` (a program named `codex` run as `codex app-server`, bridged in
/// process) and `plain` (an ACP agent with no full-access mode). `extra`
/// is merged into config.json.
fn home(name: &str, extra: Value) -> PathBuf {
    let dir = std::env::temp_dir().join(format!("acpmux-start-mode-{name}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(dir.join("work")).unwrap();
    let dir = std::fs::canonicalize(&dir).unwrap();
    let codex = dir.join("bin").join("codex");
    std::fs::create_dir_all(codex.parent().unwrap()).unwrap();
    std::fs::write(
        &codex,
        format!("#!/bin/sh\nexec python3 {} \"$@\"\n", daemon_env::sh_quote(FAKE_APP_SERVER)),
    )
    .unwrap();
    std::fs::set_permissions(&codex, std::fs::Permissions::from_mode(0o755)).unwrap();
    let mut config = json!({
        "harnesses": {
            "claude": {"argv": ["python3", FAKE_CLAUDE], "kind": "claude-stdio"},
            "codex": {"argv": [codex, "app-server"]},
            "plain": {"argv": ["python3", FAKE_AGENT]},
        },
        "defaultHarness": "codex",
        "permissionPolicy": "ask",
        "webRoots": [dir.join("work")],
    });
    for (k, v) in extra.as_object().unwrap() {
        config[k] = v.clone();
    }
    std::fs::write(dir.join("config.json"), serde_json::to_vec_pretty(&config).unwrap()).unwrap();
    dir
}

/// The daemon as it starts: config.json read from disk.
fn hub(dir: &Path) -> Arc<Hub> {
    hub_with(dir, |_| {})
}

/// The daemon as it starts, with `edit` applied to its loaded config.
fn hub_with(dir: &Path, edit: impl FnOnce(&mut Config)) -> Arc<Hub> {
    let mut cfg =
        Config::load_from_with(&dir.join("config.json"), &ProfileSources::none()).unwrap();
    cfg.store.mode = StoreMode::Memory;
    edit(&mut cfg);
    let store = acpmux::store::open(&cfg.store, Path::new("/nonexistent")).unwrap();
    Hub::new(cfg, store)
}

/// The connection, its last request id and the notifications it got.
struct Client(mpsc::Sender<String>, mpsc::Receiver<String>, i64, Vec<Value>);

impl Client {
    fn new(hub: &Arc<Hub>, origin: Origin, auth: ConnAuth) -> Self {
        let (in_tx, in_rx) = mpsc::channel(64);
        let (out_tx, out_rx) = mpsc::channel(4096);
        tokio::spawn(serve_connection_authed(hub.clone(), in_rx, out_tx, origin, auth));
        Client(in_tx, out_rx, 0, Vec::new())
    }

    /// The app's agent pane: a LocalApp connection that proved this
    /// launch's person key (`hub/person.rs`), as the app's pane does.
    async fn app(hub: &Arc<Hub>) -> Self {
        hub.person.enroll(KEY, true).unwrap();
        let mut c = Self::new(hub, Origin::LocalApp, ConnAuth::LocalApp);
        let r = c.call("initialize", json!({"protocolVersion": 1})).await;
        let challenge = &r["result"]["_meta"]["acpmux"]["personChallenge"];
        let proof = acpmux::hub::person::person_proof(
            KEY,
            acpmux::hub::person::TRANSPORT_APP,
            challenge["nonce"].as_str().unwrap_or_else(|| panic!("{r}")),
            challenge["connection"].as_str().unwrap(),
        )
        .unwrap();
        let r = c.call("_acpmux/person_prove", json!({"proof": proof})).await;
        assert!(r.get("error").is_none(), "{r}");
        c
    }

    async fn call(&mut self, m: &str, params: Value) -> Value {
        self.2 += 1;
        let id = self.2;
        self.0.send(Message::request(id, m, params).to_line()).await.unwrap();
        loop {
            let line = tokio::time::timeout(Duration::from_secs(30), self.1.recv())
                .await
                .expect("an answer in time")
                .expect("the connection stays open");
            let v: Value = serde_json::from_str(&line).unwrap();
            if v.get("id") == Some(&json!(id)) {
                return v;
            }
            if v.get("id").is_none() {
                self.3.push(v);
            }
        }
    }

    /// A new chat on `harness`: the whole reply.
    async fn new_chat(&mut self, dir: &Path, harness: &str) -> Value {
        let params = json!({"cwd": dir.join("work"), "mcpServers": [], "_meta": {"acpmux": {"harness": harness}}});
        self.call("session/new", params).await
    }

    /// A new chat on `harness`: its id and the mode it runs in.
    async fn chat(&mut self, dir: &Path, harness: &str) -> (String, String) {
        let r = self.new_chat(dir, harness).await;
        let id = r["result"]["sessionId"].as_str().unwrap_or_else(|| panic!("{r}")).to_owned();
        (id.clone(), self.mode(&id).await)
    }

    /// The mode the chat runs in, as `session/load` reports it now.
    async fn mode(&mut self, id: &str) -> String {
        let r = self.call("_acpmux/info", json!({"sessionId": id})).await;
        let mode = r["result"]["modes"]["currentModeId"].as_str().map(str::to_owned);
        mode.unwrap_or_else(|| panic!("no mode: {r}"))
    }
}

/// config.json's `lastPermissionMode`, where an older build saved the latest
/// mode pick as every new chat's start mode. Never written now.
fn last_pick(dir: &Path) -> Value {
    let config: Value =
        serde_json::from_slice(&std::fs::read(dir.join("config.json")).unwrap()).unwrap();
    config["lastPermissionMode"].clone()
}

#[tokio::test]
async fn a_new_chat_starts_in_each_harness_full_access_mode() {
    let dir = home("full", json!({"defaultPermissionMode": "fullAccess"}));
    let daemon = hub(&dir);
    let mut app = Client::app(&daemon).await;

    let (claude, mode) = app.chat(&dir, "claude").await;
    assert_eq!(mode, "bypassPermissions");
    // Claude Code was launched so that it accepts the mode (the fake, like
    // Claude Code, refuses it without --allow-dangerously-skip-permissions).
    let r = app
        .call(
            "session/prompt",
            json!({"sessionId": claude, "prompt": [{"type": "text", "text": "hi"}]}),
        )
        .await;
    assert!(r.get("error").is_none(), "{r}");
    let (_, mode) = app.chat(&dir, "codex").await;
    assert_eq!(mode, "agent-full-access");
    // A harness without a full-access mode keeps its own.
    let (_, mode) = app.chat(&dir, "plain").await;
    assert_eq!(mode, "normal");
    // The daemon set it: nothing was saved as a pick.
    assert_eq!(last_pick(&dir), Value::Null);
    let _ = std::fs::remove_dir_all(&dir);
}

/// A mode picked in a chat holds for that chat only: new chats, on every
/// harness and after a restart, start in the default (Leo 2026-10-21: "the
/// default for new chats != whatever u just temp set in an existing running
/// chat").
#[tokio::test]
async fn a_pick_in_a_chat_holds_for_that_chat_and_new_chats_start_in_the_default() {
    let dir = home("pick", json!({"defaultPermissionMode": "fullAccess"}));
    let daemon = hub(&dir);
    let mut app = Client::app(&daemon).await;
    let (claude, _) = app.chat(&dir, "claude").await;
    let (codex, _) = app.chat(&dir, "codex").await;

    // The person switches the Claude chat back to a mode that asks: that chat
    // asks; the Codex chat and every new chat stay in full access.
    let r = app.call("session/set_mode", json!({"sessionId": claude, "modeId": "default"})).await;
    assert!(r.get("error").is_none(), "{r}");
    assert_eq!(app.mode(&claude).await, "default");
    assert_eq!(app.mode(&codex).await, "agent-full-access");
    assert_eq!(app.chat(&dir, "codex").await.1, "agent-full-access");
    assert_eq!(app.chat(&dir, "claude").await.1, "bypassPermissions");
    let r = app.call("session/set_mode", json!({"sessionId": codex, "modeId": "agent"})).await;
    assert!(r.get("error").is_none(), "{r}");
    assert_eq!(app.mode(&codex).await, "agent");
    assert_eq!(last_pick(&dir), Value::Null);
    drop(app);
    drop(daemon);

    // After a restart (config.json read again) new chats start in the default too.
    let daemon = hub(&dir);
    let mut app = Client::app(&daemon).await;
    assert_eq!(app.chat(&dir, "codex").await.1, "agent-full-access");
    let answer = start_mode(&mut app, &dir, "claude").await;
    assert_eq!(answer["modeId"], "bypassPermissions", "{answer}");
    assert_eq!(answer["source"], "config", "{answer}");
    assert_eq!(app.chat(&dir, "claude").await.1, "bypassPermissions");

    // A unix socket client (an agent, a script) cannot widen a chat to full
    // access.
    let mut agent = Client::new(&daemon, Origin::Local, ConnAuth::LocalSocket);
    let (chat, _) = agent.chat(&dir, "claude").await;
    let r = agent.call("session/set_mode", json!({"sessionId": chat, "modeId": "default"})).await;
    assert!(r.get("error").is_none(), "{r}");
    let r = agent.call("session/set_mode", json!({"sessionId": chat, "modeId": "auto"})).await;
    assert_eq!(r["error"]["data"]["reason"], "permission.person_required", "{r}");
    assert_eq!(last_pick(&dir), Value::Null);
    let _ = std::fs::remove_dir_all(&dir);
}

/// acp-chief-issues.md #15 (2026-10-19 u1976): the Chief asked a headless
/// `acpmux new --mode bypassPermissions` (then auto, acceptEdits) for a
/// nightly job; each was refused with person_required, and the refusal
/// sent it to the app or a preset, so it gave up. A script can still start
/// a chat headless with no mode at all: it then runs in the person's own
/// start mode. The refusal must say so, and that start must work.
#[tokio::test]
async fn a_refused_headless_mode_start_names_the_start_without_a_mode() {
    let dir = home("headless", json!({"defaultPermissionMode": "fullAccess"}));
    let daemon = hub(&dir);
    let mut script = Client::new(&daemon, Origin::Local, ConnAuth::LocalSocket);
    let params = json!({"cwd": dir.join("work"), "mcpServers": [],
        "_meta": {"acpmux": {"harness": "claude", "mode": "bypassPermissions"}}});
    let r = script.call("session/new", params).await;
    assert_eq!(r["error"]["data"]["reason"], "permission.person_required", "{r}");
    let message = r["error"]["message"].as_str().unwrap_or_default();
    assert!(message.contains("without --mode"), "{message}");
    // That start, with no mode, works headless in the person's start mode.
    let (_, mode) = script.chat(&dir, "claude").await;
    assert_eq!(mode, "bypassPermissions");
    let _ = std::fs::remove_dir_all(&dir);
}

#[tokio::test]
async fn the_setting_chooses_ask_or_the_harness_own_mode() {
    let dir = home("ask", json!({"defaultPermissionMode": "ask"}));
    let daemon = hub(&dir);
    let mut app = Client::app(&daemon).await;
    assert_eq!(app.chat(&dir, "claude").await.1, "default");
    assert_eq!(app.chat(&dir, "codex").await.1, "ask");
    drop(app);
    drop(daemon);

    let dir = home("standard", json!({"defaultPermissionMode": "standard"}));
    let daemon = hub(&dir);
    let mut app = Client::app(&daemon).await;
    assert_eq!(app.chat(&dir, "claude").await.1, "default");
    assert_eq!(app.chat(&dir, "codex").await.1, "agent");
    let _ = std::fs::remove_dir_all(&dir);
}

#[tokio::test]
async fn a_web_chat_never_starts_in_full_access_and_an_unauthenticated_one_gets_none() {
    let dir = home("web", json!({"defaultPermissionMode": "fullAccess"}));
    let daemon = hub(&dir);
    let mut web = Client::new(&daemon, Origin::Web, ConnAuth::ListenerToken);
    let (_, mode) = web.chat(&dir, "codex").await;
    // A phone starts Codex in its asking mode, never in the bridge's own
    // default `agent` (61bdd4de942, `web_modes::BRIDGE_ASKING_MODES`).
    assert_eq!(mode, "ask", "a Web chat starts Codex in its asking mode");
    let mut none = Client::new(&daemon, Origin::Web, ConnAuth::None);
    let r = none.new_chat(&dir, "codex").await;
    assert_eq!(r["error"]["code"], json!(acpmux::server::conn_auth::UNAUTHENTICATED), "{r}");

    let _ = std::fs::remove_dir_all(&dir);
}

/// `_acpmux/start_mode`: the mode acpmux would start a plain new chat on
/// `harness` in, as this connection asks it.
async fn start_mode(c: &mut Client, dir: &Path, harness: &str) -> Value {
    let r =
        c.call("_acpmux/start_mode", json!({"harness": harness, "cwd": dir.join("work")})).await;
    assert!(r.get("error").is_none(), "{r}");
    r["result"].clone()
}

#[tokio::test]
async fn start_mode_answer_is_the_mode_a_new_chat_then_starts_in() {
    let dir = home("answer", json!({"defaultPermissionMode": "fullAccess"}));
    let daemon = hub(&dir);
    let mut app = Client::app(&daemon).await;

    // Before any chat: full access, from config.json.
    let answer = start_mode(&mut app, &dir, "claude").await;
    assert_eq!(answer["modeId"], "bypassPermissions", "{answer}");
    assert_eq!(answer["name"], "Bypass permissions", "{answer}");
    assert_eq!(answer["level"], "fullAccess", "{answer}");
    assert_eq!(answer["source"], "config", "{answer}");
    assert_eq!(app.chat(&dir, "claude").await.1, "bypassPermissions");
    // A harness with no full-access mode keeps its own: no prediction.
    assert_eq!(start_mode(&mut app, &dir, "plain").await["modeId"], Value::Null);

    // The person picks Manual in a chat: the answer, and the next new chat,
    // stay in the default.
    let (claude, _) = app.chat(&dir, "claude").await;
    let r = app.call("session/set_mode", json!({"sessionId": claude, "modeId": "default"})).await;
    assert!(r.get("error").is_none(), "{r}");
    let answer = start_mode(&mut app, &dir, "claude").await;
    assert_eq!(answer["modeId"], "bypassPermissions", "{answer}");
    assert_eq!(answer["level"], "fullAccess", "{answer}");
    assert_eq!(answer["source"], "config", "{answer}");
    assert_eq!(app.chat(&dir, "claude").await.1, "bypassPermissions");

    // Asking changes nothing.
    assert_eq!(last_pick(&dir), Value::Null);
    let _ = std::fs::remove_dir_all(&dir);
}

#[tokio::test]
async fn start_mode_answer_ignores_picks_in_preset_and_remote_chats() {
    let dir = home(
        "answer-skip",
        json!({"defaultPermissionMode": "fullAccess", "presets": {"p": {"harness": "claude"}}}),
    );
    let daemon = hub(&dir);
    let mut app = Client::app(&daemon).await;

    // A preset's chat: its pick is no start mode, and its own start is none.
    let r = app
        .call(
            "session/new",
            json!({"cwd": dir.join("work"), "mcpServers": [], "_meta": {"acpmux": {"preset": "p"}}}),
        )
        .await;
    let preset = r["result"]["sessionId"].as_str().unwrap_or_else(|| panic!("{r}")).to_owned();
    let r = app.call("session/set_mode", json!({"sessionId": preset, "modeId": "default"})).await;
    assert!(r.get("error").is_none(), "{r}");
    let r = app
        .call(
            "_acpmux/start_mode",
            json!({"harness": "claude", "preset": "p", "cwd": dir.join("work")}),
        )
        .await;
    assert_eq!(r["result"]["modeId"], Value::Null, "{r}");

    // A Web chat viewed in the app: its pick is no start mode either. (Codex: a
    // remote chain runs Claude Code only inside the macOS sandbox.)
    let mut web = Client::new(&daemon, Origin::Web, ConnAuth::ListenerToken);
    let (remote, _) = web.chat(&dir, "codex").await;
    let r = app.call("session/set_mode", json!({"sessionId": remote, "modeId": "ask"})).await;
    assert!(r.get("error").is_none(), "{r}");

    assert_eq!(last_pick(&dir), Value::Null);
    let answer = start_mode(&mut app, &dir, "claude").await;
    assert_eq!(answer["modeId"], "bypassPermissions", "{answer}");
    assert_eq!(app.chat(&dir, "claude").await.1, "bypassPermissions");
    // The Web asks for its own context: acpmux sets no start mode there.
    assert_eq!(start_mode(&mut web, &dir, "codex").await["modeId"], Value::Null);
    let _ = std::fs::remove_dir_all(&dir);
}

impl Client {
    /// Whether a `_acpmux/start_mode_changed` came, after one more round trip
    /// (a notification sent before it has arrived by then).
    async fn told_start_mode_changed(&mut self) -> bool {
        self.call("_acpmux/status", json!({})).await;
        let told = self.3.iter().any(|n| n["method"] == "_acpmux/start_mode_changed");
        self.3.clear();
        told
    }
}

#[tokio::test]
async fn start_mode_answer_change_is_announced_to_local_watchers() {
    let dir = home("answer-notice", json!({"defaultPermissionMode": "fullAccess"}));
    let daemon = hub(&dir);
    let mut app = Client::app(&daemon).await;
    let r = app.call("_acpmux/watch", json!({"enabled": true})).await;
    assert!(r.get("error").is_none(), "{r}");
    let mut web = Client::new(&daemon, Origin::Web, ConnAuth::ListenerToken);
    let r = web.call("_acpmux/watch", json!({"enabled": true})).await;
    assert!(r.get("error").is_none(), "{r}");
    let (claude, _) = app.chat(&dir, "claude").await;
    app.3.clear();

    // A pick in a chat changes no new chat's start mode: no notice.
    let r = app.call("session/set_mode", json!({"sessionId": claude, "modeId": "default"})).await;
    assert!(r.get("error").is_none(), "{r}");
    assert!(!app.told_start_mode_changed().await);
    // A new default in config.json, read at a catalog reload: a pane showing
    // a pending chat asks again.
    let path = dir.join("config.json");
    let mut config: Value = serde_json::from_slice(&std::fs::read(&path).unwrap()).unwrap();
    config["defaultPermissionMode"] = json!("ask");
    std::fs::write(&path, serde_json::to_vec_pretty(&config).unwrap()).unwrap();
    daemon.reload_catalog().await.unwrap();
    assert!(app.told_start_mode_changed().await, "the local watcher is told");
    assert!(!web.told_start_mode_changed().await, "a Web watcher's chats get no start mode");
    assert_eq!(app.chat(&dir, "claude").await.1, "default");
    let _ = std::fs::remove_dir_all(&dir);
}

/// A trusted, enabled folder profile `acme` in `dir/work/repo`, with its
/// records under `dir` (never the user's own).
fn folder_profile(dir: &Path) -> (PathBuf, acpmux::config::folder_profiles::FolderGate) {
    use acpmux::config::folder_profiles;
    let repo = dir.join("work").join("repo");
    let profiles = folder_profiles::profile_dir(&repo);
    std::fs::create_dir_all(&profiles).unwrap();
    let path = profiles.join("acme.toml");
    std::fs::write(
        &path,
        format!("schema = 1\nid = \"acme\"\ncommand = \"python3\"\nargs = [{FAKE_AGENT:?}]\n"),
    )
    .unwrap();
    std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600)).unwrap();
    let gate = folder_profiles::FolderGate {
        enable_record: dir.join("records").join(folder_profiles::ENABLE_RECORD),
        trust: acpmux::trust::Paths {
            claude_json: dir.join("records").join("claude.json"),
            codex_config: dir.join("records").join("config.toml"),
            record: dir.join("records").join("trust.json"),
            agent_home: None,
            cmux_worktrees: None,
        },
    };
    (repo, gate)
}

#[tokio::test]
async fn start_mode_answer_never_resolves_a_remote_callers_folder() {
    let dir = home("answer-web-folder", json!({"defaultPermissionMode": "fullAccess"}));
    let (repo, gate) = folder_profile(&dir);
    let daemon = hub_with(&dir, |cfg| cfg.folder_gate = Some(gate));
    let mut web = Client::new(&daemon, Origin::Web, ConnAuth::ListenerToken);
    // A folder profile's name in a folder with one: the plain null answer,
    // no error that names the folder or the file.
    for harness in ["acme", "claude"] {
        let r = web.call("_acpmux/start_mode", json!({"harness": harness, "cwd": repo})).await;
        assert!(r.get("error").is_none(), "{r}");
        assert_eq!(
            r["result"],
            json!({"harness": null, "modeId": null, "name": null, "level": null, "source": null}),
            "{r}"
        );
    }
    let _ = std::fs::remove_dir_all(&dir);
}

#[tokio::test]
async fn start_mode_answer_for_folder_pinned_and_unknown_harnesses() {
    let pinned = json!({"argv": ["python3", FAKE_CLAUDE, "--permission-mode", "default"], "kind": "claude-stdio"});
    let dir = home("answer-kinds", json!({"defaultPermissionMode": "fullAccess"}));
    let mut config: Value =
        serde_json::from_slice(&std::fs::read(dir.join("config.json")).unwrap()).unwrap();
    config["harnesses"]["pinned"] = pinned;
    std::fs::write(dir.join("config.json"), serde_json::to_vec_pretty(&config).unwrap()).unwrap();
    let (repo, gate) = folder_profile(&dir);
    acpmux::trust::set(&gate.trust, &repo.to_string_lossy(), "trusted").unwrap();
    let enabled = Config { folder_gate: Some(gate.clone()), ..Default::default() };
    let sha = acpmux::config::folder_profiles::load_one(&enabled, &gate, &repo, "acme")
        .and_then(|fp| fp.sha256)
        .expect("sha256");
    acpmux::config::folder_profiles::enable(&enabled, &gate, &repo, "acme", &sha).unwrap();
    let daemon = hub_with(&dir, |cfg| cfg.folder_gate = Some(gate));
    let mut app = Client::app(&daemon).await;

    // A folder profile's chat gets no start mode.
    let r = app.call("_acpmux/start_mode", json!({"harness": "acme", "cwd": repo})).await;
    assert!(r.get("error").is_none(), "{r}");
    assert_eq!(r["result"]["harness"], "acme", "{r}");
    assert_eq!(r["result"]["modeId"], Value::Null, "{r}");
    // A profile that pins its mode in argv: none either.
    let answer = start_mode(&mut app, &dir, "pinned").await;
    assert_eq!(answer["modeId"], Value::Null, "{answer}");
    assert_eq!(answer["level"], Value::Null, "{answer}");
    // Codex before any chat of it: the level, but no mode id yet.
    let answer = start_mode(&mut app, &dir, "codex").await;
    assert_eq!(answer["modeId"], Value::Null, "{answer}");
    assert_eq!(answer["level"], "fullAccess", "{answer}");
    assert_eq!(answer["source"], "config", "{answer}");
    // After one, its full-access mode.
    assert_eq!(app.chat(&dir, "codex").await.1, "agent-full-access");
    assert_eq!(start_mode(&mut app, &dir, "codex").await["modeId"], "agent-full-access");
    let _ = std::fs::remove_dir_all(&dir);
}

impl Client {
    /// A new chat on `harness` with acpmux permission policy `policy`: its id and its mode.
    async fn chat_with_policy(
        &mut self,
        dir: &Path,
        harness: &str,
        policy: &str,
    ) -> (String, String) {
        let params = json!({"cwd": dir.join("work"), "mcpServers": [],
            "_meta": {"acpmux": {"harness": harness, "policy": policy}}});
        let r = self.call("session/new", params).await;
        let id = r["result"]["sessionId"].as_str().unwrap_or_else(|| panic!("{r}")).to_owned();
        (id.clone(), self.mode(&id).await)
    }

    /// The `policy_unenforced` records of chat `id`.
    async fn unenforced(&mut self, id: &str) -> Vec<Value> {
        let r = self
            .call("_acpmux/events", json!({"sessionId": id, "kinds": ["policy_unenforced"]}))
            .await;
        r["result"]["events"].as_array().cloned().unwrap_or_else(|| panic!("{r}"))
    }
}

/// A chat started with a policy narrower than approve-all runs in its harness's mode that asks,
/// whatever the start level: in full access (Codex approval never + danger-full-access, Claude
/// Code bypassPermissions) the harness never asks, so the policy would answer nothing.
#[tokio::test]
async fn a_chat_with_a_narrower_policy_starts_in_the_mode_that_keeps_it() {
    let dir = home("policy", json!({"defaultPermissionMode": "fullAccess"}));
    let daemon = hub(&dir);
    let mut app = Client::app(&daemon).await;
    for (policy, codex, claude) in [
        ("ask", "ask", "default"),
        ("approve-reads", "ask", "default"),
        ("approve-edits", "ask", "default"),
        ("deny-all", "read-only", "default"),
        ("approve-all", "agent-full-access", "bypassPermissions"),
    ] {
        let (id, mode) = app.chat_with_policy(&dir, "codex", policy).await;
        assert_eq!(mode, codex, "codex, {policy}");
        assert!(app.unenforced(&id).await.is_empty(), "codex, {policy}");
        let (id, mode) = app.chat_with_policy(&dir, "claude", policy).await;
        assert_eq!(mode, claude, "claude, {policy}");
        assert!(app.unenforced(&id).await.is_empty(), "claude, {policy}");
    }
    // A chat with no policy of its own still starts in the start level.
    assert_eq!(app.chat(&dir, "codex").await.1, "agent-full-access");
    // A harness with no mode that asks cannot keep the policy: the chat says so.
    let (id, mode) = app.chat_with_policy(&dir, "plain", "approve-reads").await;
    assert_eq!(mode, "normal");
    let notes = app.unenforced(&id).await;
    assert_eq!(notes.len(), 1, "{notes:?}");
    assert_eq!(notes[0]["msg"]["policy"], "approve-reads", "{notes:?}");
    let _ = std::fs::remove_dir_all(&dir);
}

/// A narrower policy set on a live chat moves a mode that does not ask to the policy's; a mode
/// as narrow stays, and a wider policy changes no mode.
#[tokio::test]
async fn a_narrower_policy_on_a_live_chat_leaves_full_access() {
    let dir = home("policy-live", json!({"defaultPermissionMode": "fullAccess"}));
    let daemon = hub(&dir);
    let mut app = Client::app(&daemon).await;
    let (codex, mode) = app.chat(&dir, "codex").await;
    assert_eq!(mode, "agent-full-access");
    let r = app
        .call("_acpmux/set_policy", json!({"sessionId": codex, "policy": "approve-reads"}))
        .await;
    assert!(r.get("error").is_none(), "{r}");
    assert_eq!(app.mode(&codex).await, "ask");
    let r = app.call("_acpmux/set_policy", json!({"sessionId": codex, "policy": "deny-all"})).await;
    assert!(r.get("error").is_none(), "{r}");
    assert_eq!(app.mode(&codex).await, "read-only");
    let r =
        app.call("_acpmux/set_policy", json!({"sessionId": codex, "policy": "approve-all"})).await;
    assert!(r.get("error").is_none(), "{r}");
    assert_eq!(app.mode(&codex).await, "read-only");

    let (claude, _) = app.chat(&dir, "claude").await;
    let r = app.call("session/set_mode", json!({"sessionId": claude, "modeId": "plan"})).await;
    assert!(r.get("error").is_none(), "{r}");
    let r = app.call("_acpmux/set_policy", json!({"sessionId": claude, "policy": "ask"})).await;
    assert!(r.get("error").is_none(), "{r}");
    assert_eq!(app.mode(&claude).await, "plan");
    let _ = std::fs::remove_dir_all(&dir);
}

/// A narrower policy set on a chat whose agent is not running starts no agent: the chat keeps it
/// as its saved mode, which its next start restores.
#[tokio::test]
async fn a_narrower_policy_on_a_stopped_chat_starts_no_agent() {
    let dir = home("policy-stopped", json!({"defaultPermissionMode": "fullAccess"}));
    let daemon = hub(&dir);
    let mut app = Client::app(&daemon).await;
    let (codex, mode) = app.chat(&dir, "codex").await;
    assert_eq!(mode, "agent-full-access");
    let r = app.call("_acpmux/kill", json!({"sessionId": codex})).await;
    assert!(r.get("error").is_none(), "{r}");
    let r = app
        .call("_acpmux/set_policy", json!({"sessionId": codex, "policy": "approve-reads"}))
        .await;
    assert!(r.get("error").is_none(), "{r}");
    let info = app.call("_acpmux/info", json!({"sessionId": codex})).await;
    assert_eq!(info["result"]["status"], "closed", "{info}");
    assert_eq!(app.mode(&codex).await, "ask");
    // The next start keeps it: the bridge's `mode` config option, replayed after the mode,
    // does not bring full access back.
    let r = app
        .call(
            "session/prompt",
            json!({"sessionId": codex, "prompt": [{"type": "text", "text": "hi"}]}),
        )
        .await;
    assert!(r.get("error").is_none(), "{r}");
    assert_eq!(app.mode(&codex).await, "ask");
    let _ = std::fs::remove_dir_all(&dir);
}

/// A chat whose agent starts outside the plain new-chat path (a preset's, a folder profile's, a
/// handoff target that keeps the harness's mode, a resumed chat) still runs in the mode its
/// narrower policy needs: the policy is held where every agent starts, not only on `session/new`.
#[tokio::test]
async fn a_preset_chat_with_a_narrower_policy_starts_in_the_mode_that_keeps_it() {
    let dir = home(
        "policy-preset",
        json!({"defaultPermissionMode": "fullAccess", "presets": {"reads": {"harness": "codex", "policy": "approve-reads"}}}),
    );
    let daemon = hub(&dir);
    let mut app = Client::app(&daemon).await;
    let r = app
        .call(
            "session/new",
            json!({"cwd": dir.join("work"), "mcpServers": [], "_meta": {"acpmux": {"preset": "reads"}}}),
        )
        .await;
    let id = r["result"]["sessionId"].as_str().unwrap_or_else(|| panic!("{r}")).to_owned();
    assert_eq!(app.mode(&id).await, "ask");
    let _ = std::fs::remove_dir_all(&dir);
}

/// A policy acpmux sets itself (an aside's deny-all, a handoff target narrowed to its source)
/// moves the chat out of full access like `_acpmux/set_policy` does: an aside forked from a
/// full-access chat ran its question in full access under deny-all.
#[tokio::test]
async fn a_policy_acpmux_sets_itself_moves_the_chat_out_of_full_access() {
    let dir = home("policy-own", json!({"defaultPermissionMode": "fullAccess"}));
    let daemon = hub(&dir);
    let mut app = Client::app(&daemon).await;
    let (codex, mode) = app.chat(&dir, "codex").await;
    assert_eq!(mode, "agent-full-access");
    let session = daemon.resolve(&codex).unwrap();
    daemon.set_policy(&session, acpmux::config::PermissionPolicy::DenyAll).await;
    assert_eq!(app.mode(&codex).await, "read-only");
    let _ = std::fs::remove_dir_all(&dir);
}

/// deny-all as the default policy (`_acpmux/set_default_policy`) is a lockdown: every chat with
/// no policy of its own leaves full access, live or stopped, and new chats start read-only. The
/// start mode preview says so, and a switch back into a mode that never asks is refused while
/// the policy holds.
#[tokio::test]
async fn deny_all_as_the_default_policy_holds_on_every_chat() {
    let dir = home("policy-default", json!({"defaultPermissionMode": "fullAccess"}));
    let daemon = hub(&dir);
    let mut app = Client::app(&daemon).await;
    let (live, _) = app.chat(&dir, "codex").await;
    let (stopped, _) = app.chat(&dir, "codex").await;
    let r = app.call("_acpmux/kill", json!({"sessionId": stopped})).await;
    assert!(r.get("error").is_none(), "{r}");
    let r = app.call("_acpmux/set_default_policy", json!({"policy": "deny-all"})).await;
    assert!(r.get("error").is_none(), "{r}");
    assert_eq!(app.mode(&live).await, "read-only");
    assert_eq!(app.mode(&stopped).await, "read-only");
    let r = app
        .call(
            "session/prompt",
            json!({"sessionId": stopped, "prompt": [{"type": "text", "text": "hi"}]}),
        )
        .await;
    assert!(r.get("error").is_none(), "{r}");
    assert_eq!(app.mode(&stopped).await, "read-only");
    let (fresh, mode) = app.chat(&dir, "codex").await;
    assert_eq!(mode, "read-only", "{fresh}");
    let r =
        app.call("_acpmux/start_mode", json!({"harness": "codex", "cwd": dir.join("work")})).await;
    assert_eq!(r["result"]["modeId"], "read-only", "{r}");
    assert_eq!(r["result"]["source"], "policy", "{r}");
    let r = app
        .call("session/set_mode", json!({"sessionId": live, "modeId": "agent-full-access"}))
        .await;
    assert_eq!(r["error"]["data"]["reason"], "policy_mode", "{r}");
    assert_eq!(app.mode(&live).await, "read-only");
    let _ = std::fs::remove_dir_all(&dir);
}

/// A Claude Code profile that pins full access in its argv started in it under a narrower policy:
/// its start returned before the policy's mode was held, so it ran every tool without asking.
#[tokio::test]
async fn a_pinned_claude_chat_with_a_narrower_policy_leaves_full_access() {
    let dir = home("policy-pinned", json!({"defaultPermissionMode": "fullAccess"}));
    let mut config: Value =
        serde_json::from_slice(&std::fs::read(dir.join("config.json")).unwrap()).unwrap();
    config["harnesses"]["yolo"] = json!({"argv": ["python3", FAKE_CLAUDE, "--permission-mode",
        "bypassPermissions", "--dangerously-skip-permissions"], "kind": "claude-stdio"});
    std::fs::write(dir.join("config.json"), serde_json::to_vec_pretty(&config).unwrap()).unwrap();
    let daemon = hub(&dir);
    let mut app = Client::app(&daemon).await;
    let (id, _) = app.chat_with_policy(&dir, "yolo", "approve-reads").await;
    let r = app
        .call(
            "session/prompt",
            json!({"sessionId": id, "prompt": [{"type": "text", "text": "hi"}]}),
        )
        .await;
    assert!(r.get("error").is_none(), "{r}");
    assert_eq!(app.mode(&id).await, "default");
    let _ = std::fs::remove_dir_all(&dir);
}

/// The mode `id` runs in once it is `want`, or after 10 s whatever it is: a follow the daemon
/// starts on its own (startup, a move's end) lands a moment later.
async fn mode_soon(app: &mut Client, id: &str, want: &str) -> String {
    let deadline = tokio::time::Instant::now() + Duration::from_secs(10);
    loop {
        let mode = app.mode(id).await;
        if mode == want || tokio::time::Instant::now() > deadline {
            return mode;
        }
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
}

/// A deny-all default skips a chat that is moving; when the move was aborted, the chat kept
/// running in full access under the lockdown.
#[tokio::test]
async fn a_chat_whose_move_aborts_follows_a_deny_all_default_set_meanwhile() {
    let dir = home("policy-move", json!({"defaultPermissionMode": "fullAccess"}));
    let daemon = hub(&dir);
    let mut app = Client::app(&daemon).await;
    let (id, mode) = app.chat(&dir, "codex").await;
    assert_eq!(mode, "agent-full-access");
    // Only the local socket moves a chat.
    let mut mover = Client::new(&daemon, Origin::Local, ConnAuth::LocalSocket);
    let r = mover.call("initialize", json!({"protocolVersion": 1})).await;
    assert!(r.get("error").is_none(), "{r}");
    let begin = mover.call("_acpmux/transfer_begin", json!({"sessionId": id})).await;
    let transfer = begin["result"]["transferId"].clone();
    assert!(transfer.is_string(), "{begin}");
    let r = app.call("_acpmux/set_default_policy", json!({"policy": "deny-all"})).await;
    assert!(r.get("error").is_none(), "{r}");
    assert_eq!(app.mode(&id).await, "agent-full-access", "a moving chat is not touched");
    let r = mover
        .call("_acpmux/transfer_abort", json!({"sessionId": id, "transferId": transfer}))
        .await;
    assert!(r.get("error").is_none(), "{r}");
    assert_eq!(mode_soon(&mut app, &id, "read-only").await, "read-only");
    let _ = std::fs::remove_dir_all(&dir);
}

/// `permissionPolicy: deny-all` in config.json is the same lockdown from the daemon's start: its
/// chats follow it once startup finishes.
#[tokio::test]
async fn deny_all_in_config_holds_on_every_chat_from_startup() {
    let dir = home("policy-startup", json!({"defaultPermissionMode": "fullAccess"}));
    let daemon = hub(&dir);
    let mut app = Client::app(&daemon).await;
    let (id, mode) = app.chat(&dir, "codex").await;
    assert_eq!(mode, "agent-full-access");
    daemon.config.write().await.permission_policy = acpmux::config::PermissionPolicy::DenyAll;
    daemon.finish_startup().await;
    assert_eq!(mode_soon(&mut app, &id, "read-only").await, "read-only");
    let _ = std::fs::remove_dir_all(&dir);
}

/// claude-sr2, 2026-10-25 (item L): "acpmux refuses read-only reviews it should allow": a
/// reviewer started from an agent's shell with `acpmux new -m codex --mode read-only` was refused
/// on the unix socket, because the start gate knew only the Web table's asking modes, which list
/// no Codex mode. The Codex bridge's `ask` asks before every change and its `read-only` only
/// reads (`hub/start_mode.rs` `NARROW_MODES`), so a start in either needs no person. A bridge
/// mode that does not ask still does, and so does the codex-acp adapter's `read-only`, which
/// writes in the workspace without asking (`web_modes::NON_ASKING_MODES`).
#[tokio::test]
async fn the_unix_socket_starts_the_codex_bridge_in_read_only_or_ask() {
    let dir = home("narrow-start", json!({"defaultPermissionMode": "fullAccess"}));
    let daemon = hub_with(&dir, |cfg| {
        let adapter = json!({"argv": ["python3", FAKE_AGENT, "codex-acp"], "family": "codex"});
        cfg.harnesses.insert("adapter".into(), serde_json::from_value(adapter).unwrap());
    });
    let mut agent = Client::new(&daemon, Origin::Local, ConnAuth::LocalSocket);
    let start = |harness: &str, mode: &str| {
        json!({"cwd": dir.join("work"), "mcpServers": [],
            "_meta": {"acpmux": {"harness": harness, "mode": mode}}})
    };
    for mode in ["read-only", "ask"] {
        let r = agent.call("session/new", start("codex", mode)).await;
        let id = r["result"]["sessionId"].as_str().unwrap_or_else(|| panic!("{mode}: {r}"));
        let id = id.to_owned();
        assert_eq!(agent.mode(&id).await, mode);
    }
    for mode in ["agent", "agent-full-access"] {
        let r = agent.call("session/new", start("codex", mode)).await;
        assert_eq!(r["error"]["data"]["reason"], "permission.person_required", "{mode}: {r}");
    }
    let r = agent.call("session/new", start("adapter", "read-only")).await;
    assert_eq!(r["error"]["data"]["reason"], "permission.person_required", "adapter: {r}");
    let _ = std::fs::remove_dir_all(&dir);
}

/// The reviewer of cmux#(this PR), 2026-10-25: "creation-time argv can authorize a different
/// harness after adoption/respawn". An adopt may find a session already running, created on
/// another profile than the one it names now, so it never takes the Codex bridge's `read-only`
/// without the person: a running bridge chat in `ask` that an agent adopts in `read-only` (which
/// runs commands in its sandbox without asking) is refused and stays in `ask`.
#[tokio::test]
async fn an_adopt_never_moves_a_running_bridge_chat_to_read_only() {
    let dir = home("narrow-adopt", json!({"defaultPermissionMode": "fullAccess"}));
    let daemon = hub(&dir);
    let mut agent = Client::new(&daemon, Origin::Local, ConnAuth::LocalSocket);
    let start = |mode: &str, adopt: Option<Value>| {
        let mut acpmux = json!({"harness": "codex", "mode": mode});
        if let Some(adopt) = adopt {
            acpmux["adopt"] = adopt;
        }
        json!({"cwd": dir.join("work"), "mcpServers": [], "_meta": {"acpmux": acpmux}})
    };
    let r = agent.call("session/new", start("ask", None)).await;
    let id = r["result"]["sessionId"].as_str().unwrap_or_else(|| panic!("{r}")).to_owned();
    assert_eq!(agent.mode(&id).await, "ask");
    let info = agent.call("_acpmux/info", json!({"sessionId": id})).await;
    let conversation =
        info["result"]["agentSessionId"].as_str().unwrap_or_else(|| panic!("{info}"));
    let adopt = json!({"harness": "codex", "agentSessionId": conversation, "ifLive": "open"});
    let r = agent.call("session/new", start("read-only", Some(adopt))).await;
    assert_eq!(r["error"]["data"]["reason"], "permission.person_required", "{r}");
    assert_eq!(agent.mode(&id).await, "ask");
    let _ = std::fs::remove_dir_all(&dir);
}

/// The reviewer of cmux#25310, 2026-10-26: a session in the Codex bridge's `read-only` lends that
/// mode id to a chat it starts on the codex-acp adapter, whose `read-only` writes in the
/// workspace without asking. The agent in a bridge chat in `read-only` (its caller token) is
/// refused the adapter in `read-only`, and still starts the bridge in it.
#[tokio::test]
async fn a_bridge_caller_never_lends_read_only_to_the_adapter() {
    let dir = home("narrow-lend", json!({"defaultPermissionMode": "fullAccess"}));
    let daemon = hub_with(&dir, |cfg| {
        let adapter = json!({"argv": ["python3", FAKE_AGENT, "codex-acp"], "family": "codex"});
        cfg.harnesses.insert("adapter".into(), serde_json::from_value(adapter).unwrap());
    });
    let start = |harness: &str| {
        json!({"cwd": dir.join("work"), "mcpServers": [],
            "_meta": {"acpmux": {"harness": harness, "mode": "read-only"}}})
    };
    let mut cli = Client::new(&daemon, Origin::Local, ConnAuth::LocalSocket);
    let r = cli.call("session/new", start("codex")).await;
    let parent = r["result"]["sessionId"].as_str().unwrap_or_else(|| panic!("{r}")).to_owned();
    assert_eq!(cli.mode(&parent).await, "read-only");
    let mut agent = Client::new(&daemon, Origin::Local, ConnAuth::LocalSocket);
    let token = acpmux::hub::person::caller_token(&parent);
    let caller = json!({"callerSession": {"sessionId": parent, "token": token}});
    let r =
        agent.call("initialize", json!({"protocolVersion": 1, "_meta": {"acpmux": caller}})).await;
    assert!(r.get("error").is_none(), "{r}");
    let r = agent.call("session/new", start("adapter")).await;
    assert_eq!(r["error"]["data"]["reason"], "permission.person_required", "adapter: {r}");
    let r = agent.call("session/new", start("codex")).await;
    let id = r["result"]["sessionId"].as_str().unwrap_or_else(|| panic!("bridge: {r}")).to_owned();
    assert_eq!(agent.mode(&id).await, "read-only");
    let _ = std::fs::remove_dir_all(&dir);
}

/// The reviewer of cmux#25310, 2026-10-26: a Codex bridge a trusted folder profile runs is the
/// bridge too. The start check after the chat starts resolves the profile as a respawn would,
/// folder profiles included, so the unix socket starts it in `read-only`.
#[tokio::test]
async fn the_unix_socket_starts_a_folder_profile_bridge_in_read_only() {
    use acpmux::config::folder_profiles;
    let dir = home("narrow-folder", json!({"defaultPermissionMode": "fullAccess"}));
    let (repo, gate) = folder_profile(&dir);
    let codex = dir.join("bin").join("codex");
    let path = folder_profiles::profile_dir(&repo).join("acme.toml");
    std::fs::write(
        &path,
        format!("schema = 1\nid = \"acme\"\ncommand = {:?}\nargs = [\"app-server\"]\n", codex),
    )
    .unwrap();
    acpmux::trust::set(&gate.trust, &repo.to_string_lossy(), "trusted").unwrap();
    let enabled = Config { folder_gate: Some(gate.clone()), ..Default::default() };
    let sha = folder_profiles::load_one(&enabled, &gate, &repo, "acme")
        .and_then(|fp| fp.sha256)
        .expect("sha256");
    folder_profiles::enable(&enabled, &gate, &repo, "acme", &sha).unwrap();
    let daemon = hub_with(&dir, |cfg| cfg.folder_gate = Some(gate));
    let mut agent = Client::new(&daemon, Origin::Local, ConnAuth::LocalSocket);
    let r = agent
        .call(
            "session/new",
            json!({"cwd": repo, "mcpServers": [],
                "_meta": {"acpmux": {"harness": "acme", "mode": "read-only"}}}),
        )
        .await;
    let id = r["result"]["sessionId"].as_str().unwrap_or_else(|| panic!("{r}")).to_owned();
    assert_eq!(agent.mode(&id).await, "read-only");
    let _ = std::fs::remove_dir_all(&dir);
}

impl Client {
    /// The connection an agent's tools open: `initialize` with session `id`'s caller token.
    async fn as_session(hub: &Arc<Hub>, id: &str) -> Self {
        let mut c = Self::new(hub, Origin::Local, ConnAuth::LocalSocket);
        let token = acpmux::hub::person::caller_token(id);
        let r = c
            .call(
                "initialize",
                json!({"protocolVersion": 1,
                       "_meta": {"acpmux": {"callerSession": {"sessionId": id, "token": token}}}}),
            )
            .await;
        assert!(r.get("error").is_none(), "{r}");
        c
    }

    /// A new chat from preset `preset`: its id.
    async fn preset_chat(&mut self, dir: &Path, preset: &str) -> String {
        let params = json!({"cwd": dir.join("work"), "mcpServers": [], "_meta": {"acpmux": {"preset": preset}}});
        let r = self.call("session/new", params).await;
        r["result"]["sessionId"].as_str().unwrap_or_else(|| panic!("{r}")).to_owned()
    }
}

/// cmux#27847: the Chief host (a unix socket client, not the person) starts each subagent from its
/// built-in preset `optchat-sub-<home id>`, which names no mode. A preset's chat took no start
/// mode, so every subagent ran in Claude Code's asking `default` (acpmux's approve-all answering
/// each prompt), and every chat a subagent started inherited it: the mode picker read Manual. A
/// built-in subagent preset starts at the person's start level, as a plain `acpmux new` does, and
/// a chat the subagent starts inherits that. Chief's turn preset and a person's own preset keep
/// the harness's own mode.
#[tokio::test]
async fn chief_subagent_chats_start_at_the_person_start_level() {
    let presets = json!({
        "optchat-sub-0a1b2c3d": {"harness": "claude", "policy": "approve-all"},
        "optchat-sub-0a1b2c3d-claude": {"harness": "claude", "policy": "approve-all"},
        "optchat-chief-0a1b2c3d": {"harness": "claude", "policy": "approve-all"},
        "p": {"harness": "claude", "policy": "approve-all"},
    });
    let dir = home("chief-sub", json!({"defaultPermissionMode": "fullAccess", "presets": presets}));
    let daemon = hub(&dir);
    let mut chief = Client::new(&daemon, Origin::Local, ConnAuth::LocalSocket);

    let sub = chief.preset_chat(&dir, "optchat-sub-0a1b2c3d").await;
    assert_eq!(chief.mode(&sub).await, "bypassPermissions");
    let other = chief.preset_chat(&dir, "optchat-sub-0a1b2c3d-claude").await;
    assert_eq!(chief.mode(&other).await, "bypassPermissions");
    // What the app's New Agent Chat would read for it says the same.
    let r = chief
        .call(
            "_acpmux/start_mode",
            json!({"preset": "optchat-sub-0a1b2c3d", "cwd": dir.join("work")}),
        )
        .await;
    assert_eq!(r["result"]["modeId"], "bypassPermissions", "{r}");

    // A chat the subagent starts (agents_chat_new in the same acpmux) inherits its level.
    let mut agent = Client::as_session(&daemon, &sub).await;
    let (child, mode) = agent.chat(&dir, "claude").await;
    assert_eq!(mode, "bypassPermissions", "{child}");

    // Chief's own turn and a person's preset keep the harness's own mode.
    let turn = chief.preset_chat(&dir, "optchat-chief-0a1b2c3d").await;
    assert_eq!(chief.mode(&turn).await, "default");
    let own = chief.preset_chat(&dir, "p").await;
    assert_eq!(chief.mode(&own).await, "default");
    let _ = std::fs::remove_dir_all(&dir);
}

/// cmux#27847: the person's start level still rules a Chief subagent: `ask` starts it in the
/// mode that asks, and the subagent cannot widen itself afterwards.
#[tokio::test]
async fn chief_subagent_chats_follow_an_asking_start_level() {
    let presets = json!({"optchat-sub-0a1b2c3d": {"harness": "codex", "policy": "approve-all"}});
    let dir = home("chief-sub-ask", json!({"defaultPermissionMode": "ask", "presets": presets}));
    let daemon = hub(&dir);
    let mut chief = Client::new(&daemon, Origin::Local, ConnAuth::LocalSocket);
    let sub = chief.preset_chat(&dir, "optchat-sub-0a1b2c3d").await;
    assert_eq!(chief.mode(&sub).await, "ask");
    let r = chief
        .call("session/set_mode", json!({"sessionId": sub, "modeId": "agent-full-access"}))
        .await;
    assert_eq!(r["error"]["data"]["reason"], "permission.person_required", "{r}");
    let _ = std::fs::remove_dir_all(&dir);
}
