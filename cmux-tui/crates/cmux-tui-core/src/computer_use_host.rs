//! The Computer Use worker on Linux and Windows: the daemon starts the
//! same `cmux-tui` binary in its hidden `__computer-use-worker` mode, keeps
//! it running while Computer Use is on, and hands agents (acpmux's bridge)
//! its endpoint through the `computer-use-endpoint` command
//! (`server/computer_use_command.rs`). On macOS the signed cmux Remote host
//! runs the worker instead (`remote_host.rs`); this supervisor is idle there.
//!
//! - Start: on the first endpoint request (never at daemon start, so a
//!   machine nobody automates runs no worker). The worker gets a fresh 32-byte
//!   secret per launch over its stdin (`configure`), never argv or a file.
//! - Ready: the worker's `ready` line; the endpoint answers `ready` with the
//!   socket, the secret and the worker's pid.
//! - Exit or crash: started again after [`Backoff`] (200 ms doubling to 30 s,
//!   reset after a healthy run) while Computer Use is on. Its state directory
//!   is the same on every launch, so grants and saved approvals survive.
//! - No desktop (a headless box without DISPLAY): `unavailable` with the
//!   reason; tried again on the next request.
//! - Off (`computerUse.mode` = off): the worker is stopped (stdin closed) and
//!   the endpoint answers `off`.
//! - Policy: [`config`] (owner file, then settings); sent to the running
//!   worker whenever it changes.
//! - Questions (`ask`) go to the cmux app when one is attached (a
//!   notification, answered through `computer-use-approvals` `answer`);
//!   otherwise they are answered `unavailable` at once.

#![cfg_attr(target_os = "macos", allow(dead_code))]

use std::collections::HashMap;
use std::io::{BufRead, BufReader, Read, Write};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::mpsc::{SyncSender, sync_channel};
use std::sync::{Arc, Condvar, Mutex, MutexGuard, PoisonError, Weak};
use std::time::{Duration, Instant};

use cmux_computer_use::policy::{Mode, PolicyConfig};
use serde_json::{Value, json};

use crate::backoff::Backoff;

pub(crate) mod config;
#[cfg(target_os = "linux")]
#[path = "computer_use_host/linux.rs"]
mod platform;
#[cfg(windows)]
#[path = "computer_use_host/windows.rs"]
pub(crate) mod platform;

/// Advertised by `identify` once the `computer-use-*` commands exist.
pub(crate) const COMPUTER_USE_CAPABILITY: &str = "computer-use-v1";
/// The worker's hidden mode (cmux-tui `computer_use_worker.rs`).
pub const WORKER_MODE: &str = "__computer-use-worker";
/// How long `computer-use-endpoint` waits for a starting worker.
pub(crate) const ENDPOINT_WAIT: Duration = Duration::from_secs(10);
/// A worker that ran at least this long restarts at the first backoff delay.
const HEALTHY_RUN: Duration = Duration::from_secs(30);
/// How long a question stays answerable (the worker's own limit).
const ASK_LIFETIME: Duration = Duration::from_secs(120);
/// How long a control request (`approvals list`) waits for the worker.
const CONTROL_WAIT: Duration = Duration::from_secs(5);

/// A started worker process, as a launcher hands it over.
pub(crate) struct WorkerProcess {
    /// The worker's control input (its stdin).
    pub(crate) input: Box<dyn Write + Send>,
    /// The worker's control output (its stdout).
    pub(crate) output: Box<dyn Read + Send>,
    /// Called once the output ended: reaps the process.
    pub(crate) reap: Box<dyn FnOnce() + Send>,
}

/// Starts worker processes (the platform's, or an in-process one in tests).
pub(crate) trait Launcher: Send + Sync {
    /// Starts one worker; `Err` says why there can be none here now.
    fn launch(&self, log: &Path) -> Result<WorkerProcess, String>;
}

/// Where one daemon's worker lives.
#[derive(Clone, Debug)]
pub(crate) struct Paths {
    /// The agent socket: a Unix socket path, or `\\.\pipe\...` on Windows.
    pub(crate) endpoint: String,
    /// Durable: sessions, saved approvals and the audit log (0700).
    pub(crate) state: PathBuf,
    pub(crate) log: PathBuf,
}

/// What a question from the worker looks like to the app.
#[derive(Clone, Debug)]
pub(crate) struct PendingAsk {
    pub(crate) id: u64,
    pub(crate) question: Value,
    generation: u64,
    worker_id: u64,
    asked: Instant,
}

impl PendingAsk {
    pub(crate) fn to_json(&self) -> Value {
        json!({"id": self.id, "question": self.question})
    }
}

/// Routes a question to the person: true when someone can answer it.
pub(crate) type AskRouter = Arc<dyn Fn(&PendingAsk) -> bool + Send + Sync>;

#[derive(Clone, Debug, Default)]
enum Phase {
    #[default]
    Idle,
    Starting,
    Ready {
        socket: String,
        secret: String,
        pid: Option<u64>,
    },
    Unavailable(String),
}

struct Link {
    generation: u64,
    input: Mutex<Option<Box<dyn Write + Send>>>,
    started: Instant,
    secret: String,
}

impl Link {
    fn send(&self, value: &Value) -> bool {
        let mut input = self.input.lock().unwrap_or_else(PoisonError::into_inner);
        let Some(writer) = input.as_mut() else { return false };
        let ok = writeln!(writer, "{value}").and_then(|()| writer.flush()).is_ok();
        if !ok {
            *input = None;
        }
        ok
    }
    /// Closes the worker's stdin: it stops serving and exits.
    fn close(&self) {
        self.input.lock().unwrap_or_else(PoisonError::into_inner).take();
    }
}

struct Setup {
    paths: Paths,
    launcher: Arc<dyn Launcher>,
    machine: String,
}

#[derive(Default)]
struct Inner {
    setup: Mutex<Option<Setup>>,
    config: Mutex<Option<(PolicyConfig, config::Source)>>,
    /// Why the owner file was ignored, for status.
    owner_problem: Mutex<Option<String>>,
    phase: Mutex<Phase>,
    changed: Condvar,
    link: Mutex<Option<Arc<Link>>>,
    /// Held while a worker starts, so two callers never start two.
    starting: Mutex<()>,
    backoff: Mutex<Option<Backoff>>,
    generation: AtomicU64,
    asks: Mutex<HashMap<u64, PendingAsk>>,
    next_ask: AtomicU64,
    router: Mutex<Option<AskRouter>>,
    replies: Mutex<HashMap<u64, SyncSender<Value>>>,
    next_request: AtomicU64,
    watcher: Mutex<Option<cmux_config::Watcher>>,
    recompute: Mutex<()>,
}

fn lock<T>(mutex: &Mutex<T>) -> MutexGuard<'_, T> {
    mutex.lock().unwrap_or_else(PoisonError::into_inner)
}

/// The daemon's view of its Computer Use worker.
#[derive(Default)]
pub(crate) struct ComputerUseHost {
    inner: Arc<Inner>,
}

impl ComputerUseHost {
    /// Lets this daemon run a worker: where, how, and the policy to start with.
    pub(crate) fn configure(
        &self,
        paths: Paths,
        launcher: Arc<dyn Launcher>,
        machine: String,
        config: PolicyConfig,
        source: config::Source,
    ) {
        *lock(&self.inner.setup) = Some(Setup { paths, launcher, machine });
        *lock(&self.inner.config) = Some((config, source));
    }

    pub(crate) fn configured(&self) -> bool {
        lock(&self.inner.setup).is_some()
    }

    pub(crate) fn set_router(&self, router: AskRouter) {
        *lock(&self.inner.router) = Some(router);
    }

    pub(crate) fn keep_watcher(&self, watcher: cmux_config::Watcher) {
        *lock(&self.inner.watcher) = Some(watcher);
    }

    pub(crate) fn set_owner_problem(&self, problem: Option<String>) {
        *lock(&self.inner.owner_problem) = problem;
    }

    pub(crate) fn config(&self) -> Option<(PolicyConfig, config::Source)> {
        lock(&self.inner.config).clone()
    }

    /// A new policy: sent to the running worker; mode off stops it.
    pub(crate) fn set_config(&self, config: PolicyConfig, source: config::Source) {
        let changed = {
            let mut current = lock(&self.inner.config);
            let changed = current.as_ref().is_none_or(|(c, s)| *c != config || *s != source);
            *current = Some((config.clone(), source));
            changed
        };
        if !changed {
            return;
        }
        if config.mode == Mode::Off {
            Inner::stop(&self.inner);
            return;
        }
        if let Some(link) = lock(&self.inner.link).clone() {
            link.send(&json!({"type": "config", "config": config}));
        }
    }

    /// The endpoint for an agent, starting the worker when needed and
    /// waiting up to `wait` for it to be ready.
    pub(crate) fn endpoint(&self, wait: Duration) -> Value {
        let Some((config, _)) = self.config() else {
            return json!({"state": "unavailable", "reason": "this daemon runs no Computer Use worker"});
        };
        if config.mode == Mode::Off {
            return json!({"state": "off", "reason": "Computer Use is off (Settings > Computer Use)"});
        }
        Inner::start_in_background(&self.inner);
        let deadline = Instant::now() + wait;
        let mut phase = lock(&self.inner.phase);
        loop {
            match &*phase {
                Phase::Ready { socket, secret, pid } => {
                    return json!({"state": "ready", "socket": socket, "secret": secret, "pid": pid});
                }
                Phase::Unavailable(reason) => {
                    return json!({"state": "unavailable", "reason": reason});
                }
                Phase::Idle | Phase::Starting => {}
            }
            let left = deadline.saturating_duration_since(Instant::now());
            if left.is_zero() {
                return json!({"state": "starting", "reason": "the Computer Use worker is starting"});
            }
            phase = self
                .inner
                .changed
                .wait_timeout(phase, left)
                .unwrap_or_else(PoisonError::into_inner)
                .0;
        }
    }

    /// State for status (never starts the worker; no secret).
    pub(crate) fn status(&self) -> Value {
        let (state, pid, reason) = match &*lock(&self.inner.phase) {
            Phase::Idle => ("idle", None, None),
            Phase::Starting => ("starting", None, None),
            Phase::Ready { pid, .. } => ("ready", *pid, None),
            Phase::Unavailable(reason) => ("unavailable", None, Some(reason.clone())),
        };
        let config = self.config();
        json!({
            "state": state, "pid": pid, "reason": reason,
            "mode": config.as_ref().map(|(c, _)| c.mode.as_str()),
            "config_source": config.as_ref().map(|(_, s)| s.describe()),
            "owner_file_problem": lock(&self.inner.owner_problem).clone(),
        })
    }

    /// Saved-approval edits (`forget`, `always`, `never`, `revoke_sessions`).
    /// The worker applies them; with no worker running they wait for none
    /// (the next worker reads the saved file, which only the worker writes).
    pub(crate) fn edit_approvals(&self, action: &str, app_id: &str) -> Result<(), String> {
        let link = Inner::ensure_link(&self.inner)?;
        if link.send(&json!({"type": "approvals", "action": action, "app_id": app_id})) {
            Ok(())
        } else {
            Err("the Computer Use worker stopped".into())
        }
    }

    /// Saved approvals and the questions waiting for the person.
    pub(crate) fn list_approvals(&self) -> Result<Value, String> {
        let link = Inner::ensure_link(&self.inner)?;
        let id = self.inner.next_request.fetch_add(1, Ordering::Relaxed) + 1;
        let (tx, rx) = sync_channel(1);
        lock(&self.inner.replies).insert(id, tx);
        if !link.send(&json!({"type": "approvals", "action": "list", "id": id})) {
            lock(&self.inner.replies).remove(&id);
            return Err("the Computer Use worker stopped".into());
        }
        let reply = rx.recv_timeout(CONTROL_WAIT);
        lock(&self.inner.replies).remove(&id);
        let reply = reply.map_err(|_| "the Computer Use worker did not answer".to_string())?;
        Ok(
            json!({"saved": reply.get("saved").cloned().unwrap_or(Value::Null), "pending": self.pending()}),
        )
    }

    pub(crate) fn pending(&self) -> Vec<Value> {
        let mut asks = lock(&self.inner.asks);
        asks.retain(|_, ask| ask.asked.elapsed() < ASK_LIFETIME);
        let mut list: Vec<&PendingAsk> = asks.values().collect();
        list.sort_by_key(|ask| ask.id);
        list.into_iter().map(PendingAsk::to_json).collect()
    }

    /// The person's answer to question `id`.
    pub(crate) fn answer(&self, id: u64, answer: &str) -> Result<(), String> {
        let ask =
            lock(&self.inner.asks).remove(&id).ok_or("no such question (answered or expired)")?;
        let link = lock(&self.inner.link).clone().filter(|l| l.generation == ask.generation);
        let link = link.ok_or("the worker that asked has stopped")?;
        link.send(&json!({"type": "answer", "id": ask.worker_id, "answer": answer}));
        Ok(())
    }
}

impl Inner {
    fn set_phase(&self, phase: Phase) {
        *lock(&self.phase) = phase;
        self.changed.notify_all();
    }

    fn wanted(&self) -> bool {
        lock(&self.config).as_ref().is_some_and(|(c, _)| c.mode != Mode::Off)
    }

    /// The running worker's link, starting one first.
    fn ensure_link(this: &Arc<Self>) -> Result<Arc<Link>, String> {
        Self::ensure(this);
        lock(&this.link).clone().ok_or_else(|| match &*lock(&this.phase) {
            Phase::Unavailable(reason) => reason.clone(),
            _ => "the Computer Use worker is not running".into(),
        })
    }

    /// [`Self::ensure`] off the caller's thread (a launch can take a while:
    /// a scheduled task on Windows), so the caller waits at most its own
    /// limit. The phase is `Starting` before this returns, never a stale
    /// earlier `Unavailable`.
    fn start_in_background(this: &Arc<Self>) {
        if lock(&this.link).is_some() || !this.wanted() {
            return;
        }
        {
            let mut phase = lock(&this.phase);
            if !matches!(*phase, Phase::Ready { .. }) {
                *phase = Phase::Starting;
            }
        }
        let inner = Arc::clone(this);
        let spawned = std::thread::Builder::new()
            .name("cmux-cu-start".into())
            .spawn(move || Self::ensure(&inner));
        if spawned.is_err() {
            Self::ensure(this);
        }
    }

    /// Starts a worker unless one runs or Computer Use is off.
    fn ensure(this: &Arc<Self>) {
        if lock(&this.link).is_some() || !this.wanted() {
            return;
        }
        let _starting = lock(&this.starting);
        if lock(&this.link).is_some() || !this.wanted() {
            return;
        }
        if let Err(reason) = Self::start(this) {
            this.set_phase(Phase::Unavailable(reason));
        }
    }

    fn start(this: &Arc<Self>) -> Result<(), String> {
        let (paths, launcher, machine) = {
            let setup = lock(&this.setup);
            let setup = setup.as_ref().ok_or("this daemon runs no Computer Use worker")?;
            (setup.paths.clone(), Arc::clone(&setup.launcher), setup.machine.clone())
        };
        let config = lock(&this.config).as_ref().map(|(c, _)| c.clone()).unwrap_or_default();
        let secret = mint_secret()?;
        this.set_phase(Phase::Starting);
        let process = launcher.launch(&paths.log)?;
        let generation = this.generation.fetch_add(1, Ordering::SeqCst) + 1;
        let link = Arc::new(Link {
            generation,
            input: Mutex::new(Some(process.input)),
            started: Instant::now(),
            secret: secret.clone(),
        });
        let configure = json!({
            "type": "configure", "config": config, "socket": paths.endpoint, "secret": secret,
            "state_dir": paths.state, "machine": machine,
        });
        if !link.send(&configure) {
            link.close();
            (process.reap)();
            return Err("the Computer Use worker exited at once".into());
        }
        *lock(&this.link) = Some(Arc::clone(&link));
        let weak = Arc::downgrade(this);
        let (output, reap) = (process.output, process.reap);
        let reading = Arc::clone(&link);
        std::thread::Builder::new()
            .name("cmux-cu-worker".into())
            .spawn(move || Self::read(&weak, &reading, output, reap))
            .map_err(|error| format!("cannot read the worker: {error}"))?;
        Ok(())
    }

    fn read(
        this: &Weak<Self>,
        link: &Arc<Link>,
        output: Box<dyn Read + Send>,
        reap: Box<dyn FnOnce() + Send>,
    ) {
        let mut said_unavailable = None;
        let mut was_ready = false;
        let mut reader = BufReader::new(output);
        let mut line = String::new();
        loop {
            line.clear();
            match reader.read_line(&mut line) {
                Ok(0) | Err(_) => break,
                Ok(_) => {}
            }
            let Some(inner) = this.upgrade() else { break };
            let Ok(message) = serde_json::from_str::<Value>(&line) else { continue };
            let current = lock(&inner.link).as_ref().is_some_and(|l| Arc::ptr_eq(l, link));
            match message.get("type").and_then(Value::as_str).unwrap_or_default() {
                "ready" if current => {
                    was_ready = true;
                    let socket = message.get("socket").and_then(Value::as_str).unwrap_or_default();
                    inner.set_phase(Phase::Ready {
                        socket: socket.to_string(),
                        secret: link.secret.clone(),
                        pid: message.get("pid").and_then(Value::as_u64),
                    });
                }
                "unavailable" | "error" => {
                    let reason = message
                        .get("reason")
                        .and_then(Value::as_str)
                        .unwrap_or("the Computer Use worker cannot run here")
                        .to_string();
                    said_unavailable = Some(reason);
                }
                "ask" => Self::asked(&inner, link, &message),
                "approvals" => {
                    if let Some(id) = message.get("id").and_then(Value::as_u64)
                        && let Some(waiting) = lock(&inner.replies).remove(&id)
                    {
                        let _ = waiting.send(message);
                    }
                }
                _ => {}
            }
        }
        reap();
        let Some(inner) = this.upgrade() else { return };
        Self::gone(&inner, link, was_ready, said_unavailable);
    }

    fn asked(this: &Arc<Self>, link: &Arc<Link>, message: &Value) {
        let Some(worker_id) = message.get("id").and_then(Value::as_u64) else { return };
        let ask = PendingAsk {
            id: this.next_ask.fetch_add(1, Ordering::Relaxed) + 1,
            question: message.get("question").cloned().unwrap_or(Value::Null),
            generation: link.generation,
            worker_id,
            asked: Instant::now(),
        };
        lock(&this.asks).insert(ask.id, ask.clone());
        let router = lock(&this.router).clone();
        if !router.is_some_and(|route| route(&ask)) {
            lock(&this.asks).remove(&ask.id);
            link.send(&json!({"type": "answer", "id": worker_id, "answer": "unavailable"}));
        }
    }

    /// The worker's output ended: forget it, and start again after the
    /// backoff while Computer Use is on (not when it said it cannot run here).
    fn gone(this: &Arc<Self>, link: &Arc<Link>, was_ready: bool, said_unavailable: Option<String>) {
        {
            let mut current = lock(&this.link);
            if !current.as_ref().is_some_and(|l| Arc::ptr_eq(l, link)) {
                return;
            }
            *current = None;
        }
        lock(&this.asks).retain(|_, ask| ask.generation != link.generation);
        if let Some(reason) = said_unavailable {
            this.set_phase(Phase::Unavailable(reason));
            return;
        }
        if !this.wanted() {
            this.set_phase(Phase::Idle);
            return;
        }
        if !was_ready {
            this.set_phase(Phase::Unavailable(
                "the Computer Use worker exited before it was ready (see its log)".into(),
            ));
        } else {
            this.set_phase(Phase::Idle);
        }
        let ran = link.started.elapsed();
        let delay = {
            let mut backoff = lock(&this.backoff);
            let backoff = backoff.get_or_insert_with(|| {
                Backoff::new(Duration::from_millis(200), Duration::from_secs(30))
            });
            if ran >= HEALTHY_RUN {
                backoff.reset();
            }
            backoff.next_delay()
        };
        eprintln!(
            "cmux-tui: Computer Use worker stopped after {} ms; starting again in {} ms",
            ran.as_millis(),
            delay.as_millis()
        );
        let weak = Arc::downgrade(this);
        let _ = std::thread::Builder::new().name("cmux-cu-restart".into()).spawn(move || {
            // A bounded restart delay on this thread, not a synchronization.
            std::thread::sleep(delay);
            if let Some(inner) = weak.upgrade() {
                Self::ensure(&inner);
            }
        });
    }

    /// Computer Use went off: the worker stops (it exits when stdin closes).
    fn stop(this: &Arc<Self>) {
        let link = lock(&this.link).take();
        if let Some(link) = link {
            link.close();
        }
        lock(&this.asks).clear();
        this.set_phase(Phase::Idle);
    }
}

fn mint_secret() -> Result<String, String> {
    let mut bytes = [0_u8; 32];
    getrandom::fill(&mut bytes).map_err(|error| format!("cannot mint a secret: {error}"))?;
    Ok(cmux_computer_use::wire::hex(&bytes))
}

/// The paths of the worker for the daemon on `daemon_socket` with durable
/// state under `state_root`.
pub(crate) fn paths_for(daemon_socket: &Path, state_root: &Path) -> Paths {
    use sha2::{Digest, Sha256};
    let digest = format!("{:x}", Sha256::digest(daemon_socket.as_os_str().as_encoded_bytes()));
    let leaf = format!("cu-{}", &digest[..12]);
    #[cfg(unix)]
    let (endpoint, log) = {
        let mut runtime = daemon_socket.parent().unwrap_or_else(|| Path::new("/tmp")).join(&leaf);
        if !crate::server::unix_socket_path_fits(&runtime.join("cu.sock")) {
            runtime = crate::platform::fallback_runtime_dir().join(&leaf);
        }
        (
            runtime.join("cu.sock").display().to_string(),
            state_root.join("computer-use").join("worker.log"),
        )
    };
    #[cfg(windows)]
    let (endpoint, log) =
        (format!(r"\\.\pipe\cmux-{leaf}"), state_root.join("computer-use").join("worker.log"));
    Paths { endpoint, state: state_root.join("computer-use").join("state"), log }
}

/// The policy now: the owner file when trusted, else the settings over the
/// machine's base (unrestricted on a cmux Cloud VM).
fn current_policy(mux: &Arc<crate::mux::Mux>) -> (PolicyConfig, config::Source, Option<String>) {
    let owner = config::owner_path();
    let settings = || config::from_settings(&mux.settings_effective_root(), config::base_policy());
    match config::read_owner(&owner) {
        Ok(Some(policy)) => (policy, config::Source::Owner(owner), None),
        Ok(None) => (settings(), config::Source::Settings, None),
        Err(problem) => (settings(), config::Source::Settings, Some(problem)),
    }
}

impl crate::mux::Mux {
    /// Lets this daemon (Linux, Windows) run the Computer Use worker for the
    /// daemon on `daemon_socket`, with durable state beside the daemon's own.
    #[cfg(any(target_os = "linux", windows))]
    pub(crate) fn configure_computer_use(self: &Arc<Self>, daemon_socket: &Path) {
        let Some(state_root) = crate::platform::workspace_state_dir()
            .and_then(|sessions| sessions.parent().map(Path::to_path_buf))
        else {
            return;
        };
        let Ok(exe) = std::env::current_exe() else { return };
        let launcher: Arc<dyn Launcher> = Arc::new(platform::NativeLauncher::new(exe));
        self.configure_computer_use_with(paths_for(daemon_socket, &state_root), launcher);
    }

    /// [`Self::configure_computer_use`] with the launcher given (tests).
    pub(crate) fn configure_computer_use_with(
        self: &Arc<Self>,
        paths: Paths,
        launcher: Arc<dyn Launcher>,
    ) {
        let host = &self.control_clients.computer_use;
        let (policy, source, problem) = current_policy(self);
        host.set_owner_problem(problem);
        let machine = hostname();
        host.configure(paths, launcher, machine, policy, source);
        let weak = Arc::downgrade(self);
        host.set_router(Arc::new(move |ask: &PendingAsk| {
            weak.upgrade()
                .is_some_and(|mux| crate::server::computer_use_command::route_ask(&mux, ask))
        }));
        // The owner file can appear, change or go at any time (an image
        // update, the owner's edit): re-read on every hint.
        let weak = Arc::downgrade(self);
        if let Ok(watcher) = cmux_config::Watcher::start(vec![config::owner_path()], move || {
            if let Some(mux) = weak.upgrade() {
                mux.computer_use_policy_changed();
            }
        }) {
            host.keep_watcher(watcher);
        }
    }

    /// The settings or the owner file changed: recompute and resend. A
    /// policy the app pushed (`computer-use-config`) stays until the owner
    /// file or the settings change again.
    pub(crate) fn computer_use_policy_changed(self: &Arc<Self>) {
        let host = &self.control_clients.computer_use;
        if !host.configured() {
            return;
        }
        // One recompute at a time: the later one reads the later settings.
        let _ordered = lock(&host.inner.recompute);
        let (policy, source, problem) = current_policy(self);
        host.set_owner_problem(problem);
        host.set_config(policy, source);
    }
}

fn hostname() -> String {
    #[cfg(unix)]
    {
        let mut buf = [0u8; 256];
        // SAFETY: gethostname into a sized buffer.
        if unsafe { libc::gethostname(buf.as_mut_ptr().cast(), buf.len()) } == 0 {
            let end = buf.iter().position(|b| *b == 0).unwrap_or(buf.len());
            return String::from_utf8_lossy(&buf[..end]).into_owned();
        }
        String::new()
    }
    #[cfg(not(unix))]
    {
        std::env::var("COMPUTERNAME").unwrap_or_default()
    }
}

#[cfg(all(test, unix))]
#[path = "computer_use_host/tests.rs"]
mod tests;
