//! A prompt or a wait on a peer's session lasts as long as the peer's turn: the peer's
//! request deadline (`ACPMUX_PEER_REQUEST_SECS`, 600 s by default) never cuts it short, so
//! a turn longer than that no longer fails with `peer NAME timed out` while it still runs
//! (2026-10-21: cosmic-gray's sends to huge-blue lanes). The keepalive still drops a link
//! that stops answering. Two hubs: B serves WebSocket; A mirrors B as a peer.

#[path = "support/daemon_env.rs"]
mod daemon_env;
// This process runs stand-in agents (the fake agents under tests/).
const HERMETIC: daemon_env::Process = daemon_env::Process::stand_in();

use acpmux::config::{Config, HarnessProfile, PermissionPolicy, StoreMode};
use acpmux::hub::Hub;
use acpmux::rpc::{Message, method};
use acpmux::server::peer_auth::PeerAuth;
use acpmux::server::{WsAuth, bind_ws, serve_connection, serve_ws_with};
use serde_json::{Value, json};
use std::collections::BTreeMap;
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::mpsc;

fn config() -> Config {
    let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
    let mut agents = BTreeMap::new();
    agents.insert(
        "fake".to_owned(),
        HarnessProfile {
            kind: Default::default(),
            argv: vec!["python3".into(), fake.into()],
            env: BTreeMap::new(),
            description: None,
            fallback: None,
            family: None,
            models: vec![],
            model: None,
            effort: None,
            policy: None,
        },
    );
    let mut cfg =
        Config { harnesses: agents, default_harness: Some("fake".into()), ..Default::default() };
    cfg.store.mode = StoreMode::Memory;
    cfg.permission_policy = PermissionPolicy::ApproveAll;
    cfg
}

fn hub() -> Arc<Hub> {
    let cfg = config();
    let store = acpmux::store::open(&cfg.store, std::path::Path::new("/nonexistent")).unwrap();
    Hub::new(cfg, store)
}

struct C {
    tx: mpsc::Sender<String>,
    rx: mpsc::Receiver<String>,
    next: i64,
}

impl C {
    async fn call(&mut self, m: &str, p: Value) -> Result<Value, String> {
        self.next += 1;
        let id = self.next;
        self.tx.send(Message::request(id, m, p).to_line()).await.unwrap();
        loop {
            let line = tokio::time::timeout(Duration::from_secs(20), self.rx.recv())
                .await
                .expect("timeout")
                .expect("closed");
            if let Message::Response { id: rid, result, error } = Message::parse(&line).unwrap()
                && rid == id
            {
                return match error {
                    Some(e) => Err(e.message),
                    None => Ok(result.unwrap_or(Value::Null)),
                };
            }
        }
    }
}

const PERSON_KEY: &str = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";

async fn client(h: Arc<Hub>) -> C {
    let _ = h.person.install_spawn_key(PERSON_KEY);
    let (in_tx, in_rx) = mpsc::channel(64);
    let (out_tx, out_rx) = mpsc::channel(4096);
    tokio::spawn(serve_connection(h, in_rx, out_tx));
    let mut c = C { tx: in_tx, rx: out_rx, next: 0 };
    let hello = json!({"protocolVersion": 1, "clientInfo": {"name": "t"}});
    let init = c.call(method::INITIALIZE, hello).await.unwrap();
    let challenge = &init["_meta"]["acpmux"]["personChallenge"];
    let proof = acpmux::hub::person::person_proof(
        PERSON_KEY,
        acpmux::hub::person::TRANSPORT_UNIX,
        challenge["nonce"].as_str().unwrap(),
        challenge["connection"].as_str().unwrap(),
    )
    .unwrap();
    c.call("_acpmux/person_prove", json!({"proof": proof})).await.unwrap();
    c
}

async fn until_connected(a: &Hub) {
    let peer = a.peer_by_name("b").expect("peer b");
    let mut settled = peer.settled();
    let wait = async {
        while a.peers().into_iter().next().expect("one peer")["state"] != "connected" {
            settled.changed().await.expect("peer gone");
        }
    };
    tokio::time::timeout(Duration::from_secs(60), wait).await.expect("peer b never connected");
}

struct Pair {
    a: Arc<Hub>,
    home: std::path::PathBuf,
}

/// B serves a session `lane` over WebSocket; A mirrors B as peer `b`, connected.
async fn pair(tag: &str) -> Pair {
    // A 1 s request deadline and a 1 s ping, set before any peer exists.
    static ENV: std::sync::Once = std::sync::Once::new();
    // SAFETY: set once, before any peer of this binary reads them.
    ENV.call_once(|| unsafe {
        std::env::set_var("ACPMUX_PEER_REQUEST_SECS", "1");
        std::env::set_var("ACPMUX_PEER_PING_SECS", "1");
    });
    let _ = HERMETIC;
    let b = hub();
    let home = std::env::temp_dir().join(format!("aplt-{tag}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&home);
    let auth = PeerAuth::create(&home).unwrap();
    let peer_token = std::fs::read_to_string(acpmux::server::peer_auth::token_path(&home)).unwrap();
    let l = bind_ws("127.0.0.1:0").await.unwrap();
    let port = l.local_addr().unwrap().port();
    let ws_auth = WsAuth { local_app: None, peer: Some(Arc::new(auth)) };
    tokio::spawn(serve_ws_with(b.clone(), l, "tok".into(), ws_auth));
    let mut cb = client(b.clone()).await;
    cb.call(
        method::SESSION_NEW,
        json!({"cwd": std::env::temp_dir(), "mcpServers": [], "_meta": {"acpmux": {"name": "lane"}}}),
    )
    .await
    .unwrap();
    let a = hub();
    let url = format!("ws://127.0.0.1:{port}");
    a.add_peer("b", &url, Some("tok".into()), Some(peer_token), true).await.unwrap();
    until_connected(&a).await;
    Pair { a, home }
}

/// Waits (bounded) until A's link to `b` has `n` requests waiting for an answer.
async fn until_pending(a: &Hub, n: usize) -> usize {
    let peer = a.peer_by_name("b").expect("peer b");
    let deadline = tokio::time::Instant::now() + Duration::from_secs(10);
    loop {
        let now = peer.pending_requests().await;
        if now == n || tokio::time::Instant::now() >= deadline {
            return now;
        }
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
}

#[tokio::test]
async fn peer_long_turn_a_peer_turn_longer_than_the_request_deadline_still_answers() {
    let Pair { a, home } = pair("long").await;
    // The fake agent's "mute" turn says nothing for 2 s, then answers.
    let mut ca = client(a.clone()).await;
    let prompt = json!({"sessionId": "b/lane", "prompt": [{"type": "text", "text": "mute"}]});
    let answered = ca.call(method::SESSION_PROMPT, prompt).await;
    assert_eq!(
        answered.as_ref().map(|r| r["stopReason"].clone()),
        Ok(json!("end_turn")),
        "the peer's turn outlived the request deadline: {answered:?}"
    );
    let _ = std::fs::remove_dir_all(&home);
}

#[tokio::test]
async fn peer_long_turn_a_forwarded_prompt_stops_waiting_when_its_client_goes() {
    // The outbox gives an attempt up after 120 s and drops its connection; a CLI may exit.
    // The forwarded prompt must not wait on the peer's turn for nobody.
    let Pair { a, home } = pair("gone").await;
    let mut ca = client(a.clone()).await;
    let prompt =
        json!({"sessionId": "b/lane", "prompt": [{"type": "text", "text": "until-cancel"}]});
    ca.tx.send(Message::request(99, method::SESSION_PROMPT, prompt).to_line()).await.unwrap();
    // The turn streams "running" only once the prompt itself reached the peer's agent, so the
    // one request still waiting is the prompt, not the hidden attach sent ahead of it.
    let running = async {
        while let Some(line) = ca.rx.recv().await {
            if line.contains("running") {
                return;
            }
        }
        panic!("the client's connection ended before the turn started");
    };
    tokio::time::timeout(Duration::from_secs(20), running).await.expect("the turn never started");
    assert_eq!(until_pending(&a, 1).await, 1, "the prompt waits on the peer");
    drop(ca);
    assert_eq!(until_pending(&a, 0).await, 0, "the prompt still waits after its client went");
    let _ = std::fs::remove_dir_all(&home);
}

#[tokio::test]
async fn peer_long_turn_a_forwarded_prompt_stops_waiting_when_its_socket_client_exits() {
    // A CLI on the daemon's unix socket that exits mid-turn, while the turn says nothing: the
    // daemon's writer for it has nothing to write, so only its read side learns it closed.
    use tokio::io::{AsyncBufReadExt, AsyncWriteExt};
    let Pair { a, home } = pair("sock").await;
    let gate = home.join("gate");
    let made = std::process::Command::new("mkfifo").arg(&gate).status().unwrap();
    assert!(made.success(), "mkfifo");
    let path = home.join("a.sock");
    let listener = acpmux::server::bind_unix(&path).await.unwrap();
    tokio::spawn(acpmux::server::serve_unix(a.clone(), listener));
    let (rd, mut wr) = tokio::net::UnixStream::connect(&path).await.unwrap().into_split();
    let hello = json!({"protocolVersion": 1, "clientInfo": {"name": "t"}});
    let text = format!("gate: {}", gate.display());
    let prompt = json!({"sessionId": "b/lane", "prompt": [{"type": "text", "text": text}]});
    for line in [
        Message::request(1, method::INITIALIZE, hello).to_line(),
        Message::request(2, method::MUX_ATTACH, json!({"sessionId": "b/lane"})).to_line(),
        Message::request(3, method::SESSION_PROMPT, prompt).to_line(),
    ] {
        wr.write_all(line.as_bytes()).await.unwrap();
    }
    // The turn is at its gate and silent from here on.
    let mut lines = tokio::io::BufReader::new(rd).lines();
    let at_gate = async {
        while let Some(line) = lines.next_line().await.unwrap() {
            if line.contains("before-gate") {
                return;
            }
        }
        panic!("the CLI's connection ended before the turn reached its gate");
    };
    tokio::time::timeout(Duration::from_secs(20), at_gate).await.expect("never at the gate");
    assert_eq!(until_pending(&a, 1).await, 1, "the prompt waits on the peer");
    drop((lines, wr));
    let left = until_pending(&a, 0).await;
    // Open the gate so the fake agent ends its turn.
    let _ = std::fs::write(&gate, b"go");
    assert_eq!(left, 0, "the prompt still waits after the CLI exited");
    let _ = std::fs::remove_dir_all(&home);
}
