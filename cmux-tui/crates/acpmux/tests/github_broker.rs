//! The GitHub broker (`src/github_broker.rs`): a machine the person added asks the Mac (A, which
//! mirrors it as a peer) for a GitHub action, and A runs it with a stand-in `gh`.
//! Unix only: the stand-in `gh` is a shell script.
#![cfg(unix)]

#[path = "support/daemon_env.rs"]
mod daemon_env;
// This process runs stand-in agents (the fake agents under tests/).
const HERMETIC: daemon_env::Process = daemon_env::Process::stand_in();

use acpmux::config::{Config, StoreMode};
use acpmux::hub::Hub;
use acpmux::rpc::{Message, method};
use acpmux::server::peer_auth::PeerAuth;
use acpmux::server::{
    ConnAuth, Origin, WsAuth, bind_ws, serve_connection_authed, serve_connection_with,
    serve_ws_with,
};
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

/// A stand-in `gh` first on this process's PATH: it prints what it was asked, whether a token
/// reached it, and whether it was pointed anywhere but github.com. Set once, before any test
/// here starts a hub.
fn fake_gh() {
    static ONCE: std::sync::Once = std::sync::Once::new();
    ONCE.call_once(|| {
        use std::os::unix::fs::PermissionsExt;
        let bin = gh_bin();
        std::fs::create_dir_all(&bin).unwrap();
        let gh = bin.join("gh");
        // For `o/leak` it fails printing a token, and for `o/print` it prints one. For `o/slow`
        // it says it started, and says it finished 4 s later.
        let script = "#!/bin/sh\ncase \"$*\" in\n*o/slow*) d=$(dirname \"$0\"); touch \"$d/slow-started\"; sleep 4; touch \"$d/slow-done\"; exit 0;;\n*o/leak*) echo \"gh: bad credentials gho_secretB\" >&2; exit 1;;\n*o/print*) echo \"ok github_pat_secretC\"; exit 0;;\nesac\necho \"gh $*\"\n[ -n \"$GH_TOKEN$GITHUB_TOKEN\" ] && echo token-seen\n[ \"$GH_HOST\" = github.com ] || echo host-not-github\nexit 0\n";
        std::fs::write(&gh, script).unwrap();
        std::fs::set_permissions(&gh, std::fs::Permissions::from_mode(0o755)).unwrap();
        let path = format!("{}:{}", bin.display(), std::env::var("PATH").unwrap_or_default());
        // SAFETY: under the Once, before this process's tests start a hub or a child. The
        // daemon's own GitHub token must not reach the `gh` it runs for a machine.
        unsafe {
            std::env::set_var("PATH", path);
            std::env::set_var("GITHUB_TOKEN", "a-token-gh-must-not-see");
        }
    });
}

/// Where `fake_gh` is.
fn gh_bin() -> std::path::PathBuf {
    std::env::temp_dir().join(format!("ghb-bin-{}", std::process::id()))
}

/// A unix-socket client of `hub`; with `caller`, it is that agent session (`hub/person.rs`).
struct C(mpsc::Sender<String>, mpsc::Receiver<String>, i64);

impl C {
    async fn new(hub: &Arc<Hub>, caller: Option<&str>) -> Self {
        Self::open(hub, caller, Origin::Local).await
    }

    async fn with_origin(hub: &Arc<Hub>, origin: Origin) -> Self {
        Self::open(hub, None, origin).await
    }

    async fn open(hub: &Arc<Hub>, caller: Option<&str>, origin: Origin) -> Self {
        let (in_tx, in_rx) = mpsc::channel(64);
        let (out_tx, out_rx) = mpsc::channel(4096);
        tokio::spawn(serve_connection_with(hub.clone(), in_rx, out_tx, origin));
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
/// the Mac as `origin`, then asks it for `action` once (`when`) and hands back the Mac's whole
/// answer.
async fn lane_asking(
    action: Value,
    origin: &'static str,
    when: Ask,
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
            // As a lane sends it: with the time it stops waiting (`deadline_from`).
            let mut action = action.clone();
            action["deadlineMs"] = json!(acpmux::store::now_ms() + 90_000);
            let ask = Message::request(json!("lane-1"), GITHUB_ACTION, action).to_line();
            match when {
                Ask::BeforeInitialize if m == method::INITIALIZE => lines.insert(0, ask),
                Ask::BeforeWatch if m == method::INITIALIZE => lines.push(ask),
                Ask::AfterWatch if m == method::MUX_WATCH => lines.push(ask),
                _ => {}
            }
            for line in lines {
                ws.send(Ws::Text(line.trim_end().to_owned().into())).await.unwrap();
            }
        }
    });
    (port, rx)
}

/// When the stand-in machine asks: before it answers the Mac's `initialize`, right after it
/// (before the Mac's `_acpmux/watch`), or after it answers the watch, as a real one does.
#[derive(Clone, Copy)]
enum Ask {
    BeforeInitialize,
    BeforeWatch,
    AfterWatch,
}

/// What the Mac answers a lane it added with `githubBroker` as given.
async fn mac_answers(app: &mut C, name: &str, github_broker: Option<bool>, action: Value) -> Value {
    mac_answers_link(app, name, github_broker, action, "peer", Ask::AfterWatch).await
}

async fn mac_answers_link(
    app: &mut C,
    name: &str,
    github_broker: Option<bool>,
    action: Value,
    origin: &'static str,
    when: Ask,
) -> Value {
    let (port, answer) = lane_asking(action, origin, when).await;
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

/// Review of #24797 at c43d357: what `gh` printed went back as it was, so a token it printed (a
/// debug setting, a wrapper) reached the machine.
#[tokio::test]
async fn no_token_gh_prints_goes_back_to_the_machine() {
    fake_gh();
    let a = hub();
    let mut app = C::new(&a, None).await;
    let leak = json!({"sessionId": "s-1", "action": "read", "repo": "o/leak"});
    let v = mac_answers(&mut app, "leaky", Some(true), leak).await;
    assert_eq!(v["error"]["data"]["reason"], "github.command_failed", "{v}");
    assert!(!v.to_string().contains("secretB"), "{v}");
    let print = json!({"sessionId": "s-1", "action": "read", "repo": "o/print"});
    let v = mac_answers(&mut app, "leaky2", Some(true), print).await;
    assert_eq!(v["result"]["output"], "ok [redacted]\n", "{v}");
}

/// The review of #24797 at 758863e: a lent peer was served before its handshake finished, and
/// on a link where it served the Mac as Web.
#[tokio::test]
async fn the_mac_lends_only_on_a_link_whose_handshake_made_it_a_peer() {
    fake_gh();
    let a = hub();
    let mut app = C::new(&a, None).await;
    let read = json!({"action": "read", "repo": "o/r"});
    let early = Ask::BeforeInitialize;
    let v = mac_answers_link(&mut app, "early", Some(true), read.clone(), "peer", early).await;
    assert_eq!(v["error"]["data"]["reason"], "github.denied", "asked before the handshake: {v}");
    // The review of #24797 at 4dfbc25: the gate opened at `initialize`, before the watch.
    let mid = Ask::BeforeWatch;
    let v = mac_answers_link(&mut app, "mid", Some(true), read.clone(), "peer", mid).await;
    assert_eq!(v["error"]["data"]["reason"], "github.denied", "asked before the watch: {v}");
    let done = Ask::AfterWatch;
    let v = mac_answers_link(&mut app, "as-web", Some(true), read.clone(), "remote", done).await;
    assert_eq!(v["error"]["data"]["reason"], "github.denied", "served the Mac as Web: {v}");
    let v = mac_answers_link(&mut app, "lent", Some(true), read, "peer", done).await;
    assert!(v["result"]["output"].as_str().is_some_and(|o| o.starts_with("gh repo view")), "{v}");
}

/// The review of #24797 at 4dfbc25: a page, the app's pane or a peer could ask the Mac's daemon
/// for a GitHub action naming a session it mirrors, and have it forwarded to that machine.
#[tokio::test]
async fn no_page_pane_or_peer_asks_for_a_github_action() {
    let a = hub();
    for origin in [Origin::Web, Origin::LocalApp, Origin::Peer] {
        let mut c = C::with_origin(&a, origin).await;
        let ask = json!({"sessionId": "mac-b/s-1", "action": "read", "repo": "o/r"});
        let e = c.call(GITHUB_ACTION, ask).await.unwrap_err();
        let text = e.to_string();
        assert!(text.contains("_acpmux/github_action"), "{origin:?}: {text}");
    }
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

/// A machine whose agent session asks, with the session config of a real lane.
fn lane_hub() -> Arc<Hub> {
    let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
    let profile = acpmux::config::HarnessProfile {
        kind: Default::default(),
        argv: vec!["python3".into(), fake.into()],
        env: Default::default(),
        description: None,
        fallback: None,
        family: None,
        models: vec![],
        model: None,
        effort: None,
        policy: None,
    };
    let mut cfg = Config {
        harnesses: [("fake".to_owned(), profile)].into(),
        default_harness: Some("fake".into()),
        ..Default::default()
    };
    cfg.store.mode = StoreMode::Memory;
    let store = acpmux::store::open(&cfg.store, std::path::Path::new("/nonexistent")).unwrap();
    Hub::new(cfg, store)
}

/// B's WebSocket listener with a peer token; returns its port and that token.
async fn listen(b: Arc<Hub>, tag: &str) -> (u16, String) {
    let home = std::env::temp_dir().join(format!("ghb-{tag}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&home);
    let auth = PeerAuth::create(&home).unwrap();
    let token = std::fs::read_to_string(acpmux::server::peer_auth::token_path(&home)).unwrap();
    let l = bind_ws("127.0.0.1:0").await.unwrap();
    let port = l.local_addr().unwrap().port();
    let auth = WsAuth { local_app: None, peer: Some(Arc::new(auth)) };
    tokio::spawn(serve_ws_with(b, l, "tok".into(), auth));
    (port, token)
}

/// B, one agent session on it, and A mirroring it with `githubBroker` as given.
async fn pair(a: &mut C, tag: &str, github_broker: Option<bool>) -> (Arc<Hub>, String) {
    let b = lane_hub();
    let (port, peer_token) = listen(b.clone(), tag).await;
    let s = C::new(&b, None)
        .await
        .call(method::SESSION_NEW, json!({"cwd": std::env::temp_dir(), "mcpServers": []}))
        .await
        .unwrap();
    let mut add = json!({"name": tag, "url": format!("ws://127.0.0.1:{port}"), "token": "tok",
        "peerToken": peer_token, "wait": true});
    if let Some(on) = github_broker {
        add["githubBroker"] = json!(on);
    }
    let peers = a.call("_acpmux/peer_add", add).await.unwrap();
    let listed = peers["peers"].as_array().unwrap().iter().find(|p| p["name"] == tag).unwrap();
    assert_eq!(listed["connected"], true, "{peers}");
    (b, s["sessionId"].as_str().unwrap().to_owned())
}

#[tokio::test]
async fn an_added_machines_agent_uses_the_macs_gh_login_and_no_other_peers_does() {
    fake_gh();
    let a = hub();
    let mut app = C::new(&a, None).await;

    // Added with Add Machine: the agent's action runs on A, with A's own login.
    let (b, session) = pair(&mut app, "added", Some(true)).await;
    let mut agent = C::new(&b, Some(&session)).await;
    let read = agent
        .call(GITHUB_ACTION, json!({"action": "read", "repo": "o/r"}))
        .await
        .expect("an added machine's agent reads through the Mac");
    let out = read["output"].as_str().unwrap();
    assert!(out.starts_with("gh repo view o/r --json="), "{out}");
    assert!(!out.contains("token-seen"), "{out}");
    let comment = agent
        .call(GITHUB_ACTION, json!({"action": "comment", "repo": "o/r", "issue": 7, "body": "hi"}))
        .await
        .unwrap();
    assert_eq!(comment["output"], "gh issue comment 7 --body=hi --repo=o/r\n");
    // Each decision is on the agent's session, with no body in it.
    let page = agent
        .call(method::MUX_EVENTS, json!({"sessionId": session, "afterSeq": 0, "limit": 1000}))
        .await
        .unwrap();
    let rows: Vec<&Value> = page["events"]
        .as_array()
        .unwrap()
        .iter()
        .filter(|e| e["kind"] == "github_broker_action")
        .collect();
    assert_eq!(rows.len(), 2, "{page}");
    assert_eq!(rows[1]["msg"]["status"], "allowed");
    assert!(!rows[1].to_string().contains("\"hi\""), "{}", rows[1]);

    // An action outside the broker's words is refused on the machine, before A sees it.
    let e = agent
        .call(GITHUB_ACTION, json!({"action": "read", "repo": "o/r", "body": "x"}))
        .await
        .unwrap_err();
    assert!(e["message"].as_str().unwrap().contains("body is not used by read"), "{e}");
    // So is anything that is not an agent session there.
    let e = C::new(&b, None)
        .await
        .call(GITHUB_ACTION, json!({"action": "read", "repo": "o/r"}))
        .await
        .unwrap_err();
    assert!(e["message"].as_str().unwrap().contains("acpmux session's agent"), "{e}");

    // A peer added any other way is lent nothing.
    let (b2, session2) = pair(&mut app, "plain", None).await;
    let e = C::new(&b2, Some(&session2))
        .await
        .call(GITHUB_ACTION, json!({"action": "read", "repo": "o/r"}))
        .await
        .unwrap_err();
    assert_eq!(e["data"]["reason"], "github.no_owner", "{e}");
}

/// The review of the lane part at 1ea8bb6: a Mac counted as lending from its `initialize`, before
/// its own side of the handshake was done, so an action then reached a Mac that refused it.
#[tokio::test]
async fn a_mac_lends_from_its_watch_and_each_action_says_when_it_stops_waiting() {
    let b = lane_hub();
    let s = C::new(&b, None)
        .await
        .call(method::SESSION_NEW, json!({"cwd": std::env::temp_dir(), "mcpServers": []}))
        .await
        .unwrap();
    let session = s["sessionId"].as_str().unwrap().to_owned();
    // The Mac's link, as the peer listener serves it once it read this machine's peer token.
    let (mac_tx, mac_in) = mpsc::channel(64);
    let (mac_out, mut mac_rx) = mpsc::channel(4096);
    tokio::spawn(serve_connection_authed(
        b.clone(),
        mac_in,
        mac_out,
        Origin::Peer,
        ConnAuth::PeerToken,
    ));
    let hello = json!({"protocolVersion": 1, "clientInfo": {"name": "mac"},
        "_meta": {"acpmux": {"githubBroker": true}}});
    mac_tx.send(Message::request(1, method::INITIALIZE, hello).to_line()).await.unwrap();
    let read = json!({"action": "read", "repo": "o/r"});
    let mut agent = C::new(&b, Some(&session)).await;
    let e = agent.call(GITHUB_ACTION, read.clone()).await.unwrap_err();
    assert_eq!(e["data"]["reason"], "github.no_owner", "before the Mac's watch: {e}");

    let watch = Message::request(2, method::MUX_WATCH, json!({"enabled": true}));
    mac_tx.send(watch.to_line()).await.unwrap();
    // The link lends from the watch's answer on (the watch reply is built asynchronously).
    loop {
        let line = tokio::time::timeout(Duration::from_secs(30), mac_rx.recv())
            .await
            .expect("the watch is answered")
            .unwrap();
        let v: Value = serde_json::from_str(&line).unwrap();
        if v["id"] == json!(2) {
            assert!(v.get("error").is_none(), "{v}");
            break;
        }
    }
    // It counts just after its answer is queued: until then an ask finds no Mac.
    let asked = tokio::spawn(async move {
        loop {
            match agent.call(GITHUB_ACTION, read.clone()).await {
                Err(e) if e["data"]["reason"] == "github.no_owner" => {
                    tokio::time::sleep(Duration::from_millis(10)).await;
                }
                answer => break answer,
            }
        }
    });
    let ask = loop {
        let line = tokio::time::timeout(Duration::from_secs(30), mac_rx.recv())
            .await
            .expect("the action reaches the Mac")
            .unwrap();
        let v: Value = serde_json::from_str(&line).unwrap();
        if v["method"] == GITHUB_ACTION {
            break v;
        }
    };
    let deadline = ask["params"]["deadlineMs"].as_u64().expect("a deadline");
    let now = acpmux::store::now_ms();
    assert!(deadline > now && deadline <= now + 90_000, "{ask}");
    let answer =
        Message::ok(ask["id"].clone(), json!({"action": "read", "repo": "o/r", "output": "ok"}));
    mac_tx.send(answer.to_line()).await.unwrap();
    assert_eq!(asked.await.unwrap().unwrap()["output"], "ok");
}

/// Review of #24797 at f2e68a4: an action already running went on for up to 60 s after the
/// Mac took lending back (the peer removed, `githubBroker` off, its link ended).
#[tokio::test]
async fn an_action_running_when_lending_ends_is_stopped() {
    fake_gh();
    let a = hub();
    let mut app = C::new(&a, None).await;
    let slow = json!({"action": "read", "repo": "o/slow"});
    let (port, _answer) = lane_asking(slow, "peer", Ask::AfterWatch).await;
    let add = json!({"name": "slow", "url": format!("ws://127.0.0.1:{port}"), "token": "tok",
        "githubBroker": true, "wait": true});
    app.call("_acpmux/peer_add", add).await.unwrap();
    tokio::time::sleep(Duration::from_secs(2)).await;
    assert!(gh_bin().join("slow-started").exists(), "gh started");
    app.call("_acpmux/peer_remove", json!({"name": "slow"})).await.unwrap();
    tokio::time::sleep(Duration::from_secs(5)).await;
    assert!(!gh_bin().join("slow-done").exists(), "gh is stopped when lending ends");
}
