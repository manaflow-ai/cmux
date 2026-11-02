//! `_acpmux/vm_host` (`acpmux host vm-host [NAME] [on|off]`): whether a machine
//! takes its owner's VM boundary (`hub/vm_boundary.rs`), the per-machine
//! toggle. Nothing on the machine turns the boundary on: not an owner
//! `/etc/cmux/vm-kind` (the agent has sudo on a Cloud VM and can write it) and
//! not config.json's `vmHost`. Only the caller asks for it, per session. The
//! machine can only refuse it: `off` saves `vmHost: false`, `on` removes it.
//! The marker is shown (`cmuxVm`). Each hub reads the marker under its own
//! folder (`Hub::set_vm_marker_root`).

#[path = "support/daemon_env.rs"]
mod daemon_env;
// No agent starts here.
const HERMETIC: daemon_env::Process = daemon_env::Process::deny();

use acpmux::config::{Config, StoreMode};
use acpmux::hub::Hub;
use acpmux::rpc::{Message, method};
use acpmux::server::peer_auth::PeerAuth;
use acpmux::server::{Origin, WsAuth, bind_ws, serve_connection_with, serve_ws_with};
use serde_json::{Value, json};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::mpsc;

fn dir(tag: &str) -> PathBuf {
    let d = std::env::temp_dir().join(format!("vm-host-{tag}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&d);
    std::fs::create_dir_all(&d).unwrap();
    d
}

/// A hub whose config.json is `d/home/config.json` (with `vm_host` as its
/// `vmHost`) and whose creation marker is under `d/root`.
fn hub(d: &Path, vm_host: Option<bool>) -> Arc<Hub> {
    let mut cfg: Config = serde_json::from_value(json!({"vmHost": vm_host})).unwrap();
    cfg.store.mode = StoreMode::Memory;
    cfg.path = Some(d.join("home/config.json"));
    let store = acpmux::store::open(&cfg.store, Path::new("/nonexistent")).unwrap();
    let hub = Hub::new(cfg, store);
    hub.set_vm_marker_root(d.join("root"));
    hub
}

/// The marker cmux's creation path writes: `owner` on a VM made for one
/// person, `team` on a team VM.
fn mark(d: &Path, kind: &str) {
    let etc = d.join("root/etc/cmux");
    std::fs::create_dir_all(&etc).unwrap();
    std::fs::write(etc.join("vm-kind"), format!("{kind}\n")).unwrap();
}

fn saved(d: &Path) -> Option<Value> {
    let text = std::fs::read_to_string(d.join("home/config.json")).ok()?;
    Some(serde_json::from_str(&text).unwrap())
}

struct C {
    tx: mpsc::Sender<String>,
    rx: mpsc::Receiver<String>,
    next: i64,
}

impl C {
    async fn new(hub: Arc<Hub>, origin: Origin) -> C {
        let (in_tx, in_rx) = mpsc::channel(64);
        let (out_tx, out_rx) = mpsc::channel(4096);
        drop(tokio::spawn(serve_connection_with(hub, in_rx, out_tx, origin)));
        let mut c = C { tx: in_tx, rx: out_rx, next: 0 };
        c.call(method::INITIALIZE, json!({"protocolVersion": 1})).await.unwrap();
        c
    }

    /// The result, or the error object.
    async fn call(&mut self, m: &str, p: Value) -> Result<Value, Value> {
        self.next += 1;
        let id = self.next;
        self.tx.send(Message::request(id, m, p).to_line()).await.unwrap();
        loop {
            let line = tokio::time::timeout(Duration::from_secs(20), self.rx.recv())
                .await
                .expect("timeout")
                .expect("closed");
            let v: Value = serde_json::from_str(&line).unwrap();
            if v["id"] == json!(id) {
                return match v.get("error") {
                    Some(e) => Err(e.clone()),
                    None => Ok(v["result"].clone()),
                };
            }
        }
    }
}

/// Whether a machine with no `vmHost: false` takes the VM boundary: Linux only (`vmHost`).
const TAKES: bool = cfg!(target_os = "linux");

#[tokio::test]
async fn the_toggle_turns_the_boundary_off_and_on_with_no_restart() {
    let d = dir("default");
    mark(&d, "owner");
    let h = hub(&d, None);
    let mut c = C::new(h.clone(), Origin::Local).await;
    let read = c.call("_acpmux/vm_host", json!({})).await.unwrap();
    assert_eq!(read, json!({"vmHost": TAKES, "cmuxVm": true, "configured": null}));
    assert_eq!(h.vm_host().await, TAKES);

    // Off: saved, and the machine refuses its owner's boundary at once.
    let off = c.call("_acpmux/vm_host", json!({"on": false})).await.unwrap();
    assert_eq!(off, json!({"vmHost": false, "cmuxVm": true, "configured": false}));
    assert_eq!(saved(&d).unwrap()["vmHost"], false);
    assert!(!h.takes_vm_boundary().await);

    // On: the key goes, back to the default.
    let on = c.call("_acpmux/vm_host", json!({"on": true})).await.unwrap();
    assert_eq!(on, json!({"vmHost": TAKES, "cmuxVm": true, "configured": null}));
    assert!(saved(&d).unwrap().get("vmHost").is_none());
    assert_eq!(h.takes_vm_boundary().await, TAKES);
    let _ = std::fs::remove_dir_all(&d);
}

#[tokio::test]
async fn the_marker_and_config_true_are_shown_but_decide_nothing() {
    // The agent user has sudo on a Cloud VM, and can write config.json as this user.
    for (tag, kind, vm_host) in [
        ("personal", None, None),
        ("team", Some("team"), None),
        ("owner", Some("owner"), None),
        ("fleet", None, Some(true)),
        ("fleet-owner", Some("owner"), Some(true)),
    ] {
        let d = dir(tag);
        if let Some(kind) = kind {
            mark(&d, kind);
        }
        let h = hub(&d, vm_host);
        let mut c = C::new(h.clone(), Origin::Local).await;
        let read = c.call("_acpmux/vm_host", json!({})).await.unwrap();
        let cmux_vm = kind == Some("owner");
        // The marker and `vmHost: true` change nothing (`hub/vm_boundary.rs`).
        assert_eq!(h.takes_vm_boundary().await, TAKES, "{tag}");
        assert_eq!(
            read,
            json!({"vmHost": TAKES, "cmuxVm": cmux_vm, "configured": vm_host}),
            "{tag}"
        );
        let _ = std::fs::remove_dir_all(&d);
    }
    // Team files: shared, whatever the kind says.
    let d = dir("teamfiles");
    mark(&d, "owner");
    std::fs::create_dir_all(d.join("root/srv/team")).unwrap();
    assert!(!hub(&d, None).cmux_vm());
    let _ = std::fs::remove_dir_all(&d);
}

#[tokio::test]
async fn the_marker_is_read_live_for_display() {
    let d = dir("live");
    mark(&d, "team");
    let h = hub(&d, None);
    assert!(!h.cmux_vm());
    mark(&d, "owner");
    assert!(h.cmux_vm(), "shown with no restart");
    let _ = std::fs::remove_dir_all(&d);
}

#[tokio::test]
async fn a_web_client_never_changes_vm_host() {
    let d = dir("web");
    mark(&d, "owner");
    let h = hub(&d, None);
    let mut web = C::new(h.clone(), Origin::Web).await;
    let e = web.call("_acpmux/vm_host", json!({"on": false})).await.unwrap_err();
    assert_eq!(e["data"]["reason"], "vmHost.remote", "{e}");
    assert_eq!(h.vm_host().await, TAKES);
    assert!(saved(&d).is_none());
    let _ = std::fs::remove_dir_all(&d);
}

#[tokio::test]
async fn the_owner_toggles_a_peer_vm_over_its_link() {
    let db = dir("peer-b");
    mark(&db, "owner");
    let b = hub(&db, None);
    let home = db.join("peer-home");
    let auth = PeerAuth::create(&home).unwrap();
    let token = std::fs::read_to_string(acpmux::server::peer_auth::token_path(&home)).unwrap();
    let l = bind_ws("127.0.0.1:0").await.unwrap();
    let port = l.local_addr().unwrap().port();
    let ws = WsAuth { local_app: None, peer: Some(Arc::new(auth)) };
    tokio::spawn(serve_ws_with(b.clone(), l, "tok".into(), ws));

    let da = dir("peer-a");
    let a = hub(&da, None);
    a.add_peer("vm", &format!("ws://127.0.0.1:{port}"), Some("tok".into()), Some(token), true)
        .await
        .unwrap();
    let mut ca = C::new(a.clone(), Origin::Local).await;
    let read = ca.call("_acpmux/vm_host", json!({"name": "vm"})).await.unwrap();
    assert_eq!(read["vmHost"], TAKES, "{read}");
    assert_eq!(read["cmuxVm"], true, "{read}");
    assert_eq!(read["name"], "vm", "{read}");

    let off = ca.call("_acpmux/vm_host", json!({"name": "vm", "on": false})).await.unwrap();
    assert_eq!(off["vmHost"], false, "{off}");
    assert_eq!(saved(&db).unwrap()["vmHost"], false);
    assert!(!b.vm_host().await);
    let on = ca.call("_acpmux/vm_host", json!({"name": "vm", "on": true})).await.unwrap();
    assert_eq!(on["vmHost"], TAKES, "{on}");
    assert_eq!(b.vm_host().await, TAKES);

    let e = ca.call("_acpmux/vm_host", json!({"name": "nope"})).await.unwrap_err();
    assert!(e["message"].as_str().unwrap().contains("acpmux host ls"), "{e}");
    // A peer's own request is never relayed on.
    let mut from_peer = C::new(b.clone(), Origin::Peer).await;
    assert!(from_peer.call("_acpmux/vm_host", json!({"name": "x"})).await.is_err());
    let _ = std::fs::remove_dir_all(&da);
    let _ = std::fs::remove_dir_all(&db);
}
