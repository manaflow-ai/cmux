//! The cmux setting `sessions.allowFullAccess` (Settings > Agents > Agent
//! Sessions) turned off: no chat starts in a mode that skips every approval,
//! and no client (the app, the CLI, a script) switches one into it, by
//! `session/set_mode` or by any config option. A settings file acpmux cannot
//! read fails closed. Its own test binary: it sets CMUX_NEXT_CONFIG_FILE,
//! which every session start and every mode switch reads.

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
        .join(format!("acpmux-full-access-setting-{name}-{}", std::process::id()));
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
async fn full_access_off_keeps_every_chat_out_of_full_access() {
    let dir = home("off", json!({}));
    let settings = dir.join("cmux-next.json");
    // The default start level is full access (no agents.defaultPermissionMode).
    std::fs::write(&settings, r#"{"sessions": {"allowFullAccess": false}}"#).unwrap();
    // SAFETY: the only test in this binary, set before the daemon starts.
    unsafe { std::env::set_var("CMUX_NEXT_CONFIG_FILE", &settings) };
    let daemon = hub(&dir);
    let mut app = Client::app(&daemon).await;

    // A new chat starts in the harness's own mode, not full access.
    let (chat, mode) = app.chat(&dir, "codex").await;
    assert_eq!(mode, "agent");
    // A switch into full access is refused, by set_mode and by any config option's value.
    let r = app
        .call("session/set_mode", json!({"sessionId": chat, "modeId": "agent-full-access"}))
        .await;
    assert_eq!(r["error"]["data"]["reason"], "full_access_off", "{r}");
    let r = app
        .call(
            "session/set_config_option",
            json!({"sessionId": chat, "configId": "approvals", "value": "agent-full-access"}),
        )
        .await;
    assert_eq!(r["error"]["data"]["reason"], "full_access_off", "{r}");
    // Any id the shared rule (spec/full-access-modes.json) names, not only the modes acpmux picks.
    for value in
        ["danger-full-access", "auto-approve", "Bypass Permissions", "dangerously_skip_permissions"]
    {
        let r = app
            .call(
                "session/set_config_option",
                json!({"sessionId": chat, "configId": "sandbox", "value": value}),
            )
            .await;
        assert_eq!(r["error"]["data"]["reason"], "full_access_off", "{value}: {r}");
    }
    // Ids that only contain "full" do not skip approvals (Codex's full-auto still asks): not refused.
    for value in ["full-auto", "fullscreen", "full-context"] {
        let r = app
            .call(
                "session/set_config_option",
                json!({"sessionId": chat, "configId": "sandbox", "value": value}),
            )
            .await;
        assert_ne!(r["error"]["data"]["reason"], "full_access_off", "{value}: {r}");
    }
    assert_eq!(app.mode(&chat).await, "agent");
    // Other modes still switch.
    let r = app.call("session/set_mode", json!({"sessionId": chat, "modeId": "ask"})).await;
    assert!(r.get("error").is_none(), "{r}");

    // A settings file that cannot be read fails closed.
    std::fs::write(&settings, r#"{"sessions": {"allowFullAccess": tru"#).unwrap();
    let r = app
        .call("session/set_mode", json!({"sessionId": chat, "modeId": "agent-full-access"}))
        .await;
    assert_eq!(r["error"]["data"]["reason"], "full_access_off", "{r}");

    // Turned back on (or the key removed): full access switches again, and new chats start in the
    // default, full access, again.
    std::fs::write(&settings, r#"{"sessions": {}}"#).unwrap();
    let r = app
        .call("session/set_mode", json!({"sessionId": chat, "modeId": "agent-full-access"}))
        .await;
    assert!(r.get("error").is_none(), "{r}");
    assert_eq!(app.chat(&dir, "codex").await.1, "agent-full-access");
    // Off again: the default no longer starts new chats in full access.
    std::fs::write(&settings, r#"{"sessions": {"allowFullAccess": false}}"#).unwrap();
    assert_eq!(app.chat(&dir, "codex").await.1, "agent");
    let _ = std::fs::remove_dir_all(&dir);
}
