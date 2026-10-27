//! `sessions.allowFullAccess` as MDM or the team policy forces it, pushed by the app
//! (`_acpmux/chat_settings` `allowFullAccess` + `allowFullAccessManaged`, which acpmux keeps in
//! start-mode.json). claude-sr2, 2026-10-25: "an MDM-managed value is an upper bound the user
//! can't override. If MDM sets allowFullAccess=false, Full access is unavailable and the mode menu
//! says "Managed by your organization". If MDM is unset, nothing changes."
//! Its own test binary: it sets CMUX_NEXT_CONFIG_FILE, which every start and switch reads.
//!
//! One case per form and path the reviews of #23322 found (`CASES`), each on its own daemon, run
//! in turn: the test names every case that fails, so a run on older code lists what it lacked.

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
const FAKE_CLAUDE: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_claude.py");

/// Where case `name` keeps its home.
fn home_path(name: &str) -> PathBuf {
    let slug: String =
        name.chars().map(|c| if c.is_ascii_alphanumeric() { c } else { '-' }).collect();
    std::env::temp_dir().join(format!(
        "acpmux-fam-{}-{}",
        &slug[..slug.len().min(40)],
        std::process::id()
    ))
}

/// A home with `codex` (a program named `codex` run as `codex app-server`, bridged in process),
/// whose new chats start in full access (no `agents.defaultPermissionMode`).
fn home(name: &str) -> PathBuf {
    let dir = home_path(name);
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
    // Profiles pinning full access whose every start leaves its pid in `<name>-started`, and
    // that hang while `hang` exists: an ACP one (the fake agent), and a Claude one, which only a
    // live model list starts here (it lists nothing).
    let marked = |name: &str, then: String| {
        let path = dir.join("bin").join(name);
        let (started, hang) = (dir.join(format!("{name}-started")), dir.join("hang"));
        let script = format!(
            "#!/bin/sh\necho $$ >> '{}'\n[ -e '{}' ] && exec sleep 60\n{then}\n",
            started.display(),
            hang.display()
        );
        std::fs::write(&path, script).unwrap();
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o755)).unwrap();
        path
    };
    let marked_acp = marked("pinned-marked", format!("exec python3 '{FAKE_AGENT}' \"$@\""));
    let marked_claude = marked("claude-pinned", "exit 1".to_owned());
    let config = json!({
        "harnesses": {
            "codex": {"argv": [codex, "app-server"]},
            // Profiles that pin their mode in argv: two in full access, one that asks.
            "pinned-yolo": {"argv": ["python3", FAKE_AGENT, "--yolo"]},
            "pinned-bypass": {"argv": ["python3", FAKE_AGENT, "--permission-mode=bypassPermissions"]},
            "pinned-sandbox": {"argv": ["python3", FAKE_AGENT, "-sdanger-full-access", "-a", "never"]},
            "pinned-config": {"argv": ["python3", FAKE_AGENT, "-csandbox_mode=danger-full-access"]},
            "pinned-y": {"argv": ["python3", FAKE_AGENT, "-y"]},
            "pinned-approval": {"argv": ["python3", FAKE_AGENT, "--approval-mode", "yolo"]},
            "pinned-asks": {"argv": ["python3", FAKE_AGENT, "--permission-mode", "default"]},
            // Harnesses that move themselves into full access: one that declares no modes (and
            // reports one anyway), one through a config option other than its mode.
            "self-moder": {"argv": ["python3", FAKE_AGENT], "env": {"FAKE_NO_MODES": "1"}},
            "self-optioner": {"argv": ["python3", FAKE_AGENT]},
            "pinned-marked": {"argv": [marked_acp, "--yolo"]},
            "claude-pinned": {"kind": "claude-stdio",
                              "argv": [marked_claude, "--dangerously-skip-permissions"]},
            // A profile that pins nothing whose harness's own settings start it in full access.
            "self-full": {"argv": ["python3", FAKE_AGENT], "env": {"FAKE_FULL_ACCESS": "1",
                          "FAKE_NEW_MODE": "full-access"}},
            // A harness that declares no modes and reports bypassPermissions while its session
            // starts (a `current_mode_update` before it answers `session/new`).
            "self-reporter": {"argv": ["python3", FAKE_AGENT], "env": {"FAKE_NO_MODES": "1",
                              "FAKE_STARTUP_MODE": "bypassPermissions"}},
            // One that reports an asking mode while its session starts, then answers
            // `session/new` in full access.
            "self-masked": {"argv": ["python3", FAKE_AGENT], "env": {"FAKE_FULL_ACCESS": "1",
                            "FAKE_NEW_MODE": "full-access", "FAKE_STARTUP_MODE": "normal"}},
            // `self-reporter` whose report comes after 300 other updates.
            "self-busy": {"argv": ["python3", FAKE_AGENT], "env": {"FAKE_NO_MODES": "1",
                          "FAKE_STARTUP_NOISE": "300", "FAKE_STARTUP_MODE": "bypassPermissions"}},
            // `self-reporter` whose `session/new` answer names an empty session id (review 74).
            "self-blank-new": {"argv": ["python3", FAKE_AGENT], "env": {"FAKE_NO_MODES": "1",
                               "FAKE_STARTUP_MODE": "bypassPermissions", "FAKE_NEW_RESULT_SID": ""}},
            // `self-reporter` whose report names an empty session id (review 70).
            "self-blank": {"argv": ["python3", FAKE_AGENT], "env": {"FAKE_NO_MODES": "1",
                           "FAKE_STARTUP_MODE": "bypassPermissions", "FAKE_STARTUP_SID": ""}},
            // `self-reporter` that then holds its `session/new` answer while `hold` exists.
            "self-holder": {"argv": ["python3", FAKE_AGENT], "env": {"FAKE_NO_MODES": "1",
                            "FAKE_STARTUP_MODE": "bypassPermissions", "FAKE_NEW_HOLD": dir.join("hold")}},
            // `self-holder` that first waits while `gate` exists, then reports and holds its
            // answer while `gate-hold` exists.
            "self-gated": {"argv": ["python3", FAKE_AGENT], "env": {"FAKE_NO_MODES": "1",
                           "FAKE_STARTUP_MODE": "bypassPermissions", "FAKE_NEW_GATE": dir.join("gate"),
                           "FAKE_NEW_HOLD": dir.join("gate-hold")}},
            // A harness with a full-access mode whose mode changes take 1.5 s to answer.
            "slow-switcher": {"argv": ["python3", FAKE_AGENT], "env": {"FAKE_PLAN_MODE": "1",
                              "FAKE_FULL_ACCESS": "1", "FAKE_SET_MODE_DELAY_MS": "1500"}},
            // Claude Code pinned to bypassPermissions, whose start takes 1.5 s to answer.
            "claude-pinned-slow": {"argv": ["python3", FAKE_CLAUDE, "--permission-mode=bypassPermissions"],
                                   "kind": "claude-stdio", "env": {"FAKE_CLAUDE_INIT_DELAY_MS": "1500"}},
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
        for harness in [
            "pinned-yolo",
            "pinned-bypass",
            "pinned-sandbox",
            "pinned-config",
            "pinned-y",
            "pinned-approval",
        ] {
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
        let prompt = json!({"sessionId": id, "prompt": [{"type": "text", "text": "argv"}]});
        let r = self.call("session/prompt", prompt).await;
        assert!(r.get("error").is_none(), "{harness}: {r}");
        id
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

/// One case: its name and what it runs. Each runs on its own daemon and home.
type Case = (&'static str, fn(&'static str) -> futures_util::future::BoxFuture<'static, ()>);

/// The daemon of case `name`, with the person's own `sessions.allowFullAccess` (`person_on`).
async fn daemon(name: &str, person_on: bool) -> (PathBuf, Arc<Hub>, Client) {
    let dir = home(name);
    let settings = dir.join("cmux-next.json");
    let on = json!({"sessions": {"allowFullAccess": person_on}});
    std::fs::write(&settings, on.to_string()).unwrap();
    // SAFETY: the cases run one at a time, each setting it before its daemon starts.
    unsafe { std::env::set_var("CMUX_NEXT_CONFIG_FILE", &settings) };
    let daemon = hub(&dir);
    let app = Client::app(&daemon).await;
    (dir, daemon, app)
}

const OFF: &str = r#"{"allowFullAccess": false, "allowFullAccessManaged": true}"#;

fn off() -> Value {
    serde_json::from_str(OFF).unwrap()
}

/// The bound itself (claude-sr2's decision), and the pinned profiles of rounds 1 and 2.
const BOUND: &[Case] = &[
    ("MDM unset changes nothing", |name| {
        Box::pin(async move {
            let (dir, _daemon, mut app) = daemon(name, true).await;
            app.push(json!({})).await;
            app.full_access_available(&dir, "no keys").await;
            app.pinned_profiles(&dir, false, "no keys").await;
            app.push(json!({"allowFullAccess": false, "allowFullAccessManaged": false})).await;
            app.full_access_available(&dir, "an unforced off").await;
        })
    }),
    ("MDM unset: the person's own off leaves approve-all as it was", |name| {
        Box::pin(async move {
            let (dir, _daemon, mut app) = daemon(name, false).await;
            app.push(json!({})).await;
            let (chat, _) = app.chat(&dir).await;
            let r = app
                .call("_acpmux/set_policy", json!({"sessionId": chat, "policy": "approve-all"}))
                .await;
            assert!(r.get("error").is_none(), "the person's own off refused approve-all: {r}");
        })
    }),
    ("MDM off is an upper bound over the person's on", |name| {
        Box::pin(async move {
            let (dir, _daemon, mut app) = daemon(name, true).await;
            app.push(off()).await;
            app.full_access_managed_off(&dir, "MDM off").await;
        })
    }),
    ("a forced value that is not true is off", |name| {
        Box::pin(async move {
            let (dir, _daemon, mut app) = daemon(name, true).await;
            app.push(json!({"allowFullAccess": "true", "allowFullAccessManaged": true})).await;
            app.full_access_managed_off(&dir, "MDM \"true\"").await;
        })
    }),
    ("round 1 and 2: a profile pinning full access in argv does not start", |name| {
        Box::pin(async move {
            let (dir, _daemon, mut app) = daemon(name, true).await;
            app.push(off()).await;
            app.pinned_profiles(&dir, true, "MDM off").await;
        })
    }),
    ("the off holds across a restart, and unsetting it restores full access", |name| {
        Box::pin(async move {
            let (dir, daemon, mut app) = daemon(name, true).await;
            app.push(off()).await;
            drop((app, daemon));
            let daemon = hub(&dir);
            let mut app = Client::app(&daemon).await;
            app.full_access_managed_off(&dir, "after a restart").await;
            app.pinned_profiles(&dir, true, "after a restart").await;
            app.push(json!({})).await;
            app.full_access_available(&dir, "MDM unset again").await;
        })
    }),
    ("a forced on raises nothing", |name| {
        Box::pin(async move {
            let (dir, _daemon, mut app) = daemon(name, false).await;
            app.push(json!({"allowFullAccess": true, "allowFullAccessManaged": true})).await;
            let start = app.start_mode(&dir).await;
            assert!(start.get("fullAccess").is_none(), "{start}");
            let (chat, mode) = app.chat(&dir).await;
            assert_eq!(mode, "agent");
            let r = app.switch(&chat, "agent-full-access").await;
            assert_eq!(r["error"]["data"]["reason"], "full_access_off", "{r}");
        })
    }),
    ("round 9: a profile pinning full access is not probed under the off", |name| {
        Box::pin(async move {
            let (dir, _daemon, mut app) = daemon(name, true).await;
            app.push(off()).await;
            let marker = dir.join("pinned-marked-started");
            // A probe that started before the push has left its line by the time a refresh
            // answers; only what starts after it counts.
            app.call("_acpmux/models", json!({"refresh": true})).await;
            let _ = std::fs::remove_file(&marker);
            app.call("_acpmux/models", json!({"refresh": true})).await;
            assert!(!marker.exists(), "a model probe started pinned-marked under the off");
        })
    }),
    ("round 9: a switch into full access that the push overtakes is refused", |name| {
        Box::pin(async move {
            let (dir, _daemon, mut app) = daemon(name, true).await;
            let chat = app.ran_on(&dir, "slow-switcher").await;
            let r = app.switch(&chat, "build").await;
            assert!(r.get("error").is_none(), "{r}");
            // The switch passes both checks, then waits 1.5 s on the harness; the push lands then.
            let id = app
                .send("session/set_mode", json!({"sessionId": chat, "modeId": "full-access"}))
                .await;
            tokio::time::sleep(Duration::from_millis(400)).await;
            app.push(off()).await;
            let r = app.reply(id).await;
            assert_eq!(r["error"]["data"]["reason"], "full_access_off", "the switch ran on: {r}");
        })
    }),
    ("round 10: a cold Claude start that the push overtakes does not run in full access", |name| {
        Box::pin(async move {
            let (dir, _daemon, mut app) = daemon(name, true).await;
            // The start passes the pinned check, spawns Claude Code in bypassPermissions, then
            // waits 1.5 s on its initialize; the push lands then.
            let params = json!({"cwd": dir.join("work"), "mcpServers": [],
                                "_meta": {"acpmux": {"harness": "claude-pinned-slow"}}});
            let id = app.send("session/new", params).await;
            tokio::time::sleep(Duration::from_millis(400)).await;
            app.push(off()).await;
            let r = app.reply(id).await;
            assert_eq!(r["error"]["data"]["reason"], "full_access_off", "Claude ran on: {r}");
        })
    }),
];

/// The pid in `marker` once a start wrote it.
async fn started_pid(marker: &Path) -> u32 {
    for _ in 0..200 {
        let text = std::fs::read_to_string(marker).unwrap_or_default();
        if let Some(pid) = text.lines().last().and_then(|l| l.trim().parse().ok()) {
            return pid;
        }
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    panic!("{} never started", marker.display());
}

/// Whether `pid` ends within 5 s: gone, or a zombie (ended, not reaped yet).
async fn ends(pid: u32) -> bool {
    for _ in 0..100 {
        let ps = std::process::Command::new("ps")
            .args(["-o", "stat=", "-p", &pid.to_string()])
            .output()
            .unwrap();
        let stat = String::from_utf8_lossy(&ps.stdout);
        if stat.trim().is_empty() || stat.trim().starts_with('Z') {
            return true;
        }
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    false
}

/// Review 25 of #23322: model probes, which start agents outside any session.
const PROBES: &[Case] = &[
    ("review 25: a Claude profile pinning full access is not started to list its models", |name| {
        Box::pin(async move {
            let (dir, _daemon, mut app) = daemon(name, true).await;
            app.push(off()).await;
            let marker = dir.join("claude-pinned-started");
            // As round 9: only what starts after the push counts.
            app.call("_acpmux/models", json!({"refresh": true})).await;
            let _ = std::fs::remove_file(&marker);
            app.call("_acpmux/models", json!({"refresh": true})).await;
            assert!(!marker.exists(), "a live model list started claude-pinned under the off");
        })
    }),
    ("review 25: a probe running when the off lands ends", |name| {
        Box::pin(async move {
            let (dir, _daemon, mut app) = daemon(name, true).await;
            std::fs::write(dir.join("hang"), "").unwrap();
            let refresh = app.send("_acpmux/models", json!({"refresh": true})).await;
            let acp = started_pid(&dir.join("pinned-marked-started")).await;
            let claude = started_pid(&dir.join("claude-pinned-started")).await;
            app.push(off()).await;
            // The probes wait 50 s (ACP) and 15 s (a live list) for an answer that never comes.
            let answered = tokio::time::timeout(Duration::from_secs(8), app.reply(refresh)).await;
            assert!(answered.is_ok(), "the refresh waited on probes running under the off");
            assert!(ends(acp).await, "the ACP probe of pinned-marked runs on under the off");
            assert!(ends(claude).await, "the live list of claude-pinned runs on under the off");
        })
    }),
    ("reviews 32, 41, 46: a probe in full access as its session starts keeps nothing", |name| {
        Box::pin(async move {
            let (_dir, _daemon, mut app) = daemon(name, true).await;
            app.push(off()).await;
            let listed = app.call("_acpmux/models", json!({"refresh": true})).await;
            let kept: Vec<Value> = STARTS_IN_FULL_ACCESS
                .iter()
                .filter_map(|name| {
                    let all = listed["result"]["harnesses"].as_array()?;
                    let entry = all.iter().find(|h| h["harness"] == *name)?;
                    let refused =
                        entry["probeError"].as_str().is_some_and(|e| e.contains("full access"));
                    (!refused).then(|| entry.clone())
                })
                .collect();
            assert!(kept.is_empty(), "probes in full access kept under the off: {kept:?}");
        })
    }),
    (
        "review 71: a probe that reported full access ends at the off, an unset after it too",
        |name| {
            Box::pin(async move {
                let (dir, _daemon, mut app) = daemon(name, true).await;
                let hold = dir.join("hold");
                std::fs::write(&hold, "").unwrap();
                let refresh = app.send("_acpmux/models", json!({"refresh": true})).await;
                // Its harness reported bypassPermissions and holds its `session/new` answer.
                let pid = started_pid(&dir.join("hold.reported")).await;
                app.push(off()).await;
                app.push(json!({})).await;
                let answered =
                    tokio::time::timeout(Duration::from_secs(8), app.reply(refresh)).await;
                let _ = std::fs::remove_file(&hold);
                let listed =
                    answered.expect("the refresh waited on a probe in full access past the off");
                assert!(ends(pid).await, "the probe in full access runs on past the off");
                let all = listed["result"]["harnesses"].as_array().cloned().unwrap_or_default();
                let entry = all.iter().find(|h| h["harness"] == "self-holder");
                let refused = entry.is_some_and(|e| {
                    e["probeError"].as_str().is_some_and(|m| m.contains("full access"))
                });
                assert!(
                    refused,
                    "the probe in full access kept its models past the off: {entry:?}"
                );
            })
        },
    ),
    (
        "review 73: a probe started under the off ends on a report that comes after an unset",
        |name| {
            Box::pin(async move {
                let (dir, _daemon, mut app) = daemon(name, true).await;
                let (gate, hold) = (dir.join("gate"), dir.join("gate-hold"));
                std::fs::write(&gate, "").unwrap();
                std::fs::write(&hold, "").unwrap();
                app.push(off()).await;
                let refresh = app.send("_acpmux/models", json!({"refresh": true})).await;
                let pid = started_pid(&dir.join("gate.started")).await;
                // The unset lands before the harness reports bypassPermissions and holds its answer.
                app.push(json!({})).await;
                std::fs::remove_file(&gate).unwrap();
                let answered =
                    tokio::time::timeout(Duration::from_secs(8), app.reply(refresh)).await;
                let _ = std::fs::remove_file(&hold);
                let listed = answered.expect("the refresh waited on a probe the off started under");
                assert!(ends(pid).await, "the probe started under the off runs on in full access");
                let all = listed["result"]["harnesses"].as_array().cloned().unwrap_or_default();
                let entry = all.iter().find(|h| h["harness"] == "self-gated");
                let refused = entry.is_some_and(|e| {
                    e["probeError"].as_str().is_some_and(|m| m.contains("full access"))
                });
                assert!(refused, "the probe started under the off kept its models: {entry:?}");
            })
        },
    ),
];

/// The profiles whose harness is in full access as its session starts (reviews 32, 41, 46, 70
/// and 74: `self-blank` reports it under an empty session id, `self-blank-new` answers with one).
const STARTS_IN_FULL_ACCESS: &[&str] =
    &["self-full", "self-reporter", "self-masked", "self-busy", "self-blank", "self-blank-new"];

/// Runs `cases` one at a time and names every one that fails.
async fn run(cases: &[Case]) {
    use futures_util::FutureExt;
    let mut failed = Vec::new();
    for (name, case) in cases {
        if std::panic::AssertUnwindSafe(case(name)).catch_unwind().await.is_err() {
            failed.push(*name);
        }
        let _ = std::fs::remove_dir_all(home_path(name));
    }
    assert!(failed.is_empty(), "failing cases: {failed:#?}");
}

#[tokio::test]
async fn a_full_access_off_mdm_forces_is_an_upper_bound_and_unset_changes_nothing() {
    // One test: every case sets CMUX_NEXT_CONFIG_FILE for its daemon.
    run(&[BOUND, PROBES].concat()).await;
}
