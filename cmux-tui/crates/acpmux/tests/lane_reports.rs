//! A session started from inside another session is linked to it and carries the tag
//! `lane.reportsTo` naming it; a run tied to its connection, a session the person starts, or one
//! started under a closed parent carries none (`hub/lane_reports.rs`).

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
const TAG: &str = "lane.reportsTo";

fn hub() -> Arc<Hub> {
    let mut cfg: Config = serde_json::from_value(json!({
        "harnesses": {
            "fake": {"argv": ["python3", FAKE]},
        },
        "defaultHarness": "fake",
        "permissionPolicy": "approve-all",
    }))
    .unwrap();
    cfg.store.mode = StoreMode::Memory;
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

    /// The connection an agent's tools open from inside session `id`.
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
                .expect("no answer in 30 s")
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

    async fn new_session(&mut self, name: &str, extra: Value) -> String {
        let mut meta = json!({"name": name});
        meta.as_object_mut().unwrap().extend(extra.as_object().cloned().unwrap_or_default());
        let r = self
            .ok(
                "session/new",
                json!({"cwd": std::env::temp_dir(), "mcpServers": [], "_meta": {"acpmux": meta}}),
            )
            .await;
        r["sessionId"].as_str().unwrap().to_owned()
    }
}

/// The tag `lane.reportsTo` of session `id`, if any.
fn tag(hub: &Arc<Hub>, id: &str) -> Option<String> {
    let s = hub.resolve(id).unwrap();
    hub.session_summary(&s)["tags"].get(TAG).and_then(Value::as_str).map(str::to_owned)
}

#[tokio::test]
async fn lane_link_a_session_started_from_a_session_is_linked_to_it() {
    let hub = hub();
    let mut person = Client::new(&hub);
    let coord = person.new_session("coord", json!({})).await;
    let lane = Client::as_session(&hub, &coord).await.new_session("lane-a", json!({})).await;
    assert_eq!(tag(&hub, &lane).as_deref(), Some(coord.as_str()));
    // One the person starts is no lane.
    assert_eq!(tag(&hub, &coord), None);
}

#[tokio::test]
async fn lane_link_an_ephemeral_run_is_no_lane() {
    let hub = hub();
    let mut person = Client::new(&hub);
    let coord = person.new_session("coord", json!({})).await;
    // The run's own connection stays open: closing it purges the run.
    let mut owner = Client::as_session(&hub, &coord).await;
    let probe = owner.new_session("probe", json!({"ephemeral": true})).await;
    assert_eq!(tag(&hub, &probe), None);
}

#[tokio::test]
async fn lane_link_a_closed_parent_gets_no_new_lane() {
    let hub = hub();
    let mut person = Client::new(&hub);
    let coord = person.new_session("coord", json!({})).await;
    let mut from_coord = Client::as_session(&hub, &coord).await;
    person.ok("session/close", json!({"sessionId": coord})).await;
    tokio::time::sleep(Duration::from_millis(100)).await;
    let r = from_coord
        .call(
            "session/new",
            json!({"cwd": std::env::temp_dir(), "mcpServers": [], "_meta": {"acpmux": {"name": "late"}}}),
        )
        .await;
    let id = r["result"]["sessionId"].as_str().expect("session/new");
    assert_eq!(tag(&hub, id), None);
}

#[tokio::test]
async fn lane_link_a_purged_callers_connection_never_links_to_a_session_named_its_id() {
    let hub = hub();
    let mut person = Client::new(&hub);
    // A connection proven as session A stays open while A is purged; another session then takes
    // A's id as its name.
    let gone = person.new_session("a", json!({})).await;
    let mut from_gone = Client::as_session(&hub, &gone).await;
    person.ok("_acpmux/kill", json!({"sessionId": gone, "purge": true})).await;
    let impostor = person.new_session(&gone, json!({})).await;
    let r = from_gone
        .call(
            "session/new",
            json!({"cwd": std::env::temp_dir(), "mcpServers": [], "_meta": {"acpmux": {"name": "lane-g"}}}),
        )
        .await;
    let lane = r["result"]["sessionId"].as_str().expect("session/new");
    assert_eq!(tag(&hub, lane), None, "linked to {impostor}");
}
