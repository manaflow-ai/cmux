//! `_acpmux/vm_host` (`acpmux host vm-host [NAME] [on|off]`): a VM cmux
//! created (an owner `/etc/cmux/vm-kind`, no `/srv/team`) is a dedicated agent
//! VM by default; the toggle turns it off and on with no restart; a machine
//! cmux did not create (personal, SSH-added, a team VM) never gets it. Each
//! hub reads the marker under its own folder (`Hub::set_vm_marker_root`).

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

#[tokio::test]
async fn a_vm_cmux_created_is_a_vm_host_by_default_and_the_toggle_applies_without_a_restart() {
    let d = dir("default");
    mark(&d, "owner");
    let h = hub(&d, None);
    let mut c = C::new(h.clone(), Origin::Local).await;
    let read = c.call("_acpmux/vm_host", json!({})).await.unwrap();
    assert_eq!(read, json!({"vmHost": true, "cmuxVm": true, "configured": null}));
    assert!(h.vm_host().await);

    // Off: saved, and live in this daemon at once.
    let off = c.call("_acpmux/vm_host", json!({"on": false})).await.unwrap();
    assert_eq!(off, json!({"vmHost": false, "cmuxVm": true, "configured": false}));
    assert_eq!(saved(&d).unwrap()["vmHost"], false);
    assert!(!h.vm_host().await);

    // On again: back to the default, the key gone.
    let on = c.call("_acpmux/vm_host", json!({"on": true})).await.unwrap();
    assert_eq!(on, json!({"vmHost": true, "cmuxVm": true, "configured": null}));
    assert!(saved(&d).unwrap().get("vmHost").is_none());
    assert!(h.vm_host().await);
    let _ = std::fs::remove_dir_all(&d);
}

#[tokio::test]
async fn a_machine_cmux_did_not_create_refuses_vm_host() {
    // A personal or SSH-added machine: no marker at all.
    let d = dir("personal");
    let h = hub(&d, None);
    let mut c = C::new(h.clone(), Origin::Local).await;
    let read = c.call("_acpmux/vm_host", json!({})).await.unwrap();
    assert_eq!(read, json!({"vmHost": false, "cmuxVm": false, "configured": null}));
    let e = c.call("_acpmux/vm_host", json!({"on": true})).await.unwrap_err();
    assert_eq!(e["data"]["reason"], "vmHost.not_cmux_vm", "{e}");
    assert!(saved(&d).is_none(), "nothing written");
    assert!(!h.vm_host().await);
    // Off is always allowed.
    let off = c.call("_acpmux/vm_host", json!({"on": false})).await.unwrap();
    assert_eq!(off["vmHost"], false);
    let _ = std::fs::remove_dir_all(&d);

    // A team VM (shared by people), by its kind or by its team files.
    for (tag, kind, team_files) in [("team", "team", false), ("teamfiles", "owner", true)] {
        let d = dir(tag);
        mark(&d, kind);
        if team_files {
            std::fs::create_dir_all(d.join("root/srv/team")).unwrap();
        }
        let h = hub(&d, None);
        let mut c = C::new(h.clone(), Origin::Local).await;
        assert!(!h.vm_host().await, "{tag}");
        let e = c.call("_acpmux/vm_host", json!({"on": true})).await.unwrap_err();
        assert_eq!(e["data"]["reason"], "vmHost.not_cmux_vm", "{tag}: {e}");
        let _ = std::fs::remove_dir_all(&d);
    }
}

#[tokio::test]
async fn the_marker_is_read_live_so_a_fresh_vm_turns_on_once_it_reads_owner() {
    // A fresh owner VM reads `team` until its kind sync answers (fail closed).
    let d = dir("live");
    mark(&d, "team");
    let h = hub(&d, None);
    assert!(!h.vm_host().await);
    mark(&d, "owner");
    assert!(h.vm_host().await, "no restart needed");
    let _ = std::fs::remove_dir_all(&d);
}

#[tokio::test]
async fn a_fleet_written_vm_host_still_holds_where_cmux_did_not_create_the_machine() {
    let d = dir("fleet");
    let h = hub(&d, Some(true));
    assert!(h.vm_host().await);
    let mut c = C::new(h.clone(), Origin::Local).await;
    let read = c.call("_acpmux/vm_host", json!({})).await.unwrap();
    assert_eq!(read, json!({"vmHost": true, "cmuxVm": false, "configured": true}));
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
    assert!(h.vm_host().await);
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
    assert_eq!(read["vmHost"], true, "{read}");
    assert_eq!(read["name"], "vm", "{read}");

    let off = ca.call("_acpmux/vm_host", json!({"name": "vm", "on": false})).await.unwrap();
    assert_eq!(off["vmHost"], false, "{off}");
    assert!(!b.vm_host().await, "the peer turned off");
    assert!(!a.vm_host().await, "this machine was never on");
    assert_eq!(saved(&db).unwrap()["vmHost"], false);
    let on = ca.call("_acpmux/vm_host", json!({"name": "vm", "on": true})).await.unwrap();
    assert_eq!(on["vmHost"], true, "{on}");
    assert!(b.vm_host().await);

    let e = ca.call("_acpmux/vm_host", json!({"name": "nope"})).await.unwrap_err();
    assert!(e["message"].as_str().unwrap().contains("acpmux host ls"), "{e}");
    // A peer's own request is never relayed on.
    let mut from_peer = C::new(b.clone(), Origin::Peer).await;
    assert!(from_peer.call("_acpmux/vm_host", json!({"name": "x"})).await.is_err());
    let _ = std::fs::remove_dir_all(&da);
    let _ = std::fs::remove_dir_all(&db);
}
