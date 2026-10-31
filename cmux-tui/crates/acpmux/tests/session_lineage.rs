//! Session lineage at the daemon's socket (`hub/lineage.rs`): a `session/new` from a
//! connection that proved it runs in a session (an agent's `acpmux new`) records that session
//! as its `parent`, with the tree's `root` and its `depth`, and no tag request; a session the
//! app or a person starts is a root; a sub-session gets the same lineage; the sub-session depth
//! limit refuses an `acpmux new` past it; a parent that is gone leaves a root; and the lineage
//! is still there after a restart.
//!
//! Stand-in agents (fake_agent.py). One test function per process setting: the depth limit is
//! read from the settings file this process's environment names.

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
use std::path::Path;
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::mpsc;

const FAKE: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");

fn config(mode: StoreMode) -> Config {
    let mut cfg: Config = serde_json::from_value(json!({
        "harnesses": {"fake": {"argv": ["python3", FAKE]}},
        "defaultHarness": "fake",
        "permissionPolicy": "approve-all",
    }))
    .unwrap();
    cfg.store.mode = mode;
    cfg
}

fn hub() -> Arc<Hub> {
    let cfg = config(StoreMode::Memory);
    let store = acpmux::store::open(&cfg.store, Path::new("/nonexistent")).unwrap();
    Hub::new(cfg, store)
}

struct Client(mpsc::Sender<String>, mpsc::Receiver<String>, i64);

impl Client {
    fn new(hub: &Arc<Hub>) -> Self {
        let (in_tx, in_rx) = mpsc::channel(64);
        let (out_tx, out_rx) = mpsc::channel(4096);
        tokio::spawn(serve_connection_with(hub.clone(), in_rx, out_tx, Origin::Local));
        Client(in_tx, out_rx, 0)
    }

    /// The connection `acpmux new` opens in an agent's shell: `initialize` with the caller
    /// token the daemon put in that session's env.
    async fn as_session(hub: &Arc<Hub>, id: &str) -> Self {
        let mut c = Self::new(hub);
        let token = acpmux::hub::person::caller_token(id);
        c.ok(
            "initialize",
            json!({"protocolVersion": 1,
                   "_meta": {"acpmux": {"callerSession": {"sessionId": id, "token": token}}}}),
        )
        .await;
        c
    }

    async fn call(&mut self, m: &str, params: Value) -> Value {
        self.2 += 1;
        let id = self.2;
        self.0.send(Message::request(id, m, params).to_line()).await.unwrap();
        loop {
            let line = tokio::time::timeout(Duration::from_secs(30), self.1.recv())
                .await
                .unwrap()
                .unwrap();
            let v: Value = serde_json::from_str(&line).unwrap();
            if v.get("id") == Some(&json!(id)) {
                return v;
            }
        }
    }

    async fn ok(&mut self, m: &str, params: Value) -> Value {
        let r = self.call(m, params).await;
        assert!(r.get("error").is_none(), "{m}: {r}");
        r["result"].clone()
    }

    /// A new session with `meta` as its `_meta.acpmux`: its summary.
    async fn new_session(&mut self, meta: Value) -> Value {
        let p = json!({"cwd": std::env::temp_dir(), "mcpServers": [], "_meta": {"acpmux": meta}});
        self.ok("session/new", p).await["_meta"]["acpmux"].clone()
    }

    async fn refused_new(&mut self, meta: Value) -> Value {
        let p = json!({"cwd": std::env::temp_dir(), "mcpServers": [], "_meta": {"acpmux": meta}});
        let r = self.call("session/new", p).await;
        assert!(r.get("error").is_some(), "session/new should be refused: {r}");
        r["error"].clone()
    }

    async fn summary(&mut self, id: &str) -> Value {
        let list = self.ok("_acpmux/sessions", json!({})).await;
        list["sessions"]
            .as_array()
            .unwrap()
            .iter()
            .find(|s| s["sessionId"] == id)
            .cloned()
            .unwrap_or_else(|| panic!("{id} is not listed: {list}"))
    }
}

fn id(summary: &Value) -> String {
    summary["sessionId"].as_str().unwrap().to_owned()
}

#[tokio::test]
async fn agents_record_their_children_any_depth_within_the_depth_limit() {
    let root = std::env::temp_dir().join(format!("acpmux-lineage-it-{}", uuid::Uuid::now_v7()));
    std::fs::create_dir_all(&root).unwrap();
    let settings = root.join("cmux-next.json");
    std::fs::write(&settings, r#"{"agents": {"subsessions": {"maxDepth": 2}}}"#).unwrap();
    // SAFETY: the only test in this binary that sets them; set before any session starts.
    unsafe {
        std::env::set_var("CMUX_NEXT_CONFIG_FILE", &settings);
        std::env::set_var("ACPMUX_HOME", root.join("home"));
    }
    let hub = hub();

    // The app (no caller) starts a root: depth 0, its own root, no parent.
    let mut app = Client::new(&hub);
    let coord = app.new_session(json!({"name": "coord"})).await;
    let coord_id = id(&coord);
    assert_eq!(coord["parent"], Value::Null, "{coord}");
    assert_eq!(coord["depth"], 0, "{coord}");
    assert_eq!(coord["root"], coord_id.as_str(), "{coord}");
    assert_eq!(coord["spawnToolCallId"], Value::Null, "{coord}");

    // Its agent runs `acpmux new` (the proven caller): the child records it, with no tag.
    let mut c = Client::as_session(&hub, &coord_id).await;
    let kid = c.new_session(json!({"name": "kid", "spawnToolCallId": "toolu_kid"})).await;
    let kid_id = id(&kid);
    assert_eq!(kid["parent"], coord_id.as_str(), "{kid}");
    assert_eq!(kid["root"], coord_id.as_str(), "{kid}");
    assert_eq!(kid["depth"], 1, "{kid}");
    assert_eq!(kid["spawnToolCallId"], "toolu_kid", "{kid}");
    let listed = app.summary(&kid_id).await;
    assert_eq!(listed["spawnedBy"], coord_id.as_str(), "the alias names the parent: {listed}");
    assert!(listed["tags"].get("spawnedBy").is_none(), "no spawnedBy tag was set: {listed}");
    assert_eq!(listed["startedBy"], Value::Null, "not a sub-session: {listed}");

    // A child of the child: depth 2, the same root; the one-level alias stays empty.
    let mut k = Client::as_session(&hub, &kid_id).await;
    let grandkid = k.new_session(json!({"name": "grandkid"})).await;
    let grandkid_id = id(&grandkid);
    assert_eq!(grandkid["parent"], kid_id.as_str(), "{grandkid}");
    assert_eq!(grandkid["root"], coord_id.as_str(), "{grandkid}");
    assert_eq!(grandkid["depth"], 2, "{grandkid}");
    assert_eq!(app.summary(&grandkid_id).await["spawnedBy"], Value::Null);

    // The depth limit (maxDepth 2) refuses a third level, as it refuses a sub-session.
    let mut g = Client::as_session(&hub, &grandkid_id).await;
    let e = g.refused_new(json!({"name": "too-deep"})).await;
    assert_eq!(e["data"]["reason"], "subsessions.depth_limit", "{e}");
    assert_eq!(e["data"]["maxDepth"], 2, "{e}");
    let e = g.call("_acpmux/subsession/start", json!({"prompt": "echo too deep"})).await;
    assert_eq!(e["error"]["data"]["reason"], "subsessions.depth_limit", "{e}");
    // Asking for no parent (an ephemeral run, a probe) makes a root.
    let probe = g.new_session(json!({"name": "probe", "parent": null})).await;
    assert_eq!((probe["parent"].clone(), probe["depth"].clone()), (Value::Null, json!(0)));
    let eph = g.new_session(json!({"name": "eph", "ephemeral": true})).await;
    assert_eq!(eph["parent"], Value::Null, "{eph}");

    // A parent is named only as the caller itself or one of its descendants.
    let e = app.refused_new(json!({"name": "spoof", "parent": coord_id})).await;
    assert_eq!(e["data"]["reason"], "lineage.parent_not_owned", "{e}");
    let e = k.refused_new(json!({"name": "up", "parent": coord_id})).await;
    assert_eq!(e["data"]["reason"], "lineage.parent_not_owned", "{e}");
    // Also on a request that records no lineage (an ephemeral run): a parent it names is
    // still checked, never accepted as a root.
    let other = id(&app.new_session(json!({"name": "other"})).await);
    let e = c.refused_new(json!({"name": "eph-spoof", "ephemeral": true, "parent": other})).await;
    assert_eq!(e["data"]["reason"], "lineage.parent_not_owned", "{e}");
    let under_kid = c.new_session(json!({"name": "under-kid", "parent": kid_id})).await;
    assert_eq!(under_kid["parent"], kid_id.as_str(), "{under_kid}");
    assert_eq!(under_kid["depth"], 2, "{under_kid}");

    // A sub-session gets the same lineage, at its lineage depth: under the CLI child it is 2.
    let s = c.ok("_acpmux/subsession/start", json!({"prompt": "echo sub", "name": "sub"})).await;
    let sub = app.summary(s["sessionId"].as_str().unwrap()).await;
    assert_eq!(sub["parent"], coord_id.as_str(), "{sub}");
    assert_eq!(sub["startedBy"], coord_id.as_str(), "{sub}");
    assert_eq!(sub["root"], coord_id.as_str(), "{sub}");
    assert_eq!(sub["depth"], 1, "{sub}");
    let s = k.ok("_acpmux/subsession/start", json!({"prompt": "echo sub2"})).await;
    assert_eq!(s["depth"], 2, "{s}");
    let sub2 = app.summary(s["sessionId"].as_str().unwrap()).await;
    assert_eq!((sub2["parent"].clone(), sub2["root"].clone()), (json!(kid_id), json!(coord_id)));

    // A caller whose session is gone starts a root, never an error.
    let doomed = app.new_session(json!({"name": "doomed"})).await;
    let mut d = Client::as_session(&hub, &id(&doomed)).await;
    hub.kill(&hub.resolve(&id(&doomed)).unwrap(), true).await.unwrap();
    let orphan = d.new_session(json!({"name": "orphan"})).await;
    assert_eq!(orphan["parent"], Value::Null, "{orphan}");
    assert_eq!(orphan["depth"], 0, "{orphan}");
    assert_eq!(orphan["root"], id(&orphan).as_str(), "{orphan}");

    hub.shutdown_all().await;
    let _ = std::fs::remove_dir_all(&root);
}

#[tokio::test]
async fn lineage_survives_a_daemon_restart() {
    let dir = std::env::temp_dir().join(format!("acpmux-lineage-restart-{}", uuid::Uuid::now_v7()));
    let cfg = config(StoreMode::Local);
    let hub = Hub::new(cfg.clone(), acpmux::store::open(&cfg.store, &dir).unwrap());
    let mut app = Client::new(&hub);
    let coord = id(&app.new_session(json!({"name": "r-coord"})).await);
    let mut c = Client::as_session(&hub, &coord).await;
    let kid = id(&c.new_session(json!({"name": "r-kid", "spawnToolCallId": "toolu_r"})).await);
    let mut k = Client::as_session(&hub, &kid).await;
    let grandkid = id(&k.new_session(json!({"name": "r-grandkid"})).await);
    let looped = id(&app.new_session(json!({"name": "r-loop"})).await);
    hub.shutdown_all().await;
    drop((app, c, k));
    drop(hub);

    let hub = Hub::new(cfg.clone(), acpmux::store::open(&cfg.store, &dir).unwrap());
    let summary = |id: &str| hub.session_summary(&hub.resolve(id).unwrap());
    let k = summary(&kid);
    assert_eq!((k["parent"].clone(), k["root"].clone()), (json!(coord), json!(coord)), "{k}");
    assert_eq!((k["depth"].clone(), k["spawnToolCallId"].clone()), (json!(1), json!("toolu_r")));
    let g = summary(&grandkid);
    assert_eq!((g["parent"].clone(), g["root"].clone()), (json!(kid), json!(coord)), "{g}");
    assert_eq!(g["depth"], 2, "{g}");
    let r = summary(&coord);
    assert_eq!((r["parent"].clone(), r["depth"].clone()), (Value::Null, json!(0)), "{r}");
    hub.shutdown_all().await;
    drop(hub);

    // A store saved before lineage existed: only sub-session links. Their lineage is derived
    // (parent, the root up the links, the link's depth); a link loop ends, never hangs.
    let store = acpmux::store::open(&cfg.store, &dir).unwrap();
    let link = |to: &str, depth: u32| acpmux::store::SubsessionLink {
        started_by: to.to_owned(),
        short_name: format!("s{depth}"),
        depth,
        offered: false,
    };
    for (who, up, depth) in [(&kid, &coord, 1), (&grandkid, &kid, 2), (&looped, &looped, 1)] {
        let mut m = store.load(who).unwrap().unwrap();
        m.lineage = None;
        m.subsession = Some(link(up, depth));
        store.save(&m).unwrap();
    }
    drop(store);
    let hub = Hub::new(cfg.clone(), acpmux::store::open(&cfg.store, &dir).unwrap());
    let summary = |id: &str| hub.session_summary(&hub.resolve(id).unwrap());
    let g = summary(&grandkid);
    assert_eq!((g["parent"].clone(), g["root"].clone()), (json!(kid), json!(coord)), "{g}");
    assert_eq!((g["depth"].clone(), g["spawnToolCallId"].clone()), (json!(2), Value::Null));
    let k = summary(&kid);
    assert_eq!(
        (k["parent"].clone(), k["root"].clone(), k["depth"].clone()),
        (json!(coord), json!(coord), json!(1)),
        "{k}"
    );
    assert_eq!(k["spawnedBy"], coord.as_str(), "the alias still names the parent: {k}");
    let l = summary(&looped);
    assert_eq!(l["parent"], looped.as_str(), "a self link stays as saved: {l}");
    assert_eq!(l["spawnedBy"], Value::Null, "{l}");
    hub.shutdown_all().await;
    let _ = std::fs::remove_dir_all(&dir);
}
