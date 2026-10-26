//! Sub-sessions at the daemon's socket (`hub/subsessions.rs`,
//! `server/subsessions.rs`): an agent session, proven by its caller token,
//! starts children with a first prompt; the session list carries each
//! child's `startedBy`, `shortName` and `depth` and each parent's open
//! `children`; the width and depth limits come from the settings file and
//! refuse with a reason and advice; a parent closes a child's subtree, which
//! frees its slots; limits change at runtime only from an ancestor within
//! its own budget (the person path is the app's proof, `hub/person.rs`);
//! what the tools read back of a child's text is masked (`secret_scan`).
//!
//! Stand-in agents (fake_agent.py); the live run against Claude Code and
//! Codex is `subsessions_live.rs`. One test function: the settings file is
//! read from this process's environment.

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

fn hub() -> Arc<Hub> {
    let mut cfg: Config = serde_json::from_value(json!({
        "harnesses": {"fake": {"argv": ["python3", FAKE]}},
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

    /// The connection an agent's tools open: `initialize` with its caller token.
    async fn as_session(hub: &Arc<Hub>, id: &str) -> Self {
        let mut c = Self::new(hub);
        let token = acpmux::hub::person::caller_token(id);
        let r = c
            .call(
                "initialize",
                json!({"protocolVersion": 1,
                       "_meta": {"acpmux": {"callerSession": {"sessionId": id, "token": token}}}}),
            )
            .await;
        assert!(r.get("error").is_none(), "{r}");
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

    async fn refused(&mut self, m: &str, params: Value) -> Value {
        let r = self.call(m, params).await;
        assert!(r.get("error").is_some(), "{m} should be refused: {r}");
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

const START: &str = "_acpmux/subsession/start";

#[tokio::test]
async fn agents_start_children_within_their_width_and_depth_limits() {
    let root = std::env::temp_dir().join(format!("acpmux-subsessions-it-{}", uuid::Uuid::now_v7()));
    std::fs::create_dir_all(&root).unwrap();
    let settings = root.join("cmux-next.json");
    std::fs::write(&settings, r#"{"agents": {"subsessions": {"maxChildren": 2, "maxDepth": 2}}}"#)
        .unwrap();
    // SAFETY: the only test in this binary; set before any session starts.
    unsafe {
        std::env::set_var("CMUX_NEXT_CONFIG_FILE", &settings);
        std::env::set_var("ACPMUX_HOME", root.join("home"));
        std::env::set_var("FLEET_REGISTRY", root.join("fleet-registry.json"));
    }
    let hub = hub();
    let mut app = Client::new(&hub);
    let new = json!({"cwd": std::env::temp_dir(), "mcpServers": [], "_meta": {"acpmux": {"harness": "fake"}}});
    let parent = app.ok("session/new", new.clone()).await["sessionId"].as_str().unwrap().to_owned();

    // Without a caller token nobody acts as a session.
    let e = app.refused(START, json!({"prompt": "hi"})).await;
    assert_eq!(e["data"]["reason"], "subsessions.caller_required", "{e}");

    // The parent's agent starts two children: each a normal session with its link.
    let mut p = Client::as_session(&hub, &parent).await;
    let a = p.ok(START, json!({"prompt": "echo child a", "name": "Alpha"})).await;
    assert_eq!(a["shortName"], "alpha", "{a}");
    assert_eq!(a["depth"], 1, "{a}");
    let a = a["sessionId"].as_str().unwrap().to_owned();
    let b = p.ok(START, json!({"prompt": "echo child b"})).await["sessionId"]
        .as_str()
        .unwrap()
        .to_owned();
    let sa = app.summary(&a).await;
    assert_eq!(sa["startedBy"], parent.as_str(), "{sa}");
    assert_eq!(sa["depth"], 1, "{sa}");
    assert_eq!(sa["shortName"], "alpha", "{sa}");
    assert!(sa["name"].as_str().unwrap().ends_with("/alpha"), "{sa}");
    assert_eq!(app.summary(&parent).await["children"], 2);
    assert_eq!(app.summary(&parent).await["depth"], 0);

    // Width: a third open child is refused with the limit and the way to ask.
    let e = p.refused(START, json!({"prompt": "echo child c"})).await;
    assert_eq!(e["data"]["reason"], "subsessions.width_limit", "{e}");
    assert_eq!(e["data"]["maxChildren"], 2, "{e}");
    assert_eq!(e["data"]["source"], "settings", "{e}");
    let message = e["message"].as_str().unwrap();
    assert!(message.contains("at most 2") && message.contains("stop_session"), "{message}");

    // The parent sees its children and their replies.
    let list = p.ok("_acpmux/subsession/list", json!({})).await;
    assert_eq!(list["sessions"].as_array().unwrap().len(), 2, "{list}");
    assert_eq!(list["self"]["maxChildren"], 2, "{list}");
    p.ok("_acpmux/wait", json!({"sessions": [a], "until": ["ready"], "timeoutMs": 20000})).await;
    let got = p.ok("_acpmux/subsession/get", json!({"sessionId": a})).await;
    assert_eq!(got["lastReply"], "echo: echo child a", "{got}");
    // A secret in a child's text comes back masked from every read.
    let key = format!("AKIA{}", "Q7ZJ4XK2MD5P3WRT");
    p.ok("_acpmux/subsession/send", json!({"sessionId": a, "text": format!("echo use {key}")}))
        .await;
    p.ok("_acpmux/wait", json!({"sessions": [a], "until": ["ready"], "timeoutMs": 20000})).await;
    let got = p.ok("_acpmux/subsession/get", json!({"sessionId": a})).await;
    let reply = got["lastReply"].as_str().unwrap_or_default();
    assert!(reply.starts_with("echo: echo use [") && !reply.contains(&key), "{got}");
    let list = p.ok("_acpmux/subsession/list", json!({})).await;
    assert!(!list.to_string().contains(&key), "{list}");
    // A reply cut at its length cap is masked before the cut: a key that
    // straddles the cap leaves no unmasked head behind.
    let pad = "a".repeat(3983);
    p.ok("_acpmux/subsession/send", json!({"sessionId": a, "text": format!("{pad} {key}")})).await;
    p.ok("_acpmux/wait", json!({"sessions": [a], "until": ["ready"], "timeoutMs": 20000})).await;
    let got = p.ok("_acpmux/subsession/get", json!({"sessionId": a})).await;
    let reply = got["lastReply"].as_str().unwrap_or_default();
    assert!(reply.ends_with('…') && !reply.contains(&key[..10]), "{reply}");
    // The prompt of the child's running turn is masked too.
    #[cfg(unix)]
    {
        let gate = root.join(key.clone());
        let c = std::ffi::CString::new(gate.as_os_str().as_encoded_bytes()).unwrap();
        // SAFETY: valid NUL-terminated path.
        assert_eq!(unsafe { libc::mkfifo(c.as_ptr(), 0o600) }, 0);
        let text = format!("gate: {}", gate.display());
        p.ok("_acpmux/subsession/send", json!({"sessionId": a, "text": text})).await;
        let got = p.ok("_acpmux/subsession/get", json!({"sessionId": a})).await;
        assert!(got["turn"]["prompt"].is_string(), "{got}");
        assert!(!got.to_string().contains(&key), "{got}");
        let list = p.ok("_acpmux/subsession/list", json!({})).await;
        assert!(!list.to_string().contains(&key), "{list}");
        std::fs::write(&gate, b"go").unwrap();
        p.ok("_acpmux/wait", json!({"sessions": [a], "until": ["ready"], "timeoutMs": 20000}))
            .await;
    }

    // Depth: the child starts a grandchild (depth 2); the grandchild may not go deeper.
    let mut pa = Client::as_session(&hub, &a).await;
    let g = pa.ok(START, json!({"prompt": "echo grandchild"})).await;
    assert_eq!(g["depth"], 2, "{g}");
    let g = g["sessionId"].as_str().unwrap().to_owned();
    let mut pg = Client::as_session(&hub, &g).await;
    let e = pg.refused(START, json!({"prompt": "echo too deep"})).await;
    assert_eq!(e["data"]["reason"], "subsessions.depth_limit", "{e}");
    assert_eq!(e["data"]["maxDepth"], 2, "{e}");

    // A session acts only on its own family.
    let e = pa.refused("_acpmux/subsession/stop", json!({"sessionId": b})).await;
    assert_eq!(e["data"]["reason"], "subsessions.not_family", "{e}");
    // retry_session is held to the same ownership as stop_session, then to the retry's rules.
    let e = pa.refused("_acpmux/subsession/retry", json!({"sessionId": b})).await;
    assert_eq!(e["data"]["reason"], "subsessions.not_family", "{e}");
    let e = p.refused("_acpmux/subsession/retry", json!({"sessionId": a})).await;
    assert_eq!(e["data"]["reason"], "retry.nothing_failed", "{e}");
    let e = p.refused("_acpmux/subsession/retry", json!({"sessionId": a, "subagentId": "x"})).await;
    assert_eq!(e["data"]["reason"], "retry.unknown_subagent", "{e}");
    // Nor its own parent: a session retries only its own sub-sessions.
    let e = pa.refused("_acpmux/subsession/retry", json!({"sessionId": parent})).await;
    assert_eq!(e["data"]["reason"], "subsessions.not_family", "{e}");
    // A child reports to its parent.
    pa.ok("_acpmux/subsession/send", json!({"sessionId": parent, "text": "echo from a"})).await;
    // It never stops its parent's turn.
    let e = pa
        .refused(
            "_acpmux/subsession/send",
            json!({"sessionId": parent, "text": "echo stop", "interrupt": true}),
        )
        .await;
    assert!(e["message"].as_str().unwrap().contains("never interrupts its parent"), "{e}");

    // Limits at runtime: a session never changes its own, and an ancestor
    // gives a descendant at most its own (the parent's maxDepth is 2).
    let e =
        pa.refused("_acpmux/subsession/limits", json!({"sessionId": a, "maxChildren": 9})).await;
    assert_eq!(e["data"]["reason"], "subsessions.limits_person_required", "{e}");
    let e = p.refused("_acpmux/subsession/limits", json!({"sessionId": a, "maxDepth": 3})).await;
    assert_eq!(e["data"]["reason"], "subsessions.limit_out_of_range", "{e}");
    let set = p.ok("_acpmux/subsession/limits", json!({"sessionId": a, "maxChildren": 1})).await;
    assert_eq!(set["subsessionLimits"]["maxChildren"], 1, "{set}");
    assert_eq!(set["subsessionLimits"]["maxChildrenSource"], "session", "{set}");
    let e = pa.refused(START, json!({"prompt": "echo second grandchild"})).await;
    assert_eq!(e["data"]["reason"], "subsessions.width_limit", "{e}");
    assert_eq!(e["data"]["source"], "session", "{e}");
    // The grandchild inherits its parent's override.
    let info = app.ok("_acpmux/info", json!({"sessionId": g})).await;
    assert_eq!(info["subsessionLimits"]["maxChildren"], 1, "{info}");
    assert_eq!(info["subsessionLimits"]["maxChildrenSource"], "inherited", "{info}");
    // A plain unix socket connection is not the person.
    let e = app
        .refused("_acpmux/subsession/limits", json!({"sessionId": parent, "maxChildren": 9}))
        .await;
    assert_eq!(e["data"]["reason"], "permission.person_required", "{e}");

    // Closing a child closes its subtree and frees the slot.
    let stopped = p.ok("_acpmux/subsession/stop", json!({"sessionId": a, "close": true})).await;
    assert_eq!(stopped["closed"].as_array().unwrap().len(), 2, "{stopped}");
    assert_eq!(app.summary(&g).await["status"], "closed");
    assert_eq!(app.summary(&parent).await["children"], 1);
    let c = p.ok(START, json!({"prompt": "echo child c"})).await;
    assert_eq!(c["depth"], 1, "{c}");

    // host auto: the placement engine (`server/place.rs`, the one `new --host
    // auto` calls) weighs this machine, the only one a sub-session starts on,
    // before anything starts; the result says why, in `new --host auto`'s words.
    let q = app.ok("session/new", new.clone()).await["sessionId"].as_str().unwrap().to_owned();
    let here = app.ok("_acpmux/host_health", json!({})).await["host"].as_str().unwrap().to_owned();
    let registry = |max_lanes: u32| {
        let lanes = json!({"build": false, "reserved_gb": 0, "per_lane_gb": 0.1, "free_gb_floor": 0,
            "disk_per_lane_gb": 0.1, "cores_per_lane": 0.1, "max_lanes": max_lanes});
        let doc = json!({"machines": {here.clone(): {"lanes": lanes}}});
        std::fs::write(root.join("fleet-registry.json"), doc.to_string()).unwrap();
    };
    registry(1000);
    let mut pq = Client::as_session(&hub, &q).await;
    // Its role takes no builds.
    let e = pq.refused(START, json!({"prompt": "echo build", "host": "auto-build"})).await;
    assert_eq!(e["data"]["reason"], "subsessions.no_room", "{e}");
    let message = e["message"].as_str().unwrap();
    assert!(
        message.contains(&format!("{here}: no builds here (lanes.build is false)")),
        "{message}"
    );
    // No lane left under its max_lanes (or over its budget, on a busy test machine).
    registry(0);
    let e = pq.refused(START, json!({"prompt": "echo full", "host": "auto"})).await;
    assert_eq!(e["data"]["reason"], "subsessions.no_room", "{e}");
    assert!(e["message"].as_str().unwrap().contains(&format!("{here}: ")), "{e}");
    // Another machine: a family lives on one daemon.
    let e = pq.refused(START, json!({"prompt": "echo far", "host": "elsewhere"})).await;
    assert_eq!(e["data"]["reason"], "subsessions.host_unsupported", "{e}");
    let list = pq.ok("_acpmux/subsession/list", json!({})).await;
    assert_eq!(
        list["sessions"].as_array().unwrap().len(),
        0,
        "a refused start made a child: {list}"
    );
    // With room it starts here and says why (a busy test machine may refuse it).
    registry(1000);
    let r = pq.call(START, json!({"prompt": "echo placed", "host": "auto"})).await;
    if r.get("error").is_some() {
        assert_eq!(r["error"]["data"]["reason"], "subsessions.no_room", "{r}");
    } else {
        let placed = r["result"]["placed"].as_str().unwrap_or_default();
        assert!(placed.starts_with(&format!("placed on {here}: ")), "{r}");
        assert!(placed.contains("room for"), "{r}");
    }
    // This machine's own name is no placement.
    let own = pq.ok(START, json!({"prompt": "echo own", "host": here.clone()})).await;
    assert!(own.get("placed").is_none(), "{own}");

    // Settings turn the tools off.
    std::fs::write(&settings, r#"{"agents": {"subsessions": {"enabled": false}}}"#).unwrap();
    let e = p.refused(START, json!({"prompt": "echo off"})).await;
    assert_eq!(e["data"]["reason"], "subsessions.disabled", "{e}");

    let _ = std::fs::remove_dir_all(&root);
}
