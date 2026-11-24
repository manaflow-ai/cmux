//! A chat cmux-next started on another machine follows the answer of the Mac that started it to
//! "should agents you start in cmux get cmux's tools?" (`hub/cmux_tools_answer.rs`): the peer
//! daemon runs the chat's harness with that answer as `CMUX_AGENT_TOOLS_ANSWER`, which a
//! `cmux mcp serve` the chat starts uses over the peer's own settings file. Only a peer daemon's
//! own connection brings an answer; a Web client's field is ignored (a paired device's too: the
//! `cmux_tools_answer` unit tests), and a chat started on the machine itself has none (its own
//! file applies).

use acpmux::config::{Config, StoreMode};
use acpmux::hub::Hub;
use acpmux::rpc::Message;
use acpmux::server::peer_auth::PeerAuth;
use acpmux::server::{ConnAuth, Origin, WsAuth, bind_ws, serve_connection_authed, serve_ws_with};
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
        "harnesses": {
            "fakeacp": {"argv": ["python3", FAKE_AGENT], "family": "sample", "env": {"FAKE_ASK_MODE": "1"}},
            "other": {"argv": ["python3", FAKE_AGENT], "family": "other", "env": {"FAKE_ASK_MODE": "1"}}
        },
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
        self.answer_of(&s).await
    }

    /// `CMUX_AGENT_TOOLS_ANSWER` as session `s`'s harness sees it.
    async fn answer_of(&mut self, s: &str) -> String {
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
        // The `envs:` reply is the last JSON object streamed (a dispatched brief's reply comes first).
        let json = text.rfind('{').map(|at| &text[at..]).unwrap_or(&text);
        let env: Value = serde_json::from_str(json).unwrap_or_else(|_| panic!("{text}"));
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
        // Not a peer daemon (a phone, a Web client): whatever it sends, its chat gets none of
        // cmux's servers, so it runs with `off`.
        ("web", Origin::Web, ConnAuth::ListenerToken, Some("on"), "off"),
        // A peer daemon that sent none (an older Mac): a remote-origin chat with no answer, `off`.
        ("peer-none", Origin::Peer, ConnAuth::PeerToken, None, "off"),
        // A chat started on this machine: no answer in its env (its own file applies).
        ("local", Origin::Local, ConnAuth::LocalSocket, Some("on"), ""),
    ] {
        let d = dir(tag);
        let hub = hub(&d);
        let mut client = Client::new(&hub, origin, auth);
        let got = client.answer_seen(&d, sent).await;
        let _ = std::fs::remove_dir_all(&d);
        assert_eq!(got, seen, "{tag}");
    }
}

/// A `session/new` or a brief (`_acpmux/dispatch`) this daemon forwards to a peer over a real
/// peer link carries this daemon's own answer (here: no settings file, so `on`), over the `off`
/// its caller sent: the chat on the peer runs with `on`.
#[test]
fn a_start_forwarded_to_a_peer_carries_this_macs_answer_not_the_callers() {
    big_stack(async {
        let d = dir("forward");
        let b = hub(&d);
        let home = d.join("peer-home");
        let auth = PeerAuth::create(&home).unwrap();
        let token = std::fs::read_to_string(acpmux::server::peer_auth::token_path(&home)).unwrap();
        let l = bind_ws("127.0.0.1:0").await.unwrap();
        let port = l.local_addr().unwrap().port();
        let ws = WsAuth { local_app: None, peer: Some(Arc::new(auth)) };
        tokio::spawn(serve_ws_with(b.clone(), l, "tok".into(), ws));
        let a = hub(&d);
        a.add_peer("b", &format!("ws://127.0.0.1:{port}"), Some("tok".into()), Some(token), true)
            .await
            .unwrap();
        let mut app = Client::new(&a, Origin::LocalApp, ConnAuth::LocalApp);
        let p = json!({"cwd": d.join("work"), "mcpServers": [],
                       "_meta": {"acpmux": {"peer": "b", "cmuxTools": "off"}}});
        let r = app.call("session/new", p).await;
        let s = r["result"]["sessionId"].as_str().unwrap_or_else(|| panic!("{r}")).to_owned();
        let mut on_b = Client::new(&b, Origin::Local, ConnAuth::LocalSocket);
        let seen = on_b.answer_of(&s).await;
        // A brief dispatched to B (as a workflow's `on: b` activity does): the same.
        let sent = app
            .call(
                "_acpmux/dispatch",
                json!({"brief": "say hi", "host": "b", "cwd": d.join("work"),
                       "_meta": {"acpmux": {"cmuxTools": "off"}}}),
            )
            .await;
        let dispatched = sent["result"]["brief"]["sessionId"]
            .as_str()
            .unwrap_or_else(|| panic!("{sent}"))
            .to_owned();
        let seen_dispatched = on_b.answer_of(&dispatched).await;
        let _ = std::fs::remove_dir_all(&d);
        assert_eq!(seen, "on", "session/new");
        assert_eq!(seen_dispatched, "on", "dispatch");
    });
}

/// A `/btw` side chat and a handoff target of a chat another Mac started keep that Mac's answer,
/// as a fork and a sub-session do: their harnesses run with it.
#[test]
fn a_side_chat_and_a_handoff_target_keep_the_starting_macs_answer() {
    big_stack(async {
        let d = dir("btw-handoff");
        let hub = hub(&d);
        let mut peer = Client::new(&hub, Origin::Peer, ConnAuth::PeerToken);
        let p = json!({"cwd": d.join("work"), "mcpServers": [],
                       "_meta": {"acpmux": {"cmuxTools": "on", "harness": "fakeacp"}}});
        let r = peer.call("session/new", p).await;
        let chat = r["result"]["sessionId"].as_str().unwrap_or_else(|| panic!("{r}")).to_owned();
        assert_eq!(peer.answer_of(&chat).await, "on");
        let answer_in = |id: &str| {
            hub.resolve(id)
                .unwrap()
                .meta()
                .session_env
                .get("CMUX_AGENT_TOOLS_ANSWER")
                .cloned()
                .unwrap_or_default()
        };
        let mut local = Client::new(&hub, Origin::Local, ConnAuth::LocalSocket);
        let side = local.call("_acpmux/btw", json!({"sessionId": chat, "question": "why?"})).await;
        let side =
            side["result"]["sessionId"].as_str().unwrap_or_else(|| panic!("{side}")).to_owned();
        let handoff = local
            .call(
                "_acpmux/handoff_prepare",
                json!({"sessionId": chat, "harness": "other", "handoffKey": "k1"}),
            )
            .await;
        let target = handoff["result"]["target"]["sessionId"]
            .as_str()
            .unwrap_or_else(|| panic!("{handoff}"))
            .to_owned();
        let (side_answer, target_answer) = (answer_in(&side), answer_in(&target));
        let _ = std::fs::remove_dir_all(&d);
        assert_eq!(side_answer, "on", "/btw side chat");
        assert_eq!(target_answer, "on", "handoff target");
    });
}

/// The session/new handler's future is deeper than a debug build's 2 MiB worker stack, as in
/// `tests/created_by.rs`.
fn big_stack(f: impl std::future::Future<Output = ()>) {
    tokio::runtime::Builder::new_multi_thread()
        .worker_threads(2)
        .thread_stack_size(32 << 20)
        .enable_all()
        .build()
        .unwrap()
        .block_on(f);
}
