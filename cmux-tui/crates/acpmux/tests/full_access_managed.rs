//! `sessions.allowFullAccess` as MDM or the team policy forces it, pushed by the app
//! (`_acpmux/chat_settings` `allowFullAccess` + `allowFullAccessManaged`, which acpmux keeps in
//! start-mode.json). claude-sr2, 2026-10-25: "an MDM-managed value is an upper bound the user
//! can't override. If MDM sets allowFullAccess=false, Full access is unavailable and the mode menu
//! says "Managed by your organization". If MDM is unset, nothing changes."
//! Its own test binary: it sets CMUX_NEXT_CONFIG_FILE, which every start and switch reads.

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
const FAKE_AGENT: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");

/// A home with `codex` (a program named `codex` run as `codex app-server`, bridged in process),
/// whose new chats start in full access (no `agents.defaultPermissionMode`).
fn home(name: &str) -> PathBuf {
    let dir = std::env::temp_dir()
        .join(format!("acpmux-full-access-managed-{name}-{}", std::process::id()));
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
    let config = json!({
        "harnesses": {
            "codex": {"argv": [codex, "app-server"]},
            // Profiles that pin their mode in argv: two in full access, one that asks.
            "pinned-yolo": {"argv": ["python3", FAKE_AGENT, "--yolo"]},
            "pinned-bypass": {"argv": ["python3", FAKE_AGENT, "--permission-mode=bypassPermissions"]},
            "pinned-sandbox": {"argv": ["python3", FAKE_AGENT, "-sdanger-full-access", "-a", "never"]},
            "pinned-config": {"argv": ["python3", FAKE_AGENT, "-csandbox_mode=danger-full-access"]},
            "pinned-y": {"argv": ["python3", FAKE_AGENT, "-y"]},
            "pinned-asks": {"argv": ["python3", FAKE_AGENT, "--permission-mode", "default"]},
            // Harnesses that move themselves into full access: one that declares no modes (and
            // reports one anyway), one through a config option other than its mode.
            "self-moder": {"argv": ["python3", FAKE_AGENT], "env": {"FAKE_NO_MODES": "1"}},
            "self-optioner": {"argv": ["python3", FAKE_AGENT]},
        },
        "defaultHarness": "codex",
        "permissionPolicy": "ask",
        "webRoots": [dir.join("work")],
    });
    std::fs::write(dir.join("config.json"), serde_json::to_vec_pretty(&config).unwrap()).unwrap();
    dir
}

/// The daemon as it starts: config.json (and start-mode.json beside it) read from disk.
fn hub(dir: &Path) -> Arc<Hub> {
    let mut cfg =
        Config::load_from_with(&dir.join("config.json"), &ProfileSources::none()).unwrap();
    cfg.store.mode = StoreMode::Memory;
    let store = acpmux::store::open(&cfg.store, Path::new("/nonexistent")).unwrap();
    Hub::new(cfg, store)
}

struct Client(mpsc::Sender<String>, mpsc::Receiver<String>, i64, Option<Box<Client>>);

impl Client {
    fn new(hub: &Arc<Hub>, origin: Origin, auth: ConnAuth) -> Self {
        let (in_tx, in_rx) = mpsc::channel(64);
        let (out_tx, out_rx) = mpsc::channel(4096);
        tokio::spawn(serve_connection_authed(hub.clone(), in_rx, out_tx, origin, auth));
        Client(in_tx, out_rx, 0, None)
    }

    /// The app's agent pane: a LocalApp connection that proved this launch's person key, and the
    /// app's own unix-socket connection, which pushes the settings (`_acpmux/chat_settings` is
    /// served only there).
    async fn app(hub: &Arc<Hub>) -> Self {
        hub.person.enroll(KEY, true).unwrap();
        let mut c = Self::new(hub, Origin::LocalApp, ConnAuth::LocalApp);
        c.3 = Some(Box::new(Self::new(hub, Origin::Local, ConnAuth::LocalSocket)));
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
        let id = self.send(m, params).await;
        self.reply(id).await
    }

    async fn send(&mut self, m: &str, params: Value) -> i64 {
        self.2 += 1;
        self.0.send(Message::request(self.2, m, params).to_line()).await.unwrap();
        self.2
    }

    async fn reply(&mut self, id: i64) -> Value {
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

    /// The app's settings push, with `full_access` merged in (the two full-access keys, or none).
    async fn push(&mut self, full_access: Value) {
        let mut params =
            json!({"enabled": true, "discovery": false, "roots": [], "managedRoots": []});
        for (k, v) in full_access.as_object().unwrap() {
            params[k] = v.clone();
        }
        let socket = self.3.as_mut().expect("the app's socket connection");
        let r = Box::pin(socket.call("_acpmux/chat_settings", params)).await;
        assert_eq!(r["result"]["applied"], true, "{r}");
    }

    /// `_acpmux/start_mode` for codex: the whole answer.
    async fn start_mode(&mut self, dir: &Path) -> Value {
        let r = self
            .call("_acpmux/start_mode", json!({"harness": "codex", "cwd": dir.join("work")}))
            .await;
        r["result"].clone()
    }

    /// A new chat: its id and the mode it runs in.
    async fn chat(&mut self, dir: &Path) -> (String, String) {
        let params = json!({"cwd": dir.join("work"), "mcpServers": [], "_meta": {"acpmux": {"harness": "codex"}}});
        let r = self.call("session/new", params).await;
        let id = r["result"]["sessionId"].as_str().unwrap_or_else(|| panic!("{r}")).to_owned();
        let info = self.call("_acpmux/info", json!({"sessionId": id})).await;
        let mode = info["result"]["modes"]["currentModeId"].as_str().map(str::to_owned);
        (id, mode.unwrap_or_else(|| panic!("no mode: {info}")))
    }

    /// A chat on `harness` and its first turn: the refusal of either, or none.
    async fn run_on(&mut self, dir: &Path, harness: &str) -> Option<Value> {
        let params = json!({"cwd": dir.join("work"), "mcpServers": [], "_meta": {"acpmux": {"harness": harness}}});
        let r = self.call("session/new", params).await;
        if r.get("error").is_some() {
            return Some(r);
        }
        let id = r["result"]["sessionId"].as_str().unwrap_or_else(|| panic!("{r}")).to_owned();
        let prompt = json!({"sessionId": id, "prompt": [{"type": "text", "text": "argv"}]});
        let r = self.call("session/prompt", prompt).await;
        r.get("error").is_some().then_some(r)
    }

    /// A profile that pins full access in its argv (`--yolo`, `--permission-mode=bypassPermissions`)
    /// runs only while full access is not managed off; one that pins an asking mode always runs.
    async fn pinned_profiles(&mut self, dir: &Path, managed_off: bool, why: &str) {
        for harness in
            ["pinned-yolo", "pinned-bypass", "pinned-sandbox", "pinned-config", "pinned-y"]
        {
            let refusal = self.run_on(dir, harness).await;
            if managed_off {
                let r = refusal.unwrap_or_else(|| panic!("{why}: {harness} ran in full access"));
                assert_eq!(
                    r["error"]["data"]["reason"], "full_access_off",
                    "{why}: {harness}: {r}"
                );
            } else {
                assert!(refusal.is_none(), "{why}: {harness}: {refusal:?}");
            }
        }
        let refusal = self.run_on(dir, "pinned-asks").await;
        assert!(refusal.is_none(), "{why}: pinned-asks: {refusal:?}");
    }

    /// A chat on `harness` whose first turn ran: its id.
    async fn ran_on(&mut self, dir: &Path, harness: &str) -> String {
        let params = json!({"cwd": dir.join("work"), "mcpServers": [], "_meta": {"acpmux": {"harness": harness}}});
        let r = self.call("session/new", params).await;
        let id = r["result"]["sessionId"].as_str().unwrap_or_else(|| panic!("{r}")).to_owned();
        let r = self.prompt(&id, "argv").await;
        assert!(r.get("error").is_none(), "{harness}: {r}");
        id
    }

    async fn prompt(&mut self, id: &str, text: &str) -> Value {
        let prompt = json!({"sessionId": id, "prompt": [{"type": "text", "text": text}]});
        self.call("session/prompt", prompt).await
    }

    async fn switch(&mut self, id: &str, mode: &str) -> Value {
        self.call("session/set_mode", json!({"sessionId": id, "modeId": mode})).await
    }

    /// Full access is available: the start mode names it with no managed mark, a new chat starts
    /// in it, and a chat switches into it.
    async fn full_access_available(&mut self, dir: &Path, why: &str) {
        let (chat, mode) = self.chat(dir).await;
        assert_eq!(mode, "agent-full-access", "{why}");
        // Asked after a chat of the harness reported its modes, so acpmux can name the mode.
        let start = self.start_mode(dir).await;
        assert_eq!(start["modeId"], "agent-full-access", "{why}: {start}");
        assert!(start.get("fullAccess").is_none(), "{why}: {start}");
        let r = self.switch(&chat, "ask").await;
        assert!(r.get("error").is_none(), "{why}: {r}");
        let r = self.switch(&chat, "agent-full-access").await;
        assert!(r.get("error").is_none(), "{why}: {r}");
    }

    /// Full access is unavailable and managed: the start mode says `fullAccess: "managed"` and
    /// names no full-access mode, a new chat starts in the harness's own mode, and a switch into
    /// full access is refused.
    async fn full_access_managed_off(&mut self, dir: &Path, why: &str) {
        let start = self.start_mode(dir).await;
        assert_eq!(start["fullAccess"], "managed", "{why}: {start}");
        assert_ne!(start["modeId"], "agent-full-access", "{why}: {start}");
        let (chat, mode) = self.chat(dir).await;
        assert_eq!(mode, "agent", "{why}");
        let r = self.switch(&chat, "agent-full-access").await;
        assert_eq!(r["error"]["data"]["reason"], "full_access_off", "{why}: {r}");
        // Nor the policy form of full access: approve-all is refused.
        let r = self
            .call("_acpmux/set_policy", json!({"sessionId": chat, "policy": "approve-all"}))
            .await;
        assert_eq!(r["error"]["data"]["reason"], "full_access_off", "{why}: {r}");
    }
}

#[tokio::test]
async fn a_full_access_off_mdm_forces_is_an_upper_bound_and_unset_changes_nothing() {
    let dir = home("bound");
    let settings = dir.join("cmux-next.json");
    // The person's own settings allow full access.
    std::fs::write(&settings, r#"{"sessions": {"allowFullAccess": true}}"#).unwrap();
    // SAFETY: the only test in this binary, set before the daemon starts.
    unsafe { std::env::set_var("CMUX_NEXT_CONFIG_FILE", &settings) };
    let daemon = hub(&dir);
    let mut app = Client::app(&daemon).await;

    // MDM unset: nothing changes, whether the push has no keys (an older app) or an unforced value.
    app.push(json!({})).await;
    app.full_access_available(&dir, "no keys").await;
    app.pinned_profiles(&dir, false, "no keys").await;
    app.push(json!({"allowFullAccess": false, "allowFullAccessManaged": false})).await;
    app.full_access_available(&dir, "an unforced off").await;

    // MDM sets it off: unavailable over the person's own on, and the answer says it is managed.
    app.push(json!({"allowFullAccess": false, "allowFullAccessManaged": true})).await;
    app.full_access_managed_off(&dir, "MDM off").await;
    app.pinned_profiles(&dir, true, "MDM off").await;
    agents_that_move_into_full_access_by_themselves_end(&mut app, &dir).await;
    // A forced value that is not `true` is off too.
    app.push(json!({"allowFullAccess": "true", "allowFullAccessManaged": true})).await;
    app.full_access_managed_off(&dir, "MDM \"true\"").await;
    app.push(json!({"allowFullAccess": false, "allowFullAccessManaged": true})).await;

    // It holds across a daemon restart, before the app pushes again (start-mode.json).
    drop(app);
    let daemon = hub(&dir);
    let mut app = Client::app(&daemon).await;
    app.full_access_managed_off(&dir, "after a restart").await;
    app.pinned_profiles(&dir, true, "after a restart").await;

    // MDM unset again: full access is back.
    app.push(json!({})).await;
    app.full_access_available(&dir, "MDM unset again").await;
    running_agents_take_no_more_work_once_mdm_turns_it_off(&daemon, &mut app, &dir).await;

    // An upper bound only: MDM forcing it on does not raise the person's own off.
    std::fs::write(&settings, r#"{"sessions": {"allowFullAccess": false}}"#).unwrap();
    app.push(json!({"allowFullAccess": true, "allowFullAccessManaged": true})).await;
    let start = app.start_mode(&dir).await;
    assert!(start.get("fullAccess").is_none(), "{start}");
    let (chat, mode) = app.chat(&dir).await;
    assert_eq!(mode, "agent");
    let r = app.switch(&chat, "agent-full-access").await;
    assert_eq!(r["error"]["data"]["reason"], "full_access_off", "{r}");
    let _ = std::fs::remove_dir_all(&dir);
}

/// Review of #23322: under MDM off, an agent that moves itself into full access in a form acpmux
/// sets no mode for (a mode its harness reports without declaring modes, a config option other
/// than `mode`) ends; its chat's next turn runs on a new agent.
async fn agents_that_move_into_full_access_by_themselves_end(app: &mut Client, dir: &Path) {
    for (harness, turn) in [
        ("self-moder", "set-mode: bypassPermissions"),
        ("self-optioner", "set-option: sandbox danger-full-access"),
    ] {
        let chat = app.ran_on(dir, harness).await;
        let r = app.prompt(&chat, turn).await;
        assert!(r.get("error").is_none(), "{harness}: {r}");
        let mut ended = false;
        for _ in 0..500 {
            let r = app.call("_acpmux/events", json!({"sessionId": chat, "limit": 500})).await;
            if r.to_string().contains("full_access_ended") {
                ended = true;
                break;
            }
            tokio::time::sleep(Duration::from_millis(20)).await;
        }
        assert!(ended, "{harness}: the agent ran on after it moved into full access by itself");
        let r = app.prompt(&chat, "argv").await;
        assert!(r.get("error").is_none(), "{harness}: the next turn: {r}");
    }
}

/// Review of #23322: an agent already running in full access when MDM forces it off takes no more
/// work in it. A pinned profile's agent ends and its chat is refused; a chat in a full-access mode
/// starts again in a mode that asks. Starts and ends with MDM unset.
async fn running_agents_take_no_more_work_once_mdm_turns_it_off(
    daemon: &Arc<Hub>,
    app: &mut Client,
    dir: &Path,
) {
    let pinned = app.ran_on(dir, "pinned-yolo").await;
    let (moded, mode) = app.chat(dir).await;
    assert_eq!(mode, "agent-full-access");
    let r = app.prompt(&moded, "hi").await;
    assert!(r.get("error").is_none(), "{r}");
    // A turn of the pinned agent runs when MDM turns full access off: it ends with its agent.
    let mut turns = Client::new(daemon, Origin::Local, ConnAuth::LocalSocket);
    let prompt = json!({"sessionId": pinned, "prompt": [{"type": "text", "text": "until-cancel"}]});
    let turn = turns.send("session/prompt", prompt).await;
    let mut running = false;
    for _ in 0..500 {
        let r = app.call("_acpmux/events", json!({"sessionId": pinned, "limit": 500})).await;
        if r.to_string().contains("\"running\"") {
            running = true;
            break;
        }
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    assert!(running, "the pinned agent's turn never started");

    app.push(json!({"allowFullAccess": false, "allowFullAccessManaged": true})).await;
    let ended = tokio::time::timeout(Duration::from_secs(10), turns.reply(turn)).await;
    assert!(ended.is_ok(), "the full-access turn ran on after MDM turned full access off");
    let r = app.prompt(&pinned, "argv").await;
    assert_eq!(
        r["error"]["data"]["reason"], "full_access_off",
        "the pinned agent took more work: {r}"
    );
    let r = app.prompt(&moded, "hi").await;
    assert!(r.get("error").is_none(), "{r}");
    let info = app.call("_acpmux/info", json!({"sessionId": moded})).await;
    assert_ne!(
        info["result"]["modes"]["currentModeId"], "agent-full-access",
        "the chat ran on in full access: {info}"
    );
    app.push(json!({})).await;
}
