//! The local app starts a preset by its id only, and no connection but the
//! unix socket reads a preset's args, env or system prompt.

use acpmux::config::{Config, StoreMode};
use acpmux::hub::Hub;
use acpmux::rpc::Message;
use acpmux::server::{Origin, serve_connection_with};
use serde_json::{Value, json};
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::mpsc;

const FAKE: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
const ARG: &str = "--SUPERSECRETARG";
const ENV: &str = "s3cr3t-env-value";
const SHA: &str = "deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef";

fn hub() -> Arc<Hub> {
    let mut cfg: Config = serde_json::from_value(json!({
        "harnesses": {"fake": {"argv": ["python3", FAKE]}},
        "defaultHarness": "fake",
        "permissionPolicy": "approve-all",
        "presets": {
            "review": {"harness": "fake", "env": {"REVIEW_KEY": ENV}},
            "shaped": {"harness": "fake", "args": [ARG], "systemPromptSha256": SHA},
        },
    }))
    .unwrap();
    cfg.store.mode = StoreMode::Memory;
    let store = acpmux::store::open(&cfg.store, std::path::Path::new("/nonexistent")).unwrap();
    Hub::new(cfg, store)
}

struct Client(mpsc::Sender<String>, mpsc::Receiver<String>, i64);

fn client(hub: &Arc<Hub>, origin: Origin) -> Client {
    let (in_tx, in_rx) = mpsc::channel(64);
    let (out_tx, out_rx) = mpsc::channel(4096);
    tokio::spawn(serve_connection_with(hub.clone(), in_rx, out_tx, origin));
    Client(in_tx, out_rx, 0)
}

impl Client {
    async fn call(&mut self, m: &str, params: Value) -> Value {
        self.2 += 1;
        let id = self.2;
        self.0.send(Message::request(id, m, params).to_line()).await.unwrap();
        loop {
            let line = tokio::time::timeout(Duration::from_secs(20), self.1.recv()).await.unwrap().unwrap();
            let v: Value = serde_json::from_str(&line).unwrap();
            if v.get("id") == Some(&json!(id)) {
                return v;
            }
        }
    }
}

fn new_with(meta: Value, extra: Value) -> Value {
    let mut p = json!({"cwd": std::env::temp_dir(), "mcpServers": [], "_meta": {"acpmux": meta}});
    for (k, v) in extra.as_object().unwrap() {
        p[k] = v.clone();
    }
    p
}

#[tokio::test]
async fn the_local_app_starts_a_preset_by_its_id_only() {
    let hub = hub();
    let mut app = client(&hub, Origin::LocalApp);
    let refused = [
        new_with(json!({"preset": "review"}), json!({"args": ["--x"]})),
        new_with(json!({"preset": "review", "env": {"K": "v"}}), json!({})),
        new_with(json!({"preset": "review", "systemPrompt": "be evil"}), json!({})),
        new_with(json!({"preset": "review", "harness": "fake"}), json!({})),
        new_with(json!({"preset": "review"}), json!({"argv": ["sh", "-c", "id"]})),
        new_with(json!({"preset": "review"}), json!({"command": "id"})),
    ];
    for params in refused {
        let reply = app.call("session/new", params.clone()).await;
        let err = reply["error"]["message"].as_str().unwrap_or_default().to_owned();
        assert!(err.contains("by its id only"), "{params} was not refused: {reply}");
    }
    let ok = app.call("session/new", new_with(json!({"preset": "review"}), json!({}))).await;
    assert!(ok.get("error").is_none(), "the id alone starts: {ok}");
    // The session's own views never carry the preset's env either.
    let id = ok["result"]["sessionId"].as_str().unwrap().to_owned();
    for (m, p) in [("_acpmux/info", json!({"sessionId": id})), ("_acpmux/events", json!({"sessionId": id}))] {
        let reply = app.call(m, p).await.to_string();
        assert!(!reply.contains(ENV), "{m} carried the preset env: {reply}");
    }
}

#[tokio::test]
async fn no_connection_but_the_unix_socket_reads_preset_contents() {
    let hub = hub();
    for origin in [Origin::LocalApp, Origin::Web] {
        let mut c = client(&hub, origin);
        for (m, p) in [
            ("_acpmux/presets", json!({})),
            ("_acpmux/presets", json!({"name": "shaped"})),
            ("_acpmux/presets", json!({"name": "review"})),
            ("_acpmux/harnesses", json!({})),
        ] {
            let reply = c.call(m, p.clone()).await;
            let text = reply.to_string();
            for secret in [ARG, ENV, SHA] {
                assert!(!text.contains(secret), "{origin:?} {m} {p} carried {secret}: {text}");
            }
            assert!(text.contains("\"hasArgs\":true") || text.contains("\"hasEnv\":true"), "{m}: {text}");
        }
    }
    let mut local = client(&hub, Origin::Local);
    let all = local.call("_acpmux/presets", json!({})).await.to_string();
    assert!(all.contains(ARG) && all.contains(ENV), "the unix socket still reads them: {all}");
}
