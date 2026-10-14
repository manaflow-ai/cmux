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
//! Each brain runs in `<home>/c/<last 8 of id>` with its own acpmux home
//! (`a` in it), as the participant `<id>` with a token minted in process
//! (`agent-token`, 0600). The directory is short because Unix sockets live
//! under it (optchat/tools.sock, the acpmux router's socket) and a socket
//! path has at most 103 bytes; `<home>/chiefs/<id>` was 120 and more on a
//! DEV build (2026-10-14, cmux-lawrence-2).
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
    /// The localized Chief title (`MUX_CHIEF_TITLE` when the record has no
    /// display_name; a Chief's own name comes first, `brain_environment`).
    pub chief_title: Option<String>,
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

/// The brain directory of Chief `chief` under the Chief home `home`: the
/// last 8 characters of its id (40 random bits of the ULID), lowercased.
pub fn brain_home(home: &Path, chief: &str) -> PathBuf {
    let tail = chief.get(chief.len().saturating_sub(8)..).unwrap_or(chief);
    home.join("c").join(tail.to_ascii_lowercase())
}

/// The longest socket path under a brain directory: acpmux's router socket
/// (`a/router/router.sock`, no short alias; `optchat/tools.sock` is 2 bytes
/// shorter). A home whose sockets do not fit starts no brain.
const LONGEST_SOCKET: &str = "a/router/router.sock";
/// The longest Unix socket path, in bytes (macOS sun_path less the NUL).
const MAX_SOCKET_PATH: usize = 103;

fn sockets_fit(mux_home: &Path) -> bool {
    mux_home.join(LONGEST_SOCKET).as_os_str().len() <= MAX_SOCKET_PATH
}

/// The brain's whole environment (the brain starts from an empty one): the
/// one list of what a Chief brain needs, from the Chief home, the brain's
/// own directory, the app's values and a few user variables of the daemon.
/// `title` is the Chief's own name (its record's display_name): the brain's
/// `MUX_CHIEF_TITLE`, which titles its conversation, so each Chief's DM
/// shows its name, not the app's "Chief" (hq-6d 2026-10-14); `None` or
/// empty keeps the app's title.
pub fn brain_environment(
    config: &BrainsConfig,
    chief: &str,
    title: Option<&str>,
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
    put("HOME", user_home);
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
    put("ACPMUX_HOME", mux_home.join("a").display().to_string());
    put("ACPMUX_LOCAL_ROUTER", "1".into());
    put("ACPMUX_SECRET_TOOLS", "1".into());
    put("OPTCHAT_CHIEF_PARTICIPANT", chief.to_owned());
    // Lawrence 2026-10-13: Chiefs act on their own; the loop guard stops loops.
    put("OPTCHAT_GROUP_WAKE", "every".into());
    let optional = [
        ("MUX_USER_NAME", app.user_name.clone()),
        (
            "MUX_CHIEF_TITLE",
            title
                .filter(|t| !t.trim().is_empty())
                .map(str::to_owned)
                .or_else(|| app.chief_title.clone()),
        ),
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
    #[cfg_attr(not(unix), allow(dead_code))]
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

    /// A mux event: committed messages and typing go to the supervisor.
    pub(crate) fn observe(&self, event: &ConversationEvent) {
        let signal = match event {
            ConversationEvent::Changed { conversation, change, .. }
                if change.get("kind").and_then(|k| k.as_str()) == Some("message") =>
            {
                let Some(author) = change.pointer("/message/author").and_then(|a| a.as_str())
                else {
                    return;
                };
                Signal::Message { conversation: conversation.clone(), author: author.to_owned() }
            }
            ConversationEvent::Typing { conversation, participant, on } => Signal::Typing {
                conversation: conversation.clone(),
                participant: participant.clone(),
                on: *on,
            },
            _ => return,
        };
        self.send(signal);
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
    /// Stops every brain (SIGTERM, up to 5 s for them to end, then SIGKILL)
    /// and the supervisor.
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

#[cfg(unix)]
const SIGTERM: i32 = libc::SIGTERM;
#[cfg(not(unix))]
const SIGTERM: i32 = 15;
#[cfg(unix)]
const SIGKILL: i32 = libc::SIGKILL;
#[cfg(not(unix))]
const SIGKILL: i32 = 9;

/// A brain process this supervisor started: the leader of its own process
/// group. `reaped` turns true (under its lock) only after the last signal
/// the supervisor may send: the waiter takes the lock, marks it, and only
/// then reaps the zombie, so a signalled group id is never a reused one.
struct Process {
    pid: u32,
    reaped: Arc<Mutex<bool>>,
}

impl Process {
    #[cfg(not(unix))]
    fn signal(&self, _: i32) {}

    #[cfg(unix)]
    fn signal(&self, signal: i32) {
        let reaped = self.reaped.lock().unwrap_or_else(PoisonError::into_inner);
        if !*reaped && let Ok(group) = i32::try_from(self.pid) {
            // SAFETY: kill has no memory preconditions; the group's leader is
            // not reaped (checked under the lock), so its id is still ours.
            unsafe { libc::kill(-group, signal) };
        }
    }
}

struct Brain {
    process: Option<Process>,
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
    /// A message came while the process ran: if it ends anyway (exit 0, or
    /// an idle stop), start it again for that message.
    pending_wake: bool,
    /// The held-lock note was logged.
    lock_noted: bool,
    /// The Chief was deleted: when the process ends, its acpmux ends too.
    deleted: bool,
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
            pending_wake: false,
            lock_noted: false,
            deleted: false,
            typing: BTreeSet::new(),
        }
    }

    fn terminate(&mut self) {
        if let Some(process) = &self.process {
            self.stopping = true;
            process.signal(SIGTERM);
        }
    }

    fn back_off(&mut self) {
        let backoff = BACKOFF_MIN.saturating_mul(1 << self.failures.min(6)).min(BACKOFF_MAX);
        self.failures += 1;
        self.retry_at = Some(Instant::now() + backoff);
    }
}

struct Supervisor {
    mux: Weak<Mux>,
    #[cfg_attr(not(unix), allow(dead_code))]
    socket: PathBuf,
    config: BrainsConfig,
    brains: BTreeMap<String, Brain>,
    #[cfg_attr(not(unix), allow(dead_code))]
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
                // Not running, unchanged, or already stopping for good.
                if brain.process.is_none()
                    || brain.prompt == prompt_key(&record)
                    || (brain.stopping && !brain.restart)
                {
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
                    brain.pending_wake = false;
                    brain.retry_at = None;
                    brain.deleted = true;
                    brain.terminate();
                    if brain.process.is_some() {
                        return;
                    }
                }
                let mux_home = brain_home(&self.config.home, &chief);
                stop_lock_holder(&mux_home.join("state/host.lock"));
                self.end_acpmux(&mux_home);
                self.brains.remove(&chief);
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
            brain.pending_wake = true;
            return;
        }
        // A brain that failed starts again at its retry time, not per message.
        if brain.retry_at.is_some_and(|at| at > Instant::now()) {
            return;
        }
        brain.retry_at = None;
        self.spawn(chief);
    }

    fn exited(&mut self, chief: &str, pid: u32, success: bool) {
        let Some(brain) = self.brains.get_mut(chief) else { return };
        if brain.process.as_ref().map(|p| p.pid) != Some(pid) {
            return;
        }
        brain.process = None;
        brain.typing.clear();
        if brain.deleted {
            self.brains.remove(chief);
            self.end_acpmux(&brain_home(&self.config.home, chief));
            return;
        }
        let expected = std::mem::take(&mut brain.stopping);
        let woken = std::mem::take(&mut brain.pending_wake);
        if std::mem::take(&mut brain.restart) || (woken && (expected || success)) {
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
        brain.back_off();
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
                brain.pending_wake = false;
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
        let mux_home = brain_home(&self.config.home, chief);
        if !sockets_fit(&mux_home) {
            let brain = self.brains.entry(chief.to_owned()).or_insert_with(Brain::new);
            if !std::mem::replace(&mut brain.lock_noted, true) {
                eprintln!(
                    "cmux-tui: Chief brain {chief} cannot start: {} is too long for its sockets",
                    mux_home.display()
                );
            }
            return;
        }
        // Two ids with the same tail would share a directory: the first keeps it.
        let owner = std::fs::read_to_string(mux_home.join("chief-id")).unwrap_or_default();
        if !owner.trim().is_empty() && owner.trim() != chief {
            let brain = self.brains.entry(chief.to_owned()).or_insert_with(Brain::new);
            if !std::mem::replace(&mut brain.lock_noted, true) {
                eprintln!(
                    "cmux-tui: Chief brain {chief} cannot start: {} is Chief {}'s",
                    mux_home.display(),
                    owner.trim()
                );
            }
            return;
        }
        // A brain this daemon did not start (one an earlier owner left)
        // holds the lock: keep it; a new token would only end its binding.
        if lock_held(&brain_home(&self.config.home, chief).join("state/host.lock")) {
            let brain = self.brains.entry(chief.to_owned()).or_insert_with(Brain::new);
            if !std::mem::replace(&mut brain.lock_noted, true) {
                eprintln!("cmux-tui: Chief brain {chief} already runs (its lock is held)");
            }
            return;
        }
        match self.launch(&mux, &record) {
            Ok(process) => {
                let brain = self.brains.entry(chief.to_owned()).or_insert_with(Brain::new);
                brain.process = Some(process);
                brain.lock_noted = false;
                brain.started_at = Instant::now();
                brain.prompt = prompt_key(&record);
            }
            Err(error) => {
                eprintln!("cmux-tui: Chief brain {chief} did not start: {error:#}");
                self.brains.entry(chief.to_owned()).or_insert_with(Brain::new).back_off();
            }
        }
    }

    #[cfg(not(unix))]
    fn launch(&self, _: &Mux, _: &ChiefRecord) -> anyhow::Result<Process> {
        anyhow::bail!("Chief brains run on unix only")
    }

    #[cfg(unix)]
    fn launch(&self, mux: &Mux, record: &ChiefRecord) -> anyhow::Result<Process> {
        use std::io::Write as _;
        use std::os::unix::fs::{DirBuilderExt, OpenOptionsExt};
        use std::os::unix::process::CommandExt;

        let mux_home = brain_home(&self.config.home, &record.id);
        std::fs::DirBuilder::new().recursive(true).mode(0o700).create(&mux_home)?;
        std::fs::write(mux_home.join("chief-id"), &record.id)?;
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
            .envs(brain_environment(
                &self.config,
                &record.id,
                Some(&record.display_name),
                &inherited,
            ))
            .current_dir(&mux_home)
            .stdin(std::process::Stdio::null())
            .stdout(log.try_clone()?)
            .stderr(log)
            .process_group(0);
        let mut child = command.spawn()?;
        let pid = child.id();
        let reaped = Arc::new(Mutex::new(false));
        let (sender, chief, flag) = (self.sender.clone(), record.id.clone(), reaped.clone());
        std::thread::Builder::new().name("chief-brain-wait".into()).spawn(move || {
            let zombie = wait_exited(pid);
            {
                // The leader is a zombie now (its id is still taken): end what
                // is left of its own group (a crashed host's turn processes;
                // its acpmux has a group of its own), then mark it reaped
                // before the reap frees the id.
                let mut reaped = flag.lock().unwrap_or_else(PoisonError::into_inner);
                if zombie && let Ok(group) = i32::try_from(pid) {
                    // SAFETY: as Process::signal; the leader is not reaped yet.
                    unsafe { libc::kill(-group, libc::SIGTERM) };
                }
                *reaped = true;
            }
            let success = child.wait().is_ok_and(|status| status.success());
            let _ = sender.send(Signal::Exited { chief, pid, success });
        })?;
        Ok(Process { pid, reaped })
    }

    /// `acpmux daemon shutdown` for the brain directory `mux_home`: the brain
    /// started its acpmux in a process group of its own, so it outlives the
    /// brain. Reaped on its own thread.
    fn end_acpmux(&self, mux_home: &Path) {
        let acpmux = self.config.app.acpmux_bin.clone().unwrap_or_else(|| "acpmux".into());
        let inherited = |key: &str| std::env::var(key).ok().filter(|v| !v.is_empty());
        let env = brain_environment(&self.config, "", None, &inherited);
        let spawned = std::process::Command::new(acpmux)
            .args(["daemon", "shutdown"])
            .env_clear()
            .envs(
                env.iter()
                    .filter(|(k, _)| matches!(k.as_str(), "PATH" | "HOME" | "USER" | "TMPDIR")),
            )
            .env("ACPMUX_HOME", mux_home.join("a"))
            .stdin(std::process::Stdio::null())
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .spawn();
        if let Err(error) = &spawned {
            eprintln!(
                "cmux-tui: acpmux shutdown for {} did not start: {error}",
                mux_home.display()
            );
        }
        if let Ok(mut child) = spawned {
            let _ = std::thread::Builder::new().name("chief-acpmux-end".into()).spawn(move || {
                let _ = child.wait();
            });
        }
    }

    /// SIGTERM every brain, wait (bounded) for their exits, then SIGKILL
    /// what is left: a brain must not outlive its owner unseen.
    fn shutdown(&mut self, inbox: &mpsc::Receiver<Signal>) {
        for brain in self.brains.values_mut() {
            brain.restart = false;
            brain.pending_wake = false;
            brain.retry_at = None;
            brain.terminate();
        }
        let deadline = Instant::now() + SHUTDOWN_GRACE;
        while self.brains.values().any(|b| b.process.is_some()) {
            match inbox.recv_timeout(deadline.saturating_duration_since(Instant::now())) {
                Ok(Signal::Exited { chief, pid, .. }) => {
                    if let Some(brain) = self.brains.get_mut(&chief)
                        && brain.process.as_ref().map(|p| p.pid) == Some(pid)
                    {
                        brain.process = None;
                    }
                }
                Ok(_) => {}
                Err(_) => break,
            }
        }
        for brain in self.brains.values() {
            if let Some(process) = &brain.process {
                process.signal(SIGKILL);
            }
        }
    }
}

/// Blocks until child `pid` has exited, without reaping it (`WNOWAIT`);
/// whether it waits as a zombie now.
#[cfg(unix)]
fn wait_exited(pid: u32) -> bool {
    let id = libc::id_t::from(pid);
    loop {
        // SAFETY: a zeroed siginfo_t is a valid out buffer for waitid.
        let mut info: libc::siginfo_t = unsafe { std::mem::zeroed() };
        // SAFETY: waitid writes only into `info`; WNOWAIT leaves the child
        // waitable for Child::wait.
        let done =
            unsafe { libc::waitid(libc::P_PID, id, &mut info, libc::WEXITED | libc::WNOWAIT) };
        if done == 0 {
            return true;
        }
        if std::io::Error::last_os_error().raw_os_error() != Some(libc::EINTR) {
            return false;
        }
    }
}

/// Whether a process holds `lock` (`flock`, as optchat-chief's lock.rs
/// takes it). A missing file means no brain.
fn lock_held(lock: &Path) -> bool {
    #[cfg(unix)]
    {
        use std::os::fd::AsRawFd;
        let Ok(file) = std::fs::OpenOptions::new().read(true).open(lock) else { return false };
        // SAFETY: flock on a descriptor this function owns; it is released
        // when `file` drops.
        unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) != 0 }
    }
    #[cfg(not(unix))]
    {
        let _ = lock;
        false
    }
}

/// SIGTERM to the process that holds `lock` (a brain an earlier owner left),
/// by the pid optchat-chief writes in it.
fn stop_lock_holder(lock: &Path) {
    #[cfg(unix)]
    if lock_held(lock)
        && let Some(pid) = std::fs::read_to_string(lock)
            .ok()
            .and_then(|text| text.split_whitespace().next()?.parse::<i32>().ok())
            .filter(|pid| *pid > 1)
    {
        // SAFETY: kill and getpgid have no memory preconditions; the lock
        // is held, so its recorded holder is alive. A group leader (as this
        // supervisor starts brains) gets the signal for its whole group.
        let target = if unsafe { libc::getpgid(pid) } == pid { -pid } else { pid };
        // SAFETY: as above.
        unsafe { libc::kill(target, libc::SIGTERM) };
    }
    #[cfg(not(unix))]
    let _ = lock;
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
