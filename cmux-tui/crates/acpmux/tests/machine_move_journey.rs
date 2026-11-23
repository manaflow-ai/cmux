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
//! ids (`server/outbox.rs` `redeliver_open`): every prompt A sent runs exactly once, B2's
//! journal holds every record A saw of B, and the agent, which resumed its own older session,
//! is told the turns it missed (`hub/transcript.rs` `missed_turns`).
//!
//! Debug builds only: its faults are the library's debug seams (`journal_restore.rs`,
//! `hub::peer_snapshot_reads_fail`), which a release build of the library does not have.
#![cfg(debug_assertions)]

#[path = "support/daemon_env.rs"]
mod daemon_env;
// This process runs stand-in agents (the fake agents under tests/).
const HERMETIC: daemon_env::Process = daemon_env::Process::stand_in();

use acpmux::config::{Config, HarnessProfile, PermissionPolicy, StoreMode};
use acpmux::hub::Hub;
use acpmux::rpc::{Message, method};
use acpmux::server::peer_auth::PeerAuth;
use acpmux::server::{Origin, WsAuth, bind_ws, serve_connection, serve_ws_with};
use serde_json::{Value, json};
use std::collections::BTreeMap;
use std::path::Path;
use std::sync::atomic::{AtomicBool, AtomicU16, AtomicUsize, Ordering};
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
    // A chat the peer link drives must ask, in a mode the asking table lists (`remote_guard.rs`).
    cfg.permission_policy = PermissionPolicy::Ask;
    cfg.web_asking_modes.insert("fake".into(), vec!["normal".into()]);
    cfg
}

struct C {
    tx: mpsc::Sender<String>,
    rx: mpsc::Receiver<String>,
    next: i64,
}

impl C {
    async fn call(&mut self, m: &str, p: Value) -> Value {
        let v = self.raw(m, p).await;
        assert!(v.get("error").is_none(), "{m}: {v}");
        v["result"].clone()
    }

    /// The whole answer to `m`: its result or its error.
    async fn raw(&mut self, m: &str, p: Value) -> Value {
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
                return v;
            }
        }
    }
}

/// A connection of this machine's unix socket that proves no person: a chat it starts runs in
/// the machine's policy (approve-all here), which a peer's prompt may drive, as `send_async.rs`'s.
async fn plain_client(h: Arc<Hub>) -> C {
    let (in_tx, in_rx) = mpsc::channel(64);
    let (out_tx, out_rx) = mpsc::channel(4096);
    tokio::spawn(serve_connection(h, in_rx, out_tx));
    let mut c = C { tx: in_tx, rx: out_rx, next: 0 };
    c.call(method::INITIALIZE, json!({"protocolVersion": 1, "clientInfo": {"name": "t"}})).await;
    c
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
/// connection at once (the machine is gone, with no shutdown); `cut_after` cuts the next
/// connection once that many bytes went from the Mac to the machine (a requester killed midway).
struct Relay {
    port: u16,
    target: Arc<AtomicU16>,
    tasks: Arc<Mutex<Vec<JoinHandle<()>>>>,
    trip_at: Arc<AtomicUsize>,
    tripped: Arc<AtomicBool>,
}

impl Relay {
    async fn to(port: u16) -> Self {
        let l = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let relay_port = l.local_addr().unwrap().port();
        let target = Arc::new(AtomicU16::new(port));
        let tasks: Arc<Mutex<Vec<JoinHandle<()>>>> = Arc::default();
        let (trip_at, tripped) = (Arc::new(AtomicUsize::new(0)), Arc::new(AtomicBool::new(false)));
        let (kept, to) = (tasks.clone(), target.clone());
        let (trip, cut) = (trip_at.clone(), tripped.clone());
        tokio::spawn(async move {
            while let Ok((mut client, _)) = l.accept().await {
                let port = to.load(Ordering::SeqCst);
                let Ok(mut server) = tokio::net::TcpStream::connect(("127.0.0.1", port)).await
                else {
                    continue;
                };
                let at = trip.swap(0, Ordering::SeqCst);
                let pipe = if at == 0 {
                    tokio::spawn(async move {
                        let _ = tokio::io::copy_bidirectional(&mut client, &mut server).await;
                    })
                } else {
                    let (to, cut) = (to.clone(), cut.clone());
                    tokio::spawn(async move {
                        use tokio::io::{AsyncReadExt, AsyncWriteExt};
                        let (mut from_mac, mut to_mac) = client.into_split();
                        let (mut from_machine, mut to_machine) = server.into_split();
                        let down = tokio::spawn(async move {
                            let _ = tokio::io::copy(&mut from_machine, &mut to_mac).await;
                        });
                        let (mut sent, mut buf) = (0usize, vec![0u8; 8192]);
                        loop {
                            let n = match from_mac.read(&mut buf).await {
                                Ok(0) | Err(_) => break,
                                Ok(n) => n,
                            };
                            if sent + n >= at {
                                // What fits goes, then the connection ends mid-message, and
                                // nothing reaches the machine until the test points at it again.
                                let _ = to_machine.write_all(&buf[..at - sent]).await;
                                to.store(1, Ordering::SeqCst);
                                cut.store(true, Ordering::SeqCst);
                                break;
                            }
                            if to_machine.write_all(&buf[..n]).await.is_err() {
                                break;
                            }
                            sent += n;
                        }
                        down.abort();
                    })
                };
                kept.lock().unwrap().push(pipe);
            }
        });
        Self { port: relay_port, target, tasks, trip_at, tripped }
    }

    /// The machine goes away: nothing reaches it from now on.
    fn cut(&self) {
        self.target.store(1, Ordering::SeqCst);
        for task in self.tasks.lock().unwrap().drain(..) {
            task.abort();
        }
    }

    /// The next connection is cut once `bytes` went from the Mac to the machine.
    fn cut_after(&self, bytes: usize) {
        self.tripped.store(false, Ordering::SeqCst);
        self.trip_at.store(bytes.max(1), Ordering::SeqCst);
    }

    /// The connection [`Self::cut_after`] armed was cut.
    fn tripped(&self) -> bool {
        self.tripped.load(Ordering::SeqCst)
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

/// Serves `hub` as the machine on a new port, proving the owner's peer link with `auth` (one
/// credential for both machines: the owner's link reaches the fresh one as it did the old).
async fn serve(hub: Arc<Hub>, auth: &Arc<PeerAuth>) -> u16 {
    let l = bind_ws("127.0.0.1:0").await.unwrap();
    let port = l.local_addr().unwrap().port();
    let ws = WsAuth { local_app: None, peer: Some(auth.clone()) };
    tokio::spawn(serve_ws_with(hub, l, "tok".into(), ws));
    port
}

fn prompt(text: &str, prompt_id: &str) -> Value {
    json!({"request": {"sessionId": "b/moved", "prompt": [{"type": "text", "text": text}],
                       "_meta": {"acpmux": {"promptId": prompt_id}}}})
}

/// Sends `text` from A through its outbox and waits until B took it.
async fn send(ca: &mut C, text: &str, prompt_id: &str) {
    send_queued(ca, prompt(text, prompt_id), prompt_id).await;
}

/// Sends `queued` (a `MUX_SEND_QUEUE` request) from A and waits until B took it.
async fn send_queued(ca: &mut C, queued: Value, prompt_id: &str) {
    let queued = ca.call(method::MUX_SEND_QUEUE, queued).await;
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

/// The prompts a move with `fault` sends, each of which runs exactly once.
fn prompts(fault: Fault) -> Vec<&'static str> {
    let mut all = vec!["p0", "p1", "p2"];
    if fault != Fault::StaleTry {
        all.push("p-race");
    }
    if fault == Fault::LocalPrompt {
        all.push("p-local");
    }
    all
}

/// Every record of `hub`'s journal of `id`, as the wire spells them.
fn journal(hub: &Hub, id: &str) -> Vec<Value> {
    let records = hub.events(id, 0, 10_000).unwrap();
    records.iter().map(|r| serde_json::to_value(r).unwrap()).collect()
}

/// What goes wrong on the way, besides the machine going away.
#[derive(Clone, Copy, PartialEq)]
enum Fault {
    None,
    /// The fresh machine's disk fails after the first restored record.
    AppendMidway,
    /// A prompt on the fresh machine itself comes while the restore holds the chat.
    LocalPrompt,
    /// The Mac cannot read its copies twice, then can.
    ReadsFailTwice,
    /// The Mac cannot read its copies at all.
    ReadsFail,
    /// The fresh machine's first try stops short, and before the Mac tries again its link goes
    /// to another machine on an even older disk, whose own restore reads slowly.
    StaleTry,
    /// The Mac's copy keeps only its last two records before the machine goes (a turn past the
    /// copy's bound): the prompts' records it cut are held by their deliveries, and go back.
    CacheBound,
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_session_moved_to_a_fresh_machine_from_an_older_disk_loses_no_prompt_and_no_turn() {
    move_to_a_fresh_machine(Fault::None).await;
}

/// The fresh machine's disk fails after the first record of the restore, after the line is
/// written: it answers the restore as failed, the Mac keeps its copy and delivers nothing
/// again, and its retry takes back the rest, with no seq twice. Nothing is lost or run twice.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_restore_that_fails_midway_is_kept_and_finished_by_a_retry() {
    move_to_a_fresh_machine(Fault::AppendMidway).await;
}

/// A prompt on the fresh machine itself, while the restore holds the chat: it waits, and runs
/// once after every restored record.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_prompt_during_a_restore_waits_and_runs_once_after_it() {
    move_to_a_fresh_machine(Fault::LocalPrompt).await;
}

/// The Mac cannot read whether its copy is ahead, twice: nothing goes to the machine until it
/// can, and then everything does, in order.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_copy_read_that_fails_holds_everything_until_it_reads() {
    move_to_a_fresh_machine(Fault::ReadsFailTwice).await;
}

/// Review of #37284 at af36583c, F1: a restore task whose link was replaced (by a machine on an
/// older disk still) stops; it never sends its old `afterSeq` there and deletes the Mac's copy
/// on the `diverged` answer. The new link's restore gives that machine every record.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_restore_whose_link_was_replaced_leaves_the_copy_to_the_new_link() {
    move_to_a_fresh_machine(Fault::StaleTry).await;
}

/// The Mac never can: a prompt to the machine fails visibly, and nothing is delivered again.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_copy_that_cannot_be_read_holds_the_peer_and_says_so() {
    move_to_a_fresh_machine(Fault::ReadsFail).await;
}

/// Review of #37284 at 0c98c292, F1: the copy's bound cuts the records the deliveries were
/// proven by before the machine goes; they go back from the deliveries, and every prompt runs
/// exactly once on the fresh machine.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_move_past_the_copys_bound_loses_no_prompt() {
    move_to_a_fresh_machine(Fault::CacheBound).await;
}

/// The moves run one at a time: their test seams are the process's, and each machine is "b".
static ONE_AT_A_TIME: tokio::sync::Mutex<()> = tokio::sync::Mutex::const_new(());

/// Fault `kill` the requester at 90% of a restore (cmuxterm-hq
/// `docs/design/remote-cloud-durability.md` F19, H14; the class of hq#11930, a long fill tied to
/// its request and restarted from zero). The Mac's copy runs past the fresh machine's journal by
/// a turn of [`CUT_CHUNKS`] records; its link is cut once 90% of the restore's bytes crossed it,
/// and comes back. The next link's restore goes on from where the machine's journal ends: it
/// sends at most a few pages again, never the whole copy, and the journal ends whole.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_restore_cut_at_ninety_percent_goes_on_from_where_it_stopped() {
    let _one = ONE_AT_A_TIME.lock().await;
    acpmux::hub::peer_snapshot_reads_fail("b", 0);
    acpmux::hub::peer_snapshot_bound(0);
    let _ = HERMETIC;
    let _ = tracing_subscriber::fmt().with_env_filter("acpmux=info").with_test_writer().try_init();
    let home = tempfile::tempdir().unwrap();
    let (b_disk, auth_dir) = (home.path().join("b-disk"), home.path().join("b-auth"));
    std::fs::create_dir_all(&b_disk).unwrap();
    let b_cfg = config(StoreMode::Local);
    let b = Hub::new(b_cfg.clone(), acpmux::store::open(&b_cfg.store, &b_disk).unwrap());
    b.resume_queues();
    let auth = Arc::new(PeerAuth::create(&auth_dir).unwrap());
    let peer_token =
        std::fs::read_to_string(acpmux::server::peer_auth::token_path(&auth_dir)).unwrap();
    let relay = Relay::to(serve(b.clone(), &auth).await).await;
    let mut cb = plain_client(b.clone()).await;
    let new = json!({"cwd": std::env::temp_dir(), "mcpServers": [],
                     "_meta": {"acpmux": {"name": "moved"}}});
    let id = cb.call(method::SESSION_NEW, new).await["sessionId"].as_str().unwrap().to_owned();

    let a_dir = home.path().join("a");
    std::fs::create_dir_all(&a_dir).unwrap();
    let a_cfg = config(StoreMode::Local);
    let a = Hub::new(a_cfg.clone(), acpmux::store::open(&a_cfg.store, &a_dir).unwrap());
    let url = format!("ws://127.0.0.1:{}", relay.port);
    a.add_peer("b", &url, Some("tok".into()), Some(peer_token), true).await.unwrap();
    let mut ca = client(a.clone()).await;
    ca.call(method::MUX_ATTACH, json!({"session": "b/moved", "limit": 400})).await;

    // A first turn, then the machine's disk is snapshotted: the fresh machine starts there.
    send(&mut ca, "first", "p0").await;
    copy_until(&mut ca, "the first reply", |e| e.iter().any(|e| says(e, "echo: first"))).await;
    b.flush();
    let snapshot = home.path().join("b-snapshot");
    copy_dir(&b_disk, &snapshot);
    let snapshot_end = journal(&b, &id).iter().filter_map(|e| e["seq"].as_u64()).max().unwrap();

    // A long turn the copy keeps whole, past where the snapshot ends.
    send(&mut ca, &format!("chunks: {CUT_CHUNKS}"), "p1").await;
    let last_word = format!("w{} ", CUT_CHUNKS - 1);
    let deadline = Instant::now() + Duration::from_secs(60);
    let copy = loop {
        let got =
            ca.call("_acpmux/peer_snapshot", json!({"sessionId": "b/moved", "limit": 5000})).await;
        let events = got["events"].as_array().cloned().unwrap_or_default();
        if events.iter().any(|e| says(e, &last_word)) {
            break events;
        }
        assert!(Instant::now() < deadline, "A's copy never held the long turn: {got}");
        tokio::time::sleep(Duration::from_millis(100)).await;
    };
    a.flush();
    let ahead: Vec<&Value> =
        copy.iter().filter(|e| e["seq"].as_u64().is_some_and(|s| s > snapshot_end)).collect();
    let restore_bytes: usize = ahead.iter().map(|e| e.to_string().len()).sum();
    relay.cut();
    b.shutdown_all().await;

    // The fresh machine; the link to it is cut once 90% of the restore's bytes went out.
    let b2 = Hub::new(b_cfg.clone(), acpmux::store::open(&b_cfg.store, &snapshot).unwrap());
    b2.resume_queues();
    let taken_at_start = acpmux::hub::journal_restore::records_taken(&id);
    relay.cut_after(restore_bytes * 9 / 10);
    let b2_port = serve(b2.clone(), &auth).await;
    relay.point_at(b2_port);
    let deadline = Instant::now() + Duration::from_secs(60);
    while !relay.tripped() {
        assert!(Instant::now() < deadline, "the restore never crossed 90% of its bytes");
        tokio::time::sleep(Duration::from_millis(5)).await;
    }
    let taken_before_cut = acpmux::hub::journal_restore::records_taken(&id) - taken_at_start;
    // The requester comes back on a new link.
    relay.point_at(b2_port);
    let deadline = Instant::now() + Duration::from_secs(120);
    while !journal(&b2, &id).iter().any(|e| says(e, &last_word)) {
        assert!(Instant::now() < deadline, "the fresh machine never got the whole turn back");
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    let sent_again =
        acpmux::hub::journal_restore::records_taken(&id) - taken_at_start - taken_before_cut;
    eprintln!(
        "restore of {} records ({restore_bytes} bytes): {taken_before_cut} taken before the cut, {sent_again} sent after it",
        ahead.len()
    );
    // Every record the copy held past the snapshot is in the fresh machine's journal, once.
    let restored = journal(&b2, &id);
    for e in &ahead {
        let seq = e["seq"].as_u64().unwrap();
        assert_eq!(
            restored.iter().filter(|r| r["seq"].as_u64() == Some(seq)).count(),
            1,
            "record {seq} once in the fresh machine's journal"
        );
    }
    assert!(
        sent_again * 100 <= ahead.len() * 40,
        "the restore started again from zero after the cut: {sent_again} of {} records sent again ({taken_before_cut} were taken before it)",
        ahead.len()
    );
}

/// The records of the turn [`a_restore_cut_at_ninety_percent_goes_on_from_where_it_stopped`]
/// restores: under the copy's bound (`peer_snapshot.rs` `SESSION_EVENTS`), so it keeps them all.
const CUT_CHUNKS: usize = 900;

async fn move_to_a_fresh_machine(fault: Fault) {
    let _one = ONE_AT_A_TIME.lock().await;
    acpmux::hub::peer_snapshot_reads_fail("b", 0);
    acpmux::hub::peer_snapshot_bound(0);
    let fail_midway = fault == Fault::AppendMidway;
    let _ = HERMETIC;
    let _ = tracing_subscriber::fmt().with_env_filter("acpmux=info").with_test_writer().try_init();
    let home = tempfile::tempdir().unwrap();
    let (b_disk, auth) = (home.path().join("b-disk"), home.path().join("b-auth"));
    std::fs::create_dir_all(&b_disk).unwrap();
    let b_cfg = config(StoreMode::Local);
    let b = Hub::new(b_cfg.clone(), acpmux::store::open(&b_cfg.store, &b_disk).unwrap());
    b.resume_queues();
    let auth_dir = auth;
    let auth = Arc::new(PeerAuth::create(&auth_dir).unwrap());
    let peer_token =
        std::fs::read_to_string(acpmux::server::peer_auth::token_path(&auth_dir)).unwrap();
    let relay = Relay::to(serve(b.clone(), &auth).await).await;
    let mut cb = plain_client(b.clone()).await;
    let new = json!({"cwd": std::env::temp_dir(), "mcpServers": [],
                     "_meta": {"acpmux": {"name": "moved"}}});
    let id = cb.call(method::SESSION_NEW, new).await["sessionId"].as_str().unwrap().to_owned();
    if fail_midway || fault == Fault::StaleTry {
        acpmux::hub::journal_restore::fail_once_after_first_record(&id);
    }
    // The disk before any turn, for a machine older still (`Fault::StaleTry`).
    let first_snapshot = home.path().join("b-snapshot-0");
    if fault == Fault::StaleTry {
        b.flush();
        copy_dir(&b_disk, &first_snapshot);
    }

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
    // The copy had them while the turn ran: the machine goes mid-turn, with p2 still waiting.
    assert!(
        !journal(&b, &id).iter().any(|e| says(e, "echo: second")),
        "A's copy caught up only once the running turn ended"
    );
    if fault == Fault::CacheBound {
        // The copy's write reports what it saw first, so the deliveries hold their prompts'
        // records (a record a bound cuts before any write reported it is held by nothing, and
        // a proof past it is not whole: `peer_snapshot.rs`). Then a page again, under a bound
        // of two records: the copy cuts everything else.
        a.flush();
        acpmux::hub::peer_snapshot_bound(2);
        ca.call(method::MUX_ATTACH, json!({"session": "b/moved", "limit": 400})).await;
        copy_until(&mut ca, "a copy cut to its bound", |e| !e.is_empty() && e.len() <= 2).await;
        a.flush();
    }
    relay.cut();
    // Its agents end with it; nothing it writes from now on reaches anyone.
    b.shutdown_all().await;

    // A fresh machine starts from the older snapshot, at the same address.
    let b2 = Hub::new(b_cfg.clone(), acpmux::store::open(&b_cfg.store, &snapshot).unwrap());
    b2.resume_queues();
    // A prompt sent the moment the fresh machine's link reads ready races its restore: it waits
    // for the restore's decision, so it never takes the seqs the restored records need.
    let racer = (fault != Fault::StaleTry).then(|| {
        let a = a.clone();
        tokio::spawn(async move {
            let mut cr = client(a.clone()).await;
            let deadline = Instant::now() + Duration::from_secs(30);
            // The old machine's link goes first, then the fresh one's comes up.
            while a.peers()[0]["connected"] == true {
                assert!(Instant::now() < deadline, "the old machine's link never dropped");
                tokio::time::sleep(Duration::from_millis(2)).await;
            }
            while a.peers()[0]["connected"] != true {
                assert!(Instant::now() < deadline, "the fresh machine never linked");
                tokio::time::sleep(Duration::from_millis(2)).await;
            }
            let race = json!({"sessionId": "b/moved", "prompt": [{"type": "text", "text": "racer"}],
                              "_meta": {"acpmux": {"promptId": "p-race"}}});
            cr.raw(method::SESSION_PROMPT, race).await
        })
    });
    match fault {
        Fault::ReadsFailTwice => acpmux::hub::peer_snapshot_reads_fail("b", 2),
        Fault::ReadsFail => acpmux::hub::peer_snapshot_reads_fail("b", u32::MAX),
        Fault::LocalPrompt => acpmux::hub::journal_restore::pause_once_holding(&id, 1500),
        _ => {}
    }
    // On the fresh machine itself, while the restore holds the chat.
    let local = (fault == Fault::LocalPrompt).then(|| {
        let b2 = b2.clone();
        let id = id.clone();
        tokio::spawn(async move {
            let deadline = Instant::now() + Duration::from_secs(30);
            while !acpmux::hub::journal_restore::test_paused() {
                assert!(Instant::now() < deadline, "the restore never held the chat");
                tokio::time::sleep(Duration::from_millis(5)).await;
            }
            let mut c = plain_client(b2).await;
            let p = json!({"sessionId": id, "prompt": [{"type": "text", "text": "local"}],
                           "_meta": {"acpmux": {"promptId": "p-local"}}});
            c.call(method::SESSION_PROMPT, p).await
        })
    });
    relay.point_at(serve(b2.clone(), &auth).await);
    let b2 = if fault == Fault::StaleTry {
        // B2's first try stopped short; while the Mac waits to try again, its link goes to B3,
        // started from the disk before any turn, whose own restore cannot read the copy at
        // first (it reads it a few seconds later).
        let deadline = Instant::now() + Duration::from_secs(30);
        while acpmux::hub::journal_restore::fail_once_armed(&id) {
            assert!(Instant::now() < deadline, "B2's restore never stopped short");
            tokio::time::sleep(Duration::from_millis(2)).await;
        }
        acpmux::hub::peer_snapshot_reads_fail("b", 4);
        relay.cut();
        b2.shutdown_all().await;
        let b3 =
            Hub::new(b_cfg.clone(), acpmux::store::open(&b_cfg.store, &first_snapshot).unwrap());
        b3.resume_queues();
        relay.point_at(serve(b3.clone(), &auth).await);
        b3
    } else {
        b2
    };
    if fault == Fault::ReadsFail {
        let racer = racer.unwrap();
        // The racer is refused, saying why, and nothing reaches the machine: not it, not the
        // deliveries the old machine had taken.
        let answer = tokio::time::timeout(Duration::from_secs(60), racer).await.unwrap().unwrap();
        assert_eq!(answer["error"]["data"]["reason"], "restore_pending", "{answer}");
        let events = journal(&b2, &id);
        let kinds: Vec<_> = events.iter().map(|e| json!([e["seq"], e["kind"]])).collect();
        for p in ["p1", "p2", "p-race"] {
            assert!(
                !events.iter().any(|e| names_prompt(e, "user_message", p)),
                "{p} went: {kinds:?}"
            );
        }
        acpmux::hub::peer_snapshot_reads_fail("b", 0);
        return;
    }

    // The waiting prompt runs there, once.
    let deadline = Instant::now() + Duration::from_secs(60);
    loop {
        let events = journal(&b2, &id);
        if events.iter().any(|e| says(e, "echo: second")) {
            break;
        }
        if Instant::now() >= deadline {
            let copy = ca.call("_acpmux/peer_snapshot", json!({"sessionId": "b/moved"})).await;
            let mut sent = vec![];
            for d in ca.call(method::MUX_SEND_STATUS, json!({"list": true})).await["deliveries"]
                .as_array()
                .cloned()
                .unwrap_or_default()
            {
                sent.push(json!([d["promptId"], d["status"], d["error"], d["attempts"]]));
            }
            let kinds: Vec<_> = events
                .iter()
                .map(|e| json!([e["seq"], e["kind"], e["at"], e["msg"]["promptId"]]))
                .collect();
            let saw: Vec<_> = seen
                .iter()
                .filter(|e| e["msg"]["promptId"].is_string())
                .map(|e| json!([e["seq"], e["kind"], e["at"], e["msg"]["promptId"]]))
                .collect();
            eprintln!("A saw of the prompts: {saw:?}");
            let old: Vec<_> = journal(&b, &id)
                .iter()
                .filter(|e| e["seq"].as_u64() > Some(16))
                .map(|e| {
                    let text = e["msg"].to_string();
                    json!([
                        e["seq"],
                        e["kind"],
                        e["at"],
                        e["msg"]["promptId"],
                        &text[..text.len().min(80)]
                    ])
                })
                .collect();
            for e in old {
                eprintln!("B OLD {e}");
            }
            // B2's log files as they are on its disk, each line's seq and kind.
            let mut dirs = vec![snapshot.clone()];
            while let Some(dir) = dirs.pop() {
                for entry in std::fs::read_dir(&dir).into_iter().flatten().flatten() {
                    let path = entry.path();
                    if path.is_dir() {
                        dirs.push(path);
                        continue;
                    }
                    let name = path.to_string_lossy().into_owned();
                    if !name.contains(&id) || !name.contains("/events/") {
                        continue;
                    }
                    let text = std::fs::read_to_string(&path).unwrap_or_default();
                    let lines: Vec<String> = text
                        .lines()
                        .map(|l| {
                            let v: Value = serde_json::from_str(l).unwrap_or_default();
                            format!("{}:{}", v["seq"], v["kind"].as_str().unwrap_or("?"))
                        })
                        .collect();
                    eprintln!("B2 FILE {name}: {}", lines.join(" "));
                }
            }
            panic!(
                "p2 never ran on the fresh machine.\npeers: {:?}\ncopy lastSeq {} hostLastSeq {}\nsent: {sent:?}\nB2: {kinds:?}",
                a.peers(),
                copy["lastSeq"],
                copy["hostLastSeq"]
            );
        }
        tokio::time::sleep(Duration::from_millis(200)).await;
    }
    if let Some(racer) = racer {
        let raced = tokio::time::timeout(Duration::from_secs(60), racer).await.unwrap().unwrap();
        assert!(raced.get("error").is_none(), "the racer was refused: {raced}");
    }
    if let Some(local) = local {
        tokio::time::timeout(Duration::from_secs(60), local).await.unwrap().unwrap();
    }
    let events = journal(&b2, &id);
    // Every record A saw of B is in B2's journal, with its seq (past the copy's bound, every
    // record of the prompts' lives).
    let kept = |r: &&Value| fault != Fault::CacheBound || r["msg"]["promptId"].is_string();
    for record in seen.iter().filter(kept) {
        let seq = record["seq"].as_u64().unwrap();
        let held = events.iter().find(|e| e["seq"].as_u64() == Some(seq));
        assert!(
            held.is_some_and(|e| e["kind"] == record["kind"] && e["at"] == record["at"]),
            "B2 lost seq {seq} ({}) A saw: {held:?}",
            record["kind"]
        );
    }
    // Every prompt A sent ran exactly once: none lost, none run twice by the redelivery.
    for p in prompts(fault) {
        let ran = events.iter().filter(|e| names_prompt(e, "user_message", p)).count();
        assert_eq!(ran, 1, "{p} ran {ran} times: {events:#?}");
    }
    // Let the redelivery settle, then count again: a late resend runs nothing more.
    tokio::time::sleep(Duration::from_secs(2)).await;
    let events = journal(&b2, &id);
    for p in prompts(fault) {
        let ran = events.iter().filter(|e| names_prompt(e, "user_message", p)).count();
        assert_eq!(ran, 1, "{p} ran {ran} times after the redelivery: {events:#?}");
    }
    let replies = events.iter().filter(|e| says(e, "echo: second")).count();
    assert_eq!(replies, 1, "p2 answered {replies} times: {events:#?}");
    // No seq twice: each record comes after the one before it. (The old machine's own journal
    // can skip a seq; every one A saw is checked above.)
    let seqs: Vec<u64> = events.iter().filter_map(|e| e["seq"].as_u64()).collect();
    assert!(seqs.windows(2).all(|w| w[0] < w[1]), "B2's seqs: {seqs:?}");
    let restored = seen.iter().filter_map(|e| e["seq"].as_u64()).max().unwrap();
    // The local prompt ran after every restored record too.
    if fault == Fault::LocalPrompt {
        let local = events.iter().find(|e| names_prompt(e, "user_message", "p-local")).unwrap();
        assert!(local["seq"].as_u64().unwrap() > restored, "the local prompt went first: {local}");
    }
    // The racer ran after every restored record.
    if fault != Fault::StaleTry {
        let raced = events.iter().find(|e| names_prompt(e, "user_message", "p-race")).unwrap();
        assert!(raced["seq"].as_u64().unwrap() > restored, "the racer went first: {raced}");
    }
    if fail_midway {
        assert!(!acpmux::hub::journal_restore::fail_once_armed(&id), "the restore never failed");
    }
    // The agent resumed its own session from the older disk, which ended after p0: the first
    // prompt it ran there (the cut turn's continuation) carried what it missed, p1's turn, and
    // nothing it had (p0) nor what it runs itself next (p2). The agent echoes its prompt.
    if fault == Fault::None {
        let replays: Vec<&Value> =
            events.iter().filter(|e| says(e, "restored_transcript")).collect();
        assert_eq!(replays.len(), 1, "one prompt carries the missed turns: {replays:#?}");
        let replay = replays[0]["msg"].to_string();
        assert!(replay.contains("user: until-cancel") && replay.contains("running"), "{replay}");
        assert!(!replay.contains("user: first") && !replay.contains("second"), "{replay}");
    }
}

/// A Web client of the Mac cannot write a machine's journal: `_acpmux/journal_restore` naming a
/// peer's session is refused on the Mac, never passed on (the peer would read it as the Mac's).
/// Nor can a paired client device, which the machine serves as a peer with its own credential.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_web_client_or_a_paired_device_cannot_restore_a_journal() {
    let _ = HERMETIC;
    let home = tempfile::tempdir().unwrap();
    let auth_dir = home.path().join("b-auth");
    let auth = Arc::new(PeerAuth::create(&auth_dir).unwrap());
    let peer_token =
        std::fs::read_to_string(acpmux::server::peer_auth::token_path(&auth_dir)).unwrap();
    let cfg = config(StoreMode::Memory);
    let b = Hub::new(cfg.clone(), acpmux::store::open(&cfg.store, home.path()).unwrap());
    let port = serve(b.clone(), &auth).await;
    let mut cb = plain_client(b.clone()).await;
    let new = json!({"cwd": std::env::temp_dir(), "mcpServers": [],
                     "_meta": {"acpmux": {"name": "moved"}}});
    let made = cb.call(method::SESSION_NEW, new).await;
    let id = made["sessionId"].as_str().unwrap().to_owned();
    let created = b.session_summary(&b.resolve(&id).unwrap())["createdAt"].clone();
    let before = journal(&b, &id).len() as u64;

    let a = Hub::new(cfg.clone(), acpmux::store::open(&cfg.store, home.path()).unwrap());
    let url = format!("ws://127.0.0.1:{port}");
    a.add_peer("b", &url, Some("tok".into()), Some(peer_token), true).await.unwrap();
    let deadline = Instant::now() + Duration::from_secs(20);
    while a.resolve_remote("b/moved").is_none() {
        assert!(Instant::now() < deadline, "A never listed b/moved");
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    let (in_tx, in_rx) = mpsc::channel(64);
    let (out_tx, mut out_rx) = mpsc::channel(4096);
    tokio::spawn(acpmux::server::serve_connection_with(a.clone(), in_rx, out_tx, Origin::Web));
    let forged = json!({"seq": before + 1, "at": 1, "dir": "mux", "kind": "queued",
                        "msg": {"promptId": "forged", "turnId": "t-forged", "text": "rm -rf ~"}});
    let lines = [
        Message::request(1, method::INITIALIZE, json!({"protocolVersion": 1})).to_line(),
        Message::request(
            2,
            "_acpmux/journal_restore",
            json!({"sessionId": "b/moved", "createdAt": created, "afterSeq": before,
                   "records": [forged.clone()]}),
        )
        .to_line(),
    ];
    for line in lines {
        in_tx.send(line).await.unwrap();
    }
    let answer = loop {
        let line = tokio::time::timeout(Duration::from_secs(20), out_rx.recv())
            .await
            .expect("timeout")
            .expect("closed");
        let v: Value = serde_json::from_str(&line).unwrap();
        if v.get("id") == Some(&json!(2)) {
            break v;
        }
    };
    assert!(answer.get("error").is_some(), "a Web client's journal restore was taken: {answer}");
    let after = journal(&b, &id);
    assert_eq!(after.len() as u64, before, "B's journal took a Web client's records: {after:#?}");

    // A paired client device reaches B as a peer too, with its own credential: refused there.
    let (in_tx, in_rx) = mpsc::channel(64);
    let (out_tx, mut out_rx) = mpsc::channel(4096);
    tokio::spawn(acpmux::server::serve_connection_authed(
        b.clone(),
        in_rx,
        out_tx,
        Origin::Peer,
        acpmux::server::ConnAuth::Device,
    ));
    let lines = [
        Message::request(1, method::INITIALIZE, json!({"protocolVersion": 1})).to_line(),
        Message::request(
            2,
            "_acpmux/journal_restore",
            json!({"sessionId": id, "createdAt": created, "afterSeq": before,
                   "records": [forged]}),
        )
        .to_line(),
    ];
    for line in lines {
        in_tx.send(line).await.unwrap();
    }
    let answer = loop {
        let line = tokio::time::timeout(Duration::from_secs(20), out_rx.recv())
            .await
            .expect("timeout")
            .expect("closed");
        let v: Value = serde_json::from_str(&line).unwrap();
        if v.get("id") == Some(&json!(2)) {
            break v;
        }
    };
    assert!(answer.get("error").is_some(), "a paired device's journal restore was taken: {answer}");
    let after = journal(&b, &id);
    assert_eq!(
        after.len() as u64,
        before,
        "B's journal took a paired device's records: {after:#?}"
    );
}

/// One chat on a machine of its own, restored straight through its unix socket (the owner's
/// daemon would send the same request over its link). The review's F2 (a purge racing a
/// restore) is tested at the purge's own seam, `hub/journal_restore_tests.rs`.
struct OneChat {
    _home: tempfile::TempDir,
    hub: Arc<Hub>,
    c: C,
    id: String,
    created: Value,
    before: u64,
}

async fn one_chat() -> OneChat {
    let _ = HERMETIC;
    let home = tempfile::tempdir().unwrap();
    let cfg = config(StoreMode::Local);
    let hub = Hub::new(cfg.clone(), acpmux::store::open(&cfg.store, home.path()).unwrap());
    hub.resume_queues();
    let mut c = plain_client(hub.clone()).await;
    let new = json!({"cwd": std::env::temp_dir(), "mcpServers": [],
                     "_meta": {"acpmux": {"name": "moved"}}});
    let id = c.call(method::SESSION_NEW, new).await["sessionId"].as_str().unwrap().to_owned();
    let created = hub.session_summary(&hub.resolve(&id).unwrap())["createdAt"].clone();
    let before = journal(&hub, &id).iter().filter_map(|e| e["seq"].as_u64()).max().unwrap_or(0);
    OneChat { _home: home, hub, c, id, created, before }
}

impl OneChat {
    /// Three records the owner kept past where this journal ends.
    fn kept(&self) -> Vec<Value> {
        (1..=3)
            .map(|n| {
                json!({"seq": self.before + n, "at": 1_000 + n, "dir": "mux", "kind": "status",
                       "msg": {"status": "idle", "detail": format!("kept {n}")}})
            })
            .collect()
    }

    async fn restore(&mut self) -> Value {
        let p = json!({"sessionId": self.id, "createdAt": self.created,
                       "afterSeq": self.before, "records": self.kept()});
        self.c.raw("_acpmux/journal_restore", p).await
    }

    fn prompt(&self, prompt_id: &str, meta: Value) -> JoinHandle<Value> {
        let (hub, id, prompt_id) = (self.hub.clone(), self.id.clone(), prompt_id.to_owned());
        tokio::spawn(async move {
            let mut c = plain_client(hub).await;
            let mut mux = json!({"promptId": prompt_id});
            mux.as_object_mut().unwrap().extend(meta.as_object().cloned().unwrap_or_default());
            let p = json!({"sessionId": id, "prompt": [{"type": "text", "text": "hello"}],
                           "_meta": {"acpmux": mux}});
            c.raw(method::SESSION_PROMPT, p).await
        })
    }
}

/// Review of #37284 at df095c5d, F1: a restore that stopped short holds the chat until the
/// owner's next try, so a prompt sent in between waits, the retry is taken (not `diverged`), and
/// the prompt runs once, after every kept record.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_prompt_between_a_restores_tries_waits_for_the_retry() {
    let _one = ONE_AT_A_TIME.lock().await;
    let mut chat = one_chat().await;
    acpmux::hub::journal_restore::fail_once_after_first_record(&chat.id);
    let first = chat.restore().await;
    assert_eq!(first["error"]["data"]["reason"], "append_failed", "{first}");
    let between = chat.prompt("p-between", json!({}));
    tokio::time::sleep(Duration::from_millis(700)).await;
    let events = journal(&chat.hub, &chat.id);
    assert!(
        !events.iter().any(|e| ["queued", "user_message"].iter().any(|kind| names_prompt(
            e,
            kind,
            "p-between"
        ))),
        "a prompt went in between the restore's tries: {events:#?}"
    );
    let retry = chat.restore().await;
    assert!(retry.get("error").is_none(), "the retry was refused: {retry}");
    let ran = tokio::time::timeout(Duration::from_secs(60), between).await.unwrap().unwrap();
    assert!(ran.get("error").is_none(), "the prompt was refused: {ran}");
    let events = journal(&chat.hub, &chat.id);
    let seqs: Vec<u64> = events.iter().filter_map(|e| e["seq"].as_u64()).collect();
    assert!(seqs.windows(2).all(|w| w[0] < w[1]), "seqs: {seqs:?}");
    for record in chat.kept() {
        let seq = record["seq"].as_u64().unwrap();
        let held = events.iter().find(|e| e["seq"].as_u64() == Some(seq));
        assert!(held.is_some_and(|e| e["msg"] == record["msg"]), "seq {seq} is not the kept one");
    }
    let prompt = events.iter().find(|e| names_prompt(e, "user_message", "p-between")).unwrap();
    assert!(prompt["seq"].as_u64().unwrap() > chat.before + 3, "{prompt}");
}

/// F3: a flush that fails fails the restore, even with every record read back, so the owner
/// keeps its copy and tries again; the retry is taken, with each record once.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_restore_whose_flush_fails_is_not_taken_until_a_retry_flushes() {
    let _one = ONE_AT_A_TIME.lock().await;
    let mut chat = one_chat().await;
    acpmux::hub::journal_restore::fail_flush_once(&chat.id);
    let first = chat.restore().await;
    assert_eq!(first["error"]["data"]["reason"], "append_failed", "{first}");
    let retry = chat.restore().await;
    assert!(retry.get("error").is_none(), "the retry was refused: {retry}");
    assert_eq!(retry["result"]["lastSeq"], chat.before + 3, "{retry}");
    let events = journal(&chat.hub, &chat.id);
    let seqs: Vec<u64> = events.iter().filter_map(|e| e["seq"].as_u64()).collect();
    assert_eq!(seqs, (1..=chat.before + 3).collect::<Vec<_>>(), "each record once");
}

/// F4: a delivery again names the generation it first reached; a session of another generation
/// under the same id refuses it as stale and runs nothing. The same generation runs it.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_delivery_again_to_another_generation_of_its_session_is_refused_as_stale() {
    let _one = ONE_AT_A_TIME.lock().await;
    let chat = one_chat().await;
    let generation = chat.created.as_u64().unwrap();
    let stale = chat.prompt("p-stale", json!({"resend": true, "sessionCreatedAt": generation - 1}));
    let stale = tokio::time::timeout(Duration::from_secs(60), stale).await.unwrap().unwrap();
    assert_eq!(stale["error"]["data"]["reason"], "stale_generation", "{stale}");
    let events = journal(&chat.hub, &chat.id);
    assert!(
        !events.iter().any(|e| e["msg"]["promptId"] == "p-stale"),
        "a stale delivery ran: {events:#?}"
    );
    let same = chat.prompt("p-same", json!({"resend": true, "sessionCreatedAt": generation}));
    let same = tokio::time::timeout(Duration::from_secs(60), same).await.unwrap().unwrap();
    assert!(same.get("error").is_none(), "the same generation refused it: {same}");
}

/// What a move during a long turn finds: the Mac's copy holds the running turn's records and a
/// prompt queued behind it while that turn still runs, not once it ends. The turn here runs until
/// it is cancelled, so nothing the copy shows can have come with the turn's end.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_copy_takes_a_running_turns_records_while_it_runs() {
    let _one = ONE_AT_A_TIME.lock().await;
    acpmux::hub::peer_snapshot_reads_fail("b", 0);
    acpmux::hub::peer_snapshot_bound(0);
    let _ = HERMETIC;
    let home = tempfile::tempdir().unwrap();
    let (b_disk, auth_dir) = (home.path().join("b-disk"), home.path().join("b-auth"));
    std::fs::create_dir_all(&b_disk).unwrap();
    let b_cfg = config(StoreMode::Local);
    let b = Hub::new(b_cfg.clone(), acpmux::store::open(&b_cfg.store, &b_disk).unwrap());
    b.resume_queues();
    let auth = Arc::new(PeerAuth::create(&auth_dir).unwrap());
    let peer_token =
        std::fs::read_to_string(acpmux::server::peer_auth::token_path(&auth_dir)).unwrap();
    let port = serve(b.clone(), &auth).await;
    let mut cb = plain_client(b.clone()).await;
    let new = json!({"cwd": std::env::temp_dir(), "mcpServers": [],
                     "_meta": {"acpmux": {"name": "moved"}}});
    let id = cb.call(method::SESSION_NEW, new).await["sessionId"].as_str().unwrap().to_owned();
    let a_dir = home.path().join("a");
    std::fs::create_dir_all(&a_dir).unwrap();
    let a_cfg = config(StoreMode::Local);
    let a = Hub::new(a_cfg.clone(), acpmux::store::open(&a_cfg.store, &a_dir).unwrap());
    let url = format!("ws://127.0.0.1:{port}");
    a.add_peer("b", &url, Some("tok".into()), Some(peer_token), true).await.unwrap();
    let mut ca = client(a.clone()).await;
    ca.call(method::MUX_ATTACH, json!({"session": "b/moved", "limit": 400})).await;
    send(&mut ca, "first", "p0").await;
    copy_until(&mut ca, "the first reply", |e| e.iter().any(|e| says(e, "echo: first"))).await;

    send(&mut ca, "until-cancel", "p1").await;
    send(&mut ca, "second", "p2").await;
    // Well inside the turn: it runs until it is cancelled (the fake agent's cap is 30 s).
    let deadline = Instant::now() + Duration::from_secs(5);
    loop {
        let got =
            ca.call("_acpmux/peer_snapshot", json!({"sessionId": "b/moved", "limit": 1000})).await;
        let events = got["events"].as_array().cloned().unwrap_or_default();
        if events.iter().any(|e| says(e, "running"))
            && events.iter().any(|e| names_prompt(e, "queued", "p2"))
        {
            break;
        }
        if Instant::now() >= deadline {
            let shown = |records: &[Value]| -> Vec<Value> {
                records.iter().map(|e| json!([e["seq"], e["dir"], e["kind"]])).collect()
            };
            panic!(
                "A's copy lacks the running turn or the prompt behind it 5 s into the turn.\n\
                 copy lastSeq {} hostLastSeq {}: {:?}\nB: {:?}",
                got["lastSeq"],
                got["hostLastSeq"],
                shown(&events),
                shown(&journal(&b, &id))
            );
        }
        tokio::time::sleep(Duration::from_millis(100)).await;
    }
    b.shutdown_all().await;
}

/// What B's agent is asked to hold its turn on (`FAKE_UNTIL_CANCEL_IN`): the fresh machine's
/// agent is not, so the prompt B was running when it went runs to its end there.
#[cfg(unix)]
const HOLD: &str = "hold-the-turn";

/// The bytes of the document the attachment prompt carries.
#[cfg(unix)]
const NOTES: &[u8] = b"the notes say forty-two";

/// Review of #37284 at 4bce04df, F1: a prompt with an inline document starts its turn at once
/// (nothing waits), so its journal holds its `user_message` (with a hidden context: the
/// attachment's text, never logged) and `turn_started`, and no `queued` record naming its file.
/// The machine goes mid-turn; a fresh machine from an older disk takes A's copy back. The cut
/// turn is settled with no continuation (one could carry only the prompt's text), and A's
/// delivery again of that prompt id, which carries the whole prompt, is not answered from the
/// settled turn: it runs there once, with the document saved and named to the agent. 4bce04df
/// continued it with its text alone and answered the resend as a duplicate, so the document
/// never reached the fresh machine's agent.
#[cfg(unix)] // the stand-in agent's `gate:` turn waits on a FIFO (make_fifo)
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn an_attachment_prompt_cut_mid_turn_runs_again_whole_on_the_fresh_machine() {
    attachment_prompt_cut_mid_turn(false).await;
}

/// Review of #37284 at fd33a65b, F1: the same journey, but the attachment prompt first waits in
/// the queue behind a turn that runs (its `queued` record names its file), then starts, and the
/// machine goes mid-turn. Its old `queued` record proves nothing once it started: A delivers it
/// again, and it runs once on the fresh machine, whole. fd33a65b took any `queued` record as
/// proof: A checked and released the delivery, and the document never reached the agent.
#[cfg(unix)] // make_fifo, as above
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_queued_attachment_prompt_cut_mid_turn_runs_again_whole_on_the_fresh_machine() {
    attachment_prompt_cut_mid_turn(true).await;
}

/// Makes a FIFO at `path`: a `gate:` turn of the stand-in agent blocks until it is written.
#[cfg(unix)]
fn make_fifo(path: &Path) {
    let c = std::ffi::CString::new(path.as_os_str().as_encoded_bytes()).unwrap();
    // SAFETY: valid NUL-terminated path.
    assert_eq!(unsafe { libc::mkfifo(c.as_ptr(), 0o600) }, 0);
}

/// The attachment journey; `queued_first`: the attachment prompt waits in the queue first,
/// behind a turn held at a gate, and starts once that turn ends.
#[cfg(unix)]
async fn attachment_prompt_cut_mid_turn(queued_first: bool) {
    let _one = ONE_AT_A_TIME.lock().await;
    acpmux::hub::peer_snapshot_reads_fail("b", 0);
    acpmux::hub::peer_snapshot_bound(0);
    let _ = HERMETIC;
    let _ = tracing_subscriber::fmt().with_env_filter("acpmux=info").with_test_writer().try_init();
    let home = tempfile::tempdir().unwrap();
    let (b_disk, auth_dir) = (home.path().join("b-disk"), home.path().join("b-auth"));
    std::fs::create_dir_all(&b_disk).unwrap();
    let mut b_cfg = config(StoreMode::Local);
    let fake = b_cfg.harnesses.get_mut("fake").unwrap();
    fake.env.insert("FAKE_UNTIL_CANCEL_IN".into(), HOLD.into());
    let b2_cfg = config(StoreMode::Local);
    let b = Hub::new(b_cfg.clone(), acpmux::store::open(&b_cfg.store, &b_disk).unwrap());
    b.resume_queues();
    let auth = Arc::new(PeerAuth::create(&auth_dir).unwrap());
    let peer_token =
        std::fs::read_to_string(acpmux::server::peer_auth::token_path(&auth_dir)).unwrap();
    let relay = Relay::to(serve(b.clone(), &auth).await).await;
    let mut cb = plain_client(b.clone()).await;
    let new = json!({"cwd": std::env::temp_dir(), "mcpServers": [],
                     "_meta": {"acpmux": {"name": "moved"}}});
    let id = cb.call(method::SESSION_NEW, new).await["sessionId"].as_str().unwrap().to_owned();

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

    // A turn held at a gate, for the attachment prompt to wait behind (`queued_first`).
    let gate = home.path().join("gate");
    if queued_first {
        make_fifo(&gate);
        send(&mut ca, &format!("gate: {}", gate.display()), "pg").await;
        copy_until(&mut ca, "the gated turn", |e| e.iter().any(|e| says(e, "before-gate"))).await;
    }
    // The attachment prompt starts its turn at once (or waits, then starts once the gate opens),
    // and a prompt waits behind it.
    let text = format!("{HOLD}: read the notes");
    let attached = json!({"request": {"sessionId": "b/moved",
        "prompt": [{"type": "text", "text": text}, acpmux::attach::block("notes.txt", NOTES)],
        "_meta": {"acpmux": {"promptId": "p1"}}}});
    send_queued(&mut ca, attached, "p1").await;
    if queued_first {
        copy_until(&mut ca, "the waiting attachment prompt", |e| {
            e.iter().any(|e| names_prompt(e, "queued", "p1"))
        })
        .await;
        let open = gate.clone();
        tokio::task::spawn_blocking(move || std::fs::write(open, b"go")).await.unwrap().unwrap();
    }
    send(&mut ca, "second", "p2").await;
    let seen = copy_until(&mut ca, "the running attachment turn and the waiting prompt", |e| {
        e.iter().any(|e| says(e, "running"))
            && e.iter().any(|e| names_prompt(e, "turn_started", "p1"))
            && e.iter().any(|e| names_prompt(e, "queued", "p2"))
    })
    .await;
    // The case of the finding: its `user_message` holds a hidden context, and a `queued` record
    // names it only when it waited first (at 4bce04df, F1, none did; at fd33a65b, F1, one did).
    let accepted = seen.iter().find(|e| names_prompt(e, "user_message", "p1")).expect("p1's");
    assert!(accepted["msg"].get("hiddenContext").is_some(), "no hidden context: {accepted}");
    assert_eq!(
        seen.iter().any(|e| names_prompt(e, "queued", "p1")),
        queued_first,
        "whether p1 waited in the queue first: {seen:#?}"
    );
    relay.cut();
    b.shutdown_all().await;

    // A fresh machine starts from the older snapshot, at the same address.
    let b2 = Hub::new(b2_cfg.clone(), acpmux::store::open(&b2_cfg.store, &snapshot).unwrap());
    b2.resume_queues();
    relay.point_at(serve(b2.clone(), &auth).await);
    let restored = seen.iter().filter_map(|e| e["seq"].as_u64()).max().unwrap();
    let ran_whole = |e: &Value| {
        e["seq"].as_u64() > Some(restored) && says(e, "resource_link:notes.txt") && says(e, HOLD)
    };
    let deadline = Instant::now() + Duration::from_secs(60);
    loop {
        let events = journal(&b2, &id);
        if events.iter().any(ran_whole) && events.iter().any(|e| says(e, "echo: second")) {
            break;
        }
        if Instant::now() >= deadline {
            let kinds: Vec<_> =
                events.iter().map(|e| json!([e["seq"], e["kind"], e["msg"]["promptId"]])).collect();
            let mut sent = vec![];
            for d in ca.call(method::MUX_SEND_STATUS, json!({"list": true})).await["deliveries"]
                .as_array()
                .cloned()
                .unwrap_or_default()
            {
                sent.push(json!([d["promptId"], d["status"], d["error"], d["attempts"]]));
            }
            panic!(
                "the attachment prompt never ran whole on the fresh machine.\nsent: {sent:?}\nB2: {kinds:?}"
            );
        }
        tokio::time::sleep(Duration::from_millis(200)).await;
    }
    let events = journal(&b2, &id);
    // The cut turn is settled for the resend, with no continuation of its text alone.
    let settled = events
        .iter()
        .find(|e| names_prompt(e, "turn_result", "p1") && e["seq"].as_u64() > Some(restored))
        .expect("the cut turn settled");
    assert_eq!(settled["msg"]["detail"], "outcome_unknown", "{settled}");
    assert_eq!(settled["msg"]["rerunOnResend"], true, "{settled}");
    let continued = events.iter().any(|e| {
        e["msg"]["promptId"].as_str().is_some_and(|p| p.starts_with("p1") && p != "p1")
            || (e["kind"] == "auto_resume_scheduled" && e["msg"]["promptId"] == "p1")
    });
    assert!(!continued, "the cut attachment turn was continued with its text alone: {events:#?}");
    // It ran once on the fresh machine, whole: the agent got the document, saved there.
    let count = |events: &[Value]| {
        let runs = events
            .iter()
            .filter(|e| names_prompt(e, "user_message", "p1") && e["seq"].as_u64() > Some(restored))
            .count();
        (runs, events.iter().filter(|e| ran_whole(e)).count())
    };
    assert_eq!(count(&events), (1, 1), "p1 ran on the fresh machine: {events:#?}");
    let rerun = events
        .iter()
        .find(|e| names_prompt(e, "user_message", "p1") && e["seq"].as_u64() > Some(restored))
        .unwrap();
    assert!(rerun["msg"].get("hiddenContext").is_some(), "not the whole prompt: {rerun}");
    let reply = events.iter().find(|e| ran_whole(e)).unwrap().to_string();
    let uri =
        reply.split("resource_link:notes.txt:").nth(1).and_then(|r| r.split("file://").nth(1));
    let path = uri.and_then(|u| u.split(['"', ' ', '\\']).next()).expect("the document's path");
    assert_eq!(std::fs::read(path).unwrap(), NOTES, "the document the fresh machine saved");
    // Let the redelivery settle, then count again: a late resend runs nothing more.
    tokio::time::sleep(Duration::from_secs(2)).await;
    let events = journal(&b2, &id);
    assert_eq!(count(&events), (1, 1), "p1 ran again after the redelivery: {events:#?}");
    let ended = ["p0", "p2"].into_iter().chain(queued_first.then_some("pg"));
    for p in ended {
        let ran = events.iter().filter(|e| names_prompt(e, "user_message", p)).count();
        assert_eq!(ran, 1, "{p} ran {ran} times: {events:#?}");
    }
    let replies = events.iter().filter(|e| says(e, "echo: second")).count();
    assert_eq!(replies, 1, "p2 answered {replies} times: {events:#?}");
}

/// A daemon restart whose agent session is as far as its journal: no prompt carries a replay.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_restart_with_an_agent_as_far_as_its_journal_replays_nothing() {
    let _ = HERMETIC;
    let home = tempfile::tempdir().unwrap();
    let cfg = config(StoreMode::Local);
    let hub = Hub::new(cfg.clone(), acpmux::store::open(&cfg.store, home.path()).unwrap());
    hub.resume_queues();
    let mut c = plain_client(hub.clone()).await;
    let new = json!({"cwd": std::env::temp_dir(), "mcpServers": [],
                     "_meta": {"acpmux": {"name": "restarted"}}});
    let id = c.call(method::SESSION_NEW, new).await["sessionId"].as_str().unwrap().to_owned();
    let prompt = |text: &str| json!({"sessionId": id, "prompt": [{"type": "text", "text": text}]});
    c.call(method::SESSION_PROMPT, prompt("before")).await;
    hub.shutdown_all().await;
    drop(c);
    drop(hub);

    let hub = Hub::new(cfg.clone(), acpmux::store::open(&cfg.store, home.path()).unwrap());
    hub.resume_queues();
    let mut c = plain_client(hub.clone()).await;
    c.call(method::SESSION_PROMPT, prompt("after")).await;
    let events = journal(&hub, &id);
    assert!(events.iter().any(|e| says(e, "echo: after")), "{events:#?}");
    let replays = events.iter().filter(|e| says(e, "restored_transcript")).count();
    assert_eq!(replays, 0, "a restart replayed turns its agent had: {events:#?}");
}

/// E4 of plans/cloud ARCHITECTURE-2026-11.md, section 0.3 (P4, I1): the machine is killed at a
/// seeded point anywhere in a turn, a fresh machine starts from an older snapshot of its disk,
/// and the person's Mac (A) gives the session back. Each seed counts the prompts A sent and what
/// the fresh machine's journal holds of each: lost (never ran there), run twice, and turns with
/// no result (or a result other than `completed`). A seed picks:
/// - the snapshot's age: before any turn, or after the first turn (p0);
/// - the kill point: 0 to 1600 ms after p1 (`slow`: three chunks 300 ms apart) and p2 (an
///   echo queued behind it) were handed to A's outbox, so the kill lands before either reached
///   the machine, before p1's turn started, between its chunks, after it, in p2's turn or after;
/// - the down time: 0 to 500 ms, during which p3 is sent (to a machine that is gone).
///
/// Run (from `cmux-tui/`, a debug build):
/// `MOVE_SWEEP_SEEDS=50 cargo test -p acpmux --test machine_move_journey e4_ -- --ignored --nocapture`
/// It prints one row a seed and the totals, then fails on any lost prompt, prompt run twice, or
/// turn with no completed result.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[ignore = "the E4 sweep (minutes): MOVE_SWEEP_SEEDS=N ... -- --ignored"]
async fn e4_move_sweep_kills_the_machine_across_the_turn() {
    let env = |k: &str, d: u64| std::env::var(k).ok().and_then(|v| v.parse().ok()).unwrap_or(d);
    let (n, base) = (env("MOVE_SWEEP_SEEDS", 50), env("MOVE_SWEEP_SEED_BASE", 0));
    let started = Instant::now();
    let mut rows = Vec::new();
    for seed in base..base + n {
        let row = e4_one_kill(seed).await;
        eprintln!("{row}");
        rows.push(row);
    }
    let sum = |f: fn(&E4Row) -> usize| rows.iter().map(f).sum::<usize>();
    let (sent, lost, twice) = (sum(|r| r.sent), sum(|r| r.lost.len()), sum(|r| r.twice.len()));
    let (unfinished, not_completed) = (sum(|r| r.unfinished.len()), sum(|r| r.not_completed.len()));
    let by_point: BTreeMap<&str, (usize, usize)> = rows.iter().fold(BTreeMap::new(), |mut m, r| {
        let e = m.entry(r.point).or_insert((0, 0));
        e.0 += 1;
        e.1 += usize::from(!r.clean());
        m
    });
    eprintln!(
        "E4 sweep: {n} seeds (base {base}) in {:.0} s: {sent} prompts sent, {lost} lost, {twice} run twice, \
         {unfinished} turns with no result, {not_completed} turns not completed; kill points (seeds, failing): {by_point:?}",
        started.elapsed().as_secs_f64()
    );
    let failing: Vec<String> =
        rows.iter().filter(|r| !r.clean()).map(ToString::to_string).collect();
    assert!(
        failing.is_empty(),
        "{} of {n} seeds lost work:\n{}",
        failing.len(),
        failing.join("\n")
    );
}

struct E4Row {
    seed: u64,
    old_disk: bool,
    kill_ms: u64,
    down_ms: u64,
    /// Where the kill landed, read from the old machine's journal at the cut.
    point: &'static str,
    sent: usize,
    lost: Vec<String>,
    twice: Vec<String>,
    /// Prompts that ran with no `turn_result` after them.
    unfinished: Vec<String>,
    /// Prompts whose last `turn_result` is not `completed` (its status), with no completed one.
    not_completed: Vec<String>,
    /// Each prompt's `turn_result` statuses on the fresh machine.
    results: Vec<String>,
    /// Whether every answer is there once: "echo: first", "tick2", "echo: second", "echo: third".
    answers: String,
    settle_ms: u128,
}

impl E4Row {
    fn clean(&self) -> bool {
        self.lost.is_empty()
            && self.twice.is_empty()
            && self.unfinished.is_empty()
            && self.not_completed.is_empty()
    }
}

impl std::fmt::Display for E4Row {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(
            f,
            "seed {:>3} disk={} kill={:>4}ms ({:<14}) down={:>3}ms settle={:>5}ms {}: lost {:?} twice {:?} \
             unfinished {:?} not-completed {:?} results [{}] answers {}",
            self.seed,
            if self.old_disk { "before-p0" } else { "after-p0 " },
            self.kill_ms,
            self.point,
            self.down_ms,
            self.settle_ms,
            if self.clean() { "ok  " } else { "LOST" },
            self.lost,
            self.twice,
            self.unfinished,
            self.not_completed,
            self.results.join(" "),
            self.answers,
        )
    }
}

async fn e4_one_kill(seed: u64) -> E4Row {
    let _one = ONE_AT_A_TIME.lock().await;
    acpmux::hub::peer_snapshot_reads_fail("b", 0);
    acpmux::hub::peer_snapshot_bound(0);
    let _ = HERMETIC;
    let mut state = seed.wrapping_mul(0x9e37_79b9_7f4a_7c15) ^ 0xe4;
    let mut rng = move |n: u64| {
        // splitmix64
        state = state.wrapping_add(0x9e37_79b9_7f4a_7c15);
        let mut z = state;
        z = (z ^ (z >> 30)).wrapping_mul(0xbf58_476d_1ce4_e5b9);
        z = (z ^ (z >> 27)).wrapping_mul(0x94d0_49bb_1331_11eb);
        (z ^ (z >> 31)) % n
    };
    let old_disk = rng(2) == 0;
    let kill_ms = rng(1601);
    let down_ms = rng(501);

    let home = tempfile::tempdir().unwrap();
    let (b_disk, auth_dir) = (home.path().join("b-disk"), home.path().join("b-auth"));
    std::fs::create_dir_all(&b_disk).unwrap();
    let b_cfg = config(StoreMode::Local);
    let b = Hub::new(b_cfg.clone(), acpmux::store::open(&b_cfg.store, &b_disk).unwrap());
    b.resume_queues();
    let auth = Arc::new(PeerAuth::create(&auth_dir).unwrap());
    let peer_token =
        std::fs::read_to_string(acpmux::server::peer_auth::token_path(&auth_dir)).unwrap();
    let relay = Relay::to(serve(b.clone(), &auth).await).await;
    let mut cb = plain_client(b.clone()).await;
    let new = json!({"cwd": std::env::temp_dir(), "mcpServers": [],
                     "_meta": {"acpmux": {"name": "moved"}}});
    let id = cb.call(method::SESSION_NEW, new).await["sessionId"].as_str().unwrap().to_owned();
    let snapshot = home.path().join("b-snapshot");
    if old_disk {
        b.flush();
        copy_dir(&b_disk, &snapshot);
    }

    let a_dir = home.path().join("a");
    std::fs::create_dir_all(&a_dir).unwrap();
    let a_cfg = config(StoreMode::Local);
    let a = Hub::new(a_cfg.clone(), acpmux::store::open(&a_cfg.store, &a_dir).unwrap());
    let url = format!("ws://127.0.0.1:{}", relay.port);
    a.add_peer("b", &url, Some("tok".into()), Some(peer_token), true).await.unwrap();
    let mut ca = client(a.clone()).await;
    ca.call(method::MUX_ATTACH, json!({"session": "b/moved", "limit": 400})).await;

    send(&mut ca, "first", "p0").await;
    copy_until(&mut ca, "the first reply", |e| e.iter().any(|e| says(e, "echo: first"))).await;
    if !old_disk {
        b.flush();
        copy_dir(&b_disk, &snapshot);
    }

    // p1 and p2 go to A's outbox; the machine dies kill_ms later, wherever that lands.
    ca.call(method::MUX_SEND_QUEUE, prompt("slow", "p1")).await;
    ca.call(method::MUX_SEND_QUEUE, prompt("second", "p2")).await;
    tokio::time::sleep(Duration::from_millis(kill_ms)).await;
    relay.cut();
    let at_cut = journal(&b, &id);
    let has = |kind: &str, p: &str| at_cut.iter().any(|e| names_prompt(e, kind, p));
    let ended =
        |p: &str| at_cut.iter().any(|e| e["kind"] == "turn_result" && e["msg"]["promptId"] == p);
    let point = if !has("user_message", "p1") && !has("queued", "p1") {
        "before-p1"
    } else if !ended("p1") {
        match at_cut.iter().filter(|e| says(e, "tick")).count() {
            0 => "p1-started",
            1 => "p1-after-tick0",
            2 => "p1-after-tick1",
            _ => "p1-after-tick2",
        }
    } else if !has("user_message", "p2") {
        "p1-done"
    } else if !ended("p2") {
        "p2-running"
    } else {
        "p2-done"
    };
    b.shutdown_all().await;

    // While the machine is gone, the person sends p3.
    ca.call(method::MUX_SEND_QUEUE, prompt("third", "p3")).await;
    tokio::time::sleep(Duration::from_millis(down_ms)).await;

    // A fresh machine from the snapshot, at the same address.
    let b2 = Hub::new(b_cfg.clone(), acpmux::store::open(&b_cfg.store, &snapshot).unwrap());
    b2.resume_queues();
    let up = Instant::now();
    relay.point_at(serve(b2.clone(), &auth).await);
    let all = ["p0", "p1", "p2", "p3"];
    let result_of = |events: &[Value], p: &str| -> Vec<String> {
        events
            .iter()
            .filter(|e| e["kind"] == "turn_result" && e["msg"]["promptId"] == p)
            .map(|e| e["msg"]["status"].as_str().unwrap_or("?").to_owned())
            .collect()
    };
    let deadline = Instant::now() + Duration::from_secs(60);
    loop {
        let events = journal(&b2, &id);
        let done = all.iter().all(|p| !result_of(events.as_slice(), *p).is_empty())
            && says_once(&events, "echo: third");
        if done || Instant::now() >= deadline {
            break;
        }
        tokio::time::sleep(Duration::from_millis(100)).await;
    }
    let settle_ms = up.elapsed().as_millis();
    // A late redelivery runs nothing more.
    tokio::time::sleep(Duration::from_secs(2)).await;
    let events = journal(&b2, &id);
    let (mut lost, mut twice, mut unfinished, mut not_completed, mut results) =
        (vec![], vec![], vec![], vec![], vec![]);
    for p in all {
        let ran = events.iter().filter(|e| names_prompt(e, "user_message", p)).count();
        let statuses = result_of(events.as_slice(), p);
        results.push(format!("{p}:{}", statuses.join("/")));
        match ran {
            0 => lost.push(p.to_owned()),
            1 => {}
            _ => twice.push(format!("{p}x{ran}")),
        }
        if ran > 0 && statuses.is_empty() {
            unfinished.push(p.to_owned());
        } else if !statuses.is_empty() && !statuses.iter().any(|s| s == "completed") {
            not_completed.push(format!("{p}:{}", statuses.join("/")));
        }
    }
    let answers = ["echo: first", "tick2", "echo: second", "echo: third"]
        .iter()
        .map(|t| events.iter().filter(|e| says(e, t)).count().to_string())
        .collect::<Vec<_>>()
        .join("/");
    b2.shutdown_all().await;
    a.shutdown_all().await;
    E4Row {
        seed,
        old_disk,
        kill_ms,
        down_ms,
        point,
        sent: all.len(),
        lost,
        twice,
        unfinished,
        not_completed,
        results,
        answers,
        settle_ms,
    }
}

fn says_once(events: &[Value], text: &str) -> bool {
    events.iter().any(|e| says(e, text))
}
