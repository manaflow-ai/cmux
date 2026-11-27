//! Each carrier a peer link runs on today, cut in the middle of a turn: two daemons in this
//! process (B owns the agent, A mirrors B as peer `b`), the carrier between them behind a proxy
//! this test can cut and restore, and the stand-in agent's `carrier-fault:` turn, which streams
//! 200 numbered chunks with a permission ask after chunk 50.
//!
//! The carriers: a direct `ws://` link over TCP; an `ssh://` link through a stand-in `ssh` whose
//! `-W` forward goes over TCP (the tunnel `peer.rs` `open_tunnel` runs); the labs WireGuard
//! transport (`wireguard.rs`) over loopback UDP; and the mesh hub relay (`server/mesh_relay.rs`)
//! against a fake hub. A cut is a reset (the carrier's connections close, new ones are refused)
//! or a black hole (bytes stop, nothing closes, as a dropped network does).
//!
//! Per row: the turn completes and A's client sees chunks 1..=200 exactly once, in order, with
//! no journal sequence twice; the ask that was waiting when the carrier went is answered after
//! the reconnect and the answer reaches the agent (that the client is shown it again is a row
//! of its own, ignored until it holds); a prompt sent during the outage runs
//! once or fails with a named error; the link leaves connected (reconnecting, or degraded
//! for a black hole) and is connected again within the bound. Each row prints its times (`carrier_faults row=...`) as the
//! baseline. Rows that need behavior acpmux does not have yet are `#[ignore]` with the fix
//! they wait for named.
//!
//! The Cloud carrier's ssh row (relay cut → ssh through `wg dial` → ssh cut → relay, after
//! `carrier capabilities` lists ssh) runs the `cmux-tui` binary, so it lives beside that
//! binary's tests: `cmux-tui/tests/carrier_ssh.rs`
//! `carrier_faults_ssh_row_relay_cut_fails_over_to_ssh_through_wg_dial_and_back`, printing
//! `carrier_faults row=cloud-ssh ...`.

// The stand-in ssh and its permissions, and the WireGuard relay, are Unix-only.
#![cfg(unix)]

#[path = "support/daemon_env.rs"]
mod daemon_env;
// This process runs stand-in agents (the fake agents under tests/).
const HERMETIC: daemon_env::Process = daemon_env::Process::stand_in();

use acpmux::config::{Config, PeerConfig, PermissionPolicy, StoreMode};
use acpmux::hub::Hub;
use acpmux::mesh::{
    Ack, Heartbeat, HeartbeatReply, HubError, InMessage, Kind, MeshHub, OutMessage, Receipt,
    Sender, Target,
};
use acpmux::rpc::{Message, method};
use acpmux::server::mesh_relay::{MeshRelay, RefuseControl, RelayOptions};
use acpmux::server::peer_auth::PeerAuth;
use acpmux::server::{WsAuth, bind_ws, serve_connection, serve_ws_with};
use acpmux::wireguard::{StaticConfig, StaticPeer, Transport};
use futures::future::BoxFuture;
use serde_json::{Value, json};
use std::collections::{HashMap, VecDeque};
use std::net::SocketAddr;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;
use tokio::io::AsyncReadExt;
use tokio::net::{TcpListener, TcpStream, UdpSocket};
use tokio::sync::{Notify, mpsc, watch};
use tokio::time::Instant;

const TOTAL: u64 = 200;
const KILL_AT: u64 = 50;
/// How long a cut link may take to leave `connected`: the link's silence budget (a ping every
/// 2 s, three missed: `peer_link.rs` `LinkTimings`) and room for the scheduler.
const DETECT_BOUND: Duration = Duration::from_secs(8);
/// How long a restored carrier may take to carry a ready link again: one redial step
/// (`Backoff`, at most 1 s while a client waits on the peer) and the handshake.
const REDIAL_BOUND: Duration = Duration::from_secs(5);
/// How long the outage lasts at most after the cut was seen, waiting for the outage prompt to
/// fail or be held.
const OUTAGE_HOLD: Duration = Duration::from_millis(750);
const STEP: Duration = Duration::from_secs(30);
/// How long after the reconnect a waiting ask has to be shown again.
const RESHOW_WAIT: Duration = Duration::from_secs(1);
const PERSON_KEY: &str = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";

fn config() -> Config {
    let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
    let mut cfg: Config = serde_json::from_value(json!({
        "harnesses": {"fake": {"argv": ["python3", fake]}},
        "defaultHarness": "fake",
    }))
    .unwrap();
    cfg.store.mode = StoreMode::Memory;
    cfg.permission_policy = PermissionPolicy::Ask;
    cfg
}

fn store(cfg: &Config) -> Box<dyn acpmux::store::Store> {
    acpmux::store::open(&cfg.store, Path::new("/nonexistent")).unwrap()
}

/// Set once, before any peer or `ssh` of this process starts: the stand-in `ssh` comes first on
/// PATH (every row calls this first; `Once` holds the others until it is done).
fn setup(scratch: &Path) -> PathBuf {
    static ONCE: std::sync::Once = std::sync::Once::new();
    let _ = HERMETIC;
    let dir = std::env::temp_dir().join(format!("acf-ssh-{}", std::process::id()));
    ONCE.call_once(|| {
        std::fs::create_dir_all(&dir).unwrap();
        stand_in_ssh(&dir);
        let path = std::env::var("PATH").unwrap_or_default();
        // SAFETY: set once, before any thread of this process reads PATH (every row calls this
        // before it starts a hub, an agent or an ssh).
        unsafe { std::env::set_var("PATH", format!("{}:{path}", dir.display())) };
    });
    std::fs::create_dir_all(scratch).unwrap();
    dir
}

/// A stand-in `ssh` for the tunnel a peer opens (`ssh ... -W 127.0.0.1:PORT -- HOST`): it carries
/// stdio to that port on this host, as ssh does to the remote's, and exits when either side ends.
fn stand_in_ssh(dir: &Path) {
    let script = r#"#!/usr/bin/env python3
import os, socket, sys, threading
args = sys.argv[1:]
if "-W" not in args:
    sys.exit(255)
host, port = args[args.index("-W") + 1].rsplit(":", 1)
try:
    s = socket.create_connection((host, int(port)))
except OSError as e:
    sys.stderr.write("ssh: connect to host %s port %s: %s\n" % (host, port, e))
    sys.exit(255)
def up():
    while True:
        b = os.read(0, 65536)
        if not b:
            break
        s.sendall(b)
    s.shutdown(socket.SHUT_WR)
threading.Thread(target=up, daemon=True).start()
while True:
    try:
        b = s.recv(65536)
    except OSError:
        break
    if not b:
        break
    os.write(1, b)
sys.exit(0)
"#;
    let path = dir.join("ssh");
    std::fs::write(&path, script).unwrap();
    use std::os::unix::fs::PermissionsExt;
    std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o755)).unwrap();
}

// ------------------------------------------------------------------ clients

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
        let hello = json!({"protocolVersion": 1, "clientInfo": {"name": "carrier-faults"}});
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

    /// The first line `pick` takes, from index `from` on, waiting up to `limit`.
    async fn find<T>(
        &self,
        from: usize,
        limit: Duration,
        mut pick: impl FnMut(&Value) -> Option<T>,
    ) -> Option<(usize, T)> {
        let deadline = Instant::now() + limit;
        let mut at = from;
        loop {
            let woke = self.log.1.notified();
            {
                let lines = self.log.0.lock().unwrap();
                while at < lines.len() {
                    if let Some(found) = pick(&lines[at]) {
                        return Some((at, found));
                    }
                    at += 1;
                }
            }
            if tokio::time::timeout_at(deadline, woke).await.is_err() {
                return None;
            }
        }
    }

    async fn reply(&self, id: i64, limit: Duration) -> Option<Result<Value, Value>> {
        let found = self
            .find(0, limit, |v| {
                (v.get("id") == Some(&json!(id)) && v.get("method").is_none()).then(|| {
                    match v.get("error") {
                        Some(e) => Err(e.clone()),
                        None => Ok(v.get("result").cloned().unwrap_or(Value::Null)),
                    }
                })
            })
            .await;
        found.map(|(_, r)| r)
    }

    async fn call(&mut self, m: &str, p: Value) -> Result<Value, Value> {
        let id = self.send(m, p).await;
        self.reply(id, STEP).await.unwrap_or_else(|| panic!("{m}: no answer in {STEP:?}"))
    }

    fn len(&self) -> usize {
        self.log.0.lock().unwrap().len()
    }

    fn lines(&self) -> Vec<Value> {
        self.log.0.lock().unwrap().clone()
    }
}

/// The text of an `agent_message_chunk` in a notification, as a session update or an event.
fn chunk_text(v: &Value) -> Option<&str> {
    let p = v.get("params")?;
    let update = p.get("update").or_else(|| p.pointer("/msg/params/update"))?;
    (update.get("sessionUpdate")?.as_str()? == "agent_message_chunk")
        .then(|| update.pointer("/content/text")?.as_str())
        .flatten()
}

/// A notification's journal sequence: `_acpmux/event`'s `seq` or a session update's
/// `_meta.acpmux.seq`.
fn journal_seq(v: &Value) -> Option<u64> {
    let m = v.get("method")?.as_str()?;
    let p = v.get("params")?;
    match m {
        method::MUX_EVENT => p.get("seq")?.as_u64(),
        method::SESSION_UPDATE => p.pointer("/_meta/acpmux/seq")?.as_u64(),
        _ => None,
    }
}

fn is_ask(v: &Value) -> Option<Value> {
    (v.get("method")? == method::MUX_PERMISSION_PENDING).then(|| v["params"].clone())
}

// ------------------------------------------------------------------ carriers

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Cut {
    /// The carrier's connections close and new ones are refused.
    Reset,
    /// Bytes stop both ways and nothing closes; new connections hang until it is restored.
    BlackHole,
}

trait Carrier: Send + Sync {
    fn cut(&self, how: Cut);
    fn restore(&self);
}

/// A TCP proxy in front of B's WebSocket listener: what a direct link or the ssh `-W` forward
/// rides on.
struct TcpCarrier {
    addr: SocketAddr,
    up: watch::Sender<bool>,
    /// Bumped by each cut: the connections of an earlier generation end (reset) or go silent.
    epoch: watch::Sender<(u64, Cut)>,
}

impl TcpCarrier {
    async fn start(target: SocketAddr) -> Arc<Self> {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        let me = Arc::new(Self {
            addr,
            up: watch::channel(true).0,
            epoch: watch::channel((0, Cut::Reset)).0,
        });
        let weak = Arc::downgrade(&me);
        tokio::spawn(async move {
            while let Ok((conn, _)) = listener.accept().await {
                let Some(me) = weak.upgrade() else { return };
                let (up, epoch) = (me.up.subscribe(), me.epoch.subscribe());
                tokio::spawn(pump(conn, target, up, epoch));
            }
        });
        me
    }
}

async fn pump(
    mut conn: TcpStream,
    target: SocketAddr,
    mut up: watch::Receiver<bool>,
    mut epoch: watch::Receiver<(u64, Cut)>,
) {
    if !*up.borrow_and_update() {
        if epoch.borrow().1 == Cut::Reset {
            return;
        }
        // A black hole: the dial hangs, as a SYN into a dropped network does, and goes through
        // once the network is back (the dialer's retransmission).
        if up.wait_for(|u| *u).await.is_err() {
            return;
        }
    }
    let born = epoch.borrow_and_update().0;
    let Ok(mut far) = TcpStream::connect(target).await else { return };
    let how = tokio::select! {
        _ = tokio::io::copy_bidirectional(&mut conn, &mut far) => return,
        cut = epoch.wait_for(|(n, _)| *n != born) => match cut {
            Ok(cut) => cut.1,
            Err(_) => return,
        },
    };
    drop(far);
    if how == Cut::BlackHole {
        // Nothing reaches either end again, and this end is never closed by the carrier.
        let mut sink = [0u8; 16 * 1024];
        while matches!(conn.read(&mut sink).await, Ok(n) if n > 0) {}
    }
}

impl Carrier for TcpCarrier {
    fn cut(&self, how: Cut) {
        self.up.send_replace(false);
        self.epoch.send_modify(|(n, c)| {
            *n += 1;
            *c = how;
        });
    }

    fn restore(&self) {
        self.up.send_replace(true);
    }
}

/// A UDP relay between the two WireGuard sockets: A's peer `b` and B's peer `a` both point at
/// it. A cut drops every datagram; WireGuard has nothing to reset.
struct UdpCarrier {
    /// A sends here (A's endpoint for `b`).
    a_side: SocketAddr,
    up: Arc<AtomicBool>,
}

impl UdpCarrier {
    async fn bind() -> (Arc<UdpSocket>, Arc<UdpSocket>) {
        let a = UdpSocket::bind("127.0.0.1:0").await.unwrap();
        let b = UdpSocket::bind("127.0.0.1:0").await.unwrap();
        (Arc::new(a), Arc::new(b))
    }

    fn start(a: Arc<UdpSocket>, b: Arc<UdpSocket>, b_listen: SocketAddr) -> Arc<Self> {
        let up = Arc::new(AtomicBool::new(true));
        let last_a: Arc<Mutex<Option<SocketAddr>>> = Arc::default();
        let me = Arc::new(Self { a_side: a.local_addr().unwrap(), up: up.clone() });
        let (a2, b2, up2, last2) = (a.clone(), b.clone(), up.clone(), last_a.clone());
        tokio::spawn(async move {
            let mut buf = vec![0u8; 65536];
            while let Ok((n, from)) = a2.recv_from(&mut buf).await {
                *last2.lock().unwrap() = Some(from);
                if up2.load(Ordering::SeqCst) {
                    let _ = b2.send_to(&buf[..n], b_listen).await;
                }
            }
        });
        tokio::spawn(async move {
            let mut buf = vec![0u8; 65536];
            while let Ok((n, _)) = b.recv_from(&mut buf).await {
                let to = *last_a.lock().unwrap();
                if let Some(to) = to
                    && up.load(Ordering::SeqCst)
                {
                    let _ = a.send_to(&buf[..n], to).await;
                }
            }
        });
        me
    }
}

impl Carrier for UdpCarrier {
    fn cut(&self, _how: Cut) {
        self.up.store(false, Ordering::SeqCst);
    }

    fn restore(&self) {
        self.up.store(true, Ordering::SeqCst);
    }
}

// ------------------------------------------------------------------ the two daemons

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Route {
    /// `ws://` straight to B, through a TCP carrier.
    Ws,
    /// `ssh://`: the stand-in ssh's `-W` forward, through a TCP carrier.
    Ssh,
    /// The labs WireGuard transport, through a UDP carrier; the peer URL itself is unreachable.
    Wg,
    /// WireGuard first, `ssh://` as the peer URL behind it (`connect_once`'s order).
    WgThenSsh,
}

/// A second carrier a row leaves up while it cuts the first.
type Spare = Option<Arc<dyn Carrier>>;

struct World {
    a: Arc<Hub>,
    /// Kept alive for the row: B owns the agent.
    _b: Arc<Hub>,
    /// The carrier this row cuts.
    carrier: Arc<dyn Carrier>,
    /// The ssh carrier of `WgThenSsh` (the one the link should move to).
    _spare: Spare,
    scratch: PathBuf,
    _transports: Vec<Arc<Transport>>,
}

impl Drop for World {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.scratch);
    }
}

async fn world(tag: &str, route: Route) -> World {
    let scratch = std::env::temp_dir().join(format!("acf-{tag}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&scratch);
    setup(&scratch);
    // B: owns the agent and serves WebSocket with a peer token.
    let b_cfg = config();
    let b = Hub::new(b_cfg.clone(), store(&b_cfg));
    let auth_home = scratch.join("b-auth");
    let auth = PeerAuth::create(&auth_home).unwrap();
    let peer_token =
        std::fs::read_to_string(acpmux::server::peer_auth::token_path(&auth_home)).unwrap();
    let peer_token = peer_token.trim().to_owned();
    let listener = bind_ws("127.0.0.1:0").await.unwrap();
    let b_ws = listener.local_addr().unwrap();
    let ws_auth = WsAuth { local_app: None, peer: Some(Arc::new(auth)) };
    tokio::spawn(serve_ws_with(b.clone(), listener, "tok".into(), ws_auth));
    let mut cb = Client::new(&b).await;
    let meta = json!({"acpmux": {"name": "lane"}});
    cb.call(
        method::SESSION_NEW,
        json!({"cwd": std::env::temp_dir(), "mcpServers": [], "_meta": meta}),
    )
    .await
    .unwrap();

    let mut a_cfg = config();
    let mut transports = Vec::new();
    let (carrier, spare, a): (Arc<dyn Carrier>, Spare, Arc<Hub>) = match route {
        Route::Ws | Route::Ssh => {
            let tcp = TcpCarrier::start(b_ws).await;
            let url = match route {
                Route::Ws => format!("ws://{}", tcp.addr),
                _ => format!("ssh://box.invalid:{}", tcp.addr.port()),
            };
            let a = Hub::new(a_cfg.clone(), store(&a_cfg));
            a.add_peer("b", &url, Some("tok".into()), Some(peer_token.clone()), false)
                .await
                .unwrap();
            (tcp, None, a)
        }
        Route::Wg | Route::WgThenSsh => {
            let (a_home, b_home) = (scratch.join("a-wg"), scratch.join("b-wg"));
            let a_key = acpmux::cli::mesh_node_key::load_or_create_at(&a_home).unwrap();
            let b_key = acpmux::cli::mesh_node_key::load_or_create_at(&b_home).unwrap();
            let (a_side, b_side) = UdpCarrier::bind().await;
            let a_service: SocketAddr = "10.77.0.1:4100".parse().unwrap();
            let b_service: SocketAddr = "10.77.0.2:4100".parse().unwrap();
            let wg_peer =
                |key: String, endpoint: SocketAddr, address: SocketAddr, url: String| PeerConfig {
                    link_host: None,
                    url,
                    wireguard: Some(StaticPeer {
                        public_key: key,
                        endpoint: endpoint.to_string(),
                        address,
                    }),
                    token: Some("tok".into()),
                    peer_token: Some(peer_token.clone()),
                    vm_boundary: false,
                    github_broker: false,
                    group: None,
                };
            let mut b_wg = config();
            b_wg.transport.wireguard = true;
            b_wg.transport.wireguard_static =
                Some(StaticConfig { listen: "127.0.0.1:0".parse().unwrap(), address: b_service });
            b_wg.peers.insert(
                "a".into(),
                wg_peer(
                    a_key.public_key_b64(),
                    b_side.local_addr().unwrap(),
                    a_service,
                    "ws://127.0.0.1:1".into(),
                ),
            );
            let b_transport = Transport::start(&b_wg, &b_home, b_ws).await.unwrap().unwrap();
            let udp = UdpCarrier::start(a_side.clone(), b_side.clone(), b_transport.local_addr());
            let (url, spare): (String, Spare) = match route {
                Route::WgThenSsh => {
                    let tcp = TcpCarrier::start(b_ws).await;
                    (format!("ssh://box.invalid:{}", tcp.addr.port()), Some(tcp))
                }
                // Nothing listens there: with WireGuard cut, the link has no other way.
                _ => ("ws://127.0.0.1:1".into(), None),
            };
            a_cfg.transport.wireguard = true;
            a_cfg.transport.wireguard_static =
                Some(StaticConfig { listen: "127.0.0.1:0".parse().unwrap(), address: a_service });
            a_cfg
                .peers
                .insert("b".into(), wg_peer(b_key.public_key_b64(), udp.a_side, b_service, url));
            // A's transport bridges incoming streams to A's own listener, which this row never
            // dials; any loopback port does.
            let a_transport = Transport::start(&a_cfg, &a_home, "127.0.0.1:9".parse().unwrap())
                .await
                .unwrap()
                .unwrap();
            let a = Hub::new_with_wireguard(a_cfg.clone(), store(&a_cfg), a_transport.clone());
            transports = vec![a_transport, b_transport];
            (udp, spare, a)
        }
    };
    let w = World { a, _b: b, carrier, _spare: spare, scratch, _transports: transports };
    w.until_state("connected", STEP).await.expect("peer b never connected");
    w
}

impl World {
    fn state(&self) -> String {
        self.a
            .peers()
            .into_iter()
            .next()
            .map(|p| p["state"].as_str().unwrap_or("").to_owned())
            .unwrap_or_default()
    }

    /// Waits for A's link to `b` to be in `state` (sampled each 5 ms: no notice says each change).
    async fn until_state(&self, state: &str, limit: Duration) -> Option<Instant> {
        let deadline = Instant::now() + limit;
        loop {
            if self.state() == state {
                return Some(Instant::now());
            }
            if Instant::now() >= deadline {
                return None;
            }
            tokio::time::sleep(Duration::from_millis(5)).await;
        }
    }

    async fn until_not(&self, state: &str, limit: Duration) -> Option<Instant> {
        let deadline = Instant::now() + limit;
        loop {
            if self.state() != state {
                return Some(Instant::now());
            }
            if Instant::now() >= deadline {
                return None;
            }
            tokio::time::sleep(Duration::from_millis(5)).await;
        }
    }
}

/// Samples A's link state each 5 ms into a list of distinct states, until dropped.
/// Each state A's link to `b` took, with when it was first seen.
type Seen = Arc<Mutex<Vec<(String, Instant)>>>;

/// A's link state now, if A has a peer.
fn link_state(a: &Hub) -> Option<String> {
    a.peers().into_iter().next().map(|p| p["state"].as_str().unwrap_or("").to_owned())
}

/// The state list starts with the state at the call, read before it returns: the spawned
/// sampler can first run after the caller cut the carrier, so it must not be the one that
/// records the state before the cut.
fn record_states(a: Arc<Hub>) -> (Seen, tokio::task::JoinHandle<()>) {
    let first = link_state(&a).map(|state| (state, Instant::now()));
    let seen: Seen = Arc::new(Mutex::new(first.into_iter().collect()));
    let out = seen.clone();
    let task = tokio::spawn(async move {
        loop {
            let now = link_state(&a);
            if let Some(now) = now {
                let mut s = out.lock().unwrap();
                if s.last().map(|(state, _)| state) != Some(&now) {
                    s.push((now, Instant::now()));
                }
            }
            tokio::time::sleep(Duration::from_millis(5)).await;
        }
    });
    (seen, task)
}

// ------------------------------------------------------------------ one row

/// What became of the prompt sent while the carrier was down.
#[derive(Debug)]
enum Outage {
    /// Refused at once, with this error.
    Failed(Value),
    /// Held, and answered after the reconnect.
    Ran(Value),
}

struct Row {
    tag: &'static str,
    route: Route,
    cut: Cut,
    /// Restore the cut carrier once the link left `connected`. False: it stays down, and the
    /// link has to move to another carrier.
    restore: bool,
    /// The outage prompt must be held and run (an outbox for pane prompts), not refused.
    outage_must_run: bool,
    /// The ask that waited across the cut must reach A's client again after the reconnect.
    reshow_required: bool,
}

/// A row's times: the cut noticed, the link ready again after it left `connected`, and the
/// whole outage from the cut.
#[derive(Clone)]
struct Times {
    detect: Duration,
    failover: Duration,
    total: Duration,
    /// The row's `downReason` once the link was back: why the route went down.
    down_reason: Option<String>,
}

/// A's `downReason` for `b` now (`_acpmux/peers`), if it names one.
fn down_reason(a: &Hub) -> Option<String> {
    a.peers().into_iter().next().and_then(|p| p["downReason"].as_str().map(str::to_owned))
}

/// Every word `downReason` may take (`DialFail`).
const DOWN_REASONS: [&str; 5] = ["timeout", "refused", "auth", "pathChanged", "unreachable"];

async fn run(row: Row) -> Times {
    let w = world(row.tag, row.route).await;
    let gate = w.scratch.join("gate");
    let mut ca = Client::new(&w.a).await;
    ca.call(method::MUX_ATTACH, json!({"session": "b/lane", "limit": 0})).await.unwrap();
    let text = format!("carrier-fault: {TOTAL} {KILL_AT} {}", gate.display());
    let turn = ca
        .send(
            method::SESSION_PROMPT,
            json!({"sessionId": "b/lane", "prompt": [{"type": "text", "text": text}]}),
        )
        .await;
    // Chunk KILL_AT and the ask after it reached A's client: the carrier goes now.
    let last = format!("ev-{KILL_AT} ");
    ca.find(0, STEP, |v| (chunk_text(v) == Some(last.as_str())).then_some(()))
        .await
        .unwrap_or_else(|| panic!("{}: chunk {KILL_AT} never reached A's client", row.tag));
    let (_, ask) = ca.find(0, STEP, is_ask).await.unwrap_or_else(|| panic!("{}: no ask", row.tag));
    let (states, sampler) = record_states(w.a.clone());
    let cut_at = Instant::now();
    w.carrier.cut(row.cut);
    std::fs::write(&gate, b"go").unwrap();
    let left = w.until_not("connected", DETECT_BOUND + STEP).await;
    let left = left.unwrap_or_else(|| panic!("{}: the link never left connected", row.tag));
    let detect = left - cut_at;

    let mark = ca.len();

    // A prompt while the carrier is down: refused with a named error, or held.
    let mut cc = Client::new(&w.a).await;
    let outage_text = format!("outage-{}", row.tag);
    let outage = cc
        .send(
            method::SESSION_PROMPT,
            json!({"sessionId": "b/lane", "prompt": [{"type": "text", "text": outage_text}]}),
        )
        .await;
    let early = cc.reply(outage, OUTAGE_HOLD).await;
    // A black hole lifts once A's link gave up on it (`downReason` names why), so the row
    // redials, as its name says. Lifted before acpmux's own deadline, a WireGuard tunnel's TCP
    // can retransmit and the link heal in place from `degraded`: then nothing redialed, and
    // whether it did was a race between the retransmit and the request probe (#56198).
    if matches!(row.cut, Cut::BlackHole) && row.restore {
        let deadline = Instant::now() + DETECT_BOUND + STEP;
        while down_reason(&w.a).is_none() {
            assert!(
                Instant::now() < deadline,
                "{}: the black hole never took the link down",
                row.tag
            );
            tokio::time::sleep(Duration::from_millis(5)).await;
        }
    }
    let restored_at = Instant::now();
    if row.restore {
        w.carrier.restore();
    }
    let back = w.until_state("connected", REDIAL_BOUND + STEP).await;
    let back = back.unwrap_or_else(|| panic!("{}: the link never came back", row.tag));
    let redial = back - restored_at;

    // The ask that was waiting is shown again after the reconnect; the answer reaches the agent.
    // Until it is (`reshow_required`), the client answers the ask it already holds.
    let reshown = ca.find(mark, RESHOW_WAIT, is_ask).await.map(|(_, a)| a);
    assert!(
        reshown.is_some() || !row.reshow_required,
        "{}: the waiting ask was not shown again after the reconnect (first: {ask})",
        row.tag
    );
    let ask_seen = if reshown.is_some() { "reshown" } else { "held" };
    let again = reshown.unwrap_or_else(|| ask.clone());
    let session = again["sessionId"].as_str().unwrap().to_owned();
    let answer =
        json!({"sessionId": session, "permissionId": again["permissionId"], "optionId": "no"});
    ca.call(method::MUX_PERMISSION_RESPOND, answer)
        .await
        .unwrap_or_else(|e| panic!("{}: answer refused: {e}", row.tag));
    let ended =
        ca.reply(turn, STEP).await.unwrap_or_else(|| panic!("{}: the turn never ended", row.tag));
    assert_eq!(
        ended.as_ref().map(|r| r["stopReason"].clone()),
        Ok(json!("end_turn")),
        "{}: {ended:?}",
        row.tag
    );

    let outage = match early {
        Some(Err(e)) => Outage::Failed(e),
        Some(Ok(r)) => Outage::Ran(r),
        None => match cc.reply(outage, STEP).await {
            Some(Ok(r)) => Outage::Ran(r),
            Some(Err(e)) => Outage::Failed(e),
            None => panic!("{}: the outage prompt never got an answer", row.tag),
        },
    };
    sampler.abort();
    // The state at the end, read here, for the same reason as the first one: under load the
    // sampler may not run between the link coming back and its abort.
    if let Some(now) = link_state(&w.a) {
        let mut seen = states.lock().unwrap();
        if seen.last().map(|(state, _)| state) != Some(&now) {
            seen.push((now, Instant::now()));
        }
    }
    let timed = states.lock().unwrap().clone();
    // When the link went down (the link dropped, as against slow: a reset, the silence budget
    // running out, or a move to another path), if it did.
    let dropped = timed
        .iter()
        .find(|(state, _)| state == "reconnecting" || state == "restarting")
        .map(|(_, at)| *at);
    let states: Vec<String> = timed.into_iter().map(|(state, _)| state).collect();

    // The turn's answer can reach the client before the chunks the peer's link forwards ahead of
    // it are read out: wait for the last one ("chose X") before counting.
    ca.find(0, STEP, |v| chunk_text(v).filter(|t| t.starts_with("chose ")).map(|_| ())).await;
    // Chunks 1..=TOTAL, each once, in order; no journal sequence twice or out of order.
    let lines = ca.lines();
    let numbers: Vec<u64> = lines
        .iter()
        .filter_map(chunk_text)
        .filter_map(|t| t.strip_prefix("ev-")?.trim().parse().ok())
        .collect();
    let want: Vec<u64> = (1..=TOTAL).collect();
    if numbers != want {
        let mut seen: HashMap<u64, usize> = HashMap::new();
        for n in &numbers {
            *seen.entry(*n).or_default() += 1;
        }
        let missing: Vec<_> = want.iter().filter(|n| !seen.contains_key(n)).collect();
        let twice: Vec<_> = seen.iter().filter(|(_, c)| **c > 1).map(|(n, _)| *n).collect();
        panic!(
            "{}: chunks not 1..={TOTAL} once each: {} seen, missing {missing:?}, twice {twice:?}",
            row.tag,
            numbers.len()
        );
    }
    let seqs: Vec<u64> = lines.iter().filter_map(journal_seq).collect();
    for pair in seqs.windows(2) {
        assert!(
            pair[0] < pair[1],
            "{}: journal sequence {} came after {}",
            row.tag,
            pair[1],
            pair[0]
        );
    }
    let chose: Vec<_> =
        lines.iter().filter_map(chunk_text).filter(|t| t.starts_with("chose ")).collect();
    assert_eq!(chose, vec!["chose no"], "{}: the answer did not reach the agent once", row.tag);

    // The outage prompt: once, or refused by name.
    let echo = format!("echo: {outage_text}");
    let ran = |c: &Client| c.lines().iter().filter_map(chunk_text).filter(|t| *t == echo).count();
    let outcome = match &outage {
        Outage::Failed(e) => {
            assert!(
                !row.outage_must_run,
                "{}: the outage prompt was refused, not held: {e}",
                row.tag
            );
            let named = e
                .pointer("/data/reason")
                .and_then(Value::as_str)
                .map(str::to_owned)
                .or_else(|| e.get("message").and_then(Value::as_str).map(str::to_owned));
            assert!(
                named.as_deref().is_some_and(|n| !n.is_empty()),
                "{}: unnamed refusal {e}",
                row.tag
            );
            assert_eq!(ran(&ca), 0, "{}: a refused outage prompt ran", row.tag);
            format!("refused({})", named.unwrap())
        }
        Outage::Ran(r) => {
            assert_eq!(r["stopReason"], "end_turn", "{}: {r}", row.tag);
            ca.find(0, STEP, |v| (chunk_text(v) == Some(echo.as_str())).then_some(())).await;
            assert_eq!(ran(&ca), 1, "{}: the outage prompt did not run exactly once", row.tag);
            "ran-once".to_owned()
        }
    };

    // connected -> (degraded) -> reconnecting -> connected.
    assert_eq!(states.first().map(String::as_str), Some("connected"), "{}: {states:?}", row.tag);
    assert_eq!(states.last().map(String::as_str), Some("connected"), "{}: {states:?}", row.tag);
    // A reset reads as `reconnecting` at once. A black hole first reads as `degraded` (a missed
    // ping), and the outage prompt redials at once (`Peer::want`), so its link can be ready again
    // before the silence budget runs out and never read as `reconnecting`.
    assert!(
        states.iter().any(|s| s == "reconnecting" || s == "degraded"),
        "{}: never left connected: {states:?}",
        row.tag
    );
    // From the drop (else from leaving `connected`) to ready again: the redial, without the
    // time the silence budget takes to find a black hole.
    let failover = back.saturating_duration_since(dropped.unwrap_or(left));
    let why = down_reason(&w.a);
    assert!(
        why.as_deref().is_none_or(|why| DOWN_REASONS.contains(&why)),
        "{}: downReason {why:?} is not a DialFail word",
        row.tag
    );
    eprintln!(
        "carrier_faults row={} cut={:?} detect_ms={} redial_ms={} failover_ms={} total_ms={} states={} ask={ask_seen} outage_prompt={} down_reason={}",
        row.tag,
        row.cut,
        detect.as_millis(),
        redial.as_millis(),
        failover.as_millis(),
        (back - cut_at).as_millis(),
        states.join(">"),
        outcome,
        why.as_deref().unwrap_or("null")
    );
    // A black hole ends on acpmux's own deadline: the link says `timeout`, or `pathChanged`
    // when it moved to another carrier.
    if matches!(row.cut, Cut::BlackHole) {
        assert!(
            matches!(why.as_deref(), Some("timeout" | "pathChanged")),
            "{}: a black hole read downReason {why:?}",
            row.tag
        );
    }
    assert!(detect <= DETECT_BOUND, "{}: the cut took {detect:?} to notice", row.tag);
    assert!(redial <= REDIAL_BOUND, "{}: the redial took {redial:?}", row.tag);
    Times { detect, failover, total: back - cut_at, down_reason: why }
}

// ------------------------------------------------------------------ rows that pass today

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn ws_reset_mid_turn_redials_and_replays_after_seq() {
    run(Row {
        tag: "ws-reset",
        route: Route::Ws,
        cut: Cut::Reset,
        restore: true,
        outage_must_run: false,
        reshow_required: false,
    })
    .await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn ssh_reset_mid_turn_redials_and_replays_after_seq() {
    run(Row {
        tag: "ssh-reset",
        route: Route::Ssh,
        cut: Cut::Reset,
        restore: true,
        outage_must_run: false,
        reshow_required: false,
    })
    .await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn ssh_black_hole_mid_turn_redials_and_replays_after_seq() {
    run(Row {
        tag: "ssh-hole",
        route: Route::Ssh,
        cut: Cut::BlackHole,
        restore: true,
        outage_must_run: false,
        reshow_required: false,
    })
    .await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn wireguard_black_hole_mid_turn_redials_and_replays_after_seq() {
    run(Row {
        tag: "wg-hole",
        route: Route::Wg,
        cut: Cut::BlackHole,
        restore: true,
        outage_must_run: false,
        reshow_required: false,
    })
    .await;
}

// ------------------------------------------------------------------ rows that wait for a fix

/// How long the link may take from dropping its dead WireGuard path to being ready on ssh: ssh
/// is a live path, probed all along, so the redial dials it first, with no WireGuard connect
/// deadline before it (at most the 250 ms stagger behind a dead path), then the ssh dial, the
/// handshake and the replay of the turn so far (an ssh redial after a reset takes about 50 ms
/// here). Before the carrier list the whole outage was 33.3 s: each redial waited out
/// WireGuard's 30 s connect deadline first. Finding the black hole (the silence budget) is not
/// counted; sending on both paths while one is in doubt is what shortens that.
const WG_TO_SSH_FAILOVER: Duration = Duration::from_millis(250 + 1_000);

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn wireguard_dies_mid_turn_and_the_link_moves_to_ssh() {
    let times = run(Row {
        tag: "wg-to-ssh",
        route: Route::WgThenSsh,
        cut: Cut::BlackHole,
        restore: false,
        outage_must_run: false,
        reshow_required: false,
    })
    .await;
    assert_eq!(times.down_reason.as_deref(), Some("pathChanged"), "wg-to-ssh: downReason");
    assert!(
        times.failover <= WG_TO_SSH_FAILOVER,
        "wg-to-ssh: the link took {:?} to move to ssh (cut noticed after {:?}, {:?} in all)",
        times.failover,
        times.detect,
        times.total
    );
}

/// A peer whose port refuses: the dial's `ConnectionRefused` reads as `downReason: "refused"`
/// in its `_acpmux/peers` row (typed from the I/O error, not its text), and `cause` still says
/// the peer is down.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_peer_whose_port_refuses_reads_down_reason_refused() {
    let scratch = std::env::temp_dir().join(format!("acf-refused-{}", std::process::id()));
    setup(&scratch);
    // A port nothing listens on: bound, then let go.
    let port = TcpListener::bind("127.0.0.1:0").await.unwrap().local_addr().unwrap().port();
    let cfg = config();
    let a = Hub::new(cfg.clone(), store(&cfg));
    a.add_peer("b", &format!("ws://127.0.0.1:{port}"), Some("tok".into()), None, false)
        .await
        .unwrap();
    let deadline = Instant::now() + STEP;
    let row = loop {
        let row = a.peers().into_iter().next().expect("peer b listed");
        if row["downReason"].is_string() || Instant::now() >= deadline {
            break row;
        }
        tokio::time::sleep(Duration::from_millis(5)).await;
    };
    assert_eq!(row["downReason"], json!("refused"), "{row}");
    assert_eq!(row["cause"], json!("peerDown"), "{row}");
    assert_eq!(row["connected"], json!(false), "{row}");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[ignore = "needs an outbox for pane prompts (audit fix 5): a session/prompt not yet accepted when the \
            link drops fails peer_unreachable or peer_disconnected instead of waiting for the \
            reconnect and running once under its prompt id"]
async fn a_prompt_sent_during_the_outage_is_held_and_runs_once() {
    run(Row {
        tag: "ssh-held",
        route: Route::Ssh,
        cut: Cut::Reset,
        restore: true,
        outage_must_run: true,
        reshow_required: false,
    })
    .await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[ignore = "needs a hub stream carrier (audit fix 3): the mesh hub relays only mailbox text, so with \
            ssh down for good a live turn cannot go on over the hub, and the link never reconnects"]
async fn ssh_dies_mid_turn_and_the_link_moves_to_the_hub_stream() {
    // Today the hub carries no session stream for the link to move to: with ssh cut for good,
    // the row fails at the redial bound. The fix gives the link the hub as its next carrier.
    run(Row {
        tag: "ssh-to-hub",
        route: Route::Ssh,
        cut: Cut::Reset,
        restore: false,
        outage_must_run: false,
        reshow_required: false,
    })
    .await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[ignore = "needs open asks re-sent on reconnect (audit fix 6, acpmux owns the whole state): the \
            replay resumes after the link's cursor, which is past the ask, so a client attached \
            across the cut is never shown the still-open ask again and has to have kept it"]
async fn an_ask_waiting_across_the_cut_is_shown_again_after_the_reconnect() {
    run(Row {
        tag: "ws-reshow",
        route: Route::Ws,
        cut: Cut::Reset,
        restore: true,
        outage_must_run: false,
        reshow_required: true,
    })
    .await;
}

// ------------------------------------------------------------------ the hub relay

/// A mesh hub whose whole service can go down and come back: every call fails while it is down.
#[derive(Default)]
struct OutageHub {
    down: AtomicBool,
    changed: Notify,
    state: Mutex<HubState>,
}

#[derive(Default)]
struct HubState {
    waiting: VecDeque<InMessage>,
    acks: Vec<(String, Ack)>,
    heartbeats: Vec<Heartbeat>,
    /// Successful inbox reads, with when they happened.
    reads: Vec<Instant>,
    keys: HashMap<String, String>,
    receipts: HashMap<String, Receipt>,
}

impl OutageHub {
    fn set_down(&self, down: bool) {
        self.down.store(down, Ordering::SeqCst);
        self.changed.notify_waiters();
    }

    fn unavailable(&self) -> Result<(), HubError> {
        if self.down.load(Ordering::SeqCst) {
            return Err(HubError::unavailable("the hub is down"));
        }
        Ok(())
    }

    async fn until(&self, what: &str, done: impl Fn(&HubState) -> bool) -> Instant {
        let deadline = Instant::now() + STEP;
        loop {
            let changed = self.changed.notified();
            if done(&self.state.lock().unwrap()) {
                return Instant::now();
            }
            if tokio::time::timeout_at(deadline, changed).await.is_err() {
                panic!("timed out waiting for {what}");
            }
        }
    }

    fn queue(&self, message_id: &str, to: &str, body: &str) {
        let message = InMessage {
            message_id: message_id.into(),
            kind: Kind::Prompt,
            op: None,
            mode: acpmux::mesh::Mode::TurnEnd,
            to: Target { name: Some(to.into()), ..Target::default() },
            from: Sender {
                name: Some("lane-a".into()),
                daemon_id: Some("inst_a".into()),
                ..Sender::default()
            },
            body: body.into(),
            attempt: 1,
            start_work: None,
            state: Some("queued".into()),
            subject: None,
        };
        self.state.lock().unwrap().waiting.push_back(message);
        self.changed.notify_waiters();
    }
}

impl MeshHub for OutageHub {
    fn inbox(&self, wait: Duration, max: usize) -> BoxFuture<'_, Result<Vec<InMessage>, HubError>> {
        Box::pin(async move {
            let deadline = Instant::now() + wait;
            loop {
                let changed = self.changed.notified();
                self.unavailable()?;
                let leased: Vec<_> = {
                    let mut s = self.state.lock().unwrap();
                    let n = max.min(s.waiting.len());
                    let leased: Vec<_> = s.waiting.drain(..n).collect();
                    if !leased.is_empty() {
                        s.reads.push(Instant::now());
                    }
                    leased
                };
                if !leased.is_empty() {
                    self.changed.notify_waiters();
                    return Ok(leased);
                }
                if tokio::time::timeout_at(deadline, changed).await.is_err() {
                    self.state.lock().unwrap().reads.push(Instant::now());
                    self.changed.notify_waiters();
                    return Ok(Vec::new());
                }
            }
        })
    }

    fn ack<'a>(&'a self, id: &'a str, ack: &'a Ack) -> BoxFuture<'a, Result<(), HubError>> {
        Box::pin(async move {
            self.unavailable()?;
            self.state.lock().unwrap().acks.push((id.to_owned(), ack.clone()));
            self.changed.notify_waiters();
            Ok(())
        })
    }

    fn heartbeat<'a>(
        &'a self,
        beat: &'a Heartbeat,
    ) -> BoxFuture<'a, Result<HeartbeatReply, HubError>> {
        Box::pin(async move {
            self.unavailable()?;
            self.state.lock().unwrap().heartbeats.push(beat.clone());
            self.changed.notify_waiters();
            Ok(HeartbeatReply { daemon_id: "inst_b".into(), ttl_seconds: 90 })
        })
    }

    fn send<'a>(&'a self, m: &'a OutMessage) -> BoxFuture<'a, Result<Receipt, HubError>> {
        Box::pin(async move {
            self.unavailable()?;
            m.validate().map_err(HubError::refused)?;
            let id = {
                let s = self.state.lock().unwrap();
                if let Some(id) = s.keys.get(&m.idempotency_key) {
                    return Ok(s.receipts[id].clone());
                }
                format!("msg_{:032x}", s.keys.len() + 1)
            };
            let receipt = Receipt {
                message_id: id.clone(),
                state: "queued".into(),
                to: m.to.clone(),
                attempt: 0,
                prompt_id: None,
                detail: None,
                created_at: 1000,
                leased_until: None,
                acked_at: None,
                delivered_at: None,
                read_at: None,
                read_by: None,
                acked_by: None,
                resolution: None,
                start_work: None,
                result: None,
            };
            {
                let mut s = self.state.lock().unwrap();
                s.keys.insert(m.idempotency_key.clone(), id.clone());
                s.receipts.insert(id.clone(), receipt.clone());
            }
            self.queue(&id, m.to.name.as_deref().unwrap_or_default(), &m.body);
            Ok(receipt)
        })
    }

    fn receipt<'a>(&'a self, id: &'a str) -> BoxFuture<'a, Result<Receipt, HubError>> {
        Box::pin(async move {
            self.unavailable()?;
            let s = self.state.lock().unwrap();
            s.receipts.get(id).cloned().ok_or_else(|| HubError::refused("no such message"))
        })
    }
}

/// The hub carrier as it is today: a mailbox, not a session stream. B's relay runs with the
/// daemon's own timings (`RelayOptions::default`). The hub goes down while a message for a chat on
/// B waits in it: a send from A meanwhile is refused by name, and once the hub is back the waiting
/// message runs exactly once and B's relay reads again within its backoff.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn hub_outage_delivers_a_waiting_message_once_when_the_hub_returns() {
    let scratch = std::env::temp_dir().join(format!("acf-hub-{}", std::process::id()));
    setup(&scratch);
    let a_cfg = config();
    let b_cfg = config();
    let (a, b) = (Hub::new(a_cfg.clone(), store(&a_cfg)), Hub::new(b_cfg.clone(), store(&b_cfg)));
    let mut on_b = Client::new(&b).await;
    let meta = json!({"acpmux": {"name": "dep-land"}});
    let made = on_b
        .call(
            method::SESSION_NEW,
            json!({"cwd": std::env::temp_dir(), "mcpServers": [], "_meta": meta}),
        )
        .await
        .unwrap();
    let session = made["sessionId"].as_str().unwrap().to_owned();
    let fake = Arc::new(OutageHub::default());
    let relay =
        MeshRelay::start(&b, fake.clone(), Arc::new(RefuseControl), RelayOptions::default());
    fake.until("B's heartbeat", |s| s.heartbeats.iter().any(|h| !h.sessions.is_empty())).await;
    let _ = a.mesh.set(fake.clone());

    // The hub goes down while B's relay long-polls it; a message for B's chat waits in it.
    let cut_at = Instant::now();
    fake.set_down(true);
    fake.queue("msg_waiting", "dep-land", "relayed while the hub was down");
    let mut sender = Client::new(&a).await;
    let request = json!({"request": {
        "sessionId": "dep-land",
        "prompt": [{"type": "text", "text": "sent while the hub was down"}],
        "_meta": {"acpmux": {"promptId": "prompt-outage", "steer": false}},
    }});
    // Refused by name, or kept by A's outbox (`hub/outbox.rs`) to post once the hub is back.
    let sent = sender.call(method::MUX_SEND_QUEUE, request).await;
    let outage_send = match &sent {
        Ok(r) => format!("kept({})", r["deliveryId"].as_str().unwrap_or_default()),
        Err(e) => {
            let reason = e.pointer("/data/reason").and_then(Value::as_str).unwrap_or_default();
            assert!(!reason.is_empty(), "a send during the outage was refused without a name: {e}");
            format!("refused({reason})")
        }
    };
    let turns = if sent.is_ok() { 2 } else { 1 };
    // Long enough for B's relay to meet the outage and back off once.
    tokio::time::sleep(OUTAGE_HOLD).await;
    let restored_at = Instant::now();
    fake.set_down(false);
    let read = fake
        .until("B's relay reads the hub again", |s| s.acks.iter().any(|(m, _)| m == "msg_waiting"))
        .await;
    let mut info = Value::Null;
    let deadline = Instant::now() + STEP;
    while Instant::now() < deadline {
        info = on_b.call(method::MUX_INFO, json!({"sessionId": session})).await.unwrap();
        let ran = info["turnCount"].as_u64().unwrap_or(0) >= turns;
        if ran && info.get("turn").is_none_or(Value::is_null) {
            break;
        }
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    // Each message once: the waiting one, and the outage send if A's outbox kept it.
    if info["turnCount"] != turns {
        let delivery =
            sent.as_ref().ok().and_then(|r| r["deliveryId"].as_str()).unwrap_or_default();
        let status = sender
            .call(method::MUX_SEND_STATUS, json!({"deliveryId": delivery}))
            .await
            .map_or_else(|e| e.to_string(), |v| v.to_string());
        let hub = {
            let s = fake.state.lock().unwrap();
            format!(
                "keys={:?} waiting={} acks={:?}",
                s.keys,
                s.waiting.len(),
                s.acks.iter().map(|(m, a)| format!("{m}:{a:?}")).collect::<Vec<_>>()
            )
        };
        let events = on_b
            .call(method::MUX_EVENTS, json!({"sessionId": session, "afterSeq": 0, "limit": 1000}))
            .await
            .map_or_else(|e| e.to_string(), |v| v.to_string());
        panic!(
            "{turns} messages ran {} turns (outage send {outage_send}); A's status {status}; hub {hub}; B's events {events}; B {info}",
            info["turnCount"]
        );
    }
    let acked = fake.state.lock().unwrap().acks.iter().filter(|(m, _)| m == "msg_waiting").count();
    eprintln!(
        "carrier_faults row=hub-outage cut=Down redeliver_ms={} total_ms={} outage_send={outage_send}",
        (read - restored_at).as_millis(),
        (read - cut_at).as_millis(),
    );
    assert!(acked >= 1, "B never acked the waiting message");
    relay.stop().await;
    let _ = std::fs::remove_dir_all(&scratch);
}

// ------------------------------------------------------------------ the drop sweep

/// Chunks in the sweep's scripted turn; each frame boundary 1..=SWEEP_TOTAL is one cut.
const SWEEP_TOTAL: u64 = 24;

/// Which cut a seed gives an offset: seed 0 resets every offset (the fast default); any other
/// seed picks reset or black hole per offset from a fixed generator, so the same seed cuts the
/// same offsets the same way and fails the same way.
fn sweep_cut(seed: u64, offset: u64) -> Cut {
    if seed == 0 {
        return Cut::Reset;
    }
    let mut x = seed ^ offset.wrapping_mul(0x9E37_79B9_7F4A_7C15);
    x ^= x >> 33;
    x = x.wrapping_mul(0xff51_afd7_ed55_8ccd);
    x ^= x >> 33;
    if x & 1 == 0 { Cut::Reset } else { Cut::BlackHole }
}

/// The chunk texts a client saw, in order.
fn chunks(c: &Client) -> Vec<String> {
    c.lines().iter().filter_map(chunk_text).map(str::to_owned).collect()
}

fn sha(parts: &[String]) -> String {
    use sha2::Digest;
    let mut h = sha2::Sha256::new();
    for p in parts {
        h.update(p.as_bytes());
    }
    format!("{:x}", h.finalize())
}

/// One offset: the scripted turn, the carrier cut once chunk `offset` reached A's client, the
/// rest streamed while it is down, the carrier restored. Passes when A's client saw chunks
/// 1..=SWEEP_TOTAL once each in order with no journal sequence twice or backwards, and the
/// sha of what it was shown equals the sha of B's own journal of the turn (the pass rule
/// cloud-carrier-chaos-staging applies on a real machine: contiguous seq, matching sha).
/// Where one offset's cut fell, so a red names the frame that went missing: the frame the
/// carrier dropped at, the last journal seq A's client held then (A's reconnect cursor only
/// moves on what was delivered, so this is the seq the resume asks after), and the first and
/// last seq A's client got after the cut (the replay plus the live tail).
#[derive(Default)]
struct SweepFacts {
    acked_seq: Option<u64>,
    replayed: Option<(u64, u64)>,
}

async fn sweep_one(seed: u64, offset: u64, cut: Cut) -> (SweepFacts, Result<String, String>) {
    let mut facts = SweepFacts::default();
    let outcome = sweep_run(seed, offset, cut, &mut facts).await;
    (facts, outcome)
}

async fn sweep_run(
    seed: u64,
    offset: u64,
    cut: Cut,
    facts: &mut SweepFacts,
) -> Result<String, String> {
    // The seed is in the tag: both sweeps run at once in one process, and the scratch
    // folder is named for the tag and the pid.
    let tag = format!("sweep-{seed}-{offset}");
    let w = world(&tag, Route::Ws).await;
    let gate = w.scratch.join("gate");
    // B's own journal of the turn: what the agent's machine holds.
    let mut cb = Client::new(&w._b).await;
    cb.call(method::MUX_ATTACH, json!({"session": "lane", "limit": 0})).await.unwrap();
    let mut ca = Client::new(&w.a).await;
    ca.call(method::MUX_ATTACH, json!({"session": "b/lane", "limit": 0})).await.unwrap();
    let text = format!("carrier-sweep: {SWEEP_TOTAL} {offset} {}", gate.display());
    let turn = ca
        .send(
            method::SESSION_PROMPT,
            json!({"sessionId": "b/lane", "prompt": [{"type": "text", "text": text}]}),
        )
        .await;
    let at = format!("ev-{offset} ");
    ca.find(0, STEP, |v| (chunk_text(v) == Some(at.as_str())).then_some(()))
        .await
        .ok_or_else(|| format!("chunk {offset} never reached A's client before the cut"))?;
    let before = ca.len();
    facts.acked_seq = ca.lines().iter().filter_map(journal_seq).max();
    w.carrier.cut(cut);
    std::fs::write(&gate, b"go").unwrap();
    w.until_not("connected", DETECT_BOUND + STEP).await.ok_or("the link never left connected")?;
    if cut == Cut::BlackHole {
        let deadline = Instant::now() + DETECT_BOUND + STEP;
        while down_reason(&w.a).is_none() {
            if Instant::now() >= deadline {
                return Err("the black hole never took the link down".into());
            }
            tokio::time::sleep(Duration::from_millis(5)).await;
        }
    }
    w.carrier.restore();
    w.until_state("connected", REDIAL_BOUND + STEP).await.ok_or("the link never came back")?;
    let ended = ca.reply(turn, STEP).await.ok_or("the turn never ended")?;
    match ended {
        Ok(r) if r["stopReason"] == "end_turn" => {}
        other => return Err(format!("the turn ended {other:?}")),
    }
    let last = format!("ev-{SWEEP_TOTAL} ");
    cb.find(0, STEP, |v| (chunk_text(v) == Some(last.as_str())).then_some(())).await;
    ca.find(0, STEP, |v| (chunk_text(v) == Some(last.as_str())).then_some(())).await;
    let after: Vec<u64> = ca.lines()[before..].iter().filter_map(journal_seq).collect();
    facts.replayed = after.iter().min().zip(after.iter().max()).map(|(a, b)| (*a, *b));
    let (shown, held) = (chunks(&ca), chunks(&cb));
    let numbers: Vec<u64> =
        shown.iter().filter_map(|t| t.strip_prefix("ev-")?.trim().parse().ok()).collect();
    let want: Vec<u64> = (1..=SWEEP_TOTAL).collect();
    if numbers != want {
        let missing: Vec<_> = want.iter().filter(|n| !numbers.contains(n)).collect();
        return Err(format!("chunks not contiguous: shown {numbers:?}, missing {missing:?}"));
    }
    let seqs: Vec<u64> = ca.lines().iter().filter_map(journal_seq).collect();
    if let Some(p) = seqs.windows(2).find(|p| p[0] >= p[1]) {
        return Err(format!("journal sequence {} came after {}", p[1], p[0]));
    }
    let (got, want) = (sha(&shown), sha(&held));
    if got != want {
        return Err(format!(
            "sha {got} shown, {want} in B's journal ({} vs {} chunks)",
            shown.len(),
            held.len()
        ));
    }
    Ok(got)
}

/// The deterministic drop sweep: cuts the carrier at every frame boundary of one scripted turn,
/// one fresh pair of daemons per offset, and lists every offset that lost, doubled or reordered
/// output. Each failing offset is its own repro: `CARRIER_SWEEP_OFFSETS=7 CARRIER_SWEEP_SEED=S
/// cargo test -p acpmux --test carrier_faults carrier_drop_sweep`. `cloud-carrier-chaos-staging`
/// runs this first, so the staging journey only confirms what the sweep proved in process.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn carrier_drop_sweep_every_frame_offset_loses_nothing() {
    let seed: u64 =
        std::env::var("CARRIER_SWEEP_SEED").ok().and_then(|s| s.parse().ok()).unwrap_or(0);
    sweep(seed).await;
}

/// The same sweep under a fixed nonzero seed, so black holes (the link waits out its
/// liveness bound, then redials) are cut at their offsets on every run, not only on request.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn carrier_drop_sweep_seeded_black_holes_lose_nothing() {
    sweep(SWEEP_MIXED_SEED).await;
}

/// The fixed seed of the mixed sweep: it cuts about half the offsets with a black hole.
const SWEEP_MIXED_SEED: u64 = 7;

async fn sweep(seed: u64) {
    let offsets: Vec<u64> = match std::env::var("CARRIER_SWEEP_OFFSETS") {
        Ok(list) if !list.trim().is_empty() => list
            .split(',')
            .map(|s| s.trim().parse().expect("CARRIER_SWEEP_OFFSETS: numbers"))
            .collect(),
        _ => (1..=SWEEP_TOTAL).collect(),
    };
    let mut failed = Vec::new();
    let mut rows = Vec::new();
    for offset in offsets {
        let cut = sweep_cut(seed, offset);
        // Each offset in its own task, so one offset's panic is a row of the list, not the end.
        let (facts, outcome) = match tokio::spawn(sweep_one(seed, offset, cut)).await {
            Ok(r) => r,
            Err(e) => (SweepFacts::default(), Err(format!("panicked: {e}"))),
        };
        let seq = |s: Option<u64>| s.map_or("none".to_owned(), |s| s.to_string());
        let replayed = facts.replayed.map_or("none".to_owned(), |(a, b)| format!("{a}..={b}"));
        let at =
            format!("drop_at=frame{offset} acked_seq={} replayed={replayed}", seq(facts.acked_seq));
        match &outcome {
            Ok(sha) => {
                eprintln!("carrier_sweep seed={seed} offset={offset} cut={cut:?} {at} ok sha={sha}")
            }
            Err(why) => {
                eprintln!("carrier_sweep seed={seed} offset={offset} cut={cut:?} {at} FAIL {why}");
                failed.push(format!("{offset} ({cut:?}, {at}): {why}"));
            }
        }
        rows.push(json!({
            "offset": offset,
            "cut": format!("{cut:?}"),
            "drop_at_frame": offset,
            "acked_seq": facts.acked_seq,
            "replayed": facts.replayed.map(|(a, b)| json!([a, b])),
            "ok": outcome.is_ok(),
            "sha": outcome.as_ref().ok(),
            "error": outcome.as_ref().err(),
        }));
    }
    // CARRIER_SWEEP_REPORT_DIR: each seed's rows as JSON, for the pre-gate of cloud-carrier-chaos-staging.
    if let Ok(dir) = std::env::var("CARRIER_SWEEP_REPORT_DIR") {
        let path = std::path::Path::new(&dir).join(format!("sweep-seed-{seed}.json"));
        let report = json!({"seed": seed, "total": SWEEP_TOTAL, "rows": rows});
        std::fs::write(&path, serde_json::to_vec_pretty(&report).unwrap()).unwrap();
    }
    assert!(
        failed.is_empty(),
        "carrier_sweep seed={seed}: {} offset(s) lost output:\n{}",
        failed.len(),
        failed.join("\n")
    );
}
