//! Wake kind 1 of a paused agent machine (cmuxterm-hq `docs/rfd/0017-pausing-agent-machines.md`):
//! a message sent to a machine that is paused is held and delivered exactly once, also when the
//! send is retried while the machine resumes, and also when the sending daemon restarts meanwhile.
//!
//! Two daemons in this process: B owns the agent session, A reaches B as peer `b` through a
//! `cmux-fault` proxy. The machine pauses: the proxy refuses (`Drop`) or black-holes B, so the link
//! to it goes down. A's `peerWake` is a stand-in command that waits for the machine to resume (a
//! file the scenario writes once it heals the proxy, a seeded time after the command started), the
//! way the real command waits on Freestyle's resume. A client sends to `b/lane` through A's outbox
//! (`_acpmux/send_queue`) during the resume, retries that send under the same prompt id at seeded
//! points of the resume (and once after it), and in some runs A is killed and started again
//! mid-resume with its outbox on disk.
//!
//! At the end B's journal holds the prompt id as one `user_message` and one `turn_started`, the
//! delivery is delivered, and `peerWake` ran at least once.
//!
//! ```text
//! cargo test -p acpmux --test wake_held_message -- --nocapture   # CMUX_FAULT_RUNS (20)
//! CMUX_FAULT_SEED=3 cargo test -p acpmux --test wake_held_message -- --nocapture
//! ```
#![cfg(unix)]

#[path = "support/daemon_env.rs"]
mod daemon_env;
// This process runs stand-in agents (the fake agents under tests/).
const HERMETIC: daemon_env::Process = daemon_env::Process::stand_in().keep(&[
    "CMUX_FAULT_RUNS",
    "CMUX_FAULT_SEED",
    "CMUX_FAULT_SEED_BASE",
    "CMUX_FAULT_PARALLEL",
]);

use std::net::SocketAddr;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use acpmux::config::{Config, PermissionPolicy, StoreMode};
use acpmux::hub::Hub;
use acpmux::rpc::{Message, method};
use acpmux::server::peer_auth::PeerAuth;
use acpmux::server::{WsAuth, bind_ws, serve_connection, serve_ws_with};
use cmux_fault::proxy::{Partition, Proxy};
use cmux_fault::{Failed, Rng, Runs, Trace};
use serde_json::{Value, json};
use tokio::sync::{Notify, mpsc};
use tokio::time::Instant;

const STEP: Duration = Duration::from_secs(30);
/// How long a held message may take to run once its machine is back.
const DELIVER_BOUND: Duration = Duration::from_secs(60);
const PERSON_KEY: &str = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";

fn config(wake: Option<&Path>) -> Config {
    let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
    let mut value = json!({
        "harnesses": {"fake": {"argv": ["python3", fake]}},
        "defaultHarness": "fake",
    });
    if let Some(script) = wake {
        value["peerWake"] = json!({"argv": [script.display().to_string()]});
    }
    let mut cfg: Config = serde_json::from_value(value).unwrap();
    cfg.store.mode = StoreMode::Memory;
    cfg.permission_policy = PermissionPolicy::ApproveAll;
    cfg
}

fn store(cfg: &Config) -> Box<dyn acpmux::store::Store> {
    acpmux::store::open(&cfg.store, Path::new("/nonexistent")).unwrap()
}

/// A client of a hub: every line it got.
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
        let hello = json!({"protocolVersion": 1, "clientInfo": {"name": "wake-held"}});
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

fn link_state(a: &Hub) -> String {
    a.peers()
        .into_iter()
        .next()
        .map(|p| p["state"].as_str().unwrap_or("").to_owned())
        .unwrap_or_default()
}

/// Polls `cond` until it holds or `limit` passes. A condition, never a fixed pause.
async fn until(limit: Duration, mut cond: impl FnMut() -> bool) -> bool {
    let deadline = Instant::now() + limit;
    while Instant::now() < deadline {
        if cond() {
            return true;
        }
        tokio::time::sleep(Duration::from_millis(10)).await;
    }
    cond()
}

/// The stand-in `peerWake`: logs a line per run, then waits for the machine to be resumed (the
/// `resumed` file), as the real command waits for the provider's resume to finish.
fn write_wake_script(dir: &Path) -> PathBuf {
    let script = dir.join("peer-wake");
    let body = format!(
        "#!/bin/sh\necho \"$1\" >> {d}/wake.log\nwhile [ ! -e {d}/resumed ]; do sleep 0.02; done\n",
        d = dir.display()
    );
    std::fs::write(&script, body).unwrap();
    std::fs::set_permissions(&script, std::fs::Permissions::from_mode(0o755)).unwrap();
    script
}

fn wake_runs(dir: &Path) -> usize {
    std::fs::read_to_string(dir.join("wake.log")).map(|t| t.lines().count()).unwrap_or(0)
}

async fn start_a(dir: &Path, proxy: SocketAddr, peer_token: &str, script: &Path) -> Arc<Hub> {
    let cfg = config(Some(script));
    let a = Hub::new(cfg.clone(), store(&cfg));
    let pending = a.outbox.open(&dir.join("outbox.json"));
    a.add_peer(
        "b",
        &format!("ws://{proxy}"),
        Some("tok".into()),
        Some(peer_token.to_owned()),
        false,
    )
    .await
    .unwrap();
    acpmux::server::outbox::resume(&a, pending);
    a
}

fn request(prompt_id: &str, text: &str) -> Value {
    json!({"request": {
        "sessionId": "b/lane",
        "prompt": [{"type": "text", "text": text}],
        "_meta": {"acpmux": {"promptId": prompt_id}},
    }})
}

async fn scenario(seed: u64, trace: &Trace) -> Result<(), String> {
    let mut rng = Rng::new(seed);
    // How long the machine takes to resume, after the wake command started.
    let resume_ms = rng.range(300, 3_000);
    let blackhole = rng.chance(40);
    // Retries of the send at these points of the resume (ms after the first send), and one after.
    let retries: Vec<u64> = (0..rng.range(1, 4)).map(|_| rng.range(0, resume_ms)).collect();
    let restart_a = rng.chance(35);
    let fresh_connection = rng.chance(50);
    trace.note(format!(
        "resume_ms={resume_ms} blackhole={blackhole} retries={retries:?} restart_a={restart_a}"
    ));

    let dir = PathBuf::from("/tmp").join(format!("amx-whm-{seed}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    let script = write_wake_script(&dir);

    // B: owns the agent session, serves WebSocket with a peer token.
    let b_cfg = config(None);
    let b = Hub::new(b_cfg.clone(), store(&b_cfg));
    let auth = PeerAuth::create(&dir).unwrap();
    let peer_token = std::fs::read_to_string(acpmux::server::peer_auth::token_path(&dir)).unwrap();
    let peer_token = peer_token.trim().to_owned();
    let listener = bind_ws("127.0.0.1:0").await.unwrap();
    let b_ws = listener.local_addr().unwrap();
    let ws_auth = WsAuth { local_app: None, peer: Some(Arc::new(auth)) };
    tokio::spawn(serve_ws_with(b.clone(), listener, "tok".into(), ws_auth));
    let mut cb = Client::new(&b).await;
    let made = cb
        .call(
            method::SESSION_NEW,
            json!({"cwd": std::env::temp_dir(), "mcpServers": [],
                   "_meta": {"acpmux": {"name": "lane"}}}),
        )
        .await
        .unwrap();
    let session = made["sessionId"].as_str().unwrap().to_owned();

    // A reaches B through the proxy.
    let proxy = Proxy::start(b_ws, trace).await.map_err(|e| format!("proxy: {e}"))?;
    let mut a = start_a(&dir, proxy.addr(), &peer_token, &script).await;
    if !until(STEP, || link_state(&a) == "connected").await {
        return Err("peer b never connected".into());
    }
    {
        let mut ca = Client::new(&a).await;
        ca.call(method::MUX_ATTACH, json!({"session": "b/lane", "limit": 0})).await.unwrap();
    }

    // The machine pauses.
    proxy.set(if blackhole { Partition::Blackhole } else { Partition::Drop });
    proxy.cut();
    // A black hole is found by the link's silence budget; a refusal at once. The send may also
    // go before A knows (the seed decides).
    if rng.chance(60) && !until(Duration::from_secs(20), || link_state(&a) != "connected").await {
        return Err("the link never left connected after the machine paused".into());
    }

    let prompt_id = format!("wake-held-{seed}");
    let text = format!("held message {seed}");
    let mut client = Client::new(&a).await;
    let first = client.call(method::MUX_SEND_QUEUE, request(&prompt_id, &text)).await;
    let first = first.map_err(|e| format!("the send to the paused machine was refused: {e}"))?;
    let delivery = first["deliveryId"].as_str().unwrap_or_default().to_owned();
    trace.note(format!("sent, delivery {delivery}: {first}"));
    let sent_at = Instant::now();

    // The wake command runs for the message; the machine resumes resume_ms after it started.
    if !until(STEP, || wake_runs(&dir) > 0).await {
        return Err("peerWake never ran for a message sent to the paused machine".into());
    }
    let wake_started = Instant::now();
    let resumed_at = wake_started + Duration::from_millis(resume_ms);

    // Retries of the same send, mid-resume, until the machine is back.
    let mut retried = Vec::new();
    for at in &retries {
        let when = (sent_at + Duration::from_millis(*at)).min(resumed_at);
        tokio::time::sleep_until(when).await;
        if fresh_connection {
            client = Client::new(&a).await;
        }
        let r = client.call(method::MUX_SEND_QUEUE, request(&prompt_id, &text)).await;
        trace.note(format!("retry at {at} ms: {r:?}"));
        match r {
            Ok(r) => retried.push(r["deliveryId"].as_str().unwrap_or_default().to_owned()),
            Err(e) => return Err(format!("a retry during the resume was refused: {e}")),
        }
    }
    if restart_a {
        trace.note("fault: A restarts mid-resume (outbox on disk)");
        a.shutdown_all().await;
        a = start_a(&dir, proxy.addr(), &peer_token, &script).await;
        client = Client::new(&a).await;
    }
    tokio::time::sleep_until(resumed_at).await;
    // The machine is back: the proxy heals and the wake command ends.
    proxy.set(Partition::Pass);
    proxy.cut();
    proxy.set(Partition::Pass);
    std::fs::write(dir.join("resumed"), "1").unwrap();
    trace.note("the machine resumed");

    // One more retry right after it came back.
    let r = client.call(method::MUX_SEND_QUEUE, request(&prompt_id, &text)).await;
    trace.note(format!("retry after resume: {r:?}"));
    r.map_err(|e| format!("a retry after the resume was refused: {e}"))?;

    // The message is delivered and runs on B, within the bound.
    let counts = |b: &Arc<Hub>| {
        let records = b.events(&session, 0, 1_000_000).unwrap_or_default();
        let of = |kind: &str| {
            records
                .iter()
                .filter(|r| r.kind == kind && r.msg["promptId"].as_str() == Some(&prompt_id))
                .count()
        };
        (of("user_message"), of("turn_started"))
    };
    let landed = until(DELIVER_BOUND, || counts(&b).0 >= 1).await;
    // Let a duplicate show: the delivery settles, then the journal is read again.
    let settled = {
        let mut state = Value::Null;
        let deadline = Instant::now() + DELIVER_BOUND;
        while Instant::now() < deadline {
            let r = client
                .call(method::MUX_SEND_STATUS, json!({"deliveryId": delivery, "waitMs": 2000}))
                .await;
            if let Ok(s) = &r {
                state = s.clone();
                if matches!(s["status"].as_str(), Some("delivered" | "failed")) {
                    break;
                }
            }
        }
        state
    };
    let (messages, turns) = {
        // Both counts settle: the turn starts after the message is stored.
        until(Duration::from_secs(10), || counts(&b).1 >= 1).await;
        // A late duplicate has had the whole delivery settle plus this long to appear.
        tokio::time::sleep(Duration::from_millis(500)).await;
        counts(&b)
    };
    let wakes = wake_runs(&dir);
    trace.note(format!(
        "delivery {settled}; B journal: {messages} messages, {turns} turns; peerWake ran {wakes}x"
    ));
    a.shutdown_all().await;
    b.shutdown_all().await;
    let _ = std::fs::remove_dir_all(&dir);

    if !landed {
        return Err(format!(
            "the held message never reached B within {DELIVER_BOUND:?}: {settled}"
        ));
    }
    if messages != 1 || turns != 1 {
        return Err(format!(
            "the held message is in B's journal {messages} times as a message and {turns} as a \
             turn (want 1 and 1); delivery {settled}"
        ));
    }
    if settled["status"] != "delivered" {
        return Err(format!("the delivery did not settle as delivered: {settled}"));
    }
    Ok(())
}

#[test]
fn a_message_sent_to_a_paused_machine_is_held_and_delivered_once() -> Result<(), Failed> {
    let _ = HERMETIC;
    let replay = "cargo test -p acpmux --test wake_held_message";
    Runs::new("wake kind 1: held message", replay).at_most_parallel(4).run(|seed, trace| {
        let rt = tokio::runtime::Builder::new_multi_thread()
            .worker_threads(4)
            .enable_all()
            .build()
            .unwrap();
        rt.block_on(scenario(seed, trace))
    })
}
