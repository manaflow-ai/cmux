//! `sessions.allowFullAccess` (Settings > Agents > Agent Sessions) as acpmux enforces it beyond
//! the settings file and the mode switch:
//!
//! - the effective value the app pushes (`_acpmux/chat_settings` `allowFullAccess`,
//!   `allowFullAccessManaged`): a value MDM or the team policy forces beats the file, for new
//!   chats, mode switches and resumes, and holds across a daemon restart before the next push;
//! - the approve-all policy (`approve-all`, `yolo`), the policy form of full access: refused on
//!   `session/new`, `_acpmux/set_policy` and `_acpmux/set_default_policy`, and a stored one (a
//!   session's, config.json `permissionPolicy`) answers nothing itself while the switch is off;
//! - the rule: the boolean is strict (`0` or `"false"` is off), and a permission mode the shared
//!   allowlist (`spec/full-access-modes.json`) does not know counts as full access.
//!
//! Its own test binary: it sets CMUX_NEXT_CONFIG_FILE and ACPMUX_HOME, which every session start
//! and switch reads; `ENV` runs its tests one at a time.

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
use std::time::{Duration, Instant};
use tokio::sync::mpsc;

/// Held for a whole test: the tests set process-wide variables.
static ENV: tokio::sync::Mutex<()> = tokio::sync::Mutex::const_new(());

/// 32 bytes as hex: the person key the app makes at each launch.
const KEY: &str = "5e1f0c2a9b8d7e6f5a4b3c2d1e0f9a8b7c6d5e4f3a2b1c0d9e8f7a6b5c4d3e2f";

const FAKE_APP_SERVER: &str =
    concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_codex_app_server.py");
const FAKE_CLAUDE: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_claude.py");
const FAKE_AGENT: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");

/// A home with `codex` (the Codex bridge over a fake `codex app-server`), `claude` (acpmux's own
/// Claude backend over a fake Claude Code) and `fake` (an ACP agent with no modes whose
/// `ask: X` prompt asks permission). `extra` is merged into config.json.
fn home(name: &str, extra: Value) -> PathBuf {
    let dir = std::env::temp_dir()
        .join(format!("acpmux-full-access-enforcement-{name}-{}", std::process::id()));
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
            "codex": {"argv": [codex, "app-server"]},
            "claude": {"argv": ["python3", FAKE_CLAUDE], "kind": "claude-stdio"},
            "fake": {"argv": ["env", "FAKE_NO_MODES=1", "python3", FAKE_AGENT]},
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

/// The daemon as it starts: config.json (and `start-mode.json` beside it) read from disk.
fn hub(dir: &Path) -> Arc<Hub> {
    let mut cfg =
        Config::load_from_with(&dir.join("config.json"), &ProfileSources::none()).unwrap();
    cfg.store.mode = StoreMode::Memory;
    let store = acpmux::store::open(&cfg.store, Path::new("/nonexistent")).unwrap();
    Hub::new(cfg, store)
}

/// Points CMUX_NEXT_CONFIG_FILE and ACPMUX_HOME at `dir`; the caller holds `ENV`.
fn use_home(dir: &Path, settings: &str) -> PathBuf {
    let path = dir.join("cmux-next.json");
    std::fs::write(&path, settings).unwrap();
    // SAFETY: tests in this binary hold `ENV`; set before the daemon starts.
    unsafe {
        std::env::set_var("CMUX_NEXT_CONFIG_FILE", &path);
        std::env::set_var("ACPMUX_HOME", dir);
    }
    path
}

struct Client(mpsc::Sender<String>, mpsc::Receiver<String>, i64);

impl Client {
    fn new(hub: &Arc<Hub>, origin: Origin, auth: ConnAuth) -> Self {
        let (in_tx, in_rx) = mpsc::channel(64);
        let (out_tx, out_rx) = mpsc::channel(4096);
        tokio::spawn(serve_connection_authed(hub.clone(), in_rx, out_tx, origin, auth));
        Client(in_tx, out_rx, 0)
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

    /// The unix socket: the CLI, and the app's settings push.
    async fn socket(hub: &Arc<Hub>) -> Self {
        let mut c = Self::new(hub, Origin::Local, ConnAuth::LocalSocket);
        c.call("initialize", json!({"protocolVersion": 1})).await;
        c
    }

    async fn send(&mut self, m: &str, params: Value) {
        self.2 += 1;
        self.0.send(Message::request(self.2, m, params).to_line()).await.unwrap();
    }

    async fn call(&mut self, m: &str, params: Value) -> Value {
        self.send(m, params).await;
        let id = self.2;
        loop {
            let line = tokio::time::timeout(Duration::from_secs(30), self.1.recv())
                .await
                .expect("an answer in time")
                .expect("the connection stays open");
            let v: Value = serde_json::from_str(&line).unwrap();
            if v.get("id") == Some(&json!(id)) {
                return v;
            }
        }
    }

    /// The app's settings push (`ChatSettingsPush`) with the effective `sessions.allowFullAccess`
    /// (`null`: an older app that does not send it) and whether policy forces it.
    async fn push(&mut self, allowed: Value, managed: bool) {
        let params = json!({
            "enabled": true, "discovery": false, "roots": [], "managedRoots": [],
            "permissionMode": null, "permissionModeManaged": false,
            "allowFullAccess": allowed, "allowFullAccessManaged": managed,
        });
        let r = self.call("_acpmux/chat_settings", params).await;
        assert_eq!(r["result"]["applied"], true, "{r}");
    }

    /// A new chat on `harness` (with `policy`, if any): the whole reply.
    async fn new_chat(&mut self, dir: &Path, harness: &str, policy: Option<&str>) -> Value {
        let mut acpmux = json!({"harness": harness});
        if let Some(policy) = policy {
            acpmux["policy"] = json!(policy);
        }
        let params =
            json!({"cwd": dir.join("work"), "mcpServers": [], "_meta": {"acpmux": acpmux}});
        self.call("session/new", params).await
    }

    /// A new chat on `harness`: its id and the mode it runs in.
    async fn chat(&mut self, dir: &Path, harness: &str) -> (String, String) {
        let r = self.new_chat(dir, harness, None).await;
        let id = r["result"]["sessionId"].as_str().unwrap_or_else(|| panic!("{r}")).to_owned();
        (id.clone(), self.mode(&id).await)
    }

    /// A new chat with no modes on the `fake` harness, with `policy` if any: its id.
    async fn plain_chat(&mut self, dir: &Path, policy: Option<&str>) -> String {
        let r = self.new_chat(dir, "fake", policy).await;
        r["result"]["sessionId"].as_str().unwrap_or_else(|| panic!("{r}")).to_owned()
    }

    /// The mode the chat runs in, as `_acpmux/info` reports it now.
    async fn mode(&mut self, id: &str) -> String {
        let r = self.call("_acpmux/info", json!({"sessionId": id})).await;
        let mode = r["result"]["modes"]["currentModeId"].as_str().map(str::to_owned);
        mode.unwrap_or_else(|| panic!("no mode: {r}"))
    }

    /// Prompts chat `id` with a tool call that asks permission (the fake agent's `ask:`) and
    /// reports who answered it: `"policy"` when the session's policy approved it itself, `"asked"`
    /// when it waited for a person (then denied here, so the turn ends).
    async fn who_answers(&mut self, hub: &Hub, id: &str) -> &'static str {
        // Only this prompt's answer: the chat may have answered earlier ones.
        let after = hub.events(id, 0, 100_000).unwrap().last().map_or(0, |e| e.seq);
        self.send(
            "session/prompt",
            json!({"sessionId": id, "prompt": [{"type": "text", "text": "ask: deploy"}]}),
        )
        .await;
        let deadline = Instant::now() + Duration::from_secs(30);
        loop {
            let events = hub.events(id, after, 100_000).unwrap();
            if events.iter().any(|e| e.kind == "permission_auto") {
                return "policy";
            }
            if let Some(asked) = events.iter().find(|e| e.kind == "permission_request") {
                let permission = asked.msg["permissionId"].as_str().unwrap().to_owned();
                let r = self
                    .call(
                        "_acpmux/permission_respond",
                        json!({"sessionId": id, "permissionId": permission, "optionId": "no"}),
                    )
                    .await;
                assert!(r.get("error").is_none(), "{r}");
                return "asked";
            }
            assert!(Instant::now() < deadline, "no permission answer for {id}");
            tokio::time::sleep(Duration::from_millis(20)).await;
        }
    }
}

/// Finding 1: acpmux read only the settings file, so `sessions.allowFullAccess` off from MDM or
/// the team policy never reached it. The app now pushes the effective value, and a forced one
/// beats the file everywhere acpmux applies the setting.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn allow_full_access_forced_by_policy_reaches_new_chats_switches_and_resumes() {
    let _ = &HERMETIC;
    let _env = ENV.lock().await;
    let dir = home("managed", json!({}));
    // The file allows full access and starts new chats in it.
    let settings =
        use_home(&dir, r#"{"agents": {"defaultPermissionMode": "fullAccess"}, "sessions": {}}"#);
    let daemon = hub(&dir);
    let mut app = Client::app(&daemon).await;
    let mut socket = Client::socket(&daemon).await;
    let (claude, mode) = app.chat(&dir, "claude").await;
    assert_eq!(mode, "bypassPermissions");

    // MDM forces it off; the file still says nothing.
    socket.push(json!(false), true).await;
    let (codex, mode) = app.chat(&dir, "codex").await;
    assert_eq!(mode, "agent", "a new chat started in full access under a forced off");
    let r = app
        .call("session/set_mode", json!({"sessionId": codex, "modeId": "agent-full-access"}))
        .await;
    assert_eq!(r["error"]["data"]["reason"], "full_access_off", "{r}");
    // A restarted chat saved in full access comes back without it.
    let r = socket.call("_acpmux/sessions/restart_harness", json!({"sessions": [&claude]})).await;
    assert_eq!(r["result"]["restarted"], json!(1), "{r}");
    assert_eq!(app.mode(&claude).await, "default");

    // The forced value is kept beside config.json: a restarted daemon applies it before the app
    // pushes again.
    drop((app, socket));
    let daemon = hub(&dir);
    let mut app = Client::app(&daemon).await;
    let mut socket = Client::socket(&daemon).await;
    assert_eq!(app.chat(&dir, "codex").await.1, "agent", "the forced off was lost on restart");

    // Forced on beats the file's off (managed > user).
    std::fs::write(&settings, r#"{"agents": {"defaultPermissionMode": "fullAccess"}, "sessions": {"allowFullAccess": false}}"#).unwrap();
    socket.push(json!(true), true).await;
    assert_eq!(app.chat(&dir, "codex").await.1, "agent-full-access");
    // A forced value that is not a boolean is off.
    std::fs::write(
        &settings,
        r#"{"agents": {"defaultPermissionMode": "fullAccess"}, "sessions": {}}"#,
    )
    .unwrap();
    socket.push(json!("true"), true).await;
    assert_eq!(app.chat(&dir, "codex").await.1, "agent");

    // Unforced, the pushed value (a team default) applies only to a file with no key.
    socket.push(json!(false), false).await;
    assert_eq!(app.chat(&dir, "codex").await.1, "agent");
    std::fs::write(&settings, r#"{"agents": {"defaultPermissionMode": "fullAccess"}, "sessions": {"allowFullAccess": true}}"#).unwrap();
    assert_eq!(app.chat(&dir, "codex").await.1, "agent-full-access");
    // A push without the key (an older app) pushes nothing: the default (on) again.
    std::fs::write(
        &settings,
        r#"{"agents": {"defaultPermissionMode": "fullAccess"}, "sessions": {}}"#,
    )
    .unwrap();
    socket.push(Value::Null, false).await;
    assert_eq!(app.chat(&dir, "codex").await.1, "agent-full-access");
    let _ = std::fs::remove_dir_all(&dir);
}

/// Finding 2: approve-all (`yolo`) answers every permission request itself, which is full
/// access by policy. While the switch is off no one may ask for it, and a stored one asks.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn allow_full_access_off_holds_back_the_approve_all_policy() {
    let _ = &HERMETIC;
    let _env = ENV.lock().await;
    // config.json's own default policy is approve-all.
    let dir = home("policy", json!({"permissionPolicy": "approve-all"}));
    let settings = use_home(&dir, r#"{"sessions": {}}"#);
    let daemon = hub(&dir);
    let mut app = Client::app(&daemon).await;

    // Allowed: both a chat that names approve-all and one under config.json's run without asking.
    let named = app.plain_chat(&dir, Some("approve-all")).await;
    let configured = app.plain_chat(&dir, None).await;
    assert_eq!(app.who_answers(&daemon, &named).await, "policy");
    assert_eq!(app.who_answers(&daemon, &configured).await, "policy");

    // Off: no chat approves anything itself, whether its own policy or config.json's says
    // approve-all, and whether it started before or after the switch went off.
    std::fs::write(&settings, r#"{"sessions": {"allowFullAccess": false}}"#).unwrap();
    assert_eq!(app.who_answers(&daemon, &named).await, "asked", "a session's approve-all");
    assert_eq!(app.who_answers(&daemon, &configured).await, "asked", "config.json approve-all");
    let fresh = app.plain_chat(&dir, None).await;
    assert_eq!(app.who_answers(&daemon, &fresh).await, "asked", "a new chat under config.json");
    // Every request for approve-all is refused, whatever it is called.
    for policy in ["approve-all", "yolo"] {
        let r = app
            .call("_acpmux/set_policy", json!({"sessionId": configured, "policy": policy}))
            .await;
        assert_eq!(r["error"]["data"]["reason"], "full_access_off", "set_policy {policy}: {r}");
        let r = app.call("_acpmux/set_default_policy", json!({"policy": policy})).await;
        assert_eq!(
            r["error"]["data"]["reason"], "full_access_off",
            "set_default_policy {policy}: {r}"
        );
        let r = app.new_chat(&dir, "fake", Some(policy)).await;
        assert_eq!(r["error"]["data"]["reason"], "full_access_off", "session/new {policy}: {r}");
    }
    // An asking policy is still set.
    let r = app.call("_acpmux/set_policy", json!({"sessionId": named, "policy": "ask"})).await;
    assert!(r.get("error").is_none(), "{r}");

    // On again: the stored approve-all applies again.
    std::fs::write(&settings, r#"{"sessions": {"allowFullAccess": true}}"#).unwrap();
    let again = app.plain_chat(&dir, Some("approve-all")).await;
    assert_eq!(app.who_answers(&daemon, &again).await, "policy");
    let _ = std::fs::remove_dir_all(&dir);
}

/// Finding 3: the boolean is strict, and the mode rule is an allowlist that fails closed.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn allow_full_access_is_strict_and_an_unknown_mode_counts_as_full_access() {
    let _ = &HERMETIC;
    let _env = ENV.lock().await;
    let dir = home("strict", json!({}));
    let settings = use_home(&dir, r#"{"sessions": {"allowFullAccess": 0}}"#);
    let daemon = hub(&dir);
    let mut app = Client::app(&daemon).await;

    // `0` and `"false"` are off: no chat starts in full access, no switch reaches it.
    for off in
        [r#"{"sessions": {"allowFullAccess": 0}}"#, r#"{"sessions": {"allowFullAccess": "false"}}"#]
    {
        std::fs::write(&settings, off).unwrap();
        let (chat, mode) = app.chat(&dir, "codex").await;
        assert_eq!(mode, "agent", "{off}");
        let r = app
            .call("session/set_mode", json!({"sessionId": chat, "modeId": "agent-full-access"}))
            .await;
        assert_eq!(r["error"]["data"]["reason"], "full_access_off", "{off}: {r}");
    }

    // A mode no one reviewed is full access while off, by set_mode or the mode option.
    std::fs::write(&settings, r#"{"sessions": {"allowFullAccess": false}}"#).unwrap();
    let (chat, _) = app.chat(&dir, "codex").await;
    let r = app.call("session/set_mode", json!({"sessionId": chat, "modeId": "turbo"})).await;
    assert_eq!(r["error"]["data"]["reason"], "full_access_off", "{r}");
    let r = app
        .call(
            "session/set_config_option",
            json!({"sessionId": chat, "configId": "mode", "value": "turbo"}),
        )
        .await;
    assert_eq!(r["error"]["data"]["reason"], "full_access_off", "{r}");
    // A reviewed mode that asks still switches, and another option's value is judged by its
    // markers only.
    let r = app.call("session/set_mode", json!({"sessionId": chat, "modeId": "read-only"})).await;
    assert!(r.get("error").is_none(), "{r}");
    let r = app
        .call(
            "session/set_config_option",
            json!({"sessionId": chat, "configId": "sandbox", "value": "turbo"}),
        )
        .await;
    assert_ne!(r["error"]["data"]["reason"], "full_access_off", "{r}");
    let _ = std::fs::remove_dir_all(&dir);
}
