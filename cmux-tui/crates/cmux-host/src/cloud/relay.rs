//! The relay-first chat path (cmuxterm-hq#7086): from bind on, this machine
//! holds one outbound WebSocket to the platform's `MachineRelay`
//! (`GET {platform}/v1/cloud/machines/{machine}/relay`, as this machine's
//! own VM install), so a person's first chat never waits on the app's link
//! to the machine. The platform sends each chat down this socket; the
//! machine runs it in its own acpmux, as the work user, and sends the turn's
//! events back up (`cmux.machine-relay/1`, cmux-platform `MachineRelay.ts`):
//!
//! - down: `chat {id, agent, prompt, cwd?, session?, prompt_id?}`, `cancel {id}`
//! - up: `event {id, event}`, where `event.kind` is `started` (acpmux's
//!   `session` and the `prompt_id`), `text` (an agent message chunk),
//!   `record` (an `_acpmux/event` record, raw, with its `seq`), `permission`
//!   (a permission waits), then `done` or `error`
//!
//! A chat with no `session` makes one (`acp new -d`), then sends the prompt
//! on stdin (`acp send --wait --json --prompt-id`), so a resend with the same
//! prompt id never runs twice. Nothing here logs a prompt or a reply.
//!
//! The thread reconnects with backoff (250 ms doubling to 30 s), minting a
//! fresh bearer each time, and pings every 20 s; a dial the machine's address
//! change caught (a fresh machine's late network attach) is dropped at the
//! change and dialed again at once, not left to its 20 s connect timeout; a socket with no answer for 60 s
//! is dropped and dialed again. A wake from a pause ([`Relay::resumed`], or
//! the wall clock leaping between pings) drops the socket and dials again at
//! once, on a fresh HTTPS connection: the thread's own clock stood still
//! through the pause, so the old socket looks alive here while the platform
//! may send the next chat down it.
//!
//! acpmux owns a chat's turn; the socket only watches it (cmux-platform `plans/cloud/ARCHITECTURE-2026-11.md`, I1:
//! the acpmux session is the source of truth). A socket that drops, for any reason, ends no turn: the chat runs on,
//! and its events wait for the next socket. A cmux-host that stops for a restart ([`Relay::detach`]) leaves the turn
//! running in acpmux too; when the platform sends the chat again, the next cmux-host reattaches (`acp new --reuse`
//! finds the chat's session, and `acp send` with the same prompt id answers the first run's outcome without running
//! the prompt again). Only a `cancel` from the platform or a revocation (the Relay dropped by a rebind) ends a turn.

use std::collections::HashMap;
use std::path::PathBuf;
use std::process::Stdio;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::time::Duration;

use futures_util::{SinkExt as _, StreamExt as _};
use serde_json::{Value, json};
use tokio::io::{AsyncBufReadExt as _, AsyncReadExt as _, AsyncWriteExt as _, BufReader};
use tokio::sync::{mpsc, watch};
use tokio_tungstenite::tungstenite::Message;
use tokio_tungstenite::tungstenite::client::IntoClientRequest as _;
use tokio_tungstenite::tungstenite::http::HeaderValue;

use super::client::{CloudClient, Http};

pub const PROTOCOL: &str = "cmux.machine-relay/1";
const PING_EVERY: Duration = Duration::from_secs(20);
const DEAD_AFTER: Duration = Duration::from_secs(60);
/// The keepalive, byte for byte the frame the platform's runtime answers with a pong (MachineRelay.ts,
/// `setWebSocketAutoResponse`). `json!` sorts its keys (`{"t":"ping","v":1}`), which matched nothing, so no pong
/// came and the host dropped a live socket [`DEAD_AFTER`] after the last frame down: a chat quiet that long ended
/// `cloud.relay.host_gone` (cmuxterm-hq cloud chaos, token-rejected, run 42135490481).
const PING: &str = r#"{"v":1,"t":"ping"}"#;
const CONNECT_TIMEOUT: Duration = Duration::from_secs(20);
/// The first wait after a failed dial, doubling to [`MAX_BACKOFF`]: a fresh machine's first dial that fails costs it
/// a quarter second, not two.
const FIRST_BACKOFF: Duration = Duration::from_millis(250);
const MAX_BACKOFF: Duration = Duration::from_secs(30);
/// Chats run at once; the platform holds at most 8 per machine.
const MAX_CHATS: usize = 8;
const MAX_PROMPT_BYTES: usize = 256 * 1024;

/// The chats this machine is running for the relay, from a chat's arrival to its last event up. The updater
/// (`updater::role`) waits while any runs: its restart of cmux-host ends this socket, and the chat waits for the
/// next cmux-host to reattach.
static RUNNING_CHATS: AtomicUsize = AtomicUsize::new(0);

/// How many relay chats run now.
pub fn running_chats() -> usize {
    RUNNING_CHATS.load(Ordering::SeqCst)
}

/// One running chat in a count, until it is dropped: with its task, also when the task is aborted before it ran.
pub(crate) struct Running(&'static AtomicUsize);

impl Running {
    pub(crate) fn start(count: &'static AtomicUsize) -> Running {
        count.fetch_add(1, Ordering::SeqCst);
        Running(count)
    }
}

impl Drop for Running {
    fn drop(&mut self) {
        self.0.fetch_sub(1, Ordering::SeqCst);
    }
}

/// A chat the platform sent down, checked.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Chat {
    pub id: String,
    pub agent: String,
    pub prompt: String,
    pub cwd: Option<String>,
    pub session: Option<String>,
    pub prompt_id: String,
}

/// One frame from the platform.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Down {
    Chat(Chat),
    Cancel(String),
    Other,
}

fn id_like(s: &str, max: usize) -> bool {
    !s.is_empty()
        && s.len() <= max
        && s.bytes().all(|b| b.is_ascii_alphanumeric() || b"-_.:".contains(&b))
        && s.as_bytes().first().is_some_and(u8::is_ascii_alphanumeric)
}

fn agent_like(s: &str) -> bool {
    let (harness, model) = match s.split_once('/') {
        Some((h, m)) => (h, Some(m)),
        None => (s, None),
    };
    !harness.is_empty()
        && harness.len() <= 32
        && harness.as_bytes().first().is_some_and(u8::is_ascii_alphanumeric)
        && harness.bytes().all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b"._-".contains(&b))
        // acpmux's HARNESS[/MODEL], where a model may nest (`opencode/zai/glm-5.1`).
        && model.is_none_or(|m| m.len() <= 128 && m.split('/').count() <= 4 && m.split('/').all(|seg| id_like(seg, 64)))
}

/// Parses a platform frame. A chat whose fields are not well formed is
/// [`Down::Other`]: the platform checked them already, and nothing here runs
/// a value that could reach a shell or a flag.
pub fn parse_down(text: &str) -> Down {
    let Ok(v) = serde_json::from_str::<Value>(text) else { return Down::Other };
    if v.get("v") != Some(&json!(1)) {
        return Down::Other;
    }
    let s = |k: &str| v.get(k).and_then(Value::as_str);
    let Some(id) = s("id").filter(|id| id_like(id, 64)) else { return Down::Other };
    match s("t") {
        Some("cancel") => Down::Cancel(id.to_owned()),
        Some("chat") => {
            let (Some(agent), Some(prompt)) = (s("agent"), s("prompt")) else { return Down::Other };
            let cwd = s("cwd");
            let session = s("session");
            let prompt_id = s("prompt_id");
            if !agent_like(agent)
                || prompt.trim().is_empty()
                || prompt.len() > MAX_PROMPT_BYTES
                || cwd.is_some_and(|c| !c.starts_with('/') || c.contains('\0') || c.len() > 1024)
                || session.is_some_and(|x| !id_like(x, 128))
                || prompt_id.is_some_and(|x| !id_like(x, 128))
            {
                return Down::Other;
            }
            Down::Chat(Chat {
                id: id.to_owned(),
                agent: agent.to_owned(),
                prompt: prompt.to_owned(),
                cwd: cwd.map(str::to_owned),
                session: session.map(str::to_owned),
                prompt_id: prompt_id.map_or_else(|| format!("relay-{id}"), str::to_owned),
            })
        }
        _ => Down::Other,
    }
}

/// The frame that carries one event of chat `id` up.
pub fn up(id: &str, event: Value) -> String {
    json!({"v": 1, "t": "event", "id": id, "event": event}).to_string()
}

/// The session a relay chat makes: named after its whole chat id, so a retry finds it and no other chat shares it.
pub fn session_name(chat: &Chat) -> String {
    format!("relay-{}", chat.id)
}

/// `acp new`'s arguments for a chat with no session.
pub fn new_args(chat: &Chat, home: &str) -> Vec<String> {
    let cwd = chat.cwd.clone().unwrap_or_else(|| home.to_owned());
    [
        "acp",
        "--json",
        "new",
        "-d",
        "--reuse",
        "-m",
        &chat.agent,
        "-n",
        &session_name(chat),
        "--cwd",
        &cwd,
    ]
    .iter()
    .map(|s| (*s).to_owned())
    .collect()
}

/// `acp tail`'s arguments: every record of `session` from its start, then what comes live (agent message chunks,
/// permission asks). `acp --json send --wait` prints only its final object, so the turn's events come from here.
pub fn tail_args(session: &str) -> Vec<String> {
    ["acp", "--json", "tail", "--since", "0", "-f", session]
        .iter()
        .map(|s| (*s).to_owned())
        .collect()
}

/// `acp send`'s arguments; the prompt goes on stdin.
pub fn send_args(chat: &Chat, session: &str) -> Vec<String> {
    ["acp", "--json", "send", "--wait", "--no-steer", "--prompt-id", &chat.prompt_id, session, "-"]
        .iter()
        .map(|s| (*s).to_owned())
        .collect()
}

/// `acp cancel`'s arguments: ends the session's running turn in the acpmux daemon.
pub fn cancel_args(session: &str) -> Vec<String> {
    ["acp", "cancel", session].iter().map(|s| (*s).to_owned()).collect()
}

/// `acp last`'s arguments: the session's last replies.
pub fn last_args(session: &str) -> Vec<String> {
    ["acp", "--json", "last", session].iter().map(|s| (*s).to_owned()).collect()
}

/// The newest reply `acp --json last` printed (`{sessionId, replies: [...]}`), else `None`.
pub fn last_reply(stdout: &str) -> Option<String> {
    let v: Value = serde_json::from_str(stdout.trim()).ok()?;
    v.get("replies")?.as_array()?.last()?.as_str().map(str::to_owned)
}

/// Whether `acp --json new --reuse` found the session there already (`reused: true`).
pub fn reused_session(stdout: &str) -> bool {
    serde_json::from_str::<Value>(stdout.trim())
        .is_ok_and(|v| v.get("reused").and_then(Value::as_bool) == Some(true))
}

/// The acpmux session id `acp --json new` printed, else `None`.
pub fn created_session(stdout: &str) -> Option<String> {
    let v: Value = serde_json::from_str(stdout.trim()).ok()?;
    ["sessionId", "id"].iter().find_map(|k| v.get(*k).and_then(Value::as_str)).map(str::to_owned)
}

/// The relay events of one `acp --json tail` line: a notification (`{method, params}`), or a logged record
/// (an object with its `seq` and `cursor`).
pub fn events_of(line: &str) -> Vec<Value> {
    let Ok(v) = serde_json::from_str::<Value>(line) else { return Vec::new() };
    let (Some(method), Some(params)) = (v.get("method").and_then(Value::as_str), v.get("params"))
    else {
        return match v.get("seq").cloned() {
            Some(seq) if v.is_object() => vec![json!({"kind": "record", "record": v, "seq": seq})],
            _ => Vec::new(),
        };
    };
    match method {
        "session/update" => {
            let update = params.get("update");
            let kind = update.and_then(|u| u.get("sessionUpdate")).and_then(Value::as_str);
            let text = update
                .and_then(|u| u.pointer("/content/text"))
                .and_then(Value::as_str)
                .filter(|t| !t.is_empty());
            match (kind, text) {
                (Some("agent_message_chunk"), Some(text)) => {
                    vec![json!({"kind": "text", "text": text})]
                }
                _ => Vec::new(),
            }
        }
        "_acpmux/event" => {
            let mut e = json!({"kind": "record", "record": params});
            if let (Some(seq), Some(o)) = (params.get("seq").cloned(), e.as_object_mut()) {
                o.insert("seq".to_owned(), seq);
            }
            vec![e]
        }
        "_acpmux/permission_pending" => vec![json!({"kind": "permission", "request": params})],
        _ => Vec::new(),
    }
}

/// The final event once `acp --json send --wait` exited: its stdout is one object, `{sessionId, reply, stopReason,
/// ...}`. `done` carries the whole reply, which stands over the streamed text (a chunk may come before `tail` is
/// attached).
pub fn final_event(exit: Option<i32>, stdout: &str, stderr: &str) -> Value {
    final_event_of(exit, stdout, false, stderr)
}

/// [`final_event`], where `cut` says the send's output passed [`MAX_SEND_OUT`]: its object is not whole, so
/// `done` carries no `reply` (the streamed `text` events stand) and says so with `reply_cut`.
///
/// A failure keeps acpmux's type: its `--json` error envelope (`cli/errors.rs`, the last stderr line) gives the
/// `detail` (`daemon_closed`, `trust_required`, ...), acpmux's own `code`, `retryable`, the `errorKind` and a closed
/// daemon's `cause` (`panicked`, `crashed`, `socket_left`, ...: acpmux `client::closed_cause`) and its `recovery`, so a
/// closed daemon, a refused permission and an auth failure stay told apart past the relay (hq#7086). Only short
/// code-shaped words go up beside acpmux's sentence; stderr with no envelope stays a plain failure.
pub fn final_event_of(exit: Option<i32>, stdout: &str, cut: bool, stderr: &str) -> Value {
    if exit == Some(0) {
        if cut {
            return json!({"kind": "done", "stop_reason": "end_turn", "reply_cut": true});
        }
        let v = serde_json::from_str::<Value>(stdout.trim()).unwrap_or(Value::Null);
        let stop = v.get("stopReason").and_then(Value::as_str).unwrap_or("end_turn");
        let mut done = json!({"kind": "done", "stop_reason": stop});
        if let (Some(reply), Some(o)) =
            (v.get("reply").and_then(Value::as_str), done.as_object_mut())
        {
            o.insert("reply".to_owned(), json!(reply));
        }
        return done;
    }
    let line = stderr.lines().rev().find(|l| !l.trim().is_empty()).unwrap_or("").trim();
    let envelope = serde_json::from_str::<Value>(line)
        .ok()
        .and_then(|v| v.get("error").cloned())
        .filter(|e| e.get("code").is_some_and(Value::is_string));
    let word = |key: &str| {
        envelope
            .as_ref()
            .and_then(|e| e.pointer(key))
            .and_then(Value::as_str)
            .filter(|w| code_like(w))
    };
    // A signal leaves no exit status: the envelope's own exit decides then.
    let exit = exit.or_else(|| {
        envelope.as_ref().and_then(|e| e.get("exit")).and_then(Value::as_i64).map(|x| x as i32)
    });
    // acpmux's exit codes (cli/errors.rs `Code`).
    let code = match exit {
        Some(3) => "chat.timeout",
        Some(4) => "chat.no_session",
        Some(5) => "chat.permission_denied",
        _ => "chat.failed",
    };
    let message =
        envelope.as_ref().and_then(|e| e.get("message")).and_then(Value::as_str).unwrap_or(line);
    let mut event = json!({"kind": "error", "code": code, "message": message.chars().take(300).collect::<String>()});
    if let (Some(e), Some(o)) = (&envelope, event.as_object_mut()) {
        for (from, to) in [
            ("/code", "acpmux_code"),
            ("/detail", "detail"),
            ("/errorKind", "error_kind"),
            ("/data/cause", "cause"),
        ] {
            if let Some(w) = word(from) {
                o.insert(to.to_owned(), json!(w));
            }
        }
        if let Some(retryable) = e.get("retryable").and_then(Value::as_bool) {
            o.insert("retryable".to_owned(), json!(retryable));
        }
        // What to do about it (acpmux `recovery.rs`): acpmux's own sentence, bounded as the message is.
        if let Some(recovery) =
            e.get("recovery").and_then(Value::as_str).filter(|r| !r.trim().is_empty())
        {
            o.insert("recovery".to_owned(), json!(recovery.chars().take(300).collect::<String>()));
        }
    }
    event
}

/// A short code (`daemon_closed`, `auth.signed_out`): never a sentence, a path or a value.
fn code_like(s: &str) -> bool {
    !s.is_empty()
        && s.len() <= 64
        && s.bytes().all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b"_.-".contains(&b))
}

/// `https://x` to `wss://x/v1/cloud/machines/{machine}/relay`.
pub fn relay_url(platform_origin: &str, machine: &str) -> Option<String> {
    let rest = platform_origin.strip_prefix("https://")?;
    if !id_like(machine, 64) {
        return None;
    }
    Some(format!("wss://{}/v1/cloud/machines/{machine}/relay", rest.trim_end_matches('/')))
}

/// Who runs the chats: the work user, with its home and a clean environment.
#[derive(Clone, Debug)]
pub struct Runner {
    pub bin: PathBuf,
    pub user: String,
    pub uid: u32,
    pub gid: u32,
    /// The user's own supplementary groups: the chat's processes get these, never the root worker's.
    pub groups: Vec<u32>,
    pub home: PathBuf,
}

impl Runner {
    fn command(&self, args: &[String]) -> tokio::process::Command {
        let mut c = tokio::process::Command::new(&self.bin);
        // As the daemon spawn drops privilege (linux/spawn.rs): the user's groups, then its gid and uid. Std's
        // `uid`/`gid` would leave it no supplementary groups of its own.
        // SAFETY: geteuid has no preconditions.
        let drop_to = (self.uid != unsafe { libc::geteuid() })
            .then(|| (self.uid, self.gid, self.groups.clone()));
        // SAFETY: the closure makes only async-signal-safe calls and allocates nothing (the list is moved in).
        unsafe {
            c.pre_exec(move || {
                if let Some((uid, gid, groups)) = &drop_to
                    && (libc::setgroups(groups.len() as _, groups.as_ptr()) < 0
                        || libc::setgid(*gid) < 0
                        || libc::setuid(*uid) < 0)
                {
                    return Err(std::io::Error::last_os_error());
                }
                Ok(())
            });
        }
        c.args(args)
            .env_clear()
            .env("HOME", &self.home)
            .env("USER", &self.user)
            .env("LOGNAME", &self.user)
            .env(
                "PATH",
                std::env::var("PATH")
                    .unwrap_or_else(|_| crate::daemon_spec::DEFAULT_PATH.to_owned()),
            )
            .current_dir(&self.home)
            .kill_on_drop(true);
        c
    }
}

/// The relay thread; dropping it stops the thread at once: its socket closes and that socket's chats end (a
/// rebind must not leave the old machine's socket taking chats). [`Relay::detach`] stops it without ending them.
pub struct Relay {
    stop: watch::Sender<bool>,
    resumed: watch::Sender<u64>,
    /// Set by [`Relay::detach`] before the stop: the chats' turns run on in acpmux.
    detached: Arc<AtomicBool>,
}

impl Drop for Relay {
    fn drop(&mut self) {
        self.stop.send_replace(true);
    }
}

/// Resolves once `stop` is set or its `Relay` is gone.
async fn stopped(stop: &mut watch::Receiver<bool>) {
    let _ = stop.wait_for(|s| *s).await;
}

/// Runs `work` unless `stop` comes first, which drops it (and so a socket and its chats) at once.
async fn or_stop<T>(stop: &mut watch::Receiver<bool>, work: impl Future<Output = T>) -> Option<T> {
    tokio::select! {
        biased;
        () = stopped(stop) => None,
        out = work => Some(out),
    }
}

/// Whether Tokio can see this thread's children exit. The agent blocks SIGCHLD for its signalfd and this thread
/// inherits that mask, so an exit reaches Tokio only through a pidfd (Linux 5.3 on). Unblocking SIGCHLD here
/// instead would take exits from the agent, which reaps its own jobs only when its signalfd reads one.
fn child_waits_work() -> bool {
    #[cfg(target_os = "linux")]
    {
        // SAFETY: pidfd_open(pid, 0) returns a new descriptor or -1; a descriptor is closed at once.
        let fd = unsafe { libc::syscall(libc::SYS_pidfd_open, libc::getpid(), 0) };
        if fd < 0 {
            return false;
        }
        // SAFETY: `fd` is the descriptor pidfd_open just returned, owned by nothing else.
        unsafe { libc::close(fd as libc::c_int) };
    }
    true
}

impl Relay {
    pub fn spawn<H: Http + Send + 'static>(
        client: CloudClient<H>,
        runner: Runner,
        now_wall_ms: fn() -> u64,
        log: fn(&str),
    ) -> std::io::Result<Relay> {
        let (stop, stopping) = watch::channel(false);
        let (resumed, resumes) = watch::channel(0);
        let detached = Arc::new(AtomicBool::new(false));
        let owned = detached.clone();
        std::thread::Builder::new()
            .name("cmux-host-relay".to_owned())
            .spawn(move || run(client, runner, now_wall_ms, log, stopping, resumes, owned))?;
        Ok(Relay { stop, resumed, detached })
    }

    /// The machine woke from a pause (`HostEvent::Resumed`): the socket is dropped and dialed again at once, its
    /// chats carried on, and the bearer minted on a fresh HTTPS connection.
    pub fn resumed(&self) {
        self.resumed.send_modify(|n| *n = n.wrapping_add(1));
    }

    /// Stops the thread as cmux-host shuts down (a restart, an update): the socket closes and the chats' `acp send`
    /// clients end, but their turns run on in acpmux, which owns them; the next cmux-host reattaches when the
    /// platform sends a chat again. Only a `cancel` or a revocation (dropping the Relay) ends a turn.
    pub fn detach(self) {
        self.detached.store(true, Ordering::SeqCst);
    }
}

/// How the relay reaches a socket: a fresh bearer, then [`serve`] until the socket ends. Tests dial a local one.
trait Dial {
    /// The next bearer goes on a fresh HTTPS connection: after a pause the pooled one is stale.
    fn reset_transport(&mut self);
    /// One socket, until it ends; `None` once `stop` came first.
    fn serve(
        &mut self,
        rt: &tokio::runtime::Runtime,
        stop: &mut watch::Receiver<bool>,
        link: &mut Link,
        resumes: &mut watch::Receiver<u64>,
        seen: u64,
    ) -> Option<Result<Ended, String>>;
}

/// The platform's `MachineRelay`, as this machine's VM install.
struct Platform<H: Http> {
    client: CloudClient<H>,
    url: String,
    runner: Runner,
    now_wall_ms: fn() -> u64,
    /// The machine's address changes ([`cmux_server::cloud_http::network_watch`]): one during a dial ends it.
    network: watch::Receiver<u64>,
}

impl<H: Http> Dial for Platform<H> {
    fn reset_transport(&mut self) {
        self.client.reset_transport();
    }

    fn serve(
        &mut self,
        rt: &tokio::runtime::Runtime,
        stop: &mut watch::Receiver<bool>,
        link: &mut Link,
        resumes: &mut watch::Receiver<u64>,
        seen: u64,
    ) -> Option<Result<Ended, String>> {
        let changes = *self.network.borrow();
        match self.client.token((self.now_wall_ms)()) {
            Ok(token) => {
                let dial =
                    Dialing { url: &self.url, token: &token, network: &mut self.network, changes };
                let serving = serve(dial, &self.runner, link, resumes, seen, self.now_wall_ms);
                rt.block_on(or_stop(stop, serving))
            }
            Err(e) => Some(Err(format!("token: {e}"))),
        }
    }
}

fn run<H: Http>(
    client: CloudClient<H>,
    runner: Runner,
    now_wall_ms: fn() -> u64,
    log: fn(&str),
    mut stop: watch::Receiver<bool>,
    mut resumes: watch::Receiver<u64>,
    detached: Arc<AtomicBool>,
) {
    if !child_waits_work() {
        return log(
            "relay: no pidfd_open on this kernel, so a chat's process exit could never be seen; relay off",
        );
    }
    let rt = match tokio::runtime::Builder::new_current_thread().enable_all().build() {
        Ok(rt) => rt,
        Err(e) => return log(&format!("relay: runtime: {e}")),
    };
    let bound = client.bound().clone();
    let Some(url) = relay_url(bound.env.platform_origin(), &bound.machine) else {
        return log("relay: no relay URL for this machine");
    };
    let network = cmux_server::cloud_http::network_watch();
    let mut platform = Platform { client, url, runner, now_wall_ms, network: network.clone() };
    relay_loop(&rt, &mut platform, log, &mut stop, &mut resumes, &network, detached);
    // Dropping the runtime drops every chat task left, which kills its acpmux children (kill_on_drop).
}

/// Dials, serves and dials again until `stop`.
fn relay_loop(
    rt: &tokio::runtime::Runtime,
    dial: &mut impl Dial,
    log: fn(&str),
    stop: &mut watch::Receiver<bool>,
    resumes: &mut watch::Receiver<u64>,
    network: &watch::Receiver<u64>,
    detached: Arc<AtomicBool>,
) {
    let mut backoff = FIRST_BACKOFF;
    let mut last_error = String::new();
    let mut seen = *resumes.borrow();
    // The chats outlive every socket: each end leaves them running, and the next socket carries their events.
    let mut link = Link::new(detached);
    while !*stop.borrow() {
        // A resume while no socket was up: the pooled HTTPS connection is as stale as the socket was.
        if *resumes.borrow() != seen {
            seen = *resumes.borrow();
            dial.reset_transport();
        }
        let changes = *network.borrow();
        let Some(outcome) = dial.serve(rt, stop, &mut link, resumes, seen) else { break };
        match outcome {
            Ok(Ended::Resumed) => {
                log("relay: the machine resumed; dialing again");
                seen = *resumes.borrow();
                dial.reset_transport();
                backoff = FIRST_BACKOFF;
                continue;
            }
            // A socket that was up resets the backoff.
            Ok(Ended::Dropped) => backoff = FIRST_BACKOFF,
            Err(e) => {
                if e != last_error {
                    log(&format!("relay: {e}"));
                    last_error = e;
                }
                // The machine's addresses changed during the attempt (a fresh machine's network attach lands about
                // a second after its bind) and failed it: the next one goes at once, on a fresh connection.
                if *network.borrow() != changes {
                    backoff = FIRST_BACKOFF;
                    continue;
                }
                pause(rt, stop, resumes, seen, backoff);
                backoff = (backoff * 2).min(MAX_BACKOFF);
                continue;
            }
        }
        pause(rt, stop, resumes, seen, backoff);
    }
    // `link` goes here, aborting its chats; their tasks are dropped with the runtime.
}

/// Waits out `backoff` on the relay thread's own runtime, unless `stop` or a resume past `seen` comes first. The
/// timer is made inside the runtime: this thread is in none, and a `Sleep` made here panics, which ended the relay
/// for good.
fn pause(
    rt: &tokio::runtime::Runtime,
    stop: &mut watch::Receiver<bool>,
    resumes: &mut watch::Receiver<u64>,
    seen: u64,
    backoff: Duration,
) {
    rt.block_on(async {
        or_stop(stop, async {
            tokio::select! {
                () = tokio::time::sleep(backoff) => {}
                Ok(_) = resumes.wait_for(|n| *n != seen) => {}
            }
        })
        .await;
    });
}

/// The running chats; dropping them aborts them, which kills their acpmux children (kill_on_drop) and cancels their
/// turns unless the Relay was detached ([`CancelTurn`]).
#[derive(Default)]
struct Chats(HashMap<String, tokio::task::AbortHandle>);

impl Drop for Chats {
    fn drop(&mut self) {
        for h in self.0.values() {
            h.abort();
        }
    }
}

/// The relay's chats and the frames they queued, for whichever socket is up: they outlive every socket.
struct Link {
    chats: Chats,
    tx: mpsc::Sender<String>,
    rx: mpsc::Receiver<String>,
    /// The Relay's [`Relay::detach`] mark, read when a chat is dropped.
    detached: Arc<AtomicBool>,
}

impl Link {
    fn new(detached: Arc<AtomicBool>) -> Link {
        // Bounded: a slow socket holds the chats' readers back (and so acpmux's output) instead of queueing
        // without end.
        let (tx, rx) = up_queue();
        Link { chats: Chats::default(), tx, rx, detached }
    }
}

impl Default for Link {
    fn default() -> Link {
        Link::new(Arc::default())
    }
}

/// How a socket that was up ended.
#[derive(Debug, PartialEq, Eq)]
enum Ended {
    Dropped,
    /// The machine woke from a pause; its chats go on to the next socket.
    Resumed,
}

/// Whether the wall clock leapt past [`DEAD_AFTER`] between two ping ticks: the machine was paused (a missed
/// `Resumed`), since this thread's own clock does not run through a pause.
fn slept_through(last_wall_ms: u64, now_wall_ms: u64) -> bool {
    now_wall_ms.saturating_sub(last_wall_ms) > DEAD_AFTER.as_millis() as u64
}

/// Where and how one connection dials: the relay URL, the bearer, and the address-change count it started at.
struct Dialing<'a> {
    url: &'a str,
    token: &'a str,
    network: &'a mut watch::Receiver<u64>,
    changes: u64,
}

/// One connection, until it drops, the machine resumes (a resume past `seen`) or `link` ends. A change of the
/// machine's addresses during the dial ends it at once: the connection was opened on the old ones and would hang to
/// [`CONNECT_TIMEOUT`] (the caller dials again at once when the count moved).
async fn serve(
    dial: Dialing<'_>,
    runner: &Runner,
    link: &mut Link,
    resumes: &mut watch::Receiver<u64>,
    seen: u64,
    now_wall_ms: fn() -> u64,
) -> Result<Ended, String> {
    let Dialing { url, token, network, changes } = dial;
    let mut request = url.into_client_request().map_err(|e| format!("request: {e}"))?;
    let bearer =
        HeaderValue::from_str(&format!("Bearer {token}")).map_err(|_| "bearer".to_owned())?;
    request.headers_mut().insert("authorization", bearer);
    let connect = tokio::time::timeout(CONNECT_TIMEOUT, tokio_tungstenite::connect_async(request));
    let connected = tokio::select! {
        connected = connect => connected,
        Ok(_) = network.wait_for(|n| *n != changes) => {
            return Err("connect: the machine's addresses changed".to_owned());
        }
    };
    let (ws, _) = connected.map_err(|_| "connect timed out".to_owned())?.map_err(|e| match e {
        tokio_tungstenite::tungstenite::Error::Http(r) => {
            format!("refused: HTTP {}", r.status())
        }
        e => format!("connect: {e}"),
    })?;
    let (mut sink, mut stream) = ws.split();
    let Link { chats, tx, rx, detached } = link;
    let mut ping = tokio::time::interval(PING_EVERY);
    let mut heard = tokio::time::Instant::now();
    let mut ticked_wall = now_wall_ms();
    loop {
        tokio::select! {
            // Dropping the socket without a close: after a pause it is likely dead, and a close could hang on it.
            Ok(_) = resumes.wait_for(|n| *n != seen) => return Ok(Ended::Resumed),
            msg = stream.next() => {
                let Some(Ok(msg)) = msg else { return Ok(Ended::Dropped) };
                heard = tokio::time::Instant::now();
                let Message::Text(text) = msg else { continue };
                match parse_down(text.as_str()) {
                    Down::Chat(chat) => {
                        chats.0.retain(|_, h| !h.is_finished());
                        // One task per chat id. The platform sends a chat again when its socket dropped mid-turn: the
                        // running chat answers it, on this socket, and the prompt never runs twice.
                        if chats.0.contains_key(&chat.id) {
                            continue;
                        }
                        if chats.0.len() >= MAX_CHATS {
                            let _ = tx.try_send(up(&chat.id, json!({"kind": "error", "code": "cloud.relay.busy", "message": "too many chats at once"})));
                            continue;
                        }
                        let id = chat.id.clone();
                        let running = Running::start(&RUNNING_CHATS);
                        let chat = run_chat(chat, runner.clone(), tx.clone(), detached.clone());
                        let task = tokio::spawn(async move {
                            let _running = running;
                            chat.await;
                        });
                        chats.0.insert(id, task.abort_handle());
                    }
                    Down::Cancel(id) => {
                        // Aborting drops the child, which kills it (kill_on_drop).
                        if let Some(h) = chats.0.remove(&id) { h.abort(); }
                    }
                    Down::Other => {}
                }
            }
            Some(frame) = rx.recv() => {
                if sink.send(Message::text(frame)).await.is_err() { return Ok(Ended::Dropped) }
            }
            _ = ping.tick() => {
                let wall = now_wall_ms();
                if slept_through(ticked_wall, wall) {
                    return Ok(Ended::Resumed);
                }
                ticked_wall = wall;
                if heard.elapsed() > DEAD_AFTER {
                    let _ = sink.close().await;
                    return Ok(Ended::Dropped);
                }
                if sink.send(Message::text(PING)).await.is_err() {
                    return Ok(Ended::Dropped);
                }
            }
        }
    }
}

/// How much of `acp send`'s output and errors a chat keeps; the rest is read and dropped, so the child never
/// blocks on a full pipe.
pub const MAX_SEND_OUT: u64 = 4 * 1024 * 1024;
const MAX_SEND_ERR: u64 = 64 * 1024;

/// Reads `r` to its end, keeping its first `cap` bytes; `true` when there was more.
async fn read_capped(r: impl tokio::io::AsyncRead + Unpin, cap: u64) -> (String, bool) {
    let mut kept = Vec::new();
    let mut head = r.take(cap);
    let _ = head.read_to_end(&mut kept).await;
    let more =
        tokio::io::copy(&mut head.into_inner(), &mut tokio::io::sink()).await.unwrap_or(0) > 0;
    (String::from_utf8_lossy(&kept).into_owned(), more)
}

/// Ends the session's turn in the acpmux daemon when the chat is dropped before the turn ended (a `cancel`, a
/// rebind): killing `acp send` only stops the client, and the daemon would run the turn on. A detached Relay (a
/// cmux-host shutdown) cancels nothing: the turn runs on, and the next cmux-host reattaches to it.
struct CancelTurn {
    runner: Runner,
    session: String,
    armed: bool,
    /// The Relay's [`Relay::detach`] mark.
    detached: Arc<AtomicBool>,
}

impl Drop for CancelTurn {
    fn drop(&mut self) {
        if !self.armed || self.detached.load(Ordering::SeqCst) {
            return;
        }
        // A plain process, not a task: this runs while the chat's task or the whole runtime is being dropped.
        let mut cancel = self.runner.command(&cancel_args(&self.session));
        let cancel =
            cancel.as_std_mut().stdin(Stdio::null()).stdout(Stdio::null()).stderr(Stdio::null());
        if let Ok(mut child) = cancel.spawn() {
            let _ = std::thread::Builder::new()
                .name("cmux-host-relay-cancel".to_owned())
                .spawn(move || child.wait());
        }
    }
}

/// How many frames may wait for the socket; past it, every chat's events wait their turn.
const UP_QUEUE: usize = 256;

/// The queue of frames going up one socket.
fn up_queue() -> (mpsc::Sender<String>, mpsc::Receiver<String>) {
    mpsc::channel(UP_QUEUE)
}

/// Waits `grace` for a chat's event reader to end, else stops it; either way it is gone on return, so nothing
/// it read reaches the socket after the chat's `done`.
async fn end_reader(mut reader: tokio::task::JoinHandle<()>, grace: Duration) {
    if tokio::time::timeout(grace, &mut reader).await.is_err() {
        reader.abort();
        let _ = reader.await;
    }
}

async fn run_chat(chat: Chat, runner: Runner, tx: mpsc::Sender<String>, detached: Arc<AtomicBool>) {
    let send = async |event: Value| {
        let _ = tx.send(up(&chat.id, event)).await;
    };
    let home = runner.home.to_string_lossy().into_owned();
    // `reattached`: the chat's own session was there already (`new --reuse` said `reused`), so this chat came again
    // after a drop or a restart, and its prompt id names the turn that ran.
    let (session, reattached) = match &chat.session {
        Some(s) => (s.clone(), false),
        None => {
            let out = runner.command(&new_args(&chat, &home)).stdin(Stdio::null()).output().await;
            match out {
                Ok(out) if out.status.success() => {
                    let stdout = String::from_utf8_lossy(&out.stdout);
                    let session = created_session(&stdout).unwrap_or_else(|| session_name(&chat));
                    (session, reused_session(&stdout))
                }
                Ok(out) => {
                    // The create's own exit: a `no_session` or a refused permission keeps its code.
                    let err = String::from_utf8_lossy(&out.stderr).into_owned();
                    return send(final_event(out.status.code(), "", &err)).await;
                }
                Err(e) => return send(final_event(None, "", &format!("acpmux: {e}"))).await,
            }
        }
    };
    send(json!({"kind": "started", "session": session, "prompt_id": chat.prompt_id})).await;
    // The turn's events, from before the prompt goes in.
    let tail = runner
        .command(&tail_args(&session))
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn();
    let mut tail = tail.ok();
    let events = tail.as_mut().and_then(|t| t.stdout.take()).map(|out| {
        let tx = tx.clone();
        let id = chat.id.clone();
        tokio::spawn(async move {
            let mut lines = BufReader::new(out).lines();
            while let Ok(Some(line)) = lines.next_line().await {
                for e in events_of(&line) {
                    if tx.send(up(&id, e)).await.is_err() {
                        return;
                    }
                }
            }
        })
    });
    let child = runner
        .command(&send_args(&chat, &session))
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn();
    let mut child = match child {
        Ok(c) => c,
        Err(e) => return send(final_event(None, "", &format!("acpmux: {e}"))).await,
    };
    let mut turn =
        CancelTurn { runner: runner.clone(), session: session.clone(), armed: true, detached };
    if let Some(mut stdin) = child.stdin.take() {
        let prompt = chat.prompt.clone();
        tokio::spawn(async move {
            let _ = stdin.write_all(prompt.as_bytes()).await;
            let _ = stdin.shutdown().await;
        });
    }
    let mut stderr = child.stderr.take();
    let err_task = tokio::spawn(async move {
        match stderr.take() {
            Some(e) => read_capped(e, MAX_SEND_ERR).await.0,
            None => String::new(),
        }
    });
    let (out, cut) = match child.stdout.take() {
        Some(stdout) => read_capped(stdout, MAX_SEND_OUT).await,
        None => (String::new(), false),
    };
    let exit = child.wait().await.ok().and_then(|s| s.code());
    // The turn ended on its own: nothing to cancel.
    turn.armed = false;
    let err = err_task.await.unwrap_or_default();
    // The turn's last events reach `tail` just after `send` returns: a moment for them, then it stops.
    if let Some(events) = events {
        end_reader(events, TAIL_GRACE).await;
    }
    if let Some(mut tail) = tail {
        let _ = tail.kill().await;
    }
    let mut done = final_event_of(exit, &out, cut, &err);
    // A reattached chat: `send` answered the first run's outcome, and that run's reply went to its own client, so the
    // turn's reply comes from the session, which holds only this chat. A new turn with no reply stays empty.
    if reattached
        && done.get("kind").and_then(Value::as_str) == Some("done")
        && done.get("reply_cut").is_none()
        && done.get("reply").and_then(Value::as_str).is_none_or(str::is_empty)
    {
        let last = runner.command(&last_args(&session)).stdin(Stdio::null()).output().await;
        if let (Some(reply), Some(o)) = (
            last.ok().and_then(|l| last_reply(&String::from_utf8_lossy(&l.stdout))),
            done.as_object_mut(),
        ) {
            o.insert("reply".to_owned(), json!(reply));
        }
    }
    send(done).await;
}

/// How long `tail` may go on after the turn ended, for its last events.
const TAIL_GRACE: Duration = Duration::from_millis(300);

#[cfg(test)]
#[path = "relay_tests.rs"]
mod tests;

#[cfg(test)]
#[path = "relay_resume_tests.rs"]
mod resume_tests;

#[cfg(test)]
#[path = "relay_observer_tests.rs"]
mod observer_tests;
