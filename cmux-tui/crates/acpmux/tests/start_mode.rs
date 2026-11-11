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
/// process), `plain` (an ACP agent with no full-access mode and no mode that asks) and `asker`
/// (the same agent, which says it asks before every tool call). `extra`
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
            // Says nothing about asking (`FAKE_ASK_CLAIM=0`): it cannot keep a policy.
            "plain": {"argv": ["python3", FAKE_AGENT], "env": {"FAKE_ASK_CLAIM": "0"}},
            // The same agent, which says it asks before every tool call (the fake's default,
            // `agentCapabilities._meta.acpmux.asksBeforeTools`).
            "asker": {"argv": ["python3", FAKE_AGENT]},
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

    // A unix socket client (an agent, a script) may move a chat to Claude Code's own Auto under
    // the person's full-access start level (`start_mode.rs` `may_move_without_person`), but to
    // no other mode that does not ask.
    let mut agent = Client::new(&daemon, Origin::Local, ConnAuth::LocalSocket);
    let (chat, _) = agent.chat(&dir, "claude").await;
    let r = agent.call("session/set_mode", json!({"sessionId": chat, "modeId": "default"})).await;
    assert!(r.get("error").is_none(), "{r}");
    let r = agent.call("session/set_mode", json!({"sessionId": chat, "modeId": "auto"})).await;
    assert!(r.get("error").is_none(), "{r}");
    let r =
        agent.call("session/set_mode", json!({"sessionId": chat, "modeId": "acceptEdits"})).await;
    assert_eq!(r["error"]["data"]["reason"], "permission.person_required", "{r}");
    assert_eq!(last_pick(&dir), Value::Null);
    let _ = std::fs::remove_dir_all(&dir);
}

/// acp-chief-issues.md #15 (2026-10-19 u1976), cmux#37392: a headless
/// `acpmux new --mode bypassPermissions` (a Chief's `cmux chat new --mode
/// bypassPermissions` reaches the app's daemon with no caller it can prove)
/// names the mode a start with no mode gets anyway while the person's start
/// level is full access, so it starts in it. Under another level it is still
/// refused, and the refusal names the start without a mode, which works.
#[tokio::test]
async fn a_headless_mode_start_runs_in_the_persons_full_access_and_is_refused_below_it() {
    let dir = home("headless", json!({"defaultPermissionMode": "fullAccess"}));
    let daemon = hub(&dir);
    let mut script = Client::new(&daemon, Origin::Local, ConnAuth::LocalSocket);
    let params = json!({"cwd": dir.join("work"), "mcpServers": [],
        "_meta": {"acpmux": {"harness": "claude", "mode": "bypassPermissions"}}});
    let r = script.call("session/new", params.clone()).await;
    assert!(r.get("error").is_none(), "full access is the person's start level: {r}");
    let id = r["result"]["sessionId"].as_str().unwrap_or_else(|| panic!("{r}")).to_owned();
    assert_eq!(script.mode(&id).await, "bypassPermissions", "{r}");
    // Another mode that skips approvals (one acpmux never starts a chat in) stays the person's.
    let wider = json!({"cwd": dir.join("work"), "mcpServers": [],
        "_meta": {"acpmux": {"harness": "claude", "mode": "danger-full-access"}}});
    let r = script.call("session/new", wider).await;
    assert_eq!(r["error"]["data"]["reason"], "permission.person_required", "{r}");
    drop(script);
    drop(daemon);
    let _ = std::fs::remove_dir_all(&dir);

    for level in ["standard", "ask"] {
        let dir = home(&format!("headless-{level}"), json!({"defaultPermissionMode": level}));
        let daemon = hub(&dir);
        let mut script = Client::new(&daemon, Origin::Local, ConnAuth::LocalSocket);
        let params = json!({"cwd": dir.join("work"), "mcpServers": [],
            "_meta": {"acpmux": {"harness": "claude", "mode": "bypassPermissions"}}});
        let r = script.call("session/new", params).await;
        assert_eq!(r["error"]["data"]["reason"], "permission.person_required", "{level}: {r}");
        let message = r["error"]["message"].as_str().unwrap_or_default();
        assert!(message.contains("without --mode"), "{message}");
        // That start, with no mode, works headless in the person's start mode.
        let (_, mode) = script.chat(&dir, "claude").await;
        assert_ne!(mode, "bypassPermissions", "{level}");
        drop(script);
        drop(daemon);
        let _ = std::fs::remove_dir_all(&dir);
    }
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
    // Claude Code's own start mode is Auto, never Manual (`claude_stdio::OWN_MODE`).
    assert_eq!(app.chat(&dir, "claude").await.1, "auto");
    assert_eq!(app.chat(&dir, "codex").await.1, "agent");
    let _ = std::fs::remove_dir_all(&dir);
}

/// `defaultPermissionMode: "yolo"` is full access (user 2026-11-03: "default it to be
/// yolo"), and a harness's own `defaults.<harness>.permissionMode` wins over it for that
/// harness only, in a new chat and in the answer the app's mode picker reads.
#[tokio::test]
async fn yolo_is_full_access_and_a_harness_override_wins_for_that_harness() {
    let dir = home(
        "yolo-harness",
        json!({"defaultPermissionMode": "yolo", "defaults": {"codex": {"permissionMode": "ask"}}}),
    );
    let daemon = hub(&dir);
    let mut app = Client::app(&daemon).await;
    assert_eq!(app.chat(&dir, "claude").await.1, "bypassPermissions");
    let answer = start_mode(&mut app, &dir, "claude").await;
    assert_eq!(answer["level"], "fullAccess", "{answer}");
    assert_eq!(answer["source"], "config", "{answer}");
    assert_eq!(app.chat(&dir, "codex").await.1, "ask");
    let answer = start_mode(&mut app, &dir, "codex").await;
    assert_eq!(answer["modeId"], "ask", "{answer}");
    assert_eq!(answer["level"], "ask", "{answer}");
    assert_eq!(answer["source"], "harness", "{answer}");
    drop(app);
    drop(daemon);

    // The override widens too: a person who asks by default can let one harness skip.
    let dir2 = home(
        "harness-yolo",
        json!({"defaultPermissionMode": "ask", "defaults": {"claude": {"permissionMode": "yolo"}}}),
    );
    let daemon = hub(&dir2);
    let mut app = Client::app(&daemon).await;
    assert_eq!(app.chat(&dir2, "claude").await.1, "bypassPermissions");
    assert_eq!(app.chat(&dir2, "codex").await.1, "ask");
    let _ = std::fs::remove_dir_all(&dir);
    let _ = std::fs::remove_dir_all(&dir2);
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
            peer_scratch: None,
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
    /// `session/new` on `harness` with acpmux permission policy `policy`: the whole reply.
    async fn new_chat_with_policy(&mut self, dir: &Path, harness: &str, policy: &str) -> Value {
        let params = json!({"cwd": dir.join("work"), "mcpServers": [],
            "_meta": {"acpmux": {"harness": harness, "policy": policy}}});
        self.call("session/new", params).await
    }

    /// A new chat on `harness` with acpmux permission policy `policy`: its id and its mode.
    async fn chat_with_policy(
        &mut self,
        dir: &Path,
        harness: &str,
        policy: &str,
    ) -> (String, String) {
        let r = self.new_chat_with_policy(dir, harness, policy).await;
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
    // A harness with no mode that asks cannot keep any of them: the chat does not start (lead,
    // 2026-11-08: a policy that silently does not hold is a security bug).
    for policy in ["ask", "approve-reads", "approve-edits", "review", "deny-all"] {
        let r = app.new_chat_with_policy(&dir, "plain", policy).await;
        assert_eq!(r["error"]["data"]["reason"], "policy_unenforceable", "{policy}: {r}");
        // An agent that says it asks before every tool call keeps it.
        let (id, mode) = app.chat_with_policy(&dir, "asker", policy).await;
        assert_eq!(mode, "normal", "{policy}");
        assert!(app.unenforced(&id).await.is_empty(), "asker, {policy}");
    }
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
    let epoch = begin["result"]["epoch"].clone();
    assert!(transfer.is_string(), "{begin}");
    let r = app.call("_acpmux/set_default_policy", json!({"policy": "deny-all"})).await;
    assert!(r.get("error").is_none(), "{r}");
    assert_eq!(app.mode(&id).await, "agent-full-access", "a moving chat is not touched");
    let r = mover
        .call(
            "_acpmux/transfer_abort",
            json!({"sessionId": id, "transferId": transfer, "epoch": epoch}),
        )
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
/// writes in the workspace without asking (`web_modes::NON_ASKING_MODES`). The bridge's
/// full-access mode, which a start with no mode gets here, needs none (cmux#37392).
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
    let r = agent.call("session/new", start("codex", "agent")).await;
    assert_eq!(r["error"]["data"]["reason"], "permission.person_required", "agent: {r}");
    // The bridge's full-access mode is what a start with no mode gets under the person's
    // full-access start level, so naming it needs no person either (cmux#37392).
    let r = agent.call("session/new", start("codex", "agent-full-access")).await;
    let id = r["result"]["sessionId"].as_str();
    let id = id.unwrap_or_else(|| panic!("agent-full-access: {r}")).to_owned();
    assert_eq!(agent.mode(&id).await, "agent-full-access");
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
    assert_eq!(chief.mode(&turn).await, "auto");
    let own = chief.preset_chat(&dir, "p").await;
    assert_eq!(chief.mode(&own).await, "auto");
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

/// User 20336: "in acpmux/chat ui, changing permissions doesnt work (it was in edits, then i
/// changed to bypass, and it was still asking me)". A chat whose own narrower policy (approve-edits,
/// as an agent's start gave it) holds it in an asking mode refused the person's pick of a mode that
/// does not ask (`policy_mode`), so the harness kept asking. The person's pick now widens that
/// chat's policy to approve-all first: the switch takes at once, and the next ask is answered
/// without them, for Claude Code and for Codex.
#[tokio::test]
async fn the_persons_bypass_pick_on_an_edits_chat_stops_the_asking() {
    let dir = home("policy-person-bypass", json!({"defaultPermissionMode": "fullAccess"}));
    let daemon = hub(&dir);
    let mut app = Client::app(&daemon).await;
    for (harness, full) in [("claude", "bypassPermissions"), ("codex", "agent-full-access")] {
        let (id, mode) = app.chat_with_policy(&dir, harness, "approve-edits").await;
        assert_ne!(mode, full, "{harness}: the approve-edits chat asks first");
        let r = app.call("session/set_mode", json!({"sessionId": id, "modeId": full})).await;
        assert!(r.get("error").is_none(), "{harness}: the person's pick takes: {r}");
        assert_eq!(app.mode(&id).await, full, "{harness}");
        let info = app.call("_acpmux/info", json!({"sessionId": id})).await;
        assert_eq!(info["result"]["policy"], "approve-all", "{harness}: {info}");
    }
    // The harness asks before a shell command; with the pick, nothing waits for the person.
    let (claude, _) = app.chat_with_policy(&dir, "claude", "approve-edits").await;
    let r = app
        .call("session/set_mode", json!({"sessionId": claude, "modeId": "bypassPermissions"}))
        .await;
    assert!(r.get("error").is_none(), "{r}");
    let r = app
        .call(
            "session/prompt",
            json!({"sessionId": claude, "prompt": [{"type": "text", "text": "always-ask"}]}),
        )
        .await;
    assert!(r.get("error").is_none(), "the turn ends with no answer from the person: {r}");
    let info = app.call("_acpmux/info", json!({"sessionId": claude})).await;
    assert_eq!(info["result"]["pendingPermissions"], 0, "{info}");
    let _ = std::fs::remove_dir_all(&dir);
}

/// A deny-all lockdown still holds: the person's pick of a mode that does not ask is refused
/// there, as before (`policy_mode.rs`).
#[tokio::test]
async fn the_persons_bypass_pick_on_a_deny_all_chat_is_still_refused() {
    let dir = home("policy-person-deny", json!({"defaultPermissionMode": "fullAccess"}));
    let daemon = hub(&dir);
    let mut app = Client::app(&daemon).await;
    let (id, _) = app.chat_with_policy(&dir, "codex", "deny-all").await;
    let r =
        app.call("session/set_mode", json!({"sessionId": id, "modeId": "agent-full-access"})).await;
    assert_eq!(r["error"]["data"]["reason"], "policy_mode", "{r}");
    let _ = std::fs::remove_dir_all(&dir);
}

/// cmux#37392 (exact-head review of the Chief permission mode): a Chief whose mode is Auto
/// sets it on its Claude turn before each prompt, from a connection that is not the person. Under
/// an `ask` start level acpmux refused that set even on a chat already in Auto, so every Chief
/// turn was refused. A set to the mode a chat already runs changes nothing and needs no person;
/// any other move under `ask` still does, and a full-access mode is never taken this way.
#[tokio::test]
async fn a_set_to_the_mode_a_chat_already_runs_needs_no_person() {
    let dir = home("unchanged-mode", json!({"defaultPermissionMode": "ask"}));
    let daemon = hub(&dir);
    let mut app = Client::app(&daemon).await;
    let (chat, mode) = app.chat(&dir, "claude").await;
    assert_eq!(mode, "default");
    let r = app.call("session/set_mode", json!({"sessionId": chat, "modeId": "auto"})).await;
    assert!(r.get("error").is_none(), "{r}");
    let mut script = Client::new(&daemon, Origin::Local, ConnAuth::LocalSocket);
    let r = script.call("session/set_mode", json!({"sessionId": chat, "modeId": "auto"})).await;
    assert!(r.get("error").is_none(), "the chat already runs Auto: {r}");
    assert_eq!(script.mode(&chat).await, "auto");
    let r =
        script.call("session/set_mode", json!({"sessionId": chat, "modeId": "acceptEdits"})).await;
    assert_eq!(r["error"]["data"]["reason"], "permission.person_required", "{r}");
    // A chat the person put in bypass: the same set from the script stays the person's.
    let r = app
        .call("session/set_mode", json!({"sessionId": chat, "modeId": "bypassPermissions"}))
        .await;
    assert!(r.get("error").is_none(), "{r}");
    let r = script
        .call("session/set_mode", json!({"sessionId": chat, "modeId": "bypassPermissions"}))
        .await;
    assert_eq!(r["error"]["data"]["reason"], "permission.person_required", "{r}");
    let _ = std::fs::remove_dir_all(&dir);
}

const FAKE_AUTO: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_claude_auto.py");

/// A Claude Code launcher profile on acpmux's own Claude Code backend that names its own family,
/// as `claude-sr2` (`sr2 claude`) does, running a Claude Code that runs every tool without asking
/// (`fake_claude_auto.py`: Claude Code's `auto`, or a call its settings allow). It logs each call
/// to `log`.
fn launcher_profile(log: &Path) -> acpmux::config::HarnessProfile {
    acpmux::config::HarnessProfile {
        kind: acpmux::config::HarnessKind::ClaudeStdio,
        argv: vec!["python3".into(), FAKE_AUTO.into()],
        env: [("FAKE_AUTO_LOG".to_owned(), log.to_string_lossy().into_owned())].into(),
        description: None,
        fallback: None,
        family: Some("claude-sr2".into()),
        models: vec![],
        model: None,
        effort: None,
        policy: None,
    }
}

/// The calls `fake_claude_auto.py` logged, by their command (Bash) or path (Write): whether each
/// ran.
fn ran_calls(log: &Path) -> std::collections::BTreeMap<String, bool> {
    let text = std::fs::read_to_string(log).unwrap_or_default();
    text.lines()
        .map(|l| serde_json::from_str::<Value>(l).unwrap())
        .map(|r| {
            let key = r["input"]["command"].as_str().or(r["input"]["file_path"].as_str());
            (key.unwrap().to_owned(), r["ran"].as_bool().unwrap())
        })
        .collect()
}

/// Lead, 2026-11-08: any policy narrower than approve-all, however a chat gets it, holds or the
/// chat does not run. A deny-all or review default (a lockdown) refuses a new chat on a harness
/// that cannot keep it; a live chat narrowed to a policy its harness cannot keep has its agent
/// stopped (`policy_refused`), and its next start fails with `policy_unenforceable`.
#[tokio::test]
async fn a_policy_that_cannot_hold_never_runs_however_the_chat_gets_it() {
    let dir = home("policy-refuse-all", json!({}));
    let daemon = hub(&dir);
    let mut app = Client::app(&daemon).await;
    for lockdown in ["deny-all", "review"] {
        let r = app.call("_acpmux/set_default_policy", json!({"policy": lockdown})).await;
        assert!(r.get("error").is_none(), "{r}");
        let params = json!({"cwd": dir.join("work"), "mcpServers": [],
            "_meta": {"acpmux": {"harness": "plain"}}});
        let r = app.call("session/new", params).await;
        assert_eq!(r["error"]["data"]["reason"], "policy_unenforceable", "{lockdown}: {r}");
        assert_eq!(r["error"]["data"]["policy"], lockdown, "{r}");
    }
    let r = app.call("_acpmux/set_default_policy", json!({"policy": "ask"})).await;
    assert!(r.get("error").is_none(), "{r}");
    // Live: an approve-all chat runs, then is narrowed to review.
    let (id, _) = app.chat_with_policy(&dir, "plain", "approve-all").await;
    let hi = json!({"sessionId": id, "prompt": [{"type": "text", "text": "hi"}]});
    let r = app.call("session/prompt", hi.clone()).await;
    assert!(r.get("error").is_none(), "{r}");
    let r = app.call("_acpmux/set_policy", json!({"sessionId": id, "policy": "review"})).await;
    assert!(r.get("error").is_none(), "{r}");
    let r = app.call("_acpmux/events", json!({"sessionId": id, "kinds": ["policy_refused"]})).await;
    let refused = r["result"]["events"].as_array().cloned().unwrap_or_default();
    assert_eq!(refused.len(), 1, "the agent was stopped: {r}");
    assert_eq!(refused[0]["msg"]["reason"], "policy_unenforceable", "{r}");
    let r = app.call("session/prompt", hi).await;
    assert_eq!(r["error"]["data"]["reason"], "policy_unenforceable", "its next start: {r}");
    let _ = std::fs::remove_dir_all(&dir);
}

impl Client {
    /// The records of kind `kind` in chat `id`'s log.
    async fn records(&mut self, id: &str, kind: &str) -> Vec<Value> {
        let r = self.call("_acpmux/events", json!({"sessionId": id, "kinds": [kind]})).await;
        r["result"]["events"].as_array().cloned().unwrap_or_else(|| panic!("{r}"))
    }
}

/// acpmux believes an agent's `asksBeforeTools` claim only from an agent it started from a
/// harness entry of its own config that still launches what it started from, and logs every
/// claim (`asks_before_tools_claim`; lead, 2026-11-09). A folder profile (the repository's
/// `.cmux/harnesses`) that claims is not believed, so a narrow policy on it does not run; nor is
/// an entry changed while its agent runs, so a narrower policy then stops that agent.
#[tokio::test]
async fn a_policy_holds_on_an_asks_before_tools_claim_only_from_an_unchanged_config_entry() {
    use acpmux::config::folder_profiles;
    let dir = home("asks-claim-trust", json!({}));
    let (repo, gate) = folder_profile(&dir);
    // The folder profile `acme` runs the fake, which claims.
    acpmux::trust::set(&gate.trust, &repo.to_string_lossy(), "trusted").unwrap();
    let enabled = Config { folder_gate: Some(gate.clone()), ..Default::default() };
    let sha = folder_profiles::load_one(&enabled, &gate, &repo, "acme")
        .and_then(|fp| fp.sha256)
        .expect("sha256");
    folder_profiles::enable(&enabled, &gate, &repo, "acme", &sha).unwrap();
    let daemon = hub_with(&dir, |cfg| cfg.folder_gate = Some(gate));
    let mut app = Client::app(&daemon).await;

    // A config entry that claims: believed, and logged.
    let (id, _) = app.chat_with_policy(&dir, "asker", "ask").await;
    let claims = app.records(&id, "asks_before_tools_claim").await;
    assert_eq!(claims.len(), 1, "{claims:?}");
    assert_eq!(claims[0]["msg"]["harness"], "asker", "{claims:?}");
    assert_eq!(claims[0]["msg"]["trusted"], true, "{claims:?}");
    // An agent that makes no claim: none is logged.
    let (id, _) = app.chat_with_policy(&dir, "plain", "approve-all").await;
    assert!(app.records(&id, "asks_before_tools_claim").await.is_empty());

    // A folder profile that claims: not believed, so a narrow policy on it does not run.
    let folder_chat = |policy: &str| {
        json!({"cwd": repo, "mcpServers": [],
            "_meta": {"acpmux": {"harness": "acme", "policy": policy}}})
    };
    let r = app.call("session/new", folder_chat("ask")).await;
    assert_eq!(r["error"]["data"]["reason"], "policy_unenforceable", "{r}");
    let why = r["error"]["data"]["why"].as_str().unwrap_or_default();
    assert!(why.contains("not_a_config_entry"), "{r}");
    // Under approve-all it runs; its claim is logged as not believed, and a narrower policy
    // then stops its agent.
    let r = app.call("session/new", folder_chat("approve-all")).await;
    let id = r["result"]["sessionId"].as_str().unwrap_or_else(|| panic!("{r}")).to_owned();
    let claims = app.records(&id, "asks_before_tools_claim").await;
    assert_eq!(claims.len(), 1, "{claims:?}");
    assert_eq!(claims[0]["msg"]["trusted"], false, "{claims:?}");
    assert_eq!(claims[0]["msg"]["reason"], "not_a_config_entry", "{claims:?}");
    let r = app.call("_acpmux/set_policy", json!({"sessionId": id, "policy": "ask"})).await;
    assert!(r.get("error").is_none(), "{r}");
    assert_eq!(app.records(&id, "policy_refused").await.len(), 1, "folder agent stopped");

    // A config entry changed while its agent runs: it no longer launches what the agent started
    // from, so the claim is not believed, and a narrower policy stops the agent.
    let (id, _) = app.chat_with_policy(&dir, "asker", "approve-all").await;
    let mut cfg = daemon.config.write().await;
    let asker = cfg.harnesses.get_mut("asker").expect("asker");
    asker.env.insert("FAKE_CHANGED".to_owned(), "1".to_owned());
    drop(cfg);
    let r = app.call("_acpmux/set_policy", json!({"sessionId": id, "policy": "ask"})).await;
    assert!(r.get("error").is_none(), "{r}");
    let refused = app.records(&id, "policy_refused").await;
    assert_eq!(refused.len(), 1, "changed entry's agent stopped: {refused:?}");
    let why = refused[0]["msg"]["why"].as_str().unwrap_or_default();
    assert!(why.contains("entry_changed"), "{refused:?}");
    let _ = std::fs::remove_dir_all(&dir);
}

/// The median, the 95th percentile and the largest of `ms`, sorted in place.
fn spread(ms: &mut [f64]) -> (f64, f64, f64) {
    ms.sort_by(f64::total_cmp);
    let at = |q: usize| ms.get((ms.len().saturating_sub(1)) * q / 100).copied().unwrap_or(0.0);
    (at(50), at(95), at(100))
}

/// What the gate costs a chat that it does not hold (approve-all): every tool call still asks the
/// hub. Measured where Claude Code waits, from its `hook_callback` to the answer, beside the
/// repository-sync hook the backend answers itself (no hub). Printed for the record (lead,
/// 2026-11-08), bounded loosely so a loaded runner does not fail it.
#[tokio::test]
async fn the_policy_gate_round_trip_under_approve_all_is_measured() {
    let dir = home("policy-gate-latency", json!({"defaultPermissionMode": "fullAccess"}));
    let log = dir.join("auto.log");
    let daemon = hub_with(&dir, |cfg| {
        cfg.harnesses.insert("sr2".into(), launcher_profile(&log));
    });
    let mut app = Client::app(&daemon).await;
    let (id, _) = app.chat_with_policy(&dir, "sr2", "approve-all").await;
    let calls: Vec<Value> =
        (0..60).map(|i| json!(["Bash", {"command": format!("true {i}")}])).collect();
    let r = app
        .call(
            "session/prompt",
            json!({"sessionId": id, "prompt": auto_tools(&Value::Array(calls))}),
        )
        .await;
    assert!(r.get("error").is_none(), "{r}");
    let text = std::fs::read_to_string(&log).unwrap();
    let (mut sync, mut gate) = (Vec::new(), Vec::new());
    for line in text.lines() {
        let record: Value = serde_json::from_str(line).unwrap();
        assert_eq!(record["ran"], true, "approve-all runs it: {record}");
        let hooks = record["hookMs"].as_array().cloned().unwrap_or_default();
        assert_eq!(hooks.len(), 2, "the repository sync and the gate: {record}");
        for hook in hooks {
            let ms = hook["ms"].as_f64().unwrap_or_else(|| panic!("{record}"));
            match hook["callback"].as_str() {
                Some("acpmux-policy-gate") => gate.push(ms),
                _ => sync.push(ms),
            }
        }
    }
    assert_eq!(gate.len(), 60);
    let (g50, g95, gmax) = spread(&mut gate);
    let (s50, s95, _) = spread(&mut sync);
    // Straight to the process's stderr, past the test harness's capture: the number is the
    // record.
    let line = format!(
        "policy gate round trip under approve-all, n=60: p50 {g50:.2} ms, p95 {g95:.2} ms, max {gmax:.2} ms (backend-only hook: p50 {s50:.2} ms, p95 {s95:.2} ms)\n"
    );
    let _ = std::io::Write::write_all(&mut std::io::stderr(), line.as_bytes());
    assert!(g50 < 500.0, "p50 {g50} ms");
    let _ = std::fs::remove_dir_all(&dir);
}

/// `git -C dir args`, which must succeed.
fn git_in(dir: &Path, args: &[&str]) {
    let ok = std::process::Command::new("git").arg("-C").arg(dir).args(args).status();
    assert!(ok.unwrap().success(), "git {args:?}");
}

/// The prompt that makes `fake_claude_auto.py` run `calls`, each `[tool, input]`.
fn auto_tools(calls: &Value) -> Value {
    json!([{"type": "text", "text": format!("auto-tools: {calls}")}])
}

/// W5-L: a chat on a `claude-sr2` profile under deny-all or review ran a `touch` and a Write with
/// no prompt and no deny: the profile's own family hid Claude Code's asking mode from the policy
/// tables, the chat stayed in `auto`, and the daemon only warned. A policy is now held whatever
/// the harness's mode: every tool call the harness makes passes acpmux's PreToolUse gate, which
/// denies what the policy refuses (a write, a commit, a command that does not only read) and lets
/// reads and read-only commands run, also git reads in a partial clone with merge drivers (the
/// cmux checkout, where a review chat could not run `git diff`). The chat also moves to Claude
/// Code's asking mode. Under approve-all the same calls run, and a chat narrowed to review while
/// its agent runs is held at once.
#[tokio::test]
async fn a_narrow_policy_holds_on_a_claude_launcher_that_runs_tools_without_asking() {
    let dir = home("policy-gate", json!({"defaultPermissionMode": "fullAccess"}));
    let work = dir.join("work");
    git_in(&work, &["init", "-q"]);
    git_in(&work, &["config", "user.name", "Gate Test"]);
    git_in(&work, &["config", "user.email", "gate@example.invalid"]);
    std::fs::write(work.join("file.txt"), "needle\n").unwrap();
    git_in(&work, &["add", "file.txt"]);
    git_in(&work, &["commit", "-qm", "init"]);
    git_in(&work, &["update-ref", "refs/remotes/origin/x", "HEAD"]);
    // As the cmux checkout: merge drivers and a promisor remote.
    for (key, value) in [
        ("merge.pbxproj-v1.driver", "/nonexistent/merge %O %A %B"),
        ("merge.pbxproj-v1.name", "pbxproj"),
        ("remote.origin.url", "https://example.invalid/r.git"),
        ("remote.origin.promisor", "true"),
        ("remote.origin.partialclonefilter", "blob:none"),
    ] {
        git_in(&work, &["config", key, value]);
    }
    let log = dir.join("auto.log");
    let daemon = hub_with(&dir, |cfg| {
        cfg.harnesses.insert("sr2".into(), launcher_profile(&log));
    });
    let mut app = Client::app(&daemon).await;
    let reads = [
        "git status",
        "ls",
        "git diff origin/x -- file.txt",
        "git log --oneline -1",
        "git show HEAD:file.txt",
        "git blame file.txt",
        "cat file.txt",
        "grep -rn needle .",
    ];
    let commit = "git commit -q --allow-empty -m gate";
    let mut last = String::new();
    for policy in ["review", "deny-all", "approve-all"] {
        let _ = std::fs::remove_file(&log);
        let (id, _) = app.chat_with_policy(&dir, "sr2", policy).await;
        let probe = dir.join(format!("probe-{policy}"));
        let written = work.join(format!("written-{policy}.txt"));
        let touch = format!("touch {}", probe.display());
        let mut calls = vec![
            json!(["Bash", {"command": touch}]),
            json!(["Write", {"file_path": written, "content": "x"}]),
            json!(["Bash", {"command": commit}]),
        ];
        calls.extend(reads.iter().map(|r| json!(["Bash", {"command": r}])));
        let calls = Value::Array(calls);
        let r = app
            .call("session/prompt", json!({"sessionId": id, "prompt": auto_tools(&calls)}))
            .await;
        assert!(r.get("error").is_none(), "{policy}: {r}");
        let ran = ran_calls(&log);
        assert_eq!(ran.len(), 3 + reads.len(), "{policy}: every call was made: {ran:?}");
        // Deny-all denies every shell command, read-only or not (lead, 2026-11-08: the name
        // promises it; review is the read-only preset).
        let shell_reads = policy != "deny-all";
        for read in reads {
            assert!(ran[read] == shell_reads, "{policy}: {read}: {ran:?}");
        }
        let writes = policy == "approve-all";
        assert!(ran[&touch] == writes, "{policy}: the touch: {ran:?}");
        assert!(ran[&written.to_string_lossy().into_owned()] == writes, "{policy}: {ran:?}");
        assert!(ran[commit] == writes, "{policy}: the commit: {ran:?}");
        assert!(probe.exists() == writes, "{policy}: the touch");
        assert!(written.exists() == writes, "{policy}: the Write");
        if !writes {
            // Reported: each refused call is a denied permission in the chat's log.
            let r = app
                .call("_acpmux/events", json!({"sessionId": id, "kinds": ["permission_auto"]}))
                .await;
            let denied = r["result"]["events"]
                .as_array()
                .unwrap_or_else(|| panic!("{r}"))
                .iter()
                .filter(|e| e["msg"]["optionId"] == "reject_once")
                .count();
            let want = if shell_reads { 3 } else { 3 + reads.len() };
            assert_eq!(denied, want, "{policy}: the touch, the Write, the commit: {r}");
            // And the chat runs in Claude Code's mode that asks, not `auto`.
            assert_eq!(app.mode(&id).await, "default", "{policy}");
        }
        last = id;
    }
    // Narrowed while its agent runs: held from the next call, with no restart.
    let r = app.call("_acpmux/set_policy", json!({"sessionId": last, "policy": "review"})).await;
    assert!(r.get("error").is_none(), "{r}");
    let _ = std::fs::remove_file(&log);
    let probe = dir.join("probe-narrowed");
    let touch = format!("touch {}", probe.display());
    let calls = json!([["Bash", {"command": touch}], ["Bash", {"command": "git log -1"}]]);
    let r =
        app.call("session/prompt", json!({"sessionId": last, "prompt": auto_tools(&calls)})).await;
    assert!(r.get("error").is_none(), "{r}");
    let ran = ran_calls(&log);
    assert!(!ran[&touch] && !probe.exists(), "narrowed to review: {ran:?}");
    assert!(ran["git log -1"], "narrowed to review: {ran:?}");
    // A harness that can neither gate nor keep a policy by its mode does not start under it:
    // never "warn and run unprotected".
    for policy in ["ask", "approve-reads", "approve-edits", "review", "deny-all"] {
        let r = app.new_chat_with_policy(&dir, "plain", policy).await;
        assert_eq!(r["error"]["data"]["reason"], "policy_unenforceable", "{policy}: {r}");
        assert_eq!(r["error"]["data"]["policy"], policy, "{r}");
        assert!(r["error"]["data"]["hint"].as_str().is_some_and(|h| !h.is_empty()), "{r}");
    }
    let _ = std::fs::remove_dir_all(&dir);
}

/// A remote chat records the launch of its config entry as the entry is written, not the
/// canonical program path its remote start resolves (lead, 2026-11-09): a catalog reload that
/// changes nothing never marks it for a respawn, as it never marks a local chat. `asker`'s
/// program is the bare `python3`, which a remote start resolves to a path. The reload also
/// changes the entry of a local control chat, `ctl`: once that one's agent started again, the
/// sweep that judged every chat is done.
#[tokio::test]
async fn a_remote_chat_keeps_its_entrys_launch_through_an_unchanged_reload() {
    let ctl = |flag: &str| json!({"argv": ["python3", FAKE_AGENT], "env": {"CTL": flag}});
    let dir = home("remote-respawn", json!({"webAskingModes": {"asker": ["normal"]}}));
    let config_path = dir.join("config.json");
    let write_ctl = |flag: &str| {
        let mut config: Value =
            serde_json::from_slice(&std::fs::read(&config_path).unwrap()).unwrap();
        config["harnesses"]["ctl"] = ctl(flag);
        std::fs::write(&config_path, serde_json::to_vec_pretty(&config).unwrap()).unwrap();
    };
    write_ctl("1");
    let daemon = hub(&dir);
    let mut web = Client::new(&daemon, Origin::Web, ConnAuth::ListenerToken);
    let (remote, _) = web.chat(&dir, "asker").await;
    let mut app = Client::app(&daemon).await;
    let claims = app.records(&remote, "asks_before_tools_claim").await;
    assert_eq!(claims.len(), 1, "{claims:?}");
    assert_eq!(claims[0]["msg"]["trusted"], true, "the remote chat's claim: {claims:?}");
    let (control, _) = app.chat(&dir, "ctl").await;

    let mut events = daemon.subscribe();
    write_ctl("2");
    daemon.reload_catalog().await.unwrap();
    tokio::time::timeout(Duration::from_secs(30), async {
        while app.records(&control, "asks_before_tools_claim").await.len() < 2 {
            if let Err(tokio::sync::broadcast::error::RecvError::Closed) = events.recv().await {
                panic!("the hub ended");
            }
        }
    })
    .await
    .expect("the control chat's agent started again on its changed entry");
    let marked = app.records(&remote, "respawn_pending").await;
    assert!(marked.is_empty(), "an unchanged entry respawns no remote chat: {marked:?}");
    let _ = std::fs::remove_dir_all(&dir);
}
