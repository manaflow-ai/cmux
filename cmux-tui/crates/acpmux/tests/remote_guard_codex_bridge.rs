//! Lawrence, 2026-10-13: "remote connection must be authed, and should be
//! able to pretty much use yolo mode". An authenticated remote (Web)
//! connection drives Codex through the in-process bridge (`codex
//! app-server`, `codex_app_server.rs`) in any of its modes, agent-full-access
//! included. The codex-acp adapter stays refused on the Web, and a
//! connection that proved nothing gets no session at all.
#![cfg(unix)]

#[path = "support/daemon_env.rs"]
mod daemon_env;
// This process runs stand-in agents (the fake agents under tests/).
const HERMETIC: daemon_env::Process = daemon_env::Process::stand_in();

use acpmux::config::{Config, StoreMode};
use acpmux::hub::Hub;
use acpmux::rpc::Message;
use acpmux::server::{ConnAuth, Origin, serve_connection_authed};
use serde_json::{Value, json};
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::mpsc;

const FAKE_APP_SERVER: &str =
    concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_codex_app_server.py");
const FAKE_AGENT: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");

fn dir(tag: &str) -> PathBuf {
    let d = std::env::temp_dir().join(format!("acb-{tag}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&d);
    std::fs::create_dir_all(d.join("work")).unwrap();
    std::fs::canonicalize(&d).unwrap()
}

/// `bridge`: a program named `codex` run as `codex app-server` (the fake
/// app-server), so acpmux bridges it in process. `adapter`: the fake ACP
/// agent as the codex-acp adapter (family codex).
fn hub(d: &Path) -> Arc<Hub> {
    let codex = d.join("bin").join("codex");
    std::fs::create_dir_all(codex.parent().unwrap()).unwrap();
    std::fs::write(
        &codex,
        format!("#!/bin/sh\nexec python3 {} \"$@\"\n", daemon_env::sh_quote(FAKE_APP_SERVER)),
    )
    .unwrap();
    std::fs::set_permissions(&codex, std::fs::Permissions::from_mode(0o755)).unwrap();
    let mut cfg: Config = serde_json::from_value(json!({
        "harnesses": {
            "bridge": {"argv": [codex.clone(), "app-server"]},
            "bridge-placeholder": {"argv": [d.join("missing/codex"), "app-server"]},
            "adapter": {"argv": ["python3", FAKE_AGENT, "codex-acp"], "family": "codex"},
        },
        "defaults": {
            "bridge-placeholder": {"env": {"CODEX_PATH": codex}}
        },
        "defaultHarness": "bridge",
        "permissionPolicy": "ask",
        "webRoots": [d.join("work")],
    }))
    .unwrap();
    cfg.store.mode = StoreMode::Memory;
    let store = acpmux::store::open(&cfg.store, Path::new("/nonexistent")).unwrap();
    Hub::new(cfg, store)
}

struct Client(mpsc::Sender<String>, mpsc::Receiver<String>, i64);

impl Client {
    /// A connection with the proof `auth` (a WebSocket's listener token is
    /// `ConnAuth::ListenerToken`).
    fn new(hub: &Arc<Hub>, origin: Origin, auth: ConnAuth) -> Self {
        let (in_tx, in_rx) = mpsc::channel(64);
        let (out_tx, out_rx) = mpsc::channel(4096);
        tokio::spawn(serve_connection_authed(hub.clone(), in_rx, out_tx, origin, auth));
        Client(in_tx, out_rx, 0)
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

    async fn new_on(&mut self, d: &Path, harness: &str) -> Value {
        self.call(
            "session/new",
            json!({"cwd": d.join("work"), "mcpServers": [], "_meta": {"acpmux": {"harness": harness}}}),
        )
        .await
    }
}

fn err(v: &Value) -> String {
    v["error"]["message"].as_str().unwrap_or_default().to_owned()
}

#[tokio::test]
async fn an_authenticated_web_connection_drives_the_codex_bridge_in_full_access() {
    let d = dir("full");
    let hub = hub(&d);
    let mut web = Client::new(&hub, Origin::Web, ConnAuth::ListenerToken);
    let created = web.new_on(&d, "bridge").await;
    let s =
        created["result"]["sessionId"].as_str().unwrap_or_else(|| panic!("{created}")).to_owned();
    for mode in ["agent-full-access", "agent", "read-only", "ask"] {
        let r = web.call("session/set_mode", json!({"sessionId": s, "modeId": mode})).await;
        assert!(r.get("error").is_none(), "{mode}: {r}");
        let r = web
            .call(
                "session/prompt",
                json!({"sessionId": s, "prompt": [{"type": "text", "text": "hi"}]}),
            )
            .await;
        assert_eq!(r["result"]["stopReason"], "end_turn", "{mode}: {r}");
    }
    // A model or mode set through a config option passes too.
    let r = web
        .call(
            "session/set_config_option",
            json!({"sessionId": s, "configId": "mode", "value": "agent-full-access"}),
        )
        .await;
    assert!(r.get("error").is_none(), "{r}");
    let _ = std::fs::remove_dir_all(&d);
}

#[tokio::test]
async fn a_remote_codex_bridge_validates_the_effective_codex_path() {
    let d = dir("effective-path");
    let hub = hub(&d);
    let mut web = Client::new(&hub, Origin::Web, ConnAuth::ListenerToken);
    let created = web.new_on(&d, "bridge-placeholder").await;
    let session = created["result"]["sessionId"]
        .as_str()
        .unwrap_or_else(|| panic!("valid CODEX_PATH was refused: {created}"));
    let reply = web
        .call(
            "session/prompt",
            json!({"sessionId": session, "prompt": [{"type": "text", "text": "hi"}]}),
        )
        .await;
    assert_eq!(reply["result"]["stopReason"], "end_turn", "{reply}");
    let _ = std::fs::remove_dir_all(&d);
}

#[tokio::test]
async fn the_codex_acp_adapter_stays_refused_on_the_web() {
    let d = dir("adapter");
    let hub = hub(&d);
    let mut web = Client::new(&hub, Origin::Web, ConnAuth::ListenerToken);
    let r = web.new_on(&d, "adapter").await;
    assert!(err(&r).contains("no reviewed asking mode"), "{r}");
    let _ = std::fs::remove_dir_all(&d);
}

#[tokio::test]
async fn an_unauthenticated_connection_gets_no_bridge_session() {
    let d = dir("none");
    let hub = hub(&d);
    let mut none = Client::new(&hub, Origin::Web, ConnAuth::None);
    let r = none.new_on(&d, "bridge").await;
    assert_eq!(r["error"]["code"], json!(acpmux::server::conn_auth::UNAUTHENTICATED), "{r}");
    let _ = std::fs::remove_dir_all(&d);
}

/// Only a connection held to the Web's rules widens without the person: the
/// unix socket (the CLI, scripts, agents) and a peer forwarding its own unix
/// socket client still need the person key for a mode that does not ask.
#[tokio::test]
async fn the_unix_socket_and_a_peers_local_client_still_need_the_person() {
    let d = dir("person");
    let hub = hub(&d);
    let mut web = Client::new(&hub, Origin::Web, ConnAuth::ListenerToken);
    let created = web.new_on(&d, "bridge").await;
    let s =
        created["result"]["sessionId"].as_str().unwrap_or_else(|| panic!("{created}")).to_owned();
    let widen = json!({"sessionId": s, "modeId": "agent-full-access"});
    let mut local = Client::new(&hub, Origin::Local, ConnAuth::LocalSocket);
    let r = local.call("session/set_mode", widen.clone()).await;
    assert_eq!(r["error"]["data"]["reason"], "permission.person_required", "unix socket: {r}");
    let mut peer = Client::new(&hub, Origin::Peer, ConnAuth::PeerToken);
    let r = peer.call("session/set_mode", widen.clone()).await;
    assert_eq!(
        r["error"]["data"]["reason"], "permission.person_required",
        "peer without via web: {r}"
    );
    // The same peer forwarding for its own Web client is held to the Web's rules.
    let mut via_web = widen;
    via_web["_meta"] = json!({"acpmux": {"via": "web"}});
    let r = peer.call("session/set_mode", via_web).await;
    assert!(r.get("error").is_none(), "peer via web: {r}");
    let _ = std::fs::remove_dir_all(&d);
}

/// A session a remote device STARTS on the bridge begins in its `ask` mode
/// (approval `untrusted`: Codex asks before every change), never in the
/// bridge's default `agent`, and the catalog tells the device so: the
/// bridge is startable in `ask`, the adapter is not (cnx-ios parity round 2).
#[tokio::test]
async fn a_remote_device_starts_the_codex_bridge_in_its_asking_mode() {
    let d = dir("ask");
    let hub = hub(&d);
    let mut web = Client::new(&hub, Origin::Web, ConnAuth::ListenerToken);
    let created = web.new_on(&d, "bridge").await;
    assert_eq!(created["result"]["modes"]["currentModeId"], "ask", "{created}");
    let catalog = web.call("_acpmux/harnesses", json!({})).await;
    let rows = &catalog["result"]["harnesses"];
    assert_eq!(rows["bridge"]["remote"], json!({"startable": true, "modes": ["ask"]}), "{catalog}");
    assert_eq!(rows["adapter"]["remote"]["startable"], json!(false), "{catalog}");
    // The unix socket's own new session keeps the bridge's default.
    let mut local = Client::new(&hub, Origin::Local, ConnAuth::LocalSocket);
    let own = local.new_on(&d, "bridge").await;
    assert_ne!(own["result"]["modes"]["currentModeId"], "ask", "{own}");
    let _ = std::fs::remove_dir_all(&d);
}
