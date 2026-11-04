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
//! The thread reconnects with backoff (1 s doubling to 30 s), minting a fresh
//! bearer each time, and pings every 20 s; a socket with no answer for 60 s
//! is dropped and dialed again.

use std::collections::HashMap;
use std::path::PathBuf;
use std::process::Stdio;
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
const CONNECT_TIMEOUT: Duration = Duration::from_secs(20);
/// Chats run at once; the platform holds at most 8 per machine.
const MAX_CHATS: usize = 8;
const MAX_PROMPT_BYTES: usize = 256 * 1024;

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
    // acpmux's exit codes (cli/errors.rs `Code`).
    let code = match exit {
        Some(3) => "chat.timeout",
        Some(4) => "chat.no_session",
        Some(5) => "chat.permission_denied",
        _ => "chat.failed",
    };
    let line = stderr.lines().rev().find(|l| !l.trim().is_empty()).unwrap_or("").trim();
    json!({"kind": "error", "code": code, "message": line.chars().take(300).collect::<String>()})
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
/// rebind must not leave the old machine's socket taking chats).
pub struct Relay {
    stop: watch::Sender<bool>,
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

impl Relay {
    pub fn spawn<H: Http + Send + 'static>(
        client: CloudClient<H>,
        runner: Runner,
        now_wall_ms: fn() -> u64,
        log: fn(&str),
    ) -> std::io::Result<Relay> {
        let (stop, stopping) = watch::channel(false);
        std::thread::Builder::new()
            .name("cmux-host-relay".to_owned())
            .spawn(move || run(client, runner, now_wall_ms, log, stopping))?;
        Ok(Relay { stop })
    }
}

fn run<H: Http>(
    mut client: CloudClient<H>,
    runner: Runner,
    now_wall_ms: fn() -> u64,
    log: fn(&str),
    mut stop: watch::Receiver<bool>,
) {
    let rt = match tokio::runtime::Builder::new_current_thread().enable_all().build() {
        Ok(rt) => rt,
        Err(e) => return log(&format!("relay: runtime: {e}")),
    };
    let bound = client.bound().clone();
    let Some(url) = relay_url(bound.env.platform_origin(), &bound.machine) else {
        return log("relay: no relay URL for this machine");
    };
    let mut backoff = Duration::from_secs(1);
    let mut last_error = String::new();
    while !*stop.borrow() {
        let outcome = match client.token(now_wall_ms()) {
            Ok(token) => match rt.block_on(or_stop(&mut stop, serve(&url, &token, &runner))) {
                Some(outcome) => outcome,
                None => break,
            },
            Err(e) => Err(format!("token: {e}")),
        };
        match outcome {
            // A socket that was up resets the backoff.
            Ok(()) => backoff = Duration::from_secs(1),
            Err(e) => {
                if e != last_error {
                    log(&format!("relay: {e}"));
                    last_error = e;
                }
                backoff = (backoff * 2).min(Duration::from_secs(30));
            }
        }
        rt.block_on(or_stop(&mut stop, tokio::time::sleep(backoff)));
    }
    // Dropping the runtime drops every chat task left, which kills its acpmux children (kill_on_drop).
}

/// One connection, until it drops. `Ok` once it was up.
/// The running chats of one socket; dropping it aborts them, which kills their acpmux children (kill_on_drop).
#[derive(Default)]
struct Chats(HashMap<String, tokio::task::AbortHandle>);

impl Drop for Chats {
    fn drop(&mut self) {
        for h in self.0.values() {
            h.abort();
        }
    }
}

async fn serve(url: &str, token: &str, runner: &Runner) -> Result<(), String> {
    let mut request = url.into_client_request().map_err(|e| format!("request: {e}"))?;
    let bearer =
        HeaderValue::from_str(&format!("Bearer {token}")).map_err(|_| "bearer".to_owned())?;
    request.headers_mut().insert("authorization", bearer);
    let (ws, _) = tokio::time::timeout(CONNECT_TIMEOUT, tokio_tungstenite::connect_async(request))
        .await
        .map_err(|_| "connect timed out".to_owned())?
        .map_err(|e| match e {
            tokio_tungstenite::tungstenite::Error::Http(r) => {
                format!("refused: HTTP {}", r.status())
            }
            e => format!("connect: {e}"),
        })?;
    let (mut sink, mut stream) = ws.split();
    // Bounded: a slow socket holds the chats' readers back (and so acpmux's output) instead of queueing without end.
    let (tx, mut rx) = up_queue();
    // Every return ends the chats of this socket: the platform ended their streams with it (host_gone), and a
    // cancel for them can only come down this socket.
    let mut chats = Chats::default();
    let mut ping = tokio::time::interval(PING_EVERY);
    let mut heard = tokio::time::Instant::now();
    loop {
        tokio::select! {
            msg = stream.next() => {
                let Some(Ok(msg)) = msg else { return Ok(()) };
                heard = tokio::time::Instant::now();
                let Message::Text(text) = msg else { continue };
                match parse_down(text.as_str()) {
                    Down::Chat(chat) => {
                        chats.0.retain(|_, h| !h.is_finished());
                        // One task per chat id: a repeated id (a retry) would run the prompt twice.
                        if chats.0.contains_key(&chat.id) {
                            let _ = tx.try_send(up(&chat.id, json!({"kind": "error", "code": "cloud.relay.duplicate", "message": "a chat with this id is already running"})));
                            continue;
                        }
                        if chats.0.len() >= MAX_CHATS {
                            let _ = tx.try_send(up(&chat.id, json!({"kind": "error", "code": "cloud.relay.busy", "message": "too many chats at once"})));
                            continue;
                        }
                        let id = chat.id.clone();
                        let task = tokio::spawn(run_chat(chat, runner.clone(), tx.clone()));
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
                if sink.send(Message::text(frame)).await.is_err() { return Ok(()) }
            }
            _ = ping.tick() => {
                if heard.elapsed() > DEAD_AFTER {
                    let _ = sink.close().await;
                    return Ok(());
                }
                if sink.send(Message::text(json!({"v": 1, "t": "ping"}).to_string())).await.is_err() {
                    return Ok(());
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

/// Ends the session's turn in the acpmux daemon when the chat is dropped before the turn ended (a `cancel`, the
/// socket gone, a rebind): killing `acp send` only stops the client, and the daemon would run the turn on.
struct CancelTurn {
    runner: Runner,
    session: String,
    armed: bool,
}

impl Drop for CancelTurn {
    fn drop(&mut self) {
        if !self.armed {
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

async fn run_chat(chat: Chat, runner: Runner, tx: mpsc::Sender<String>) {
    let send = async |event: Value| {
        let _ = tx.send(up(&chat.id, event)).await;
    };
    let home = runner.home.to_string_lossy().into_owned();
    let session = match &chat.session {
        Some(s) => s.clone(),
        None => {
            let out = runner.command(&new_args(&chat, &home)).stdin(Stdio::null()).output().await;
            match out {
                Ok(out) if out.status.success() => {
                    created_session(&String::from_utf8_lossy(&out.stdout))
                        .unwrap_or_else(|| session_name(&chat))
                }
                Ok(out) => {
                    let err = String::from_utf8_lossy(&out.stderr).into_owned();
                    return send(final_event(Some(1), "", &err)).await;
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
    let mut turn = CancelTurn { runner: runner.clone(), session: session.clone(), armed: true };
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
    send(final_event_of(exit, &out, cut, &err)).await;
}

/// How long `tail` may go on after the turn ended, for its last events.
const TAIL_GRACE: Duration = Duration::from_millis(300);

#[cfg(test)]
#[path = "relay_tests.rs"]
mod tests;
