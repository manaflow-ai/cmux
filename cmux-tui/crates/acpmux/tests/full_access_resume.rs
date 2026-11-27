//! `sessions.allowFullAccess` turned off after chats ran in full access: a
//! restarted Claude chat (respawned with its saved `--permission-mode`) and a
//! restarted ACP chat (its saved mode and options replayed) both come back in
//! the harness's own mode, not full access. Its own test binary: it sets
//! CMUX_NEXT_CONFIG_FILE.

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

const FAKE_CLAUDE: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_claude.py");
const FAKE_AGENT: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");

const FAKE_APP_SERVER: &str =
    concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_codex_app_server.py");

/// A home with `codex` (a program named `codex` run as `codex app-server`,
/// bridged in process). `extra` is merged into config.json.
fn home(name: &str, extra: Value) -> PathBuf {
    let dir = std::env::temp_dir()
        .join(format!("acpmux-full-access-resume-{name}-{}", std::process::id()));
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
            // An ACP adapter whose session/load restores the chat's full-access mode itself.
            "restores": {"argv": ["env", "FAKE_FULL_ACCESS=1", "FAKE_LOAD_MODE=full-access", "python3", FAKE_AGENT]},
            // One that restores full access and offers no lower mode after the load.
            "stuck": {"argv": ["env", "FAKE_FULL_ACCESS=1", "FAKE_LOAD_MODE=full-access", "FAKE_LOAD_ONLY_MODE=1", "python3", FAKE_AGENT]},
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

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_restarted_chat_saved_in_full_access_comes_back_without_it_when_off() {
    let dir = home("resume", json!({}));
    let settings = dir.join("cmux-next.json");
    std::fs::write(&settings, r#"{"sessions": {}}"#).unwrap();
    // SAFETY: the only test in this binary, set before the daemon starts.
    unsafe { std::env::set_var("CMUX_NEXT_CONFIG_FILE", &settings) };
    let daemon = hub(&dir);
    let mut app = Client::app(&daemon).await;

    // Allowed (the default start level is full access): both chats run in it.
    let (claude, mode) = app.chat(&dir, "claude").await;
    assert_eq!(mode, "bypassPermissions");
    let (codex, mode) = app.chat(&dir, "codex").await;
    assert_eq!(mode, "agent-full-access");
    let (restores, mode) = app.chat(&dir, "restores").await;
    assert_eq!(mode, "full-access");
    let (stuck, mode) = app.chat(&dir, "stuck").await;
    assert_eq!(mode, "full-access");

    // Turned off, then both harnesses restart: neither gets full access back.
    std::fs::write(&settings, r#"{"sessions": {"allowFullAccess": false}}"#).unwrap();
    // The unix socket (the CLI's `cmux harness restart`): only it may restart a harness.
    let mut cli = Client::new(&daemon, Origin::Local, ConnAuth::LocalSocket);
    let r = cli
        .call("_acpmux/sessions/restart_harness", json!({"sessions": [&claude, &codex, &restores]}))
        .await;
    assert_eq!(r["result"]["restarted"], json!(3), "{r}");
    // Each comes back on its own harness, in that harness's mode that asks: Claude's `default`,
    // the Codex bridge's `agent`, and for the harness that restored full access on load, the mode
    // acpmux then sent it explicitly (`normal`, its first mode that does not skip approvals).
    for (id, harness, mode) in [
        (&claude, "claude", "default"),
        (&codex, "codex", "agent"),
        (&restores, "restores", "normal"),
    ] {
        let r = app.call("_acpmux/info", json!({"sessionId": id})).await;
        assert_eq!(r["result"]["harness"], harness, "{r}");
        assert_eq!(r["result"]["modes"]["currentModeId"], mode, "{harness}: {r}");
    }
    // A chat that cannot leave full access does not run: its restart fails, and so does a prompt.
    let r = cli.call("_acpmux/sessions/restart_harness", json!({"sessions": [&stuck]})).await;
    assert_eq!(r["result"]["failed"], json!(1), "{r}");
    let r = app
        .call(
            "session/prompt",
            json!({"sessionId": stuck, "prompt": [{"type": "text", "text": "hi"}]}),
        )
        .await;
    assert_eq!(r["error"]["data"]["reason"], "full_access_off", "{r}");
    let _ = std::fs::remove_dir_all(&dir);
}
