//! A daemon that mirrors a peer keeps its memory flat however long the peer's
//! chats run. Every record the hub hears goes into its event ring (8192 slots,
//! `hub/mod.rs`), and a ring slot keeps its value until it is overwritten, so
//! whatever one record carries is held 8192 times over. A peer's records once
//! each carried a copy of their session's summary (13 KB of JSON at the median
//! on cosmic-gray, its tools, queue and tags): huge-blue, mirroring cosmic-gray's
//! busy lanes, grew past its 8 GiB `memory.high` and stalled (2026-10-21).
//!
//! Live heap bytes are counted by this binary's allocator; it holds one test so
//! nothing else allocates beside it.

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
use std::alloc::{GlobalAlloc, Layout, System};
use std::collections::BTreeMap;
use std::sync::Arc;
use std::sync::atomic::{AtomicIsize, Ordering};
use std::time::Duration;
use tokio::sync::mpsc;

struct Counting;

static LIVE: AtomicIsize = AtomicIsize::new(0);

// SAFETY: forwards to the system allocator and only counts bytes.
unsafe impl GlobalAlloc for Counting {
    unsafe fn alloc(&self, layout: Layout) -> *mut u8 {
        LIVE.fetch_add(layout.size() as isize, Ordering::Relaxed);
        unsafe { System.alloc(layout) }
    }
    unsafe fn dealloc(&self, ptr: *mut u8, layout: Layout) {
        LIVE.fetch_sub(layout.size() as isize, Ordering::Relaxed);
        unsafe { System.dealloc(ptr, layout) }
    }
    unsafe fn realloc(&self, ptr: *mut u8, layout: Layout, new_size: usize) -> *mut u8 {
        LIVE.fetch_add(new_size as isize - layout.size() as isize, Ordering::Relaxed);
        unsafe { System.realloc(ptr, layout, new_size) }
    }
}

#[global_allocator]
static ALLOC: Counting = Counting;

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
            let line = tokio::time::timeout(Duration::from_secs(20), self.rx.recv())
                .await
                .expect("timeout")
                .expect("closed");
            if let Message::Response { id: rid, result, error } = Message::parse(&line).unwrap()
                && rid == id
            {
                assert!(error.is_none(), "{m}: {error:?}");
                return result.unwrap_or(Value::Null);
            }
        }
    }
}

/// The person key these hubs hold (`hub/person.rs`).
const PERSON_KEY: &str = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";

async fn client(h: Arc<Hub>) -> C {
    let _ = h.person.install_spawn_key(PERSON_KEY);
    let (in_tx, in_rx) = mpsc::channel(64);
    // Drained by `call`, which reads past notifications to its answer.
    let (out_tx, out_rx) = mpsc::channel(4096);
    tokio::spawn(serve_connection(h, in_rx, out_tx));
    let mut c = C { tx: in_tx, rx: out_rx, next: 0 };
    let init = c
        .call(method::INITIALIZE, json!({"protocolVersion": 1, "clientInfo": {"name": "t"}}))
        .await;
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

/// Turns of a peer's chat, each streamed to this daemon's watcher.
async fn turns(c: &mut C, n: usize) {
    for i in 0..n {
        let prompt = json!({"sessionId": "b/busy", "prompt": [{"type": "text", "text": format!("turn {i}")}]});
        let r = c.call(method::SESSION_PROMPT, prompt).await;
        assert_eq!(r["stopReason"], "end_turn", "{r}");
    }
}

/// Retained per turn: the ring's 8192 slots, held full, cost 8192 records of
/// this many bytes' worth. 4 KiB per turn keeps a full ring near 30 MiB.
const KEPT_PER_TURN: isize = 4 * 1024;

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn mirroring_a_peers_busy_chat_keeps_no_copy_of_its_summary_per_event() {
    let dir = std::env::temp_dir().join(format!("acpmux-peer-memory-{}", uuid::Uuid::now_v7()));
    // B owns the chat and keeps its log on disk, so its history is not on the heap.
    let mut b_cfg = config();
    b_cfg.store.mode = StoreMode::Local;
    let b = Hub::new(b_cfg.clone(), acpmux::store::open(&b_cfg.store, &dir).unwrap());
    let home = dir.join("peer-auth");
    std::fs::create_dir_all(&home).unwrap();
    let auth = PeerAuth::create(&home).unwrap();
    let token = std::fs::read_to_string(acpmux::server::peer_auth::token_path(&home)).unwrap();
    let listener = bind_ws("127.0.0.1:0").await.unwrap();
    let port = listener.local_addr().unwrap().port();
    let auth = WsAuth { local_app: None, peer: Some(Arc::new(auth)) };
    tokio::spawn(serve_ws_with(b.clone(), listener, "tok".into(), auth));
    let mut cb = client(b.clone()).await;
    let s = cb
        .call(
            method::SESSION_NEW,
            json!({"cwd": std::env::temp_dir(), "mcpServers": [], "_meta": {"acpmux": {"name": "busy"}}}),
        )
        .await;
    let id = s["sessionId"].as_str().unwrap().to_owned();
    // A summary the size of a busy lane's (its tools, queue and tags): 16 KB of tags.
    let tags: serde_json::Map<String, Value> =
        (0..64).map(|i| (format!("note-{i}"), Value::String("x".repeat(240)))).collect();
    let summary = cb.call(method::MUX_TAG, json!({"sessionId": id, "set": tags})).await;
    assert!(summary.to_string().len() > 16_000, "summary is {} bytes", summary.to_string().len());
    // B's own client is attached to the chat; nothing reads it from here on.
    drop(cb);

    // A mirrors B, and a watcher on A follows the chat.
    let a = Hub::new(config(), acpmux::store::open(&config().store, &dir.join("a")).unwrap());
    a.add_peer("b", &format!("ws://127.0.0.1:{port}"), Some("tok".into()), Some(token), true)
        .await
        .unwrap();
    let mut ca = client(a.clone()).await;
    ca.call(method::MUX_WATCH, json!({})).await;
    ca.call(method::MUX_ATTACH, json!({"session": "b/busy", "limit": 0})).await;

    // Warm: the agent, the link and both rings' first pages are allocated.
    turns(&mut ca, 20).await;
    let before = LIVE.load(Ordering::Relaxed);
    let n = 150;
    turns(&mut ca, n).await;
    let kept = LIVE.load(Ordering::Relaxed) - before;

    assert!(
        kept < KEPT_PER_TURN * n as isize,
        "{n} turns of a peer's chat kept {} KiB ({} B a turn)",
        kept >> 10,
        kept / n as isize,
    );
    b.shutdown_all().await;
    let _ = std::fs::remove_dir_all(&dir);
}
