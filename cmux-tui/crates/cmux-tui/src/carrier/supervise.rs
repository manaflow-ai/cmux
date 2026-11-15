//! `cmux carrier supervise --machine <vm_id> --socket <path>`: one Cloud
//! session's `cmux carrier serve` lifecycle, for the app. The app starts one
//! per session and talks to it in JSON lines; this process runs the serve
//! child through [`ServeMachine`]: launch, token refresh, stop, park and the
//! account fence, so a late result never acts on a child or a session that
//! has moved on.
//!
//! Contract:
//! - stdin, one JSON object per line, from the app:
//!   `{"connect":W,"keep_refusal":bool}` asks for the serving socket (waiter
//!   `W`, unique per process); `{"park":true}` ends the child while the
//!   machine is paused (the next connect starts another); `{"stop":true}`
//!   and `{"account_ended":true}` end the serve for good (later connects
//!   resume `closed`); `{"token":R,"env":{…}}` answers `read_token` `R` with
//!   the child's environment (the access token under
//!   `CMUX_CLOUD_ACCESS_TOKEN`), `{"token":R,"error":E}` with why it has
//!   none, `{"token":R,"fenced":true}` with the account having ended. Any
//!   other line is skipped. The end of stdin is a stop.
//! - stderr, one JSON object per line, to the app: `{"read_token":R}`;
//!   `{"resume":[W…],"socket":PATH}` or `{"resume":[W…],"error":E}`;
//!   `{"publish":"owner"|"team"|"unknown"}` for each connection's grant
//!   answer; and `{"state":{"refusal":E|null,"answer":…|null}}` whenever
//!   either changes, before the lines of the same step. `E` is
//!   `{"kind":…}` with the app's link error fields ([`supervise_wire`]).
//!   `{"log":TEXT}` names each link step (a connect, park or stop, a child's
//!   start and exit, the socket ready or a connect's failure, a refusal, an
//!   unanswered token read) in one bounded line with no credential
//!   ([`supervise_wire::log_line`]); the app writes it to its unified log,
//!   category `cloud.carrier`, at a level release builds keep.
//! - The serve child is this executable's `carrier serve --machine --socket`,
//!   spawned with this process's environment plus the app's `env`. Its stdin
//!   gets the token lines; its stderr lines become the machine's events; its
//!   ready line's socket passes [`serve_policy`] first.
//! - Two supervisors of one socket (a session replaced while its child
//!   still exits) take turns: a launch holds `<socket>.supervise` (a file
//!   lock) from its claim to its child's exit, and waits for it at most
//!   [`LEASE_WAIT`], after which it launches anyway and serve's own refusal
//!   says why.
//! - A child whose stdin closed gets SIGTERM after [`STOP_GRACE`], SIGKILL
//!   [`KILL_AFTER`] later. It exits 0 once the serve stopped and every child
//!   it started exited.

use std::collections::{HashMap, VecDeque};
use std::fs::OpenOptions;
use std::os::fd::OwnedFd;
use std::os::unix::fs::OpenOptionsExt as _;
use std::os::unix::process::ExitStatusExt as _;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use cmux_file_lock::{FileLock, Kind};
use cmux_scope::Scope;
use tokio::io::AsyncBufReadExt as _;
use tokio::net::unix::pipe;
use tokio::sync::{mpsc, oneshot};

use super::serve_machine::{
    Caller, ChildId, Effect, Env, Epoch, Event, LinkError, ReadId, ServeMachine, State, TokenRead,
};
use super::supervise_wire::{self as wire, AppLine};
use super::{contract, serve_policy};

/// `carrier serve` binds at once and dials only per connection, so its
/// ready line comes fast.
pub(super) const READY_DEADLINE: Duration = Duration::from_secs(15);
/// How long a child has, after its stdin closed, before SIGTERM.
pub(super) const STOP_GRACE: Duration = Duration::from_secs(5);
/// How long a child has after SIGTERM before SIGKILL.
pub(super) const KILL_AFTER: Duration = Duration::from_secs(5);
/// The longest a launch waits for another supervisor's child to give up
/// the socket: its stop grace and SIGTERM.
pub(super) const LEASE_WAIT: Duration = Duration::from_secs(10);
/// How long the app has to answer a `read_token` line. The launch waits
/// for that answer with the socket's lease held and every connect joins it,
/// so an answer that never comes (lost, or an app read that never returns)
/// would wedge the session's link for good (2026-11-15: every Cloud chat
/// start waited 180 s on such a read). Past it the read fails, the connects
/// resume with that error and the next connect reads again. The app answers
/// within its own 75 s.
pub(super) const TOKEN_READ_DEADLINE: Duration = Duration::from_secs(90);
/// How long a token line may take to go out.
const WRITE_LIMIT: Duration = Duration::from_secs(5);
/// How long stderr is still read after the child exited (a process it
/// started may hold the pipe).
const STDERR_DRAIN: Duration = Duration::from_secs(1);
/// The stderr lines kept for a child that never wrote a line we read.
const TAIL_LINES: usize = 20;
const USAGE: &str = "usage: cmux carrier supervise --machine vm_… --socket /absolute/path";

/// What one supervisor runs: the serve child's argv, its socket, and the
/// waits (tests shorten them and pass a stand-in child).
pub(super) struct Config {
    pub socket: String,
    pub program: PathBuf,
    pub args: Vec<String>,
    /// The file whose lock is the socket's lease.
    pub lease: PathBuf,
    pub ready_deadline: Duration,
    pub stop_grace: Duration,
    pub kill_after: Duration,
    pub lease_wait: Duration,
    /// How long a `read_token` line waits for the app's answer.
    pub token_read_deadline: Duration,
    pub refresh_delay: fn(&str) -> Duration,
    pub check: fn(&str) -> Result<(), LinkError>,
}

impl Config {
    /// `exe carrier serve --machine machine --socket socket`, with the
    /// production waits and checks.
    pub(super) fn serve(exe: PathBuf, machine: &str, socket: &str) -> Self {
        Self {
            socket: socket.to_owned(),
            program: exe,
            args: ["carrier", "serve", "--machine", machine, "--socket", socket]
                .map(str::to_owned)
                .to_vec(),
            lease: PathBuf::from(format!("{socket}.supervise")),
            ready_deadline: READY_DEADLINE,
            stop_grace: STOP_GRACE,
            kill_after: KILL_AFTER,
            lease_wait: LEASE_WAIT,
            token_read_deadline: TOKEN_READ_DEADLINE,
            refresh_delay: wire::refresh_delay,
            check: serve_policy::check,
        }
    }
}

/// Where the supervisor's lines go.
pub(super) type Out = Arc<dyn Fn(String) + Send + Sync>;

/// `supervise --machine vm_… --socket PATH`, each once.
pub(super) fn parse(args: &[String]) -> Option<(String, String)> {
    let (verb, rest) = args.split_first()?;
    if verb != "supervise" {
        return None;
    }
    let (mut machine, mut socket) = (None, None);
    let mut words = rest.iter();
    while let Some(flag) = words.next() {
        let value = words.next()?.clone();
        let slot = match flag.as_str() {
            "--machine" => &mut machine,
            "--socket" => &mut socket,
            _ => return None,
        };
        if slot.replace(value).is_some() {
            return None;
        }
    }
    let machine = machine.filter(|id| contract::valid_machine(id))?;
    let socket = socket.filter(|path| {
        let path = Path::new(path);
        path.is_absolute() && cmux_unix_socket::fits(path)
    })?;
    Some((machine, socket))
}

/// `cmux carrier supervise …`: the exit code.
pub(super) fn run(args: &[String]) -> i32 {
    let Some((machine, socket)) = parse(args) else {
        return super::usage(USAGE);
    };
    let Ok(exe) = std::env::current_exe() else {
        return super::usage("cmux carrier supervise: this executable's path is unknown");
    };
    let runtime = match super::runtime() {
        Ok(runtime) => runtime,
        Err(code) => return code,
    };
    let config = Config::serve(exe, &machine, &socket);
    let code = runtime.block_on(async move {
        let (lines, app) = mpsc::unbounded_channel();
        let stdin = Scope::new("carrier supervise stdin");
        stdin.spawn_until_cancelled("app lines", async move {
            let mut input = tokio::io::BufReader::new(tokio::io::stdin()).lines();
            while let Ok(Some(line)) = input.next_line().await {
                if lines.send(line).is_err() {
                    return;
                }
            }
        });
        let out: Out = Arc::new(|line: String| super::reply(&format!("{line}\n")));
        let code = supervise(config, app, out).await;
        let _ = stdin.close(Duration::from_millis(100)).await;
        code
    });
    runtime.shutdown_timeout(super::STDIO_SHUTDOWN_TIMEOUT);
    code
}

/// Runs the serve for the app's lines on `app` (its end is a stop) until
/// the serve stopped and every child exited; 0.
pub(super) async fn supervise(
    config: Config,
    mut app: mpsc::UnboundedReceiver<String>,
    out: Out,
) -> i32 {
    let scope = Scope::new("carrier supervise");
    let (tx, mut rx) = mpsc::unbounded_channel();
    let lines = tx.clone();
    scope.spawn_until_cancelled("app lines", async move {
        while let Some(line) = app.recv().await {
            if lines.send(Msg::App(line)).is_err() {
                return;
            }
        }
        let _ = lines.send(Msg::AppEnded);
    });
    let mut supervisor = Supervisor::new(config, out, tx, scope);
    while let Some(msg) = rx.recv().await {
        supervisor.on(msg);
        if supervisor.done() {
            break;
        }
    }
    let Supervisor { scope, .. } = supervisor;
    let _ = scope.close(Duration::from_secs(2)).await;
    0
}

/// What the supervisor's loop reads.
enum Msg {
    App(String),
    AppEnded,
    Event(Event),
    /// A claim's lease: None when the wait ran out (the launch goes ahead).
    Claimed {
        epoch: Epoch,
        lease: Option<FileLock>,
    },
    ReadyTimer {
        generation: u64,
        epoch: Epoch,
    },
    RefreshTimer {
        generation: u64,
        epoch: Epoch,
    },
    /// A `read_token` line's deadline: the read fails when it is still unanswered.
    TokenReadDeadline(ReadId),
    Signal(ChildId, i32),
}

/// A child's pid, signalled only while it is unreaped: its waiter marks it
/// reaped under the same lock before the reap.
struct Reap {
    pid: libc::pid_t,
    reaped: Mutex<bool>,
}

impl Reap {
    fn signal(&self, signal: i32) {
        let reaped = self.reaped.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        if !*reaped && self.pid > 0 {
            // SAFETY: the child is unreaped (its waiter sets `reaped` under
            // this lock before it reaps), so `pid` is still this child's.
            unsafe { libc::kill(self.pid, signal) };
        }
    }
}

struct ChildSlot {
    stdin: Mutex<Option<Arc<pipe::Sender>>>,
    reap: Arc<Reap>,
    /// Its stop deadline and signal timers; dropped (cancelled) at its exit.
    timers: Vec<oneshot::Sender<()>>,
}

struct Supervisor {
    config: Arc<Config>,
    machine: ServeMachine,
    out: Out,
    tx: mpsc::UnboundedSender<Msg>,
    scope: Scope,
    children: HashMap<ChildId, ChildSlot>,
    /// Each unanswered `read_token` line: its launch's epoch, and its deadline (dropping it cancels the deadline).
    reads: HashMap<ReadId, (Epoch, oneshot::Sender<()>)>,
    /// The socket lease and the child that took it over (None: the launch
    /// that claimed it has not spawned yet).
    lease: Option<(FileLock, Option<ChildId>)>,
    ready: (u64, Option<oneshot::Sender<()>>),
    refresh: (u64, Option<oneshot::Sender<()>>),
    /// The refusal and answer the app last got.
    shown: (Option<LinkError>, Option<Caller>),
    queue: VecDeque<Event>,
}

impl Supervisor {
    fn new(config: Config, out: Out, tx: mpsc::UnboundedSender<Msg>, scope: Scope) -> Self {
        let machine = ServeMachine::new(&config.socket);
        let shown = (machine.refusal(), machine.answer());
        Self {
            config: Arc::new(config),
            machine,
            out,
            tx,
            scope,
            children: HashMap::new(),
            reads: HashMap::new(),
            lease: None,
            ready: (0, None),
            refresh: (0, None),
            shown,
            queue: VecDeque::new(),
        }
    }

    /// The serve stopped and no child it started still runs.
    fn done(&self) -> bool {
        matches!(self.machine.state(), State::Stopped(_)) && self.children.is_empty()
    }

    fn on(&mut self, msg: Msg) {
        match msg {
            Msg::App(text) => match wire::app_line(&text) {
                Some(AppLine::Connect { waiter, keep_refusal }) => {
                    self.note(&format!("connect {waiter}"));
                    self.dispatch(Event::Connect { waiter, keep_refusal });
                }
                Some(AppLine::Park) => {
                    self.note("park");
                    self.dispatch(Event::Park);
                }
                Some(AppLine::Stop) => {
                    self.note("stop");
                    self.dispatch(Event::Stop);
                }
                Some(AppLine::AccountEnded) => {
                    self.note("account ended: stop");
                    self.dispatch(Event::AccountEnded);
                }
                Some(AppLine::Token { read, result }) => {
                    if let Some((epoch, _deadline)) = self.reads.remove(&read) {
                        self.dispatch(Event::TokenRead { epoch, read, result });
                    }
                }
                None => {}
            },
            Msg::AppEnded => {
                self.note("the app's input ended: stop");
                self.dispatch(Event::Stop);
            }
            Msg::Event(event) => self.dispatch(event),
            Msg::Claimed { epoch, lease } => {
                // A claim the machine left behind gives its lease back here.
                if self.machine.is_claiming(epoch) {
                    if lease.is_none() {
                        let waited = self.config.lease_wait.as_secs();
                        self.note(&format!(
                            "another supervisor kept the socket past {waited} s: launching anyway"
                        ));
                    }
                    self.lease = lease.map(|lease| (lease, None));
                    self.dispatch(Event::SocketClaimed(epoch));
                }
            }
            Msg::ReadyTimer { generation, epoch } => {
                if generation == self.ready.0 {
                    self.dispatch(Event::ReadyDeadline(epoch));
                }
            }
            Msg::TokenReadDeadline(read) => {
                if let Some((epoch, _deadline)) = self.reads.remove(&read) {
                    let waited = self.config.token_read_deadline.as_secs();
                    self.note(&format!("token read {read} unanswered after {waited} s"));
                    let reason = "the app did not answer its access token read".to_owned();
                    let result = TokenRead::Failed(LinkError::HelperNotRunning { reason });
                    self.dispatch(Event::TokenRead { epoch, read, result });
                }
            }
            Msg::RefreshTimer { generation, epoch } => {
                if generation == self.refresh.0 {
                    self.dispatch(Event::RefreshDue(epoch));
                }
            }
            Msg::Signal(child, signal) => {
                if let Some(slot) = self.children.get(&child) {
                    slot.reap.signal(signal);
                }
            }
        }
    }

    /// Reduces `event`, and every event its effects queue, in order.
    fn dispatch(&mut self, event: Event) {
        self.queue.push_back(event);
        while let Some(event) = self.queue.pop_front() {
            let exited = match &event {
                Event::ChildExit { child, code } => {
                    self.note(&format!("serve child {child} exited with code {code}"));
                    Some(*child)
                }
                _ => None,
            };
            let effects = self.machine.reduce(event);
            self.show_state();
            for effect in effects {
                self.run(effect);
            }
            // A claim no child took over (the launch failed or stopped
            // before its spawn) goes back.
            if matches!(self.lease, Some((_, None))) && !self.machine.launching() {
                self.lease = None;
            }
            if let Some(child) = exited {
                self.children.remove(&child);
                if matches!(self.lease, Some((_, Some(owner))) if owner == child) {
                    self.lease = None;
                }
            }
        }
    }

    fn show_state(&mut self) {
        let now = (self.machine.refusal(), self.machine.answer());
        if now != self.shown {
            if now.0 != self.shown.0 {
                match &now.0 {
                    Some(refusal) => self.note(&format!("refused: {}", wire::error_json(refusal))),
                    None => self.note("refusal cleared"),
                }
            }
            if let Some(answer) = now.1
                && now.1 != self.shown.1
            {
                self.note(&format!("answer {}", answer.word()));
            }
            (self.out)(wire::state_line(now.0.as_ref(), now.1));
            self.shown = now;
        }
    }

    /// One link step's `log` line ([`wire::log_line`]).
    fn note(&self, text: &str) {
        (self.out)(wire::log_line(text));
    }

    fn run(&mut self, effect: Effect) {
        match effect {
            Effect::ClaimSocket(epoch) => self.claim(epoch),
            Effect::ReadToken(epoch, read) => {
                let deadline =
                    self.timer(self.config.token_read_deadline, Msg::TokenReadDeadline(read));
                self.reads.insert(read, (epoch, deadline));
                (self.out)(wire::read_token_line(read));
            }
            Effect::Spawn { child, env } => self.spawn(child, &env),
            // The app's fence comes as `account_ended`; nothing holds here.
            Effect::Hold(child) => self.queue.push_back(Event::HeldResult { child, held: true }),
            Effect::Release(_) => {}
            Effect::ArmReadyDeadline(epoch) => {
                let generation = self.ready.0.wrapping_add(1);
                let cancel =
                    self.timer(self.config.ready_deadline, Msg::ReadyTimer { generation, epoch });
                self.ready = (generation, Some(cancel));
            }
            Effect::CancelReadyDeadline => self.ready = (self.ready.0.wrapping_add(1), None),
            Effect::ArmRefresh(epoch, token) => {
                let generation = self.refresh.0.wrapping_add(1);
                let delay = (self.config.refresh_delay)(token.as_deref().unwrap_or_default());
                let cancel = self.timer(delay, Msg::RefreshTimer { generation, epoch });
                self.refresh = (generation, Some(cancel));
            }
            Effect::CancelRefresh => self.refresh = (self.refresh.0.wrapping_add(1), None),
            Effect::WriteToken { child, token } => self.write_token(child, token),
            Effect::CloseStdin(child) => {
                if let Some(slot) = self.children.get(&child) {
                    let mut stdin =
                        slot.stdin.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
                    *stdin = None;
                }
            }
            Effect::ArmStopDeadline(child) => {
                let after = self.config.stop_grace;
                self.child_timer(child, after, Msg::Event(Event::StopDeadline(child)));
            }
            Effect::Terminate(child) => self.terminate(child, Duration::ZERO),
            Effect::TerminateAfterGrace(child) => self.terminate(child, self.config.stop_grace),
            Effect::Resume(waiters, result) => {
                let connects =
                    waiters.iter().map(ToString::to_string).collect::<Vec<_>>().join(",");
                match &result {
                    _ if waiters.is_empty() => {}
                    Ok(_) => self.note(&format!("socket ready for connect {connects}")),
                    Err(error) => self
                        .note(&format!("connect {connects} failed: {}", wire::error_json(error))),
                }
                (self.out)(wire::resume_line(&waiters, &result));
            }
            Effect::Publish(caller) => (self.out)(wire::publish_line(caller)),
        }
    }

    /// Sends `msg` after `after` unless the returned sender drops first.
    fn timer(&self, after: Duration, msg: Msg) -> oneshot::Sender<()> {
        let (cancel, cancelled) = oneshot::channel::<()>();
        let tx = self.tx.clone();
        self.scope.spawn_until_cancelled("carrier supervise timer", async move {
            tokio::select! {
                () = tokio::time::sleep(after) => {
                    let _ = tx.send(msg);
                }
                _ = cancelled => {}
            }
        });
        cancel
    }

    fn child_timer(&mut self, child: ChildId, after: Duration, msg: Msg) {
        let cancel = self.timer(after, msg);
        if let Some(slot) = self.children.get_mut(&child) {
            slot.timers.push(cancel);
        }
    }

    /// SIGTERM after `after`, then SIGKILL [`Config::kill_after`] later.
    fn terminate(&mut self, child: ChildId, after: Duration) {
        let kill = after.saturating_add(self.config.kill_after);
        self.child_timer(child, after, Msg::Signal(child, libc::SIGTERM));
        self.child_timer(child, kill, Msg::Signal(child, libc::SIGKILL));
    }

    /// The socket lease: at once when no other supervisor holds it, else
    /// once it is given up, or at [`Config::lease_wait`] without it.
    fn claim(&self, epoch: Epoch) {
        let (path, wait, tx) = (self.config.lease.clone(), self.config.lease_wait, self.tx.clone());
        self.scope.spawn_until_cancelled("carrier supervise lease", async move {
            let lease =
                tokio::task::spawn_blocking(move || take_lease(&path, wait)).await.ok().flatten();
            let _ = tx.send(Msg::Claimed { epoch, lease });
        });
    }

    fn write_token(&mut self, child: ChildId, token: String) {
        let sender = self.children.get(&child).and_then(|slot| {
            slot.stdin.lock().unwrap_or_else(std::sync::PoisonError::into_inner).clone()
        });
        let tx = self.tx.clone();
        self.scope.spawn_until_cancelled("carrier serve token line", async move {
            let line = wire::token_line(&token);
            let ok = match sender {
                Some(sender) => write_all(&sender, line.as_bytes()).await,
                None => false,
            };
            let _ = tx.send(Msg::Event(Event::TokenWritten { child, token, ok }));
        });
    }

    fn spawn(&mut self, child: ChildId, env: &Env) {
        let mut command = cmux_process::Command::new(&self.config.program);
        command
            .args(&self.config.args)
            .envs(env.iter())
            .stdin(cmux_process::Stdio::piped())
            .stdout(cmux_process::Stdio::null())
            .stderr(cmux_process::Stdio::piped());
        let mut process = match command.spawn() {
            Ok(process) => process,
            Err(error) => {
                self.note(&format!("serve child {child} did not start: {error}"));
                let failure =
                    LinkError::disconnected(&format!("cmux carrier serve did not start: {error}"));
                self.queue.push_back(Event::Spawned { child, failure: Some(failure) });
                return;
            }
        };
        let stdin = process
            .stdin
            .take()
            .and_then(|stdin| pipe::Sender::from_owned_fd(OwnedFd::from(stdin)).ok())
            .map(Arc::new);
        let stderr = process
            .stderr
            .take()
            .and_then(|stderr| pipe::Receiver::from_owned_fd(OwnedFd::from(stderr)).ok());
        let reap = Arc::new(Reap {
            pid: libc::pid_t::try_from(process.id()).unwrap_or(0),
            reaped: Mutex::new(false),
        });
        let (exited, exit) = oneshot::channel();
        let waiter = reap.clone();
        self.scope.spawn_named("carrier serve exit", async move {
            let code = tokio::task::spawn_blocking(move || wait_child(process, &waiter))
                .await
                .unwrap_or(-1);
            let _ = exited.send(code);
        });
        let (tx, check) = (self.tx.clone(), self.config.check);
        self.scope.spawn_named("carrier serve stderr", read_stderr(child, stderr, exit, check, tx));
        self.children
            .insert(child, ChildSlot { stdin: Mutex::new(stdin), reap, timers: Vec::new() });
        if let Some((_, owner)) = &mut self.lease
            && owner.is_none()
        {
            *owner = Some(child);
        }
        self.note(&format!("serve child {child} started"));
        self.queue.push_back(Event::Spawned { child, failure: None });
    }
}

/// Takes the lease at `path` within `wait`; None when another holder kept
/// it (or it cannot be opened).
fn take_lease(path: &Path, wait: Duration) -> Option<FileLock> {
    let file =
        OpenOptions::new().create(true).truncate(false).write(true).mode(0o600).open(path).ok()?;
    // short-gate: 50 ms is the retry interval between lock attempts; `wait` is the deadline.
    FileLock::take_within(file, Kind::Exclusive, wait, Duration::from_millis(50)).ok()
}

/// Writes all of `bytes` within [`WRITE_LIMIT`].
async fn write_all(sender: &pipe::Sender, bytes: &[u8]) -> bool {
    let write = async {
        let mut sent = 0;
        while sent < bytes.len() {
            if sender.writable().await.is_err() {
                return false;
            }
            match sender.try_write(bytes.get(sent..).unwrap_or_default()) {
                Ok(n) => sent += n,
                Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {}
                Err(_) => return false,
            }
        }
        true
    };
    tokio::time::timeout(WRITE_LIMIT, write).await.unwrap_or(false)
}

/// Waits for the child's exit (an event, not a poll), marks it reaped under
/// `reap`'s lock and reaps it: its exit code, 128 + the signal that ended it,
/// or -1.
fn wait_child(mut process: cmux_process::Child, reap: &Reap) -> i32 {
    loop {
        match process.exited_within(Duration::from_secs(3600)) {
            Ok(true) => break,
            Ok(false) => {}
            Err(_) => {
                reap.signal(libc::SIGKILL);
                break;
            }
        }
    }
    let mut reaped = reap.reaped.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
    *reaped = true;
    match process.wait() {
        Ok(status) => status.code().unwrap_or_else(|| 128 + status.signal().unwrap_or(0)),
        Err(_) => -1,
    }
}

/// The child's stderr lines as its events, in order, then the end of
/// stderr with its tail, then its exit.
async fn read_stderr(
    child: ChildId,
    stderr: Option<pipe::Receiver>,
    mut exit: oneshot::Receiver<i32>,
    check: fn(&str) -> Result<(), LinkError>,
    tx: mpsc::UnboundedSender<Msg>,
) {
    let mut tail: VecDeque<String> = VecDeque::new();
    let mut code = None;
    if let Some(stderr) = stderr {
        let mut lines = tokio::io::BufReader::new(stderr).lines();
        loop {
            let next = if code.is_some() {
                match tokio::time::timeout(STDERR_DRAIN, lines.next_line()).await {
                    Ok(next) => next,
                    Err(_) => break,
                }
            } else {
                tokio::select! {
                    next = lines.next_line() => next,
                    exited = &mut exit => {
                        code = Some(exited.unwrap_or(-1));
                        continue;
                    }
                }
            };
            let Ok(Some(text)) = next else { break };
            match wire::serve_event(child, &text, check) {
                Some(event) => {
                    let _ = tx.send(Msg::Event(event));
                }
                None => {
                    if tail.len() == TAIL_LINES {
                        tail.pop_front();
                    }
                    tail.push_back(text);
                }
            }
        }
    }
    let stderr = Vec::from(tail).join("\n").trim().to_owned();
    let _ = tx.send(Msg::Event(Event::StderrEnded { child, stderr }));
    let code = match code {
        Some(code) => code,
        None => exit.await.unwrap_or(-1),
    };
    let _ = tx.send(Msg::Event(Event::ChildExit { child, code }));
}

#[cfg(test)]
#[path = "supervise_tests.rs"]
mod tests;
