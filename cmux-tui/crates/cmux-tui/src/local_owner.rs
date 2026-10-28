//! Ensuring a detached owner process for a local session.
//!
//! A local session is owned by one headless `cmux-tui --headless` process so
//! that every interactive `cmux` on the machine is an equal client of the
//! same session: the mux survives any client detaching or exiting, and a
//! later `cmux` reattaches through the same socket instead of racing to
//! rebuild the mux and adopt the durable terminal hosts. `ensure_owner` is
//! the single entrypoint shared by the interactive startup path and the
//! `cmux daemon ensure` CLI verb (`cmux-tui server ensure`).
//!
//! The owner is spawned with no controlling terminal and null stdio; its
//! diagnostics go to the bounded client log at the session state root.
//! Concurrent ensures serialize on a lock file next to the socket, because
//! the server's stale-socket recovery (probe, unlink, bind) is not atomic:
//! without the lock, two racing owners could both bind, one of them on an
//! already-unlinked socket path that no client can ever reach. Every holder
//! keeps that lock only for moments: an ensure across one probe and the
//! spawn, an owner across its bind. An owner binds its socket before it
//! restores its session (cx-n3bs) and holds connections unanswered until the
//! restore ends (then `identify` reports `lifecycle_ready: false` until
//! startup ends), so ensure reads a live but silent socket as a starting
//! owner, waits for it outside the lock, and never mistakes it for an absent
//! one.

use std::io;
use std::io::{BufRead, BufReader, Read, Write};
use std::path::PathBuf;
use std::time::{Duration, Instant};

use cmux_process::{Command, Stdio};
use cmux_tui_core::platform::{self, transport};
use serde_json::Value;

/// Time to reach an owner: for an owner this call spawns, from the spawn
/// until it answers on its socket (it binds before its restore, so this is
/// process start, not restore). Each identify exchange is bounded by it too.
/// Matches the lifecycle CLI exchange deadline. The restore itself is
/// bounded by `RESTORE_DEADLINE`.
pub(crate) const ENSURE_DEADLINE: Duration = Duration::from_secs(10);

/// Upper bound on the wait for an owner that is alive but still restoring
/// its session (registry, terminal host adoption) before it accepts clients.
/// Once an owner accepts a connection but its identify times out (restoring)
/// or answers `lifecycle_ready: false`, ensure
/// waits for its restore up to this bound instead of reporting the owner
/// unavailable (cx-w760: a slow box took over 10 s to restore after a
/// restart, and the first ensure failed).
pub(crate) const RESTORE_DEADLINE: Duration = Duration::from_secs(120);

/// How often a waiting ensure reports that the owner is still restoring
/// (`RestoreProgress`). A client that watches these reports (the app runs
/// `server ensure --restore-progress`) bounds its wait by their absence, not by a
/// fixed timeout shorter than `RESTORE_DEADLINE`.
pub(crate) const PROGRESS_INTERVAL: Duration = Duration::from_secs(5);

/// The owner is alive and still restoring its session.
pub(crate) struct Restoring {
    /// The owner's pid when known (its socket identity or this call's spawn).
    pub pid: Option<u64>,
    /// Time since this ensure started waiting on the restore.
    pub waited: Duration,
}

/// Reports a restoring owner to the caller: the first sighting at once, then
/// at most once per `PROGRESS_INTERVAL`.
pub(crate) struct RestoreProgress<'a> {
    report: &'a dyn Fn(&Restoring),
    first: std::cell::Cell<Option<Instant>>,
    last: std::cell::Cell<Option<Instant>>,
}

impl<'a> RestoreProgress<'a> {
    pub(crate) fn new(report: &'a dyn Fn(&Restoring)) -> Self {
        Self { report, first: std::cell::Cell::new(None), last: std::cell::Cell::new(None) }
    }

    /// No reports (callers that show nothing while they wait).
    pub(crate) fn silent() -> RestoreProgress<'static> {
        fn ignore(_: &Restoring) {}
        RestoreProgress::new(&ignore)
    }

    fn restoring(&self, pid: Option<u64>) {
        let now = Instant::now();
        let first = self.first.get().unwrap_or(now);
        self.first.set(Some(first));
        // A few ms of slack: a wait slice that ends just short of the
        // interval must not skip every other report.
        let slack = Duration::from_millis(50);
        if self.last.get().is_some_and(|last| now.duration_since(last) + slack < PROGRESS_INTERVAL)
        {
            return;
        }
        self.last.set(Some(now));
        (self.report)(&Restoring { pid, waited: now.duration_since(first) });
    }
}

/// Probe interval while an owner this process did not start is still
/// starting. That owner's readiness is announced only to its own parent
/// (`OWNER_READY_FD_ARG`); the socket has no readiness event, so a second
/// client re-asks. An owner this process spawns is awaited on its pipe.
const POLL_INTERVAL: Duration = Duration::from_millis(25);

/// Windows has no readiness pipe or `waitid`: the spawned owner is probed
/// like a foreign one and the reaper ticks.
#[cfg(not(unix))]
const REAP_INTERVAL: Duration = Duration::from_secs(1);
const RESPONSE_LIMIT: usize = 16 * 1024 * 1024;

/// Private startup option: the detached owner writes one byte to this
/// inherited descriptor once it accepts clients, then closes it. End of
/// file first means the owner exited (a lost bind race or a crash).
pub(crate) const OWNER_READY_FD_ARG: &str = "--owner-ready-fd";

mod install_key;
#[cfg(windows)]
mod job_breakaway;
mod replace;
pub(crate) use install_key::{OWNER_INSTALL_KEY_FD_ARG, install_key_from_launcher};
pub(crate) use replace::{ReplaceError, replace_if_unresponsive};

/// Takes an inherited descriptor (`option` names it) from argv and keeps it
/// out of every process the owner starts (terminal hosts): only this owner
/// holds the readiness pipe's write end and the install key pipe.
pub(crate) fn claim_inherited_fd(option: &str, value: &str) -> Result<i32, String> {
    let fd: i32 = value
        .parse()
        .ok()
        .filter(|fd| *fd > 2)
        .ok_or_else(|| format!("{option} needs a descriptor number above 2"))?;
    #[cfg(unix)]
    {
        // SAFETY: fcntl on a descriptor number only changes its flags; an
        // invalid descriptor reports EBADF.
        if unsafe { libc::fcntl(fd, libc::F_SETFD, libc::FD_CLOEXEC) } != 0 {
            return Err(format!("{option} {fd}: {}", io::Error::last_os_error()));
        }
    }
    Ok(fd)
}

/// Whether `arg` is a private owner startup option `claim_owner_arg` parses.
pub(crate) fn is_owner_arg(arg: &str) -> bool {
    arg == OWNER_READY_FD_ARG || arg == OWNER_INSTALL_KEY_FD_ARG || install_key::is_stdin_arg(arg)
}

/// Parses `OWNER_READY_FD_ARG`, `OWNER_INSTALL_KEY_FD_ARG` (each once,
/// taking its value from `values`) or, on Windows, the value-less
/// `OWNER_INSTALL_KEY_STDIN_ARG`.
pub(crate) fn claim_owner_arg(
    arg: &str,
    values: &mut impl Iterator<Item = String>,
    args: &mut crate::Args,
) -> Result<(), String> {
    if install_key::is_stdin_arg(arg) {
        return install_key::claim_install_key_stdin();
    }
    let value = values.next().ok_or_else(|| format!("{arg} needs a value"))?;
    let fd = claim_inherited_fd(arg, &value)?;
    let slot = if arg == OWNER_READY_FD_ARG {
        &mut args.owner_ready_fd
    } else {
        &mut args.owner_install_key_fd
    };
    if slot.replace(fd).is_some() {
        return Err(format!("{arg} may be supplied only once"));
    }
    Ok(())
}

/// Tells the parent that spawned this owner that it accepts clients.
pub(crate) fn signal_ready(fd: i32) {
    #[cfg(unix)]
    {
        use std::os::fd::FromRawFd;
        // SAFETY: `claim_inherited_fd` validated this inherited descriptor, and
        // this is its only use; the File closes it.
        let mut pipe = unsafe { std::fs::File::from_raw_fd(fd) };
        let _ = pipe.write_all(b"1");
    }
    #[cfg(not(unix))]
    let _ = fd;
}

/// `server ensure --ws-loopback [--ws-allow-origin <origin>[,<origin>...]]` (private app
/// contract, cx-hnmbt.2): the owner opens `--ws 127.0.0.1:0` and, with no
/// token configured, mints its credential into a 0600 file next to the
/// socket (`websocket_credential`), never on argv.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct EnsureWebSocket {
    /// The extra page origins the listener accepts (the app's first-party
    /// pages, `cmux-page://cmux.<page>`).
    pub allow_origins: Vec<String>,
}

/// How the owner process is launched.
pub(crate) struct OwnerSpec {
    pub session: String,
    pub socket: PathBuf,
    pub socket_is_derived: bool,
    pub state: Option<PathBuf>,
    pub term: Option<String>,
    /// Host colors sampled by the first interactive client. The detached
    /// owner has no terminal of its own, so the client passes these values
    /// through the private startup contract before it creates a PTY.
    pub initial_host_colors: Option<cmux_tui_core::DefaultColors>,
    /// `--terminal-reap-grace-seconds` for the owner. Reaping is opt-in, so
    /// `None` starts an owner that never reaps unplaced terminals.
    pub terminal_reap_grace: Option<Duration>,
    /// The app's install key for an owner this call spawns (`server ensure
    /// --install-key-stdin`); a running owner never receives it.
    pub install_key: Option<cmux_tui_core::server::FrontendKey>,
    /// `CMUX_TUI_CHIEF_TOOLS_SOCKET` for an owner this call spawns: the
    /// Chief brain's tools socket, so the owner serves chief.engine.* and
    /// chief.stop (only `cmux chief` sets it, for its Chief home's owner).
    pub chief_tools_socket: Option<PathBuf>,
    /// `CMUX_TUI_CHIEF_BRAINS` for an owner this call spawns: the daemon
    /// starts the brains of the Chiefs that are not the default
    /// (cmux-tui-core chief_brains).
    pub chief_brains: Option<String>,
    /// The loopback WebSocket listener for an owner this call spawns; a
    /// running owner keeps the listener it was started with.
    pub websocket: Option<EnsureWebSocket>,
}

/// A validated, client-ready owner.
pub(crate) struct ReadyOwner {
    pub session: String,
    pub pid: u64,
    pub generation: String,
}

pub(crate) enum Ensured {
    /// A ready owner already served the socket.
    Running(ReadyOwner),
    /// This call spawned the owner.
    Started(ReadyOwner),
}

pub(crate) enum EnsureError {
    /// The owner process could not be spawned (or the spawn lock failed).
    Spawn(io::Error),
    /// The deadline elapsed before the owner accepted clients.
    NotReady,
    /// An owner was alive but did not finish restoring its session within
    /// `RESTORE_DEADLINE`.
    RestoreTimeout,
    /// The socket is served by something that is not a cmux-tui server.
    WrongOwner,
    /// The socket is served by a different session than requested.
    DifferentSession,
    /// The socket's owner serves another state dir than requested, for
    /// example one deleted and created again at the same path (cx-t1ok).
    DifferentState,
    /// The server identity was missing required lifecycle fields.
    InvalidIdentity,
    /// The server speaks a protocol incompatible with this client.
    UnsupportedProtocol,
}

/// One connect-and-identify attempt against the session socket.
enum Attempt {
    /// Nothing serves the socket: the connect failed (missing file, refused).
    /// An owner seen restoring before has exited.
    Gone,
    /// A connection was accepted but closed or broke before an identity came
    /// back: a stale or dying peer, or a live owner refusing extra clients.
    Unanswered,
    /// A cmux-tui server answered but is not lifecycle-ready yet (its pid
    /// when its identity carried one).
    Starting(Option<u64>),
    Ready(ReadyOwner),
}

/// Connect to a ready owner for `spec.session` on `spec.socket`, spawning a
/// detached headless owner process when none is running. `expected_session`
/// is the caller's session constraint for a server that is already running;
/// an owner spawned here is always validated against `spec.session`.
/// `deadline` bounds reaching an owner (`ENSURE_DEADLINE`); a live owner's
/// restore is awaited up to `RESTORE_DEADLINE`.
pub(crate) fn ensure_owner(
    spec: &OwnerSpec,
    expected_session: Option<&str>,
    deadline: Instant,
    progress: &RestoreProgress<'_>,
) -> Result<Ensured, EnsureError> {
    cmux_tui_core::server::prepare_socket_parent(&spec.socket, spec.socket_is_derived)
        .map_err(|error| EnsureError::Spawn(io::Error::other(error)))?;
    let restore_deadline = deadline.max(Instant::now() + RESTORE_DEADLINE);
    let owner = loop {
        if let Some(ready) =
            wait_while_starting(spec, expected_session, restore_deadline, progress)?
        {
            return Ok(Ensured::Running(ready));
        }
        if Instant::now() >= restore_deadline {
            return Err(EnsureError::RestoreTimeout);
        }
        // Every holder keeps this lock only across a probe and a spawn or a
        // bind, so the start lock's own short bound applies.
        let lock = cmux_tui_core::server::SocketStartLock::acquire(
            &spec.socket,
            Instant::now() + cmux_tui_core::server::START_LOCK_DEADLINE,
        )
        .map_err(EnsureError::Spawn)?;
        // One probe under the lock: a concurrent ensure may have spawned the
        // owner while this call waited for the lock. A restoring owner is
        // awaited outside the lock (next turn), never while holding it.
        match attempt(spec, expected_session, attempt_deadline(restore_deadline))? {
            Attempt::Ready(ready) => return Ok(Ensured::Running(ready)),
            Attempt::Starting(pid) => {
                progress.restoring(pid);
                drop(lock);
                cmux_blocking::thread::sleep(POLL_INTERVAL);
                continue;
            }
            // The lock is released once the spawn is issued. A redundant
            // owner spawned by a racing ensure finds the socket live at its
            // bind, exits before it restores anything, and every caller
            // converges on the winner through the probes below.
            Attempt::Gone | Attempt::Unanswered => {
                let owner = spawn_detached_owner(spec).map_err(EnsureError::Spawn);
                drop(lock);
                break owner?;
            }
        }
    };
    // The spawned owner binds at process start; give it the full contact
    // bound from now, even when this call already waited on an earlier owner.
    let contact_deadline = deadline.max(Instant::now() + ENSURE_DEADLINE);
    let ready = match owner.ready.as_ref() {
        Some(pipe) => wait_for_spawned_owner(
            pipe,
            owner.pid,
            spec,
            contact_deadline,
            restore_deadline,
            progress,
        ),
        None => wait_until_ready(
            spec,
            Some(&spec.session),
            &|| owner.exited(),
            contact_deadline,
            restore_deadline,
            progress,
        ),
    };
    match ready {
        Ok(Some(ready)) => Ok(Ensured::Started(ready)),
        Ok(None) => {
            owner.terminate();
            Err(EnsureError::NotReady)
        }
        Err(error) => {
            owner.terminate();
            Err(error)
        }
    }
}

/// One identify exchange never waits longer than the contact deadline: a
/// busy peer reads as starting and is asked again, so a wedged peer cannot
/// hold one attempt for the whole restore bound.
fn attempt_deadline(restore_deadline: Instant) -> Instant {
    restore_deadline.min(Instant::now() + ENSURE_DEADLINE)
}

/// Poll while a live server reports it is still starting (restoring its
/// session). `Ok(None)` means nothing serves the socket; the caller decides
/// whether to spawn. `restore_deadline` bounds the wait for a live owner.
fn wait_while_starting(
    spec: &OwnerSpec,
    expected_session: Option<&str>,
    restore_deadline: Instant,
    progress: &RestoreProgress<'_>,
) -> Result<Option<ReadyOwner>, EnsureError> {
    loop {
        match attempt(spec, expected_session, attempt_deadline(restore_deadline))? {
            Attempt::Ready(ready) => return Ok(Some(ready)),
            Attempt::Gone | Attempt::Unanswered => return Ok(None),
            Attempt::Starting(pid) => progress.restoring(pid),
        }
        if Instant::now() >= restore_deadline {
            return Err(EnsureError::RestoreTimeout);
        }
        cmux_blocking::thread::sleep(POLL_INTERVAL);
    }
}

/// Poll until the freshly spawned owner accepts clients. Before any owner
/// answers, the wait is bounded by `contact_deadline`; an owner that answers
/// but is still restoring is awaited until `restore_deadline`. An owner seen
/// restoring that then vanishes from the socket ends the restore wait at
/// once: the contact bound applies again, and when the spawned process has
/// exited too (`owner_exited`) ensure fails now instead of waiting.
fn wait_until_ready(
    spec: &OwnerSpec,
    expected_session: Option<&str>,
    owner_exited: &dyn Fn() -> bool,
    contact_deadline: Instant,
    restore_deadline: Instant,
    progress: &RestoreProgress<'_>,
) -> Result<Option<ReadyOwner>, EnsureError> {
    let mut seen_alive = false;
    loop {
        match attempt(spec, expected_session, attempt_deadline(restore_deadline))? {
            Attempt::Ready(ready) => return Ok(Some(ready)),
            Attempt::Starting(pid) => {
                seen_alive = true;
                progress.restoring(pid);
            }
            // Accepted but unanswered: keep what is known about the owner.
            Attempt::Unanswered => {}
            Attempt::Gone => {
                seen_alive = false;
                if owner_exited() {
                    return Ok(None);
                }
            }
        }
        let now = Instant::now();
        if seen_alive && now >= restore_deadline {
            return Err(EnsureError::RestoreTimeout);
        }
        if !seen_alive && now >= contact_deadline {
            return Ok(None);
        }
        cmux_blocking::thread::sleep(POLL_INTERVAL);
    }
}

/// Waits on the spawned owner's readiness pipe, not on a timer. A byte means
/// the owner accepts clients; end of file means it exited, and whoever won
/// the bind (another ensure's owner) is found by probing.
#[cfg(unix)]
fn wait_for_spawned_owner(
    pipe: &std::fs::File,
    pid: u32,
    spec: &OwnerSpec,
    contact_deadline: Instant,
    restore_deadline: Instant,
    progress: &RestoreProgress<'_>,
) -> Result<Option<ReadyOwner>, EnsureError> {
    let expected = Some(spec.session.as_str());
    // The pipe stays open while the owner lives, and the owner writes its
    // byte only after its restore, so a live owner is awaited up to the
    // restore bound, never killed at the shorter contact bound (cx-w760).
    // The wait wakes once per progress interval to report the live owner.
    let started = Instant::now();
    loop {
        let slice = restore_deadline.min(Instant::now() + PROGRESS_INTERVAL);
        if wait_readable(pipe, slice) {
            break;
        }
        if Instant::now() >= restore_deadline {
            return Err(EnsureError::RestoreTimeout);
        }
        // Silent for the first slice: a quick owner start is not a restore.
        if started.elapsed() + Duration::from_millis(50) >= PROGRESS_INTERVAL {
            progress.restoring(Some(u64::from(pid)));
        }
    }
    let mut byte = [0_u8; 1];
    let signaled = matches!((&*pipe).read(&mut byte), Ok(1));
    if signaled
        && let Attempt::Ready(ready) = attempt(spec, expected, attempt_deadline(restore_deadline))?
    {
        return Ok(Some(ready));
    }
    // End of file: this owner exited. It lost the bind to a racing ensure's
    // owner (which announces readiness only to its own parent), or crashed.
    wait_until_ready(spec, expected, &|| true, contact_deadline, restore_deadline, progress)
}

/// Whether `pipe` became readable (a byte or end of file) before `deadline`.
#[cfg(unix)]
fn wait_readable(pipe: &std::fs::File, deadline: Instant) -> bool {
    use std::os::fd::AsRawFd;
    loop {
        let remaining = deadline.saturating_duration_since(Instant::now());
        // Round up: a rounded-down wait ends before `deadline`.
        let timeout = i32::try_from(remaining.as_nanos().div_ceil(1_000_000)).unwrap_or(i32::MAX);
        let mut poll = libc::pollfd { fd: pipe.as_raw_fd(), events: libc::POLLIN, revents: 0 };
        // SAFETY: one valid pollfd for the lifetime of the call.
        match unsafe { libc::poll(&mut poll, 1, timeout) } {
            0 => return false,
            result if result > 0 => return true,
            _ if io::Error::last_os_error().kind() == io::ErrorKind::Interrupted => {}
            _ => return true,
        }
    }
}

/// No readiness pipe exists off Unix (`SpawnedOwner::ready` is always
/// `None` there), so this is never called.
#[cfg(not(unix))]
fn wait_for_spawned_owner(
    pipe: &std::convert::Infallible,
    _pid: u32,
    _spec: &OwnerSpec,
    _contact_deadline: Instant,
    _restore_deadline: Instant,
    _progress: &RestoreProgress<'_>,
) -> Result<Option<ReadyOwner>, EnsureError> {
    match *pipe {}
}

fn attempt(
    spec: &OwnerSpec,
    expected_session: Option<&str>,
    deadline: Instant,
) -> Result<Attempt, EnsureError> {
    let stream =
        match cmux_tui_core::server::connect_session_socket(&spec.socket, spec.socket_is_derived) {
            Ok(stream) => stream,
            Err(_) => return Ok(Attempt::Gone),
        };
    let identity = match identify(stream, deadline) {
        Ok(identity) => identity,
        // A timeout is a live but busy server; anything else on a fresh
        // connection is a dying or stale peer (or a full one).
        Err(IdentifyError::Timeout) => return Ok(Attempt::Starting(None)),
        Err(IdentifyError::Failed) => return Ok(Attempt::Unanswered),
    };
    if identity["app"] != "cmux-tui" {
        return Err(EnsureError::WrongOwner);
    }
    if identity.get("protocol").and_then(Value::as_u64)
        != Some(u64::from(cmux_tui_core::server::PROTOCOL_VERSION))
    {
        return Err(EnsureError::UnsupportedProtocol);
    }
    // Servers on this protocol always report lifecycle readiness, so a
    // missing or malformed field is a broken identity, never "ready".
    match identity.get("lifecycle_ready") {
        Some(Value::Bool(false)) => {
            return Ok(Attempt::Starting(identity.get("pid").and_then(Value::as_u64)));
        }
        Some(Value::Bool(true)) => {}
        _ => return Err(EnsureError::InvalidIdentity),
    }
    let session = identity["session"].as_str().unwrap_or_default();
    if session.is_empty() {
        return Err(EnsureError::InvalidIdentity);
    }
    if expected_session.is_some_and(|expected| session != expected) {
        return Err(EnsureError::DifferentSession);
    }
    if !serves_requested_state(spec, session, &identity) {
        return Err(EnsureError::DifferentState);
    }
    let Some(pid) = identity["pid"].as_u64() else {
        return Err(EnsureError::InvalidIdentity);
    };
    let Some(generation) = identity["generation"].as_str().filter(|value| !value.is_empty()) else {
        return Err(EnsureError::InvalidIdentity);
    };
    Ok(Attempt::Ready(ReadyOwner {
        session: session.to_string(),
        pid,
        generation: generation.to_string(),
    }))
}

/// Whether the owner's registry is the one stored in the requested state
/// dir. An owner always writes its registry before it is lifecycle-ready, so
/// a missing registry or another id there means the owner serves other state
/// (a deleted and recreated home keeps the socket path but not the registry).
/// An unreadable registry is not proof of a mismatch and keeps the owner.
fn serves_requested_state(spec: &OwnerSpec, session: &str, identity: &Value) -> bool {
    let Some(running) = identity.get("registry_id").and_then(Value::as_str) else {
        return true;
    };
    let Some(root) = spec.state.clone().or_else(platform::workspace_state_dir) else {
        return true;
    };
    match cmux_tui_core::WorkspaceRegistry::stored_registry_id(&root, session) {
        Ok(stored) => stored.as_deref() == Some(running),
        Err(_) => true,
    }
}

enum IdentifyError {
    Timeout,
    Failed,
}

/// Run one identify exchange on a fresh connection with a bounded timeout.
fn identify(stream: Box<dyn transport::Stream>, deadline: Instant) -> Result<Value, IdentifyError> {
    let timeout =
        Some(deadline.saturating_duration_since(Instant::now()).min(Duration::from_secs(2)));
    stream.set_read_timeout(timeout).map_err(|_| IdentifyError::Failed)?;
    stream.set_write_timeout(timeout).map_err(|_| IdentifyError::Failed)?;
    let mut connection = BufReader::new(stream);
    writeln!(connection.get_mut(), "{}", serde_json::json!({"id":1,"cmd":"identify"}))
        .and_then(|()| connection.get_mut().flush())
        .map_err(|_| IdentifyError::Failed)?;
    loop {
        let mut bytes = Vec::new();
        let remaining = deadline.saturating_duration_since(Instant::now());
        if remaining.is_zero() {
            return Err(IdentifyError::Timeout);
        }
        connection
            .get_mut()
            .set_read_timeout(Some(remaining.min(Duration::from_secs(2))))
            .map_err(|_| IdentifyError::Failed)?;
        match connection.by_ref().take((RESPONSE_LIMIT + 2) as u64).read_until(b'\n', &mut bytes) {
            Ok(0) => return Err(IdentifyError::Failed),
            Ok(_) => {}
            Err(error)
                if matches!(error.kind(), io::ErrorKind::TimedOut | io::ErrorKind::WouldBlock) =>
            {
                return Err(IdentifyError::Timeout);
            }
            Err(_) => return Err(IdentifyError::Failed),
        }
        if bytes.len() > RESPONSE_LIMIT || !bytes.ends_with(b"\n") {
            return Err(IdentifyError::Failed);
        }
        let Ok(response) = serde_json::from_slice::<Value>(&bytes) else {
            return Err(IdentifyError::Failed);
        };
        if response.get("event").is_some() || response["id"] != 1 {
            continue;
        }
        if response["ok"] == true {
            return Ok(response.get("data").cloned().unwrap_or(Value::Null));
        }
        return Err(IdentifyError::Failed);
    }
}

/// Spawn the headless owner detached from this process's terminal.
struct OwnerProcessState {
    child: std::sync::Mutex<Option<cmux_process::Child>>,
    #[cfg(not(unix))]
    wake: std::sync::Condvar,
    #[cfg(not(unix))]
    terminate: std::sync::atomic::AtomicBool,
}

struct SpawnedOwner {
    state: std::sync::Arc<OwnerProcessState>,
    /// The owner's process id.
    pid: u32,
    /// Read end of the owner's readiness pipe (`OWNER_READY_FD_ARG`).
    #[cfg(unix)]
    ready: Option<std::fs::File>,
    #[cfg(not(unix))]
    ready: Option<std::convert::Infallible>,
}

const DETACHED_OWNER_IDENTITY_ENV: [&str; 5] =
    ["CMUX_SURFACE_ID", "CMUX_WORKSPACE_ID", "CMUX_TAB_ID", "CMUX_PANEL_ID", "CMUX_PANE_ID"];

/// Remove terminal identity and agent caller claims
/// (`startup_env::AGENT_CALLER_ENV`, cx-4nar) from the detached owner while
/// preserving configuration and socket variables inherited from the
/// launching client.
fn configure_detached_owner_environment(command: &mut Command) {
    for key in DETACHED_OWNER_IDENTITY_ENV.into_iter().chain(crate::startup_env::AGENT_CALLER_ENV) {
        command.env_remove(key);
    }
}

impl SpawnedOwner {
    /// Whether the owner process has exited (and been reaped).
    fn exited(&self) -> bool {
        self.state.child.lock().map(|child| child.is_none()).unwrap_or(true)
    }

    fn terminate(self) {
        #[cfg(not(unix))]
        self.state.terminate.store(true, std::sync::atomic::Ordering::Release);
        // Reap synchronously instead of waiting for the reaper thread: this
        // must terminate the owner even when that thread could not be
        // created. The owner is still unreaped here (the reaper takes the
        // child out of the slot before reaping), so its pid is still its own.
        let mut child = self.state.child.lock().expect("owner mutex poisoned");
        if let Some(mut process) = child.take() {
            let _ = process.kill();
            let _ = process.wait();
        }
        #[cfg(not(unix))]
        self.state.wake.notify_all();
    }
}

/// The descriptor number the owner gets its readiness pipe's write end at.
#[cfg(unix)]
const OWNER_READY_FD: std::os::fd::RawFd = 3;

/// The readiness pipe: the read end stays here, the write end goes to the
/// owner only, as `OWNER_READY_FD` (`Command::inherit_fd`).
#[cfg(unix)]
fn ready_pipe(command: &mut Command) -> io::Result<(std::fs::File, io::PipeWriter)> {
    use std::os::fd::{AsFd, OwnedFd};
    let (reader, writer) = io::pipe()?;
    command.arg(OWNER_READY_FD_ARG).arg(OWNER_READY_FD.to_string());
    command.inherit_fd(writer.as_fd(), OWNER_READY_FD)?;
    Ok((std::fs::File::from(OwnedFd::from(reader)), writer))
}

fn spawn_detached_owner(spec: &OwnerSpec) -> io::Result<SpawnedOwner> {
    let program = platform::self_exe_for_spawn()?;
    let mut command = Command::new(program);
    command.arg("--headless");
    command.arg("--session").arg(&spec.session);
    command.arg("--socket").arg(&spec.socket);
    if let Some(state) = &spec.state {
        command.arg("--state").arg(state);
    }
    if let Some(term) = &spec.term {
        command.arg("--term").arg(term);
    }
    if let Some(grace) = spec.terminal_reap_grace {
        command.arg("--terminal-reap-grace-seconds").arg(grace.as_secs().to_string());
    }
    if let Some(websocket) = &spec.websocket {
        command.arg("--ws").arg("127.0.0.1:0");
        for origin in &websocket.allow_origins {
            command.arg("--ws-allow-origin").arg(origin);
        }
    }
    if let Some(colors) = spec.initial_host_colors {
        if let Some(foreground) = colors.fg {
            command
                .arg("--owner-host-fg")
                .arg(format!("#{:02x}{:02x}{:02x}", foreground.r, foreground.g, foreground.b));
        }
        if let Some(background) = colors.bg {
            command
                .arg("--owner-host-bg")
                .arg(format!("#{:02x}{:02x}{:02x}", background.r, background.g, background.b));
        }
    }
    configure_detached_owner_environment(&mut command);
    if let Some(tools) = &spec.chief_tools_socket {
        command.env("CMUX_TUI_CHIEF_TOOLS_SOCKET", tools);
    }
    if let Some(brains) = &spec.chief_brains {
        command.env(cmux_tui_core::chief_brains::ENV, brains);
    }
    // The app directory settings this client took at start go to the owner
    // daemon it spawns only (cx-e0cs): the owner takes them out of its own
    // environment again and applies the bundle rule (first_party_dir).
    if let Some(dir) = cmux_tui_core::first_party_dir::taken() {
        command.env(cmux_tui_core::first_party_dir::ENV, dir);
    }
    if let Some(dirs) = cmux_tui_core::first_party_dir::apps_dirs() {
        command.env(cmux_tui_core::first_party_dir::DIRS_ENV, dirs);
    }
    // So is the owning app's pid (startup_env.rs): only that owner gets it.
    if let Some(pid) = crate::startup_env::owner_app_pid() {
        command.env(crate::startup_env::OWNER_APP_PID_ENV, pid);
    }
    #[cfg(unix)]
    let (ready, ready_writer) = ready_pipe(&mut command)?;
    #[cfg(unix)]
    let _install_key_pipe = match &spec.install_key {
        Some(key) => Some(install_key::install_key_pipe(&mut command, key)?),
        None => None,
    };
    #[cfg(not(unix))]
    let ready = None;
    // The owner reports through the bounded client log at its state root;
    // terminal teardown must never reach it, so it gets no stdio and (on
    // Unix) its own session, free of the controlling terminal. On Windows
    // its stdin is the install key pipe when there is a key.
    #[cfg(windows)]
    if spec.install_key.is_some() {
        command.arg(install_key::OWNER_INSTALL_KEY_STDIN_ARG);
    }
    #[cfg(unix)]
    {
        set_owner_stdio(&mut command, spec);
        command.new_session();
    }
    #[cfg(windows)]
    install_key::keep_std_handles_from_children();
    #[cfg(unix)]
    let child = command.spawn()?;
    #[cfg(windows)]
    let mut child = job_breakaway::spawn_owner_out_of_callers_job(&mut command, spec)?;
    // Only the owner holds the write end now (the builder's copy went to the
    // spawn), so end of file means it exited.
    #[cfg(unix)]
    drop(ready_writer);
    #[cfg(windows)]
    install_key::send_over_stdin(&mut child, spec.install_key.as_ref());
    let pid = child.id();
    // The owner outlives this process. Reap it in the background so an
    // owner that exits early (for example after losing the bind race) never
    // lingers as a zombie of a long-lived interactive client.
    let state = std::sync::Arc::new(OwnerProcessState {
        child: std::sync::Mutex::new(Some(child)),
        #[cfg(not(unix))]
        wake: std::sync::Condvar::new(),
        #[cfg(not(unix))]
        terminate: std::sync::atomic::AtomicBool::new(false),
    });
    let reaper_state = std::sync::Arc::clone(&state);
    #[cfg(unix)]
    let reaper = move || reap_on_exit(&reaper_state, pid);
    #[cfg(not(unix))]
    let reaper = move || reap_on_tick(&reaper_state);
    if let Err(_error) =
        std::thread::Builder::new().name("local-owner-reaper".to_string()).spawn(reaper)
    {
        // If the helper thread cannot be created, reap synchronously before
        // returning. This preserves the no-zombie guarantee even under
        // thread exhaustion; the owner has already been detached from the
        // caller's terminal and cannot report through its stdio.
        SpawnedOwner { state: std::sync::Arc::clone(&state), pid, ready: None }.terminate();
        return Err(io::Error::other("local owner reaper unavailable"));
    }
    #[cfg(unix)]
    let ready = Some(ready);
    Ok(SpawnedOwner { state, pid, ready })
}

/// The owner's stdio: none, except on Windows the install key pipe as stdin
/// when there is a key. A spawn uses the streams up, so a second spawn of
/// the same command sets them again.
fn set_owner_stdio(command: &mut Command, spec: &OwnerSpec) {
    command.stdin(Stdio::null()).stdout(Stdio::null()).stderr(Stdio::null());
    #[cfg(windows)]
    if spec.install_key.is_some() {
        command.stdin(Stdio::piped());
    }
    #[cfg(not(windows))]
    let _ = spec;
}

/// Blocks until the owner exits, without reaping it (`WNOWAIT`), so a
/// concurrent `terminate` can still signal the pid safely; then reaps it
/// unless `terminate` already did. No timer wakes this thread.
#[cfg(unix)]
fn reap_on_exit(state: &OwnerProcessState, pid: u32) {
    let pid = libc::id_t::from(pid);
    loop {
        // SAFETY: waitid writes only into the zeroed siginfo it is given.
        let mut info = unsafe { std::mem::zeroed::<libc::siginfo_t>() };
        // SAFETY: waitid writes one siginfo_t into `info`, a live local; WNOWAIT leaves the child
        // unreaped.
        let result =
            unsafe { libc::waitid(libc::P_PID, pid, &mut info, libc::WEXITED | libc::WNOWAIT) };
        if result == 0 || io::Error::last_os_error().kind() != io::ErrorKind::Interrupted {
            break;
        }
    }
    if let Some(mut process) = state.child.lock().expect("owner mutex poisoned").take() {
        let _ = process.wait();
    }
}

#[cfg(not(unix))]
fn reap_on_tick(state: &OwnerProcessState) {
    let mut child = state.child.lock().expect("owner mutex poisoned");
    while let Some(process) = child.as_mut() {
        if state.terminate.load(std::sync::atomic::Ordering::Acquire) {
            let _ = process.kill();
        }
        let exited = match process.try_wait() {
            Ok(Some(_)) | Err(_) => true,
            Ok(None) => false,
        };
        if exited {
            child.take();
            state.wake.notify_all();
            break;
        }
        child = state.wake.wait_timeout(child, REAP_INTERVAL).expect("owner condvar poisoned").0;
    }
}

#[cfg(test)]
mod tests {
    use std::ffi::OsString;

    use cmux_process::Command;

    use super::configure_detached_owner_environment;

    #[cfg(unix)]
    mod event_driven {
        use std::os::fd::IntoRawFd;
        use std::sync::Arc;
        use std::time::{Duration, Instant};

        use super::super::*;

        #[test]
        fn ready_descriptor_is_claimed_close_on_exec_and_signaled_once() {
            let (mut reader, writer) = io::pipe().unwrap();
            let fd = writer.into_raw_fd();
            assert_eq!(claim_inherited_fd(OWNER_READY_FD_ARG, &fd.to_string()), Ok(fd));
            // SAFETY: querying flags of a descriptor this test owns.
            let flags = unsafe { libc::fcntl(fd, libc::F_GETFD) };
            assert_ne!(flags & libc::FD_CLOEXEC, 0);
            signal_ready(fd);
            let mut bytes = Vec::new();
            reader.read_to_end(&mut bytes).unwrap();
            assert_eq!(bytes, b"1");
            for invalid in ["0", "2", "-1", "x"] {
                assert!(claim_inherited_fd(OWNER_READY_FD_ARG, invalid).is_err(), "{invalid}");
            }
        }

        fn owner_state(command: &mut Command) -> (Arc<OwnerProcessState>, u32) {
            let child = command.spawn().unwrap();
            let pid = child.id();
            (Arc::new(OwnerProcessState { child: std::sync::Mutex::new(Some(child)) }), pid)
        }

        #[test]
        fn the_reaper_wakes_on_exit_and_leaves_no_zombie() {
            let (state, pid) = owner_state(&mut Command::new("true"));
            let reaper = {
                let state = Arc::clone(&state);
                std::thread::spawn(move || reap_on_exit(&state, pid))
            };
            reaper.join().unwrap();
            assert!(state.child.lock().unwrap().is_none());
            // SAFETY: probing a pid this test spawned and the reaper reaped.
            assert_eq!(unsafe { libc::kill(pid as libc::pid_t, 0) }, -1);
        }

        #[test]
        fn terminate_ends_a_blocked_reaper_and_the_owner() {
            let (state, pid) = owner_state(Command::new("sleep").arg("60"));
            let reaper = {
                let state = Arc::clone(&state);
                std::thread::spawn(move || reap_on_exit(&state, pid))
            };
            let started = Instant::now();
            SpawnedOwner { state: Arc::clone(&state), pid, ready: None }.terminate();
            reaper.join().unwrap();
            assert!(started.elapsed() < Duration::from_secs(5));
            assert!(state.child.lock().unwrap().is_none());
        }
    }

    #[test]
    fn detached_owner_removes_terminal_identity_but_keeps_configuration() {
        let mut command = Command::new("cmux-tui");
        command
            .env("CMUX_SURFACE_ID", "surface")
            .env("CMUX_WORKSPACE_ID", "workspace")
            .env("CMUX_TAB_ID", "tab")
            .env("CMUX_PANEL_ID", "panel")
            .env("CMUX_PANE_ID", "pane")
            .env("CMUX_TUI_CONFIG", "/tmp/mux.json")
            .env("CMUX_MUX_CONFIG", "/tmp/legacy-mux.json");

        configure_detached_owner_environment(&mut command);

        let values = command
            .get_envs()
            .map(|(key, value)| (key.to_owned(), value.map(OsString::from)))
            .collect::<std::collections::HashMap<_, _>>();
        for key in
            ["CMUX_SURFACE_ID", "CMUX_WORKSPACE_ID", "CMUX_TAB_ID", "CMUX_PANEL_ID", "CMUX_PANE_ID"]
        {
            assert_eq!(values.get(OsString::from(key).as_os_str()), Some(&None));
        }
        assert_eq!(
            values.get(OsString::from("CMUX_TUI_CONFIG").as_os_str()),
            Some(&Some(OsString::from("/tmp/mux.json")))
        );
        assert_eq!(
            values.get(OsString::from("CMUX_MUX_CONFIG").as_os_str()),
            Some(&Some(OsString::from("/tmp/legacy-mux.json")))
        );
    }
}
