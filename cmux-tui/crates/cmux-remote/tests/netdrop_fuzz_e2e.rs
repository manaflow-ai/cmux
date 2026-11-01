#![cfg(unix)]
//! Fuzz catalog row h, network drop: seeded network faults under a remote
//! workspace session (the direct CMXR WebSocket carrier that cmux Cloud and
//! the SSH payload proxy end in), with a real PTY and a TCP tunnel at work.
//!
//! Each seed runs its own daemon, its own TCP proxy and its own client in its
//! own thread. The proxy sits between the test's client and the test's
//! daemon on loopback; no host network, firewall or SSH state changes. Its
//! faults, at seeded times and lengths:
//!
//! - cut: close both sockets of every carrier;
//! - freeze: carry nothing either way, sockets open, below and above the
//!   dead-peer timeouts (bytes are held, as TCP retransmits them, and flow
//!   again when the freeze ends);
//! - halfcut: the same in one direction only;
//! - slow: delay every chunk (latency, not a bandwidth cap);
//! - cutburst: cut again each time a reconnect reaches the proxy.
//!
//! The workload: a PTY prints `SEQ <n>` lines without pause and echoes each
//! numbered input line as `IN <k>`; the client writes numbered input lines
//! with idempotent write IDs, polls a control request, keeps a tunnel open
//! across each fault and opens a fresh one after it.
//!
//! The oracle, per seed:
//! (a) no silent loss: every `SEQ` line arrives once and in order, and every
//!     input line the daemon acknowledged reaches the PTY once, unless the
//!     protocol signals the loss (`OutputTruncated`, `ReplayGap`, or a typed
//!     stream error);
//! (b) visible state: `ConnectionState` leaves `Connected` within
//!     [`STATE_BOUND`] of a cut or of a freeze longer than that, and is
//!     `Connected` again within [`RECONNECT_TIMEOUT`] of the link's return.
//!     A terminal state is allowed only after an outage longer than the
//!     daemon's resume lease, and it must reach the API as a typed error and
//!     stay terminal;
//! (c) no client API call takes longer than [`STALL_BOUND`] while the state
//!     is `Connected` and no fault is active.
//!
//! Each violation prints one `NETDROP VIOLATION` line; the run ends with one
//! `NETDROP SUMMARY` line and fails if any violation was found. A failing
//! seed is shrunk: each of its faults runs alone, and the faults that still
//! fail are printed as its minimal list.
//!
//! This is a measurement, not a CI test: it returns at once (`NETDROP SKIP`)
//! unless the fleet step key contains `netdrop` (`cmux-ci run ... --key
//! fuzz-h-netdrop-<sha12>-<n>`) or `CMUX_NETDROP_FUZZ` is set.
//!
//! The timings are the production mechanisms at test scale (heartbeat every
//! 250 ms with a 1 s answer deadline, WebSocket dead-peer timeout 1.5 s,
//! resume lease 4 s). Not covered: the macOS app's SSH workspace UI over a
//! real ssh connection, and a cmux Cloud VM.

use std::collections::{BTreeMap, BTreeSet};
use std::net::SocketAddr;
use std::path::PathBuf;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex as StdMutex, MutexGuard, PoisonError};
use std::time::Duration;

use bytes::Bytes;
use cmux_remote::client::{ProcessEventStream, WorkspaceClient};
use cmux_remote::connection::{ClientConnection, ClientConnectionConfig, ReconnectPolicy};
use cmux_remote::crypto::{ClientAuthMode, StaticIdentity};
use cmux_remote::daemon::{
    DaemonSessionPolicy, DirectWebSocketOptions, DirectWebSocketServer, RemoteDaemon,
    ServerConnection, WebSocketKeepalive, serve_direct_websocket_with_options,
};
use cmux_remote::identity::AuthDatabase;
use cmux_remote::observability::ConnectionState;
use cmux_remote::provider::{ConnectRequest, DirectWebSocketProvider, TransportProvider};
use cmux_remote::service::{EndpointRole, ServiceMultiplexer, ServiceStream};
use cmux_remote::services::DaemonServices;
use cmux_remote::session::SessionLimits;
use cmux_remote::workspace::WorkspaceService;
use cmux_remote_protocol::{
    ByteString, LanePolicy, ProcessEnvironment, ProcessEvent, ProcessId, ProcessIo,
    ProcessLifetime, PtyEofPolicy, RouteId, RoutePolicy, RpcEvent, Service, ServiceControl,
    SessionId, WorkspaceRequest, WorkspaceResponse,
};
use tempfile::{TempDir, tempdir};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::tcp::{OwnedReadHalf, OwnedWriteHalf};
use tokio::net::{TcpListener, TcpStream};
use tokio::sync::{mpsc, watch};
use tokio::time::Instant;
use url::Url;
use zeroize::Zeroizing;

const MAXIMUM_FRAME_BYTES: usize = 65_535;

/// The daemon pings a silent link after 300 ms and closes it after 1.5 s.
const KEEPALIVE: WebSocketKeepalive = WebSocketKeepalive {
    ping_interval: Duration::from_millis(300),
    dead_peer_timeout: Duration::from_millis(1_500),
};
const HEARTBEAT_INTERVAL: Duration = Duration::from_millis(250);
const HEARTBEAT_TIMEOUT: Duration = Duration::from_millis(1_000);
const ATTEMPT_TIMEOUT: Duration = Duration::from_secs(2);
/// The client's dead-peer detection (one heartbeat interval plus its answer
/// deadline) and 1 s of margin for a loaded runner.
const STATE_BOUND: Duration = Duration::from_millis(250 + 1_000 + 1_000);
/// How long the daemon keeps a disconnected session for a reconnect.
const RESUME_LEASE: Duration = Duration::from_secs(4);
const RECONNECT_TIMEOUT: Duration = Duration::from_secs(10);
const STALL_BOUND: Duration = Duration::from_secs(2);
const TUNNEL_BOUND: Duration = Duration::from_secs(2);
/// How long a terminal state must hold before the harness calls it terminal.
const TERMINAL_HOLD: Duration = Duration::from_secs(2);
const SAMPLE_PERIOD: Duration = Duration::from_millis(10);
const WRITE_PACE: Duration = Duration::from_millis(25);
const PROBE_PACE: Duration = Duration::from_millis(200);
const SEED_TIMEOUT: Duration = Duration::from_secs(45);
/// The shrink pass starts only before this point, so the test stays under a minute.
const SHRINK_START_LIMIT: Duration = Duration::from_secs(36);

/// Fixed seeds: a fleet step cannot pass an environment variable.
const SEEDS: [u64; 4] = [0x4e44_0001, 0x4e44_0002, 0x4e44_0003, 0x4e44_0004];
/// One seed freezes the link longer than the resume lease, so the session ends.
const EXPIRY_SEED: u64 = 0x4e44_00ff;

/// Prints `SEQ <n>` lines until the stop file exists, then `SEQEND <n>`, and
/// echoes each input line as `IN <line>`. Echo is off, so only these lines
/// reach the client.
const PTY_SCRIPT: &str = r#"stty -echo
stop="$1"
(
  i=0
  while [ ! -e "$stop" ]; do
    j=0
    while [ "$j" -lt 16 ]; do
      i=$((i + 1))
      printf 'SEQ %d\n' "$i"
      j=$((j + 1))
    done
    sleep 0.02
  done
  printf 'SEQEND %d\n' "$i"
) &
printf 'READY\n'
while IFS= read -r line; do printf 'IN %s\n' "$line"; done
"#;

// ---------------------------------------------------------------- the plan

/// SplitMix64: a fixed seed gives the same plan on every host.
struct Rng(u64);

impl Rng {
    fn next(&mut self) -> u64 {
        self.0 = self.0.wrapping_add(0x9e37_79b9_7f4a_7c15);
        let mut value = self.0;
        value = (value ^ (value >> 30)).wrapping_mul(0xbf58_476d_1ce4_e5b9);
        value = (value ^ (value >> 27)).wrapping_mul(0x94d0_49bb_1331_11eb);
        value ^ (value >> 31)
    }

    fn between(&mut self, low: u64, high: u64) -> u64 {
        low + self.next() % (high - low + 1)
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Dir {
    /// Client to daemon.
    Up,
    /// Daemon to client.
    Down,
}

#[derive(Clone, Copy, Debug)]
enum Fault {
    Cut,
    Freeze { ms: u64 },
    HalfFreeze { blocked: Dir, ms: u64 },
    Slow { delay_ms: u64, ms: u64 },
    CutBurst { cuts: u64, gap_ms: u64 },
}

impl Fault {
    fn label(self) -> String {
        match self {
            Self::Cut => "cut".into(),
            Self::Freeze { ms } => format!("freeze-{ms}ms"),
            Self::HalfFreeze { blocked: Dir::Up, ms } => format!("halfcut-up-{ms}ms"),
            Self::HalfFreeze { blocked: Dir::Down, ms } => format!("halfcut-down-{ms}ms"),
            Self::Slow { delay_ms, ms } => format!("slow-{delay_ms}ms-for-{ms}ms"),
            Self::CutBurst { cuts, gap_ms } => format!("cutburst-{cuts}x-{gap_ms}ms"),
        }
    }

    fn severs(self) -> bool {
        matches!(self, Self::Cut | Self::CutBurst { .. })
    }
}

#[derive(Clone, Copy, Debug)]
struct Step {
    fault: Fault,
    calm_ms: u64,
}

#[derive(Clone, Debug)]
struct SeedConfig {
    seed: u64,
    steps: Vec<Step>,
    retained_output_bytes: u32,
}

impl SeedConfig {
    /// Every fault kind once, in a seeded order with seeded lengths.
    fn seeded(seed: u64) -> Self {
        let mut rng = Rng(seed);
        let mut kinds = [0_u8, 1, 2, 3, 4, 5];
        for index in (1..kinds.len()).rev() {
            let other = usize::try_from(rng.next() % (index as u64 + 1)).unwrap_or(0);
            kinds.swap(index, other);
        }
        let steps = kinds
            .iter()
            .map(|kind| {
                let fault = match *kind {
                    0 => Fault::Cut,
                    // Below every dead-peer timeout.
                    1 => Fault::Freeze { ms: rng.between(200, 900) },
                    // Above both dead-peer timeouts and the state bound, below
                    // the resume lease.
                    2 => Fault::Freeze { ms: rng.between(2_400, 3_200) },
                    3 => Fault::HalfFreeze {
                        blocked: if rng.next() & 1 == 0 { Dir::Up } else { Dir::Down },
                        ms: rng.between(2_400, 3_200),
                    },
                    4 => Fault::Slow {
                        delay_ms: rng.between(30, 250),
                        ms: rng.between(1_000, 2_000),
                    },
                    _ => Fault::CutBurst { cuts: rng.between(3, 5), gap_ms: rng.between(0, 80) },
                };
                Step { fault, calm_ms: rng.between(500, 1_200) }
            })
            .collect();
        // A small output history on half the seeds, so a lagging process
        // stream has to signal a replay gap instead of replaying.
        let retained_output_bytes = if seed & 1 == 0 { 4 * 1024 } else { 256 * 1024 };
        Self { seed, steps, retained_output_bytes }
    }

    /// A freeze longer than the resume lease: the session may end, typed.
    fn expiry(seed: u64) -> Self {
        Self {
            seed,
            steps: vec![
                Step { fault: Fault::Cut, calm_ms: 600 },
                Step { fault: Fault::Freeze { ms: 7_000 }, calm_ms: 500 },
            ],
            retained_output_bytes: 256 * 1024,
        }
    }

    fn plan(&self) -> Vec<String> {
        self.steps.iter().map(|step| step.fault.label()).collect()
    }
}

// ---------------------------------------------------------------- the proxy

#[derive(Clone, Copy, Debug, PartialEq)]
enum Mode {
    Open,
    Frozen,
    HalfFrozen(Dir),
    Slow(Duration),
}

#[derive(Clone, Copy, Debug)]
struct LinkState {
    mode: Mode,
    cut_epoch: u64,
}

/// A TCP proxy between the test's client and the test's daemon. Every
/// physical carrier crosses it; [`Mode`] applies to every carrier, the ones
/// a reconnect opens included.
struct FaultProxy {
    address: SocketAddr,
    state: watch::Sender<LinkState>,
    accepted: Arc<AtomicUsize>,
    task: tokio::task::JoinHandle<()>,
}

impl FaultProxy {
    async fn start(upstream: SocketAddr) -> Result<Self, String> {
        let listener = TcpListener::bind("127.0.0.1:0").await.map_err(fail("proxy bind"))?;
        let address = listener.local_addr().map_err(fail("proxy address"))?;
        let (state, _) = watch::channel(LinkState { mode: Mode::Open, cut_epoch: 0 });
        let accepted = Arc::new(AtomicUsize::new(0));
        let task = tokio::spawn({
            let state = state.clone();
            let accepted = accepted.clone();
            async move {
                loop {
                    let Ok((downstream, _)) = listener.accept().await else { return };
                    accepted.fetch_add(1, Ordering::AcqRel);
                    tokio::spawn(carry(downstream, upstream, state.subscribe()));
                }
            }
        });
        Ok(Self { address, state, accepted, task })
    }

    fn set_mode(&self, mode: Mode) {
        self.state.send_modify(|state| state.mode = mode);
    }

    fn cut(&self) {
        self.state.send_modify(|state| state.cut_epoch += 1);
    }

    fn accepted(&self) -> usize {
        self.accepted.load(Ordering::Acquire)
    }
}

impl Drop for FaultProxy {
    fn drop(&mut self) {
        self.task.abort();
        self.cut();
    }
}

async fn carry(downstream: TcpStream, upstream: SocketAddr, mut state: watch::Receiver<LinkState>) {
    let epoch = state.borrow_and_update().cut_epoch;
    let Ok(upstream) = TcpStream::connect(upstream).await else { return };
    let _ = downstream.set_nodelay(true);
    let _ = upstream.set_nodelay(true);
    let (down_read, down_write) = downstream.into_split();
    let (up_read, up_write) = upstream.into_split();
    let up_state = state.clone();
    let down_state = state.clone();
    tokio::select! {
        _ = async move {
            tokio::join!(
                pump(down_read, up_write, Dir::Up, up_state),
                pump(up_read, down_write, Dir::Down, down_state),
            )
        } => {}
        () = wait_for_cut(&mut state, epoch) => {}
    }
    // Dropping both halves of both sockets closes them.
}

async fn wait_for_cut(state: &mut watch::Receiver<LinkState>, epoch: u64) {
    loop {
        if state.borrow_and_update().cut_epoch != epoch {
            return;
        }
        if state.changed().await.is_err() {
            return;
        }
    }
}

/// Carries one direction. The reader never stops reading, so a held chunk
/// waits here (as an unacknowledged TCP segment would) instead of pushing
/// back on the sender's socket.
async fn pump(
    mut from: OwnedReadHalf,
    mut to: OwnedWriteHalf,
    direction: Dir,
    mut state: watch::Receiver<LinkState>,
) {
    let (chunks, mut queue) = mpsc::unbounded_channel::<(Instant, Option<Bytes>)>();
    let reader = async move {
        let mut buffer = vec![0_u8; 64 * 1024];
        loop {
            match from.read(&mut buffer).await {
                Ok(0) | Err(_) => {
                    let _ = chunks.send((Instant::now(), None));
                    return;
                }
                Ok(read) => {
                    let chunk = Bytes::copy_from_slice(&buffer[..read]);
                    if chunks.send((Instant::now(), Some(chunk))).is_err() {
                        return;
                    }
                }
            }
        }
    };
    let writer = async move {
        while let Some((read_at, chunk)) = queue.recv().await {
            if !hold(&mut state, direction, read_at).await {
                return;
            }
            match chunk {
                Some(bytes) => {
                    if to.write_all(&bytes).await.is_err() {
                        return;
                    }
                }
                None => {
                    let _ = to.shutdown().await;
                    return;
                }
            }
        }
    };
    tokio::join!(reader, writer);
}

/// Waits until the link state lets a chunk read at `read_at` cross in
/// `direction`. False when the proxy is gone.
async fn hold(state: &mut watch::Receiver<LinkState>, direction: Dir, read_at: Instant) -> bool {
    loop {
        let mode = state.borrow_and_update().mode;
        let due = match mode {
            Mode::Open => return true,
            Mode::HalfFrozen(blocked) if blocked != direction => return true,
            Mode::Frozen | Mode::HalfFrozen(_) => None,
            Mode::Slow(delay) => Some(read_at + delay),
        };
        match due {
            Some(due) if Instant::now() >= due => return true,
            Some(due) => {
                tokio::select! {
                    () = tokio::time::sleep_until(due) => return true,
                    changed = state.changed() => {
                        if changed.is_err() {
                            return false;
                        }
                    }
                }
            }
            None => {
                if state.changed().await.is_err() {
                    return false;
                }
            }
        }
    }
}

/// The tunnel's far end: echoes every byte.
struct EchoTarget {
    address: SocketAddr,
    task: tokio::task::JoinHandle<()>,
}

impl EchoTarget {
    async fn start() -> Result<Self, String> {
        let listener = TcpListener::bind("127.0.0.1:0").await.map_err(fail("echo bind"))?;
        let address = listener.local_addr().map_err(fail("echo address"))?;
        let task = tokio::spawn(async move {
            loop {
                let Ok((socket, _)) = listener.accept().await else { return };
                tokio::spawn(async move {
                    let (mut read, mut write) = socket.into_split();
                    let _ = tokio::io::copy(&mut read, &mut write).await;
                });
            }
        });
        Ok(Self { address, task })
    }
}

impl Drop for EchoTarget {
    fn drop(&mut self) {
        self.task.abort();
    }
}

// ---------------------------------------------------------------- the output oracle

#[derive(Debug, Clone)]
enum ReaderEnd {
    Exit,
    /// The stream ended with no exit and no error: a silent end.
    Closed,
    /// A typed error: an explicit end of the stream.
    Error(String),
}

/// Follows the PTY's byte stream and records every break in it.
#[derive(Default)]
struct OutputChecker {
    partial: Vec<u8>,
    last_event: u64,
    last_seq: u64,
    seq_end: Option<u64>,
    ready: bool,
    inputs: BTreeMap<u64, u32>,
    last_input: u64,
    /// A signalled gap: the next event and the next line may jump forward.
    event_gap: bool,
    line_gap: bool,
    skip_partial_line: bool,
    gaps: u32,
    gap_reasons: Vec<String>,
    /// When each signalled gap reached the client: an echo of a write sent
    /// before it may be in the dropped range.
    gap_at: Vec<Instant>,
    lines: u64,
    problems: Vec<(Instant, String)>,
}

impl OutputChecker {
    fn event(&mut self, now: Instant, event: &RpcEvent) {
        match &event.event {
            ProcessEvent::Stdout { data, .. } | ProcessEvent::Stderr { data, .. } => {
                if !self.sequence(now, event.sequence) {
                    return;
                }
                match data.decode() {
                    Ok(bytes) => self.bytes(now, &bytes),
                    Err(error) => {
                        self.problems.push((now, format!("output-undecodable {error:?}")));
                    }
                }
            }
            ProcessEvent::OutputTruncated { reason, .. } => {
                self.sequence(now, event.sequence);
                self.gap(now, format!("output-truncated {reason:?}"));
            }
            ProcessEvent::ReplayGap { requested_after, range, .. } => {
                // `RpcEvent.sequence` is the latest known sequence here, not a new event.
                self.gap(now, format!("replay-gap after {requested_after} range {range:?}"));
            }
            ProcessEvent::Exit { .. } => {
                self.sequence(now, event.sequence);
            }
        }
    }

    /// False for a repeated event, whose bytes are not applied again.
    fn sequence(&mut self, now: Instant, sequence: u64) -> bool {
        if sequence <= self.last_event {
            self.problems.push((
                now,
                format!("output-event-duplicate: sequence {sequence} after {}", self.last_event),
            ));
            return false;
        }
        if sequence != self.last_event + 1 && !self.event_gap {
            self.problems.push((
                now,
                format!(
                    "output-event-loss: sequence {} to {} missing, no gap signal",
                    self.last_event + 1,
                    sequence - 1
                ),
            ));
        }
        self.event_gap = false;
        self.last_event = sequence;
        true
    }

    fn gap(&mut self, now: Instant, reason: String) {
        self.gaps += 1;
        self.gap_at.push(now);
        self.gap_reasons.push(reason);
        self.event_gap = true;
        self.line_gap = true;
        self.partial.clear();
        self.skip_partial_line = true;
    }

    fn bytes(&mut self, now: Instant, bytes: &[u8]) {
        for &byte in bytes {
            if byte == b'\n' {
                let raw = std::mem::take(&mut self.partial);
                self.line(now, &raw);
            } else {
                self.partial.push(byte);
            }
        }
    }

    fn line(&mut self, now: Instant, raw: &[u8]) {
        let text = String::from_utf8_lossy(raw);
        let text = text.trim_matches(|character: char| character == '\r' || character == ' ');
        if std::mem::take(&mut self.skip_partial_line) && parse_line(text).is_none() {
            return;
        }
        if text.is_empty() {
            return;
        }
        self.lines += 1;
        match parse_line(text) {
            Some(Line::Ready) => self.ready = true,
            Some(Line::Seq(number)) => {
                if number <= self.last_seq {
                    self.problems.push((
                        now,
                        format!("output-duplicate: SEQ {number} after SEQ {}", self.last_seq),
                    ));
                    return;
                }
                if number != self.last_seq + 1 && !self.line_gap {
                    self.problems.push((
                        now,
                        format!(
                            "output-loss: SEQ {} to {} missing, no gap signal",
                            self.last_seq + 1,
                            number - 1
                        ),
                    ));
                }
                self.line_gap = false;
                self.last_seq = number;
            }
            Some(Line::SeqEnd(number)) => {
                if number != self.last_seq && !self.line_gap {
                    self.problems.push((
                        now,
                        format!(
                            "output-loss: SEQEND {number} after SEQ {}, no gap signal",
                            self.last_seq
                        ),
                    ));
                }
                self.seq_end = Some(number);
            }
            Some(Line::Input(write_id)) => {
                let count = self.inputs.entry(write_id).or_insert(0);
                *count += 1;
                if *count > 1 {
                    self.problems.push((
                        now,
                        format!("input-duplicate: write {write_id} reached the PTY {count} times"),
                    ));
                } else if write_id < self.last_input {
                    self.problems.push((
                        now,
                        format!("input-order: write {write_id} after write {}", self.last_input),
                    ));
                }
                self.last_input = self.last_input.max(write_id);
            }
            None => {
                let shown = text.chars().take(80).collect::<String>();
                self.problems.push((now, format!("output-garbled: line {shown:?}")));
            }
        }
    }
}

enum Line {
    Ready,
    Seq(u64),
    SeqEnd(u64),
    Input(u64),
}

fn parse_line(text: &str) -> Option<Line> {
    if text == "READY" {
        return Some(Line::Ready);
    }
    if let Some(number) = text.strip_prefix("SEQ ") {
        return number.parse().ok().map(Line::Seq);
    }
    if let Some(number) = text.strip_prefix("SEQEND ") {
        return number.parse().ok().map(Line::SeqEnd);
    }
    if let Some(number) = text.strip_prefix("IN ") {
        return number.parse().ok().map(Line::Input);
    }
    None
}

// ---------------------------------------------------------------- shared records

#[derive(Clone, Copy)]
struct Sample {
    at: Instant,
    state: ConnectionState,
    generation: u64,
}

struct RequestRecord {
    kind: &'static str,
    start: Instant,
    end: Instant,
}

#[derive(Default)]
struct Shared {
    samples: Vec<Sample>,
    checker: OutputChecker,
    requests: Vec<RequestRecord>,
    acked: BTreeSet<u64>,
    /// When each write was first sent: its echo can be produced from then on.
    first_sent: BTreeMap<u64, Instant>,
    /// Writes the daemon refused with a typed idempotency error.
    typed_write_errors: BTreeMap<u64, String>,
    /// Every other API error: (when, code, message).
    request_errors: Vec<(Instant, String, String)>,
    reader_end: Option<(Instant, ReaderEnd)>,
}

fn lock(shared: &StdMutex<Shared>) -> MutexGuard<'_, Shared> {
    shared.lock().unwrap_or_else(PoisonError::into_inner)
}

struct FaultWindow {
    fault: Fault,
    start: Instant,
    restored: Instant,
    generation_before: u64,
    generation_at_restore: u64,
    /// When the driver saw `Connected` again (with a new generation after a cut).
    settled: Option<Instant>,
    terminal: Option<TerminalObservation>,
    checks_done: Instant,
    /// Carriers the client dialled from the fault's start to `checks_done`.
    dials: usize,
}

struct TerminalObservation {
    at: Instant,
    /// Samples back in `Reconnecting` after the first terminal sample.
    flaps: usize,
    /// Carriers the client dialled after the first terminal sample.
    dials: usize,
}

struct Violation {
    at_ms: u64,
    fault: String,
    what: String,
}

struct SeedReport {
    seed: u64,
    plan: Vec<String>,
    faults_run: usize,
    reconnects: u64,
    violations: Vec<Violation>,
    gaps: u32,
    lines: u64,
    acked: usize,
    unverified: usize,
    state_max_stale_ms: u64,
    reconnect_ms: Vec<u64>,
    api_max_ms: u64,
    notes: Vec<String>,
    noverdict: Option<String>,
}

impl SeedReport {
    fn new(config: &SeedConfig) -> Self {
        Self {
            seed: config.seed,
            plan: config.plan(),
            faults_run: 0,
            reconnects: 0,
            violations: Vec::new(),
            gaps: 0,
            lines: 0,
            acked: 0,
            unverified: 0,
            state_max_stale_ms: 0,
            reconnect_ms: Vec::new(),
            api_max_ms: 0,
            notes: Vec::new(),
            noverdict: None,
        }
    }

    fn violation(&mut self, t0: Instant, at: Instant, fault: &str, what: impl Into<String>) {
        self.violations.push(Violation {
            at_ms: millis(at.saturating_duration_since(t0)),
            fault: fault.to_owned(),
            what: what.into(),
        });
    }
}

fn millis(duration: Duration) -> u64 {
    u64::try_from(duration.as_millis()).unwrap_or(u64::MAX)
}

fn fail<E: std::fmt::Debug>(what: &'static str) -> impl FnOnce(E) -> String {
    move |error| format!("{what}: {error:?}")
}

fn session_id(seed: u64, salt: u8) -> SessionId {
    let mut bytes = [0_u8; 16];
    bytes[..8].copy_from_slice(&seed.to_be_bytes());
    bytes[8] = salt;
    bytes[15] = 0x6e;
    SessionId(bytes)
}

fn reconnect_policy() -> ReconnectPolicy {
    ReconnectPolicy {
        initial_delay: Duration::from_millis(20),
        maximum_delay: Duration::from_millis(250),
        attempt_timeout: ATTEMPT_TIMEOUT,
        full_jitter: false,
        heartbeat_interval: Some(HEARTBEAT_INTERVAL),
        heartbeat_timeout: HEARTBEAT_TIMEOUT,
        maximum_attempts: None,
        maximum_duration: None,
    }
}

// ---------------------------------------------------------------- the session

struct ClientSide {
    client: Arc<ClientConnection>,
    daemon_client: Arc<ServerConnection>,
    service_task: tokio::task::JoinHandle<()>,
    multiplexer: Arc<ServiceMultiplexer>,
    workspace: Arc<WorkspaceClient>,
}

/// Enrolls a new device with an invitation and connects it through the proxy.
async fn connect_client(
    auth: &Arc<AuthDatabase>,
    proxy: SocketAddr,
    session: SessionId,
    accepted: &mut mpsc::Receiver<Arc<ServerConnection>>,
    services: &Arc<DaemonServices>,
    device_name: &str,
) -> Result<ClientSide, String> {
    let endpoint = Url::parse(&format!("ws://{proxy}/v1/link")).map_err(fail("endpoint"))?;
    let invitation = auth
        .create_invitation(Duration::from_secs(60), Vec::new())
        .await
        .map_err(fail("create invitation"))?;
    let approver = tokio::spawn({
        let auth = auth.clone();
        async move {
            let pending = auth
                .wait_for_pending(Duration::from_secs(10))
                .await
                .map_err(fail("wait for enrollment"))?;
            let first = pending.first().ok_or_else(|| "no pending enrollment".to_owned())?;
            auth.approve(&first.invitation_id).await.map_err(fail("approve"))?;
            Ok::<(), String>(())
        }
    });
    let group = DirectWebSocketProvider::new(MAXIMUM_FRAME_BYTES)
        .connect(ConnectRequest {
            endpoint,
            session,
            lane_policy: LanePolicy::Auto,
            routing: BTreeMap::new(),
        })
        .await
        .map_err(fail("provider connect"))?;
    let secret = invitation.secret_bytes().map_err(fail("invitation secret"))?;
    let client = ClientConnection::connect(
        group,
        ClientConnectionConfig {
            identity: StaticIdentity::generate().map_err(fail("identity"))?,
            expected_daemon: Some(auth.identity().public_key()),
            auth: ClientAuthMode::Invitation { id: invitation.id, secret: Zeroizing::new(secret) },
            device_name: device_name.into(),
            session,
            lane_policy: LanePolicy::Auto,
            limits: SessionLimits::default(),
            reconnect: reconnect_policy(),
        },
    )
    .await
    .map_err(fail("client connect"))?;
    approver.await.map_err(fail("approver"))??;
    let daemon_client = tokio::time::timeout(Duration::from_secs(5), accepted.recv())
        .await
        .map_err(fail("daemon accept timed out"))?
        .ok_or_else(|| "daemon accept channel closed".to_owned())?;
    let service_task = tokio::task::spawn_local({
        let services = services.clone();
        let daemon_client = daemon_client.clone();
        async move {
            let _ = services.serve_client(daemon_client).await;
        }
    });
    let multiplexer = ServiceMultiplexer::new(client.clone(), EndpointRole::Client);
    let workspace =
        WorkspaceClient::connect(multiplexer.clone()).await.map_err(fail("workspace connect"))?;
    Ok(ClientSide { client, daemon_client, service_task, multiplexer, workspace })
}

struct Session {
    seed: u64,
    _state: TempDir,
    _root: TempDir,
    stop_file: PathBuf,
    auth: Arc<AuthDatabase>,
    server: DirectWebSocketServer,
    proxy: FaultProxy,
    accepted: mpsc::Receiver<Arc<ServerConnection>>,
    services: Arc<DaemonServices>,
    side: ClientSide,
    _echo: EchoTarget,
    route: RouteId,
    process: ProcessId,
    pid: Option<u32>,
    events: Option<ProcessEventStream>,
}

impl Session {
    async fn open(config: &SeedConfig) -> Result<Self, String> {
        let state = tempdir().map_err(fail("state dir"))?;
        let root = tempdir().map_err(fail("workspace dir"))?;
        let auth =
            AuthDatabase::load_or_create(state.path(), format!("netdrop-{:x}", config.seed), false)
                .map_err(fail("auth database"))?;
        let (daemon, mut accepted) = RemoteDaemon::with_policy(
            auth.clone(),
            SessionLimits::default(),
            DaemonSessionPolicy { resume_lease: RESUME_LEASE },
        )
        .map_err(fail("daemon"))?;
        let server = serve_direct_websocket_with_options(
            daemon,
            "127.0.0.1:0".parse().map_err(fail("listen address"))?,
            MAXIMUM_FRAME_BYTES,
            DirectWebSocketOptions { keepalive: KEEPALIVE, ..Default::default() },
        )
        .await
        .map_err(fail("listener"))?;
        let proxy = FaultProxy::start(server.local_addr()).await?;
        let services = DaemonServices::new(WorkspaceService::new(), None);
        let side = connect_client(
            &auth,
            proxy.address,
            session_id(config.seed, 0),
            &mut accepted,
            &services,
            "netdrop-client",
        )
        .await?;

        let opened = side
            .workspace
            .request(WorkspaceRequest::OpenWorkspace {
                root: root.path().to_string_lossy().into_owned(),
            })
            .await
            .map_err(fail("open workspace"))?;
        let WorkspaceResponse::Workspace { id: workspace_id, .. } = opened else {
            return Err(format!("open-workspace answered {opened:?}"));
        };
        let echo = EchoTarget::start().await?;
        let created = side
            .workspace
            .request(WorkspaceRequest::CreateRoute {
                workspace: workspace_id.clone(),
                host: echo.address.ip().to_string(),
                port: echo.address.port(),
                policy: RoutePolicy::LoopbackOnly,
            })
            .await
            .map_err(fail("create route"))?;
        let WorkspaceResponse::RouteCreated { route, .. } = created else {
            return Err(format!("create-route answered {created:?}"));
        };
        let stop_file = root.path().join("netdrop.stop");
        let process = side.workspace.allocate_process_handle();
        let started = side
            .workspace
            .spawn_process_with_events(
                process,
                WorkspaceRequest::SpawnProcess {
                    workspace: workspace_id,
                    argv: vec![
                        "/bin/sh".into(),
                        "-c".into(),
                        PTY_SCRIPT.into(),
                        "netdrop".into(),
                        stop_file.to_string_lossy().into_owned(),
                    ],
                    cwd: None,
                    env: BTreeMap::new(),
                    io: ProcessIo::Pty {
                        cols: 120,
                        rows: 40,
                        term: "xterm-256color".into(),
                        eof: PtyEofPolicy::Reject,
                    },
                    // Detached: the shell outlives an expired session, so a
                    // new session can read what the old one missed.
                    lifetime: ProcessLifetime::Detached,
                    operation: None,
                    timeout_ms: Some(120_000),
                    retained_output_bytes: Some(config.retained_output_bytes),
                    environment: ProcessEnvironment::Inherit,
                },
            )
            .await
            .map_err(fail("spawn PTY"))?;
        Ok(Self {
            seed: config.seed,
            _state: state,
            _root: root,
            stop_file,
            auth,
            server,
            proxy,
            accepted,
            services,
            side,
            _echo: echo,
            route,
            process,
            pid: started.pid,
            events: Some(started.events),
        })
    }
}

// ---------------------------------------------------------------- workload tasks

async fn monitor_state(
    client: Arc<ClientConnection>,
    shared: Arc<StdMutex<Shared>>,
    mut stop: watch::Receiver<bool>,
) {
    loop {
        let start = Instant::now();
        let snapshot = client.snapshot().await;
        let end = Instant::now();
        {
            let mut shared = lock(&shared);
            shared.samples.push(Sample {
                at: end,
                state: snapshot.state,
                generation: snapshot.generation,
            });
            shared.requests.push(RequestRecord { kind: "snapshot", start, end });
        }
        tokio::select! {
            () = tokio::time::sleep(SAMPLE_PERIOD) => {}
            _ = stop.changed() => return,
        }
    }
}

async fn read_output(
    workspace: Arc<WorkspaceClient>,
    process: ProcessId,
    mut events: ProcessEventStream,
    shared: Arc<StdMutex<Shared>>,
) {
    let end = loop {
        match events.receive().await {
            Ok(Some(event)) => {
                let now = Instant::now();
                let reopen_after = {
                    let mut shared = lock(&shared);
                    shared.checker.event(now, &event);
                    match &event.event {
                        ProcessEvent::Exit { .. } => {
                            shared.reader_end = Some((now, ReaderEnd::Exit));
                            return;
                        }
                        ProcessEvent::ReplayGap { range, .. } => Some(
                            range
                                .first_available
                                .map_or(range.last_produced, |first| first.saturating_sub(1)),
                        ),
                        _ => None,
                    }
                };
                // A replay gap ends the stream; follow the process again
                // from the oldest event it still keeps.
                if let Some(after) = reopen_after {
                    match workspace.process_events(process, after).await {
                        Ok(reopened) => events = reopened,
                        Err(error) => {
                            break ReaderEnd::Error(format!(
                                "reopen after gap: {}: {}",
                                error.code, error.message
                            ));
                        }
                    }
                }
            }
            Ok(None) => break ReaderEnd::Closed,
            Err(error) => break ReaderEnd::Error(format!("{}: {}", error.code, error.message)),
        }
    };
    lock(&shared).reader_end = Some((Instant::now(), end));
}

/// Writes numbered input lines. A transport error retries the same write ID,
/// which the daemon applies at most once.
async fn write_input(
    workspace: Arc<WorkspaceClient>,
    process: ProcessId,
    shared: Arc<StdMutex<Shared>>,
    stop: watch::Receiver<bool>,
) {
    let mut write_id = 0_u64;
    'lines: while !*stop.borrow() {
        write_id += 1;
        let data = ByteString::from_bytes(format!("{write_id}\n").as_bytes());
        loop {
            let start = Instant::now();
            lock(&shared).first_sent.entry(write_id).or_insert(start);
            let result = workspace
                .request(WorkspaceRequest::WriteProcess {
                    process,
                    write_id,
                    data: data.clone(),
                    eof: false,
                })
                .await;
            let end = Instant::now();
            let retry = {
                let mut shared = lock(&shared);
                shared.requests.push(RequestRecord { kind: "write", start, end });
                match result {
                    Ok(WorkspaceResponse::ProcessWriteAccepted { write_id: accepted, .. })
                        if accepted == write_id =>
                    {
                        shared.acked.insert(write_id);
                        false
                    }
                    Ok(other) => {
                        shared.request_errors.push((
                            end,
                            "wrong-response".into(),
                            format!("{other:?}"),
                        ));
                        false
                    }
                    Err(error)
                        if matches!(
                            error.code.as_str(),
                            "write-outcome-unknown" | "write-id-conflict" | "stale-write-id"
                        ) =>
                    {
                        shared.typed_write_errors.insert(write_id, error.code);
                        false
                    }
                    Err(error) => {
                        shared.request_errors.push((end, error.code, error.message));
                        true
                    }
                }
            };
            if !retry {
                break;
            }
            if *stop.borrow() {
                break 'lines;
            }
            tokio::time::sleep(Duration::from_millis(50)).await;
        }
        tokio::time::sleep(WRITE_PACE).await;
    }
}

/// A control-lane request every [`PROBE_PACE`], timed for the stall oracle.
async fn probe_control(
    workspace: Arc<WorkspaceClient>,
    shared: Arc<StdMutex<Shared>>,
    stop: watch::Receiver<bool>,
) {
    while !*stop.borrow() {
        let start = Instant::now();
        let result = workspace.request(WorkspaceRequest::ListWorkspaces).await;
        let end = Instant::now();
        {
            let mut shared = lock(&shared);
            shared.requests.push(RequestRecord { kind: "control", start, end });
            if let Err(error) = result {
                shared.request_errors.push((end, error.code, error.message));
            }
        }
        tokio::time::sleep(PROBE_PACE).await;
    }
}

// ---------------------------------------------------------------- tunnels

async fn open_tunnel(
    multiplexer: &Arc<ServiceMultiplexer>,
    route: RouteId,
) -> Result<ServiceStream, String> {
    let tunnel = multiplexer
        .open(Service::TcpTunnel, BTreeMap::from([("route".into(), route.0.to_string())]))
        .await
        .map_err(fail("open tunnel"))?;
    let opened = tunnel
        .receive()
        .await
        .map_err(fail("tunnel open answer"))?
        .ok_or_else(|| "tunnel closed during open".to_owned())?;
    match serde_json::from_slice::<ServiceControl>(&opened.payload) {
        Ok(ServiceControl::Opened { service: Service::TcpTunnel }) => Ok(tunnel),
        other => Err(format!("tunnel open answered {other:?}")),
    }
}

#[derive(Debug)]
enum Echo {
    Echoed,
    /// An explicit end: an error, a reset or a close.
    Ended(String),
    Mismatch(String),
    Silent,
}

async fn echo(tunnel: &ServiceStream, payload: &[u8], bound: Duration) -> Echo {
    let attempt = async {
        if let Err(error) = tunnel.send(Bytes::copy_from_slice(payload)).await {
            return Echo::Ended(format!("send: {error}"));
        }
        let mut received = Vec::new();
        while received.len() < payload.len() {
            match tunnel.receive().await {
                Ok(Some(chunk)) => {
                    if chunk.reset {
                        return Echo::Ended("reset".into());
                    }
                    received.extend_from_slice(&chunk.payload);
                    if chunk.finished && received.len() < payload.len() {
                        return Echo::Ended("finished".into());
                    }
                }
                Ok(None) => return Echo::Ended("closed".into()),
                Err(error) => return Echo::Ended(error.to_string()),
            }
        }
        if received == payload {
            Echo::Echoed
        } else {
            Echo::Mismatch(String::from_utf8_lossy(&received).into_owned())
        }
    };
    tokio::time::timeout(bound, attempt).await.unwrap_or(Echo::Silent)
}

// ---------------------------------------------------------------- the fault driver

/// Waits for `Connected` (with a generation past `generation` when `severed`)
/// or a terminal state that holds for [`TERMINAL_HOLD`].
async fn wait_settled(
    session: &Session,
    generation: u64,
    severed: bool,
    deadline: Instant,
) -> (Option<Instant>, Option<TerminalObservation>) {
    let client = &session.side.client;
    let mut terminal: Option<(Instant, usize, usize)> = None;
    loop {
        let snapshot = client.snapshot().await;
        let now = Instant::now();
        match snapshot.state {
            ConnectionState::Disconnected | ConnectionState::Closed => {
                if terminal.is_none() {
                    terminal = Some((now, 0, session.proxy.accepted()));
                }
            }
            ConnectionState::Reconnecting => {
                if let Some((_, flaps, _)) = terminal.as_mut() {
                    *flaps += 1;
                }
            }
            ConnectionState::Connected => {
                terminal = None;
                if !severed || snapshot.generation > generation {
                    return (Some(now), None);
                }
            }
        }
        if let Some((at, flaps, dials_before)) = terminal
            && now.saturating_duration_since(at) >= TERMINAL_HOLD
        {
            let dials = session.proxy.accepted().saturating_sub(dials_before);
            return (None, Some(TerminalObservation { at, flaps, dials }));
        }
        if now >= deadline && terminal.is_none() {
            return (None, None);
        }
        tokio::time::sleep(SAMPLE_PERIOD).await;
    }
}

async fn run_fault(
    session: &Session,
    shared: &Arc<StdMutex<Shared>>,
    step: Step,
    t0: Instant,
    report: &mut SeedReport,
) -> FaultWindow {
    let label = step.fault.label();
    let proxy = &session.proxy;
    let side = &session.side;

    // A tunnel opened before the fault: afterwards it must still carry or
    // end explicitly, never go silent.
    let tunnel = match open_tunnel(&side.multiplexer, session.route).await {
        Ok(tunnel) => match echo(&tunnel, b"before", TUNNEL_BOUND).await {
            Echo::Echoed => Some(tunnel),
            other => {
                report.violation(
                    t0,
                    Instant::now(),
                    &label,
                    format!("tunnel-before-fault: {other:?}"),
                );
                None
            }
        },
        Err(error) => {
            report.violation(t0, Instant::now(), &label, format!("tunnel-open: {error}"));
            None
        }
    };

    let generation_before = side.client.snapshot().await.generation;
    // The generation read just before the last cut: a reconnect that
    // commits after the cut moves past it, one that committed before is cut.
    let mut generation_at_restore = generation_before;
    let dials_before = proxy.accepted();
    let start = Instant::now();
    match step.fault {
        Fault::Cut => proxy.cut(),
        Fault::Freeze { ms } => {
            proxy.set_mode(Mode::Frozen);
            tokio::time::sleep(Duration::from_millis(ms)).await;
            proxy.set_mode(Mode::Open);
        }
        Fault::HalfFreeze { blocked, ms } => {
            proxy.set_mode(Mode::HalfFrozen(blocked));
            tokio::time::sleep(Duration::from_millis(ms)).await;
            proxy.set_mode(Mode::Open);
        }
        Fault::Slow { delay_ms, ms } => {
            proxy.set_mode(Mode::Slow(Duration::from_millis(delay_ms)));
            tokio::time::sleep(Duration::from_millis(ms)).await;
            proxy.set_mode(Mode::Open);
        }
        Fault::CutBurst { cuts, gap_ms } => {
            proxy.cut();
            for _ in 1..cuts {
                // Cut again once the reconnect has reached the proxy.
                let seen = proxy.accepted();
                let deadline = Instant::now() + Duration::from_secs(3);
                while proxy.accepted() == seen && Instant::now() < deadline {
                    tokio::time::sleep(Duration::from_millis(2)).await;
                }
                tokio::time::sleep(Duration::from_millis(gap_ms)).await;
                generation_at_restore = side.client.snapshot().await.generation;
                proxy.cut();
            }
        }
    }
    let restored = Instant::now();
    let (settled, terminal) = wait_settled(
        session,
        if step.fault.severs() { generation_at_restore } else { generation_before },
        step.fault.severs(),
        restored + RECONNECT_TIMEOUT,
    )
    .await;

    if terminal.is_none() {
        tokio::time::sleep(Duration::from_millis(step.calm_ms)).await;
        if let Some(tunnel) = tunnel {
            let reconnected = side.client.snapshot().await.generation > generation_before;
            match echo(&tunnel, b"after", TUNNEL_BOUND).await {
                Echo::Echoed => {}
                Echo::Ended(why) => report.notes.push(format!(
                    "{label}: a tunnel opened before the fault ended explicitly: {why}"
                )),
                Echo::Mismatch(received) => report.violation(
                    t0,
                    Instant::now(),
                    &label,
                    format!("tunnel-corrupt: an open tunnel echoed {received:?}"),
                ),
                Echo::Silent if reconnected => report.violation(
                    t0,
                    Instant::now(),
                    &label,
                    "tunnel-silent: a tunnel opened before the reconnect neither carried nor \
                     ended within 2 s",
                ),
                Echo::Silent => report.violation(
                    t0,
                    Instant::now(),
                    &label,
                    "tunnel-stall: an open tunnel did not echo within 2 s with no reconnect",
                ),
            }
            let _ = tokio::time::timeout(Duration::from_secs(1), tunnel.close()).await;
        }
        let fresh_start = Instant::now();
        let fresh = tokio::time::timeout(TUNNEL_BOUND, async {
            let tunnel = open_tunnel(&side.multiplexer, session.route).await?;
            let outcome = echo(&tunnel, b"fresh", TUNNEL_BOUND).await;
            let _ = tunnel.close().await;
            match outcome {
                Echo::Echoed => Ok::<(), String>(()),
                other => Err(format!("{other:?}")),
            }
        })
        .await;
        let fresh_end = Instant::now();
        lock(shared).requests.push(RequestRecord {
            kind: "tunnel",
            start: fresh_start,
            end: fresh_end,
        });
        match fresh {
            Ok(Ok(())) => {}
            Ok(Err(error)) => report.violation(
                t0,
                fresh_end,
                &label,
                format!("tunnel-fresh: a new tunnel after the fault failed: {error}"),
            ),
            Err(_) => report.violation(
                t0,
                fresh_end,
                &label,
                "tunnel-fresh: a new tunnel after the fault did not echo within 2 s",
            ),
        }
    }
    FaultWindow {
        fault: step.fault,
        start,
        restored,
        generation_before,
        generation_at_restore,
        settled,
        terminal,
        checks_done: Instant::now(),
        dials: proxy.accepted().saturating_sub(dials_before),
    }
}

/// Whether a signalled gap may hold the echo of a write first sent at `sent`:
/// any gap that reached the client at or after the send (the dropped range
/// can hold output produced from the send on). An unknown send time counts.
fn echo_may_be_in_a_gap(sent: Option<Instant>, gaps: &[Instant]) -> bool {
    sent.is_none_or(|sent| gaps.iter().any(|&gap| gap >= sent))
}

/// Dials one severed carrier may make in `window` under [`reconnect_policy`]:
/// the first dial, then one per backoff delay that fits (delays double from
/// `initial_delay` up to `maximum_delay`; each attempt takes at least no time).
fn dials_within(window: Duration) -> usize {
    let policy = reconnect_policy();
    let mut delay = policy.initial_delay;
    let mut spent = Duration::ZERO;
    let mut dials = 1;
    while spent + delay <= window {
        spent += delay;
        dials += 1;
        delay = (delay * 2).min(policy.maximum_delay);
    }
    dials
}

/// The most dials a fault may cause before it is a redial storm: per carrier
/// the fault severs (each cut of a burst; a freeze or a half cut may end one
/// carrier by the dead-peer timeout), what the backoff allows in the window,
/// plus one for a race at the window's edge.
fn dial_bound(fault: Fault, window: Duration) -> usize {
    let severed = match fault {
        Fault::CutBurst { cuts, .. } => usize::try_from(cuts).unwrap_or(usize::MAX),
        Fault::Cut | Fault::Freeze { .. } | Fault::HalfFreeze { .. } | Fault::Slow { .. } => 1,
    };
    severed.saturating_mul(dials_within(window)).saturating_add(1)
}

// ---------------------------------------------------------------- one seed

async fn run_seed(config: SeedConfig) -> SeedReport {
    let t0 = Instant::now();
    let mut report = SeedReport::new(&config);
    let mut session =
        match tokio::time::timeout(Duration::from_secs(20), Session::open(&config)).await {
            Ok(Ok(session)) => session,
            Ok(Err(error)) => {
                report.noverdict = Some(format!("setup: {error}"));
                return report;
            }
            Err(_) => {
                report.noverdict = Some("setup timed out".into());
                return report;
            }
        };
    let shared = Arc::new(StdMutex::new(Shared::default()));
    let (monitor_stop, monitor_stopped) = watch::channel(false);
    let monitor = tokio::task::spawn_local(monitor_state(
        session.side.client.clone(),
        shared.clone(),
        monitor_stopped,
    ));
    let Some(events) = session.events.take() else {
        report.noverdict = Some("no process event stream".into());
        return report;
    };
    let reader = tokio::task::spawn_local(read_output(
        session.side.workspace.clone(),
        session.process,
        events,
        shared.clone(),
    ));

    // Input waits for READY, so `stty -echo` is in place first.
    let ready_deadline = Instant::now() + Duration::from_secs(10);
    while !lock(&shared).checker.ready {
        if Instant::now() >= ready_deadline {
            report.noverdict = Some("the PTY never printed READY".into());
            reader.abort();
            monitor_stop.send_replace(true);
            teardown(session, None, &mut report).await;
            return report;
        }
        tokio::time::sleep(SAMPLE_PERIOD).await;
    }
    let (workload_stop, workload_stopped) = watch::channel(false);
    let writer = tokio::task::spawn_local(write_input(
        session.side.workspace.clone(),
        session.process,
        shared.clone(),
        workload_stopped.clone(),
    ));
    let prober = tokio::task::spawn_local(probe_control(
        session.side.workspace.clone(),
        shared.clone(),
        workload_stopped,
    ));
    tokio::time::sleep(Duration::from_millis(500)).await;

    let mut windows = Vec::new();
    for step in &config.steps {
        let window = run_fault(&session, &shared, *step, t0, &mut report).await;
        let terminal = window.terminal.is_some();
        windows.push(window);
        report.faults_run += 1;
        if terminal {
            break;
        }
    }
    let terminal = windows.iter().any(|window| window.terminal.is_some());

    // Stop the input first, then the output, then wait for both to drain.
    workload_stop.send_replace(true);
    for (name, task) in [("write", writer), ("control", prober)] {
        let abort = task.abort_handle();
        if tokio::time::timeout(RECONNECT_TIMEOUT, task).await.is_err() {
            abort.abort();
            if !terminal {
                report.violation(
                    t0,
                    Instant::now(),
                    "none",
                    format!("api-hang: a {name} request did not return within 10 s of the end"),
                );
            }
        }
    }
    if let Err(error) = std::fs::write(&session.stop_file, b"stop") {
        report.notes.push(format!("stop file: {error}"));
    }
    let mut recovery = None;
    let mut verifiable = true;
    if terminal {
        reader.abort();
        let (side, outcome, complete) = read_after_terminal(&mut session, &shared).await;
        report.notes.push(format!("after the session ended: {outcome}"));
        verifiable = complete;
        recovery = side;
    } else {
        let drain_deadline = Instant::now() + RECONNECT_TIMEOUT;
        loop {
            let done = {
                let shared = lock(&shared);
                shared.reader_end.is_some()
                    || (shared.checker.seq_end.is_some()
                        && shared
                            .acked
                            .iter()
                            .all(|write_id| shared.checker.inputs.contains_key(write_id)))
            };
            if done || Instant::now() >= drain_deadline {
                break;
            }
            tokio::time::sleep(SAMPLE_PERIOD).await;
        }
        reader.abort();
    }
    monitor_stop.send_replace(true);
    let _ = tokio::time::timeout(Duration::from_secs(2), monitor).await;

    evaluate(&windows, &lock(&shared), t0, terminal, verifiable, &mut report);
    teardown(session, recovery, &mut report).await;
    report
}

/// After the session ended: a new session reads the output the old one
/// missed, so acknowledged input is still checked.
async fn read_after_terminal(
    session: &mut Session,
    shared: &Arc<StdMutex<Shared>>,
) -> (Option<ClientSide>, String, bool) {
    let side = match connect_client(
        &session.auth,
        session.proxy.address,
        session_id(session.seed, 1),
        &mut session.accepted,
        &session.services,
        "netdrop-recovery",
    )
    .await
    {
        Ok(side) => side,
        Err(error) => return (None, format!("new session failed: {error}"), false),
    };
    let deadline = Instant::now() + Duration::from_secs(8);
    let mut after = lock(shared).checker.last_event;
    let mut read = 0_usize;
    loop {
        let response = side
            .workspace
            .request_with_timeout(
                WorkspaceRequest::ReadProcessEvents {
                    process: session.process,
                    after_sequence: after,
                    limit: 512,
                },
                Duration::from_secs(3),
            )
            .await;
        let now = Instant::now();
        match response {
            Ok(WorkspaceResponse::ProcessEvents { events, next_cursor, .. }) => {
                let done = {
                    let mut shared = lock(shared);
                    for event in &events {
                        shared.checker.event(now, event);
                        after = after.max(event.sequence);
                    }
                    read += events.len();
                    shared.checker.seq_end.is_some()
                        && shared
                            .acked
                            .iter()
                            .all(|write_id| shared.checker.inputs.contains_key(write_id))
                };
                if let Some(cursor) = next_cursor {
                    after = after.max(cursor);
                }
                if done {
                    return (Some(side), format!("a new session read {read} more events"), true);
                }
                if events.is_empty() {
                    tokio::time::sleep(Duration::from_millis(100)).await;
                }
            }
            Ok(WorkspaceResponse::ProcessReplayGap { requested_after, range, .. }) => {
                lock(shared).checker.gap(
                    Instant::now(),
                    format!("replay-gap after {requested_after} range {range:?}"),
                );
                after = range
                    .first_available
                    .map_or(range.last_produced, |first| first.saturating_sub(1));
            }
            Ok(other) => {
                return (Some(side), format!("read-process-events answered {other:?}"), false);
            }
            Err(error) => {
                return (
                    Some(side),
                    format!("read-process-events failed: {}: {}", error.code, error.message),
                    false,
                );
            }
        }
        if Instant::now() >= deadline {
            return (Some(side), format!("a new session read {read} events, incomplete"), false);
        }
    }
}

async fn teardown(session: Session, recovery: Option<ClientSide>, report: &mut SeedReport) {
    let _ = std::fs::write(&session.stop_file, b"stop");
    if let Some(pid) = session.pid.and_then(|pid| i32::try_from(pid).ok()) {
        // The PTY shell and its children, which this test started. The PTY
        // child leads its own process group.
        // SAFETY: kill(2) with a process ID this test's daemon spawned.
        unsafe {
            libc::kill(-pid, libc::SIGKILL);
            libc::kill(pid, libc::SIGKILL);
        }
    }
    let Session { server, side, proxy, .. } = session;
    for side in [Some(side), recovery].into_iter().flatten() {
        let ClientSide { client, daemon_client, service_task, multiplexer, workspace } = side;
        drop(workspace);
        if tokio::time::timeout(Duration::from_secs(3), multiplexer.shutdown()).await.is_err() {
            report.notes.push("teardown: multiplexer shutdown took over 3 s".into());
        }
        if tokio::time::timeout(Duration::from_secs(3), client.close()).await.is_err() {
            report.notes.push("teardown: client close took over 3 s".into());
        }
        if tokio::time::timeout(Duration::from_secs(3), daemon_client.close()).await.is_err() {
            report.notes.push("teardown: daemon connection close took over 3 s".into());
        }
        service_task.abort();
    }
    drop(proxy);
    if tokio::time::timeout(Duration::from_secs(3), server.shutdown()).await.is_err() {
        report.notes.push("teardown: listener shutdown took over 3 s".into());
    }
}

// ---------------------------------------------------------------- the oracle

fn window_label(windows: &[FaultWindow], at: Instant) -> String {
    windows
        .iter()
        .find(|window| at >= window.start && at <= window.checks_done + Duration::from_secs(1))
        .map_or_else(|| "none".to_owned(), |window| window.fault.label())
}

fn evaluate(
    windows: &[FaultWindow],
    shared: &Shared,
    t0: Instant,
    terminal: bool,
    verifiable: bool,
    report: &mut SeedReport,
) {
    let checker = &shared.checker;
    report.gaps = checker.gaps;
    report.lines = checker.lines;
    report.acked = shared.acked.len();
    report.reconnects = shared.samples.last().map_or(0, |sample| sample.generation);

    // (a) output: every break the checker saw.
    for (at, what) in &checker.problems {
        report.violation(t0, *at, &window_label(windows, *at), what.clone());
    }
    for reason in &checker.gap_reasons {
        report.notes.push(format!("signalled gap: {reason}"));
    }
    match &shared.reader_end {
        Some((at, ReaderEnd::Closed)) if !terminal => report.violation(
            t0,
            *at,
            &window_label(windows, *at),
            "output-stream-closed: the process stream ended with no exit and no error",
        ),
        Some((at, ReaderEnd::Error(error))) if !terminal => {
            // Explicit: the client knows the rest of the output is missing.
            report.gaps += 1;
            let at_ms = millis(at.saturating_duration_since(t0));
            report.notes.push(format!("process stream ended at {at_ms} ms: {error}"));
        }
        _ => {}
    }
    let stream_explicitly_ended =
        matches!(shared.reader_end, Some((_, ReaderEnd::Error(_)))) || terminal;
    if !stream_explicitly_ended && checker.seq_end.is_none() {
        report.violation(
            t0,
            Instant::now(),
            "none",
            format!(
                "output-incomplete: no SEQEND within 10 s of the stop (last SEQ {})",
                checker.last_seq
            ),
        );
    }
    // (a) input: every acknowledged write reached the PTY once.
    for write_id in &shared.acked {
        if checker.inputs.contains_key(write_id) {
            continue;
        }
        // A gap signalled at or after the write was sent may hold its echo:
        // that is a signalled loss of output, not a lost input.
        let echo_in_a_gap =
            echo_may_be_in_a_gap(shared.first_sent.get(write_id).copied(), &checker.gap_at);
        if verifiable
            && !echo_in_a_gap
            && !matches!(shared.reader_end, Some((_, ReaderEnd::Error(_))))
        {
            report.violation(
                t0,
                Instant::now(),
                "none",
                format!("acked-input-lost: write {write_id} was acknowledged and never echoed"),
            );
        } else {
            report.unverified += 1;
        }
    }

    // (b) visible state, per fault.
    let samples = &shared.samples;
    for window in windows {
        let label = window.fault.label();
        // No redial storm while the fault lasts, not only after a terminal state.
        let bound =
            dial_bound(window.fault, window.checks_done.saturating_duration_since(window.start));
        if window.dials > bound {
            report.violation(
                t0,
                window.checks_done,
                &label,
                format!(
                    "redial-storm: {} dials during the fault, the backoff allows at most {bound}",
                    window.dials
                ),
            );
        }
        let left_at = samples
            .iter()
            .filter(|sample| sample.at >= window.start && sample.at <= window.checks_done)
            .find(|sample| {
                sample.state != ConnectionState::Connected
                    || sample.generation > window.generation_before
            })
            .map(|sample| sample.at);
        match window.fault {
            Fault::Slow { .. } => {}
            Fault::Cut | Fault::CutBurst { .. } => match left_at {
                Some(at) => {
                    let stale = at.saturating_duration_since(window.start);
                    report.state_max_stale_ms = report.state_max_stale_ms.max(millis(stale));
                    if stale > STATE_BOUND {
                        report.violation(
                            t0,
                            at,
                            &label,
                            format!(
                                "state-stale: Connected for {} ms after the carrier was cut \
                                 (bound {} ms)",
                                millis(stale),
                                millis(STATE_BOUND)
                            ),
                        );
                    }
                }
                None => report.violation(
                    t0,
                    window.restored,
                    &label,
                    "state-stale: the client neither left Connected nor reconnected after the \
                     carrier was cut",
                ),
            },
            Fault::Freeze { ms } | Fault::HalfFreeze { ms, .. } => {
                let shown_until = left_at.map_or(window.restored, |at| at.min(window.restored));
                let stale = shown_until.saturating_duration_since(window.start);
                report.state_max_stale_ms = report.state_max_stale_ms.max(millis(stale));
                if Duration::from_millis(ms) > STATE_BOUND && stale > STATE_BOUND {
                    report.violation(
                        t0,
                        shown_until,
                        &label,
                        format!(
                            "state-stale: Connected for {} ms over a frozen link (bound {} ms)",
                            millis(stale),
                            millis(STATE_BOUND)
                        ),
                    );
                }
            }
        }
        if let Some(left) = left_at
            && window.terminal.is_none()
        {
            let required = if window.fault.severs() {
                window.generation_at_restore.max(window.generation_before)
            } else {
                window.generation_before
            };
            let from = left.max(window.restored);
            let back = samples
                .iter()
                .find(|sample| {
                    sample.at >= from
                        && sample.state == ConnectionState::Connected
                        && sample.generation > required
                })
                .map(|sample| sample.at);
            match back {
                Some(at) if at.saturating_duration_since(window.restored) <= RECONNECT_TIMEOUT => {
                    report.reconnect_ms.push(millis(at.saturating_duration_since(window.restored)));
                }
                _ if window.settled.is_some() && !window.fault.severs() => {
                    // Back in the same generation: the carrier survived.
                }
                _ => report.violation(
                    t0,
                    window.restored,
                    &label,
                    format!(
                        "no-reconnect: not Connected in a new generation within {} ms of the \
                         link's return",
                        millis(RECONNECT_TIMEOUT)
                    ),
                ),
            }
        }
        // A terminal state: allowed only after the resume lease, typed and stable.
        if let Some(observation) = &window.terminal {
            let outage = window.restored.saturating_duration_since(window.start);
            if outage < RESUME_LEASE {
                report.violation(
                    t0,
                    observation.at,
                    &label,
                    format!(
                        "terminal-before-lease: the session ended after a {} ms outage \
                         (lease {} ms)",
                        millis(outage),
                        millis(RESUME_LEASE)
                    ),
                );
            }
            let error = shared.request_errors.iter().find(|(at, _, _)| *at >= window.start);
            match error {
                None => report.violation(
                    t0,
                    observation.at,
                    &label,
                    "terminal-silent: the state went Disconnected and no API call returned an \
                     error",
                ),
                Some((at, code, message)) if code == "transport" => {
                    let message = message.chars().take(160).collect::<String>();
                    report.violation(
                        t0,
                        *at,
                        &label,
                        format!(
                            "terminal-untyped: the session end reached the API only as \
                             code=transport message={message:?}"
                        ),
                    );
                }
                Some((_, code, _)) => {
                    report.notes.push(format!("the session end reached the API as code={code}"));
                }
            }
            if observation.flaps > 0 {
                report.violation(
                    t0,
                    observation.at,
                    &label,
                    format!(
                        "terminal-flaps: after the session ended the state went back to \
                         Reconnecting in {} samples and the client dialled {} carriers in {} ms",
                        observation.flaps,
                        observation.dials,
                        millis(TERMINAL_HOLD)
                    ),
                );
            }
        }
    }

    // (c) no stall while Connected and no fault is active.
    let terminal_from = windows.iter().find(|window| window.terminal.is_some()).map(|w| w.start);
    for request in &shared.requests {
        let took = request.end.saturating_duration_since(request.start);
        if request.kind == "snapshot" {
            // A diagnostic read: never waits, faults included.
            if took > STALL_BOUND {
                report.violation(
                    t0,
                    request.start,
                    &window_label(windows, request.start),
                    format!("stall: snapshot took {} ms", millis(took)),
                );
            }
            continue;
        }
        if terminal_from.is_some_and(|from| request.end >= from) {
            continue;
        }
        let mut bound = STALL_BOUND;
        let mut during_fault = false;
        for window in windows {
            let end = window.settled.unwrap_or(window.checks_done) + Duration::from_millis(300);
            if request.start >= end || request.end <= window.start {
                continue;
            }
            match window.fault {
                Fault::Slow { delay_ms, .. } => bound += Duration::from_millis(2 * delay_ms),
                _ => during_fault = true,
            }
        }
        if during_fault {
            continue;
        }
        let connected_throughout = samples
            .iter()
            .filter(|sample| sample.at >= request.start && sample.at <= request.end)
            .all(|sample| sample.state == ConnectionState::Connected);
        if !connected_throughout {
            continue;
        }
        report.api_max_ms = report.api_max_ms.max(millis(took));
        if took > bound {
            report.violation(
                t0,
                request.start,
                &window_label(windows, request.start),
                format!(
                    "stall: a {} request took {} ms while Connected (bound {} ms)",
                    request.kind,
                    millis(took),
                    millis(bound)
                ),
            );
        }
    }
    if !shared.typed_write_errors.is_empty() {
        report.notes.push(format!(
            "{} writes refused with a typed idempotency error",
            shared.typed_write_errors.len()
        ));
    }
    let non_terminal_errors = shared
        .request_errors
        .iter()
        .filter(|(at, _, _)| terminal_from.is_none_or(|from| *at < from))
        .count();
    if non_terminal_errors > 0 {
        report.notes.push(format!("{non_terminal_errors} API errors before any terminal state"));
    }
}

// ---------------------------------------------------------------- the runner

fn run_seed_blocking(config: SeedConfig) -> SeedReport {
    let seed = config.seed;
    let mut hung = SeedReport::new(&config);
    let runtime =
        match tokio::runtime::Builder::new_multi_thread().worker_threads(2).enable_all().build() {
            Ok(runtime) => runtime,
            Err(error) => {
                hung.noverdict = Some(format!("runtime: {error}"));
                return hung;
            }
        };
    let local = tokio::task::LocalSet::new();
    let report = local.block_on(&runtime, async move {
        tokio::time::timeout(SEED_TIMEOUT, run_seed(config)).await.ok()
    });
    drop(local);
    runtime.shutdown_timeout(Duration::from_secs(2));
    report.unwrap_or_else(|| {
        hung.violations.push(Violation {
            at_ms: millis(SEED_TIMEOUT),
            fault: "none".into(),
            what: format!(
                "seed-hang: seed {seed:#x} did not finish in {} s",
                SEED_TIMEOUT.as_secs()
            ),
        });
        hung
    })
}

fn run_all(configs: Vec<SeedConfig>) -> Vec<SeedReport> {
    let handles = configs
        .into_iter()
        .map(|config| {
            let fallback = SeedReport::new(&config);
            (fallback, std::thread::spawn(move || run_seed_blocking(config)))
        })
        .collect::<Vec<_>>();
    handles
        .into_iter()
        .map(|(mut fallback, handle)| {
            handle.join().unwrap_or_else(|_| {
                fallback.noverdict = Some("the seed's thread panicked".into());
                fallback
            })
        })
        .collect()
}

fn print_report(report: &SeedReport) {
    let seed = report.seed;
    if let Some(reason) = &report.noverdict {
        println!("NETDROP NOVERDICT seed={seed:#x} reason={reason}");
    }
    for violation in &report.violations {
        println!(
            "NETDROP VIOLATION seed={seed:#x} fault={} at={} what={}",
            violation.fault, violation.at_ms, violation.what
        );
    }
    for note in &report.notes {
        println!("NETDROP NOTE seed={seed:#x} {note}");
    }
    println!(
        "NETDROP SEED seed={seed:#x} plan=[{}] faults={} reconnects={} violations={} gaps={} \
         lines={} acked={} unverified={} state_max_stale_ms={} reconnect_ms={:?} api_max_ms={}",
        report.plan.join(","),
        report.faults_run,
        report.reconnects,
        report.violations.len(),
        report.gaps,
        report.lines,
        report.acked,
        report.unverified,
        report.state_max_stale_ms,
        report.reconnect_ms,
        report.api_max_ms
    );
}

/// Runs each fault of each failing seed alone and prints the faults that
/// still fail: the smallest fault list this pass can find.
fn shrink(failing: &[SeedConfig]) {
    let singles = failing
        .iter()
        .flat_map(|config| {
            config.steps.iter().map(|step| SeedConfig { steps: vec![*step], ..config.clone() })
        })
        .collect::<Vec<_>>();
    let reports = run_all(singles.clone());
    for config in failing {
        let mut minimal = Vec::new();
        for (single, report) in singles.iter().zip(&reports) {
            if single.seed != config.seed {
                continue;
            }
            let label = single.steps[0].fault.label();
            let failed = !report.violations.is_empty() || report.noverdict.is_some();
            println!(
                "NETDROP SHRINK seed={:#x} fault={label} alone violations={}{}",
                config.seed,
                report.violations.len(),
                report
                    .violations
                    .first()
                    .map_or_else(String::new, |v| format!(" first={}", v.what))
            );
            if failed {
                minimal.push(label);
            }
        }
        if minimal.is_empty() {
            minimal = config.plan();
        }
        println!("NETDROP SHRINK seed={:#x} minimal=[{}]", config.seed, minimal.join(","));
    }
}

fn percentile(sorted: &[u64], percent: usize) -> u64 {
    if sorted.is_empty() {
        return 0;
    }
    sorted[(sorted.len() - 1) * percent / 100]
}

/// Whether this run is a netdrop measurement: a fleet step keyed for it, or
/// an explicit opt-in. Elsewhere the test skips, so it adds no CI test.
fn netdrop_requested() -> bool {
    std::env::var("CMUX_CI_STEP_KEY").is_ok_and(|key| key.contains("netdrop"))
        || std::env::var_os("CMUX_NETDROP_FUZZ").is_some()
}

/// The oracle's own rules, checked before any seed runs (review FIX at
/// 5f7245b4c64, #30383): a run with a wrong oracle gives no verdict.
fn oracle_self_checks() {
    let t = Instant::now();
    let later = t + Duration::from_millis(5);
    // A gap signalled after the send may hold the echo: unverified, not lost.
    assert!(echo_may_be_in_a_gap(Some(t), &[later]));
    assert!(echo_may_be_in_a_gap(Some(t), &[t]));
    assert!(echo_may_be_in_a_gap(None, &[]));
    // A gap before the send cannot hold it: a missing echo is a lost input.
    assert!(!echo_may_be_in_a_gap(Some(later), &[t]));
    assert!(!echo_may_be_in_a_gap(Some(t), &[]));
    // Backoff 20, 40, 80, 160, then 250 ms: 1 dial at 0 ms, 5 by 300 ms.
    assert_eq!(dials_within(Duration::ZERO), 1);
    assert_eq!(dials_within(Duration::from_millis(300)), 5);
    assert_eq!(dials_within(Duration::from_millis(550)), 6);
    // A 3-cut burst may dial 3 times what one cut may, plus 1.
    let window = Duration::from_secs(3);
    assert_eq!(
        dial_bound(Fault::CutBurst { cuts: 3, gap_ms: 50 }, window),
        3 * dials_within(window) + 1
    );
    // A client that redials every 2 ms for 3 s is a storm.
    assert!(1_500 > dial_bound(Fault::CutBurst { cuts: 3, gap_ms: 50 }, window));
    println!("NETDROP ORACLE self-checks passed");
}

#[test]
fn netdrop_fuzz_seeded_network_faults_never_lose_data_silently() {
    if !netdrop_requested() {
        println!(
            "NETDROP SKIP: runs only in a fleet step whose key contains netdrop, or with \
             CMUX_NETDROP_FUZZ set"
        );
        return;
    }
    oracle_self_checks();
    let started = std::time::Instant::now();
    let mut configs = SEEDS.iter().map(|&seed| SeedConfig::seeded(seed)).collect::<Vec<_>>();
    configs.push(SeedConfig::expiry(EXPIRY_SEED));
    let reports = run_all(configs.clone());
    for report in &reports {
        print_report(report);
    }

    let failing = configs
        .iter()
        .zip(&reports)
        .filter(|(config, report)| !report.violations.is_empty() && config.steps.len() > 1)
        .map(|(config, _)| config.clone())
        .collect::<Vec<_>>();
    if !failing.is_empty() {
        if started.elapsed() < SHRINK_START_LIMIT {
            shrink(&failing);
        } else {
            println!("NETDROP SHRINK skipped: {} s already spent", started.elapsed().as_secs());
        }
    }

    let violations = reports.iter().map(|report| report.violations.len()).sum::<usize>();
    let noverdicts = reports.iter().filter(|report| report.noverdict.is_some()).count();
    let mut reconnect_ms =
        reports.iter().flat_map(|report| report.reconnect_ms.iter().copied()).collect::<Vec<_>>();
    reconnect_ms.sort_unstable();
    println!(
        "NETDROP SUMMARY seeds={} faults={} reconnects={} violations={violations} gaps={} \
         state_max_stale_ms={} reconnect_ms p50={} max={} noverdict={noverdicts} elapsed_s={}",
        reports.len(),
        reports.iter().map(|report| report.faults_run).sum::<usize>(),
        reports.iter().map(|report| report.reconnects).sum::<u64>(),
        reports.iter().map(|report| report.gaps).sum::<u32>(),
        reports.iter().map(|report| report.state_max_stale_ms).max().unwrap_or(0),
        percentile(&reconnect_ms, 50),
        reconnect_ms.last().copied().unwrap_or(0),
        started.elapsed().as_secs()
    );
    assert_eq!(noverdicts, 0, "a seed gave no verdict; see the NETDROP NOVERDICT lines");
    assert_eq!(violations, 0, "network faults broke the oracle; see the NETDROP VIOLATION lines");
}
