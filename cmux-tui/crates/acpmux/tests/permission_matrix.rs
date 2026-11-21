//! The permission combinations a person meets, end to end through the daemon (Leo 2026-11-17:
//! "test out more of these permission related combinations in ci ... so things are as people
//! would expect"). Every cell of
//!
//!   harness (Claude Code over stream-json, Codex over `codex app-server`)
//!   x access level (the default, Full access, the harness's own mode, Ask, approve-all policy)
//!   x chat (a new chat, an existing chat after its harness restarted, an existing chat the person
//!     switches to Full access)
//!   x host (this Mac, a peer daemon the chat runs on)
//!   x the daemon's default permission policy (`ask`, today's default; `approve-all`, the default
//!     a pending change may flip it to; and the build's own default with nothing written, read
//!     from `PermissionPolicy::default()`), so the matrix holds whichever default ships
//!
//! runs as the app's pane drives it: a proven app connection starts the chat (`session/new`, which
//! every cell asserts succeeds: no "cmux did not start a session"), its
//! first message gets a reply, and a turn that runs a shell command (`perm-probe`, the stand-ins'
//! `npm test`) either runs unasked (no approval reaches the app under full access) or shows the
//! approval, which the person allows, and the turn completes. The chat's mode, model and effort
//! are the same after the turns as before: nothing the person picked changes by itself.
//!
//! The stand-ins speak each harness's own protocol with its own mode ids (Claude Code's
//! `bypassPermissions`/`default`, Codex's `approvalPolicy` never/on-request/untrusted), so the
//! daemon's real translators (`claude_stdio`, the cmux-codex-acp bridge) are what is under test.
//! Each test prints its rows as a table; a failing cell names itself and what it saw.

// Unix only until the Windows port runs the daemon (cmux::local_socket).
#![cfg(unix)]

#[path = "support/daemon_env.rs"]
mod daemon_env;
// This process runs stand-in agents (the fake agents under tests/).
const HERMETIC: daemon_env::Process = daemon_env::Process::stand_in();

use acpmux::config::{Config, PermissionPolicy, ProfileSources, StoreMode};
use acpmux::hub::Hub;
use acpmux::rpc::{Message, method};
use acpmux::server::peer_auth::PeerAuth;
use acpmux::server::{ConnAuth, Origin, WsAuth, bind_ws, serve_connection_authed, serve_ws_with};
use serde_json::{Value, json};
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::mpsc;

/// 32 bytes as hex: the person key the app on this Mac makes at each launch.
const KEY: &str = "5e1f0c2a9b8d7e6f5a4b3c2d1e0f9a8b7c6d5e4f3a2b1c0d9e8f7a6b5c4d3e2f";
/// The person key of the app on the peer (the app keeps it to answer that peer's prompts,
/// `AcpmuxRemotePersonKeys.swift`).
const PEER_KEY: &str = "fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210";

const FAKE_CLAUDE: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_claude.py");
const FAKE_APP_SERVER: &str =
    concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_codex_app_server.py");

/// How long one request or one turn may take before the cell fails.
const WAIT: Duration = Duration::from_secs(30);

#[derive(Clone, Copy, Debug, PartialEq)]
enum Level {
    /// Nothing set: what a fresh install runs (full access).
    Default,
    FullAccess,
    /// The harness's own start mode (`standard`): acpmux sets nothing.
    Standard,
    Ask,
    /// The harness's own mode under the approve-all policy: acpmux answers every approval.
    ApproveAll,
}

/// The daemon's default permission policy (config.json `permissionPolicy`).
#[derive(Clone, Copy, Debug, PartialEq)]
enum Policy {
    /// Nothing written: whatever this build defaults to.
    Builtin,
    Ask,
    ApproveAll,
}

impl Policy {
    fn effective(self) -> PermissionPolicy {
        match self {
            Policy::Builtin => PermissionPolicy::default(),
            Policy::Ask => PermissionPolicy::Ask,
            Policy::ApproveAll => PermissionPolicy::ApproveAll,
        }
    }

    fn name(self) -> String {
        match self {
            Policy::Builtin => format!("built-in ({})", PermissionPolicy::default()),
            Policy::Ask => "ask".into(),
            Policy::ApproveAll => "approve-all".into(),
        }
    }

    fn slug(self) -> &'static str {
        match self {
            Policy::Builtin => "builtin",
            Policy::Ask => "ask",
            Policy::ApproveAll => "approve_all",
        }
    }
}

impl Level {
    fn config(self, policy: Policy) -> Value {
        let mut config = match self {
            Level::Default => json!({}),
            Level::FullAccess => json!({"defaultPermissionMode": "fullAccess"}),
            Level::Standard => json!({"defaultPermissionMode": "standard"}),
            Level::Ask => json!({"defaultPermissionMode": "ask"}),
            Level::ApproveAll => {
                let policy = "approve-all";
                return json!({"defaultPermissionMode": "standard", "permissionPolicy": policy});
            }
        };
        match policy {
            Policy::Builtin => {}
            Policy::Ask => config["permissionPolicy"] = json!("ask"),
            Policy::ApproveAll => config["permissionPolicy"] = json!("approve-all"),
        }
        config
    }

    /// The policy the daemon answers approvals under at this level.
    fn policy(self, policy: Policy) -> PermissionPolicy {
        if self == Level::ApproveAll { PermissionPolicy::ApproveAll } else { policy.effective() }
    }

    /// Whether the person sees an approval for the probe at this level.
    fn asks(self) -> bool {
        matches!(self, Level::Standard | Level::Ask)
    }

    fn name(self) -> &'static str {
        match self {
            Level::Default => "default",
            Level::FullAccess => "full access",
            Level::Standard => "harness own",
            Level::Ask => "ask",
            Level::ApproveAll => "approve-all",
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq)]
enum Age {
    New,
    /// The chat ran a turn, its harness restarted, and a new pane connection opens it.
    Existing,
    /// The chat started at Ask and the person picks Full access in its composer.
    Switched,
}

impl Age {
    fn name(self) -> &'static str {
        match self {
            Age::New => "new",
            Age::Existing => "existing",
            Age::Switched => "switched to full",
        }
    }
}

/// The full-access mode id of each harness (`start_mode::FULL_ACCESS_MODES`).
fn full_access_mode(harness: &str) -> &'static str {
    if harness == "claude" { "bypassPermissions" } else { "agent-full-access" }
}

/// A daemon home with `claude` (Claude Code over stdio, the stand-in) and `codex` (a program
/// named `codex` run as `codex app-server`, bridged in process, with Codex's approval policies).
fn home(name: &str, extra: Value) -> PathBuf {
    let dir = std::env::temp_dir()
        .join(format!("acpmux-permission-matrix-{name}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(dir.join("work")).unwrap();
    let dir = std::fs::canonicalize(&dir).unwrap();
    let codex = dir.join("bin").join("codex");
    std::fs::create_dir_all(codex.parent().unwrap()).unwrap();
    std::fs::write(
        &codex,
        format!(
            "#!/bin/sh\nFAKE_CODEX_APPROVALS=1 exec python3 {} \"$@\"\n",
            daemon_env::sh_quote(FAKE_APP_SERVER)
        ),
    )
    .unwrap();
    std::fs::set_permissions(&codex, std::fs::Permissions::from_mode(0o755)).unwrap();
    let mut config = json!({
        "harnesses": {
            "claude": {"argv": ["python3", FAKE_CLAUDE], "kind": "claude-stdio"},
            "codex": {"argv": [codex, "app-server"]},
        },
        "defaultHarness": "codex",
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

/// One connection: its sender, its receiver, its last request id.
struct Client(mpsc::Sender<String>, mpsc::Receiver<String>, i64);

impl Client {
    fn new(hub: &Arc<Hub>, origin: Origin, auth: ConnAuth) -> Self {
        let (in_tx, in_rx) = mpsc::channel(64);
        let (out_tx, out_rx) = mpsc::channel(4096);
        tokio::spawn(serve_connection_authed(hub.clone(), in_rx, out_tx, origin, auth));
        Client(in_tx, out_rx, 0)
    }

    /// The app's agent pane: a LocalApp connection that proved this launch's person key.
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

    async fn send(&mut self, m: &str, params: Value) -> i64 {
        self.2 += 1;
        self.0.send(Message::request(self.2, m, params).to_line()).await.unwrap();
        self.2
    }

    async fn next(&mut self) -> Value {
        let line = tokio::time::timeout(WAIT, self.1.recv())
            .await
            .expect("a message in time")
            .expect("the connection stays open");
        serde_json::from_str(&line).unwrap()
    }

    async fn call(&mut self, m: &str, params: Value) -> Value {
        let id = self.send(m, params).await;
        loop {
            let v = self.next().await;
            if v.get("id") == Some(&json!(id)) && v.get("method").is_none() {
                return v;
            }
        }
    }
}

/// Where the chat runs, and how the app answers its approvals.
enum Host {
    Local,
    /// A peer daemon (`b`) this Mac's daemon mirrors; the app relays an allow with the peer's
    /// person proof, as it does for a remote chat.
    Peer {
        remote: Arc<Hub>,
    },
}

/// What one cell saw.
#[derive(Default, Debug)]
struct Seen {
    /// `session/new` gave the chat an id (the pane did not show "cmux did not start a session").
    started: bool,
    mode: String,
    replied: bool,
    asked: bool,
    /// What answered the probe's approval in the daemon (`permission_auto`): full access in
    /// its mode, or a policy.
    auto: Option<String>,
    probe: String,
    /// Why the cell did not run here (a remote Claude chain with no sandbox on this host).
    skipped: Option<String>,
    problems: Vec<String>,
}

/// The approvals the daemon answered itself in the chat (`permission_auto` records).
fn autos(owner: &Arc<Hub>, id: &str) -> Vec<Value> {
    owner
        .events(id, 0, 100_000)
        .unwrap_or_default()
        .into_iter()
        .filter(|e| e.kind == "permission_auto")
        .map(|e| e.msg)
        .collect()
}

/// The chat's mode, model and effort as `_acpmux/info` reports them.
async fn picks(app: &mut Client, id: &str) -> (Value, Value, Value) {
    let r = app.call(method::MUX_INFO, json!({"sessionId": id})).await;
    let info = &r["result"];
    (info["modes"]["currentModeId"].clone(), info["model"].clone(), info["effort"].clone())
}

/// The agent's text in the chat past its first `skip` records, as the daemon the chat runs on
/// logged it (what any pane that opens the chat shows).
fn logged_text(owner: &Arc<Hub>, raw: &str, skip: usize) -> String {
    owner
        .events(raw, 0, 100_000)
        .unwrap_or_default()
        .iter()
        .skip(skip)
        .filter(|e| e.kind == "agent_message_chunk")
        .filter_map(|e| e.msg.pointer("/params/update/content/text").and_then(Value::as_str))
        .collect()
}

/// One prompt, to its end: the agent's text, and whether an approval reached the app (which
/// the person then allows).
async fn turn(app: &mut Client, host: &Host, id: &str, text: &str, seen: &mut Seen) -> String {
    let (peer, raw) = match host {
        Host::Local => (None, id),
        Host::Peer { remote } => (Some(remote), id.rsplit('/').next().unwrap()),
    };
    let skip = peer.map_or(0, |o| o.events(raw, 0, 100_000).unwrap_or_default().len());
    let rid = app
        .send(
            "session/prompt",
            json!({"sessionId": id, "prompt": [{"type": "text", "text": text}]}),
        )
        .await;
    let mut said = String::new();
    loop {
        let v = app.next().await;
        if v.get("id") == Some(&json!(rid)) && v.get("method").is_none() {
            if let Some(e) = v.get("error") {
                seen.problems.push(format!("{text:?} failed: {e}"));
            } else if v["result"]["stopReason"] != "end_turn" {
                seen.problems.push(format!("{text:?} ended {}", v["result"]));
            }
            // A local chat's text reached the pane before the turn's answer, or the pane drew
            // the turn ended and then its words (`server/fanout.rs` `Flush`). A peer chat's
            // text is read where it runs: its relayed updates may reach this connection after
            // the turn's answer.
            return match peer {
                Some(o) => logged_text(o, raw, skip),
                None => said,
            };
        }
        let p = &v["params"];
        match v["method"].as_str() {
            Some("session/update") => {
                let u = &p["update"];
                if u["sessionUpdate"] == "agent_message_chunk"
                    && let Some(t) = u["content"]["text"].as_str()
                {
                    said.push_str(t);
                }
            }
            Some(method::MUX_PERMISSION_PENDING) => {
                seen.asked = true;
                let permission = p["permissionId"].as_str().unwrap_or_default().to_owned();
                let options = p["request"]["options"].as_array().cloned().unwrap_or_default();
                let allow = options
                    .iter()
                    .find(|o| o["kind"] == "allow_once")
                    .or_else(|| options.iter().find(|o| o["kind"] == "allow_always"))
                    .and_then(|o| o["optionId"].as_str())
                    .unwrap_or_else(|| panic!("no allow among {options:?}"))
                    .to_owned();
                let session = p["sessionId"].as_str().unwrap_or(id).to_owned();
                let mut answer =
                    json!({"sessionId": session, "permissionId": permission, "optionId": allow});
                if let Host::Peer { .. } = host {
                    let nonce = p["decisionNonce"].as_str().expect("the peer's decision nonce");
                    let instance = p["personInstance"].as_str().expect("the peer's daemon run");
                    let proof = acpmux::hub::person::decision_proof(
                        PEER_KEY,
                        instance,
                        &session,
                        &permission,
                        &allow,
                        nonce,
                    )
                    .unwrap();
                    answer["_meta"] =
                        json!({"acpmux": {"decisionNonce": nonce, "personDecision": proof}});
                }
                // Not `call`: the answer may come after the turn's own events.
                app.send(method::MUX_PERMISSION_RESPOND, answer).await;
            }
            _ => {
                // A refused answer to the respond above: a problem of the cell.
                if v.get("method").is_none()
                    && let Some(e) = v.get("error")
                {
                    seen.problems.push(format!("the allow was refused: {e}"));
                }
            }
        }
    }
}

/// Runs one cell on a fresh daemon (and a fresh peer daemon for a remote cell).
async fn cell(harness: &str, level: Level, policy: Policy, age: Age, remote: bool) -> Seen {
    let name = format!(
        "{harness}-{}-{}-{}-{}",
        level.name().replace(' ', "_"),
        policy.slug(),
        age.name().replace(' ', "_"),
        if remote { "peer" } else { "local" }
    );
    // A switched chat starts at Ask; the person then picks Full access.
    let start_level = if age == Age::Switched { Level::Ask } else { level };
    let dir = home(&name, start_level.config(policy));
    let mut seen = Seen::default();
    // A remote chain's Claude Code runs only inside the platform sandbox (`hub/remote_sandbox.rs`):
    // on Linux that is bwrap, which the cmux-tui Linux test job installs and requires.
    // Its sandbox keeper is the acpmux binary itself, which an in-process test does not have, so
    // that chain runs where the binary does (`remote_sandbox_linux.rs`); macOS runs it here.
    #[cfg(target_os = "linux")]
    if remote && harness == "claude" {
        seen.skipped = Some("Linux remote Claude runs in remote_sandbox_linux.rs".into());
        return seen;
    }
    let (here, host, cwd) = if remote {
        let peer_dir = home(&format!("{name}-b"), start_level.config(policy));
        let b = hub(&peer_dir);
        b.person.install_spawn_key(PEER_KEY).unwrap();
        let (port, token) = listen_with_peer_token(b.clone(), &name).await;
        let a = hub(&dir);
        a.add_peer("b", &format!("ws://127.0.0.1:{port}"), Some("tok".into()), Some(token), true)
            .await
            .unwrap();
        (a, Host::Peer { remote: b }, peer_dir.join("work"))
    } else {
        (hub(&dir), Host::Local, dir.join("work"))
    };
    let mut app = Client::app(&here).await;
    let mut acpmux = json!({"harness": harness});
    if remote {
        acpmux["peer"] = json!("b");
    }
    let started = app
        .call("session/new", json!({"cwd": cwd, "mcpServers": [], "_meta": {"acpmux": acpmux}}))
        .await;
    let Some(id) = started["result"]["sessionId"].as_str().map(str::to_owned) else {
        // What the pane shows as "cmux did not start a session".
        seen.problems.push(format!("no session started: {started}"));
        return seen;
    };
    seen.started = true;
    app.call(method::MUX_ATTACH, json!({"sessionId": id, "limit": 0})).await;

    // The first message gets a reply.
    let said = turn(&mut app, &host, &id, "hi", &mut seen).await;
    seen.replied = !said.trim().is_empty();
    if !seen.replied {
        seen.problems.push("the first message got no reply".into());
    }
    // The daemon the chat runs on, and its own id there.
    let owner = match &host {
        Host::Local => here.clone(),
        Host::Peer { remote } => remote.clone(),
    };
    let raw = id.rsplit('/').next().unwrap().to_owned();
    if age == Age::Existing {
        // The harness restarts (the app relaunched, or `cmux harness restart`), and a new pane
        // opens the chat.
        let mut cli = Client::new(&owner, Origin::Local, ConnAuth::LocalSocket);
        let r = cli.call("_acpmux/sessions/restart_harness", json!({"sessions": [raw]})).await;
        if r["result"]["restarted"] != json!(1) {
            seen.problems.push(format!("the harness did not restart: {r}"));
        }
        app = Client::app(&here).await;
        app.call(method::MUX_ATTACH, json!({"sessionId": id, "limit": 0})).await;
        let said = turn(&mut app, &host, &id, "hi again", &mut seen).await;
        if said.trim().is_empty() {
            seen.problems.push("the existing chat's message got no reply".into());
        }
    }
    if age == Age::Switched && !remote {
        let full = full_access_mode(harness);
        let r = app.call("session/set_mode", json!({"sessionId": id, "modeId": full})).await;
        if let Some(e) = r.get("error") {
            seen.problems.push(format!("the switch to {full} was refused: {e}"));
        }
    }
    if age == Age::Switched && remote {
        // A peer chat runs its harness's ask mode (it is remote-origin); Full access there is the
        // approve-all policy, which the peer takes only with its person's proof over a challenge
        // it issued (`hub/person/policy_grant.rs`), as the app sends it.
        if let Err(e) = raise_peer_policy(&mut app, &id, "approve-all").await {
            seen.problems.push(e);
        }
    }
    let before = picks(&mut app, &id).await;
    seen.mode = before.0.as_str().unwrap_or("?").to_owned();
    seen.asked = false;
    let auto_before = autos(&owner, &raw).len();
    seen.probe = turn(&mut app, &host, &id, "perm-probe", &mut seen).await;
    seen.auto = autos(&owner, &raw).get(auto_before).map(|r| match r["fullAccess"].as_str() {
        Some(mode) => format!("full access ({mode})"),
        None => format!("policy {}", r["policy"].as_str().unwrap_or("?")),
    });
    let after = picks(&mut app, &id).await;
    if before != after {
        seen.problems
            .push(format!("the chat's picks changed by themselves: {before:?} -> {after:?}"));
    }
    let full_now = age == Age::Switched || matches!(level, Level::Default | Level::FullAccess);
    // Whether the daemon's policy answers an approval the harness asks for (on this Mac).
    let policy_answers = level.policy(policy) == PermissionPolicy::ApproveAll;
    // A chat a peer connection starts runs under its own `ask` policy, not the peer daemon's
    // default (`server/remote_guard.rs`), so an approve-all default does not answer for it: it
    // asks unless it runs under full access. On this Mac it asks at an asking level unless the
    // approve-all policy answers.
    let expect_ask = if remote { !full_now } else { level.asks() && !policy_answers };
    if seen.asked != expect_ask {
        seen.problems.push(format!(
            "an approval {} the app, expected {}",
            if seen.asked { "reached" } else { "never reached" },
            if expect_ask { "one" } else { "none" }
        ));
    }
    if !seen.probe.contains("perm-probe ran npm test") {
        seen.problems.push(format!("the probe turn did not run its command: {:?}", seen.probe));
    }
    if remote {
        // Remote-origin: the harness asks, and the peer daemon answers under full access.
        if full_now && seen.auto.is_none() {
            seen.problems.push("the peer did not answer the approval under full access".into());
        }
    } else {
        if policy_answers && !full_now && seen.auto.is_none() {
            seen.problems.push("the approve-all policy did not answer the approval".into());
        }
        if full_now && !seen.probe.contains("unasked") {
            seen.problems.push(format!("the harness asked under full access: {:?}", seen.probe));
        }
        let full = full_access_mode(harness);
        if full_now && seen.mode != full {
            seen.problems.push(format!("the chat runs {}, expected {full}", seen.mode));
        }
    }
    let _ = std::fs::remove_dir_all(&dir);
    seen
}

/// The app's policy pick on a peer chat: the peer refuses it with a challenge, and the app sends
/// it again with the peer person's proof over that challenge.
async fn raise_peer_policy(app: &mut Client, id: &str, policy: &str) -> Result<(), String> {
    use acpmux::hub::person::policy_grant::{CHALLENGE_FIELD, NONCE_FIELD, PROOF_FIELD};
    let ask = json!({"sessionId": id, "policy": policy});
    let r = app.call(method::MUX_SET_POLICY, ask.clone()).await;
    if r.get("error").is_none() {
        return Ok(());
    }
    let challenge = &r["error"]["data"][CHALLENGE_FIELD];
    let (Some(nonce), Some(instance), Some(session)) = (
        challenge["nonce"].as_str(),
        challenge["personInstance"].as_str(),
        challenge["sessionId"].as_str(),
    ) else {
        return Err(format!("the switch to {policy} was refused with no challenge: {r}"));
    };
    let proof =
        acpmux::hub::person::policy_proof(PEER_KEY, instance, session, policy, nonce).unwrap();
    let mut proved = ask;
    proved["_meta"] = json!({"acpmux": {NONCE_FIELD: nonce, PROOF_FIELD: proof}});
    let r = app.call(method::MUX_SET_POLICY, proved).await;
    match r.get("error") {
        Some(e) => Err(format!("the proved switch to {policy} was refused: {e}")),
        None => Ok(()),
    }
}

/// The peer's WebSocket listener with a peer token (`server/peer_auth.rs`).
async fn listen_with_peer_token(b: Arc<Hub>, tag: &str) -> (u16, String) {
    let home = std::env::temp_dir().join(format!("pm-peer-{tag}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&home);
    let auth = PeerAuth::create(&home).unwrap();
    let token = std::fs::read_to_string(acpmux::server::peer_auth::token_path(&home)).unwrap();
    let l = bind_ws("127.0.0.1:0").await.unwrap();
    let port = l.local_addr().unwrap().port();
    let auth = WsAuth { local_app: None, peer: Some(Arc::new(auth)) };
    tokio::spawn(serve_ws_with(b, l, "tok".into(), auth));
    (port, token)
}

/// The cells of one harness, host and level (a new chat, an existing one, and under Full access
/// a chat switched to it); prints their rows and fails naming each bad cell. One test each, so
/// the cells run side by side and each stays inside nextest's per-test budget.
async fn matrix(harness: &str, remote: bool, level: Level, policy: Policy) {
    let mut ages = vec![Age::New, Age::Existing];
    if level == Level::FullAccess {
        ages.push(Age::Switched);
    }
    let mut rows = Vec::new();
    for age in ages {
        rows.push((level, age, cell(harness, level, policy, age, remote).await));
    }
    let host = if remote { "peer" } else { "local" };
    println!(
        "\n| harness | host | default policy | access | chat | started | mode | first reply | approval shown | auto-answered | probe | result |"
    );
    println!("|---|---|---|---|---|---|---|---|---|---|---|---|");
    let mut failed = Vec::new();
    for (level, age, seen) in &rows {
        let result = match (&seen.skipped, seen.problems.is_empty()) {
            (Some(why), _) => format!("skipped: {why}"),
            (None, true) => "pass".to_owned(),
            (None, false) => seen.problems.join("; "),
        };
        let yes = |b: bool| if b { "yes" } else { "no" };
        println!(
            "| {harness} | {host} | {} | {} | {} | {} | {} | {} | {} | {} | {} | {result} |",
            policy.name(),
            level.name(),
            age.name(),
            yes(seen.started),
            seen.mode,
            yes(seen.replied),
            yes(seen.asked),
            seen.auto.as_deref().unwrap_or("no"),
            seen.probe.replace('|', "/"),
        );
        if !seen.problems.is_empty() {
            failed.push(format!(
                "{harness}/{host}/policy {}/{}/{}: {result}",
                policy.name(),
                level.name(),
                age.name()
            ));
        }
    }
    assert!(failed.is_empty(), "failing cells:\n{}", failed.join("\n"));
}

/// One test per harness, host, level and default policy:
/// `cells!(name: harness, remote, level, policy)`.
macro_rules! cells {
    ($($name:ident: $harness:literal, $remote:literal, $level:ident, $policy:ident;)*) => {$(
        #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
        async fn $name() {
            matrix($harness, $remote, Level::$level, Policy::$policy).await;
        }
    )*};
}

/// Each harness and host: every access level under the `ask` and the `approve-all` default
/// policy, the approve-all level (its own policy), and the build's own default with nothing set.
macro_rules! harness_host {
    ($($prefix:ident: $harness:literal, $remote:literal;)*) => {$(
        mod $prefix {
            use super::*;
            cells! {
                default_builtin: $harness, $remote, Default, Builtin;
                default_policy_ask: $harness, $remote, Default, Ask;
                default_policy_approve_all: $harness, $remote, Default, ApproveAll;
                full_access_policy_ask: $harness, $remote, FullAccess, Ask;
                full_access_policy_approve_all: $harness, $remote, FullAccess, ApproveAll;
                own_mode_policy_ask: $harness, $remote, Standard, Ask;
                own_mode_policy_approve_all: $harness, $remote, Standard, ApproveAll;
                ask_policy_ask: $harness, $remote, Ask, Ask;
                ask_policy_approve_all: $harness, $remote, Ask, ApproveAll;
                approve_all: $harness, $remote, ApproveAll, ApproveAll;
            }
        }
    )*};
}

harness_host! {
    claude_here: "claude", false;
    codex_here: "codex", false;
    claude_peer: "claude", true;
    codex_peer: "codex", true;
}
