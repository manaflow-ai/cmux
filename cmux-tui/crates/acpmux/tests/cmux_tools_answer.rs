//! A chat cmux-next started on another machine follows the answer of the Mac that started it to
//! "should agents you start in cmux get cmux's tools?" (`hub/cmux_tools_answer.rs`): the peer
//! daemon runs the chat's harness with that answer as `CMUX_AGENT_TOOLS_ANSWER`, which a
//! `cmux mcp serve` the chat starts uses over the peer's own settings file. Only a peer daemon's
//! own connection brings an answer; a Web client's field is ignored (a paired device's too: the
//! `cmux_tools_answer` unit tests), and a chat started on the machine itself has none (its own
//! file applies).

#[path = "support/daemon_env.rs"]
mod daemon_env;
// This process runs a stand-in agent (tests/fake_agent.py).
const HERMETIC: daemon_env::Process = daemon_env::Process::stand_in();

use acpmux::config::{Config, StoreMode};
use acpmux::hub::Hub;
use acpmux::rpc::Message;
use acpmux::server::{ConnAuth, Origin, serve_connection_authed};
use serde_json::{Value, json};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::mpsc;

const FAKE_AGENT: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");

fn dir(tag: &str) -> PathBuf {
    let d = std::env::temp_dir().join(format!("acta-{tag}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&d);
    std::fs::create_dir_all(d.join("work")).unwrap();
    std::fs::canonicalize(&d).unwrap()
}

fn hub(d: &Path) -> Arc<Hub> {
    let mut cfg: Config = serde_json::from_value(json!({
        "harnesses": {"fakeacp": {"argv": ["python3", FAKE_AGENT], "family": "sample"}},
        "defaultHarness": "fakeacp",
        "permissionPolicy": "ask",
        "webRoots": [d.join("work")],
        "webAskingModes": {"sample": ["ask"]},
    }))
    .unwrap();
    cfg.store.mode = StoreMode::Memory;
    cfg.path = Some(d.join("home/config.json"));
    let store = acpmux::store::open(&cfg.store, Path::new("/nonexistent")).unwrap();
    Hub::new(cfg, store)
}

struct Client(mpsc::Sender<String>, mpsc::Receiver<String>, i64);

impl Client {
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
                .unwrap()
                .unwrap();
            let v: Value = serde_json::from_str(&line).unwrap();
            if v.get("id") == Some(&json!(id)) {
                return v;
            }
        }
    }

    /// `CMUX_AGENT_TOOLS_ANSWER` as the harness of a new chat sees it, the chat started with
    /// `_meta.acpmux.cmuxTools` = `sent` (none when `None`).
    async fn answer_seen(&mut self, d: &Path, sent: Option<&str>) -> String {
        let mut params = json!({"cwd": d.join("work"), "mcpServers": []});
        if let Some(sent) = sent {
            params["_meta"] = json!({"acpmux": {"cmuxTools": sent}});
        }
        let r = self.call("session/new", params).await;
        let s = r["result"]["sessionId"].as_str().unwrap_or_else(|| panic!("{r}")).to_owned();
        let p = json!({"sessionId": s, "prompt": [{"type": "text", "text": "envs: CMUX_AGENT_TOOLS_ANSWER"}]});
        let r = self.call("session/prompt", p).await;
        assert!(r.get("error").is_none(), "{r}");
        let e = self.call("_acpmux/events", json!({"sessionId": s, "limit": 1000})).await;
        let text: String = e["result"]["events"]
            .as_array()
            .into_iter()
            .flatten()
            .filter_map(|e| e.pointer("/msg/params/update/content/text").and_then(Value::as_str))
            .collect();
        let env: Value = serde_json::from_str(&text).unwrap_or_else(|_| panic!("{text}"));
        env["CMUX_AGENT_TOOLS_ANSWER"].as_str().unwrap_or_default().to_owned()
    }
}

#[tokio::test]
async fn a_chat_a_peer_daemon_started_runs_with_that_macs_answer() {
    for (tag, origin, auth, sent, seen) in [
        ("peer-off", Origin::Peer, ConnAuth::PeerToken, Some("off"), "off"),
        ("peer-on", Origin::Peer, ConnAuth::PeerToken, Some("on"), "on"),
        // The Cloud carrier's owner connection (`ConnAuth::CarrierOwner`) needs an attested
        // carrier, which an in-process connection has not: the unit tests pin that it counts.
        // Not a peer daemon: whatever it sends, the chat has no answer from elsewhere.
        ("web", Origin::Web, ConnAuth::ListenerToken, Some("on"), ""),
        // A peer daemon that sent none (an older Mac): this machine's own file applies.
        ("peer-none", Origin::Peer, ConnAuth::PeerToken, None, ""),
    ] {
        let d = dir(tag);
        let hub = hub(&d);
        let mut client = Client::new(&hub, origin, auth);
        let got = client.answer_seen(&d, sent).await;
        let _ = std::fs::remove_dir_all(&d);
        assert_eq!(got, seen, "{tag}");
    }
}
