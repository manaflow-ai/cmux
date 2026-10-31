//! Fuzz row g: random chat, session, queue, outbox, watch and permission operations from several
//! concurrent clients against a real acpmux daemon, with `kill -9` of that daemon at random
//! points (between requests, and while other clients' requests are in flight), then a restart on
//! the same `ACPMUX_HOME`.
//!
//! Oracles:
//! 1. Every answer the daemon's documents call durable survives the crash and the restart:
//!    - `_acpmux/draft_set`: "the one durable shared draft" (docs/acpmux-schema.json,
//!      `_acpmux/composer_set` note);
//!    - an accepted prompt (`_acpmux/prompt_accepted`, queued or not) is still queued or ran, and
//!      a prompt `_acpmux/queue_remove` answered `removed` never comes back: "the queue is rebuilt
//!      from the log" (schema, `_acpmux/prompt_withdraw` note);
//!    - `_acpmux/send_queue`: "That answer is the ack: the message is the daemon's to deliver from
//!      then on, across a restart too" (README, the outbox);
//!    - `_acpmux/watch_add` / `_acpmux/watch_rm`: "Watches and undelivered messages survive
//!      restart" (README, `durable-watches-v1`);
//!    - `session/new`: a created chat is still listed ("a daemon restart before then keeps it",
//!      schema `session/new`; `store.mode` `local` writes `sessions/<id>/session.json`).
//!
//!    Losses of answers no document promises (a rename, `_acpmux/markUnread`, `session/set_mode`,
//!    a permission answer's `permission_decision` record) are printed as `FUZZ-G NOTE` lines,
//!    not violations.
//! 2. No request waits more than 2 s for its answer while the daemon is up (a prompt's answer is
//!    its `_acpmux/prompt_accepted`, not its turn's end).
//! 3. The restarted daemon answers, lists no session twice and none this test did not create,
//!    and is still running after the checks (no crash loop).
//!
//! On a violation the test prints `FUZZ-G VIOLATION seed=.. step=.. op=.. what=..`, replays the
//! issued operations one at a time (kills included) and shrinks them by dropping operations,
//! and prints the shortest list that still shows the same kind of violation.
//!
//! These are measurements a fuzz owner runs on the fleet, not CI tests (CLAUDE.md: no new CI
//! tests): each test runs only in a fleet step whose key names it (`CMUX_CI_STEP_KEY` contains
//! `fuzz-g`), or when `ACPMUX_FUZZ_SEED` is set; elsewhere it prints `FUZZ-G SKIP` and passes.
//! `ACPMUX_FUZZ_SEED` (a u64) and `ACPMUX_FUZZ_ROUNDS` (kills per seed) choose the run; without
//! them each test runs its three seeds, 12 kills each, at most 70 s a seed.
#![cfg(unix)]

#[path = "support/daemon_env.rs"]
mod daemon_env;
// Stand-in agents (tests/fake_agent.py). The step key and the two fuzz variables select the run;
// none holds a credential.
const HERMETIC: daemon_env::Process = daemon_env::Process::stand_in().keep(&[
    "CMUX_CI_STEP_KEY",
    "ACPMUX_FUZZ_SEED",
    "ACPMUX_FUZZ_ROUNDS",
]);

use serde_json::{Value, json};
use std::collections::{BTreeMap, BTreeSet};
use std::io::{BufRead, BufReader, ErrorKind, Write};
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::process::{Child, Stdio};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

/// The longest a request may wait for its answer while the daemon is up.
const STALL_MS: u64 = 2_000;
/// Clients that send at once.
const CLIENTS: usize = 3;
/// Operations one client sends at most between two kills.
const OPS_PER_CLIENT: usize = 24;

// ------------------------------------------------------------------ PRNG

/// SplitMix64: small, seeded, and the same on every host.
#[derive(Clone)]
struct Rng(u64);

impl Rng {
    fn next(&mut self) -> u64 {
        self.0 = self.0.wrapping_add(0x9E37_79B9_7F4A_7C15);
        let mut z = self.0;
        z = (z ^ (z >> 30)).wrapping_mul(0xBF58_476D_1CE4_E5B9);
        z = (z ^ (z >> 27)).wrapping_mul(0x94D0_49BB_1331_11EB);
        z ^ (z >> 31)
    }
    fn below(&mut self, n: u64) -> u64 {
        if n == 0 { 0 } else { self.next() % n }
    }
    fn pick<'a, T>(&mut self, items: &'a [T]) -> Option<&'a T> {
        if items.is_empty() {
            return None;
        }
        items.get(self.below(items.len() as u64) as usize)
    }
}

// ------------------------------------------------------------------ operations

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Role {
    /// Idle between prompts: echo turns.
    Plain,
    /// A turn that runs until cancelled, so prompts queue behind it.
    Busy,
    /// A turn that waits on a permission answer.
    Ask,
}

/// One operation. Chats are named by their creation label, so a replay that drops a create
/// skips the operations on that chat.
#[derive(Clone, Debug)]
enum Op {
    NewChat {
        label: u32,
        role: Role,
    },
    DraftSet {
        chat: u32,
        text: String,
    },
    Rename {
        chat: u32,
        name: String,
    },
    MarkUnread {
        chat: u32,
    },
    SetMode {
        chat: u32,
        mode: String,
    },
    Prompt {
        chat: u32,
        pid: String,
    },
    QueueRemove {
        chat: u32,
        pid: String,
    },
    SendQueue {
        chat: u32,
        pid: String,
    },
    WatchAdd {
        to: u32,
        watched: u32,
        tag: u32,
    },
    WatchRm {
        tag: u32,
    },
    PermissionAnswer {
        chat: u32,
    },
    /// `kill -9` of the daemon, then a restart and the checks (replays only; the fuzz run kills
    /// from its own thread).
    Kill,
}

impl Op {
    fn name(&self) -> &'static str {
        match self {
            Op::NewChat { .. } => "session/new",
            Op::DraftSet { .. } => "_acpmux/draft_set",
            Op::Rename { .. } => "_acpmux/rename",
            Op::MarkUnread { .. } => "_acpmux/markUnread",
            Op::SetMode { .. } => "session/set_mode",
            Op::Prompt { .. } => "session/prompt",
            Op::QueueRemove { .. } => "_acpmux/queue_remove",
            Op::SendQueue { .. } => "_acpmux/send_queue",
            Op::WatchAdd { .. } => "_acpmux/watch_add",
            Op::WatchRm { .. } => "_acpmux/watch_rm",
            Op::PermissionAnswer { .. } => "_acpmux/permission_respond",
            Op::Kill => "kill -9",
        }
    }
}

// ------------------------------------------------------------------ the client

enum Reply {
    Ok(Value),
    Err(Value),
    /// The socket closed (the daemon died) before the answer.
    Dead,
    /// No answer within the read timeout while the socket stayed open.
    Timeout,
}

struct Client {
    reader: BufReader<UnixStream>,
    writer: UnixStream,
    next: u64,
}

enum Line {
    Msg(Value),
    Dead,
    Timeout,
}

impl Client {
    fn connect(socket: &Path) -> Option<Self> {
        let stream = UnixStream::connect(socket).ok()?;
        stream.set_read_timeout(Some(Duration::from_secs(20))).ok()?;
        let reader = BufReader::new(stream.try_clone().ok()?);
        let mut client = Self { reader, writer: stream, next: 0 };
        let hello = json!({"protocolVersion": 1, "clientInfo": {"name": "fuzz-g"}});
        match client.call("initialize", hello) {
            Reply::Ok(_) => Some(client),
            _ => None,
        }
    }

    fn send(&mut self, method: &str, params: Value) -> Option<u64> {
        self.next += 1;
        let line = json!({"jsonrpc": "2.0", "id": self.next, "method": method, "params": params});
        self.writer.write_all(format!("{line}\n").as_bytes()).ok()?;
        Some(self.next)
    }

    fn line(&mut self) -> Line {
        let mut text = String::new();
        match self.reader.read_line(&mut text) {
            Ok(0) => Line::Dead,
            Ok(_) => Line::Msg(serde_json::from_str(&text).unwrap_or(Value::Null)),
            Err(e) if matches!(e.kind(), ErrorKind::WouldBlock | ErrorKind::TimedOut) => {
                Line::Timeout
            }
            Err(_) => Line::Dead,
        }
    }

    fn is_answer(v: &Value, id: u64) -> bool {
        v.get("method").is_none() && v.get("id") == Some(&json!(id))
    }

    fn call(&mut self, method: &str, params: Value) -> Reply {
        let Some(id) = self.send(method, params) else { return Reply::Dead };
        loop {
            match self.line() {
                Line::Dead => return Reply::Dead,
                Line::Timeout => return Reply::Timeout,
                Line::Msg(v) if Self::is_answer(&v, id) => {
                    return match v.get("error") {
                        Some(e) => Reply::Err(e.clone()),
                        None => Reply::Ok(v["result"].clone()),
                    };
                }
                Line::Msg(_) => {}
            }
        }
    }

    /// Sends a prompt and waits for its `_acpmux/prompt_accepted` (or an early answer).
    fn prompt(&mut self, session: &str, text: &str, pid: &str) -> Reply {
        let params = json!({"sessionId": session, "prompt": [{"type": "text", "text": text}],
                            "_meta": {"acpmux": {"promptId": pid, "steer": false}}});
        let Some(id) = self.send("session/prompt", params) else { return Reply::Dead };
        loop {
            match self.line() {
                Line::Dead => return Reply::Dead,
                Line::Timeout => return Reply::Timeout,
                Line::Msg(v)
                    if v["method"] == "_acpmux/prompt_accepted"
                        && v["params"]["promptId"] == pid =>
                {
                    return Reply::Ok(v["params"].clone());
                }
                Line::Msg(v) if Self::is_answer(&v, id) => {
                    return match v.get("error") {
                        Some(e) => Reply::Err(e.clone()),
                        None => Reply::Ok(v["result"].clone()),
                    };
                }
                Line::Msg(_) => {}
            }
        }
    }

    /// A prompt whose answer nobody waits for (a turn that runs until cancelled).
    fn prompt_async(&mut self, session: &str, text: &str, pid: &str) {
        let params = json!({"sessionId": session, "prompt": [{"type": "text", "text": text}],
                            "_meta": {"acpmux": {"promptId": pid, "steer": false}}});
        let _ = self.send("session/prompt", params);
    }

    /// `call`, retried on a fresh connection only to read state after a restart.
    fn get(&mut self, method: &str, params: Value) -> Result<Value, String> {
        match self.call(method, params) {
            Reply::Ok(v) => Ok(v),
            Reply::Err(e) => Err(format!("{method} error {e}")),
            Reply::Dead => Err(format!("{method}: the daemon closed the socket")),
            Reply::Timeout => Err(format!("{method}: no answer in 20 s")),
        }
    }
}

// ------------------------------------------------------------------ the daemon

struct Daemon {
    home: PathBuf,
    socket: PathBuf,
    child: Option<Child>,
    starts: u32,
}

impl Daemon {
    fn new(tag: &str) -> Self {
        // Short, under /tmp: the socket path must stay under the macOS limit.
        let home = PathBuf::from("/tmp").join(format!("amx-fg-{tag}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&home);
        std::fs::create_dir_all(home.join("p")).expect("home");
        // The daemon refuses a state folder others may write to.
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&home, std::fs::Permissions::from_mode(0o700)).unwrap();
        let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
        let config = json!({"harnesses": {"fake": {"argv": ["python3", fake]}},
                            "defaultHarness": "fake", "permissionPolicy": "ask",
                            "agentInbox": false, "autoResumeDelaysMs": []});
        std::fs::write(home.join("config.json"), config.to_string()).expect("config");
        std::fs::set_permissions(home.join("config.json"), std::fs::Permissions::from_mode(0o600))
            .unwrap();
        let socket = home.join("s.sock");
        Self { home, socket, child: None, starts: 0 }
    }

    /// Starts the daemon and waits until it answers `initialize`; the time it took.
    fn start(&mut self) -> Result<Duration, String> {
        let began = Instant::now();
        self.starts += 1;
        let log = std::fs::File::create(self.home.join(format!("stderr-{}.log", self.starts)))
            .map_err(|e| e.to_string())?;
        let child = daemon_env::command(&self.home, daemon_env::Agents::StandIn, &[])
            .args(["daemon", "run", "--log", "warn"])
            .env("ACPMUX_HOME", &self.home)
            .env("ACPMUX_SOCKET", &self.socket)
            // No agent hosts: a host outlives its daemon, and this test kills only the daemon.
            .env("ACPMUX_AGENT_HOSTS", "0")
            .env("ACPMUX_LOGIN_ENV", "0")
            .current_dir(self.home.join("p"))
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::from(log))
            .spawn()
            .map_err(|e| format!("spawn: {e}"))?;
        self.child = Some(child);
        let deadline = began + Duration::from_secs(30);
        loop {
            if Client::connect(&self.socket).is_some() {
                return Ok(began.elapsed());
            }
            if let Some(child) = self.child.as_mut()
                && let Ok(Some(status)) = child.try_wait()
            {
                self.child = None;
                return Err(format!("the daemon exited at start: {status}"));
            }
            if Instant::now() > deadline {
                return Err("the daemon did not answer within 30 s of its start".into());
            }
            std::thread::sleep(Duration::from_millis(25));
        }
    }

    /// `kill -9` of the daemon child this test started.
    fn kill9(&mut self) {
        if let Some(mut child) = self.child.take() {
            if child.try_wait().ok().flatten().is_none() {
                // SAFETY: the unreaped daemon child this test started.
                unsafe { libc::kill(child.id() as i32, libc::SIGKILL) };
            }
            let _ = child.wait();
        }
    }

    fn running(&mut self) -> bool {
        self.child.as_mut().is_some_and(|c| matches!(c.try_wait(), Ok(None)))
    }

    fn stderr_tail(&self) -> String {
        let text = std::fs::read_to_string(self.home.join(format!("stderr-{}.log", self.starts)))
            .unwrap_or_default();
        let lines: Vec<&str> = text.lines().collect();
        lines[lines.len().saturating_sub(8)..].join(" | ")
    }
}

impl Drop for Daemon {
    fn drop(&mut self) {
        self.kill9();
        let _ = std::fs::remove_dir_all(&self.home);
    }
}

// ------------------------------------------------------------------ the model

/// One write to a register (a draft, a name, a mode).
#[derive(Clone, Debug)]
struct RegWrite {
    value: Option<String>,
    sent: Instant,
    acked: Option<Instant>,
}

/// The values a register may hold after a crash: any write that no acknowledged write followed
/// (one sent after its answer), or the initial value when nothing was acknowledged.
fn allowed(writes: &[RegWrite]) -> Option<Vec<Option<String>>> {
    if !writes.iter().any(|w| w.acked.is_some()) {
        return None;
    }
    let ok = writes
        .iter()
        .filter(|w| {
            !writes.iter().any(|t| t.acked.is_some() && w.acked.is_some_and(|a| a < t.sent))
        })
        .map(|w| w.value.clone())
        .collect();
    Some(ok)
}

#[derive(Default)]
struct ChatModel {
    id: Option<String>,
    role: Option<Role>,
    /// The create was sent but not answered (the daemon died).
    unsure: bool,
    drafts: Vec<RegWrite>,
    names: Vec<RegWrite>,
    modes: Vec<RegWrite>,
    unread_acked: bool,
    /// Prompt ids the daemon accepted, and those it may have taken.
    accepted: BTreeSet<String>,
    maybe: BTreeSet<String>,
    /// Prompt ids `_acpmux/queue_remove` answered `removed: true` for.
    removed: BTreeSet<String>,
    /// Permission ids answered.
    answered: BTreeSet<String>,
}

#[derive(Default)]
struct WatchModel {
    id: Option<String>,
    to: u32,
    removed: bool,
    maybe_removed: bool,
}

/// What one issued operation did.
#[derive(Clone, Debug)]
struct Issued {
    op: Op,
    outcome: &'static str,
    latency_ms: Option<u64>,
}

#[derive(Default)]
struct Model {
    chats: BTreeMap<u32, ChatModel>,
    /// The outbox's acknowledged deliveries: (delivery id, step).
    deliveries: Vec<(String, usize)>,
    watches: BTreeMap<u32, WatchModel>,
    issued: Vec<Issued>,
    next_label: u32,
    next_tag: u32,
    next_pid: u64,
}

impl Model {
    fn chats_with(&self, role: Option<Role>) -> Vec<u32> {
        self.chats
            .iter()
            .filter(|(_, c)| c.id.is_some() && (role.is_none() || c.role == role))
            .map(|(k, _)| *k)
            .collect()
    }

    fn id(&self, label: u32) -> Option<String> {
        self.chats.get(&label).and_then(|c| c.id.clone())
    }
}

/// A violation or a note, with the step it is about.
#[derive(Clone, Debug)]
struct Finding {
    step: usize,
    op: String,
    kind: &'static str,
    what: String,
}

// ------------------------------------------------------------------ generating and running ops

/// Picks the next operation for the current model.
fn generate(rng: &mut Rng, model: &mut Model, seed: u64) -> Op {
    let chats = model.chats_with(None);
    let roll = rng.below(100);
    if chats.len() < 2 || roll < 8 {
        model.next_label += 1;
        let role = match rng.below(3) {
            0 => Role::Plain,
            1 => Role::Busy,
            _ => Role::Ask,
        };
        return Op::NewChat { label: model.next_label, role };
    }
    let chat = *rng.pick(&chats).unwrap();
    model.next_pid += 1;
    let pid = format!("fg-{seed:x}-{}", model.next_pid);
    match roll {
        8..=25 => {
            let text = if rng.below(6) == 0 { String::new() } else { format!("draft {pid}") };
            Op::DraftSet { chat, text }
        }
        26..=31 => Op::Rename { chat, name: format!("n-{pid}") },
        32..=35 => Op::MarkUnread { chat },
        36..=41 => {
            let mode = if rng.below(2) == 0 { "normal" } else { "strict" };
            Op::SetMode { chat, mode: mode.into() }
        }
        42..=61 => {
            let busy = model.chats_with(Some(Role::Busy));
            let chat = rng.pick(&busy).copied().unwrap_or(chat);
            Op::Prompt { chat, pid }
        }
        62..=69 => {
            let pending: Vec<(u32, String)> = model
                .chats
                .iter()
                .flat_map(|(k, c)| c.accepted.iter().map(move |p| (*k, p.clone())))
                .collect();
            match rng.pick(&pending) {
                Some((chat, pid)) => Op::QueueRemove { chat: *chat, pid: pid.clone() },
                None => Op::DraftSet { chat, text: format!("draft {pid}") },
            }
        }
        70..=81 => Op::SendQueue { chat, pid },
        82..=89 => {
            let other: Vec<u32> = chats.iter().copied().filter(|c| *c != chat).collect();
            let watched = *rng.pick(&other).unwrap();
            model.next_tag += 1;
            Op::WatchAdd { to: chat, watched, tag: model.next_tag }
        }
        90..=93 => {
            let live: Vec<u32> = model
                .watches
                .iter()
                .filter(|(_, w)| w.id.is_some() && !w.removed)
                .map(|(k, _)| *k)
                .collect();
            match rng.pick(&live) {
                Some(tag) => Op::WatchRm { tag: *tag },
                None => Op::MarkUnread { chat },
            }
        }
        _ => {
            let ask = model.chats_with(Some(Role::Ask));
            match rng.pick(&ask) {
                Some(chat) => Op::PermissionAnswer { chat: *chat },
                None => Op::MarkUnread { chat },
            }
        }
    }
}

/// The turn a chat of `role` runs while it waits: Busy runs until cancelled, Ask waits on a
/// permission answer.
fn arm(client: &mut Client, id: &str, role: Role, n: u64) {
    match role {
        Role::Busy => client.prompt_async(id, "until-cancel", &format!("arm-busy-{n}")),
        Role::Ask => client.prompt_async(id, "ask: fuzz", &format!("arm-ask-{n}")),
        Role::Plain => {}
    }
}

/// Sends `op` and records what came back. Returns false once the daemon is gone.
fn run_op(client: &mut Client, model: &Mutex<Model>, op: Op, home: &Path) -> bool {
    let sent = Instant::now();
    // Register writes are noted before they go, so a write the daemon may have taken counts.
    let step = {
        let mut m = model.lock().unwrap();
        match &op {
            Op::DraftSet { chat, text } => {
                let value = (!text.trim().is_empty()).then(|| text.clone());
                if let Some(c) = m.chats.get_mut(chat) {
                    c.drafts.push(RegWrite { value, sent, acked: None });
                }
            }
            Op::Rename { chat, name } => {
                if let Some(c) = m.chats.get_mut(chat) {
                    c.names.push(RegWrite { value: Some(name.clone()), sent, acked: None });
                }
            }
            Op::SetMode { chat, mode } => {
                if let Some(c) = m.chats.get_mut(chat) {
                    c.modes.push(RegWrite { value: Some(mode.clone()), sent, acked: None });
                }
            }
            Op::NewChat { label, role } => {
                let c = m.chats.entry(*label).or_default();
                c.role = Some(*role);
                c.unsure = true;
            }
            Op::Prompt { chat, pid } => {
                if let Some(c) = m.chats.get_mut(chat) {
                    c.maybe.insert(pid.clone());
                    // A prompt subscribes this connection as showing the chat
                    // (`server/view.rs` `subscribe_local`), which is seeing it: unread clears.
                    c.unread_acked = false;
                }
            }
            Op::PermissionAnswer { chat } => {
                // Its next waiting turn is a prompt too (`arm`).
                if let Some(c) = m.chats.get_mut(chat) {
                    c.unread_acked = false;
                }
            }
            _ => {}
        }
        m.issued.push(Issued { op: op.clone(), outcome: "sent", latency_ms: None });
        m.issued.len() - 1
    };
    let id_of = |label: &u32| model.lock().unwrap().id(*label);
    let (reply, after): (Reply, After) = match &op {
        Op::Kill => return true,
        Op::NewChat { label, role } => {
            let params = json!({"cwd": home.join("p"), "mcpServers": [],
                                "_meta": {"acpmux": {"name": format!("c{label}")}}});
            let (label, role) = (*label, *role);
            (
                client.call("session/new", params),
                then(move |m: &mut Model, v: &Value| {
                    let c = m.chats.entry(label).or_default();
                    c.id = v["sessionId"].as_str().map(str::to_owned);
                    c.role = Some(role);
                    c.unsure = false;
                    c.names.push(RegWrite {
                        value: Some(format!("c{label}")),
                        sent,
                        acked: Some(sent),
                    });
                }),
            )
        }
        Op::DraftSet { chat, text } => {
            let Some(id) = id_of(chat) else { return true };
            let chat = *chat;
            (
                client.call("_acpmux/draft_set", json!({"sessionId": id, "text": text})),
                then(move |m: &mut Model, _v: &Value| ack_last(m, chat, Reg::Draft, sent)),
            )
        }
        Op::Rename { chat, name } => {
            let Some(id) = id_of(chat) else { return true };
            let chat = *chat;
            (
                client.call("_acpmux/rename", json!({"sessionId": id, "newName": name})),
                then(move |m: &mut Model, _v: &Value| ack_last(m, chat, Reg::Name, sent)),
            )
        }
        Op::MarkUnread { chat } => {
            let Some(id) = id_of(chat) else { return true };
            let chat = *chat;
            (
                client.call("_acpmux/markUnread", json!({"sessionId": id})),
                then(move |m: &mut Model, _v: &Value| {
                    if let Some(c) = m.chats.get_mut(&chat) {
                        c.unread_acked = true;
                    }
                }),
            )
        }
        Op::SetMode { chat, mode } => {
            let Some(id) = id_of(chat) else { return true };
            let chat = *chat;
            (
                client.call("session/set_mode", json!({"sessionId": id, "modeId": mode})),
                then(move |m: &mut Model, _v: &Value| ack_last(m, chat, Reg::Mode, sent)),
            )
        }
        Op::Prompt { chat, pid } => {
            let Some(id) = id_of(chat) else { return true };
            let (chat, p) = (*chat, pid.clone());
            (
                client.prompt(&id, &format!("q {pid}"), pid),
                then(move |m: &mut Model, _v: &Value| {
                    if let Some(c) = m.chats.get_mut(&chat) {
                        c.accepted.insert(p);
                    }
                }),
            )
        }
        Op::QueueRemove { chat, pid } => {
            let Some(id) = id_of(chat) else { return true };
            let (chat, p) = (*chat, pid.clone());
            (
                client.call("_acpmux/queue_remove", json!({"sessionId": id, "promptId": pid})),
                then(move |m: &mut Model, v: &Value| {
                    if v["removed"] == true
                        && let Some(c) = m.chats.get_mut(&chat)
                    {
                        c.accepted.remove(&p);
                        c.removed.insert(p);
                    }
                }),
            )
        }
        Op::SendQueue { chat, pid } => {
            let Some(id) = id_of(chat) else { return true };
            let request = json!({"sessionId": id, "prompt": [{"type": "text", "text": format!("o {pid}")}],
                                 "_meta": {"acpmux": {"promptId": pid, "steer": false, "resend": false}}});
            (
                client.call("_acpmux/send_queue", json!({"request": request})),
                then(move |m: &mut Model, v: &Value| {
                    if let Some(d) = v["deliveryId"].as_str() {
                        m.deliveries.push((d.to_owned(), step));
                    }
                }),
            )
        }
        Op::WatchAdd { to, watched, tag } => {
            let (Some(to_id), Some(watched_id)) = (id_of(to), id_of(watched)) else { return true };
            let (to, tag) = (*to, *tag);
            model.lock().unwrap().watches.insert(tag, WatchModel { to, ..Default::default() });
            (
                client.call(
                    "_acpmux/watch_add",
                    json!({"to": to_id, "sessions": [watched_id], "once": true}),
                ),
                then(move |m: &mut Model, v: &Value| {
                    if let Some(w) = m.watches.get_mut(&tag) {
                        w.id = v["id"].as_str().map(str::to_owned);
                    }
                }),
            )
        }
        Op::WatchRm { tag } => {
            let Some(wid) = model.lock().unwrap().watches.get(tag).and_then(|w| w.id.clone())
            else {
                return true;
            };
            let tag = *tag;
            if let Some(w) = model.lock().unwrap().watches.get_mut(&tag) {
                w.maybe_removed = true;
            }
            (
                client.call("_acpmux/watch_rm", json!({"id": wid})),
                then(move |m: &mut Model, _v: &Value| {
                    if let Some(w) = m.watches.get_mut(&tag) {
                        w.removed = true;
                    }
                }),
            )
        }
        Op::PermissionAnswer { chat } => {
            let Some(id) = id_of(chat) else { return true };
            let info = match client.call("_acpmux/info", json!({"sessionId": id})) {
                Reply::Ok(v) => v,
                Reply::Dead => return finish(model, step, "dead", None),
                Reply::Timeout => return finish(model, step, "timeout", None),
                Reply::Err(_) => return finish(model, step, "error", None) | true,
            };
            let Some(pid) = info["pending"]
                .as_array()
                .and_then(|p| p.first())
                .and_then(|p| p["permissionId"].as_str())
                .map(str::to_owned)
            else {
                return finish(model, step, "nothing pending", None) | true;
            };
            let chat = *chat;
            // A reject: only the person's proof allows (`hub/person.rs`).
            let params = json!({"sessionId": id, "permissionId": pid, "optionId": "no"});
            let reply = client.call("_acpmux/permission_respond", params);
            if matches!(reply, Reply::Ok(_)) {
                let n = model.lock().unwrap().next_pid;
                arm(client, &id, Role::Ask, n);
            }
            (
                reply,
                then(move |m: &mut Model, _v: &Value| {
                    if let Some(c) = m.chats.get_mut(&chat) {
                        c.answered.insert(pid);
                    }
                }),
            )
        }
    };
    let latency = sent.elapsed().as_millis() as u64;
    match reply {
        Reply::Ok(v) => {
            let mut m = model.lock().unwrap();
            after(&mut *m, &v);
            drop(m);
            // A new waiting chat starts its waiting turn.
            if let Op::NewChat { role, label } = &op
                && let Some(id) = v["sessionId"].as_str()
            {
                arm(client, id, *role, u64::from(*label));
            }
            finish(model, step, "ok", Some(latency))
        }
        Reply::Err(_) => finish(model, step, "error", Some(latency)),
        Reply::Dead => finish(model, step, "dead", None),
        Reply::Timeout => finish(model, step, "timeout", Some(latency)),
    }
}

#[derive(Clone, Copy)]
enum Reg {
    Draft,
    Name,
    Mode,
}

fn ack_last(m: &mut Model, chat: u32, reg: Reg, sent: Instant) {
    let Some(c) = m.chats.get_mut(&chat) else { return };
    let writes = match reg {
        Reg::Draft => &mut c.drafts,
        Reg::Name => &mut c.names,
        Reg::Mode => &mut c.modes,
    };
    if let Some(w) = writes.iter_mut().rev().find(|w| w.sent == sent) {
        w.acked = Some(Instant::now());
    }
}

/// What a request's answer changes in the model.
type After = Box<dyn FnOnce(&mut Model, &Value)>;

fn then(f: impl FnOnce(&mut Model, &Value) + 'static) -> After {
    Box::new(f)
}

/// Records the outcome of step `step`; false when the daemon is gone.
fn finish(model: &Mutex<Model>, step: usize, outcome: &'static str, latency: Option<u64>) -> bool {
    let mut m = model.lock().unwrap();
    if let Some(i) = m.issued.get_mut(step) {
        i.outcome = outcome;
        i.latency_ms = latency;
    }
    outcome != "dead"
}

// ------------------------------------------------------------------ the checks after a restart

/// Text of every record of `kinds` in a chat's log.
fn log_text(client: &mut Client, id: &str, kinds: &[&str]) -> Result<String, String> {
    let page = client.get(
        "_acpmux/events",
        json!({"sessionId": id, "afterSeq": 0, "limit": 5000, "maxBytes": 4_194_304, "kinds": kinds}),
    )?;
    Ok(page["events"].to_string())
}

fn step_of(model: &Model, pred: impl Fn(&Op) -> bool) -> (usize, String) {
    model
        .issued
        .iter()
        .enumerate()
        .rev()
        .find(|(_, i)| pred(&i.op))
        .map(|(n, i)| (n, i.op.name().to_owned()))
        .unwrap_or((0, "-".into()))
}

/// Durable answers the checks after the restarts compared, by kind (coverage: a pass that
/// checked nothing proves nothing).
static CHECKED: Mutex<BTreeMap<&'static str, u64>> = Mutex::new(BTreeMap::new());

fn checked(kind: &'static str, n: usize) {
    *CHECKED.lock().unwrap().entry(kind).or_default() += n as u64;
}

/// Checks the restarted daemon against the model.
fn check(daemon: &mut Daemon, model: &Model) -> Vec<Finding> {
    let mut out = Vec::new();
    let mut bad = |step: usize, op: &str, kind: &'static str, what: String| {
        out.push(Finding { step, op: op.to_owned(), kind, what });
    };
    let last = model.issued.len().saturating_sub(1);
    let Some(mut client) = Client::connect(&daemon.socket) else {
        bad(last, "restart", "restart", "the restarted daemon does not answer".into());
        return out;
    };
    // (3) Every listed session once, and only sessions this test created.
    match client.get("session/list", json!({})) {
        Ok(list) => {
            let ids: Vec<String> = list["sessions"]
                .as_array()
                .into_iter()
                .flatten()
                .filter_map(|s| s["sessionId"].as_str().map(str::to_owned))
                .collect();
            let unique: BTreeSet<&String> = ids.iter().collect();
            if unique.len() != ids.len() {
                bad(
                    last,
                    "session/list",
                    "duplicate",
                    format!("a session is listed twice: {ids:?}"),
                );
            }
            let known: BTreeSet<String> =
                model.chats.values().filter_map(|c| c.id.clone()).collect();
            let unsure = model.chats.values().filter(|c| c.unsure).count();
            let extra: Vec<&String> =
                unique.iter().copied().filter(|i| !known.contains(*i)).collect();
            if extra.len() > unsure {
                bad(
                    last,
                    "session/list",
                    "phantom",
                    format!("sessions this test did not create: {extra:?}"),
                );
            }
            for (label, c) in &model.chats {
                if let Some(id) = &c.id
                    && !unique.contains(id)
                {
                    let (step, op) =
                        step_of(model, |o| matches!(o, Op::NewChat { label: l, .. } if l == label));
                    bad(step, &op, "lost-session", format!("chat c{label} ({id}) is not listed"));
                }
            }
        }
        Err(e) => bad(last, "session/list", "restart", e),
    }
    for (label, c) in &model.chats {
        let Some(id) = &c.id else { continue };
        let info = match client.get("_acpmux/info", json!({"sessionId": id})) {
            Ok(v) => v,
            Err(e) => {
                bad(last, "_acpmux/info", "restart", format!("c{label}: {e}"));
                continue;
            }
        };
        checked("chats", 1);
        // Drafts: promised durable.
        if let Some(ok) = allowed(&c.drafts) {
            checked("drafts", 1);
            let now = client
                .get("_acpmux/draft_get", json!({"sessionId": id}))
                .map(|v| v["draft"].as_str().map(str::to_owned));
            match now {
                Ok(now) if !ok.contains(&now) => {
                    let (step, op) =
                        step_of(model, |o| matches!(o, Op::DraftSet { chat, .. } if chat == label));
                    bad(step, &op, "lost-draft", format!("c{label} draft {now:?}, allowed {ok:?}"));
                }
                Ok(_) => {}
                Err(e) => bad(last, "_acpmux/draft_get", "restart", e),
            }
        }
        // Not promised: the name, the mode, the unread mark.
        if let Some(ok) = allowed(&c.names) {
            let now = info["name"].as_str().map(str::to_owned);
            if !ok.contains(&now) {
                let (step, op) =
                    step_of(model, |o| matches!(o, Op::Rename { chat, .. } if chat == label));
                bad(step, &op, "note:name", format!("c{label} name {now:?}, allowed {ok:?}"));
            }
        }
        if let Some(ok) = allowed(&c.modes) {
            let now = info["currentModeId"].as_str().map(str::to_owned);
            if !ok.contains(&now) {
                let (step, op) =
                    step_of(model, |o| matches!(o, Op::SetMode { chat, .. } if chat == label));
                bad(step, &op, "note:mode", format!("c{label} mode {now:?}, allowed {ok:?}"));
            }
        }
        if c.unread_acked && info["unread"] != true {
            let (step, op) =
                step_of(model, |o| matches!(o, Op::MarkUnread { chat } if chat == label));
            bad(
                step,
                &op,
                "note:unread",
                format!("c{label} unread is {} after an acknowledged markUnread", info["unread"]),
            );
        }
        // Accepted prompts: still queued, or ran. Removed ones: neither queued nor run since.
        // A prompt may move from the queue to its turn between the two reads: read again.
        let mut missing: Vec<String> = Vec::new();
        let mut back: Vec<String> = Vec::new();
        for attempt in 0..6 {
            let queue = match client.get("_acpmux/info", json!({"sessionId": id})) {
                Ok(v) => v["queue"].to_string(),
                Err(e) => {
                    bad(last, "_acpmux/info", "restart", e);
                    break;
                }
            };
            let ran = match log_text(&mut client, id, &["user_message"]) {
                Ok(t) => t,
                Err(e) => {
                    bad(last, "_acpmux/events", "restart", e);
                    break;
                }
            };
            let found = |p: &String| {
                let key = format!("\"promptId\":\"{p}\"");
                queue.contains(&key) || ran.contains(&key)
            };
            missing = c.accepted.iter().filter(|p| !found(*p)).cloned().collect();
            back = c
                .removed
                .iter()
                .filter(|p| queue.contains(&format!("\"promptId\":\"{p}\"")))
                .cloned()
                .collect();
            if (missing.is_empty() && back.is_empty()) || attempt == 5 {
                break;
            }
            std::thread::sleep(Duration::from_millis(300));
        }
        checked("prompts", c.accepted.len());
        checked("removals", c.removed.len());
        for p in missing {
            let (step, op) = step_of(model, |o| matches!(o, Op::Prompt { pid, .. } if *pid == p));
            bad(
                step,
                &op,
                "lost-prompt",
                format!("c{label} accepted prompt {p} is neither queued nor run"),
            );
        }
        for p in back {
            let (step, op) =
                step_of(model, |o| matches!(o, Op::QueueRemove { pid, .. } if *pid == p));
            bad(step, &op, "removed-back", format!("c{label} removed prompt {p} is queued again"));
        }
        if !c.answered.is_empty() {
            let decisions = log_text(&mut client, id, &["permission_decision"]).unwrap_or_default();
            for p in &c.answered {
                if !decisions.contains(p.as_str()) {
                    let (step, op) = step_of(
                        model,
                        |o| matches!(o, Op::PermissionAnswer { chat } if chat == label),
                    );
                    bad(
                        step,
                        &op,
                        "note:permission",
                        format!("c{label} answered permission {p} has no permission_decision"),
                    );
                }
            }
        }
    }
    // The outbox: every acknowledged delivery is still known.
    checked("deliveries", model.deliveries.len());
    for (delivery, step) in &model.deliveries {
        if let Err(e) = client.get("_acpmux/send_status", json!({"deliveryId": delivery})) {
            bad(*step, "_acpmux/send_queue", "lost-delivery", format!("delivery {delivery}: {e}"));
        }
    }
    // Watches: an acknowledged add is listed, pending or delivered; an acknowledged remove
    // stays removed.
    match client.get("_acpmux/watch_ls", json!({})) {
        Ok(ls) => {
            let listed = ls["watches"].to_string();
            let owed = ls["deliveries"].to_string();
            for (tag, w) in &model.watches {
                let Some(wid) = &w.id else { continue };
                checked(if w.removed { "watch_removals" } else { "watches" }, 1);
                let (step, op) =
                    step_of(model, |o| matches!(o, Op::WatchAdd { tag: t, .. } if t == tag));
                let is_listed = listed.contains(&format!("\"id\":\"{wid}\""));
                if w.removed && is_listed {
                    let (step, op) =
                        step_of(model, |o| matches!(o, Op::WatchRm { tag: t } if t == tag));
                    bad(step, &op, "watch-back", format!("removed watch {wid} is listed again"));
                } else if !w.removed
                    && !w.maybe_removed
                    && !is_listed
                    && !owed.contains(wid.as_str())
                {
                    // Delivered: its message went to the recipient (once watches end on delivery).
                    let to_text = model
                        .id(w.to)
                        .map(|id| {
                            log_text(&mut client, &id, &["user_message", "queued"])
                                .unwrap_or_default()
                        })
                        .unwrap_or_default();
                    if !to_text.contains(wid.as_str()) {
                        bad(
                            step,
                            &op,
                            "lost-watch",
                            format!("watch {wid} is neither listed nor delivered"),
                        );
                    }
                }
            }
        }
        Err(e) => bad(last, "_acpmux/watch_ls", "restart", e),
    }
    drop(client);
    std::thread::sleep(Duration::from_millis(300));
    if !daemon.running() {
        bad(
            last,
            "restart",
            "crash-loop",
            format!("the restarted daemon exited: {}", daemon.stderr_tail()),
        );
    }
    out
}

/// After a restart: start the waiting turns again (the agents died with the daemon).
fn rearm(daemon: &Daemon, model: &Mutex<Model>, epoch: u64) -> Option<Client> {
    let mut client = Client::connect(&daemon.socket)?;
    let chats: Vec<(String, Role)> = {
        let mut m = model.lock().unwrap();
        // The waiting turns' prompts show their chats: unread clears (see `run_op`).
        for c in m.chats.values_mut() {
            if c.role.is_some_and(|r| r != Role::Plain) {
                c.unread_acked = false;
            }
        }
        m.chats.values().filter_map(|c| Some((c.id.clone()?, c.role?))).collect()
    };
    for (id, role) in chats {
        arm(&mut client, &id, role, 1_000_000 + epoch);
    }
    Some(client)
}

// ------------------------------------------------------------------ one fuzz run

#[derive(Default)]
struct Totals {
    ops: u64,
    kills: u64,
    latencies: Vec<u64>,
    violations: Vec<Finding>,
    notes: Vec<Finding>,
    restart_ms: Vec<u64>,
    /// Requests the kill cut before their answer (in flight at the kill).
    cut: u64,
}

/// Splits the findings: notes (unpromised losses) and violations.
fn sort_findings(found: Vec<Finding>, totals: &mut Totals) {
    for f in found {
        if f.kind.starts_with("note:") {
            totals.notes.push(f);
        } else {
            totals.violations.push(f);
        }
    }
}

/// One seed: `rounds` epochs of concurrent clients, each ended by a `kill -9`. Returns the
/// issued log (with kill markers) for the shrinker.
fn fuzz_seed(seed: u64, rounds: u32, budget: Duration, totals: &mut Totals) -> Vec<Op> {
    let began = Instant::now();
    let mut daemon = Daemon::new(&format!("{:x}", seed & 0xffff_ffff));
    let model = Arc::new(Mutex::new(Model::default()));
    let mut log: Vec<Op> = Vec::new();
    let mut rng = Rng(seed);
    if let Err(e) = daemon.start() {
        totals.violations.push(Finding { step: 0, op: "start".into(), kind: "restart", what: e });
        return log;
    }
    let mut admin = rearm(&daemon, &model, 0);
    for epoch in 0..u64::from(rounds) {
        if began.elapsed() > budget {
            break;
        }
        let acked = Arc::new(AtomicU64::new(0));
        let stop = Arc::new(AtomicBool::new(false));
        let mut threads = Vec::new();
        for c in 0..CLIENTS {
            let mut crng =
                Rng(seed ^ (epoch << 32) ^ (c as u64 + 1).wrapping_mul(0x5851_F42D_4C95_7F2D));
            let (model, acked, stop) = (model.clone(), acked.clone(), stop.clone());
            let (socket, home) = (daemon.socket.clone(), daemon.home.clone());
            threads.push(std::thread::spawn(move || {
                let Some(mut client) = Client::connect(&socket) else { return };
                for _ in 0..OPS_PER_CLIENT {
                    if stop.load(Ordering::SeqCst) {
                        return;
                    }
                    let op = generate(&mut crng, &mut model.lock().unwrap(), seed);
                    if !run_op(&mut client, &model, op, &home) {
                        return;
                    }
                    acked.fetch_add(1, Ordering::SeqCst);
                    // A little spacing, seeded, so kills land in different places.
                    std::thread::sleep(Duration::from_millis(crng.below(20)));
                }
            }));
        }
        // The kill point: after `target` answers, with the other clients' requests in flight,
        // or once every client has stopped (between requests).
        let target = 4 + rng.below((CLIENTS * OPS_PER_CLIENT) as u64 - 4);
        let in_flight = rng.below(3) != 0;
        let wait_until = Instant::now() + Duration::from_secs(60);
        while acked.load(Ordering::SeqCst) < target
            && !threads.iter().all(|t| t.is_finished())
            && Instant::now() < wait_until
        {
            std::thread::sleep(Duration::from_millis(2));
        }
        if !in_flight {
            stop.store(true, Ordering::SeqCst);
            for t in threads.drain(..) {
                let _ = t.join();
            }
        }
        daemon.kill9();
        drop(admin.take());
        for t in threads.drain(..) {
            let _ = t.join();
        }
        totals.kills += 1;
        {
            let m = model.lock().unwrap();
            log = m.issued.iter().map(|i| i.op.clone()).collect();
        }
        log.push(Op::Kill);
        match daemon.start() {
            Ok(took) => totals.restart_ms.push(took.as_millis() as u64),
            Err(e) => {
                let step = model.lock().unwrap().issued.len();
                totals.violations.push(Finding {
                    step,
                    op: "restart".into(),
                    kind: "restart",
                    what: e,
                });
                break;
            }
        }
        let found = check(&mut daemon, &model.lock().unwrap());
        let had = totals.violations.len();
        sort_findings(found, totals);
        if totals.violations.len() > had {
            break;
        }
        admin = rearm(&daemon, &model, epoch + 1);
        // Mark the kill in the issued log so later steps number after it.
        model.lock().unwrap().issued.push(Issued {
            op: Op::Kill,
            outcome: "kill",
            latency_ms: None,
        });
    }
    let m = model.lock().unwrap();
    for (step, i) in m.issued.iter().enumerate() {
        if matches!(i.op, Op::Kill) {
            continue;
        }
        totals.ops += 1;
        if i.outcome == "dead" {
            totals.cut += 1;
        }
        if let Some(ms) = i.latency_ms {
            totals.latencies.push(ms);
            if ms > STALL_MS {
                totals.violations.push(Finding {
                    step,
                    op: i.op.name().into(),
                    kind: "stall",
                    what: format!("{} ms ({})", ms, i.outcome),
                });
            }
        }
    }
    log
}

// ------------------------------------------------------------------ replay and shrink

/// Runs `ops` one at a time on a fresh daemon; the kinds of violation it shows (stalls left out:
/// a replay measures durability).
fn replay(ops: &[Op], tag: &str) -> BTreeSet<&'static str> {
    let mut kinds = BTreeSet::new();
    let mut daemon = Daemon::new(tag);
    if daemon.start().is_err() {
        kinds.insert("restart");
        return kinds;
    }
    let model = Mutex::new(Model::default());
    let mut client = Client::connect(&daemon.socket);
    for op in ops {
        if matches!(op, Op::Kill) {
            daemon.kill9();
            client = None;
            if daemon.start().is_err() {
                kinds.insert("restart");
                return kinds;
            }
            for f in check(&mut daemon, &model.lock().unwrap()) {
                if !f.kind.starts_with("note:") {
                    kinds.insert(f.kind);
                }
            }
            client = rearm(&daemon, &model, 7);
            continue;
        }
        let Some(c) = client.as_mut() else { break };
        if let Op::NewChat { label, .. } = op {
            let mut m = model.lock().unwrap();
            m.next_label = m.next_label.max(*label);
        }
        if !run_op(c, &model, op.clone(), &daemon.home.clone()) {
            client = None;
        }
    }
    kinds
}

/// Drops operations while the replay still shows `kind`; the shortest list found in `budget`.
fn shrink(ops: Vec<Op>, kind: &'static str, budget: Duration) -> (Vec<Op>, bool, u32) {
    let began = Instant::now();
    let mut tries = 0u32;
    tries += 1;
    if !replay(&ops, "sh0").contains(kind) {
        return (ops, false, tries);
    }
    let mut best = ops;
    let mut chunk = best.len().div_ceil(2).max(1);
    while chunk >= 1 && began.elapsed() < budget {
        let mut i = 0;
        let mut dropped = false;
        while i < best.len() && began.elapsed() < budget {
            let mut candidate = best.clone();
            let end = (i + chunk).min(candidate.len());
            candidate.drain(i..end);
            // A list must still end in a kill to check anything.
            if !matches!(candidate.last(), Some(Op::Kill)) {
                candidate.push(Op::Kill);
            }
            tries += 1;
            if replay(&candidate, &format!("sh{tries}")).contains(kind) {
                best = candidate;
                dropped = true;
            } else {
                i += chunk;
            }
        }
        if !dropped {
            if chunk == 1 {
                break;
            }
            chunk = chunk.div_ceil(2);
        }
    }
    (best, true, tries)
}

// ------------------------------------------------------------------ the entry points

fn percentile(sorted: &[u64], p: f64) -> u64 {
    if sorted.is_empty() {
        return 0;
    }
    let i = ((sorted.len() as f64 - 1.0) * p).round() as usize;
    sorted[i.min(sorted.len() - 1)]
}

/// Whether this process may run the fuzz (see the module text).
fn enabled() -> bool {
    std::env::var("CMUX_CI_STEP_KEY").is_ok_and(|k| k.contains("fuzz-g"))
        || std::env::var("ACPMUX_FUZZ_SEED").is_ok()
}

fn run(name: &str, seeds: &[u64], rounds: u32) {
    let _ = HERMETIC;
    if !enabled() {
        println!(
            "FUZZ-G SKIP {name}: runs only in a fleet step keyed fuzz-g or with ACPMUX_FUZZ_SEED"
        );
        return;
    }
    let seeds: Vec<u64> = match std::env::var("ACPMUX_FUZZ_SEED").ok().and_then(|s| s.parse().ok())
    {
        Some(seed) => vec![seed],
        None => seeds.to_vec(),
    };
    let rounds =
        std::env::var("ACPMUX_FUZZ_ROUNDS").ok().and_then(|s| s.parse().ok()).unwrap_or(rounds);
    let mut totals = Totals::default();
    for &seed in &seeds {
        let had = totals.violations.len();
        let notes_had = totals.notes.len();
        let log = fuzz_seed(seed, rounds, Duration::from_secs(70), &mut totals);
        let mut seen = BTreeSet::new();
        for f in &totals.notes[notes_had..] {
            if !seen.insert((f.kind, f.what.clone())) {
                continue;
            }
            println!(
                "FUZZ-G NOTE seed={seed} step={} op={} what={}: {} (not promised)",
                f.step, f.op, f.kind, f.what
            );
        }
        let new: Vec<Finding> = totals.violations[had..].to_vec();
        for f in &new {
            println!(
                "FUZZ-G VIOLATION seed={seed} step={} op={} what={}: {}",
                f.step, f.op, f.kind, f.what
            );
        }
        // Shrink the first durability violation (a stall is a timing, not a sequence).
        if let Some(f) = new.iter().find(|f| f.kind != "stall") {
            let upto: Vec<Op> = log.clone();
            let (min, reproduced, tries) = shrink(upto, f.kind, Duration::from_secs(90));
            println!(
                "FUZZ-G SHRUNK seed={seed} what={} reproduced_sequentially={reproduced} tries={tries} ops={}",
                f.kind,
                min.len()
            );
            for (n, op) in min.iter().enumerate() {
                println!("FUZZ-G SHRUNK-OP {n}: {op:?}");
            }
        }
    }
    let mut lat = totals.latencies.clone();
    lat.sort_unstable();
    let mut restart = totals.restart_ms.clone();
    restart.sort_unstable();
    println!(
        "FUZZ-G SUMMARY test={name} seeds={} ops={} kills={} cut_in_flight={} violations={} notes={} latency_ms p50={} p95={} p99={} max={} restart_ms p50={} max={} checked={:?}",
        seeds.len(),
        totals.ops,
        totals.kills,
        totals.cut,
        totals.violations.len(),
        totals.notes.len(),
        percentile(&lat, 0.50),
        percentile(&lat, 0.95),
        percentile(&lat, 0.99),
        lat.last().copied().unwrap_or(0),
        percentile(&restart, 0.50),
        restart.last().copied().unwrap_or(0),
        CHECKED.lock().unwrap(),
    );
    assert!(
        totals.violations.is_empty(),
        "FUZZ-G: {} violations (see the VIOLATION lines)",
        totals.violations.len()
    );
}

#[test]
fn fuzz_g_crash_durable_seed_a() {
    run("seed_a", &[0x6701, 0x6711, 0x6721], 12);
}

#[test]
fn fuzz_g_crash_durable_seed_b() {
    run("seed_b", &[0x6702, 0x6712, 0x6722], 12);
}

#[test]
fn fuzz_g_crash_durable_seed_c() {
    run("seed_c", &[0x6703, 0x6713, 0x6723], 12);
}

#[test]
fn fuzz_g_crash_durable_seed_d() {
    run("seed_d", &[0x6704, 0x6714, 0x6724], 12);
}
