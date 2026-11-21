//! Bytes on the wire per Cloud chat action (CMUX-674, Leo: "similar to remote stuff"): a Mac's
//! hub (A) mirrors a Cloud machine's hub (B) as a peer through a TCP relay that counts each
//! direction. For chats of 0 to 10000 messages it measures opening the chat, an idle open chat
//! and a reconnect with a few new messages, so a cost that grows with history shows up as a
//! number. It prints one `CLOUD-BYTES {json}` line per action and history size, then checks
//! that idle and reconnect stay flat; opening is bounded by its page (1 MiB) and only printed.

#[path = "support/daemon_env.rs"]
mod daemon_env;
// This process runs stand-in agents (the fake agents under tests/).
const HERMETIC: daemon_env::Process = daemon_env::Process::stand_in();

use acpmux::config::{Config, HarnessProfile, PermissionPolicy, StoreMode};
use acpmux::hub::Hub;
use acpmux::rpc::{Message, method};
use acpmux::server::peer_auth::PeerAuth;
use acpmux::server::{WsAuth, bind_ws, serve_connection, serve_ws_with};
use acpmux::store::EventRecord;
use serde_json::{Value, json};
use std::collections::BTreeMap;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::time::{Duration, Instant};
use tokio::sync::{mpsc, watch};

/// The idle window: a few of the link's 2 s pings (`peer_link.rs` `ping_every`).
const IDLE: Duration = Duration::from_secs(10);
/// New messages B gets while the link is down.
const K: usize = 5;
/// Bytes of one seeded message's text.
const TEXT: usize = 200;

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

fn hub(cfg: Config) -> Arc<Hub> {
    let store = acpmux::store::open(&cfg.store, std::path::Path::new("/nonexistent")).unwrap();
    Hub::new(cfg, store)
}

struct C {
    tx: mpsc::Sender<String>,
    rx: mpsc::Receiver<String>,
    next: i64,
}

impl C {
    async fn call(&mut self, m: &str, p: Value) -> Value {
        self.next += 1;
        let id = self.next;
        self.tx.send(Message::request(id, m, p).to_line()).await.unwrap();
        loop {
            let line = tokio::time::timeout(Duration::from_secs(60), self.rx.recv())
                .await
                .expect("timeout")
                .expect("closed");
            if let Message::Response { id: rid, result, error } = Message::parse(&line).unwrap()
                && rid == id
            {
                match error {
                    Some(e) => panic!("{m}: {}", e.message),
                    None => return result.unwrap_or(Value::Null),
                }
            }
        }
    }

    /// Waits up to `within` for an `_acpmux/event` at or past `seq`.
    async fn event_through(&mut self, seq: u64, within: Duration) {
        let deadline = tokio::time::Instant::now() + within;
        loop {
            let line = tokio::time::timeout_at(deadline, self.rx.recv())
                .await
                .unwrap_or_else(|_| panic!("no event through seq {seq} within {within:?}"))
                .expect("closed");
            if let Message::Notification { method: m, params: Some(p) } =
                Message::parse(&line).unwrap()
                && m == method::MUX_EVENT
                && p["seq"].as_u64().is_some_and(|s| s >= seq)
            {
                return;
            }
        }
    }
}

/// The person key these hubs hold (`hub/person.rs`).
const PERSON_KEY: &str = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";

async fn client(h: Arc<Hub>) -> C {
    let _ = h.person.install_spawn_key(PERSON_KEY);
    let (in_tx, in_rx) = mpsc::channel(64);
    let (out_tx, out_rx) = mpsc::channel(16384);
    tokio::spawn(serve_connection(h, in_rx, out_tx));
    let mut c = C { tx: in_tx, rx: out_rx, next: 0 };
    let hello = json!({"protocolVersion": 1, "clientInfo": {"name": "t"}});
    let init = c.call(method::INITIALIZE, hello).await;
    let challenge = &init["_meta"]["acpmux"]["personChallenge"];
    let proof = acpmux::hub::person::person_proof(
        PERSON_KEY,
        acpmux::hub::person::TRANSPORT_UNIX,
        challenge["nonce"].as_str().unwrap(),
        challenge["connection"].as_str().unwrap(),
    )
    .unwrap();
    c.call("_acpmux/person_prove", json!({"proof": proof})).await;
    c
}

/// B's WebSocket listener with a peer token; returns its port and the token.
async fn listen_with_peer_token(b: Arc<Hub>, tag: &str) -> (u16, String) {
    let home = std::env::temp_dir().join(format!("cloud-bytes-{tag}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&home);
    let auth = PeerAuth::create(&home).unwrap();
    let token = std::fs::read_to_string(acpmux::server::peer_auth::token_path(&home)).unwrap();
    let l = bind_ws("127.0.0.1:0").await.unwrap();
    let port = l.local_addr().unwrap().port();
    let auth = WsAuth { local_app: None, peer: Some(Arc::new(auth)) };
    tokio::spawn(serve_ws_with(b, l, "tok".into(), auth));
    (port, token)
}

/// A TCP relay in front of B that counts bytes each way, can cut every live connection (a
/// dropped network) and, while `held`, closes new ones at once (the network is still down).
struct Relay {
    port: u16,
    up: Arc<AtomicU64>,
    down: Arc<AtomicU64>,
    cut: watch::Sender<u64>,
    held: Arc<AtomicBool>,
}

impl Relay {
    async fn new(to: u16) -> Self {
        let l = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let port = l.local_addr().unwrap().port();
        let (up, down) = (Arc::new(AtomicU64::new(0)), Arc::new(AtomicU64::new(0)));
        let (cut, cut_rx) = watch::channel(0u64);
        let held = Arc::new(AtomicBool::new(false));
        let (u, d, h) = (up.clone(), down.clone(), held.clone());
        tokio::spawn(async move {
            while let Ok((client, _)) = l.accept().await {
                if h.load(Ordering::SeqCst) {
                    continue;
                }
                let Ok(server) = tokio::net::TcpStream::connect(("127.0.0.1", to)).await else {
                    continue;
                };
                let (mut cr, mut cw) = client.into_split();
                let (mut sr, mut sw) = server.into_split();
                let (u, d) = (u.clone(), d.clone());
                let mut gone = cut_rx.clone();
                let _ = gone.borrow_and_update();
                tokio::spawn(async move {
                    tokio::select! {
                        _ = pump(&mut cr, &mut sw, &u) => {}
                        _ = pump(&mut sr, &mut cw, &d) => {}
                        _ = gone.changed() => {}
                    }
                });
            }
        });
        Self { port, up, down, cut, held }
    }

    fn bytes(&self) -> (u64, u64) {
        (self.up.load(Ordering::SeqCst), self.down.load(Ordering::SeqCst))
    }

    fn since(&self, (u, d): (u64, u64)) -> (u64, u64) {
        let (nu, nd) = self.bytes();
        (nu - u, nd - d)
    }
}

async fn pump(
    r: &mut tokio::net::tcp::OwnedReadHalf,
    w: &mut tokio::net::tcp::OwnedWriteHalf,
    n: &AtomicU64,
) {
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    let mut buf = vec![0u8; 64 * 1024];
    while let Ok(got) = r.read(&mut buf).await {
        if got == 0 || w.write_all(&buf[..got]).await.is_err() {
            return;
        }
        n.fetch_add(got as u64, Ordering::SeqCst);
    }
}

/// Waits up to 60 s for `cond`; a test helper over hub state with no change signal.
async fn until(what: &str, cond: impl Fn() -> bool) {
    let deadline = Instant::now() + Duration::from_secs(60);
    while !cond() {
        assert!(Instant::now() < deadline, "timed out waiting for {what}");
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
}

fn connected(a: &Hub) -> bool {
    a.peers().first().is_some_and(|p| p["connected"] == true)
}

/// B with one chat named `chat` of `n` messages, alternately the person's and the agent's, each
/// about [`TEXT`] bytes, written straight into its store as `peer_integration.rs` seeds a long
/// chat: the chat is made by a hub (a real meta and agent), then its log is appended to.
async fn seeded(n: usize, tag: &str) -> (Arc<Hub>, String, std::path::PathBuf) {
    let dir = std::env::temp_dir().join(format!("cloud-bytes-{tag}-{}", uuid::Uuid::now_v7()));
    let mut cfg = config();
    cfg.store.mode = StoreMode::Local;
    cfg.store.segment_bytes = 8 * 1024 * 1024;
    let b = Hub::new(cfg.clone(), acpmux::store::open(&cfg.store, &dir).unwrap());
    let mut cb = client(b.clone()).await;
    let s = cb.call(method::SESSION_NEW, json!({"cwd": std::env::temp_dir(), "mcpServers": [], "_meta": {"acpmux": {"name": "chat"}}})).await;
    let id = s["sessionId"].as_str().unwrap().to_owned();
    let mut seq = b.resolve("chat").unwrap().meta().last_seq;
    b.shutdown_all().await;
    drop(cb);
    drop(b);
    let store = acpmux::store::open(&cfg.store, &dir).unwrap();
    for i in 0..n {
        seq += 1;
        let text =
            format!("message {i}: {}", "the checks on the merged head are green. ".repeat(5));
        let text = &text[..TEXT];
        let (way, kind, msg) = if i % 2 == 0 {
            ("mux", "user_message", json!({"text": text}))
        } else {
            let update = json!({"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": text}});
            let msg = json!({"jsonrpc": "2.0", "method": "session/update", "params": {"sessionId": "agent-1", "update": update}});
            ("in", "agent_message_chunk", msg)
        };
        let rec =
            EventRecord { seq, at: seq, dir: way.into(), kind: kind.into(), msg, host_seq: None };
        store.append(&id, &rec).unwrap();
    }
    let b = Hub::new(cfg, store);
    let _ = b.person.install_spawn_key(PERSON_KEY);
    (b, id, dir)
}

/// What one action cost on the link.
struct Row {
    case: &'static str,
    history: usize,
    up: u64,
    down: u64,
    ms: u128,
    window_s: Option<u64>,
}

impl Row {
    fn total(&self) -> u64 {
        self.up + self.down
    }

    fn print(&self) {
        let mut v = json!({"case": self.case, "history": self.history, "up": self.up,
                           "down": self.down, "ms": self.ms});
        if let Some(s) = self.window_s {
            v["window_s"] = json!(s);
            v["bytes_per_s"] = json!(self.total() / s.max(1));
        }
        println!("CLOUD-BYTES {v}");
    }
}

/// The open page as the app's agent pane asks it (`agent_session_attach.rs` `page_params`:
/// 200 records, a live stream, no wait for the log) with acpmux's default byte bound.
fn open(after: Option<u64>) -> Value {
    let mut p = json!({"session": "b/chat", "limit": 200, "eventStream": true, "waitLogs": false});
    if let Some(after) = after {
        p["afterSeq"] = json!(after);
    }
    p
}

/// Every action for a chat of `n` messages.
async fn measure(n: usize) -> Vec<Row> {
    let tag = format!("h{n}");
    let (b, id, dir) = seeded(n, &tag).await;
    let (port, peer_token) = listen_with_peer_token(b.clone(), &tag).await;
    let relay = Relay::new(port).await;
    let url = format!("ws://127.0.0.1:{}", relay.port);
    let mut rows = Vec::new();

    // Start: linking the machine, then opening the chat with its newest page.
    let at = relay.bytes();
    let t = Instant::now();
    let a = hub(config());
    a.add_peer("b", &url, Some("tok".into()), Some(peer_token.clone()), true).await.unwrap();
    let mut ca = client(a.clone()).await;
    let page = ca.call(method::MUX_ATTACH, open(None)).await;
    let (up, down) = relay.since(at);
    rows.push(Row {
        case: "chat_start",
        history: n,
        up,
        down,
        ms: t.elapsed().as_millis(),
        window_s: None,
    });
    let seen = page["events"].as_array().unwrap().last().map_or(0, |e| e["seq"].as_u64().unwrap());

    // Idle: the chat open, nothing happening.
    tokio::time::sleep(Duration::from_millis(500)).await;
    let at = relay.bytes();
    let t = Instant::now();
    tokio::time::sleep(IDLE).await;
    let (up, down) = relay.since(at);
    rows.push(Row {
        case: "chat_idle",
        history: n,
        up,
        down,
        ms: t.elapsed().as_millis(),
        window_s: Some(IDLE.as_secs()),
    });

    // Reconnect: the network drops, B's chat gets K new messages, the network comes back and
    // A's peer catches the open chat up from its cursor.
    relay.held.store(true, Ordering::SeqCst);
    relay.cut.send_modify(|n| *n += 1);
    until("the link to drop", || !connected(&a)).await;
    let mut cb = client(b.clone()).await;
    for i in 0..K {
        let prompt = json!({"sessionId": id, "prompt": [{"type": "text", "text": format!("while down {i}")}]});
        cb.call(method::SESSION_PROMPT, prompt).await;
    }
    let last = b.resolve(&id).unwrap().meta().last_seq;
    let at = relay.bytes();
    let t = Instant::now();
    relay.held.store(false, Ordering::SeqCst);
    ca.event_through(last, Duration::from_secs(60)).await;
    until("the link to come back", || connected(&a)).await;
    let ms = t.elapsed().as_millis();
    // What follows the catch-up (lists, settled marks) belongs to the reconnect too.
    tokio::time::sleep(Duration::from_millis(500)).await;
    let (up, down) = relay.since(at);
    rows.push(Row { case: "chat_reconnect", history: n, up, down, ms, window_s: None });

    // Cursorless: a fresh A (a restarted Mac) whose peer holds no cursor for the chat; its pane
    // resumes after the last record it drew, as `afterSeq`.
    let _ = a.remove_peer("b").await;
    drop(ca);
    let at = relay.bytes();
    let t = Instant::now();
    let a2 = hub(config());
    a2.add_peer("b", &url, Some("tok".into()), Some(peer_token), true).await.unwrap();
    let mut ca2 = client(a2.clone()).await;
    ca2.call(method::MUX_ATTACH, open(Some(seen))).await;
    let (up, down) = relay.since(at);
    rows.push(Row {
        case: "chat_reconnect_cursorless",
        history: n,
        up,
        down,
        ms: t.elapsed().as_millis(),
        window_s: None,
    });

    let _ = a2.remove_peer("b").await;
    b.shutdown_all().await;
    let _ = std::fs::remove_dir_all(dir);
    rows
}

/// Prints every row, then checks idle and reconnect cost at the largest history against the
/// empty chat: flat, with room for timing noise (a ping more or less).
async fn sweep(sizes: &[usize]) {
    let mut rows = Vec::new();
    for &n in sizes {
        let got = measure(n).await;
        for r in &got {
            r.print();
        }
        rows.extend(got);
    }
    let cost = |case: &str, n: usize| {
        rows.iter().find(|r| r.case == case && r.history == n).map(Row::total).unwrap()
    };
    let (small, large) = (sizes[0], *sizes.last().unwrap());
    for case in ["chat_idle", "chat_reconnect"] {
        let (base, big) = (cost(case, small), cost(case, large));
        assert!(
            big as f64 <= base as f64 * 1.5 + 512.0,
            "{case} grows with history: {base} bytes at {small} messages, {big} at {large}"
        );
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn idle_and_reconnect_bytes_stay_flat_with_chat_history() {
    sweep(&[0, 1000]).await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[ignore = "a bench: cargo test -p acpmux --test cloud_chat_bytes -- --ignored --nocapture"]
async fn cloud_chat_bytes_sweep() {
    sweep(&[0, 100, 1000, 10000]).await;
}
