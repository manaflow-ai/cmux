//! A session moves to a fresh machine with nothing lost (cmuxterm-hq#7415 row 25; plans/cloud
//! ARCHITECTURE-2026-11.md, P4/E4: "kill the machine mid-turn, start a fresh one from snapshot +
//! session, count lost prompts and turns; any loss fails"). The acpmux session is the source of
//! truth and the machine is disposable (I1).
//!
//! Two hubs as in `peer_warm_copy.rs`: B is the machine (its sessions on disk, WebSocket), A is
//! the person's Mac, linked to B through a relay the test cuts and points elsewhere. A turn runs
//! on B and a prompt waits behind it when B goes away with no shutdown; B2 starts from a copy of
//! B's disk taken before either was sent, and the relay now reaches B2 (the same address, a
//! fresh machine). A's copy of the chat goes back to B2 (`hub/peer_snapshot/restore.rs`,
//! `hub/journal_restore.rs`) and what B had accepted is delivered again under its own prompt
//! ids (`server/outbox.rs` `redeliver_open`): every prompt A sent runs exactly once, and B2's
//! journal holds every record A saw of B.

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
use std::path::Path;
use std::sync::atomic::{AtomicU16, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};
use tokio::sync::mpsc;
use tokio::task::JoinHandle;

fn config(store: StoreMode) -> Config {
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
    cfg.store.mode = store;
    cfg.permission_policy = PermissionPolicy::Ask;
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
            let line = tokio::time::timeout(Duration::from_secs(30), self.rx.recv())
                .await
                .expect("timeout")
                .expect("closed");
            let v: Value = serde_json::from_str(&line).unwrap();
            if v.get("id") == Some(&json!(id)) {
                assert!(v.get("error").is_none(), "{m}: {v}");
                return v["result"].clone();
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

/// The machine's address: a TCP relay to whichever port it points at now. `cut` ends every
/// connection at once (the machine is gone, with no shutdown).
struct Relay {
    port: u16,
    target: Arc<AtomicU16>,
    tasks: Arc<Mutex<Vec<JoinHandle<()>>>>,
}

impl Relay {
    async fn to(port: u16) -> Self {
        let l = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let relay_port = l.local_addr().unwrap().port();
        let target = Arc::new(AtomicU16::new(port));
        let tasks: Arc<Mutex<Vec<JoinHandle<()>>>> = Arc::default();
        let (kept, to) = (tasks.clone(), target.clone());
        tokio::spawn(async move {
            while let Ok((mut client, _)) = l.accept().await {
                let port = to.load(Ordering::SeqCst);
                let Ok(mut server) = tokio::net::TcpStream::connect(("127.0.0.1", port)).await
                else {
                    continue;
                };
                let pipe = tokio::spawn(async move {
                    let _ = tokio::io::copy_bidirectional(&mut client, &mut server).await;
                });
                kept.lock().unwrap().push(pipe);
            }
        });
        Self { port: relay_port, target, tasks }
    }

    /// The machine goes away: nothing reaches it from now on.
    fn cut(&self) {
        self.target.store(1, Ordering::SeqCst);
        for task in self.tasks.lock().unwrap().drain(..) {
            task.abort();
        }
    }

    fn point_at(&self, port: u16) {
        self.target.store(port, Ordering::SeqCst);
    }
}

fn copy_dir(from: &Path, to: &Path) {
    std::fs::create_dir_all(to).unwrap();
    for entry in std::fs::read_dir(from).unwrap() {
        let entry = entry.unwrap();
        let kind = entry.file_type().unwrap();
        let dest = to.join(entry.file_name());
        if kind.is_dir() {
            copy_dir(&entry.path(), &dest);
        } else if kind.is_file() {
            std::fs::copy(entry.path(), &dest).unwrap();
        }
    }
}

/// Serves `hub` as the machine on a new port, with the machine's peer credential.
async fn serve(hub: Arc<Hub>, auth: &Path) -> u16 {
    let l = bind_ws("127.0.0.1:0").await.unwrap();
    let port = l.local_addr().unwrap().port();
    let ws = WsAuth { local_app: None, peer: Some(Arc::new(PeerAuth::create(auth).unwrap())) };
    tokio::spawn(serve_ws_with(hub, l, "tok".into(), ws));
    port
}

fn prompt(text: &str, prompt_id: &str) -> Value {
    json!({"request": {"sessionId": "b/moved", "prompt": [{"type": "text", "text": text}],
                       "_meta": {"acpmux": {"promptId": prompt_id}}}})
}

/// Sends `text` from A through its outbox and waits until B took it.
async fn send(ca: &mut C, text: &str, prompt_id: &str) {
    let queued = ca.call(method::MUX_SEND_QUEUE, prompt(text, prompt_id)).await;
    let delivery = queued["deliveryId"].as_str().expect("a delivery id").to_owned();
    let deadline = Instant::now() + Duration::from_secs(30);
    loop {
        let status =
            ca.call(method::MUX_SEND_STATUS, json!({"deliveryId": delivery, "waitMs": 2000})).await;
        if status["status"] == "delivered" {
            return;
        }
        assert!(Instant::now() < deadline, "{prompt_id} was never delivered: {status}");
    }
}

/// A's copy of the chat, once `done` holds of its records.
async fn copy_until(ca: &mut C, what: &str, done: impl Fn(&[Value]) -> bool) -> Vec<Value> {
    let deadline = Instant::now() + Duration::from_secs(30);
    loop {
        let got =
            ca.call("_acpmux/peer_snapshot", json!({"sessionId": "b/moved", "limit": 1000})).await;
        let events = got["events"].as_array().cloned().unwrap_or_default();
        if done(&events) {
            return events;
        }
        assert!(Instant::now() < deadline, "A's copy never showed {what}: {got}");
        tokio::time::sleep(Duration::from_millis(100)).await;
    }
}

fn names_prompt(e: &Value, kind: &str, prompt_id: &str) -> bool {
    e["kind"] == kind && e["msg"]["promptId"] == prompt_id
}

fn says(e: &Value, text: &str) -> bool {
    e["kind"] == "agent_message_chunk" && e["msg"].to_string().contains(text)
}

/// Every record of `hub`'s journal of `id`, as the wire spells them.
fn journal(hub: &Hub, id: &str) -> Vec<Value> {
    let records = hub.events(id, 0, 10_000).unwrap();
    records.iter().map(|r| serde_json::to_value(r).unwrap()).collect()
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_session_moved_to_a_fresh_machine_from_an_older_disk_loses_no_prompt_and_no_turn() {
    let _ = HERMETIC;
    let home = tempfile::tempdir().unwrap();
    let (b_disk, auth) = (home.path().join("b-disk"), home.path().join("b-auth"));
    std::fs::create_dir_all(&b_disk).unwrap();
    let b_cfg = config(StoreMode::Local);
    let b = Hub::new(b_cfg.clone(), acpmux::store::open(&b_cfg.store, &b_disk).unwrap());
    b.resume_queues();
    let peer_token = {
        PeerAuth::create(&auth).unwrap();
        std::fs::read_to_string(acpmux::server::peer_auth::token_path(&auth)).unwrap()
    };
    let relay = Relay::to(serve(b.clone(), &auth).await).await;
    let mut cb = client(b.clone()).await;
    let new = json!({"cwd": std::env::temp_dir(), "mcpServers": [],
                     "_meta": {"acpmux": {"name": "moved"}}});
    let id = cb.call(method::SESSION_NEW, new).await["sessionId"].as_str().unwrap().to_owned();

    // A, the person's Mac, keeps its copies on disk and has the chat open.
    let a_dir = home.path().join("a");
    std::fs::create_dir_all(&a_dir).unwrap();
    let a_cfg = config(StoreMode::Local);
    let a = Hub::new(a_cfg.clone(), acpmux::store::open(&a_cfg.store, &a_dir).unwrap());
    let url = format!("ws://127.0.0.1:{}", relay.port);
    a.add_peer("b", &url, Some("tok".into()), Some(peer_token), true).await.unwrap();
    let mut ca = client(a.clone()).await;
    ca.call(method::MUX_ATTACH, json!({"session": "b/moved", "limit": 400})).await;

    // A first turn runs to its end; then the machine's disk is snapshotted.
    send(&mut ca, "first", "p0").await;
    copy_until(&mut ca, "the first reply", |e| e.iter().any(|e| says(e, "echo: first"))).await;
    b.flush();
    let snapshot = home.path().join("b-snapshot");
    copy_dir(&b_disk, &snapshot);

    // A turn runs, and a prompt waits behind it, when the machine goes away.
    send(&mut ca, "until-cancel", "p1").await;
    send(&mut ca, "second", "p2").await;
    let seen = copy_until(&mut ca, "the running turn and the waiting prompt", |e| {
        e.iter().any(|e| says(e, "running")) && e.iter().any(|e| names_prompt(e, "queued", "p2"))
    })
    .await;
    relay.cut();
    // Its agents end with it; nothing it writes from now on reaches anyone.
    b.shutdown_all().await;

    // A fresh machine starts from the older snapshot, at the same address.
    let b2 = Hub::new(b_cfg.clone(), acpmux::store::open(&b_cfg.store, &snapshot).unwrap());
    b2.resume_queues();
    relay.point_at(serve(b2.clone(), &auth).await);

    // The waiting prompt runs there, once.
    let deadline = Instant::now() + Duration::from_secs(60);
    let events = loop {
        let events = journal(&b2, &id);
        if events.iter().any(|e| says(e, "echo: second")) {
            break events;
        }
        assert!(Instant::now() < deadline, "p2 never ran on the fresh machine: {events:#?}");
        tokio::time::sleep(Duration::from_millis(200)).await;
    };
    // Every record A saw of B is in B2's journal, with its seq.
    for record in &seen {
        let seq = record["seq"].as_u64().unwrap();
        let held = events.iter().find(|e| e["seq"].as_u64() == Some(seq));
        assert!(
            held.is_some_and(|e| e["kind"] == record["kind"] && e["at"] == record["at"]),
            "B2 lost seq {seq} ({}) A saw: {held:?}",
            record["kind"]
        );
    }
    // Every prompt A sent ran exactly once: none lost, none run twice by the redelivery.
    for p in ["p0", "p1", "p2"] {
        let ran = events.iter().filter(|e| names_prompt(e, "user_message", p)).count();
        assert_eq!(ran, 1, "{p} ran {ran} times: {events:#?}");
    }
    // Let the redelivery settle, then count again: a late resend runs nothing more.
    tokio::time::sleep(Duration::from_secs(2)).await;
    let events = journal(&b2, &id);
    for p in ["p0", "p1", "p2"] {
        let ran = events.iter().filter(|e| names_prompt(e, "user_message", p)).count();
        assert_eq!(ran, 1, "{p} ran {ran} times after the redelivery: {events:#?}");
    }
    let replies = events.iter().filter(|e| says(e, "echo: second")).count();
    assert_eq!(replies, 1, "p2 answered {replies} times: {events:#?}");
}
