//! The daemon's Chief brain supervisor (Multi-Chief S6, bead cx-ebm.60.6;
//! hq .cmux-scratch/hq6d-multi-chief/DESIGN.md section 10): every Chief that
//! is not the default gets its own brain host (`optchat-chief host`), started
//! and stopped by the daemon that owns its conversations.
//!
//! The app (or another launcher) turns it on with `CMUX_TUI_CHIEF_BRAINS`, a
//! JSON object: `executable` (the brain), `home` (this build's Chief home
//! root) and `app`, the values only the app knows (its bundle `bin`, the
//! person's name, the localized Chief title, the MCP command, the bundled
//! CLI and acpmux). The daemon takes the variable out of its environment at
//! start (`take_from_env`), so no terminal it starts inherits it. Without
//! it nothing starts.
//!
//! Each brain runs in `<home>/chiefs/<id>` with its own acpmux home, as the
//! participant `<id>` with a token minted in process (`agent-token`, 0600).
//! The default Chief (`agent_mux`) is never started here: the app's Home
//! keeps its lifecycle (and NIGHTLY's shared home) as it was.
//!
//! - Start: on `chief.profile.create`, and on a committed message by a person
//!   or another Chief in a conversation where the Chief is a participant and
//!   not the author. The brain applies its own wake rule
//!   (`OPTCHAT_GROUP_WAKE=every` by default).
//! - Restart: a brain that fails is started again after 1 s, doubling to
//!   60 s; one that exits 0 waits for the next message. A record change of a
//!   field the prompt renders restarts the brain between turns (the brain
//!   types while a main turn runs).
//! - Stop (SIGTERM to its process group; the host stops its own acpmux):
//!   `chief.profile.delete`, 30 minutes with no message and no turn, and
//!   daemon shutdown.

use std::collections::{BTreeMap, BTreeSet};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, OnceLock, PoisonError, Weak, mpsc};
use std::time::{Duration, Instant};

use serde::Deserialize;

use crate::chief_registry::{ChiefRecord, ChiefStore, DEFAULT_CHIEF};
use crate::conversation_store::ConversationEvent;
use crate::mux::Mux;

/// The launch variable (see the module doc).
pub const ENV: &str = "CMUX_TUI_CHIEF_BRAINS";
/// No message and no turn this long: the brain stops.
const IDLE: Duration = Duration::from_secs(30 * 60);
const BACKOFF_MIN: Duration = Duration::from_secs(1);
const BACKOFF_MAX: Duration = Duration::from_secs(60);
/// A brain that ran this long before it failed starts again at the shortest backoff.
const HEALTHY_RUN: Duration = Duration::from_secs(60);
/// How long daemon shutdown waits for the brains to end after SIGTERM.
const SHUTDOWN_GRACE: Duration = Duration::from_secs(5);

/// `CMUX_TUI_CHIEF_BRAINS`.
#[derive(Debug, Clone, Deserialize)]
pub struct BrainsConfig {
    pub executable: PathBuf,
    pub home: PathBuf,
    #[serde(default)]
    pub app: AppValues,
}

/// The values only the app knows; each is optional.
#[derive(Debug, Clone, Default, Deserialize)]
#[serde(default)]
pub struct AppValues {
    /// The bundle's `bin` (first on `PATH`).
    pub bin_dir: Option<PathBuf>,
    /// The person's name (`MUX_USER_NAME`).
    pub user_name: Option<String>,
    /// The localized Chief title (`MUX_CHIEF_TITLE`).
    pub chief_title: Option<String>,
    pub mcp_command: Option<String>,
    pub bundled_cli: Option<PathBuf>,
    pub acpmux_bin: Option<PathBuf>,
    /// `MUX_HARNESS`.
    pub harness: Option<String>,
}

static TAKEN: OnceLock<Option<String>> = OnceLock::new();

/// Reads `CMUX_TUI_CHIEF_BRAINS` and removes it from this process.
///
/// # Safety
///
/// Call it before this process starts any thread: removing an environment
/// variable is unsound while another thread can read the environment.
pub unsafe fn take_from_env() {
    let value = std::env::var(ENV).ok().filter(|v| !v.trim().is_empty());
    // SAFETY: forwarded from this function's contract (no other thread yet).
    unsafe { std::env::remove_var(ENV) };
    let _ = TAKEN.set(value);
}

/// The value this process started with, as given (`server ensure` hands it
/// to the owner it spawns).
pub fn taken() -> Option<String> {
    match TAKEN.get() {
        Some(taken) => taken.clone(),
        None => std::env::var(ENV).ok().filter(|v| !v.trim().is_empty()),
    }
}

fn config() -> Option<BrainsConfig> {
    let raw = taken()?;
    match serde_json::from_str::<BrainsConfig>(&raw) {
        Ok(config) if config.executable.is_absolute() && config.home.is_absolute() => Some(config),
        Ok(_) => {
            eprintln!("cmux-tui: {ENV}: executable and home must be absolute; no Chief brains");
            None
        }
        Err(error) => {
            eprintln!("cmux-tui: {ENV}: {error}; no Chief brains");
            None
        }
    }
}

/// The brain directory of Chief `chief` under the Chief home `home`.
pub fn brain_home(home: &Path, chief: &str) -> PathBuf {
    home.join("chiefs").join(chief)
}

/// The brain's whole environment (the brain starts from an empty one): the
/// one list of what a Chief brain needs, from the Chief home, the brain's
/// own directory, the app's values and a few user variables of the daemon.
pub fn brain_environment(
    config: &BrainsConfig,
    chief: &str,
    inherited: &dyn Fn(&str) -> Option<String>,
) -> BTreeMap<String, String> {
    let mux_home = brain_home(&config.home, chief);
    let app = &config.app;
    let user_home = inherited("HOME").unwrap_or_else(|| "/".into());
    let mut env = BTreeMap::new();
    let mut put = |key: &str, value: String| {
        env.insert(key.to_owned(), value);
    };
    let mut path: Vec<String> = app.bin_dir.iter().map(|d| d.display().to_string()).collect();
    path.extend(
        ["bin", ".local/bin", ".bun/bin", ".cargo/bin"].map(|d| format!("{user_home}/{d}")),
    );
    path.extend(
        ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
            .map(str::to_owned),
    );
    put("PATH", path.join(":"));
    put("HOME", user_home.clone());
    put("MUX_HOME", mux_home.display().to_string());
    put("MUX_AGENT_TOKEN_FILE", mux_home.join("agent-token").display().to_string());
    put("MUX_HOST_LOG", mux_home.join("host.log").display().to_string());
    // `cmux chief` in the brain's turns opens this build's Chief home.
    put("CMUX_CHIEF_HOME", config.home.display().to_string());
    // The constant links to the app that last opened Home (ChiefAppLinks).
    put("CMUX_SOCKET_PATH", config.home.join("state/app.sock").display().to_string());
    put("CMUX_APP_DAEMON_SOCKET", config.home.join("state/app-daemon.sock").display().to_string());
    // Its own acpmux (the brain derives the socket from the home); never the
    // default Chief's.
    put("ACPMUX_HOME", mux_home.join("acpmux").display().to_string());
    put("ACPMUX_LOCAL_ROUTER", "1".into());
    put("ACPMUX_SECRET_TOOLS", "1".into());
    put("OPTCHAT_CHIEF_PARTICIPANT", chief.to_owned());
    // Lawrence 2026-10-13: Chiefs act on their own; the loop guard stops loops.
    put("OPTCHAT_GROUP_WAKE", "every".into());
    let optional = [
        ("MUX_USER_NAME", app.user_name.clone()),
        ("MUX_CHIEF_TITLE", app.chief_title.clone()),
        ("CMUX_MCP_COMMAND", app.mcp_command.clone()),
        ("CMUX_BUNDLED_CLI_PATH", app.bundled_cli.as_ref().map(|p| p.display().to_string())),
        ("ACPMUX_BIN", app.acpmux_bin.as_ref().map(|p| p.display().to_string())),
        ("MUX_HARNESS", app.harness.clone()),
    ];
    for (key, value) in optional {
        if let Some(value) = value.filter(|v| !v.is_empty()) {
            put(key, value);
        }
    }
    for key in ["USER", "LOGNAME", "SHELL", "TMPDIR", "LANG", "LC_ALL"] {
        if let Some(value) = inherited(key) {
            put(key, value);
        }
    }
    env
}

/// What the supervisor hears.
enum Signal {
    /// A committed message: its conversation and author.
    Message {
        conversation: String,
        author: String,
    },
    Typing {
        conversation: String,
        participant: String,
        on: bool,
    },
    Created(Box<ChiefRecord>),
    Updated(Box<ChiefRecord>),
    Deleted(String),
    Exited {
        chief: String,
        pid: u32,
        success: bool,
    },
    Shutdown(mpsc::Sender<()>),
}

/// The supervisor's inbox on the Chief registry host: empty until
/// [`start`] runs.
#[derive(Default)]
pub(crate) struct Slot {
    sender: Mutex<Option<mpsc::Sender<Signal>>>,
}

impl Slot {
    fn send(&self, signal: Signal) {
        if let Some(sender) = self.sender.lock().unwrap_or_else(PoisonError::into_inner).as_ref() {
            let _ = sender.send(signal);
        }
    }

    fn running(&self) -> bool {
        self.sender.lock().unwrap_or_else(PoisonError::into_inner).is_some()
    }

    /// A mux event: committed messages and typing go to the supervisor.
    pub(crate) fn observe(&self, event: &ConversationEvent) {
        if !self.running() {
            return;
        }
        match event {
            ConversationEvent::Changed { conversation, change, .. }
                if change.get("kind").and_then(|k| k.as_str()) == Some("message") =>
            {
                if let Some(author) = change.pointer("/message/author").and_then(|a| a.as_str()) {
                    self.send(Signal::Message {
                        conversation: conversation.clone(),
                        author: author.to_owned(),
                    });
                }
            }
            ConversationEvent::Typing { conversation, participant, on } => {
                self.send(Signal::Typing {
                    conversation: conversation.clone(),
                    participant: participant.clone(),
                    on: *on,
                });
            }
            _ => {}
        }
    }

    /// A committed registry write (not a replay).
    pub(crate) fn chief_written(&self, record: &ChiefRecord, created: bool, deleted: bool) {
        if deleted {
            self.send(Signal::Deleted(record.id.clone()));
        } else if created {
            self.send(Signal::Created(Box::new(record.clone())));
        } else {
            self.send(Signal::Updated(Box::new(record.clone())));
        }
    }
}

/// The running supervisor; [`ChiefBrains::stop`] ends every brain.
pub struct ChiefBrains {
    sender: mpsc::Sender<Signal>,
    thread: Option<std::thread::JoinHandle<()>>,
    mux: Weak<Mux>,
}

impl ChiefBrains {
    /// Stops every brain (SIGTERM, then up to 5 s for them to end) and the
    /// supervisor.
    pub fn stop(mut self) {
        if let Some(mux) = self.mux.upgrade() {
            mux.chiefs().brains.sender.lock().unwrap_or_else(PoisonError::into_inner).take();
        }
        let (done, ended) = mpsc::channel();
        if self.sender.send(Signal::Shutdown(done)).is_ok() {
            let _ = ended.recv_timeout(SHUTDOWN_GRACE + Duration::from_secs(1));
        }
        if let Some(thread) = self.thread.take() {
            let _ = thread.join();
        }
    }
}

/// Starts the supervisor for `mux`, whose clients connect on `socket`, when
/// `CMUX_TUI_CHIEF_BRAINS` is set; `None` otherwise.
pub fn start(mux: &Arc<Mux>, socket: &Path) -> Option<ChiefBrains> {
    let config = config()?;
    let (sender, inbox) = mpsc::channel();
    *mux.chiefs().brains.sender.lock().unwrap_or_else(PoisonError::into_inner) =
        Some(sender.clone());
    let mut supervisor = Supervisor {
        mux: Arc::downgrade(mux),
        socket: socket.to_owned(),
        config,
        brains: BTreeMap::new(),
        sender: sender.clone(),
    };
    let thread = std::thread::Builder::new()
        .name("chief-brains".into())
        .spawn(move || supervisor.run(&inbox))
        .ok()?;
    Some(ChiefBrains { sender, thread: Some(thread), mux: Arc::downgrade(mux) })
}

/// The record fields the brain renders into its prompt or grant at start.
fn prompt_key(record: &ChiefRecord) -> String {
    serde_json::json!([
        record.display_name,
        record.role,
        record.personality,
        record.instructions,
        record.tools,
        record.harnesses,
        record.self_edit,
    ])
    .to_string()
}

struct Brain {
    /// The running process (its own process group) and whether it was reaped.
    process: Option<(u32, Arc<AtomicBool>)>,
    started_at: Instant,
    /// The prompt fields the running process started with.
    prompt: String,
    last_activity: Instant,
    failures: u32,
    retry_at: Option<Instant>,
    /// SIGTERM sent by the supervisor: the exit is expected.
    stopping: bool,
    /// Start again once the process ended (a prompt change).
    restart: bool,
    typing: BTreeSet<String>,
}

impl Brain {
    fn new() -> Self {
        let now = Instant::now();
        Self {
            process: None,
            started_at: now,
            prompt: String::new(),
            last_activity: now,
            failures: 0,
            retry_at: None,
            stopping: false,
            restart: false,
            typing: BTreeSet::new(),
        }
    }

    #[cfg(not(unix))]
    fn terminate(&mut self) {}

    #[cfg(unix)]
    fn terminate(&mut self) {
        if let Some((pid, reaped)) = &self.process
            && !reaped.load(Ordering::Acquire)
            && let Ok(group) = i32::try_from(*pid)
        {
            self.stopping = true;
            // SAFETY: kill has no memory preconditions; the group is this
            // supervisor's own child's (not reaped, so not reused).
            unsafe { libc::kill(-group, libc::SIGTERM) };
        }
    }
}

struct Supervisor {
    mux: Weak<Mux>,
    socket: PathBuf,
    config: BrainsConfig,
    brains: BTreeMap<String, Brain>,
    sender: mpsc::Sender<Signal>,
}

impl Supervisor {
    fn run(&mut self, inbox: &mpsc::Receiver<Signal>) {
        loop {
            let signal = match self.next_deadline() {
                Some(at) => {
                    match inbox.recv_timeout(at.saturating_duration_since(Instant::now())) {
                        Ok(signal) => Some(signal),
                        Err(mpsc::RecvTimeoutError::Timeout) => None,
                        Err(mpsc::RecvTimeoutError::Disconnected) => return,
                    }
                }
                None => match inbox.recv() {
                    Ok(signal) => Some(signal),
                    Err(_) => return,
                },
            };
            match signal {
                Some(Signal::Shutdown(done)) => {
                    self.shutdown(inbox);
                    let _ = done.send(());
                    return;
                }
                Some(signal) => self.handle(signal),
                None => {}
            }
            self.on_time();
        }
    }

    fn next_deadline(&self) -> Option<Instant> {
        self.brains
            .values()
            .flat_map(|b| {
                let idle = (b.process.is_some() && !b.stopping).then_some(b.last_activity + IDLE);
                [b.retry_at, idle]
            })
            .flatten()
            .min()
    }

    fn handle(&mut self, signal: Signal) {
        match signal {
            Signal::Message { conversation, author } => {
                for chief in self.woken_by(&conversation, &author) {
                    self.wake(&chief);
                }
            }
            Signal::Typing { conversation, participant, on } => {
                let Some(brain) = self.brains.get_mut(&participant) else { return };
                brain.last_activity = Instant::now();
                if on {
                    brain.typing.insert(conversation);
                } else {
                    brain.typing.remove(&conversation);
                    if brain.typing.is_empty() && brain.restart && !brain.stopping {
                        brain.terminate();
                    }
                }
            }
            Signal::Created(record) => {
                if !is_default(&record) {
                    self.wake(&record.id);
                }
            }
            Signal::Updated(record) => {
                let Some(brain) = self.brains.get_mut(&record.id) else { return };
                if brain.process.is_none() || brain.prompt == prompt_key(&record) {
                    return;
                }
                brain.restart = true;
                if brain.typing.is_empty() {
                    brain.terminate();
                }
            }
            Signal::Deleted(chief) => {
                if let Some(brain) = self.brains.get_mut(&chief) {
                    brain.restart = false;
                    brain.retry_at = None;
                    brain.terminate();
                }
            }
            Signal::Exited { chief, pid, success } => self.exited(&chief, pid, success),
            Signal::Shutdown(_) => {}
        }
    }

    /// The Chiefs a message by `author` in `conversation` starts: each
    /// participant that is a Chief (not the default, not the author) when the
    /// author is a person or a Chief.
    fn woken_by(&self, conversation: &str, author: &str) -> Vec<String> {
        let Some(mux) = self.mux.upgrade() else { return Vec::new() };
        let head = match mux.with_conversations(|store| store.head(conversation)) {
            Ok(Some(head)) => head,
            _ => return Vec::new(),
        };
        let chiefs: BTreeSet<String> = list_chiefs(&mux).into_iter().map(|r| r.id).collect();
        let by_person = head
            .participants
            .iter()
            .any(|p| p.id == author && p.kind == cmux_conversation::ParticipantKind::Human);
        if !by_person && !chiefs.contains(author) {
            return Vec::new();
        }
        head.participants
            .iter()
            .map(|p| p.id.clone())
            .filter(|id| id != author && id != DEFAULT_CHIEF && chiefs.contains(id))
            .collect()
    }

    fn wake(&mut self, chief: &str) {
        let brain = self.brains.entry(chief.to_owned()).or_insert_with(Brain::new);
        brain.last_activity = Instant::now();
        if brain.process.is_some() {
            return;
        }
        brain.retry_at = None;
        self.spawn(chief);
    }

    fn exited(&mut self, chief: &str, pid: u32, success: bool) {
        let Some(brain) = self.brains.get_mut(chief) else { return };
        if brain.process.as_ref().map(|(p, _)| *p) != Some(pid) {
            return;
        }
        brain.process = None;
        brain.typing.clear();
        let expected = std::mem::take(&mut brain.stopping);
        if std::mem::take(&mut brain.restart) {
            brain.failures = 0;
            self.spawn(chief);
            return;
        }
        if expected || success {
            brain.failures = 0;
            return;
        }
        if brain.started_at.elapsed() >= HEALTHY_RUN {
            brain.failures = 0;
        }
        let backoff = BACKOFF_MIN.saturating_mul(1 << brain.failures.min(6)).min(BACKOFF_MAX);
        brain.failures += 1;
        brain.retry_at = Some(Instant::now() + backoff);
    }

    fn on_time(&mut self) {
        let now = Instant::now();
        let mut retry = Vec::new();
        for (chief, brain) in &mut self.brains {
            if brain.retry_at.is_some_and(|at| at <= now) {
                brain.retry_at = None;
                if brain.last_activity.elapsed() < IDLE {
                    retry.push(chief.clone());
                }
            }
            if brain.process.is_some()
                && !brain.stopping
                && brain.typing.is_empty()
                && brain.last_activity + IDLE <= now
            {
                brain.restart = false;
                brain.terminate();
            }
        }
        for chief in retry {
            self.spawn(&chief);
        }
    }

    fn spawn(&mut self, chief: &str) {
        let Some(mux) = self.mux.upgrade() else { return };
        let Some(record) = list_chiefs(&mux).into_iter().find(|r| r.id == chief) else {
            self.brains.remove(chief);
            return;
        };
        if is_default(&record) {
            return;
        }
        match self.launch(&mux, &record) {
            Ok((pid, reaped)) => {
                let brain = self.brains.entry(chief.to_owned()).or_insert_with(Brain::new);
                brain.process = Some((pid, reaped));
                brain.started_at = Instant::now();
                brain.prompt = prompt_key(&record);
            }
            Err(error) => {
                eprintln!("cmux-tui: Chief brain {chief} did not start: {error:#}");
                let brain = self.brains.entry(chief.to_owned()).or_insert_with(Brain::new);
                let backoff =
                    BACKOFF_MIN.saturating_mul(1 << brain.failures.min(6)).min(BACKOFF_MAX);
                brain.failures += 1;
                brain.retry_at = Some(Instant::now() + backoff);
            }
        }
    }

    #[cfg(not(unix))]
    fn launch(&self, _: &Mux, _: &ChiefRecord) -> anyhow::Result<(u32, Arc<AtomicBool>)> {
        anyhow::bail!("Chief brains run on unix only")
    }

    #[cfg(unix)]
    fn launch(&self, mux: &Mux, record: &ChiefRecord) -> anyhow::Result<(u32, Arc<AtomicBool>)> {
        use std::io::Write as _;
        use std::os::unix::fs::{DirBuilderExt, OpenOptionsExt};
        use std::os::unix::process::CommandExt;

        let mux_home = brain_home(&self.config.home, &record.id);
        std::fs::DirBuilder::new().recursive(true).mode(0o700).create(&mux_home)?;
        let token = mux.with_conversations(|store| store.mint_agent_token(&record.id))?;
        let token_file = mux_home.join("agent-token");
        let _ = std::fs::remove_file(&token_file);
        let mut file = std::fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o600)
            .open(&token_file)?;
        file.write_all(token.as_bytes())?;
        drop(file);
        let log = std::fs::OpenOptions::new()
            .create(true)
            .append(true)
            .mode(0o600)
            .open(mux_home.join("host.log"))?;
        let inherited = |key: &str| std::env::var(key).ok().filter(|v| !v.is_empty());
        let mut command = std::process::Command::new(&self.config.executable);
        command
            .arg("host")
            .arg("--daemon-socket")
            .arg(&self.socket)
            .arg("--mux-home")
            .arg(&mux_home)
            .env_clear()
            .envs(brain_environment(&self.config, &record.id, &inherited))
            .current_dir(&mux_home)
            .stdin(std::process::Stdio::null())
            .stdout(log.try_clone()?)
            .stderr(log)
            .process_group(0);
        let mut child = command.spawn()?;
        let pid = child.id();
        let reaped = Arc::new(AtomicBool::new(false));
        let (sender, chief, flag) = (self.sender.clone(), record.id.clone(), reaped.clone());
        std::thread::Builder::new().name("chief-brain-wait".into()).spawn(move || {
            let success = child.wait().is_ok_and(|status| status.success());
            flag.store(true, Ordering::Release);
            let _ = sender.send(Signal::Exited { chief, pid, success });
        })?;
        Ok((pid, reaped))
    }

    /// SIGTERM every brain, then wait (bounded) for their exits.
    fn shutdown(&mut self, inbox: &mpsc::Receiver<Signal>) {
        for brain in self.brains.values_mut() {
            brain.restart = false;
            brain.retry_at = None;
            brain.terminate();
        }
        let deadline = Instant::now() + SHUTDOWN_GRACE;
        while self.brains.values().any(|b| b.process.is_some()) {
            match inbox.recv_timeout(deadline.saturating_duration_since(Instant::now())) {
                Ok(Signal::Exited { chief, pid, .. }) => {
                    if let Some(brain) = self.brains.get_mut(&chief)
                        && brain.process.as_ref().map(|(p, _)| *p) == Some(pid)
                    {
                        brain.process = None;
                    }
                }
                Ok(_) => {}
                Err(_) => return,
            }
        }
    }
}

fn is_default(record: &ChiefRecord) -> bool {
    record.is_default || record.id == DEFAULT_CHIEF
}

/// The live Chiefs of `mux`'s registry (opened on first use).
fn list_chiefs(mux: &Mux) -> Vec<ChiefRecord> {
    let mut store = mux.chiefs().store.lock().unwrap_or_else(PoisonError::into_inner);
    if store.is_none() {
        match ChiefStore::open(mux.session_state_directory().as_deref()) {
            Ok(opened) => *store = Some(opened),
            Err(_) => return Vec::new(),
        }
    }
    store.as_ref().and_then(|s| s.list().ok()).unwrap_or_default()
}
