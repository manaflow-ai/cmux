//! `_acpmux/process/census` over a client connection: the daemon answers the census `acpmux ps
//! --json` prints, with each session's status from its own hub, and advertises it as
//! `process-census-v1`. Only this machine's clients get it.

#[path = "support/daemon_env.rs"]
mod daemon_env;
// This process runs a stand-in agent (tests/fake_agent.py) for one real session.
const HERMETIC: daemon_env::Process = daemon_env::Process::stand_in();

use acpmux::config::{Config, StoreMode};
use acpmux::hub::Hub;
use acpmux::rpc::Message;
use acpmux::server::{Origin, serve_connection_with};
use serde_json::{Value, json};
use std::sync::Arc;
use std::time::{Duration, Instant};
use tokio::sync::mpsc;

const FAKE: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
const CENSUS: &str = "_acpmux/process/census";

fn hub() -> Arc<Hub> {
    let mut cfg: Config = serde_json::from_value(json!({
        "harnesses": {"fcodex": {"argv": ["python3", FAKE], "family": "codex"}},
        "defaultHarness": "fcodex",
    }))
    .unwrap();
    cfg.store.mode = StoreMode::Memory;
    let store = acpmux::store::open(&cfg.store, std::path::Path::new("/nonexistent")).unwrap();
    Hub::new(cfg, store)
}

struct Client {
    tx: mpsc::Sender<String>,
    rx: mpsc::Receiver<String>,
    next: u64,
}

impl Client {
    fn connect(hub: &Arc<Hub>, origin: Origin) -> Self {
        let (tx, in_rx) = mpsc::channel(64);
        let (out_tx, rx) = mpsc::channel(4096);
        tokio::spawn(serve_connection_with(hub.clone(), in_rx, out_tx, origin));
        Self { tx, rx, next: 1 }
    }

    /// The whole reply (`result` or `error`) to one request.
    async fn reply(&mut self, m: &str, params: Value) -> Value {
        let id = self.next;
        self.next += 1;
        self.tx.send(Message::request(id as i64, m, params).to_line()).await.unwrap();
        loop {
            let line = tokio::time::timeout(Duration::from_secs(30), self.rx.recv())
                .await
                .unwrap()
                .unwrap();
            let v: Value = serde_json::from_str(&line).unwrap();
            if v.get("id") == Some(&json!(id)) {
                return v;
            }
        }
    }

    async fn call(&mut self, m: &str, params: Value) -> Value {
        let v = self.reply(m, params).await;
        assert!(v.get("error").is_none(), "{m}: {v}");
        v["result"].clone()
    }
}

/// A `sleep` this test started with a session's marks in its environment, ended on drop.
struct Marked(std::process::Child);

impl Marked {
    fn start(session_id: &str) -> Self {
        let child = std::process::Command::new("sleep")
            .arg("120")
            .env("ACPMUX_SESSION_ID", session_id)
            .env("ACPMUX_SESSION_NAME", "census-rpc")
            .stdin(std::process::Stdio::null())
            .spawn()
            .unwrap();
        Self(child)
    }

    fn pid(&self) -> u32 {
        self.0.id()
    }
}

impl Drop for Marked {
    fn drop(&mut self) {
        let _ = self.0.kill();
        let _ = self.0.wait();
    }
}

fn row(census: &Value, pid: u32) -> Option<Value> {
    census["processes"].as_array()?.iter().find(|p| p["pid"] == json!(pid)).cloned()
}

/// The census once every one of `pids` is in it with its session (a child's environment is the
/// test's until it has exec'd `sleep`), 20 s at most.
async fn census_with(c: &mut Client, params: Value, pids: &[u32]) -> Value {
    let by = Instant::now() + Duration::from_secs(20);
    loop {
        let census = c.call(CENSUS, params.clone()).await;
        let all =
            pids.iter().all(|pid| row(&census, *pid).is_some_and(|r| r["sessionId"].is_string()));
        if all || Instant::now() >= by {
            return census;
        }
        tokio::time::sleep(Duration::from_millis(100)).await;
    }
}

#[tokio::test]
async fn the_daemon_answers_the_census_with_its_own_sessions_status() {
    let hub = hub();
    let mut c = Client::connect(&hub, Origin::Local);
    c.call("initialize", json!({"protocolVersion": 1, "clientInfo": {"name": "test"}})).await;
    let new =
        c.call("session/new", json!({"cwd": env!("CARGO_MANIFEST_DIR"), "mcpServers": []})).await;
    let sid = new["sessionId"].as_str().expect("a session id").to_owned();

    let known = Marked::start(&sid);
    let unknown = Marked::start("census-rpc-no-such-session");
    let census = census_with(&mut c, json!({}), &[known.pid(), unknown.pid()]).await;

    // The shape `acpmux ps --json` prints.
    assert_eq!(census["product"], "acpmux", "{census}");
    assert!(census["home"].is_string(), "{census}");
    for key in
        ["processes", "inUse", "idle", "orphaned", "unknown", "hostRecords", "strayLiveLocks"]
    {
        assert!(census["summary"][key].is_u64(), "summary.{key}: {census}");
    }
    let processes = census["processes"].as_array().expect("processes");
    assert_eq!(census["summary"]["processes"], json!(processes.len()), "{census}");
    assert!(census["state"]["daemon"].is_object(), "{census}");
    assert_eq!(census["state"]["daemon"]["connected"], true, "{census}");
    assert!(census["state"]["hostRecords"].is_array(), "{census}");
    assert!(census["state"]["unreadableHostRecords"].is_array(), "{census}");
    assert!(census["state"]["strayLiveLocks"].is_array(), "{census}");
    assert!(census["gc"]["candidates"].is_array(), "{census}");
    assert!(census["gc"]["refused"].is_array(), "{census}");

    // The session the hub has: its status is the hub's, read in process.
    let mine = row(&census, known.pid()).unwrap_or_else(|| panic!("no row: {census}"));
    assert_eq!(mine["sessionId"], json!(sid), "{mine}");
    assert_eq!(mine["sessionName"], "census-rpc", "{mine}");
    let status = mine["sessionStatus"].as_str().unwrap_or_else(|| panic!("no status: {mine}"));
    assert_ne!(status, "gone", "{mine}");
    let info = c.call("_acpmux/info", json!({"sessionId": sid})).await;
    assert!(info["status"].is_string(), "{info}");
    assert!(mine["lastActivityMs"].is_u64(), "{mine}");
    assert_eq!(mine["owner"], "live", "{mine}");
    assert_eq!(mine["kind"], "helper", "{mine}");
    assert!(["in-use", "idle"].contains(&mine["state"].as_str().unwrap_or("")), "{mine}");
    assert!(mine["reason"].as_str().is_some_and(|r| !r.is_empty()), "{mine}");
    assert_eq!(mine["argv"][0], "sleep", "{mine}");

    // A session the hub does not have reads gone, never a guess; and it is never a gc candidate.
    let other = row(&census, unknown.pid()).unwrap_or_else(|| panic!("no row: {census}"));
    assert_eq!(other["sessionStatus"], "gone", "{other}");
    assert_eq!(other["state"], "in-use", "{other}");
    for list in ["candidates", "refused"] {
        let named = census["gc"][list]
            .as_array()
            .unwrap()
            .iter()
            .any(|r| r["pid"] == json!(known.pid()) || r["pid"] == json!(unknown.pid()));
        assert!(!named, "gc.{list} names a live session's process: {census}");
    }

    // The asker's own session's processes read yours.
    let asked = census_with(&mut c, json!({"callerSession": sid}), &[known.pid()]).await;
    let mine = row(&asked, known.pid()).unwrap_or_else(|| panic!("no row: {asked}"));
    assert_eq!(mine["owner"], "yours", "{mine}");
    let other = row(&asked, unknown.pid()).unwrap_or_else(|| panic!("no row: {asked}"));
    assert_eq!(other["owner"], "live", "{other}");

    let bad = c.reply(CENSUS, json!({"callerSession": 7})).await;
    assert_eq!(bad["error"]["code"], -32602, "{bad}");
}

#[tokio::test]
async fn the_census_is_advertised_and_served_to_this_machines_clients_only() {
    let hub = hub();
    let mut local = Client::connect(&hub, Origin::Local);
    let init = local
        .call("initialize", json!({"protocolVersion": 1, "clientInfo": {"name": "test"}}))
        .await;
    let advertised = |caps: &Value| {
        caps.as_array().is_some_and(|ids| ids.iter().any(|id| id == "process-census-v1"))
    };
    assert!(advertised(&init["_meta"]["acpmux"]["capabilities"]), "{init}");
    let status = local.call("_acpmux/status", json!({})).await;
    assert!(advertised(&status["capabilities"]), "{status}");

    // The app's own connection reads it too.
    let mut app = Client::connect(&hub, Origin::LocalApp);
    assert_eq!(app.call(CENSUS, json!({})).await["product"], "acpmux");

    // A remote WebSocket device and a peer daemon never do: argv and locks are local state.
    for origin in [Origin::Web, Origin::Peer] {
        let mut remote = Client::connect(&hub, origin);
        let reply = remote.reply(CENSUS, json!({})).await;
        assert_eq!(reply["error"]["code"], -32601, "{origin:?}: {reply}");
        assert!(reply.get("result").is_none(), "{origin:?}: {reply}");
    }
}
