//! Lawrence, 2026-10-13: "remote connection must be authed, and should be
//! able to pretty much use yolo mode". An authenticated remote (Web)
//! connection drives Codex through the in-process bridge (`codex
//! app-server`, `codex_app_server.rs`). A chat it starts has its own `ask`
//! policy, which holds the chat in a mode that asks (#23572): only a paired
//! machine the person let run chats in Full access moves it out (Leo: "#2
//! seems reasonable i think... it's a gate that you can enable for your
//! phone, which is an attack vector you opt in to"; `crate::pairing`). The
//! codex-acp adapter stays refused on the Web, and a connection that proved
//! nothing gets no session at all.
#![cfg(unix)]

#[path = "support/daemon_env.rs"]
mod daemon_env;
// This process runs stand-in agents (the fake agents under tests/).
const HERMETIC: daemon_env::Process = daemon_env::Process::stand_in();

use acpmux::config::{Config, StoreMode};
use acpmux::hub::Hub;
use acpmux::pairing::Role;
use acpmux::rpc::Message;
use acpmux::server::{ConnAuth, Origin, serve_connection_authed, serve_connection_device};
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

const PERSON_KEY: &str = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";

/// A connection, and the `_meta.acpmux.via` its requests carry (a paired
/// machine forwarding for its own Web client says `web`).
struct Client(mpsc::Sender<String>, mpsc::Receiver<String>, i64, Option<&'static str>);

impl Client {
    /// A connection with the proof `auth` (a WebSocket's listener token is
    /// `ConnAuth::ListenerToken`).
    fn new(hub: &Arc<Hub>, origin: Origin, auth: ConnAuth) -> Self {
        let (in_tx, in_rx) = mpsc::channel(64);
        let (out_tx, out_rx) = mpsc::channel(4096);
        tokio::spawn(serve_connection_authed(hub.clone(), in_rx, out_tx, origin, auth));
        Client(in_tx, out_rx, 0, None)
    }

    /// A newly paired `client` machine named `name` (its Full-access setting
    /// off) and a connection that presented its credential, forwarding for
    /// its Web client when `via_web`.
    fn paired(hub: &Arc<Hub>, name: &str, via_web: bool) -> (String, Self) {
        let (device, token) = hub.pairing.issue(name, Role::Client).unwrap();
        (device.id, Self::device(hub, &token, via_web))
    }

    /// Another connection with the credential `token`.
    fn device(hub: &Arc<Hub>, token: &str, via_web: bool) -> Self {
        let proof = hub.pairing.device_for(token).expect("a live credential");
        let (in_tx, in_rx) = mpsc::channel(64);
        let (out_tx, out_rx) = mpsc::channel(4096);
        tokio::spawn(serve_connection_device(hub.clone(), in_rx, out_tx, proof));
        Client(in_tx, out_rx, 0, via_web.then_some("web"))
    }

    /// The unix socket, proven as the person at this machine's app (`hub/person.rs`).
    async fn person(hub: &Arc<Hub>) -> Self {
        let _ = hub.person.install_spawn_key(PERSON_KEY);
        let mut c = Client::new(hub, Origin::Local, ConnAuth::LocalSocket);
        let init = c.call("initialize", json!({"protocolVersion": 1})).await;
        let challenge = &init["result"]["_meta"]["acpmux"]["personChallenge"];
        let proof = acpmux::hub::person::person_proof(
            PERSON_KEY,
            acpmux::hub::person::TRANSPORT_UNIX,
            challenge["nonce"].as_str().unwrap(),
            challenge["connection"].as_str().unwrap(),
        )
        .unwrap();
        let r = c.call("_acpmux/person_prove", json!({"proof": proof})).await;
        assert!(r.get("error").is_none(), "{r}");
        c
    }

    async fn call(&mut self, m: &str, mut params: Value) -> Value {
        self.2 += 1;
        let id = self.2;
        if let Some(via) = self.3 {
            let meta = params.as_object_mut().unwrap().entry("_meta").or_insert(json!({}));
            let mux = meta.as_object_mut().unwrap().entry("acpmux").or_insert(json!({}));
            mux["via"] = json!(via);
        }
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

/// A new bridge chat on `c`; its id.
async fn bridge_chat(c: &mut Client, d: &Path) -> String {
    let created = c.new_on(d, "bridge").await;
    created["result"]["sessionId"].as_str().unwrap_or_else(|| panic!("{created}")).to_owned()
}

fn full_access(s: &str) -> Value {
    json!({"sessionId": s, "modeId": "agent-full-access"})
}

/// The chat's own `ask` policy held its mode (`hub/policy_mode.rs`).
fn held(r: &Value) -> bool {
    r["error"]["data"]["reason"] == "policy_mode"
}

fn mode_now(hub: &Hub, s: &str) -> Value {
    hub.resolve(s).unwrap().meta().modes.unwrap_or_default()["currentModeId"].clone()
}

async fn set_full_access(c: &mut Client, id: &str, on: bool) -> Value {
    c.call("_acpmux/pair_set", json!({"id": id, "fullAccess": on})).await
}

/// The shared dashboard token names no machine, so no setting covers it: the
/// chat it starts stays in a mode that asks. A paired machine with the
/// setting off is held the same way; once the person turns it on, that
/// machine's next request drives the bridge in every mode, Full access too.
#[tokio::test]
async fn a_paired_device_drives_the_codex_bridge_in_full_access_only_with_its_setting() {
    let d = dir("full");
    let hub = hub(&d);
    let mut web = Client::new(&hub, Origin::Web, ConnAuth::ListenerToken);
    let s = bridge_chat(&mut web, &d).await;
    let r = web.call("session/set_mode", full_access(&s)).await;
    assert!(held(&r), "the shared token: {r}");
    let (id, mut phone) = Client::paired(&hub, "phone", true);
    let s = bridge_chat(&mut phone, &d).await;
    let r = phone.call("session/set_mode", full_access(&s)).await;
    assert!(held(&r), "setting off: {r}");
    let r = phone
        .call(
            "session/set_config_option",
            json!({"sessionId": s, "configId": "mode", "value": "agent-full-access"}),
        )
        .await;
    assert!(held(&r), "setting off, as a config option: {r}");
    let mut person = Client::person(&hub).await;
    let on = set_full_access(&mut person, &id, true).await;
    assert_eq!(on["result"]["device"]["full_access"], true, "{on}");
    let allows = on["result"]["allows"].as_str().unwrap_or_default();
    assert!(allows.contains("phone") && allows.contains("without asking"), "{on}");
    let list = person.call("_acpmux/pair_list", json!({})).await;
    assert_eq!(list["result"]["devices"][0]["full_access"], true, "{list}");
    for mode in ["agent-full-access", "agent", "read-only", "ask"] {
        let r = phone.call("session/set_mode", json!({"sessionId": s, "modeId": mode})).await;
        assert!(r.get("error").is_none(), "{mode}: {r}");
        let r = phone
            .call(
                "session/prompt",
                json!({"sessionId": s, "prompt": [{"type": "text", "text": "hi"}]}),
            )
            .await;
        assert_eq!(r["result"]["stopReason"], "end_turn", "{mode}: {r}");
    }
    // A model or mode set through a config option passes too.
    let r = phone
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

/// The unix socket (the CLI, scripts, agents) and a peer forwarding its own
/// unix socket client still need the person key for a mode that does not
/// ask, the setting or not. A peer forwarding for its own Web client is held
/// to the Web's rules: refused on a peer token, which names no machine, and
/// on a paired machine with the setting off; allowed once it is on.
#[tokio::test]
async fn the_unix_socket_and_a_peers_local_client_still_need_the_person() {
    let d = dir("person");
    let hub = hub(&d);
    let mut web = Client::new(&hub, Origin::Web, ConnAuth::ListenerToken);
    let s = bridge_chat(&mut web, &d).await;
    let widen = full_access(&s);
    let mut local = Client::new(&hub, Origin::Local, ConnAuth::LocalSocket);
    let r = local.call("session/set_mode", widen.clone()).await;
    assert_eq!(r["error"]["data"]["reason"], "permission.person_required", "unix socket: {r}");
    let mut peer = Client::new(&hub, Origin::Peer, ConnAuth::PeerToken);
    let r = peer.call("session/set_mode", widen.clone()).await;
    assert_eq!(
        r["error"]["data"]["reason"], "permission.person_required",
        "peer without via web: {r}"
    );
    let mut via_web = widen.clone();
    via_web["_meta"] = json!({"acpmux": {"via": "web"}});
    let r = peer.call("session/set_mode", via_web).await;
    assert!(held(&r), "a peer token via web: {r}");
    let (id, mut laptop) = Client::paired(&hub, "laptop", true);
    let r = laptop.call("session/set_mode", widen.clone()).await;
    assert!(held(&r), "a paired machine via web, setting off: {r}");
    let mut person = Client::person(&hub).await;
    let on = set_full_access(&mut person, &id, true).await;
    assert!(on.get("error").is_none(), "{on}");
    let token = hub.pairing.issue("laptop-cli", Role::Client).unwrap().1;
    let laptop_cli_id = hub.pairing.device_for(&token).unwrap().id;
    let on = set_full_access(&mut person, &laptop_cli_id, true).await;
    assert!(on.get("error").is_none(), "{on}");
    let mut own = Client::device(&hub, &token, false);
    let r = own.call("session/set_mode", widen.clone()).await;
    assert_eq!(
        r["error"]["data"]["reason"], "permission.person_required",
        "a paired machine with the setting, for its own unix socket client: {r}"
    );
    let r = laptop.call("session/set_mode", widen).await;
    assert!(r.get("error").is_none(), "a paired machine via web, setting on: {r}");
    assert_eq!(mode_now(&hub, &s), "agent-full-access");
    let _ = std::fs::remove_dir_all(&d);
}

/// The setting is per machine: one paired machine with it on moves its chat
/// out of the asking modes; another, without it, is refused on its own chat
/// and on the first machine's.
#[tokio::test]
async fn a_paired_device_without_the_setting_stays_refused_while_one_with_it_is_allowed() {
    let d = dir("two");
    let hub = hub(&d);
    let (with_id, mut with) = Client::paired(&hub, "with", true);
    let (_, mut without) = Client::paired(&hub, "without", true);
    let mut person = Client::person(&hub).await;
    let on = set_full_access(&mut person, &with_id, true).await;
    assert!(on.get("error").is_none(), "{on}");
    let mine = bridge_chat(&mut without, &d).await;
    let r = without.call("session/set_mode", full_access(&mine)).await;
    assert!(held(&r), "without, its own chat: {r}");
    let theirs = bridge_chat(&mut with, &d).await;
    let r = without.call("session/set_mode", full_access(&theirs)).await;
    assert!(held(&r), "without, the other machine's chat: {r}");
    let r = with.call("session/set_mode", full_access(&theirs)).await;
    assert!(r.get("error").is_none(), "with: {r}");
    let r = with.call("session/set_mode", full_access(&mine)).await;
    assert!(r.get("error").is_none(), "with, the other machine's chat: {r}");
    let _ = std::fs::remove_dir_all(&d);
}

/// Turning the setting off, or revoking the machine, counts for the same
/// connection's next request, with no reconnect: the switch is refused, and
/// the chat it had moved is back in its policy's mode before the Mac's
/// request is answered.
#[tokio::test]
async fn turning_the_setting_off_or_revoking_the_machine_counts_for_its_next_request() {
    let d = dir("revoke");
    let hub = hub(&d);
    let (id, mut phone) = Client::paired(&hub, "phone", true);
    let s = bridge_chat(&mut phone, &d).await;
    let mut person = Client::person(&hub).await;
    assert!(set_full_access(&mut person, &id, true).await.get("error").is_none());
    let r = phone.call("session/set_mode", full_access(&s)).await;
    assert!(r.get("error").is_none(), "{r}");
    // Off narrows: any unix socket client may turn it off.
    let mut local = Client::new(&hub, Origin::Local, ConnAuth::LocalSocket);
    let off = set_full_access(&mut local, &id, false).await;
    assert_eq!(off["result"]["device"]["full_access"], false, "{off}");
    assert_eq!(off["result"]["held_again"], 1, "{off}");
    assert_eq!(mode_now(&hub, &s), "ask", "the chat is back in its policy's mode");
    let r = phone.call("session/set_mode", full_access(&s)).await;
    assert!(held(&r), "after off: {r}");
    assert!(set_full_access(&mut person, &id, true).await.get("error").is_none());
    let r = phone.call("session/set_mode", full_access(&s)).await;
    assert!(r.get("error").is_none(), "on again: {r}");
    let revoked = local.call("_acpmux/pair_revoke", json!({"id": id})).await;
    assert!(revoked.get("error").is_none(), "{revoked}");
    assert_eq!(mode_now(&hub, &s), "ask", "revoked: the chat is back in its policy's mode");
    let r = phone.call("session/set_mode", full_access(&s)).await;
    assert!(held(&r), "after revoke: {r}");
    let _ = std::fs::remove_dir_all(&d);
}

/// Only the person turns the setting on, on this machine's unix socket, and
/// only for a live `client` machine: not an agent on the socket, not a Web
/// or peer connection, not a read-only machine.
#[tokio::test]
async fn only_the_person_turns_the_setting_on_for_a_client_machine() {
    let d = dir("set");
    let hub = hub(&d);
    let (id, mut phone) = Client::paired(&hub, "phone", true);
    let mut local = Client::new(&hub, Origin::Local, ConnAuth::LocalSocket);
    let r = set_full_access(&mut local, &id, true).await;
    assert_eq!(r["error"]["data"]["reason"], "permission.person_required", "{r}");
    let r = set_full_access(&mut phone, &id, true).await;
    assert!(err(&r).contains("local socket only"), "{r}");
    let mut web = Client::new(&hub, Origin::Web, ConnAuth::ListenerToken);
    let r = set_full_access(&mut web, &id, true).await;
    assert!(err(&r).contains("local socket only"), "{r}");
    let mut person = Client::person(&hub).await;
    let watcher = hub.pairing.issue("watcher", Role::ReadOnly).unwrap().0;
    let r = set_full_access(&mut person, &watcher.id, true).await;
    assert_eq!(r["error"]["data"]["reason"], "full_access_role", "{r}");
    let r = set_full_access(&mut person, "nobody", true).await;
    assert_eq!(r["error"]["data"]["reason"], "not_found", "{r}");
    assert!(!hub.pairing.full_access(&id) && !hub.pairing.full_access(&watcher.id));
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
