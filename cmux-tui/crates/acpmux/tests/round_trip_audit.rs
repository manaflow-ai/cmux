//! The round-trip audit bench (item 7 of the transport pair matrix): every request the phone
//! (or the Mac, towards a Linux peer) waits on before the person sees a result, replayed in the
//! client's real order against a real acpmux hub through `cmux_fault::shaper::Shaper`, with the
//! measured time and bytes of each. One `ROUNDTRIP {...}` line per round trip per run (see
//! pm/rtt/INVENTORY.md for the table with callers and verdicts; the rows below mirror it).
//!
//! The Mac host's own waits on its acpmux (cmux-mobile-host services.rs `connect_acpmux`,
//! `trusted_session_query`, `current_mode`) are replayed on loopback against the hub, unshaped.
//! The Mac-Linux rows run on this hub behind the shaped link standing in for the Linux peer
//! (each such line carries `stand_in`). A step that cannot be replayed headless prints
//! `"ms":null` and a `"reason"`: client-side Swift waits, the link's upload and daemon channels,
//! the Linux carrier lines and the dial race beyond the ws path are not in this crate's rig. This is the
//! acpmux bench (no phone Link in the path); the replayed steps are the WebSocket requests the
//! phone's `acpmux` service splices to the hub, so the shaper sits where the phone's radio does.
//!
//! Loads: `idle` = 5 sessions, 20 turns; `duress` = 50 sessions, one chat at `RTT_DURESS_TURNS`
//! (default 5000) turns, another chat streaming ticks while the measured steps run.
//!
//! Env: `RTT_PROFILES` (lte,lossy-3), `RTT_LOADS` (idle,duress), `RTT_RUNS` (`PAIRMATRIX_N`, 5),
//! `RTT_SEED_BASE` (`PAIRMATRIX_SEED_BASE`, 0), `RTT_DURESS_TURNS` (5000).
//! `cargo test --release -p acpmux --test round_trip_audit -- --ignored --nocapture --test-threads 1`
#![cfg(unix)]

#[path = "support/daemon_env.rs"]
mod daemon_env;
const HERMETIC: daemon_env::Process = daemon_env::Process::stand_in().keep(&[
    "RTT_PROFILES",
    "RTT_LOADS",
    "RTT_RUNS",
    "RTT_SEED_BASE",
    "RTT_DURESS_TURNS",
    "PAIRMATRIX_N",
    "PAIRMATRIX_SEED_BASE",
]);

#[path = "support/app_ws.rs"]
mod app_ws;

use acpmux::config::{Config, StoreMode};
use acpmux::hub::Hub;
use acpmux::rpc::{Message as RpcMessage, method};
use acpmux::server::{AGENT_PANE_ORIGIN, Origin, serve_connection_with};
use cmux_fault::Trace;
use cmux_fault::shaper::{ProfileFile, Shaper};
use futures_util::stream::SplitSink;
use futures_util::{SinkExt, StreamExt};
use serde_json::{Value, json};
use std::collections::{HashMap, VecDeque};
use std::path::Path;
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::mpsc;
use tokio::time::Instant;
use tokio_tungstenite::tungstenite::{Message, client::IntoClientRequest};

const FAKE: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
const PAGE_SIZE: u64 = 400;
const OPEN_BYTES: u64 = 128 * 1024;
const TOOL_OUTPUT_MAX_BYTES: u64 = 64 * 1024;
const SCROLL_BYTES: u64 = 256 * 1024;
const WATCH_LIMIT: u64 = 100;
const CHAT_KINDS: &[&str] = &[
    "transcript",
    "queue_updated",
    "queue_order",
    "queue_paused",
    "queue_resumed",
    "claude.system.api_retry",
    "bookmarks",
];
const BOUND: Duration = Duration::from_secs(90);
const BASE_TURNS: u64 = 20;

type Ws = tokio_tungstenite::WebSocketStream<tokio::net::TcpStream>;

// ---------------------------------------------------------------------------------------------
// The phone's connection (cmux-next-ios AcpmuxHub.swift / AcpmuxConnection.swift)

struct Link {
    sink: SplitSink<Ws, Message>,
    rx: mpsc::UnboundedReceiver<(Instant, Value)>,
    pending: VecDeque<(Instant, Value)>,
    /// Answers that came while a notification was awaited.
    held: Vec<(Instant, Value)>,
    next: i64,
}

impl Link {
    async fn dial(addr: std::net::SocketAddr) -> Result<Self, String> {
        let tcp =
            tokio::net::TcpStream::connect(addr).await.map_err(|e| format!("connect: {e}"))?;
        let _ = tcp.set_nodelay(true);
        let mut req = format!("ws://{addr}/").into_client_request().map_err(|e| e.to_string())?;
        req.headers_mut().insert("authorization", "Bearer tok".parse().unwrap());
        req.headers_mut().insert("origin", AGENT_PANE_ORIGIN.parse().unwrap());
        let (ws, _) = tokio_tungstenite::client_async(req, tcp)
            .await
            .map_err(|e| format!("websocket handshake: {e}"))?;
        let (sink, mut stream) = ws.split();
        let (tx, rx) = mpsc::unbounded_channel();
        tokio::spawn(async move {
            while let Some(Ok(frame)) = stream.next().await {
                let now = Instant::now();
                match frame {
                    Message::Text(t) => {
                        if let Ok(v) = serde_json::from_str::<Value>(&t) {
                            if tx.send((now, v)).is_err() {
                                break;
                            }
                        }
                    }
                    Message::Close(_) => break,
                    _ => {}
                }
            }
        });
        Ok(Self { sink, rx, pending: VecDeque::new(), held: Vec::new(), next: 0 })
    }

    /// Writes the request; returns its id and its bytes.
    async fn post(&mut self, m: &str, params: Value) -> Result<(i64, u64), String> {
        self.next += 1;
        let text =
            json!({"jsonrpc": "2.0", "id": self.next, "method": m, "params": params}).to_string();
        let len = text.len() as u64;
        self.sink.send(Message::Text(text.into())).await.map_err(|e| format!("send {m}: {e}"))?;
        Ok((self.next, len))
    }

    /// The answer to `id`: its arrival, result and bytes; notifications wait in `pending`.
    async fn answer(
        &mut self,
        id: i64,
        deadline: Instant,
    ) -> Result<(Instant, Value, u64), String> {
        let take = |at: Instant, v: Value| {
            if let Some(e) = v.get("error") {
                return Err(format!("request {id}: {e}"));
            }
            let n = v.to_string().len() as u64;
            Ok((at, v["result"].clone(), n))
        };
        if let Some(i) = self.held.iter().position(|(_, v)| v.get("id") == Some(&json!(id))) {
            let (at, v) = self.held.remove(i);
            return take(at, v);
        }
        loop {
            match tokio::time::timeout_at(deadline, self.rx.recv()).await {
                Err(_) => return Err(format!("no answer to request {id} in time")),
                Ok(None) => return Err(format!("closed before the answer to request {id}")),
                Ok(Some((at, v))) => {
                    if v.get("id") == Some(&json!(id)) && v.get("method").is_none() {
                        return take(at, v);
                    }
                    if v.get("method").is_some() {
                        self.pending.push_back((at, v));
                    }
                }
            }
        }
    }

    /// One request and its answer: (ms, up bytes, down bytes, result).
    async fn rt(&mut self, m: &str, params: Value) -> Result<(f64, u64, u64, Value), String> {
        let start = Instant::now();
        let (id, up) = self.post(m, params).await?;
        let (at, v, down) = self.answer(id, start + BOUND).await?;
        Ok((ms(at - start), up, down, v))
    }

    /// The next frame: a held notification first, else the next one off the socket (an answer
    /// too; the caller holds those it does not want in `held`).
    async fn notification(&mut self, deadline: Instant) -> Option<(Instant, Value)> {
        if let Some(x) = self.pending.pop_front() {
            return Some(x);
        }
        loop {
            match tokio::time::timeout_at(deadline, self.rx.recv()).await {
                Ok(Some(frame)) => return Some(frame),
                _ => return None,
            }
        }
    }
}

fn ms(d: Duration) -> f64 {
    (d.as_secs_f64() * 10_000.0).round() / 10.0
}

fn rows(reply: &Value) -> Vec<u64> {
    reply["events"]
        .as_array()
        .map(|a| a.iter().filter_map(|e| e["seq"].as_u64()).collect())
        .unwrap_or_default()
}

fn kinds() -> Value {
    json!(CHAT_KINDS)
}

// ---------------------------------------------------------------------------------------------
// The fixture

fn hub(home: &Path) -> Arc<Hub> {
    acpmux::config::set_home_override(home.to_path_buf());
    let mut cfg: Config = serde_json::from_value(json!({
        "harnesses": {"fake": {"argv": ["python3", FAKE], "family": "codex"}},
        "defaultHarness": "fake",
        "permissionPolicy": "approve-all"
    }))
    .unwrap();
    cfg.store.mode = StoreMode::Memory;
    let store = acpmux::store::open(&cfg.store, Path::new("/nonexistent")).unwrap();
    Hub::new(cfg, store)
}

struct Control {
    tx: mpsc::Sender<String>,
    rx: mpsc::Receiver<String>,
    next: i64,
}

impl Control {
    fn new(hub: &Arc<Hub>) -> Self {
        let (tx, in_rx) = mpsc::channel(64);
        let (out_tx, rx) = mpsc::channel(65536);
        tokio::spawn(serve_connection_with(hub.clone(), in_rx, out_tx, Origin::Local));
        Self { tx, rx, next: 0 }
    }

    async fn post(&mut self, m: &str, params: Value) -> i64 {
        self.next += 1;
        self.tx.send(RpcMessage::request(self.next, m, params).to_line()).await.unwrap();
        self.next
    }

    async fn answer(&mut self, id: i64, within: Duration) -> Option<Value> {
        let deadline = Instant::now() + within;
        loop {
            let line = tokio::time::timeout_at(deadline, self.rx.recv()).await.ok()??;
            let v: Value = serde_json::from_str(&line).ok()?;
            if v.get("id") == Some(&json!(id)) && v.get("method").is_none() {
                return Some(v);
            }
        }
    }

    async fn call(&mut self, m: &str, params: Value) -> Value {
        let id = self.post(m, params).await;
        self.answer(id, BOUND).await.unwrap_or_else(|| panic!("{m}: no answer in {BOUND:?}"))
    }

    async fn new_session(&mut self, cwd: &Path, name: &str) -> String {
        let made = self
            .call(
                method::SESSION_NEW,
                json!({"cwd": cwd, "mcpServers": [], "_meta": {"acpmux": {"name": name}}}),
            )
            .await;
        made["result"]["sessionId"].as_str().unwrap_or_else(|| panic!("{made}")).to_owned()
    }

    async fn prompt(&mut self, session: &str, text: &str) -> i64 {
        self.post(
            method::SESSION_PROMPT,
            json!({"sessionId": session, "prompt": [{"type": "text", "text": text}]}),
        )
        .await
    }

    async fn seed(&mut self, session: &str, turns: u64) {
        let pad = "lorem ipsum dolor sit amet ".repeat(37);
        let started = Instant::now();
        for n in 0..turns {
            if n > 0 && n % 500 == 0 {
                eprintln!("rtt: seeding turn {n}/{turns}, {:?} so far", started.elapsed());
            }
            let id = self.prompt(session, &format!("turn {n}: {pad}")).await;
            let v = self.answer(id, BOUND).await.unwrap_or_else(|| panic!("seed turn {n} hung"));
            assert!(v.get("error").is_none(), "seed turn {n}: {v}");
        }
    }
}

// ---------------------------------------------------------------------------------------------
// The audit table: the rows of pm/rtt/INVENTORY.md

/// What a row measures; `Na` rows print `"ms":null` and the reason.
#[derive(Clone, Copy, PartialEq, Eq, Hash, Debug)]
enum Op {
    OpenInitWatch,
    Attach,
    Opener,
    Reattach,
    GapProbe,
    Scroll,
    SendPrompt,
    /// Mac-local: `connect_acpmux` alone (a fresh loopback WebSocket, services.rs:1163).
    HostDial,
    /// Mac-local: `trusted_session_query` = a fresh loopback WebSocket + `_acpmux/info`
    /// (services.rs:1510, no `initialize`, as the host sends it).
    HostCanonicalize,
    /// Mac-local: `current_mode` = `_acpmux/info` on the kept side socket (services.rs:1473).
    HostMode,
    /// TCP + WebSocket handshake through the shaped link.
    Dial,
    /// `initialize` alone: its answer from its own write.
    Initialize,
    /// `_acpmux/sessions {withTools:false, limit:2048}`: one list page as the peer reads it.
    SessionsPage,
    /// `_acpmux/attach` of the send chat (the hidden first-touch attach before a prompt).
    SendAttach,
    /// `session/prompt` to its answer (the turn's end).
    PromptEnd,
    FilePutBegin,
    /// Every `_acpmux/file_put_chunk` of the file, each awaited in turn (ms = their sum).
    FilePutChunks,
    FilePutFinish,
    /// `session/prompt` naming the upload by id, to its `user_message` record.
    UploadPrompt,
}

const ALL_OPS: &[Op] = &[
    Op::OpenInitWatch,
    Op::Attach,
    Op::Opener,
    Op::Reattach,
    Op::GapProbe,
    Op::Scroll,
    Op::SendPrompt,
    Op::HostDial,
    Op::HostCanonicalize,
    Op::HostMode,
    Op::Dial,
    Op::Initialize,
    Op::SessionsPage,
    Op::SendAttach,
    Op::PromptEnd,
    Op::FilePutBegin,
    Op::FilePutChunks,
    Op::FilePutFinish,
    Op::UploadPrompt,
];

enum Exec {
    Measure(Op),
    /// Measured on a stand-in: the note says what stands in for what.
    Stand(Op, &'static str),
    Na(&'static str),
}

/// The Mac-local waits, replayed: the same loopback WebSocket and request the host makes,
/// against the hub directly (no shaper; the profile does not apply, the hub's load does).
const LOOP: &str = "replayed on loopback against the hub, unshaped: the host's own request (cmux-mobile-host services.rs), not a network round trip; the hub's load applies, the profile does not";
/// The Linux peer, stood in by this hub behind the shaped link.
const PEER_STAND: &str = "one acpmux hub behind the shaped link stands in for the Linux peer; the forwarding Mac hub's own time is not in it";
const WS_DIAL: &str = "the ws path only: TCP + WebSocket handshake through the shaped link; the staggered race and the wg/ssh/hub paths are not in this rig";
const UPLOAD_BYTES: usize = 2 << 20;

struct Row {
    flow: &'static str,
    pair: &'static str,
    step: u32,
    rpc: &'static str,
    caller: &'static str,
    waits_on: u32,
    verdict: &'static str,
    why: &'static str,
    exec: Exec,
}

const HOST: &str = "Mac-host-local wait in cmux-mobile-host (no network round trip); the acpmux rig has no mobile host";
const SWIFT: &str = "client-side Swift wait or CPU, not replayable headless";
const PEER: &str = "needs a second host (ssh/relay peer); this rig has one hub";
const CARRIER: &str = "Mac<->Linux carrier line inside cmux-mobile-host; not in this crate's rig";
const UPLOAD: &str =
    "link `upload` channel (cmux-mobile-link/mobile-host); not reachable from the acpmux hub rig";
const LINK: &str =
    "WireGuard/auth/channel setup in cmux-mobile-link; covered by the link benches, not this rig";
const DAEMON: &str =
    "terminal `daemon` channel (cmux-mobile-host to the cmux daemon); not in this crate's rig";

const PUSH_HOP: &str = "push hop (optimum-ledger row 16): not replayable on the acpmux hub rig; the send-to-receive number needs a device and a Worker with PUSH_SENT_AT_PROBE=1 (PushLatencyProbe)";
const IOSM: &str = "ios-mac";
const IOSL: &str = "ios-linux";
const MACL: &str = "mac-linux";
const AH: &str = "cmux-next-ios/CmuxMobileKit/Sources/CmuxMobileLive/AcpmuxHub.swift";
const SVC: &str = "cmux-next-ios/rust/crates/cmux-mobile-host/src/services.rs";
const CLD: &str = "cmux-next-ios/rust/crates/cmux-mobile-host/src/cloud_acp.rs";
const DTS: &str = "cmux-next-ios/CmuxMobileKit/Sources/CmuxMobileLive/DaemonTerminalSession.swift";
const WS: &str = "cmux-next-ios/CmuxMobileKit/Sources/CmuxMobileLive/WorkspaceSync.swift";

#[allow(clippy::too_many_arguments)]
fn r(
    flow: &'static str,
    pair: &'static str,
    step: u32,
    rpc: &'static str,
    caller: &'static str,
    waits_on: u32,
    verdict: &'static str,
    why: &'static str,
    exec: Exec,
) -> Row {
    Row { flow, pair, step, rpc, caller, waits_on, verdict, why, exec }
}

fn table() -> Vec<Row> {
    use Exec::{Measure as M, Na, Stand};
    let mut t = vec![
        // send text
        r(
            "send",
            IOSM,
            1,
            "session/prompt",
            "CmuxMobileLive/AcpmuxHub.swift:962",
            0,
            "optimistic",
            "the person's own text is local at the tap; the wait only confirms it (user_message record, same promptId)",
            M(Op::SendPrompt),
        ),
        r(
            "send",
            IOSM,
            2,
            "_acpmux/info (canonicalize)",
            "cmux-mobile-host/src/services.rs:1536",
            1,
            "deletable",
            "fresh loopback WS per request just to map an alias the phone already has canonical",
            Stand(Op::HostCanonicalize, LOOP),
        ),
        r(
            "send",
            IOSM,
            3,
            "_acpmux/info (current_mode)",
            "cmux-mobile-host/src/services.rs:1473",
            2,
            "pipelinable",
            "mode only picks marked vs refusal; acpmux decides by the credential; cache from the watch stream",
            Stand(Op::HostMode, LOOP),
        ),
        r(
            "send",
            IOSL,
            1,
            "session/prompt",
            "cmux-mobile-host/src/cloud_acp.rs:366",
            0,
            "optimistic",
            "as ios-mac plus the Linux hop; answer at prompt_accepted",
            Na(CARRIER),
        ),
        r(
            "send",
            IOSL,
            2,
            "agent-session-attach limit:1 then agent-session-prompt",
            "cmux-mobile-host/src/cloud_acp.rs:200",
            1,
            "pipelinable",
            "carrier answers lines in order: write both at once or cache the mode",
            Na(CARRIER),
        ),
        r(
            "send",
            IOSL,
            3,
            "identify + set-client-info (per channel open)",
            "cmux-mobile-host/src/services.rs:488",
            0,
            "pipelinable",
            "two lines in one write, read both replies after",
            Na(CARRIER),
        ),
        r(
            "send",
            MACL,
            1,
            "_acpmux/attach (hidden, first touch)",
            "acpmux/src/server/peer_forward.rs:807",
            0,
            "pipelinable",
            "peer answers a link's requests in order: attach and prompt can go back to back",
            Stand(Op::SendAttach, PEER_STAND),
        ),
        r(
            "send",
            MACL,
            2,
            "session/prompt",
            "acpmux/src/peer_runtime_io.rs:959",
            1,
            "needed",
            "the request is the work",
            Stand(Op::PromptEnd, PEER_STAND),
        ),
        r(
            "send",
            MACL,
            3,
            "user_message at MUX_PROMPT_ACCEPTED",
            "acpmux/src/server/peer_forward.rs:855",
            2,
            "optimistic",
            "local hub can append under the promptId at forward time and reconcile on accepted",
            Stand(Op::SendPrompt, PEER_STAND),
        ),
        // send attachment / video
        r(
            "send-attachment",
            IOSM,
            1,
            "upload channel open {name,size,cwd}",
            "CmuxMobileTransport/LinkUpload.swift:84",
            0,
            "needed",
            "no ack; bytes go straight out",
            Na(UPLOAD),
        ),
        r(
            "send-attachment",
            IOSM,
            2,
            "upload_folder -> daemon list-workspaces",
            "cmux-mobile-host/src/services.rs:2063",
            1,
            "pipelinable",
            "check can run while bytes stream; only publish needs it",
            Na(HOST),
        ),
        r(
            "send-attachment",
            IOSM,
            3,
            "stream size bytes (192 KiB writes)",
            "cmux-mobile-host/src/services.rs:2162",
            1,
            "needed",
            "the bytes are the cost: size over bandwidth",
            Na(UPLOAD),
        ),
        r(
            "send-attachment",
            IOSM,
            4,
            "flush+sync_all then reply {path,size}",
            "cmux-mobile-host/src/services.rs:2201",
            3,
            "deletable",
            "fsync of the whole file before the reply is on the critical path; reply first, sync after",
            Na(HOST),
        ),
        r(
            "send-attachment",
            IOSM,
            5,
            "wait for reply, no timeout",
            "CmuxMobileTransport/LinkUpload.swift:116",
            4,
            "needed",
            "unbounded wait is the hang: a stalled channel holds both sides until the link dies",
            Na(UPLOAD),
        ),
        r(
            "send-attachment",
            IOSM,
            6,
            "session/prompt with blocks",
            "CmuxMobileLive/AcpmuxHub.swift:1059",
            5,
            "pipelinable",
            "path is named by the Mac after the upload; serial by design unless the phone picks the name",
            M(Op::SendPrompt),
        ),
        r(
            "send-attachment",
            IOSM,
            7,
            "base64 of PDFs/frames before the prompt",
            "CmuxMobileLive/AcpmuxHub.swift:1120",
            5,
            "pipelinable",
            "CPU on the phone; could run during the upload",
            Na(SWIFT),
        ),
        r(
            "send-attachment",
            IOSL,
            1,
            "(refused) attachment blocks",
            "cmux-mobile-host/src/cloud_acp.rs:167",
            0,
            "needed",
            "text blocks only: no upload round trip exists; the missing feature is the finding",
            Na(CARRIER),
        ),
        r(
            "send-attachment",
            MACL,
            1,
            "_acpmux/file_put_begin",
            "acpmux/src/hub/file_uploads.rs:970",
            0,
            "pipelinable",
            "client can mint the uploadId and send chunk 0 without waiting",
            Stand(Op::FilePutBegin, PEER_STAND),
        ),
        r(
            "send-attachment",
            MACL,
            2,
            "_acpmux/file_put_chunk x N (512 KiB, stop and wait)",
            "acpmux/src/hub/file_uploads.rs:978",
            1,
            "pipelinable",
            "N chunks = N round trips; window them and check the offset at finish",
            Stand(Op::FilePutChunks, PEER_STAND),
        ),
        r(
            "send-attachment",
            MACL,
            3,
            "_acpmux/file_put_finish",
            "acpmux/src/hub/file_uploads.rs:992",
            2,
            "pipelinable",
            "can ride with the last chunk",
            Stand(Op::FilePutFinish, PEER_STAND),
        ),
        r(
            "send-attachment",
            MACL,
            4,
            "session/prompt with upload meta",
            "acpmux/src/server/peer_forward.rs:645",
            3,
            "needed",
            "the work",
            Stand(Op::UploadPrompt, PEER_STAND),
        ),
        // open
        r(
            "open",
            IOSM,
            1,
            "signaling + WG handshake + path probes",
            "cmux-next-ios/rust/crates/cmux-mobile-link/src/dial/mod.rs:576",
            0,
            "needed",
            "keys and endpoints must be exchanged; already one bundle",
            Na(LINK),
        ),
        r(
            "open",
            IOSM,
            2,
            "auth channel challenge/signature",
            "cmux-mobile-host/src/pairing.rs:788",
            1,
            "pipelinable",
            "shared with the first writes behind link.gate(); resumed paired phones could skip a fresh challenge",
            Na(LINK),
        ),
        r(
            "open",
            IOSM,
            3,
            "Mac connects loopback WS before relaying",
            "cmux-mobile-host/src/services.rs:1211",
            2,
            "pipelinable",
            "Mac-local; keep a warm socket",
            Stand(Op::HostDial, LOOP),
        ),
        r(
            "open",
            IOSM,
            4,
            "initialize + _acpmux/watch {limit:100} (dial included)",
            "CmuxMobileLive/AcpmuxHub.swift:200",
            3,
            "needed",
            "already pipelined into one round trip",
            M(Op::OpenInitWatch),
        ),
        r(
            "open",
            IOSM,
            5,
            "_acpmux/watch cursor pages (readRest)",
            "CmuxMobileLive/AcpmuxHub.swift:259",
            4,
            "optimistic",
            "background; first page already drawn",
            Na("background pages after the first draw; not on the critical path"),
        ),
        r(
            "open",
            IOSM,
            6,
            "_acpmux/events per chat (seedPending), serial",
            "CmuxMobileLive/AcpmuxHub.swift:270",
            4,
            "pipelinable",
            "serial for-loop; send all then read all",
            Na(SWIFT),
        ),
        r(
            "open",
            IOSM,
            7,
            "daemon batch (set-client-info, identify, subscribe, list-workspaces...)",
            "CmuxMobileLive/WorkspaceSync.swift:164",
            2,
            "needed",
            "already one write",
            Na(DAEMON),
        ),
        r(
            "open",
            IOSM,
            8,
            "list-workspaces retry without known/limit",
            "CmuxMobileLive/WorkspaceSync.swift:284",
            7,
            "pipelinable",
            "only when the Mac refused a guessed capability",
            Na(DAEMON),
        ),
        r(
            "open",
            IOSM,
            9,
            "refresh() whole tree after first window",
            "CmuxMobileLive/WorkspaceSync.swift:300",
            7,
            "optimistic",
            "first window drawn first",
            Na(DAEMON),
        ),
        r(
            "open",
            IOSM,
            10,
            "_acpmux/attach newest page",
            "CmuxMobileLive/AcpmuxHub.swift:1805",
            4,
            "pipelinable",
            "session-scoped read acpmux answers in order behind watch; can be written with initialize+watch when the last session is remembered",
            M(Op::Attach),
        ),
        r(
            "open",
            IOSM,
            11,
            "_acpmux/info canonicalize on the attach",
            "cmux-mobile-host/src/services.rs:1536",
            10,
            "deletable",
            "see send step 2",
            Stand(Op::HostCanonicalize, LOOP),
        ),
        r(
            "open",
            IOSM,
            12,
            "_acpmux/events opener (user_message) when page has no prompt",
            "CmuxMobileLive/AcpmuxHub.swift:1880",
            10,
            "pipelinable",
            "only inside a long turn; could share the attach write",
            M(Op::Opener),
        ),
        r(
            "open",
            IOSL,
            1,
            "phone hop steps 1-4 as ios-mac",
            "cmux-mobile-host/src/services.rs:1211",
            0,
            "needed",
            "same as ios-mac open",
            Na(LINK),
        ),
        r(
            "open",
            IOSL,
            5,
            "carrier open: request_cloud_links, identify, set-client-info serial",
            "cmux-mobile-host/src/services.rs:415",
            4,
            "pipelinable",
            "two lines in one write",
            Na(CARRIER),
        ),
        r(
            "open",
            IOSL,
            6,
            "_acpmux/watch -> list-workspaces on the carrier (full directory)",
            "cmux-mobile-host/src/cloud_acp.rs:145",
            5,
            "needed",
            "cacheable on the Mac across channel opens",
            Na(CARRIER),
        ),
        r(
            "open",
            MACL,
            1,
            "path dial (staggered race)",
            "acpmux/src/peer_paths.rs:91",
            0,
            "needed",
            "already a race",
            Stand(Op::Dial, WS_DIAL),
        ),
        r(
            "open",
            MACL,
            2,
            "hub carrier ticket + relay circuit hello",
            "acpmux/src/hub_carrier.rs:68",
            1,
            "pipelinable",
            "prefetch or cache the ticket",
            Na(PEER),
        ),
        r(
            "open",
            MACL,
            3,
            "initialize",
            "acpmux/src/peer_runtime_io.rs:699",
            1,
            "needed",
            "feature negotiation",
            Stand(Op::Initialize, PEER_STAND),
        ),
        r(
            "open",
            MACL,
            4,
            "_acpmux/watch (pipelined only when the last link had the feature)",
            "acpmux/src/peer.rs:645",
            3,
            "pipelinable",
            "persist the feature per peer on disk",
            Stand(
                Op::SessionsPage,
                "the first link's serial list read, as one `_acpmux/sessions` page (2048 rows, peer.rs:708; the whole list at this load) on one hub behind the shaped link",
            ),
        ),
        r(
            "open",
            MACL,
            5,
            "_acpmux/sessions pages, serial until cursor null",
            "acpmux/src/peer_list_read.rs:90",
            4,
            "pipelinable",
            "6 MB list took 66 s on a far restart; parallel pages or the delta from the last whole list",
            Stand(
                Op::SessionsPage,
                "one page is the whole list at this load (2048-row pages, peer.rs:708); one hub behind the shaped link stands in for the peer",
            ),
        ),
        r(
            "open",
            MACL,
            6,
            "replay_chat: attach afterSeq per attached chat before Connected",
            "acpmux/src/peer_runtime_io.rs:800",
            5,
            "pipelinable",
            "send behind watch; admit requests before the longest chat finishes",
            Stand(Op::Reattach, PEER_STAND),
        ),
        // attach
        r(
            "attach",
            IOSM,
            1,
            "_acpmux/attach newest page {limit:400,maxBytes:128K}",
            "CmuxMobileLive/AcpmuxHub.swift:1805",
            0,
            "needed",
            "shows rows; the kept copy draws first",
            M(Op::Attach),
        ),
        r(
            "attach",
            IOSM,
            2,
            "_acpmux/attach reattach afterSeq + beforeSeq tail",
            "CmuxMobileLive/AcpmuxHub.swift:1790",
            0,
            "needed",
            "one round trip for the gap",
            M(Op::Reattach),
        ),
        r(
            "attach",
            IOSM,
            3,
            "_acpmux/events afterSeq gap probe",
            "CmuxMobileLive/AcpmuxHub.swift:1833",
            2,
            "pipelinable",
            "the attach answer already knows hasMore/lastSeq; no second read",
            M(Op::GapProbe),
        ),
        r(
            "attach",
            IOSM,
            4,
            "_acpmux/events gap fill pages (background)",
            "CmuxMobileLive/AcpmuxHub.swift:1963",
            2,
            "optimistic",
            "after the newest page shows",
            Na("background after the newest page shows"),
        ),
        r(
            "attach",
            IOSL,
            1,
            "agent-session-attach limit:1 then attach",
            "cmux-mobile-host/src/cloud_acp.rs:208",
            0,
            "pipelinable",
            "2 carrier round trips on a cold surface",
            Na(CARRIER),
        ),
        r(
            "attach",
            MACL,
            1,
            "_acpmux/attach of a remote chat",
            "acpmux/src/server/peer_forward.rs:800",
            0,
            "needed",
            "one round trip",
            Stand(Op::Attach, PEER_STAND),
        ),
        r(
            "attach-terminal",
            IOSM,
            1,
            "daemon open + batch set-client-info, identify, attach-surface",
            "CmuxMobileLive/DaemonTerminalSession.swift:1093",
            0,
            "needed",
            "already pipelined",
            Na(DAEMON),
        ),
        r(
            "attach-terminal",
            IOSM,
            2,
            "attach-surface only after identify (size unknown)",
            "CmuxMobileLive/DaemonTerminalSession.swift:1140",
            1,
            "pipelinable",
            "send with the size the view will have",
            Na(DAEMON),
        ),
        r(
            "attach-terminal",
            IOSM,
            3,
            "attach retry without replay_history_start",
            "CmuxMobileLive/DaemonTerminalSession.swift:1162",
            2,
            "pipelinable",
            "identify already lists windowReplay",
            Na(DAEMON),
        ),
        // scroll
        r(
            "scroll",
            IOSM,
            1,
            "_acpmux/events {beforeSeq,limit:400,maxBytes:256K}",
            "CmuxMobileLive/AcpmuxHub.swift:2290",
            0,
            "optimistic",
            "next page read ahead and held; first scroll after open has one round trip; prefetch behind the open removes it",
            M(Op::Scroll),
        ),
        r(
            "scroll",
            IOSM,
            2,
            "terminal loadOlderHistory (attach-surface replace)",
            "CmuxMobileLive/DaemonTerminalSession.swift:810",
            0,
            "optimistic",
            "prefetched once; beyond the tail window the replacing attach re-sends rows already held",
            Na(DAEMON),
        ),
        r(
            "scroll",
            IOSL,
            1,
            "agent-session-attach limit:1 then events",
            "cmux-mobile-host/src/cloud_acp.rs:181",
            0,
            "pipelinable",
            "2 carrier round trips",
            Na(CARRIER),
        ),
        r(
            "scroll",
            MACL,
            1,
            "_acpmux/events beforeSeq forwarded",
            "acpmux/src/server/peer_forward.rs:971",
            0,
            "needed",
            "1 round trip per page; prefetch is the client's job",
            Stand(Op::Scroll, PEER_STAND),
        ),
        r(
            "push",
            IOSM,
            1,
            "Mac gate: first finished turn at once, the rest of 30 s held",
            "cmux-next-ios/rust/crates/cmux-mobile-host/src/notify.rs:371",
            0,
            "needed",
            "one finished-turn push per session per 30 s window (TURN_WINDOW, notify.rs:96): the first goes at once, the newest of the rest waits for the window end, so a later turn can wait up to 30 s",
            Na(PUSH_HOP),
        ),
        r(
            "push",
            IOSM,
            2,
            "Mac access token (cached, refreshed 60 s early)",
            "cmux-next-ios/rust/crates/cmux-mobile-host/src/notify.rs:527",
            1,
            "pipelinable",
            "a Stack refresh round trip only when the cached token is within 60 s of expiry (auth.rs:78); start it with the event, not after the gate",
            Na(PUSH_HOP),
        ),
        r(
            "push",
            IOSM,
            3,
            "ask only: fresh loopback WS, initialize, _acpmux/info for decisionNonce",
            "cmux-next-ios/rust/crates/cmux-mobile-host/src/sealed_notify.rs:236",
            2,
            "pipelinable",
            "a question or permission push opens a new acpmux socket just to read the nonce, timeout 3 s (sealed_notify.rs:259); the nonce could ride on the event",
            Na(PUSH_HOP),
        ),
        r(
            "push",
            IOSM,
            4,
            "POST /v1/devices/{mac}/notify (lead)",
            "cmux-next-ios/rust/crates/cmux-mobile-host/src/notify.rs:548",
            3,
            "needed",
            "one HTTPS round trip Mac to the Worker; its answer decides whether batches follow (batches_follow, notify.rs:576)",
            Na(PUSH_HOP),
        ),
        r(
            "push",
            IOSM,
            5,
            "Worker: listOwnerPush (store read) then turnPushAllowed (UserHub DO call, 15 s window)",
            "cmux-next-ios/backend/src/index.ts:602",
            4,
            "pipelinable",
            "two serial reads before APNs: the registration list and the coalescing DO call (index.ts:613); independent, can run together",
            Na(PUSH_HOP),
        ),
        r(
            "push",
            IOSM,
            6,
            "Worker: APNs POST per phone (HTTP/2, parallel across phones)",
            "cmux-next-ios/backend/src/push.ts:733",
            5,
            "needed",
            "the hand-off to APNs; the probe stamps cmuxSentAtMs here (push.ts apnsRequest); no fixed delay and no retry in this sender",
            Na(PUSH_HOP),
        ),
        r(
            "push",
            IOSM,
            7,
            "further batches, one notify per 20 phones, after the lead answers",
            "cmux-next-ios/rust/crates/cmux-mobile-host/src/notify.rs:561",
            6,
            "pipelinable",
            "each batch waits for the previous answer; only with more than 20 paired phones",
            Na(PUSH_HOP),
        ),
        r(
            "push",
            IOSM,
            8,
            "APNs to device, then NotificationService.didReceive (PushLatencyProbe.record)",
            "cmux-next-ios/NotificationService/NotificationService.swift:16",
            7,
            "needed",
            "Apple's delivery; the extension logs receive minus cmuxSentAtMs: the send-to-receive row of the ledger (optimum 1 s p50)",
            Na(PUSH_HOP),
        ),
    ];
    let _ = (SVC, CLD, DTS, WS, AH);
    t.shrink_to_fit();
    t
}

// ---------------------------------------------------------------------------------------------
// Replay

struct Fixture {
    hub_addr: std::net::SocketAddr,
    token: String,
    big: String,
    small: String,
    _hub: Arc<Hub>,
    _control: Control,
    _scratch: daemon_env::Scratch,
}

async fn fixture(load: &str, duress_turns: u64) -> Fixture {
    let scratch = daemon_env::Scratch::new(&format!("rtt-{load}"));
    let hub = hub(&scratch.path().join("home"));
    let listener = app_ws::listen(&hub).await;
    let hub_addr: std::net::SocketAddr =
        listener.url.trim_start_matches("ws://").trim_end_matches('/').parse().unwrap();
    let mut control = Control::new(&hub);
    let cwd = scratch.path().join("work");
    std::fs::create_dir_all(&cwd).unwrap();
    let (sessions, turns) = if load == "duress" { (50, duress_turns) } else { (5, BASE_TURNS) };
    let big = control.new_session(&cwd, "rtt-big").await;
    let small = control.new_session(&cwd, "rtt-send").await;
    for n in 2..sessions {
        control.new_session(&cwd, &format!("rtt-{n}")).await;
    }
    control.seed(&big, turns).await;
    control.seed(&small, BASE_TURNS).await;
    if load == "duress" {
        // A chat streaming into the measured one while it is measured (ticks of 100 ms, 20 min).
        let _ = control.prompt(&big, "ticking:12000:100").await;
    }
    Fixture {
        hub_addr: listener
            .url
            .trim_start_matches("ws://")
            .trim_end_matches('/')
            .parse()
            .unwrap_or(hub_addr),
        token: listener.token,
        big,
        small,
        _hub: hub,
        _control: control,
        _scratch: scratch,
    }
}

type Measured = Result<(f64, u64, u64), String>;

async fn replay(shaper: &Shaper, fx: &Fixture, run: u64) -> HashMap<Op, Measured> {
    let mut out: HashMap<Op, Measured> = HashMap::new();
    host_local(fx, &mut out).await;
    let start = Instant::now();
    let deadline = start + BOUND;
    // open: dial, then initialize + watch written together, both answered.
    let opened = async {
        let mut link = tokio::time::timeout_at(deadline, Link::dial(shaper.addr()))
            .await
            .map_err(|_| "connect timed out".to_owned())??;
        let dialed = Instant::now();
        out.insert(Op::Dial, Ok((ms(dialed - start), 0, 0)));
        let meta = json!({"localAppToken": fx.token});
        let (init, u1) = link
            .post(
                "initialize",
                json!({"protocolVersion": 1, "clientInfo": {"name": "cmux-ios", "version": "1"},
                       "clientCapabilities": {}, "_meta": {"acpmux": meta}}),
            )
            .await?;
        let (watch, u2) =
            link.post("_acpmux/watch", json!({"enabled": true, "limit": WATCH_LIMIT})).await?;
        let (a1, _, d1) = link.answer(init, deadline).await?;
        out.insert(Op::Initialize, Ok((ms(a1 - dialed), u1, d1)));
        let (a2, _, d2) = link.answer(watch, deadline).await?;
        Ok::<_, String>((link, (ms(a1.max(a2) - start), u1 + u2, d1 + d2)))
    }
    .await;
    let mut link = match opened {
        Ok((l, m)) => {
            out.insert(Op::OpenInitWatch, Ok(m));
            l
        }
        Err(e) => {
            out.insert(Op::OpenInitWatch, Err(e));
            return out;
        }
    };
    let session = fx.big.as_str();
    let attach_params = json!({"sessionId": session, "limit": PAGE_SIZE, "kinds": kinds(),
        "eventStream": true, "maxBytes": OPEN_BYTES, "toolOutputMaxBytes": TOOL_OUTPUT_MAX_BYTES});
    let attached = link.rt("_acpmux/attach", attach_params).await;
    let (oldest, newest) = match &attached {
        Ok((_, _, _, v)) => {
            let seqs = rows(v);
            (seqs.iter().copied().min(), seqs.iter().copied().max())
        }
        Err(_) => (None, None),
    };
    out.insert(Op::Attach, attached.map(|(a, b, c, _)| (a, b, c)));
    let (Some(oldest), Some(newest)) = (oldest, newest) else {
        for op in [Op::Opener, Op::Reattach, Op::GapProbe, Op::Scroll] {
            out.insert(op, Err("the attach reply carried no rows".into()));
        }
        return finish_send(link, fx, run, out).await;
    };
    let opener = link
        .rt(
            "_acpmux/events",
            json!({"sessionId": session, "beforeSeq": oldest, "kinds": ["user_message"], "limit": 1}),
        )
        .await;
    out.insert(Op::Opener, opener.map(|(a, b, c, _)| (a, b, c)));
    let reattach = link
        .rt(
            "_acpmux/attach",
            json!({"sessionId": session, "limit": PAGE_SIZE, "kinds": kinds(), "eventStream": true,
                   "afterSeq": newest.saturating_sub(5), "beforeSeq": 1u64 << 40}),
        )
        .await;
    out.insert(Op::Reattach, reattach.map(|(a, b, c, _)| (a, b, c)));
    let gap = link
        .rt(
            "_acpmux/events",
            json!({"sessionId": session, "afterSeq": newest, "kinds": kinds(), "limit": PAGE_SIZE}),
        )
        .await;
    out.insert(Op::GapProbe, gap.map(|(a, b, c, _)| (a, b, c)));
    let scroll = link
        .rt(
            "_acpmux/events",
            json!({"sessionId": session, "beforeSeq": oldest, "kinds": kinds(), "limit": PAGE_SIZE,
                   "maxBytes": SCROLL_BYTES}),
        )
        .await;
    out.insert(Op::Scroll, scroll.map(|(a, b, c, _)| (a, b, c)));
    let page = link.rt("_acpmux/sessions", json!({"withTools": false, "limit": 2048})).await;
    out.insert(Op::SessionsPage, page.map(|(a, b, c, _)| (a, b, c)));
    finish_send(link, fx, run, out).await
}

/// The Mac host's own waits on its acpmux, replayed as it makes them: a fresh loopback socket
/// (`connect_acpmux`), `trusted_session_query`'s fresh socket + `_acpmux/info`, and
/// `current_mode`'s `_acpmux/info` on its kept side socket (the second ask; the first opens it).
async fn host_local(fx: &Fixture, out: &mut HashMap<Op, Measured>) {
    let start = Instant::now();
    let dial = match tokio::time::timeout_at(start + BOUND, Link::dial(fx.hub_addr)).await {
        Ok(Ok(l)) => Ok(l),
        Ok(Err(e)) => Err(e),
        Err(_) => Err("loopback connect timed out".to_owned()),
    };
    out.insert(
        Op::HostDial,
        dial.as_ref().map(|_| (ms(start.elapsed()), 0, 0)).map_err(Clone::clone),
    );
    drop(dial);
    let start = Instant::now();
    let canon = async {
        let mut l = Link::dial(fx.hub_addr).await?;
        let (_, up, down, v) =
            l.rt("_acpmux/info", json!({"sessionId": fx.big, "waitLogs": false})).await?;
        if v.get("sessionId").and_then(Value::as_str).is_none() {
            return Err(format!("_acpmux/info named no sessionId: {v}"));
        }
        Ok::<_, String>((ms(start.elapsed()), up, down))
    };
    out.insert(
        Op::HostCanonicalize,
        tokio::time::timeout(BOUND, canon).await.unwrap_or_else(|_| Err("timed out".into())),
    );
    let mode = async {
        let mut side = Link::dial(fx.hub_addr).await?;
        side.rt("_acpmux/info", json!({"sessionId": fx.small})).await?;
        let (t, up, down, _) = side.rt("_acpmux/info", json!({"sessionId": fx.small})).await?;
        Ok::<_, String>((t, up, down))
    };
    out.insert(
        Op::HostMode,
        tokio::time::timeout(BOUND, mode).await.unwrap_or_else(|_| Err("timed out".into())),
    );
}

/// A prompt to the small chat, shown as sent when its `user_message` record comes back.
async fn finish_send(
    mut link: Link,
    fx: &Fixture,
    run: u64,
    mut out: HashMap<Op, Measured>,
) -> HashMap<Op, Measured> {
    let attach = link
        .rt(
            "_acpmux/attach",
            json!({"sessionId": fx.small, "limit": 20, "kinds": kinds(), "eventStream": true}),
        )
        .await;
    match attach {
        Ok((t, up, down, _)) => {
            out.insert(Op::SendAttach, Ok((t, up, down)));
        }
        Err(e) => {
            for op in [Op::SendAttach, Op::SendPrompt, Op::PromptEnd] {
                out.insert(op, Err(format!("attach of the send chat: {e}")));
            }
            return out;
        }
    }
    let prompt_id = format!("rtt-{run}-{}", uuid::Uuid::now_v7());
    let start = Instant::now();
    let deadline = start + BOUND;
    let sent = link
        .post(
            method::SESSION_PROMPT,
            json!({"sessionId": fx.small, "prompt": [{"type": "text", "text": "ping"}],
                   "_meta": {"acpmux": {"promptId": prompt_id, "steer": false, "resend": false}}}),
        )
        .await;
    let (res, ended) = match sent {
        Err(e) => (Err(e.clone()), Err(e)),
        Ok((id, up)) => {
            let shown = shown(&mut link, id, &prompt_id, start, up, deadline).await;
            let ended =
                link.answer(id, deadline).await.map(|(at, _, down)| (ms(at - start), up, down));
            (shown, ended)
        }
    };
    out.insert(Op::SendPrompt, res);
    out.insert(Op::PromptEnd, ended);
    upload(&mut link, fx, run, &mut out).await;
    out
}

/// The prompt's `user_message` record (same promptId) back as `_acpmux/event`.
/// An error answer to the prompt `id` ends the wait with the refusal.
async fn shown(
    link: &mut Link,
    id: i64,
    prompt_id: &str,
    start: Instant,
    up: u64,
    deadline: Instant,
) -> Measured {
    while let Some((at, v)) = link.notification(deadline).await {
        if v.get("method").is_none() {
            if v.get("id") == Some(&json!(id)) {
                if let Some(e) = v.get("error") {
                    return Err(format!("the prompt was refused: {e}"));
                }
            }
            link.held.push((at, v));
            continue;
        }
        let p = v["params"].to_string();
        if v["method"] == method::MUX_EVENT && p.contains("user_message") && p.contains(prompt_id) {
            return Ok((ms(at - start), up, v.to_string().len() as u64));
        }
    }
    Err("the prompt's user_message never came back".to_owned())
}

/// The Mac-to-peer upload as `hub/file_uploads.rs` `forward_put` sends it: begin, each
/// 512 KiB chunk awaited in turn, finish; then a prompt naming the upload.
async fn upload(link: &mut Link, fx: &Fixture, run: u64, out: &mut HashMap<Op, Measured>) {
    use base64::Engine as _;
    let mut file = b"\x89PNG\r\n\x1a\n\0\0\0\rIHDR".to_vec();
    file.resize(UPLOAD_BYTES, (run % 251) as u8);
    let name = format!("rtt-{run}.png");
    let begin = json!({"sessionId": fx.small, "fileName": name, "size": file.len()});
    let up = match link.rt("_acpmux/file_put_begin", begin).await {
        Ok((t, u, d, v)) => {
            out.insert(Op::FilePutBegin, Ok((t, u, d)));
            match v["uploadId"].as_str() {
                Some(id) => id.to_owned(),
                None => {
                    let e = format!("file_put_begin gave no uploadId: {v}");
                    for op in [Op::FilePutChunks, Op::FilePutFinish, Op::UploadPrompt] {
                        out.insert(op, Err(e.clone()));
                    }
                    return;
                }
            }
        }
        Err(e) => {
            for op in [Op::FilePutBegin, Op::FilePutChunks, Op::FilePutFinish, Op::UploadPrompt] {
                out.insert(op, Err(e.clone()));
            }
            return;
        }
    };
    let (mut total, mut ups, mut downs) = (0.0, 0, 0);
    for (n, piece) in file.chunks(512 << 10).enumerate() {
        let data = base64::engine::general_purpose::STANDARD.encode(piece);
        let put = json!({"sessionId": fx.small, "uploadId": up, "offset": n << 19, "data": data});
        match link.rt("_acpmux/file_put_chunk", put).await {
            Ok((t, u, d, _)) => {
                total += t;
                ups += u;
                downs += d;
            }
            Err(e) => {
                for op in [Op::FilePutChunks, Op::FilePutFinish, Op::UploadPrompt] {
                    out.insert(op, Err(format!("chunk {n}: {e}")));
                }
                return;
            }
        }
    }
    out.insert(Op::FilePutChunks, Ok(((total * 10.0_f64).round() / 10.0, ups, downs)));
    let finish =
        json!({"sessionId": fx.small, "uploadId": up, "fileName": name, "size": file.len()});
    match link.rt("_acpmux/file_put_finish", finish).await {
        Ok((t, u, d, _)) => {
            out.insert(Op::FilePutFinish, Ok((t, u, d)));
        }
        Err(e) => {
            out.insert(Op::FilePutFinish, Err(e.clone()));
            out.insert(Op::UploadPrompt, Err(format!("finish: {e}")));
            return;
        }
    }
    let prompt_id = format!("rtt-up-{run}-{}", uuid::Uuid::now_v7());
    let start = Instant::now();
    let deadline = start + BOUND;
    let blocks = json!([{"type": "text", "text": "see this"},
        {"type": "image", "mimeType": "image/png",
         "_meta": {"acpmux": {"upload": {"uploadId": up, "fileName": name}}}}]);
    let sent = link
        .post(
            method::SESSION_PROMPT,
            json!({"sessionId": fx.small, "prompt": blocks,
                   "_meta": {"acpmux": {"promptId": prompt_id, "steer": false, "resend": false}}}),
        )
        .await;
    let res = match sent {
        Err(e) => Err(e),
        Ok((id, up)) => {
            let r = shown(link, id, &prompt_id, start, up, deadline).await;
            // The turn's end, so the next run starts on an idle chat.
            if r.is_ok() {
                let _ = link.answer(id, deadline).await;
            }
            r
        }
    };
    out.insert(Op::UploadPrompt, res);
}

fn env_list(name: &str, default: &[&str]) -> Vec<String> {
    match std::env::var(name) {
        Ok(v) if !v.trim().is_empty() => {
            v.split(',').map(|s| s.trim().to_owned()).filter(|s| !s.is_empty()).collect()
        }
        _ => default.iter().map(|s| (*s).to_owned()).collect(),
    }
}

fn env_u64(names: &[&str], default: u64) -> u64 {
    names
        .iter()
        .find_map(|n| std::env::var(n).ok().and_then(|v| v.trim().parse().ok()))
        .unwrap_or(default)
}

fn emit(row: &Row, profile: &str, load: &str, run: u64, m: Option<&Measured>) {
    let mut line = json!({
        "flow": row.flow, "pair": row.pair, "step": row.step, "rpc": row.rpc,
        "caller": row.caller, "waits_on": row.waits_on, "profile": profile, "load": load,
        "run": run, "verdict": row.verdict, "why": row.why, "host_os": std::env::consts::OS,
        "rig": "round_trip_audit.rs::round_trips",
    });
    match (m, &row.exec) {
        (Some(Ok((t, up, down))), _) => {
            line["ms"] = json!(t);
            line["up_bytes"] = json!(up);
            line["down_bytes"] = json!(down);
        }
        (Some(Err(e)), _) => {
            line["ms"] = Value::Null;
            line["up_bytes"] = Value::Null;
            line["down_bytes"] = Value::Null;
            line["reason"] = json!(format!("run failed: {e}"));
        }
        (None, Exec::Na(why)) => {
            line["ms"] = Value::Null;
            line["up_bytes"] = Value::Null;
            line["down_bytes"] = Value::Null;
            line["reason"] = json!(why);
        }
        (None, Exec::Measure(_) | Exec::Stand(..)) => {
            line["ms"] = Value::Null;
            line["reason"] = json!("the run did not reach this step");
        }
    }
    if let Exec::Stand(_, note) = &row.exec {
        line["stand_in"] = json!(note);
    }
    println!("ROUNDTRIP {line}");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[ignore = "the round-trip audit bench: run with --ignored --nocapture"]
async fn round_trips() {
    let _ = HERMETIC;
    let file = ProfileFile::builtin();
    let profiles: Vec<_> = env_list("RTT_PROFILES", &["lte", "lossy-3"])
        .iter()
        .map(|n| file.get(n).unwrap_or_else(|| panic!("no link profile {n}")).clone())
        .collect();
    let loads = env_list("RTT_LOADS", &["idle", "duress"]);
    let runs = env_u64(&["RTT_RUNS", "PAIRMATRIX_N"], 5);
    let seed_base = env_u64(&["RTT_SEED_BASE", "PAIRMATRIX_SEED_BASE"], 0);
    let duress_turns = env_u64(&["RTT_DURESS_TURNS"], 5000);
    let rows = table();
    let trace = Trace::new();
    for load in &loads {
        let fx = fixture(load, duress_turns).await;
        for profile in &profiles {
            for run in 0..runs {
                let started = Shaper::start_through(
                    fx.hub_addr,
                    profile.clone(),
                    None,
                    run + seed_base,
                    &trace,
                )
                .await;
                let measured = match started {
                    Ok((shaper, _)) => replay(&shaper, &fx, run).await,
                    Err(e) => {
                        let msg = format!("shaper: {e}");
                        ALL_OPS.iter().map(|op| (*op, Err(msg.clone()))).collect()
                    }
                };
                for row in &rows {
                    match &row.exec {
                        Exec::Measure(op) | Exec::Stand(op, _) => {
                            emit(row, &profile.name, load, run, measured.get(op))
                        }
                        Exec::Na(_) if run == 0 => emit(row, &profile.name, load, run, None),
                        Exec::Na(_) => {}
                    }
                }
            }
        }
    }
}
