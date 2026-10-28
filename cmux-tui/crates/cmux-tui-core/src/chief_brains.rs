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
//! Each brain runs in `<home>/c/<last 8 of id>`, as the participant `<id>`
//! with a token minted in process (`agent-token`, 0600). The directory is
//! short because a Unix socket lives under it (optchat/tools.sock) and a
//! socket path has at most 103 bytes; `<home>/chiefs/<id>` was 120 and more
//! on a DEV build (2026-10-14, cmux-lawrence-2).
//!
//! One acpmux per Chief home (hq-6d 2026-10-14): every brain uses the Chief
//! home's acpmux, `<home>/acpmux`, the default Chief's (one config, one
//! login-env cache, one daemon), with `OPTCHAT_ACPMUX_SHARED=1`: the brain
//! starts it when none answers and never shuts it down; each Chief's
//! sessions keep their own names and tags (its home id), and a Chief reaches
//! only its own (optchat-chief agents.rs). Delete ends that Chief's sessions
//! only (the brain's `end-sessions`). At start the supervisor removes the
//! per-Chief acpmux homes `<home>/c/<id>/a` of earlier builds (never in the
//! person's shared `~/.cmux/chief/default`).
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
//! - Stop (SIGTERM to its process group; the host ends its own sessions):
//!   `chief.profile.delete`, 30 minutes with no message and no turn, and
//!   daemon shutdown. After a delete, once the brain and its `end-sessions`
//!   ended, its folder `<home>/c/<id tail>` (memory, state, token) is removed
//!   when its `chief-id` names it and no brain holds its lock.

use std::collections::{BTreeMap, BTreeSet};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, OnceLock, PoisonError, Weak, mpsc};
use std::time::{Duration, Instant};

use cmux_agent_pane_policy::build_identity::{BuildIdentity, NIGHTLY_BUNDLE_ID};
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
    /// The person's login-shell `PATH` (the app's login environment
    /// capture; the `cmux chief` CLI's own `PATH`): after `bin_dir`, before
    /// the fixed tool directories, so the brain and its acpmux find the
    /// harnesses a terminal finds (claude under Homebrew, nvm, ...).
    pub path: Option<String>,
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

/// The Chief home of this daemon's brains config (`home`), when it runs
/// brains: the default Chief's own brain home, and the root of the others'.
pub(crate) fn configured_home() -> Option<PathBuf> {
    config().map(|config| config.home)
}

/// The brain directory of Chief `chief` under the Chief home `home`: the
/// last 8 characters of its id (40 random bits of the ULID), lowercased.
pub fn brain_home(home: &Path, chief: &str) -> PathBuf {
    let tail = chief.get(chief.len().saturating_sub(8)..).unwrap_or(chief);
    home.join("c").join(tail.to_ascii_lowercase())
}

/// The tools socket of Chief `chief`'s brain (`optchat/tools.sock` in its
/// directory), where `chief.engine.*` and `chief.stop` with `chief` go
/// (chief-brains-v1). Refused with a reason and a message when this daemon
/// runs no brains (`not_configured`) or the directory is not this Chief's
/// (`unavailable`: never started here, or another id with the same tail). A
/// brain that does not run now (idle stop, restart backoff) has a path whose
/// socket does not answer: `chief_control::ask` says `unavailable`.
pub fn tools_socket(chief: &str) -> Result<PathBuf, (&'static str, String)> {
    let config =
        config().ok_or(("not_configured", "this daemon runs no Chief brains".to_owned()))?;
    let mux_home = brain_home(&config.home, chief);
    let owner = std::fs::read_to_string(mux_home.join("chief-id")).unwrap_or_default();
    if owner.trim() != chief {
        return Err(("unavailable", format!("Chief {chief}'s brain is not running")));
    }
    Ok(mux_home.join(LONGEST_SOCKET))
}

/// The longest socket path under a brain directory (the Chief home's acpmux
/// has its own, the default Chief's). A home whose socket does not fit
/// starts no brain.
const LONGEST_SOCKET: &str = "optchat/tools.sock";
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
    // The account's home, as the app gives the default Chief's host
    // (`FileManager.homeDirectoryForCurrentUser`), not the HOME the daemon
    // inherited: an app a job runner started (nx-remote on mac26: HOME is
    // the job root) passed that on, and the brain then found no Claude
    // settings env (the person's API route) in it (hq-6d P1 2026-10-14).
    let user_home = account_home().or_else(|| inherited("HOME")).unwrap_or_else(|| "/".into());
    let mut env = BTreeMap::new();
    let mut put = |key: &str, value: String| {
        env.insert(key.to_owned(), value);
    };
    let mut path: Vec<String> = app.bin_dir.iter().map(|d| d.display().to_string()).collect();
    path.extend(
        // Absolute entries only: a relative one (`.`, `node_modules/.bin`)
        // would run a file planted in the project a turn works in.
        app.path
            .iter()
            .flat_map(|p| p.split(':'))
            .filter(|d| d.starts_with('/'))
            .map(str::to_owned),
    );
    path.extend(
        ["bin", ".local/bin", ".bun/bin", ".cargo/bin"].map(|d| format!("{user_home}/{d}")),
    );
    path.extend(
        ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
            .map(str::to_owned),
    );
    let mut seen = BTreeSet::new();
    path.retain(|d| seen.insert(d.clone()));
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
    // The Chief home's acpmux, the default Chief's (the brain derives the
    // socket from the home); shared: the brain never shuts it down.
    put("ACPMUX_HOME", config.home.join("acpmux").display().to_string());
    put("OPTCHAT_ACPMUX_SHARED", "1".into());
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

/// The home directory of this process's account in the user database
/// (getpwuid_r); None where there is none (or off Unix). A brain gets it as
/// HOME, whoever starts it (the daemon, or `cmux chief`).
pub fn account_home() -> Option<String> {
    #[cfg(unix)]
    {
        let mut buffer = vec![0 as libc::c_char; 4096];
        let mut record = std::mem::MaybeUninit::<libc::passwd>::uninit();
        let mut found: *mut libc::passwd = std::ptr::null_mut();
        // SAFETY: every pointer is valid for the call and the buffer length
        // is the buffer's length.
        let rc = unsafe {
            libc::getpwuid_r(
                libc::getuid(),
                record.as_mut_ptr(),
                buffer.as_mut_ptr(),
                buffer.len(),
                &mut found,
            )
        };
        if rc != 0 || found.is_null() {
            return None;
        }
        // SAFETY: getpwuid_r succeeded, so pw_dir points into `buffer`.
        let dir = unsafe { std::ffi::CStr::from_ptr((*found).pw_dir) };
        dir.to_str().ok().filter(|d| d.starts_with('/')).map(str::to_owned)
    }
    #[cfg(not(unix))]
    {
        None
    }
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
    /// A new Chief; `reply` hears what happened to its brain.
    Created(Box<ChiefRecord>, Option<mpsc::Sender<BrainStart>>),
    Updated(Box<ChiefRecord>),
    Deleted(String),
    /// `chief.engine.set` for this Chief: start its brain when it does
    /// not run (as a message would); `reply` hears whether a brain process
    /// runs now (or starts again after the one that is ending).
    Control(String, Option<mpsc::Sender<bool>>),
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
    /// What came before [`start`] ran (the control socket accepts clients
    /// before the owner loop starts the supervisor): a Chief created then
    /// still gets its brain. Kept only when brains are configured, at most
    /// [`EARLY_MAX`]; lock order: `sender`, then `early`.
    early: Mutex<Vec<Signal>>,
    /// The supervisor stopped ([`ChiefBrains::stop`]): no signal waits for
    /// it any more, and a new Chief's brain is answered at once.
    stopped: std::sync::atomic::AtomicBool,
}

/// What happened to a new Chief's brain (`chief.profile.create` and
/// `chief.profile.adopt` answer it as the record's `brain`): started, or not
/// with the reason (`no_supervisor`: this daemon runs no brains, or its
/// supervisor stopped; `launch_disabled`: agents are off in this build
/// session; `error`: the start failed, see the daemon log; `unconfirmed`:
/// the supervisor did not answer in time, it may still start). A create made
/// while the supervisor starts waits for its real answer.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum BrainStart {
    Started,
    NotStarted(&'static str),
}

impl BrainStart {
    pub(crate) fn wire(&self) -> serde_json::Value {
        match self {
            Self::Started => serde_json::json!({"state": "started"}),
            Self::NotStarted(reason) => {
                serde_json::json!({"state": "not_started", "reason": reason})
            }
        }
    }
}

/// A new Chief's brain outcome, known or to wait for.
pub(crate) enum BrainPending {
    Ready(BrainStart),
    Wait(mpsc::Receiver<BrainStart>),
}

impl BrainPending {
    /// The outcome; a supervisor that does not answer in 5 s is an error.
    pub(crate) fn resolve(self) -> BrainStart {
        match self {
            Self::Ready(start) => start,
            Self::Wait(answer) => answer
                .recv_timeout(Duration::from_secs(5))
                .unwrap_or(BrainStart::NotStarted("unconfirmed")),
        }
    }
}

/// The most signals [`Slot`] keeps before the supervisor starts.
const EARLY_MAX: usize = 256;

impl Slot {
    fn send(&self, signal: Signal) {
        if self.stopped.load(std::sync::atomic::Ordering::Acquire) {
            return;
        }
        let sender = self.sender.lock().unwrap_or_else(PoisonError::into_inner);
        if let Some(sender) = sender.as_ref() {
            let _ = sender.send(signal);
        } else if taken().is_some() {
            let mut early = self.early.lock().unwrap_or_else(PoisonError::into_inner);
            if early.len() < EARLY_MAX {
                early.push(signal);
            }
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

    /// `chief.engine.set` names this Chief (chief_control.rs): start its
    /// brain when it does not run now. The answer says whether a brain
    /// process runs now; `None` while the supervisor has not started yet.
    #[cfg_attr(not(unix), allow(dead_code))]
    pub(crate) fn start_for_control(&self, chief: &str) -> Option<mpsc::Receiver<bool>> {
        let sender = self.sender.lock().unwrap_or_else(PoisonError::into_inner);
        if let Some(sender) = sender.as_ref() {
            let (reply, answer) = mpsc::channel();
            let sent = sender.send(Signal::Control(chief.to_owned(), Some(reply))).is_ok();
            return sent.then_some(answer);
        }
        drop(sender);
        self.send(Signal::Control(chief.to_owned(), None));
        None
    }

    /// A committed registry write (not a replay). For a new Chief, what
    /// happens to its brain: known now, or the supervisor's answer to wait
    /// for (never under the registry lock: the supervisor reads it).
    pub(crate) fn chief_written(
        &self,
        record: &ChiefRecord,
        created: bool,
        deleted: bool,
    ) -> Option<BrainPending> {
        if deleted {
            self.send(Signal::Deleted(record.id.clone()));
            return None;
        }
        if !created {
            self.send(Signal::Updated(Box::new(record.clone())));
            return None;
        }
        let sender = self.sender.lock().unwrap_or_else(PoisonError::into_inner);
        if let Some(sender) = sender.as_ref() {
            let (reply, answer) = mpsc::channel();
            if sender.send(Signal::Created(Box::new(record.clone()), Some(reply))).is_ok() {
                return Some(BrainPending::Wait(answer));
            }
            return Some(BrainPending::Ready(BrainStart::NotStarted("error")));
        }
        if config().is_none() || self.stopped.load(std::sync::atomic::Ordering::Acquire) {
            return Some(BrainPending::Ready(BrainStart::NotStarted("no_supervisor")));
        }
        // The supervisor is still starting (the control socket accepts
        // clients before the owner loop starts it): the signal waits in
        // `early` with its reply, and `start` hands both to the supervisor,
        // which answers the real state once it handles them. Still under the
        // `sender` lock, so `start` cannot drain in between.
        // A create always waits (other early signals stop at EARLY_MAX; creates
        // are bounded by MAX_CHIEFS), so its brain is never dropped.
        let mut early = self.early.lock().unwrap_or_else(PoisonError::into_inner);
        let (reply, answer) = mpsc::channel();
        early.push(Signal::Created(Box::new(record.clone()), Some(reply)));
        drop(early);
        drop(sender);
        Some(BrainPending::Wait(answer))
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
            let slot = &mux.chiefs().brains;
            slot.stopped.store(true, std::sync::atomic::Ordering::Release);
            slot.sender.lock().unwrap_or_else(PoisonError::into_inner).take();
            slot.early.lock().unwrap_or_else(PoisonError::into_inner).clear();
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
    // Tests only (a debug build): hold the install until the test opens this
    // FIFO for writing, so a create made before it is proven to wait for the
    // supervisor's answer (tests/cli/chief_brains.rs). Opening a FIFO for
    // reading blocks until a writer comes: no sleep, no polling.
    #[cfg(debug_assertions)]
    if let Some(gate) = std::env::var_os("CMUX_TUI_TEST_CHIEF_BRAINS_GATE") {
        let _ = std::fs::File::open(gate);
    }
    let (sender, inbox) = mpsc::channel();
    {
        let slot = &mux.chiefs().brains;
        let mut installed = slot.sender.lock().unwrap_or_else(PoisonError::into_inner);
        for early in slot.early.lock().unwrap_or_else(PoisonError::into_inner).drain(..) {
            let _ = sender.send(early);
        }
        *installed = Some(sender.clone());
    }
    let mut supervisor = Supervisor {
        mux: Arc::downgrade(mux),
        socket: socket.to_owned(),
        config,
        brains: BTreeMap::new(),
        sender: sender.clone(),
    };
    let thread = std::thread::Builder::new()
        .name("chief-brains".into())
        .spawn(move || {
            // Before any brain starts: its lock probe cannot race a start.
            remove_old_acpmux_homes(
                &supervisor.config.home,
                supervisor.config.app.acpmux_bin.as_deref(),
            );
            supervisor.run(&inbox);
        })
        .ok()?;
    Some(ChiefBrains { sender, thread: Some(thread), mux: Arc::downgrade(mux) })
}

/// The engine a Chief's record names (`cmux chief new --harness unii`, the
/// `chiefs` tool's `harness`), as the brain's starting engine: the
/// `OPTCHAT_CHIEF_*` values it reads before `MUX_HARNESS` and its defaults.
/// The brain's own `engine.json` (`cmux chief engine`) still wins, so a
/// switch made later is not undone at the next start.
pub(crate) fn record_engine_env(engine: &crate::chief_registry::Engine) -> Vec<(String, String)> {
    [
        ("OPTCHAT_CHIEF_HARNESS", &engine.harness),
        ("OPTCHAT_CHIEF_MODEL", &engine.model),
        ("OPTCHAT_CHIEF_EFFORT", &engine.effort),
    ]
    .into_iter()
    .filter_map(|(key, value)| {
        let value = value.as_deref()?.trim();
        (!value.is_empty() && value != "default").then(|| (key.to_owned(), value.to_owned()))
    })
    .collect()
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
    /// The Chief was deleted: when the process ends, its sessions end too.
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
            Signal::Created(record, reply) => {
                if !is_default(&record) {
                    self.wake(&record.id);
                }
                if let Some(reply) = reply {
                    let running = self.brains.get(&record.id).is_some_and(|b| b.process.is_some());
                    let held = lock_held(
                        &brain_home(&self.config.home, &record.id).join("state/host.lock"),
                    );
                    let _ = reply.send(if running || held {
                        BrainStart::Started
                    } else if crate::agent_launch::disabled() {
                        BrainStart::NotStarted("launch_disabled")
                    } else {
                        BrainStart::NotStarted("error")
                    });
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
                self.end_sessions(&chief);
                self.brains.remove(&chief);
            }
            Signal::Control(chief, reply) => {
                // As a message: a brain that is ending (idle stop, exit 0)
                // starts again after its exit (`pending_wake`).
                self.wake(&chief);
                if let Some(reply) = reply {
                    let running = self.brains.get(&chief).is_some_and(|b| b.process.is_some());
                    let _ = reply.send(running);
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
            self.end_sessions(chief);
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
        // cx-tgf4h: no brain while agents are off in this build session (its
        // turns could not start an agent; it would only hold the message).
        if crate::agent_launch::disabled() {
            let brain = self.brains.entry(chief.to_owned()).or_insert_with(Brain::new);
            if !std::mem::replace(&mut brain.lock_noted, true) {
                eprintln!(
                    "cmux-tui: Chief brain {chief} does not start: {}",
                    crate::agent_launch::MESSAGE
                );
            }
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
            .envs(record_engine_env(&record.engine))
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

    /// Ends the sessions of Chief `chief` on the Chief home's shared acpmux
    /// (its turns, compactor and subagents; never another Chief's, never the
    /// daemon): the brain executable's `end-sessions`, as that Chief. The
    /// host ends them itself when it stops; this covers a brain that
    /// crashed or was not running. Reaped on its own thread.
    fn end_sessions(&self, chief: &str) {
        let mux_home = brain_home(&self.config.home, chief);
        if !mux_home.is_dir() {
            return;
        }
        let inherited = |key: &str| std::env::var(key).ok().filter(|v| !v.is_empty());
        let spawned = std::process::Command::new(&self.config.executable)
            .arg("end-sessions")
            .env_clear()
            .envs(brain_environment(&self.config, chief, None, &inherited))
            .current_dir(&mux_home)
            .stdin(std::process::Stdio::null())
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .spawn();
        // Only a deleted Chief's sessions end here: its folder goes after them, unless a live
        // Chief shares it (the same id tail).
        let shared = self.mux.upgrade().is_some_and(|mux| {
            list_chiefs(&mux).iter().any(|r| brain_home(&self.config.home, &r.id) == mux_home)
        });
        let owner = chief.to_owned();
        let remove = move || {
            if !shared {
                remove_brain_home(&mux_home, &owner);
            }
        };
        match spawned {
            Ok(mut child) => {
                let _ = std::thread::Builder::new().name("chief-sessions-end".into()).spawn(
                    move || {
                        let _ = child.wait();
                        remove();
                    },
                );
            }
            Err(error) => {
                eprintln!("cmux-tui: ending the sessions of Chief {chief} did not start: {error}");
                remove();
            }
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

/// Removes deleted Chief `chief`'s brain folder: a real folder only (never a link out of the
/// Chief home), whose `chief-id` names that Chief (never another Chief's with the same id tail),
/// and never while a brain still holds its lock (a stale holder that has not exited yet keeps
/// it; the folder then stays).
fn remove_brain_home(dir: &Path, chief: &str) {
    let owner = std::fs::read_to_string(dir.join("chief-id")).unwrap_or_default();
    if !std::fs::symlink_metadata(dir).is_ok_and(|m| m.is_dir())
        || owner.trim() != chief
        || lock_held(&dir.join("state/host.lock"))
    {
        return;
    }
    if let Err(error) = std::fs::remove_dir_all(dir) {
        eprintln!("cmux-tui: removing {}: {error}", dir.display());
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

/// Removes the per-Chief acpmux homes `<home>/c/<tail>/a` that brains of
/// earlier builds used (before one acpmux per Chief home): `acpmux daemon
/// shutdown --end-agents` there first (that Chief's own daemon, not the shared one),
/// then the folder. Only inside this build's Chief home `home`, never in
/// the person's shared `~/.cmux/chief/default` (NIGHTLY's), and not while
/// a brain an earlier owner left holds that Chief's lock (it still uses
/// its acpmux; a later start removes it). Runs on the supervisor thread
/// before the first brain starts.
fn remove_old_acpmux_homes(home: &Path, acpmux_bin: Option<&Path>) {
    // Without HOME the person's default home cannot be ruled out: keep all.
    let Some(user) = std::env::var_os("HOME").filter(|h| !h.is_empty()) else { return };
    // NIGHTLY's Chief home, named by the build identity resolver.
    let nightly = BuildIdentity::new(Some(NIGHTLY_BUNDLE_ID), None);
    let Ok(canonical) = std::fs::canonicalize(home) else { return };
    // NIGHTLY's home under the inherited HOME and under the account's home
    // (a job runner's HOME differs from it).
    let defaults = [Some(PathBuf::from(user)), account_home().map(PathBuf::from)];
    if defaults.into_iter().flatten().any(|user| {
        std::fs::canonicalize(nightly.chief_home(&user, "default")).ok().as_deref()
            == Some(canonical.as_path())
    }) {
        return;
    }
    let Ok(entries) = std::fs::read_dir(home.join("c")) else { return };
    for entry in entries.flatten() {
        let chief_dir = home.join("c").join(entry.file_name());
        let old = chief_dir.join("a");
        // A real folder only: never follow a link out of the Chief home.
        let is_dir = std::fs::symlink_metadata(&chief_dir).is_ok_and(|m| m.is_dir())
            && std::fs::symlink_metadata(&old).is_ok_and(|m| m.is_dir());
        if !is_dir || lock_held(&chief_dir.join("state/host.lock")) {
            continue;
        }
        let acpmux = acpmux_bin.map(Path::to_path_buf).unwrap_or_else(|| "acpmux".into());
        let user = |key: &str| std::env::var(key).ok().filter(|v| !v.is_empty());
        let stop = |end_flag: bool| {
            let mut command = std::process::Command::new(&acpmux);
            command.args(["daemon", "shutdown"]);
            if end_flag {
                command.arg("--end-agents");
            }
            command
                .env_clear()
                .env("ACPMUX_HOME", &old)
                .stdin(std::process::Stdio::null())
                .stdout(std::process::Stdio::null())
                .stderr(std::process::Stdio::null());
            for key in ["PATH", "HOME", "USER", "TMPDIR"] {
                if let Some(value) = user(key) {
                    command.env(key, value);
                }
            }
            command.status().ok()
        };
        // On this thread only: `daemon shutdown --end-agents` ends that daemon's agents
        // first (acpmux bounds its own grace), then the folder goes. An acpmux of a build
        // before the flag refuses it (usage error, exit 2); its plain shutdown ends them.
        // A stop that failed (no acpmux to ask, or no daemon there: acpmux exits 1) removes the
        // folder only when no daemon holds its lock; a running one keeps it.
        let stopped = match stop(true) {
            Some(status) if status.code() == Some(2) => stop(false),
            other => other,
        };
        if !stopped.is_some_and(|status| status.success()) && lock_held(&old.join("daemon.lock")) {
            continue;
        }
        if let Err(error) = std::fs::remove_dir_all(&old) {
            eprintln!("cmux-tui: removing {}: {error}", old.display());
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

#[cfg(test)]
mod record_engine_tests {
    use super::record_engine_env;
    use crate::chief_registry::Engine;

    #[test]
    fn a_record_harness_becomes_the_brains_starting_harness() {
        let engine =
            Engine { harness: Some("unii".into()), model: None, effort: Some("default".into()) };
        assert_eq!(
            record_engine_env(&engine),
            vec![("OPTCHAT_CHIEF_HARNESS".to_owned(), "unii".to_owned())]
        );
        assert!(record_engine_env(&Engine::default()).is_empty());
        let full = Engine {
            harness: Some("codex".into()),
            model: Some("gpt-5.5".into()),
            effort: Some("high".into()),
        };
        assert_eq!(record_engine_env(&full).len(), 3);
    }
}
