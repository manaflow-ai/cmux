//! A connection that is not the local unix socket (Web, LocalApp) never
//! makes this machine spawn a process, set a spawn env, or read or write a
//! path of its choice (`server/remote_guard.rs`); the unix socket keeps
//! today's behavior.

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
use std::path::PathBuf;
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::mpsc;

const FAKE: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");

fn hub() -> Arc<Hub> {
    let mut cfg: Config = serde_json::from_value(json!({
        "harnesses": {"fake": {"argv": ["python3", FAKE]}},
        "defaultHarness": "fake",
        "permissionPolicy": "approve-all",
        "presets": {"p": {"harness": "fake"}},
        // The tests' folders live under the temp dir: a Web root for them.
        "webRoots": [std::env::temp_dir()],
        // The fake harness is not in the reviewed table: its two modes ask.
        "webAskingModes": {"fake": ["normal", "strict"]},
    }))
    .unwrap();
    cfg.store.mode = StoreMode::Memory;
    let store = acpmux::store::open(&cfg.store, std::path::Path::new("/nonexistent")).unwrap();
    Hub::new(cfg, store)
}

struct Client(mpsc::Sender<String>, mpsc::Receiver<String>, i64);

impl Client {
    fn new(hub: &Arc<Hub>, origin: Origin) -> Self {
        let (in_tx, in_rx) = mpsc::channel(64);
        let (out_tx, out_rx) = mpsc::channel(4096);
        tokio::spawn(serve_connection_with(hub.clone(), in_rx, out_tx, origin));
        Client(in_tx, out_rx, 0)
    }

    async fn send(&mut self, m: &str, params: Value) -> i64 {
        self.2 += 1;
        let id = self.2;
        self.0.send(Message::request(id, m, params).to_line()).await.unwrap();
        id
    }

    async fn notify(&self, m: &str, params: Value) {
        self.0.send(Message::notification(m, params).to_line()).await.unwrap();
    }

    async fn call_with_notifications(&mut self, m: &str, params: Value) -> (Value, Vec<Value>) {
        let id = self.send(m, params).await;
        let mut notifications = Vec::new();
        loop {
            let line = tokio::time::timeout(Duration::from_secs(20), self.1.recv())
                .await
                .unwrap()
                .unwrap();
            let v: Value = serde_json::from_str(&line).unwrap();
            if v.get("id") == Some(&json!(id)) {
                return (v, notifications);
            }
            if v.get("method").is_some() {
                notifications.push(v);
            }
        }
    }

    async fn call(&mut self, m: &str, params: Value) -> Value {
        self.call_with_notifications(m, params).await.0
    }

    async fn wait_for(&mut self, m: &str, pred: impl Fn(&Value) -> bool) -> Value {
        loop {
            let line = tokio::time::timeout(Duration::from_secs(20), self.1.recv())
                .await
                .unwrap()
                .unwrap();
            let Message::Notification { method, params } = Message::parse(&line).unwrap() else {
                continue;
            };
            let params = params.unwrap_or(Value::Null);
            if method == m && pred(&params) {
                return params;
            }
        }
    }
}

/// Refused for the Web: by an allow list, or (a mode or option set on a
/// session whose policy does not ask, as this hub's approve-all default)
/// by Web control (`hub/web_control.rs`).
fn refused_for_web(r: &Value) -> bool {
    err(r).contains(WEB_ONLY) || r["error"]["data"]["reason"] == "remote.policy_not_asking"
}

fn err(v: &Value) -> String {
    v["error"]["message"].as_str().unwrap_or_default().to_owned()
}

struct Dirs {
    base: PathBuf,
    real: PathBuf,
    link: PathBuf,
    file: PathBuf,
}

fn dirs(tag: &str) -> Dirs {
    let base = std::env::temp_dir().join(format!("arg-{tag}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&base);
    let real = base.join("real");
    std::fs::create_dir_all(&real).unwrap();
    let file = base.join("file.txt");
    std::fs::write(&file, "x").unwrap();
    let link = base.join("link");
    std::os::unix::fs::symlink(&real, &link).unwrap();
    Dirs { base, real, link, file }
}

fn new_session(cwd: &str, extra: Value) -> Value {
    let mut p = json!({"cwd": cwd, "mcpServers": []});
    for (k, v) in extra.as_object().unwrap() {
        p[k] = v.clone();
    }
    p
}

const REMOTE: [Origin; 2] = [Origin::Web, Origin::LocalApp];

#[tokio::test]
async fn mcp_servers_from_a_websocket_connection_are_refused() {
    let d = dirs("mcp");
    let hub = hub();
    let marker = d.base.join("spawned");
    let servers = json!([{"name": "x", "command": "touch", "args": [marker], "env": []}]);
    let cwd = d.real.to_string_lossy().into_owned();
    for origin in REMOTE {
        let mut c = Client::new(&hub, origin);
        let r = c.call("session/new", new_session(&cwd, json!({"mcpServers": servers}))).await;
        assert!(err(&r).contains("mcpServers"), "{origin:?}: {r}");
        let r = c
            .call(
                "session/new",
                new_session(&cwd, json!({"_meta": {"acpmux": {"mcpServers": servers}}})),
            )
            .await;
        assert!(err(&r).contains("mcpServers"), "{origin:?} meta: {r}");
        // Any other method that carries them, too (load, fork, prompt...).
        let r = c
            .call("session/load", json!({"sessionId": "nope", "cwd": cwd, "mcpServers": servers}))
            .await;
        assert!(err(&r).contains("mcpServers"), "{origin:?} load: {r}");
    }
    // The unix socket: unchanged (the daemon never passes them on).
    let mut local = Client::new(&hub, Origin::Local);
    let r = local.call("session/new", new_session(&cwd, json!({"mcpServers": servers}))).await;
    assert!(r.get("error").is_none(), "{r}");
    assert!(!marker.exists(), "nothing spawned a caller's MCP server");
    let _ = std::fs::remove_dir_all(&d.base);
}

#[tokio::test]
async fn an_unhandled_session_method_reaches_the_harness_only_from_the_unix_socket() {
    let d = dirs("fwd");
    let hub = hub();
    let cwd = d.real.to_string_lossy().into_owned();
    let mut local = Client::new(&hub, Origin::Local);
    let id = local.call("session/new", new_session(&cwd, json!({}))).await["result"]["sessionId"]
        .as_str()
        .unwrap()
        .to_owned();
    for origin in REMOTE {
        let mut c = Client::new(&hub, origin);
        let r = c.call("_harness/anything", json!({"sessionId": id, "command": "id"})).await;
        assert!(err(&r).contains("only from the local unix socket"), "{origin:?}: {r}");
    }
    let r = local.call("_harness/anything", json!({"sessionId": id})).await;
    assert!(!err(&r).contains("only from the local unix socket"), "{r}");
    // The app's stop on a subagent row is the one exception, and only for the app: it stops a
    // task the agent already runs and carries no params that spawn or read.
    let stop = json!({"sessionId": id, "subagentSessionId": "x/toolu_1"});
    let r = Client::new(&hub, Origin::Web).call("_acpmux/subagent_stop", stop.clone()).await;
    assert!(err(&r).contains("only from the local unix socket"), "{r}");
    let r = Client::new(&hub, Origin::Peer).call("_acpmux/subagent_stop", stop.clone()).await;
    assert!(r.get("error").is_some(), "a peer cannot stop a subagent: {r}");
    let r = Client::new(&hub, Origin::LocalApp).call("_acpmux/subagent_stop", stop).await;
    assert!(!err(&r).contains("only from the local unix socket"), "{r}");
    // A subagent's transcript is read by the daemon from the chat's Claude store, for the app and
    // the unix socket only: never for a Web client.
    let read = json!({"sessionId": id, "runId": "wf_4fe", "agentId": "a01"});
    let r = Client::new(&hub, Origin::Web).call("_acpmux/subagent_transcript", read.clone()).await;
    assert!(err(&r).contains("transcriptRead.remote"), "{r}");
    let r = Client::new(&hub, Origin::LocalApp).call("_acpmux/subagent_transcript", read).await;
    assert!(!err(&r).contains("transcriptRead.remote"), "{r}");
    // So is a chat's older native history, read from its Claude Code transcript.
    let older = json!({"sessionId": id, "before": 4096});
    let r = Client::new(&hub, Origin::Web).call("_acpmux/native_history", older.clone()).await;
    assert!(err(&r).contains("transcriptRead.remote"), "{r}");
    let r = Client::new(&hub, Origin::LocalApp).call("_acpmux/native_history", older).await;
    assert!(!err(&r).contains("transcriptRead.remote"), "{r}");
    // The daemon's workflows (they name its chats and their workflows' args): never for the Web.
    let r = Client::new(&hub, Origin::Web).call("_acpmux/workflows", json!({})).await;
    assert!(err(&r).contains("workflows.remote"), "{r}");
    let r = Client::new(&hub, Origin::LocalApp).call("_acpmux/workflows", json!({})).await;
    assert_eq!(r["result"]["workflows"], json!([]), "{r}");
    let _ = std::fs::remove_dir_all(&d.base);
}

#[tokio::test]
async fn spawn_env_and_arbitrary_paths_are_unix_socket_only() {
    let d = dirs("env");
    let hub = hub();
    let outside = d.file.to_string_lossy().into_owned();
    let calls = [
        (
            "_acpmux/defaults",
            json!({"family": "fake", "set": {"env": {"NODE_OPTIONS": "--require /tmp/x"}}}),
        ),
        ("_acpmux/presets", json!({"name": "p", "set": {"env": {"LD_PRELOAD": "/tmp/x.so"}}})),
        ("_acpmux/export", json!({"sessionId": "nope", "dest": d.base})),
        ("_acpmux/import", json!({"path": outside})),
    ];
    for origin in REMOTE {
        let mut c = Client::new(&hub, origin);
        for (m, p) in &calls {
            let r = c.call(m, p.clone()).await;
            assert!(err(&r).contains("only over the local unix socket"), "{origin:?} {m}: {r}");
        }
    }
    // The unix socket may still set a family env.
    let mut local = Client::new(&hub, Origin::Local);
    let r = local.call(calls[0].0, calls[0].1.clone()).await;
    assert!(!err(&r).contains("only over the local unix socket"), "{r}");
    let _ = std::fs::remove_dir_all(&d.base);
}

#[tokio::test]
async fn folder_fields_from_a_websocket_connection_are_existing_directories_made_canonical() {
    let d = dirs("dirs");
    let hub = hub();
    let real = std::fs::canonicalize(&d.real).unwrap().to_string_lossy().into_owned();
    let bad = [
        "relative/dir".to_owned(),
        d.base.join("missing").to_string_lossy().into_owned(),
        d.file.to_string_lossy().into_owned(),
    ];
    for origin in REMOTE {
        let mut c = Client::new(&hub, origin);
        for b in &bad {
            let r = c.call("session/new", new_session(b, json!({}))).await;
            assert!(err(&r).contains("existing directory"), "{origin:?} cwd {b}: {r}");
            let r = c
                .call("session/new", new_session(&real, json!({"additionalDirectories": [b]})))
                .await;
            assert!(
                err(&r).contains("existing directory"),
                "{origin:?} additionalDirectories {b}: {r}"
            );
            let r = c.call("acp.trust.set", json!({"cwd": b, "level": "trusted"})).await;
            assert!(err(&r).contains("existing directory"), "{origin:?} trust {b}: {r}");
            let r = c.call("session/fork", json!({"sessionId": "nope", "cwd": b})).await;
            assert!(err(&r).contains("existing directory"), "{origin:?} fork {b}: {r}");
        }
        // A symlink to a directory runs in the resolved path.
        let r = c
            .call(
                "session/new",
                new_session(&d.link.to_string_lossy(), json!({"additionalDirectories": [d.link]})),
            )
            .await;
        assert!(r.get("error").is_none(), "{origin:?}: {r}");
        let id = r["result"]["sessionId"].as_str().unwrap().to_owned();
        let info = c.call("_acpmux/info", json!({"sessionId": id})).await;
        assert_eq!(info["result"]["cwd"], json!(real), "{origin:?}: {info}");
    }
    // The unix socket: unchanged (additionalDirectories is not checked there).
    let mut local = Client::new(&hub, Origin::Local);
    let r = local
        .call("session/new", new_session(&real, json!({"additionalDirectories": ["relative"]})))
        .await;
    assert!(r.get("error").is_none(), "{r}");
    let _ = std::fs::remove_dir_all(&d.base);
}

const WEB_ONLY: &str = "never from a remote WebSocket connection";

#[tokio::test]
async fn a_policy_that_skips_asking_comes_from_the_local_app_or_the_unix_socket_never_the_web() {
    let d = dirs("policy");
    let hub = hub();
    let cwd = std::fs::canonicalize(&d.real).unwrap().to_string_lossy().into_owned();
    let mut local = Client::new(&hub, Origin::Local);
    let id = local.call("session/new", new_session(&cwd, json!({}))).await["result"]["sessionId"]
        .as_str()
        .unwrap()
        .to_owned();
    let skipping = [
        ("session/new", new_session(&cwd, json!({"policy": "approve-all"}))),
        (
            "session/new",
            new_session(&cwd, json!({"_meta": {"acpmux": {"policy": "approve-edits"}}})),
        ),
        ("_acpmux/set_policy", json!({"sessionId": id, "policy": "approve-all"})),
        ("_acpmux/set_policy", json!({"sessionId": id, "policy": "yolo"})),
        ("_acpmux/set_default_policy", json!({"policy": "approve-reads"})),
        ("_acpmux/defaults", json!({"family": "fake", "set": {"policy": "approve-all"}})),
        ("_acpmux/presets", json!({"name": "p", "set": {"policy": "approve-all"}})),
        ("_acpmux/set_rules", json!({"sessionId": id, "rules": {"autoApprove": ["execute"]}})),
        ("_acpmux/set_rules", json!({"sessionId": id, "rules": {"default": "approve"}})),
        ("session/set_mode", json!({"sessionId": id, "modeId": "bypassPermissions"})),
        (
            "session/set_config_option",
            json!({"sessionId": id, "configId": "mode", "value": "full-access"}),
        ),
    ];
    let mut web = Client::new(&hub, Origin::Web);
    for (m, p) in &skipping {
        let r = web.call(m, p.clone()).await;
        assert!(refused_for_web(&r), "Web {m} {p}: {r}");
    }
    for origin in [Origin::LocalApp, Origin::Local] {
        let mut c = Client::new(&hub, origin);
        for (m, p) in &skipping {
            let r = c.call(m, p.clone()).await;
            assert!(!err(&r).contains(WEB_ONLY), "{origin:?} {m} {p}: {r}");
        }
    }
    // Asking policies stay open to the Web.
    for (m, p) in [
        ("session/new", new_session(&cwd, json!({"policy": "ask"}))),
        ("_acpmux/set_policy", json!({"sessionId": id, "policy": "deny-all"})),
        ("session/set_mode", json!({"sessionId": id, "modeId": "strict"})),
    ] {
        let r = web.call(m, p.clone()).await;
        assert!(!err(&r).contains(WEB_ONLY), "Web {m} {p}: {r}");
    }
    let _ = std::fs::remove_dir_all(&d.base);
}

#[tokio::test]
async fn peers_change_over_the_unix_socket_only() {
    let hub = hub();
    for origin in REMOTE {
        let mut c = Client::new(&hub, origin);
        for (m, p) in [
            ("_acpmux/peer_add", json!({"name": "x", "url": "ws://127.0.0.1:1/"})),
            ("_acpmux/peer_remove", json!({"name": "x"})),
        ] {
            let r = c.call(m, p).await;
            assert!(err(&r).contains("only over the local unix socket"), "{origin:?} {m}: {r}");
        }
    }
    let mut local = Client::new(&hub, Origin::Local);
    let r = local.call("_acpmux/peer_add", json!({"name": "x", "url": "ws://127.0.0.1:1/"})).await;
    assert!(!err(&r).contains("only over the local unix socket"), "{r}");
}

#[tokio::test]
async fn directory_listings_are_for_the_local_app_and_the_unix_socket() {
    let d = dirs("list");
    let hub = hub();
    let p = json!({"path": d.base, "cwd": d.base});
    let mut web = Client::new(&hub, Origin::Web);
    let r = web.call("_acpmux/directories", p.clone()).await;
    assert_eq!(
        r["error"]["code"],
        json!(-32601),
        "the dashboard falls back on Method not found: {r}"
    );
    for origin in [Origin::LocalApp, Origin::Local] {
        let mut c = Client::new(&hub, origin);
        let r = c.call("_acpmux/directories", p.clone()).await;
        assert!(r["result"]["directories"].is_array(), "{origin:?}: {r}");
    }
    let _ = std::fs::remove_dir_all(&d.base);
}

#[tokio::test]
async fn web_modes_policies_and_rules_are_allow_lists() {
    let d = dirs("allow");
    let hub = hub();
    let cwd = std::fs::canonicalize(&d.real).unwrap().to_string_lossy().into_owned();
    let mut local = Client::new(&hub, Origin::Local);
    let id = local.call("session/new", new_session(&cwd, json!({}))).await["result"]["sessionId"]
        .as_str()
        .unwrap()
        .to_owned();
    let refused = [
        ("session/set_mode", json!({"sessionId": id, "modeId": "totally-invented-mode"})),
        ("session/set_mode", json!({"sessionId": id})),
        (
            "session/set_config_option",
            json!({"sessionId": id, "configId": "mode", "value": "invented"}),
        ),
        (
            "session/set_config_option",
            json!({"sessionId": id, "configId": "approval_policy", "value": "on-request"}),
        ),
        (
            "session/set_config_option",
            json!({"sessionId": id, "configId": "invented_option", "value": "x"}),
        ),
        ("_acpmux/set_policy", json!({"sessionId": id, "policy": "accept-edits"})),
        ("_acpmux/set_policy", json!({"sessionId": id, "policy": "invented"})),
        ("session/new", new_session(&cwd, json!({"policy": "invented"}))),
        ("_acpmux/set_rules", json!({"sessionId": id, "rules": {"default": "invented"}})),
        ("_acpmux/set_rules", json!({"sessionId": id, "rules": {"unknownKey": 1}})),
        ("_acpmux/set_rules", json!({"sessionId": id, "rules": "approve"})),
    ];
    let mut web = Client::new(&hub, Origin::Web);
    for (m, p) in &refused {
        let r = web.call(m, p.clone()).await;
        assert!(refused_for_web(&r), "Web {m} {p}: {r}");
    }
    // LocalApp and the unix socket are unchanged: none of these is refused by the guard.
    for origin in [Origin::LocalApp, Origin::Local] {
        let mut c = Client::new(&hub, origin);
        for (m, p) in &refused {
            let r = c.call(m, p.clone()).await;
            assert!(!err(&r).contains(WEB_ONLY), "{origin:?} {m} {p}: {r}");
        }
    }
    for (m, p) in [
        ("session/set_mode", json!({"sessionId": id, "modeId": "normal"})),
        (
            "session/set_config_option",
            json!({"sessionId": id, "configId": "mode", "value": "strict"}),
        ),
        ("session/set_config_option", json!({"sessionId": id, "configId": "model", "value": "m2"})),
        (
            "_acpmux/set_rules",
            json!({"sessionId": id, "rules": {"autoDeny": ["rm"], "ask": ["execute"], "default": "deny"}}),
        ),
        ("_acpmux/set_rules", json!({"sessionId": id, "rules": null})),
        ("_acpmux/set_policy", json!({"sessionId": id, "policy": "ask"})),
    ] {
        let r = web.call(m, p.clone()).await;
        assert!(!err(&r).contains(WEB_ONLY), "Web {m} {p} must be allowed: {r}");
    }
    let _ = std::fs::remove_dir_all(&d.base);
}

// Chief policy 2026-10-09: fast mode costs more per token, so only the app's trusted pages and the
// CLI may toggle it, never a Web origin. `fast-mode` stays out of web_modes FREE_CONFIG_IDS.
#[tokio::test]
async fn fast_mode_is_never_web_changeable() {
    let d = dirs("fast");
    let hub = hub();
    let cwd = std::fs::canonicalize(&d.real).unwrap().to_string_lossy().into_owned();
    let mut local = Client::new(&hub, Origin::Local);
    let id = local.call("session/new", new_session(&cwd, json!({}))).await["result"]["sessionId"]
        .as_str()
        .unwrap()
        .to_owned();
    let mut web = Client::new(&hub, Origin::Web);
    for value in ["on", "off"] {
        let p = json!({"sessionId": id, "configId": "fast-mode", "value": value});
        let r = web.call("session/set_config_option", p.clone()).await;
        assert!(refused_for_web(&r), "Web fast-mode={value}: {r}");
        for origin in [Origin::LocalApp, Origin::Local] {
            let mut c = Client::new(&hub, origin);
            let r = c.call("session/set_config_option", p.clone()).await;
            assert!(!err(&r).contains(WEB_ONLY), "{origin:?} fast-mode={value}: {r}");
        }
    }
    let _ = std::fs::remove_dir_all(&d.base);
}

/// A side session (`_acpmux/btw`, `hub/btw.rs`) is a new session on this
/// machine that approves reads: the app and the unix socket open it, a Web
/// connection or a peer never does, whatever the chat.
#[tokio::test]
async fn a_side_session_is_opened_by_the_app_and_the_unix_socket_never_the_web_or_a_peer() {
    let hub = hub();
    let mut local = Client::new(&hub, Origin::Local);
    let cwd = std::env::temp_dir().to_string_lossy().into_owned();
    let chat = local.call("session/new", new_session(&cwd, json!({}))).await;
    let id = chat["result"]["sessionId"].as_str().unwrap_or_else(|| panic!("{chat}")).to_owned();
    let before = hub.sessions().len();
    for origin in [Origin::Web, Origin::Peer] {
        let mut c = Client::new(&hub, origin);
        let r = c.call("_acpmux/btw", json!({"sessionId": id, "question": "why?"})).await;
        assert_eq!(r["error"]["data"]["reason"], "btw.remote", "{origin:?}: {r}");
    }
    assert_eq!(hub.sessions().len(), before, "a refused side session opens nothing");
    for origin in [Origin::LocalApp, Origin::Local] {
        let mut c = Client::new(&hub, origin);
        let r = c.call("_acpmux/btw", json!({"sessionId": id, "question": "why?"})).await;
        assert!(r["result"]["sessionId"].is_string(), "{origin:?}: {r}");
    }
    assert_eq!(hub.sessions().len(), before + 2, "one side session each");
}

async fn session(c: &mut Client, name: &str) -> String {
    let r = c
        .call(
            "session/new",
            json!({
                "cwd": std::env::temp_dir(),
                "mcpServers": [],
                "_meta": {"acpmux": {"name": name}}
            }),
        )
        .await;
    r["result"]["sessionId"]
        .as_str()
        .unwrap_or_else(|| panic!("session/new failed: {r}"))
        .to_owned()
}

async fn start_until_cancel(c: &mut Client, id: &str) {
    c.send(
        "session/prompt",
        json!({"sessionId": id, "prompt": [{"type": "text", "text": "until-cancel"}]}),
    )
    .await;
    c.wait_for("session/update", |p| p["update"]["sessionUpdate"] == "agent_message_chunk").await;
}

async fn wait_for_turn_end(c: &mut Client) -> Value {
    c.wait_for("_acpmux/event", |p| p["kind"] == "turn_end").await
}

async fn assert_no_turn_end(c: &mut Client) {
    let result = tokio::time::timeout(
        Duration::from_millis(300),
        c.wait_for("_acpmux/event", |p| p["kind"] == "turn_end"),
    )
    .await;
    assert!(result.is_err(), "a refused remote cancel still ended the turn: {result:?}");
}

#[tokio::test]
async fn remote_request_and_notification_cancels_cannot_stop_local_sessions() {
    // A peer link that proved the peer token is the owner's own daemon and may
    // (`tests/cancel_owner.rs`, with every peer that is not).
    for (n, origin) in [("web", Origin::Web)] {
        // Request form: a local-origin turn remains active after the remote
        // caller is refused, then the Unix socket can still stop it.
        let hub = hub();
        let mut local = Client::new(&hub, Origin::Local);
        let id = session(&mut local, &format!("{n}-request")).await;
        start_until_cancel(&mut local, &id).await;
        let mut remote = Client::new(&hub, origin);
        let (reply, _) =
            remote.call_with_notifications("session/cancel", json!({"sessionId": id})).await;
        assert_eq!(
            reply["error"]["data"]["reason"], "remote.session_cancel_ownership",
            "{origin:?}: {reply}"
        );
        assert_no_turn_end(&mut local).await;
        local.notify("session/cancel", json!({"sessionId": id})).await;
        assert_eq!(wait_for_turn_end(&mut local).await["msg"]["stopReason"], "cancelled");

        // Notification form has no response to inspect, so the running turn
        // itself is the side-effect assertion.
        let id = session(&mut local, &format!("{n}-notification")).await;
        start_until_cancel(&mut local, &id).await;
        remote.notify("session/cancel", json!({"sessionId": id})).await;
        assert_no_turn_end(&mut local).await;
        local.notify("session/cancel", json!({"sessionId": id})).await;
        assert_eq!(wait_for_turn_end(&mut local).await["msg"]["stopReason"], "cancelled");
    }
}

#[tokio::test]
async fn remote_callers_can_cancel_sessions_they_started() {
    // A Web-owned session may be cancelled by the Web request form.
    let web_hub = hub();
    let mut web = Client::new(&web_hub, Origin::Web);
    let id = session(&mut web, "web-owned").await;
    start_until_cancel(&mut web, &id).await;
    let (reply, notifications) =
        web.call_with_notifications("session/cancel", json!({"sessionId": id})).await;
    assert_eq!(reply["result"], json!({}), "{reply}");
    assert_eq!(
        wait_for_turn_end_or_seen(&mut web, &notifications).await["msg"]["stopReason"],
        "cancelled"
    );

    // A Peer-owned session may be cancelled by the ACP notification form.
    let peer_hub = hub();
    let mut peer = Client::new(&peer_hub, Origin::Peer);
    let id = session(&mut peer, "peer-owned").await;
    start_until_cancel(&mut peer, &id).await;
    peer.notify("session/cancel", json!({"sessionId": id})).await;
    assert_eq!(wait_for_turn_end(&mut peer).await["msg"]["stopReason"], "cancelled");
}

#[tokio::test]
async fn web_cancel_still_requires_web_control_of_remote_sessions() {
    for form in ["request", "notification"] {
        let hub = hub();
        let mut web = Client::new(&hub, Origin::Web);
        let id = session(&mut web, &format!("web-owned-{form}")).await;
        let owned = hub.resolve(&id).unwrap();
        hub.set_rules(&owned, Some(json!({"default": "approve"})));
        let mut local = Client::new(&hub, Origin::Local);

        // Keep a turn running so the refusal is checked by its actual side effect.
        start_until_cancel(&mut local, &id).await;
        if form == "request" {
            let (reply, _) =
                web.call_with_notifications("session/cancel", json!({"sessionId": id})).await;
            assert_eq!(reply["error"]["data"]["reason"], "remote.policy_not_asking", "{reply}");
        } else {
            web.notify("session/cancel", json!({"sessionId": id})).await;
        }
        assert_no_turn_end(&mut local).await;

        local.notify("session/cancel", json!({"sessionId": id})).await;
        assert_eq!(wait_for_turn_end(&mut local).await["msg"]["stopReason"], "cancelled");
    }
}

async fn wait_for_turn_end_or_seen(c: &mut Client, seen: &[Value]) -> Value {
    if let Some(event) =
        seen.iter().find(|v| v["method"] == "_acpmux/event" && v["params"]["kind"] == "turn_end")
    {
        return event["params"].clone();
    }
    wait_for_turn_end(c).await
}
