//! The cmux setting `agents.defaultPermissionMode` in the app's settings
//! file (JSONC, read at each new chat) chooses a new chat's start mode when
//! acpmux config.json names none; a settings file acpmux cannot read, or a
//! value it does not know, never gives full access (cx-wx93i). A change to
//! the setting after the person's latest mode pick wins over that pick, and a
//! later pick wins again. Its own test
//! binary: it sets CMUX_NEXT_CONFIG_FILE, which every session start reads.

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

const FAKE_APP_SERVER: &str =
    concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_codex_app_server.py");

/// A home with `codex` (a program named `codex` run as `codex app-server`,
/// bridged in process). `extra` is merged into config.json.
fn home(name: &str, extra: Value) -> PathBuf {
    let dir = std::env::temp_dir()
        .join(format!("acpmux-start-mode-settings-{name}-{}", std::process::id()));
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
    let mut cfg =
        Config::load_from_with(&dir.join("config.json"), &ProfileSources::none()).unwrap();
    cfg.store.mode = StoreMode::Memory;
    let store = acpmux::store::open(&cfg.store, Path::new("/nonexistent")).unwrap();
    Hub::new(cfg, store)
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

#[tokio::test]
async fn start_mode_answer_and_new_chats_follow_the_settings_file_never_full_access_unreadable() {
    let dir = home("settings", json!({}));
    let settings = dir.join("cmux-next.json");
    // JSONC as the app writes it: an inline comment and a trailing comma.
    std::fs::write(
        &settings,
        "{\n  \"agents\": {\"defaultPermissionMode\": \"ask\", /* safer */},\n  // more\n}\n",
    )
    .unwrap();
    // SAFETY: the only test in this binary, set before the daemon starts.
    unsafe { std::env::set_var("CMUX_NEXT_CONFIG_FILE", &settings) };
    let daemon = hub(&dir);
    let mut app = Client::app(&daemon).await;
    assert_eq!(app.chat(&dir, "codex").await.1, "ask");
    // `_acpmux/start_mode` answers from the same setting, and says so.
    let r =
        app.call("_acpmux/start_mode", json!({"harness": "codex", "cwd": dir.join("work")})).await;
    assert_eq!(r["result"]["modeId"], "ask", "{r}");
    assert_eq!(r["result"]["level"], "ask", "{r}");
    assert_eq!(r["result"]["source"], "settings", "{r}");
    // Read at each new chat.
    std::fs::write(&settings, r#"{"agents": {"defaultPermissionMode": "fullAccess"}}"#).unwrap();
    assert_eq!(app.chat(&dir, "codex").await.1, "agent-full-access");
    // No key: full access, the default.
    std::fs::write(&settings, r#"{"agents": {}}"#).unwrap();
    assert_eq!(app.chat(&dir, "codex").await.1, "agent-full-access");
    // A file that does not parse, or a value this build does not know: the
    // harness's own mode, never full access.
    std::fs::write(&settings, r#"{"agents": {"defaultPermissionMode": "ask""#).unwrap();
    assert_eq!(app.chat(&dir, "codex").await.1, "agent");
    std::fs::write(&settings, r#"{"agents": {"defaultPermissionMode": "Ask"}}"#).unwrap();
    assert_eq!(app.chat(&dir, "codex").await.1, "agent");

    // The person's latest choice wins, whether it is a pick in a chat or a
    // change to the setting (Leo 2026-10-18: users set their own default).
    std::fs::write(&settings, r#"{"agents": {"defaultPermissionMode": "fullAccess"}}"#).unwrap();
    let (chat, mode) = app.chat(&dir, "codex").await;
    assert_eq!(mode, "agent-full-access");
    // A pick after the setting: new chats follow the pick.
    let r = app.call("session/set_mode", json!({"sessionId": chat, "modeId": "ask"})).await;
    assert!(r.get("error").is_none(), "{r}");
    assert_eq!(app.chat(&dir, "codex").await.1, "ask");
    // The setting changes after the pick: new chats follow the setting.
    std::fs::write(&settings, r#"{"agents": {"defaultPermissionMode": "standard"}}"#).unwrap();
    assert_eq!(app.chat(&dir, "codex").await.1, "agent");
    let r =
        app.call("_acpmux/start_mode", json!({"harness": "codex", "cwd": dir.join("work")})).await;
    assert_eq!(r["result"]["source"], "settings", "{r}");
    // A pick after that change wins again, also when it picks the level it
    // picked before the change.
    let r = app.call("session/set_mode", json!({"sessionId": chat, "modeId": "ask"})).await;
    assert!(r.get("error").is_none(), "{r}");
    assert_eq!(app.chat(&dir, "codex").await.1, "ask");
    let r =
        app.call("_acpmux/start_mode", json!({"harness": "codex", "cwd": dir.join("work")})).await;
    assert_eq!(r["result"]["source"], "pick", "{r}");
    // Removing the key is a change too: the default (full access) applies.
    std::fs::write(&settings, r#"{"agents": {}}"#).unwrap();
    assert_eq!(app.chat(&dir, "codex").await.1, "agent-full-access");

    // A catalog reload reads both: a pick of `standard` made under `ask`
    // (another daemon, or the file restored) wins while the setting is `ask`.
    std::fs::write(&settings, r#"{"agents": {"defaultPermissionMode": "ask"}}"#).unwrap();
    let edit = |pick: Value| {
        let path = dir.join("config.json");
        let mut config: Value = serde_json::from_slice(&std::fs::read(&path).unwrap()).unwrap();
        for (k, v) in pick.as_object().unwrap() {
            match v {
                Value::Null => config.as_object_mut().unwrap().remove(k),
                v => config.as_object_mut().unwrap().insert(k.clone(), v.clone()),
            };
        }
        std::fs::write(&path, serde_json::to_vec_pretty(&config).unwrap()).unwrap();
    };
    edit(json!({"lastPermissionMode": "standard", "lastPermissionModeSetting": "\"ask\""}));
    daemon.reload_catalog().await.unwrap();
    assert_eq!(app.chat(&dir, "codex").await.1, "agent");
    drop(app);
    drop(daemon);

    // A pick saved before acpmux recorded the setting beside it (an upgrade)
    // keeps winning, and the setting as it is now is recorded, so a later
    // change to the setting still wins over it.
    edit(json!({"lastPermissionMode": "ask", "lastPermissionModeSetting": null}));
    let daemon = hub(&dir);
    let mut app = Client::app(&daemon).await;
    assert_eq!(app.chat(&dir, "codex").await.1, "ask");
    std::fs::write(&settings, r#"{"agents": {"defaultPermissionMode": "fullAccess"}}"#).unwrap();
    assert_eq!(app.chat(&dir, "codex").await.1, "agent-full-access");
    let _ = std::fs::remove_dir_all(&dir);
}
