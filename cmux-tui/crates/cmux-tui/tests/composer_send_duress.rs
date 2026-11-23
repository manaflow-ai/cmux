//! The iPhone composer's Send under link duress, against a real `cmux-tui` daemon over the
//! `cmux_fault` shaper (the harness of `mobile_link_conditions.rs`, trimmed and copied here: that
//! file is its own test binary).
//!
//! Leo, 2026-11-23: "If it lags, it's like pretty bad because it can get like interrupted and
//! like, because there's like a sort of like double send type thing. [...] if it wasn't connected
//! properly in time, the send doesn't go through, right? Like because like the text goes through.
//! But then the send doesn't go through."
//!
//! The terminal runs a recorder, not `cat`: no echo, every line it reads appended to a log. Each
//! Send's text is a unique `msg-NNN`. After a run one sentinel `END` plus Return on an unshaped
//! socket ends a trailing partial line, then each Send is classified from the log:
//!
//! - applied once: one line `msg-N` (the line's last token, Return after it);
//! - text without submit: `msg-N` ran into the next line (`msg-7msg-8`) or the sentinel's;
//! - double submit: two or more lines ending `msg-N`;
//! - lost both: `msg-N` never appears.
//!
//! Per link condition (`lossy-3`, `lossy-10`, `flap`: good-wifi dark 2 s every 6 s, `redial`:
//! lossy-3 with each Send fired while the phone's channel is being replaced) and per client policy:
//!
//! - `legacy`: a Rust model of the Swift composer at this checkout's base, projected: every Send
//!   two unkeyed writes (text, then Return 60 ms later) through `DaemonTerminalSession`'s input
//!   queue ([`Legacy`], Swift lines cited);
//! - `outbox`: the same person driving `cmux_composer_send::Outbox`.
//!
//! The person taps Send every 300-700 ms (seeded) and taps again when the text comes back to the
//! composer as not sent (up to three times per text); with the outbox never on MaybeSent.
//!
//! `composer_send_duress_table` prints the table (100 Sends per cell, env `COMPOSER_SEND_SENDS`);
//! `composer_send_duress_holds` asserts the outbox (env `COMPOSER_SEND_POLICY=legacy` switches it
//! to the legacy model, to show it fail) on 20 Sends per condition (`COMPOSER_SEND_ASSERT_SENDS`).
//! Every scenario has its own surface and shaper, and they run at once, so a test takes about as
//! long as its slowest scenario.

#![cfg(unix)]

use std::collections::{HashMap, VecDeque};
use std::fs;
use std::io::{BufRead, BufReader, Write};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use base64::Engine;
use cmux_composer_send::{Answer, DEFAULT_HOLD, Form, Outbox, Outcome};
use cmux_fault::Trace;
use cmux_fault::shaper::{ProfileFile, Shaper};
use serde_json::{Value, json};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream, UnixStream};
use tokio::sync::mpsc;

/// The phone's grid (an iPhone 15 portrait at the default font).
const COLS: u64 = 47;
const ROWS: u64 = 38;
/// `DaemonTerminalSession.inputRequestDeadline` and the input lane's `within(.seconds(10))`
/// (DaemonTerminalSession.swift:234, :1656, :1670): one attempt's answer bound, both policies.
const ATTEMPT_TIMEOUT: Duration = Duration::from_secs(10);
/// `DaemonTerminalSession.inputHoldLimit` (DaemonTerminalSession.swift:212).
const INPUT_HOLD: Duration = Duration::from_secs(10);
/// `ComposerSubmit.enterDelay` (ComposerSubmit.swift:21): the mirror path's Return after the text.
const ENTER_DELAY: Duration = Duration::from_millis(60);
/// `DaemonTerminalSession.maxInputInFlight` (DaemonTerminalSession.swift:232).
const MAX_IN_FLIGHT: usize = 64;
/// After a failed channel, the next attach (the model's stand-in for `scheduleAutoReattach`).
const REATTACH_DELAY: Duration = Duration::from_secs(1);
/// A person taps Send again at most this often per text.
const RETAPS: u32 = 3;
/// After the last tap, how long a scenario may take to settle.
const SETTLE: Duration = Duration::from_secs(150);

fn env_u64(name: &str, default: u64) -> u64 {
    std::env::var(name).ok().and_then(|value| value.trim().parse().ok()).unwrap_or(default)
}

fn text_of(msg: usize) -> String {
    format!("msg-{msg:03}")
}

/// splitmix64: the person's seeded pace.
struct Rng(u64);

impl Rng {
    fn next(&mut self) -> u64 {
        self.0 = self.0.wrapping_add(0x9e37_79b9_7f4a_7c15);
        let mut z = self.0;
        z = (z ^ (z >> 30)).wrapping_mul(0xbf58_476d_1ce4_e5b9);
        z = (z ^ (z >> 27)).wrapping_mul(0x94d0_49bb_1331_11eb);
        z ^ (z >> 31)
    }

    fn millis(&mut self, lo: u64, hi: u64) -> Duration {
        Duration::from_millis(lo + self.next() % (hi - lo + 1))
    }
}

// ---------------------------------------------------------------------------------------------
// The daemon (copied from mobile_link_conditions.rs)

struct SyncClient {
    reader: BufReader<std::os::unix::net::UnixStream>,
    writer: std::os::unix::net::UnixStream,
    next: u64,
}

impl SyncClient {
    fn connect(socket: &Path) -> Self {
        let stream = std::os::unix::net::UnixStream::connect(socket).unwrap();
        stream.set_read_timeout(Some(Duration::from_secs(60))).unwrap();
        SyncClient { writer: stream.try_clone().unwrap(), reader: BufReader::new(stream), next: 0 }
    }

    fn call(&mut self, mut request: Value) -> Value {
        self.next += 1;
        request["id"] = json!(self.next);
        writeln!(self.writer, "{request}").unwrap();
        loop {
            let mut line = String::new();
            assert!(self.reader.read_line(&mut line).unwrap() > 0, "daemon closed the socket");
            let Ok(reply) = serde_json::from_str::<Value>(&line) else { continue };
            if reply["id"] == json!(self.next) && reply.get("ok").is_some() {
                assert_eq!(reply["ok"], true, "{request} failed: {reply}");
                return reply["data"].clone();
            }
        }
    }
}

struct Daemon {
    child: Child,
    dir: PathBuf,
    socket: PathBuf,
    pane: Value,
    serial: AtomicU64,
}

impl Daemon {
    fn start() -> Self {
        let stamp = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos();
        let dir = PathBuf::from("/tmp").join(format!("cmux-csd-{}-{stamp}", std::process::id()));
        fs::create_dir_all(&dir).unwrap();
        let socket = dir.join("mux.sock");
        let child = Command::new(env!("CARGO_BIN_EXE_cmux-tui"))
            .args(["--headless", "--socket"])
            .arg(&socket)
            .arg("--state")
            .arg(dir.join("state"))
            .env("CMUX_TUI_CONFIG", dir.join("config.json"))
            .env("SHELL", "/bin/sh")
            .env_remove("SSH_CONNECTION")
            .env_remove("SSH_CLIENT")
            .env_remove("SSH_TTY")
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .unwrap();
        let deadline = Instant::now() + Duration::from_secs(60);
        while std::os::unix::net::UnixStream::connect(&socket).is_err() {
            assert!(Instant::now() < deadline, "daemon did not create {}", socket.display());
            std::thread::sleep(Duration::from_millis(25));
        }
        let mut client = SyncClient::connect(&socket);
        let base = client.call(
            json!({"cmd": "new-workspace", "name": "composer-send", "cols": 120, "rows": 40}),
        );
        let tree = client.call(json!({"cmd": "list-workspaces"}));
        let surface = &base["surface"];
        let pane = tree["workspaces"]
            .as_array()
            .unwrap()
            .iter()
            .flat_map(|ws| ws["screens"].as_array().into_iter().flatten())
            .flat_map(|screen| screen["panes"].as_array().into_iter().flatten())
            .find(|pane| {
                pane["tabs"].as_array().into_iter().flatten().any(|tab| {
                    tab == surface || &tab["id"] == surface || &tab["surface"] == surface
                })
            })
            .map(|pane| pane["id"].clone())
            .unwrap_or_else(|| panic!("no pane holds the base surface: {tree}"));
        Daemon { child, dir, socket, pane, serial: AtomicU64::new(0x300) }
    }

    /// A terminal that records each line it reads (no echo); its surface and log.
    fn recorder(&self, name: &str) -> (u64, PathBuf) {
        let log = self.dir.join(format!("{name}.log"));
        let shown = log.display();
        let script = format!(
            "stty -echo; : > '{shown}'; while IFS= read -r l; do printf '%s\\n' \"$l\" >> '{shown}'; done"
        );
        let serial = self.serial.fetch_add(1, Ordering::SeqCst);
        let terminal_id = format!("{:08x}00004000800{:013x}", std::process::id(), serial);
        let mut client = SyncClient::connect(&self.socket);
        let data = client.call(json!({"cmd": "new-tab", "pane": self.pane,
            "terminal_id": terminal_id, "cols": 120, "rows": 40, "env": {"SHELL": "/bin/sh"},
            "shell_args": ["-c", script]}));
        let surface = data["surface"].as_u64().unwrap_or_else(|| panic!("no surface in {data}"));
        let deadline = Instant::now() + Duration::from_secs(30);
        while !log.exists() {
            assert!(Instant::now() < deadline, "recorder {name} did not start");
            std::thread::sleep(Duration::from_millis(50));
        }
        // `stty -echo` ran before the log was made.
        (surface, log)
    }

    /// Ends a trailing partial line with `END` and Return on the unshaped socket; the log then.
    fn sentinel(&self, surface: u64, log: &Path) -> String {
        let mut client = SyncClient::connect(&self.socket);
        let bytes = base64::engine::general_purpose::STANDARD.encode(b"END\r");
        client.call(json!({"cmd": "send", "surface": surface, "bytes": bytes}));
        let deadline = Instant::now() + Duration::from_secs(20);
        loop {
            let text = fs::read_to_string(log).unwrap_or_default();
            if text.lines().any(|line| line.ends_with("END")) {
                return text;
            }
            assert!(Instant::now() < deadline, "the sentinel never reached {}", log.display());
            std::thread::sleep(Duration::from_millis(50));
        }
    }

    fn stop(mut self) {
        if let Ok(stream) = std::os::unix::net::UnixStream::connect(&self.socket) {
            let _ = stream.set_read_timeout(Some(Duration::from_secs(10)));
            let mut client = SyncClient {
                writer: stream.try_clone().unwrap(),
                reader: BufReader::new(stream),
                next: 0,
            };
            let identity = client.call(json!({"cmd": "identify"}));
            let _ = writeln!(
                client.writer,
                "{}",
                json!({"id": 99, "cmd": "shutdown-daemon", "pid": identity["pid"],
                "generation": identity["generation"], "force": true, "end_terminals": true})
            );
        }
        let deadline = Instant::now() + Duration::from_secs(10);
        while Instant::now() < deadline {
            if matches!(self.child.try_wait(), Ok(Some(_))) {
                break;
            }
            std::thread::sleep(Duration::from_millis(50));
        }
        let _ = self.child.kill();
        let _ = self.child.wait();
        let _ = fs::remove_dir_all(&self.dir);
    }
}

/// The phone's host side: each TCP connection spliced to the daemon's session socket.
async fn splice(socket: &Path) -> std::net::SocketAddr {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
    let socket = socket.to_owned();
    tokio::spawn(async move {
        while let Ok((mut tcp, _)) = listener.accept().await {
            let socket = socket.clone();
            tokio::spawn(async move {
                let Ok(mut unix) = UnixStream::connect(&socket).await else { return };
                let _ = tokio::io::copy_bidirectional(&mut tcp, &mut unix).await;
            });
        }
    });
    addr
}

// ---------------------------------------------------------------------------------------------
// One phone channel

enum In {
    Reply(u64, Value),
    Closed,
}

/// A phone channel over the shaper: replies by id. Dropping it closes the socket at once, and
/// the shaper drops what it still held for it (a channel the phone gave up on).
struct Conn {
    writer: tokio::net::tcp::OwnedWriteHalf,
    inbound: mpsc::UnboundedReceiver<In>,
    reader: tokio::task::JoinHandle<()>,
}

impl Conn {
    async fn open(addr: std::net::SocketAddr) -> std::io::Result<Self> {
        let stream = TcpStream::connect(addr).await?;
        stream.set_nodelay(true)?;
        let (read, writer) = stream.into_split();
        let (send, inbound) = mpsc::unbounded_channel();
        let reader = tokio::spawn(async move {
            let mut lines = tokio::io::BufReader::new(read);
            let mut line = String::new();
            loop {
                line.clear();
                match lines.read_line(&mut line).await {
                    Ok(0) | Err(_) => {
                        let _ = send.send(In::Closed);
                        return;
                    }
                    Ok(_) => {}
                }
                let Ok(value) = serde_json::from_str::<Value>(&line) else { continue };
                if let Some(id) = value.get("id").and_then(Value::as_u64)
                    && value.get("ok").is_some()
                    && send.send(In::Reply(id, value)).is_err()
                {
                    return;
                }
            }
        });
        Ok(Conn { writer, inbound, reader })
    }

    async fn write(&mut self, requests: &[Value]) -> std::io::Result<()> {
        let mut bytes = Vec::new();
        for request in requests {
            bytes.extend_from_slice(request.to_string().as_bytes());
            bytes.push(b'\n');
        }
        self.writer.write_all(&bytes).await
    }
}

impl Drop for Conn {
    fn drop(&mut self) {
        self.reader.abort();
    }
}

// ---------------------------------------------------------------------------------------------
// The client policies

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Told {
    NotSent,
    MaybeSent,
}

/// What a policy hands its driver: requests to write, a failed channel, what the screen said.
#[derive(Default)]
struct Io {
    surface: u64,
    next_id: u64,
    writes: Vec<Value>,
    fail: bool,
    told: Vec<(usize, Told)>,
    /// `inputNotSent` notices (the legacy screen's "not sent" line, with or without text back).
    notices: u64,
}

impl Io {
    fn request(&mut self, cmd: &str, mut params: Value) -> u64 {
        self.next_id += 1;
        params["id"] = json!(self.next_id);
        params["cmd"] = json!(cmd);
        self.writes.push(params);
        self.next_id
    }
}

trait Phone: Send {
    /// The person taps Send with `msg`'s text in the composer.
    fn tap(&mut self, msg: usize, now: Instant);
    /// The channel's identify and attach came back.
    fn attached(&mut self, caps: &[String], now: Instant);
    fn reply(&mut self, id: u64, reply: &Value, now: Instant);
    /// The channel is gone (the phone dropped it, or it failed).
    fn lost(&mut self, now: Instant);
    /// A fresh session object for the next channel (the redial condition).
    fn fresh(&mut self);
    fn tick(&mut self, now: Instant);
    fn idle(&self) -> bool;
    fn io(&mut self) -> &mut Io;
}

/// The phone at this checkout's base. A projected terminal (the default since #49901) never took
/// the keyed daemon path: `TerminalProjectingSession` did not pass `sendPasteAndSubmit` on, so every
/// composer Send went through the mirror (TerminalSurfaceView.swift:816) as two unkeyed `send`s, the
/// text and then a Return [`ENTER_DELAY`] later, through `DaemonTerminalSession`'s input queue
/// (`enqueueTyped` :418, `drainInput` :1600, `inputSettled` :1745). A dropped or timed-out batch
/// handed the draft back (the screen said not sent), and the person sent it again.
///
/// Approximations: one channel carries attach and input (Swift has an input lane beside the attach
/// channel; `inputClient ?? client`, :1606), so the lane's 10 s answer bound (`abandonInputLane`,
/// :1716) fails the whole channel and the terminal reattaches after [`REATTACH_DELAY`]; writes
/// complete at once (`inputWriting` never holds the queue); every Send whose text or Return was in
/// a dropped batch gets its draft back (Swift's `heldComposerSend` hands back only the last held
/// one, within 30 s); an error reply drops like a failure; the composer is empty whenever text comes
/// back.
struct Legacy {
    io: Io,
    attached: bool,
    /// `refusingInput` (:205; cleared at the attach, :1113).
    refusing: bool,
    input: VecDeque<Queued>,
    flights: Vec<Flight>,
    recovering: bool,
    failed: Vec<Failed>,
    next_batch: u64,
    /// `Task.sleep(inputHoldLimit)` then `expireInput()` (:438, :465).
    expiries: Vec<Instant>,
    /// The mirror path's Return, `ENTER_DELAY` after its text, for its Send.
    enters: Vec<(Instant, usize)>,
}

struct Queued {
    bytes: Vec<u8>,
    at: Instant,
    detached: bool,
    msg: usize,
}

struct Flight {
    id: u64,
    number: u64,
    msgs: Vec<usize>,
    deadline: Instant,
}

/// `inputFailed` (always `written: true` here: writes complete at once, so every failure is
/// after the write, uncertain, and unkeyed: never resent by the queue).
struct Failed {
    number: u64,
    msgs: Vec<usize>,
}

impl Legacy {
    fn new(surface: u64, _nonce: &str) -> Self {
        Legacy {
            io: Io { surface, ..Io::default() },
            attached: false,
            refusing: false,
            input: VecDeque::new(),
            flights: Vec::new(),
            recovering: false,
            failed: Vec::new(),
            next_batch: 0,
            expiries: Vec::new(),
            enters: Vec::new(),
        }
    }

    /// `enqueueTyped` (:418).
    fn enqueue(&mut self, bytes: Vec<u8>, msg: usize, now: Instant) {
        if self.refusing && !self.attached {
            self.not_sent(vec![msg]);
            return;
        }
        self.input.push_back(Queued { bytes, at: now, detached: !self.attached, msg });
        // `inputHoldBytes` is never reached by these Sends.
        if self.attached {
            self.drain(now);
        } else {
            self.expiries.push(now + INPUT_HOLD);
        }
    }

    /// The `.inputNotSent` notice (TerminalModel.swift:326-339): each Send's draft comes back once.
    fn not_sent(&mut self, mut msgs: Vec<usize>) {
        self.io.notices += 1;
        msgs.sort_unstable();
        msgs.dedup();
        self.io.told.extend(msgs.into_iter().map(|msg| (msg, Told::NotSent)));
    }

    fn drop_all(&mut self, extra: Vec<usize>) {
        let mut msgs = extra;
        msgs.extend(self.input.drain(..).map(|q| q.msg));
        self.not_sent(msgs);
    }

    /// `expireInput` (:477) and `dropDetachedInput` (:484).
    fn expire(&mut self, now: Instant) {
        let Some(cutoff) = now.checked_sub(INPUT_HOLD) else { return };
        if !self.input.iter().any(|q| q.detached && q.at <= cutoff) {
            return;
        }
        if !self.attached {
            self.refusing = true;
        }
        self.drop_all(Vec::new());
    }

    /// `markInputDetached` (:456).
    fn mark_detached(&mut self, now: Instant) {
        for queued in &mut self.input {
            queued.detached = true;
        }
        if !self.input.is_empty() {
            self.expiries.push(now + INPUT_HOLD);
        }
    }

    /// `drainInput` (:1600) with no keys: everything queued goes as one batch; writes complete at
    /// once, so it loops where Swift recurses.
    fn drain(&mut self, now: Instant) {
        loop {
            if !self.attached {
                return;
            }
            self.expire(now);
            if self.input.is_empty() {
                return;
            }
            if !self.flights.is_empty() && (self.recovering || self.flights.len() >= MAX_IN_FLIGHT)
            {
                return;
            }
            let number = self.next_batch;
            self.next_batch += 1;
            let taken: Vec<Queued> = self.input.drain(..).collect();
            let batch: Vec<u8> = taken.iter().flat_map(|q| q.bytes.iter().copied()).collect();
            let surface = self.io.surface;
            let id = self.io.request(
                "send",
                json!({"surface": surface,
                    "bytes": base64::engine::general_purpose::STANDARD.encode(&batch)}),
            );
            let msgs = taken.iter().map(|q| q.msg).collect();
            self.flights.push(Flight { id, number, msgs, deadline: now + ATTEMPT_TIMEOUT });
        }
    }

    /// `inputSettled` (:1745): unkeyed failures are never resent; it and every batch after it
    /// dropped, the screen told (:1776-1785).
    fn settled(&mut self, now: Instant) {
        if !self.flights.is_empty() {
            return self.drain(now);
        }
        if self.recovering {
            self.recovering = false;
            let mut failed = std::mem::take(&mut self.failed);
            failed.sort_by_key(|f| f.number);
            if !failed.is_empty() {
                let msgs = failed.into_iter().flat_map(|f| f.msgs).collect();
                self.drop_all(msgs);
            }
        }
        self.drain(now);
    }
}

impl Phone for Legacy {
    fn tap(&mut self, msg: usize, now: Instant) {
        // The mirror path (TerminalSurfaceView.swift:816): the text now, Return 60 ms later.
        self.enqueue(text_of(msg).into_bytes(), msg, now);
        self.enters.push((now + ENTER_DELAY, msg));
    }

    fn attached(&mut self, _caps: &[String], now: Instant) {
        // Projected: the daemon's `send-key-v1` and `send-expect-agent-v1` never reach the
        // composer, so its Sends stay unkeyed mirror writes whatever the daemon offers.
        self.attached = true;
        self.refusing = false;
        self.drain(now);
    }

    fn reply(&mut self, id: u64, reply: &Value, now: Instant) {
        let Some(index) = self.flights.iter().position(|f| f.id == id) else { return };
        let flight = self.flights.remove(index);
        if reply["ok"] != json!(true) {
            self.recovering = true;
            self.failed.push(Failed { number: flight.number, msgs: flight.msgs });
        }
        self.settled(now);
    }

    fn lost(&mut self, now: Instant) {
        // The catch at :1683-1705: every written batch on the channel fails as uncertain.
        self.attached = false;
        if !self.flights.is_empty() {
            self.recovering = true;
            for f in std::mem::take(&mut self.flights) {
                self.failed.push(Failed { number: f.number, msgs: f.msgs });
            }
            self.settled(now);
        }
        self.mark_detached(now);
    }

    fn fresh(&mut self) {
        // A new session object; the queue carries over (it is the terminal's, not the channel's).
    }

    fn tick(&mut self, now: Instant) {
        let due: Vec<usize> =
            self.enters.iter().filter(|(at, _)| *at <= now).map(|(_, msg)| *msg).collect();
        self.enters.retain(|(at, _)| *at > now);
        for msg in due {
            self.enqueue(b"\r".to_vec(), msg, now);
        }
        if self.expiries.iter().any(|at| *at <= now) {
            self.expiries.retain(|at| *at > now);
            self.expire(now);
        }
        if self.flights.iter().any(|f| f.deadline <= now) {
            self.io.fail = true;
        }
    }

    fn idle(&self) -> bool {
        self.input.is_empty() && self.flights.is_empty() && self.enters.is_empty()
    }

    fn io(&mut self) -> &mut Io {
        &mut self.io
    }
}

/// The same person and session driving `cmux_composer_send::Outbox`.
struct OutboxPhone {
    io: Io,
    outbox: Outbox,
    form: Option<Form>,
    attached: bool,
    flight: Option<(u64, u64, Instant)>,
    msgs: HashMap<u64, usize>,
}

impl OutboxPhone {
    fn new(surface: u64, nonce: &str) -> Self {
        OutboxPhone {
            io: Io { surface, ..Io::default() },
            outbox: Outbox::new(nonce, DEFAULT_HOLD),
            form: None,
            attached: false,
            flight: None,
            msgs: HashMap::new(),
        }
    }

    fn record(&mut self, done: cmux_composer_send::Done) {
        let Some(msg) = self.msgs.remove(&done.seq) else { return };
        if let Outcome::NotSent { .. } = &done.outcome {
            self.io.told.push((msg, Told::NotSent));
        } else if let Outcome::MaybeSent { .. } = &done.outcome {
            self.io.told.push((msg, Told::MaybeSent));
        }
    }

    fn pump(&mut self, now: Instant) {
        for done in self.outbox.expire(now) {
            self.record(done);
        }
        if !self.attached || self.flight.is_some() {
            return;
        }
        let Some(form) = self.form else { return };
        if let Some((seq, mut params)) = self.outbox.next_request(form) {
            params["surface"] = json!(self.io.surface);
            let id = self.io.request("send", params);
            self.flight = Some((seq, id, now + ATTEMPT_TIMEOUT));
        }
    }
}

impl Phone for OutboxPhone {
    fn tap(&mut self, msg: usize, now: Instant) {
        let seq = self.outbox.push(text_of(msg), true, now);
        self.msgs.insert(seq, msg);
        self.pump(now);
    }

    fn attached(&mut self, caps: &[String], now: Instant) {
        self.form = Form::from_caps(caps.iter().map(String::as_str));
        self.attached = true;
        self.pump(now);
    }

    fn reply(&mut self, id: u64, reply: &Value, now: Instant) {
        let Some((seq, flight_id, _)) = self.flight else { return };
        if flight_id != id {
            return;
        }
        self.flight = None;
        let answer = if reply["ok"] == json!(true) {
            Answer::Applied
        } else if reply["error_delivery"] == json!("known-not-delivered") {
            Answer::Refused
        } else {
            Answer::Uncertain
        };
        if let Some(done) = self.outbox.answer(seq, answer) {
            self.record(done);
        }
        self.pump(now);
    }

    fn lost(&mut self, _now: Instant) {
        self.attached = false;
        self.flight = None;
        self.outbox.link_lost();
    }

    fn fresh(&mut self) {
        self.form = None;
    }

    fn tick(&mut self, now: Instant) {
        if let Some((seq, _, deadline)) = self.flight
            && deadline <= now
        {
            self.flight = None;
            if let Some(done) = self.outbox.answer(seq, Answer::Lost) {
                self.record(done);
            }
            self.io.fail = true;
        }
        self.pump(now);
    }

    fn idle(&self) -> bool {
        self.outbox.is_empty()
    }

    fn io(&mut self) -> &mut Io {
        &mut self.io
    }
}

// ---------------------------------------------------------------------------------------------
// Conditions, scenarios, classification

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Cond {
    Lossy3,
    Lossy10,
    Flap,
    Redial,
}

const CONDS: [Cond; 4] = [Cond::Lossy3, Cond::Lossy10, Cond::Flap, Cond::Redial];

impl Cond {
    fn name(self) -> &'static str {
        match self {
            Cond::Lossy3 => "lossy-3",
            Cond::Lossy10 => "lossy-10",
            Cond::Flap => "flap",
            Cond::Redial => "redial",
        }
    }

    fn profile(self) -> &'static str {
        match self {
            Cond::Lossy3 | Cond::Redial => "lossy-3",
            Cond::Lossy10 => "lossy-10",
            Cond::Flap => "good-wifi",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Policy {
    Legacy,
    Outbox,
}

impl Policy {
    fn name(self) -> &'static str {
        match self {
            Policy::Legacy => "legacy",
            Policy::Outbox => "outbox",
        }
    }
}

#[derive(Debug, Default, Clone)]
struct Row {
    cond: &'static str,
    policy: &'static str,
    sends: usize,
    applied_once: u64,
    text_without_submit: u64,
    double_submit: u64,
    lost_both: u64,
    lost_unreported: u64,
    told_not_sent: u64,
    told_maybe_sent: u64,
    bare_returns: u64,
    notices: u64,
    retaps: u64,
    channels: u64,
    secs: f64,
}

/// Each Send's `(submitted, unsubmitted)` count from the recorder's log, and bare Returns.
fn tally(log: &str, sends: usize) -> (Vec<(u64, u64)>, u64) {
    let mut counts = vec![(0_u64, 0_u64); sends];
    let mut bare = 0;
    for line in log.lines() {
        let sentinel = line.ends_with("END");
        let mut tokens = Vec::new();
        let mut rest = line;
        while let Some(at) = rest.find("msg-") {
            let digits: String =
                rest[at + 4..].chars().take(3).take_while(char::is_ascii_digit).collect();
            rest = &rest[at + 4 + digits.len()..];
            if let Ok(msg) = digits.parse::<usize>()
                && msg < sends
            {
                tokens.push(msg);
            }
        }
        if line.is_empty() {
            bare += 1;
        }
        let ends_with_token = !sentinel && rest.is_empty();
        for (index, msg) in tokens.iter().enumerate() {
            let last = index + 1 == tokens.len();
            if last && ends_with_token {
                counts[*msg].0 += 1;
            } else {
                counts[*msg].1 += 1;
            }
        }
    }
    (counts, bare)
}

struct Setup {
    identify: u64,
    attach: u64,
    deadline: Instant,
    caps: Vec<String>,
}

fn attach_requests(io: &mut Io) -> Setup {
    let surface = io.surface;
    io.request(
        "set-client-info",
        json!({"name": "bench iPhone", "kind": "ios", "device_kind": "iphone",
            "device_name": "bench iPhone", "device_id": "bench-device-0001",
            "capabilities": ["size-lease-v2", "size-lease-v1", "shared-sizing-v1", "host-grid-view-v1"]}),
    );
    let identify = io.request("identify", json!({}));
    let attach = io.request(
        "attach-surface",
        json!({"surface": surface, "cols": COLS, "rows": ROWS, "replay_history_rows": 0}),
    );
    Setup { identify, attach, deadline: Instant::now() + ATTEMPT_TIMEOUT, caps: Vec::new() }
}

#[allow(clippy::too_many_lines, reason = "one scenario's event loop reads best in one place")]
async fn scenario(
    cond: Cond,
    policy: Policy,
    surface: u64,
    upstream: std::net::SocketAddr,
    sends: usize,
    seed: u64,
) -> (Row, HashMap<usize, (Instant, Option<Instant>)>) {
    let profile = ProfileFile::builtin()
        .get(cond.profile())
        .unwrap_or_else(|| panic!("no link profile {}", cond.profile()))
        .clone();
    let shaper = Shaper::start(upstream, profile, seed, &Trace::new()).await.unwrap();
    let addr = shaper.addr();
    let nonce = format!("csd-{}-{}-{seed}", cond.name(), policy.name());
    let mut phone: Box<dyn Phone> = match policy {
        Policy::Legacy => Box::new(Legacy::new(surface, &nonce)),
        Policy::Outbox => Box::new(OutboxPhone::new(surface, &nonce)),
    };
    let mut rng = Rng(seed.wrapping_mul(0x2545_f491_4f6c_dd1d) ^ 0x5eed);
    let started = Instant::now();
    let mut taps = VecDeque::new();
    let mut at = started + Duration::from_secs(1);
    for msg in 0..sends {
        at += rng.millis(300, 700);
        taps.push_back((at, msg));
    }
    let last_tap = at;
    let bound = last_tap + SETTLE;
    let mut retaps: Vec<(Instant, usize)> = Vec::new();
    let mut retapped: HashMap<usize, u32> = HashMap::new();
    // Per Send: its last tap, and the last time the screen said something about it.
    let mut fate: HashMap<usize, (Instant, Option<Instant>)> = HashMap::new();
    let mut row = Row { cond: cond.name(), policy: policy.name(), sends, ..Row::default() };
    let mut conn: Option<Conn> = None;
    let mut setup: Option<Setup> = None;
    let mut reopen_at = Some(started);
    let mut next_blackout = (cond == Cond::Flap).then(|| started + Duration::from_secs(6));
    loop {
        let now = Instant::now();
        if let Some(at) = next_blackout
            && now >= at
        {
            shaper.blackout(Duration::from_secs(2));
            next_blackout = Some(at + Duration::from_secs(6));
        }
        let mut open = conn.is_none() && reopen_at.is_some_and(|at| now >= at);
        let mut tapped = Vec::new();
        while let Some(&(at, msg)) = taps.front()
            && at <= now
        {
            taps.pop_front();
            if cond == Cond::Redial {
                // The phone's channel is replaced now, and the Send fires before the new
                // attach and identify come back.
                conn = None;
                setup = None;
                phone.lost(now);
                phone.fresh();
                open = true;
            }
            tapped.push(msg);
        }
        if open {
            reopen_at = None;
            match Conn::open(addr).await {
                Ok(new) => {
                    row.channels += 1;
                    conn = Some(new);
                    setup = Some(attach_requests(phone.io()));
                }
                Err(_) => reopen_at = Some(now + REATTACH_DELAY),
            }
        }
        for msg in tapped {
            fate.insert(msg, (now, None));
            phone.tap(msg, now);
        }
        let due: Vec<usize> =
            retaps.iter().filter(|(at, _)| *at <= now).map(|(_, msg)| *msg).collect();
        retaps.retain(|(at, _)| *at > now);
        for msg in due {
            row.retaps += 1;
            fate.insert(msg, (now, None));
            phone.tap(msg, now);
        }
        phone.tick(now);
        if setup.as_ref().is_some_and(|s| s.deadline <= now) {
            phone.io().fail = true;
        }
        // Writes go out before a failure drops the channel they were made for.
        let writes = std::mem::take(&mut phone.io().writes);
        if !writes.is_empty()
            && let Some(c) = conn.as_mut()
            && c.write(&writes).await.is_err()
        {
            phone.io().fail = true;
        }
        if std::mem::take(&mut phone.io().fail) {
            conn = None;
            setup = None;
            phone.lost(now);
            reopen_at = Some(now + REATTACH_DELAY);
            let writes = std::mem::take(&mut phone.io().writes);
            assert!(writes.is_empty(), "a detached phone wrote {writes:?}");
        }
        let mut told_now = std::mem::take(&mut phone.io().told);
        // One way back per text per tick, however many of its batches dropped.
        told_now.sort_by_key(|(msg, told)| (*msg, matches!(told, Told::MaybeSent)));
        told_now.dedup_by_key(|(msg, _)| *msg);
        for (msg, told) in told_now {
            if let Some(entry) = fate.get_mut(&msg) {
                entry.1 = Some(now);
            }
            match told {
                Told::NotSent => {
                    // One way back per text at a time.
                    if retaps.iter().any(|(_, m)| *m == msg) {
                        continue;
                    }
                    row.told_not_sent += 1;
                    let count = retapped.entry(msg).or_default();
                    if *count < RETAPS {
                        *count += 1;
                        retaps.push((now + rng.millis(500, 1500), msg));
                    }
                }
                Told::MaybeSent => row.told_maybe_sent += 1,
            }
        }
        if taps.is_empty() && retaps.is_empty() && phone.idle() && now > last_tap {
            break;
        }
        if now > bound {
            eprintln!("composer-send {} {}: not settled at the bound", cond.name(), policy.name());
            break;
        }
        let item = match conn.as_mut() {
            Some(c) => {
                match tokio::time::timeout(Duration::from_millis(20), c.inbound.recv()).await {
                    Ok(item) => Some(item.unwrap_or(In::Closed)),
                    Err(_) => None,
                }
            }
            None => {
                tokio::time::sleep(Duration::from_millis(20)).await;
                None
            }
        };
        let now = Instant::now();
        match item {
            None => {}
            Some(In::Closed) => phone.io().fail = true,
            Some(In::Reply(id, reply)) => {
                let mut done_setup = false;
                if let Some(s) = setup.as_mut() {
                    if id == s.identify {
                        s.caps = reply["data"]["capabilities"]
                            .as_array()
                            .into_iter()
                            .flatten()
                            .filter_map(|c| c.as_str().map(str::to_owned))
                            .collect();
                        continue;
                    }
                    if id == s.attach {
                        if reply["ok"] != json!(true) {
                            phone.io().fail = true;
                            continue;
                        }
                        done_setup = true;
                    }
                }
                if done_setup {
                    let caps = setup.take().map(|s| s.caps).unwrap_or_default();
                    phone.attached(&caps, now);
                } else {
                    phone.reply(id, &reply, now);
                }
            }
        }
    }
    row.notices = phone.io().notices;
    drop(conn);
    row.secs = started.elapsed().as_secs_f64();
    (row, fate)
}

fn classify(row: &mut Row, log: &str, fate: &HashMap<usize, (Instant, Option<Instant>)>) {
    let (counts, bare) = tally(log, row.sends);
    row.bare_returns = bare;
    for (msg, (submitted, unsubmitted)) in counts.into_iter().enumerate() {
        if unsubmitted > 0 {
            row.text_without_submit += 1;
        } else if submitted >= 2 {
            row.double_submit += 1;
        } else if submitted == 0 {
            row.lost_both += 1;
            let reported =
                fate.get(&msg).is_some_and(|(tap, told)| told.is_some_and(|t| t >= *tap));
            if !reported {
                row.lost_unreported += 1;
            }
        } else {
            row.applied_once += 1;
        }
    }
}

/// Every (condition, policy) at once, each on its own recorder and shaper.
fn run(policies: &[Policy], sends: usize) -> Vec<Row> {
    let daemon = Daemon::start();
    let mut plan = Vec::new();
    for cond in CONDS {
        for policy in policies {
            let (surface, log) = daemon.recorder(&format!("{}-{}", cond.name(), policy.name()));
            plan.push((cond, *policy, surface, log));
        }
    }
    let runtime =
        tokio::runtime::Builder::new_multi_thread().worker_threads(4).enable_all().build().unwrap();
    let seed_base = env_u64("COMPOSER_SEND_SEED", 1);
    let results = runtime.block_on(async {
        let upstream = splice(&daemon.socket).await;
        let mut handles = Vec::new();
        for (index, (cond, policy, surface, _)) in plan.iter().enumerate() {
            // One seed per condition: both policies see the same pace and link draws.
            let seed = seed_base + CONDS.iter().position(|c| c == cond).unwrap_or(index) as u64;
            handles.push(tokio::spawn(scenario(*cond, *policy, *surface, upstream, sends, seed)));
        }
        let mut results = Vec::new();
        for handle in handles {
            results.push(handle.await.unwrap());
        }
        results
    });
    drop(runtime);
    let mut rows = Vec::new();
    for ((mut row, fate), (_, _, surface, log)) in results.into_iter().zip(&plan) {
        let text = daemon.sentinel(*surface, log);
        classify(&mut row, &text, &fate);
        eprintln!(
            "COMPOSER-SEND {}",
            json!({"condition": row.cond, "policy": row.policy, "sends": row.sends,
                "applied_once": row.applied_once, "text_without_submit": row.text_without_submit,
                "double_submit": row.double_submit, "lost_both": row.lost_both,
                "lost_unreported": row.lost_unreported, "told_not_sent": row.told_not_sent,
                "told_maybe_sent": row.told_maybe_sent, "bare_returns": row.bare_returns,
                "notices": row.notices, "retaps": row.retaps, "channels": row.channels,
                "secs": (row.secs * 10.0).round() / 10.0})
        );
        rows.push(row);
    }
    daemon.stop();
    rows
}

fn print_table(rows: &[Row], policies: &[Policy], sends: usize) {
    eprintln!();
    eprintln!(
        "composer Send under duress, per {sends} Sends: tws = text without submit, dbl = double submit, lost = lost both, NS = told not sent, MS = told maybe sent"
    );
    let mut header = format!("{:<10}", "condition");
    for policy in policies {
        header.push_str(&format!(
            " | {:<7}{:>4}{:>4}{:>5}{:>4}{:>4}",
            policy.name(),
            "tws",
            "dbl",
            "lost",
            "NS",
            "MS"
        ));
    }
    eprintln!("{header}");
    for cond in CONDS {
        let mut line = format!("{:<10}", cond.name());
        for policy in policies {
            let Some(row) =
                rows.iter().find(|r| r.cond == cond.name() && r.policy == policy.name())
            else {
                continue;
            };
            line.push_str(&format!(
                " | {:<7}{:>4}{:>4}{:>5}{:>4}{:>4}",
                "",
                row.text_without_submit,
                row.double_submit,
                row.lost_both,
                row.told_not_sent,
                row.told_maybe_sent
            ));
        }
        eprintln!("{line}");
    }
    eprintln!();
}

#[test]
fn the_recorder_log_is_classified_per_send() {
    let log = "msg-000\nmsg-001msg-002\nmsg-003\nmsg-003\n\nmsg-005END\n";
    let (counts, bare) = tally(log, 7);
    assert_eq!(counts[0], (1, 0));
    assert_eq!(counts[1], (0, 1));
    assert_eq!(counts[2], (1, 0));
    assert_eq!(counts[3], (2, 0));
    assert_eq!(counts[4], (0, 0));
    assert_eq!(counts[5], (0, 1));
    assert_eq!(counts[6], (0, 0));
    assert_eq!(bare, 1);
}

/// The table: both policies, every condition, 100 Sends each.
#[test]
fn composer_send_duress_table() {
    let sends = env_u64("COMPOSER_SEND_SENDS", 100) as usize;
    let policies = [Policy::Legacy, Policy::Outbox];
    let started = Instant::now();
    let rows = run(&policies, sends);
    print_table(&rows, &policies, sends);
    eprintln!("composer_send_duress_table: {:.1} s", started.elapsed().as_secs_f64());
}

/// The outbox (or `COMPOSER_SEND_POLICY=legacy`) on every condition: no text without its
/// Return, no double submit, no Send lost without the screen saying so.
#[test]
fn composer_send_duress_holds() {
    let sends = env_u64("COMPOSER_SEND_ASSERT_SENDS", 20) as usize;
    let policy = match std::env::var("COMPOSER_SEND_POLICY").as_deref() {
        Ok("legacy") => Policy::Legacy,
        _ => Policy::Outbox,
    };
    let started = Instant::now();
    let rows = run(&[policy], sends);
    print_table(&rows, &[policy], sends);
    eprintln!("composer_send_duress_holds: {:.1} s", started.elapsed().as_secs_f64());
    let bad: Vec<String> = rows
        .iter()
        .filter(|r| r.text_without_submit > 0 || r.double_submit > 0 || r.lost_unreported > 0)
        .map(|r| {
            format!(
                "{} {}: {} text without submit, {} double submit, {} lost unreported",
                r.cond, r.policy, r.text_without_submit, r.double_submit, r.lost_unreported
            )
        })
        .collect();
    assert!(bad.is_empty(), "the composer's Send broke under duress: {bad:?}");
}
