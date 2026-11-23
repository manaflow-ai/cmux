//! A prompt sent to a session on another machine runs there exactly once, however the link
//! between the two daemons drops around it: before the prompt is written, after the peer took it
//! but before its answer came back, or after the answer (cmuxterm-hq
//! `plans/cmux-next/claude-desktop-changelog-watch.md` row 9).
//!
//! Two daemons in this process: B owns the agents (one stand-in agent per sender), A reaches B
//! as peer `b` over `ws://` through a TCP proxy this test cuts and restores at random. Several
//! senders on A send hundreds of prompts, each under its own prompt id, while a chaos task resets
//! the link every few hundred milliseconds. A sender that gets an error or no answer retries the
//! same prompt id with `_meta.acpmux.resend`, as the pane and the CLI do, until it is answered;
//! some senders also retry a prompt that was answered, as a client whose answer was lost would.
//!
//! At the end each prompt id is in B's log as one `user_message` and one `turn_started`, and
//! every send was answered within the bound (none stuck).

// The proxy is plain TCP; the stand-in agent runs under python3.
#![cfg(unix)]

#[path = "support/daemon_env.rs"]
mod daemon_env;
// This process runs stand-in agents (the fake agents under tests/).
const HERMETIC: daemon_env::Process = daemon_env::Process::stand_in();

use acpmux::config::{Config, PermissionPolicy, StoreMode};
use acpmux::hub::Hub;
use acpmux::rpc::{Message, method};
use acpmux::server::peer_auth::PeerAuth;
use acpmux::server::{WsAuth, bind_ws, serve_connection, serve_ws_with};
use serde_json::{Value, json};
use std::collections::HashMap;
use std::net::SocketAddr;
use std::path::Path;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;
use tokio::net::{TcpListener, TcpStream};
use tokio::sync::{Notify, mpsc, watch};
use tokio::time::Instant;

/// Senders, each with its own session on B.
const SENDERS: usize = 4;
/// Prompts each sender sends.
const PER_SENDER: usize = 150;
/// How long one attempt waits for its answer before it is retried.
const ATTEMPT_WAIT: Duration = Duration::from_secs(10);
/// How long one prompt may take, all its retries included, before it counts as stuck.
const STUCK: Duration = Duration::from_secs(120);
const STEP: Duration = Duration::from_secs(30);
const PERSON_KEY: &str = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";

fn config(policy: PermissionPolicy) -> Config {
    let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
    let mut cfg: Config = serde_json::from_value(json!({
        "harnesses": {"fake": {"argv": ["python3", fake]}},
        "defaultHarness": "fake",
    }))
    .unwrap();
    cfg.store.mode = StoreMode::Memory;
    cfg.permission_policy = policy;
    cfg
}

fn store(cfg: &Config) -> Box<dyn acpmux::store::Store> {
    acpmux::store::open(&cfg.store, Path::new("/nonexistent")).unwrap()
}

/// A small deterministic generator, so a failing run can be repeated from its printed seed.
struct Rng(u64);

impl Rng {
    fn next(&mut self) -> u64 {
        self.0 ^= self.0 << 13;
        self.0 ^= self.0 >> 7;
        self.0 ^= self.0 << 17;
        self.0
    }

    fn below(&mut self, n: u64) -> u64 {
        self.next() % n.max(1)
    }
}

// ------------------------------------------------------------------ a client

/// A client of a hub (the app on that machine): every line it got, in order.
struct Client {
    tx: mpsc::Sender<String>,
    log: Arc<(Mutex<Vec<Value>>, Notify)>,
    next: i64,
}

impl Client {
    async fn new(h: &Arc<Hub>) -> Self {
        let _ = h.person.install_spawn_key(PERSON_KEY);
        let (in_tx, in_rx) = mpsc::channel(64);
        let (out_tx, mut out_rx) = mpsc::channel::<String>(4096);
        tokio::spawn(serve_connection(h.clone(), in_rx, out_tx));
        let log: Arc<(Mutex<Vec<Value>>, Notify)> = Arc::default();
        let sink = log.clone();
        tokio::spawn(async move {
            while let Some(line) = out_rx.recv().await {
                if let Ok(v) = serde_json::from_str::<Value>(&line) {
                    sink.0.lock().unwrap().push(v);
                    sink.1.notify_waiters();
                }
            }
        });
        let mut c = Self { tx: in_tx, log, next: 0 };
        let hello = json!({"protocolVersion": 1, "clientInfo": {"name": "peer-exactly-once"}});
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

    async fn send(&mut self, m: &str, p: Value) -> i64 {
        self.next += 1;
        self.tx.send(Message::request(self.next, m, p).to_line()).await.unwrap();
        self.next
    }

    async fn reply(&self, id: i64, limit: Duration) -> Option<Result<Value, Value>> {
        let deadline = Instant::now() + limit;
        let mut at = 0;
        loop {
            let woke = self.log.1.notified();
            {
                let lines = self.log.0.lock().unwrap();
                while at < lines.len() {
                    let v = &lines[at];
                    if v.get("id") == Some(&json!(id)) && v.get("method").is_none() {
                        return Some(match v.get("error") {
                            Some(e) => Err(e.clone()),
                            None => Ok(v.get("result").cloned().unwrap_or(Value::Null)),
                        });
                    }
                    at += 1;
                }
            }
            if tokio::time::timeout_at(deadline, woke).await.is_err() {
                return None;
            }
        }
    }

    async fn call(&mut self, m: &str, p: Value) -> Result<Value, Value> {
        let id = self.send(m, p).await;
        self.reply(id, STEP).await.unwrap_or_else(|| panic!("{m}: no answer in {STEP:?}"))
    }
}

// ------------------------------------------------------------------ the link

/// A TCP proxy in front of B's WebSocket listener. A cut resets every connection through it and
/// refuses new ones until it is restored.
struct Carrier {
    addr: SocketAddr,
    up: watch::Sender<bool>,
    epoch: watch::Sender<u64>,
}

impl Carrier {
    async fn start(target: SocketAddr) -> Arc<Self> {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        let me = Arc::new(Self { addr, up: watch::channel(true).0, epoch: watch::channel(0).0 });
        let weak = Arc::downgrade(&me);
        tokio::spawn(async move {
            while let Ok((conn, _)) = listener.accept().await {
                let Some(me) = weak.upgrade() else { return };
                if !*me.up.borrow() {
                    drop(conn);
                    continue;
                }
                tokio::spawn(pump(conn, target, me.epoch.subscribe()));
            }
        });
        me
    }

    fn cut(&self) {
        self.up.send_replace(false);
        self.epoch.send_modify(|n| *n += 1);
    }

    fn restore(&self) {
        self.up.send_replace(true);
    }
}

async fn pump(mut conn: TcpStream, target: SocketAddr, mut epoch: watch::Receiver<u64>) {
    let born = *epoch.borrow_and_update();
    let Ok(mut far) = TcpStream::connect(target).await else { return };
    tokio::select! {
        _ = tokio::io::copy_bidirectional(&mut conn, &mut far) => {}
        _ = epoch.wait_for(|n| *n != born) => {}
    }
}

fn link_state(a: &Hub) -> String {
    a.peers()
        .into_iter()
        .next()
        .map(|p| p["state"].as_str().unwrap_or("").to_owned())
        .unwrap_or_default()
}

async fn until_connected(a: &Hub, limit: Duration) -> bool {
    let deadline = Instant::now() + limit;
    while Instant::now() < deadline {
        if link_state(a) == "connected" {
            return true;
        }
        tokio::time::sleep(Duration::from_millis(5)).await;
    }
    false
}

// ------------------------------------------------------------------ the test

fn prompt(session: &str, text: &str, prompt_id: &str, resend: bool) -> Value {
    json!({
        "sessionId": session,
        "prompt": [{"type": "text", "text": text}],
        "_meta": {"acpmux": {"promptId": prompt_id, "resend": resend}},
    })
}

/// What one sender saw.
#[derive(Default)]
struct Tally {
    attempts: u64,
    errors: u64,
    timeouts: u64,
    lost_ack_retries: u64,
    /// Retries after a failed attempt that the peer answered as a duplicate: the attempt failed
    /// after the peer took the prompt.
    taken_then_dropped: u64,
    /// Lost-answer retries the peer answered marked as a duplicate.
    lost_ack_marked: u64,
    /// Why attempts failed, by reason.
    reasons: HashMap<String, u64>,
    stuck: Vec<String>,
    /// A later attempt of an answered prompt that was not answered as that prompt's first outcome.
    wrong_answers: Vec<String>,
}

#[tokio::test(flavor = "multi_thread", worker_threads = 8)]
async fn a_peer_prompt_runs_once_across_random_link_drops_under_load() {
    let seed = std::env::var("PEER_EXACTLY_ONCE_SEED")
        .ok()
        .and_then(|s| s.parse().ok())
        .unwrap_or_else(|| {
            std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos()
                as u64
                | 1
        });
    eprintln!("peer_exactly_once seed={seed}");
    let _ = HERMETIC;

    // B: owns the agents and serves WebSocket with a peer token.
    let b_cfg = config(PermissionPolicy::ApproveAll);
    let b = Hub::new(b_cfg.clone(), store(&b_cfg));
    let auth_home = std::env::temp_dir().join(format!("peo-auth-{}-{}", std::process::id(), seed));
    let _ = std::fs::remove_dir_all(&auth_home);
    std::fs::create_dir_all(&auth_home).unwrap();
    let auth = PeerAuth::create(&auth_home).unwrap();
    let peer_token =
        std::fs::read_to_string(acpmux::server::peer_auth::token_path(&auth_home)).unwrap();
    let peer_token = peer_token.trim().to_owned();
    let listener = bind_ws("127.0.0.1:0").await.unwrap();
    let b_ws = listener.local_addr().unwrap();
    let ws_auth = WsAuth { local_app: None, peer: Some(Arc::new(auth)) };
    tokio::spawn(serve_ws_with(b.clone(), listener, "tok".into(), ws_auth));
    let mut cb = Client::new(&b).await;
    let mut sessions = Vec::new();
    for n in 0..SENDERS {
        let meta = json!({"acpmux": {"name": format!("lane{n}")}});
        let made = cb
            .call(
                method::SESSION_NEW,
                json!({"cwd": std::env::temp_dir(), "mcpServers": [], "_meta": meta}),
            )
            .await
            .unwrap();
        sessions.push(made["sessionId"].as_str().unwrap().to_owned());
    }

    // A: reaches B as peer `b` through the carrier.
    let carrier = Carrier::start(b_ws).await;
    let a_cfg = config(PermissionPolicy::ApproveAll);
    let a = Hub::new(a_cfg.clone(), store(&a_cfg));
    a.add_peer("b", &format!("ws://{}", carrier.addr), Some("tok".into()), Some(peer_token), false)
        .await
        .unwrap();
    assert!(until_connected(&a, STEP).await, "peer b never connected");
    {
        let mut ca = Client::new(&a).await;
        for n in 0..SENDERS {
            ca.call(method::MUX_ATTACH, json!({"session": format!("b/lane{n}"), "limit": 0}))
                .await
                .unwrap();
        }
    }

    // Chaos: the link resets every 300..1200 ms and stays down 0..150 ms, until the senders
    // finish: long enough up that most cuts land on a send in flight.
    let done = Arc::new(AtomicBool::new(false));
    let cuts = Arc::new(AtomicU64::new(0));
    // Sends written to A and not yet answered, and the sum of that count at each cut: a cut with
    // sends in flight drops them after they left (A writes a prompt only on a ready link).
    let in_flight = Arc::new(AtomicU64::new(0));
    let cut_in_flight = Arc::new(AtomicU64::new(0));
    let chaos = tokio::spawn({
        let (carrier, done, cuts) = (carrier.clone(), done.clone(), cuts.clone());
        let (in_flight, cut_in_flight) = (in_flight.clone(), cut_in_flight.clone());
        let mut rng = Rng(seed ^ 0x9e37_79b9_7f4a_7c15);
        async move {
            while !done.load(Ordering::SeqCst) {
                tokio::time::sleep(Duration::from_millis(300 + rng.below(900))).await;
                carrier.cut();
                cuts.fetch_add(1, Ordering::SeqCst);
                cut_in_flight.fetch_add(in_flight.load(Ordering::SeqCst), Ordering::SeqCst);
                tokio::time::sleep(Duration::from_millis(rng.below(150))).await;
                carrier.restore();
            }
            carrier.restore();
        }
    });

    let started = Instant::now();
    let mut senders = Vec::new();
    for n in 0..SENDERS {
        let (a, in_flight) = (a.clone(), in_flight.clone());
        let mut rng = Rng(seed.wrapping_add(n as u64 * 0x1000_0001) | 1);
        senders.push(tokio::spawn(async move {
            let target = format!("b/lane{n}");
            let mut tally = Tally::default();
            let mut client = Client::new(&a).await;
            for i in 0..PER_SENDER {
                let prompt_id = format!("peo-{seed}-{n}-{i}");
                // One in three is the stand-in agent's 0.9 s turn, so drops land while the peer runs it.
                let text =
                    if rng.below(3) == 0 { "slow".to_owned() } else { format!("msg {n} {i}") };
                let began = Instant::now();
                let mut first: Option<Value> = None;
                let mut resend = false;
                let mut tries = 0u32;
                loop {
                    if began.elapsed() > STUCK {
                        tally.stuck.push(prompt_id.clone());
                        break;
                    }
                    tally.attempts += 1;
                    tries += 1;
                    in_flight.fetch_add(1, Ordering::SeqCst);
                    let id = client
                        .send(method::SESSION_PROMPT, prompt(&target, &text, &prompt_id, resend))
                        .await;
                    resend = true;
                    let answer = client.reply(id, ATTEMPT_WAIT).await;
                    in_flight.fetch_sub(1, Ordering::SeqCst);
                    match answer {
                        Some(Ok(r)) if r["stopReason"] == "end_turn" => {
                            if tries > 1
                                && r.pointer("/_meta/acpmux/duplicate") == Some(&json!(true))
                            {
                                tally.taken_then_dropped += 1;
                            }
                            first = Some(r);
                            break;
                        }
                        other @ (Some(Ok(_)) | Some(Err(_))) => {
                            tally.errors += 1;
                            let why = match &other {
                                Some(Ok(r)) => format!("answered {}", r["stopReason"]),
                                Some(Err(e)) => e
                                    .pointer("/data/reason")
                                    .and_then(Value::as_str)
                                    .map(str::to_owned)
                                    .unwrap_or_else(|| {
                                        e["message"]
                                            .as_str()
                                            .unwrap_or("")
                                            .chars()
                                            .take(60)
                                            .collect()
                                    }),
                                None => unreachable!(),
                            };
                            *tally.reasons.entry(why).or_default() += 1;
                            // A client that saw its send fail opens a new connection, as the pane
                            // does after a disconnect, and retries the same id.
                            client = Client::new(&a).await;
                            tokio::time::sleep(Duration::from_millis(rng.below(50))).await;
                        }
                        None => {
                            tally.timeouts += 1;
                            client = Client::new(&a).await;
                        }
                    }
                }
                // One in five: the answer was lost on the client's side, so it sends the prompt
                // again. It must be answered as the run that happened, not run again.
                if first.is_some() && rng.below(5) == 0 {
                    tally.lost_ack_retries += 1;
                    let deadline = Instant::now() + STUCK;
                    loop {
                        if Instant::now() > deadline {
                            tally.stuck.push(format!("{prompt_id} (lost-ack retry)"));
                            break;
                        }
                        let id = client
                            .send(method::SESSION_PROMPT, prompt(&target, &text, &prompt_id, true))
                            .await;
                        match client.reply(id, ATTEMPT_WAIT).await {
                            Some(Ok(r)) => {
                                if r.pointer("/_meta/acpmux/duplicate") == Some(&json!(true)) {
                                    tally.lost_ack_marked += 1;
                                }
                                if r["stopReason"] != "end_turn" {
                                    tally.wrong_answers.push(format!("{prompt_id}: {r}"));
                                }
                                break;
                            }
                            Some(Err(_)) | None => {
                                client = Client::new(&a).await;
                                tokio::time::sleep(Duration::from_millis(rng.below(50))).await;
                            }
                        }
                    }
                }
            }
            tally
        }));
    }
    let mut tallies = Vec::new();
    for s in senders {
        tallies.push(s.await.unwrap());
    }
    done.store(true, Ordering::SeqCst);
    let _ = chaos.await;
    let elapsed = started.elapsed();

    // Every prompt id is in B's log once, as a message and as a turn.
    let mut twice = Vec::new();
    let mut missing = Vec::new();
    for (n, session) in sessions.iter().enumerate() {
        let records = b.events(session, 0, 1_000_000).unwrap();
        let mut messages: HashMap<String, usize> = HashMap::new();
        let mut turns: HashMap<String, usize> = HashMap::new();
        for r in &records {
            let Some(id) = r.msg["promptId"].as_str() else { continue };
            match r.kind.as_str() {
                "user_message" => *messages.entry(id.to_owned()).or_default() += 1,
                "turn_started" => *turns.entry(id.to_owned()).or_default() += 1,
                _ => {}
            }
        }
        for i in 0..PER_SENDER {
            let id = format!("peo-{seed}-{n}-{i}");
            let (m, t) =
                (messages.get(&id).copied().unwrap_or(0), turns.get(&id).copied().unwrap_or(0));
            if m > 1 || t > 1 {
                twice.push(format!("{id}: {m} messages, {t} turns"));
            } else if m == 0 || t == 0 {
                missing.push(format!("{id}: {m} messages, {t} turns"));
            }
        }
    }
    let sum = |f: fn(&Tally) -> u64| tallies.iter().map(f).sum::<u64>();
    let stuck: Vec<_> = tallies.iter().flat_map(|t| t.stuck.clone()).collect();
    let wrong: Vec<_> = tallies.iter().flat_map(|t| t.wrong_answers.clone()).collect();
    let mut reasons: HashMap<String, u64> = HashMap::new();
    for t in &tallies {
        for (k, v) in &t.reasons {
            *reasons.entry(k.clone()).or_default() += v;
        }
    }
    eprintln!("peer_exactly_once failed attempts by reason: {reasons:?}");
    eprintln!(
        "peer_exactly_once seed={seed} prompts={} attempts={} errors={} timeouts={} lost_ack_retries={} lost_ack_marked={} taken_then_dropped={} cuts={} cut_in_flight={} elapsed_ms={} twice={} missing={} stuck={} wrong={}",
        SENDERS * PER_SENDER,
        sum(|t| t.attempts),
        sum(|t| t.errors),
        sum(|t| t.timeouts),
        sum(|t| t.lost_ack_retries),
        sum(|t| t.lost_ack_marked),
        sum(|t| t.taken_then_dropped),
        cuts.load(Ordering::SeqCst),
        cut_in_flight.load(Ordering::SeqCst),
        elapsed.as_millis(),
        twice.len(),
        missing.len(),
        stuck.len(),
        wrong.len(),
    );
    a.shutdown_all().await;
    b.shutdown_all().await;
    let _ = std::fs::remove_dir_all(&auth_home);
    assert!(twice.is_empty(), "seed {seed}: prompts ran more than once: {twice:?}");
    assert!(missing.is_empty(), "seed {seed}: answered prompts missing on the peer: {missing:?}");
    assert!(stuck.is_empty(), "seed {seed}: prompts never answered: {stuck:?}");
    assert!(
        wrong.is_empty(),
        "seed {seed}: a retry of an answered prompt was not answered as it: {wrong:?}"
    );
    assert!(cuts.load(Ordering::SeqCst) > 0, "seed {seed}: the link was never cut");
    // Each point of the send was hit: before it left A (`peer_unreachable`), after it left and
    // before its answer (a cut with sends in flight; A mostly carries those over to the next
    // link, else answers `prompt_outcome_unknown` or `peer_disconnected` and the client resends),
    // and after the answer (a lost-answer retry).
    let reason = |k: &str| reasons.get(k).copied().unwrap_or(0);
    assert!(reason("peer_unreachable") > 0, "seed {seed}: no drop fell before a send: {reasons:?}");
    assert!(
        cut_in_flight.load(Ordering::SeqCst) > 0,
        "seed {seed}: no drop fell between a send and its answer"
    );
    assert!(sum(|t| t.lost_ack_retries) > 0, "seed {seed}: no answer was lost");
}
