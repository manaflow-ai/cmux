//! The GitHub broker (`src/github_broker.rs`): a machine the person added asks the Mac (A, which
//! mirrors it as a peer) for a GitHub action, and A runs it with a stand-in `gh`.

#[path = "support/daemon_env.rs"]
mod daemon_env;
// This process runs stand-in agents (the fake agents under tests/).
const HERMETIC: daemon_env::Process = daemon_env::Process::stand_in();

use acpmux::config::{Config, StoreMode};
use acpmux::hub::Hub;
use acpmux::rpc::{Message, method};
use acpmux::server::{Origin, serve_connection_with};
use futures_util::{SinkExt, StreamExt};
use serde_json::{Value, json};
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::{mpsc, oneshot};

/// By name, so the same test runs, and fails, on a build from before the broker.
const GITHUB_ACTION: &str = "_acpmux/github_action";

fn hub() -> Arc<Hub> {
    let mut cfg = Config::default();
    cfg.store.mode = StoreMode::Memory;
    let store = acpmux::store::open(&cfg.store, std::path::Path::new("/nonexistent")).unwrap();
    Hub::new(cfg, store)
}

/// A stand-in `gh` first on this process's PATH: it prints what it was asked, and whether a
/// token reached it. Set once, before any test here starts a hub.
fn fake_gh() {
    static ONCE: std::sync::Once = std::sync::Once::new();
    ONCE.call_once(|| {
        use std::os::unix::fs::PermissionsExt;
        let bin = std::env::temp_dir().join(format!("ghb-bin-{}", std::process::id()));
        std::fs::create_dir_all(&bin).unwrap();
        let gh = bin.join("gh");
        let script = "#!/bin/sh\necho \"gh $*\"\n[ -n \"$GH_TOKEN$GITHUB_TOKEN\" ] && echo token-seen\nexit 0\n";
        std::fs::write(&gh, script).unwrap();
        std::fs::set_permissions(&gh, std::fs::Permissions::from_mode(0o755)).unwrap();
        let path = format!("{}:{}", bin.display(), std::env::var("PATH").unwrap_or_default());
        // SAFETY: under the Once, before this process's tests start a hub or a child.
        unsafe { std::env::set_var("PATH", path) };
    });
}

/// A unix-socket client of `hub`; with `caller`, it is that agent session (`hub/person.rs`).
struct C(mpsc::Sender<String>, mpsc::Receiver<String>, i64);

impl C {
    async fn new(hub: &Arc<Hub>, caller: Option<&str>) -> Self {
        let (in_tx, in_rx) = mpsc::channel(64);
        let (out_tx, out_rx) = mpsc::channel(4096);
        tokio::spawn(serve_connection_with(hub.clone(), in_rx, out_tx, Origin::Local));
        let mut c = C(in_tx, out_rx, 0);
        let mut hello = json!({"protocolVersion": 1, "clientInfo": {"name": "t"}});
        if let Some(id) = caller {
            let token = acpmux::hub::person::caller_token(id);
            hello["_meta"] =
                json!({"acpmux": {"callerSession": {"sessionId": id, "token": token}}});
        }
        c.call(method::INITIALIZE, hello).await.unwrap();
        c
    }

    async fn call(&mut self, m: &str, params: Value) -> Result<Value, Value> {
        self.2 += 1;
        let id = self.2;
        self.0.send(Message::request(id, m, params).to_line()).await.unwrap();
        loop {
            let line = tokio::time::timeout(Duration::from_secs(30), self.1.recv())
                .await
                .expect("timeout")
                .expect("closed");
            let v: Value = serde_json::from_str(&line).unwrap();
            if v.get("id") == Some(&json!(id)) {
                return match v.get("error") {
                    Some(e) => Err(e.clone()),
                    None => Ok(v["result"].clone()),
                };
            }
        }
    }
}

/// A stand-in for the added machine's daemon: it answers the Mac's handshake saying it serves
/// the Mac as `origin`, then asks it for `action` once (with `early`, before it answers the
/// Mac's `initialize`) and hands back the Mac's whole answer.
async fn lane_asking(
    action: Value,
    origin: &'static str,
    early: bool,
) -> (u16, oneshot::Receiver<Value>) {
    use tokio_tungstenite::tungstenite::Message as Ws;
    let l = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = l.local_addr().unwrap().port();
    let (tx, rx) = oneshot::channel();
    tokio::spawn(async move {
        let (tcp, _) = l.accept().await.unwrap();
        let mut ws = tokio_tungstenite::accept_async(tcp).await.unwrap();
        let mut tx = Some(tx);
        while let Some(Ok(Ws::Text(text))) = ws.next().await {
            let v: Value = serde_json::from_str(&text).unwrap();
            if v["id"] == "lane-1" {
                let _ = tx.take().map(|tx| tx.send(v));
                continue;
            }
            let Ok(Message::Request { id, method: m, .. }) = Message::parse(&text) else {
                continue;
            };
            let result = match m.as_str() {
                method::INITIALIZE => json!({"protocolVersion": 1,
                    "_meta": {"acpmux": {"version": "0", "build": "t", "origin": origin}}}),
                method::MUX_WATCH => json!({"sessions": []}),
                _ => json!({}),
            };
            let mut lines = vec![Message::ok(id, result).to_line()];
            let ask_now = if early { m == method::INITIALIZE } else { m == method::MUX_WATCH };
            if ask_now {
                let ask = Message::request(json!("lane-1"), GITHUB_ACTION, action.clone());
                if early {
                    lines.insert(0, ask.to_line());
                } else {
                    lines.push(ask.to_line());
                }
            }
            for line in lines {
                ws.send(Ws::Text(line.trim_end().to_owned().into())).await.unwrap();
            }
        }
    });
    (port, rx)
}

/// What the Mac answers a lane it added with `githubBroker` as given.
async fn mac_answers(app: &mut C, name: &str, github_broker: Option<bool>, action: Value) -> Value {
    mac_answers_link(app, name, github_broker, action, "peer", false).await
}

async fn mac_answers_link(
    app: &mut C,
    name: &str,
    github_broker: Option<bool>,
    action: Value,
    origin: &'static str,
    early: bool,
) -> Value {
    let (port, answer) = lane_asking(action, origin, early).await;
    let mut add = json!({"name": name, "url": format!("ws://127.0.0.1:{port}"), "token": "tok",
        "wait": true});
    if let Some(on) = github_broker {
        add["githubBroker"] = json!(on);
    }
    app.call("_acpmux/peer_add", add).await.unwrap();
    tokio::time::timeout(Duration::from_secs(30), answer).await.expect("the Mac answered").unwrap()
}

#[tokio::test]
async fn the_mac_runs_an_added_machines_action_with_its_own_gh_and_no_other_peers() {
    fake_gh();
    let a = hub();
    let mut app = C::new(&a, None).await;

    let read = json!({"sessionId": "s-1", "action": "read", "repo": "o/r"});
    let v = mac_answers(&mut app, "added", Some(true), read.clone()).await;
    let out = v["result"]["output"].as_str().unwrap_or_else(|| panic!("{v}"));
    assert!(out.starts_with("gh repo view o/r --json="), "{v}");
    assert!(!out.contains("token-seen"), "{v}");
    let comment = json!({"action": "comment", "repo": "o/r", "issue": 7, "body": "hi"});
    let v = mac_answers(&mut app, "added2", Some(true), comment).await;
    assert_eq!(v["result"]["output"], "gh issue comment 7 --body=hi --repo=o/r\n", "{v}");

    // What the Mac does not offer is refused there too, whatever the machine sent.
    let merge = json!({"action": "merge", "repo": "o/r", "issue": 7});
    let v = mac_answers(&mut app, "added3", Some(true), merge).await;
    assert_eq!(v["error"]["code"], -32602, "{v}");

    // A peer added any other way is lent nothing.
    let v = mac_answers(&mut app, "plain", None, read.clone()).await;
    assert_eq!(v["error"]["data"]["reason"], "github.denied", "{v}");
}

/// The review of #24797 at 758863e: a lent peer was served before its handshake finished, and
/// on a link where it served the Mac as Web.
#[tokio::test]
async fn the_mac_lends_only_on_a_link_whose_handshake_made_it_a_peer() {
    fake_gh();
    let a = hub();
    let mut app = C::new(&a, None).await;
    let read = json!({"action": "read", "repo": "o/r"});
    let v = mac_answers_link(&mut app, "early", Some(true), read.clone(), "peer", true).await;
    assert_eq!(v["error"]["data"]["reason"], "github.denied", "asked before the handshake: {v}");
    let v = mac_answers_link(&mut app, "as-web", Some(true), read.clone(), "remote", false).await;
    assert_eq!(v["error"]["data"]["reason"], "github.denied", "served the Mac as Web: {v}");
    let v = mac_answers_link(&mut app, "lent", Some(true), read, "peer", false).await;
    assert!(v["result"]["output"].as_str().is_some_and(|o| o.starts_with("gh repo view")), "{v}");
}

/// The review of #24797's Add Machine part at 5e03d7f: lending to a peer added before replaced its
/// saved tokens with none.
#[tokio::test]
async fn lending_to_a_peer_added_before_keeps_its_tokens() {
    let a = hub();
    let mut app = C::new(&a, None).await;
    let url = "ws://127.0.0.1:9";
    let add = json!({"name": "old", "url": url, "token": "tok", "peerToken": "pt"});
    app.call("_acpmux/peer_add", add).await.unwrap();
    let lend = json!({"name": "old", "url": url, "githubBroker": true});
    app.call("_acpmux/peer_add", lend).await.unwrap();
    let saved = a.config.read().await.peers.get("old").cloned().unwrap();
    assert!(saved.github_broker);
    assert_eq!((saved.token.as_deref(), saved.peer_token.as_deref()), (Some("tok"), Some("pt")));
}
