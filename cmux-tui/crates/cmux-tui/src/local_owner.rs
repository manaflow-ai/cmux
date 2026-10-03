//! Ensuring a detached owner process for a local session.
//!
//! A local session is owned by one headless `cmux-tui --headless` process so
//! that every interactive `cmux` on the machine is an equal client of the
//! same session: the mux survives any client detaching or exiting, and a
//! later `cmux` reattaches through the same socket instead of racing to
//! rebuild the mux and adopt the durable terminal hosts. `ensure_owner` is
//! the single entrypoint shared by the interactive startup path and the
//! `cmux server ensure` CLI verb.
//!
//! The owner is spawned with no controlling terminal and null stdio; its
//! diagnostics go to the bounded client log at the session state root.
//! Concurrent ensures serialize on a lock file next to the socket, because
//! the server's stale-socket recovery (probe, unlink, bind) is not atomic:
//! without the lock, two racing owners could both bind, one of them on an
//! already-unlinked socket path that no client can ever reach.

use std::io;
use std::io::{BufRead, BufReader, Read, Write};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

use cmux_tui_core::platform::{self, transport};
use serde_json::Value;

/// Total time an ensure may spend probing, spawning, and waiting for the
/// owner to accept clients. Matches the lifecycle CLI exchange deadline.
pub(crate) const ENSURE_DEADLINE: Duration = Duration::from_secs(10);

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

/// Takes the inherited readiness descriptor from argv and keeps it out of
/// every process the owner starts before it is ready (terminal hosts), so
/// only this owner's exit or signal can end the parent's wait.
pub(crate) fn claim_ready_fd(value: &str) -> Result<i32, String> {
    let fd: i32 = value
        .parse()
        .ok()
        .filter(|fd| *fd > 2)
        .ok_or_else(|| format!("{OWNER_READY_FD_ARG} needs a descriptor number above 2"))?;
    #[cfg(unix)]
    {
        // SAFETY: fcntl on a descriptor number only changes its flags; an
        // invalid descriptor reports EBADF.
        if unsafe { libc::fcntl(fd, libc::F_SETFD, libc::FD_CLOEXEC) } != 0 {
            return Err(format!("{OWNER_READY_FD_ARG} {fd}: {}", io::Error::last_os_error()));
        }
    }
    Ok(fd)
}

/// Tells the parent that spawned this owner that it accepts clients.
pub(crate) fn signal_ready(fd: i32) {
    #[cfg(unix)]
    {
        use std::os::fd::FromRawFd;
        // SAFETY: `claim_ready_fd` validated this inherited descriptor, and
        // this is its only use; the File closes it.
        let mut pipe = unsafe { std::fs::File::from_raw_fd(fd) };
        let _ = pipe.write_all(b"1");
    }
    #[cfg(not(unix))]
    let _ = fd;
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
    /// The socket is served by something that is not a cmux-tui server.
    WrongOwner,
    /// The socket is served by a different session than requested.
    DifferentSession,
    /// The server identity was missing required lifecycle fields.
    InvalidIdentity,
    /// The server speaks a protocol incompatible with this client.
    UnsupportedProtocol,
}

/// One connect-and-identify attempt against the session socket.
enum Attempt {
    /// Nothing serves the socket (missing file, refused, or dead peer).
    Absent,
    /// A cmux-tui server answered but is not lifecycle-ready yet.
    Starting,
    Ready(ReadyOwner),
}

/// Connect to a ready owner for `spec.session` on `spec.socket`, spawning a
/// detached headless owner process when none is running. `expected_session`
/// is the caller's session constraint for a server that is already running;
/// an owner spawned here is always validated against `spec.session`.
pub(crate) fn ensure_owner(
    spec: &OwnerSpec,
    expected_session: Option<&str>,
    deadline: Instant,
) -> Result<Ensured, EnsureError> {
    cmux_tui_core::server::prepare_socket_parent(&spec.socket, spec.socket_is_derived)
        .map_err(|error| EnsureError::Spawn(io::Error::other(error)))?;
    if let Some(ready) =
        wait_while_starting(&spec.socket, spec.socket_is_derived, expected_session, deadline)?
    {
        return Ok(Ensured::Running(ready));
    }
    let owner = {
        let _lock = cmux_tui_core::server::SocketStartLock::acquire(&spec.socket, deadline)
            .map_err(EnsureError::Spawn)?;
        // Re-probe under the lock: a concurrent ensure may have spawned the
        // owner while this call waited for the lock.
        if let Some(ready) =
            wait_while_starting(&spec.socket, spec.socket_is_derived, expected_session, deadline)?
        {
            return Ok(Ensured::Running(ready));
        }
        // The lock is released once the spawn is issued: the owner's serve
        // path takes the same lock to bind, so holding it across the
        // readiness wait would deadlock parent against child. A redundant
        // owner spawned by a racing ensure loses the serialized bind, exits,
        // and every caller converges on the winner through the probe below.
        spawn_detached_owner(spec).map_err(EnsureError::Spawn)?
    };
    let ready = match owner.ready.as_ref() {
        Some(pipe) => wait_for_spawned_owner(pipe, spec, deadline),
        None => {
            wait_until_ready(&spec.socket, spec.socket_is_derived, Some(&spec.session), deadline)
        }
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

/// Poll while a live server reports it is still starting. `Ok(None)` means
/// nothing serves the socket; the caller decides whether to spawn.
fn wait_while_starting(
    socket: &Path,
    socket_is_derived: bool,
    expected_session: Option<&str>,
    deadline: Instant,
) -> Result<Option<ReadyOwner>, EnsureError> {
    loop {
        match attempt(socket, socket_is_derived, expected_session, deadline)? {
            Attempt::Ready(ready) => return Ok(Some(ready)),
            Attempt::Absent => return Ok(None),
            Attempt::Starting => {}
        }
        if Instant::now() >= deadline {
            return Err(EnsureError::NotReady);
        }
        std::thread::sleep(POLL_INTERVAL);
    }
}

/// Poll until the freshly spawned owner accepts clients. Absence is
/// tolerated here because the owner may not have bound the socket yet.
fn wait_until_ready(
    socket: &Path,
    socket_is_derived: bool,
    expected_session: Option<&str>,
    deadline: Instant,
) -> Result<Option<ReadyOwner>, EnsureError> {
    loop {
        if let Attempt::Ready(ready) =
            attempt(socket, socket_is_derived, expected_session, deadline)?
        {
            return Ok(Some(ready));
        }
        if Instant::now() >= deadline {
            return Ok(None);
        }
        std::thread::sleep(POLL_INTERVAL);
    }
}

/// Waits on the spawned owner's readiness pipe, not on a timer. A byte means
/// the owner accepts clients; end of file means it exited, and whoever won
/// the bind (another ensure's owner) is found by probing.
#[cfg(unix)]
fn wait_for_spawned_owner(
    pipe: &std::fs::File,
    spec: &OwnerSpec,
    deadline: Instant,
) -> Result<Option<ReadyOwner>, EnsureError> {
    use std::os::fd::AsRawFd;
    let expected = Some(spec.session.as_str());
    loop {
        let remaining = deadline.saturating_duration_since(Instant::now());
        let timeout = i32::try_from(remaining.as_millis()).unwrap_or(i32::MAX);
        let mut poll = libc::pollfd { fd: pipe.as_raw_fd(), events: libc::POLLIN, revents: 0 };
        // SAFETY: one valid pollfd for the lifetime of the call.
        match unsafe { libc::poll(&mut poll, 1, timeout) } {
            0 => return Ok(None),
            result if result > 0 => break,
            _ if io::Error::last_os_error().kind() == io::ErrorKind::Interrupted => {}
            _ => break,
        }
    }
    let mut byte = [0_u8; 1];
    let signaled = matches!((&*pipe).read(&mut byte), Ok(1));
    if signaled
        && let Attempt::Ready(ready) =
            attempt(&spec.socket, spec.socket_is_derived, expected, deadline)?
    {
        return Ok(Some(ready));
    }
    // End of file: this owner lost the bind to a racing ensure's owner (or
    // crashed). That owner announces readiness only to its own parent.
    wait_until_ready(&spec.socket, spec.socket_is_derived, expected, deadline)
}

#[cfg(not(unix))]
fn wait_for_spawned_owner(
    _pipe: &std::convert::Infallible,
    spec: &OwnerSpec,
    deadline: Instant,
) -> Result<Option<ReadyOwner>, EnsureError> {
    wait_until_ready(&spec.socket, spec.socket_is_derived, Some(&spec.session), deadline)
}

fn attempt(
    socket: &Path,
    socket_is_derived: bool,
    expected_session: Option<&str>,
    deadline: Instant,
) -> Result<Attempt, EnsureError> {
    let stream = match cmux_tui_core::server::connect_session_socket(socket, socket_is_derived) {
        Ok(stream) => stream,
        Err(_) => return Ok(Attempt::Absent),
    };
    let identity = match identify(stream, deadline) {
        Ok(identity) => identity,
        // A timeout is a live but busy server; anything else on a fresh
        // connection is a dying or stale peer and reads as absent.
        Err(IdentifyError::Timeout) => return Ok(Attempt::Starting),
        Err(IdentifyError::Failed) => return Ok(Attempt::Absent),
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
        Some(Value::Bool(false)) => return Ok(Attempt::Starting),
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
    child: std::sync::Mutex<Option<std::process::Child>>,
    #[cfg(not(unix))]
    wake: std::sync::Condvar,
    #[cfg(not(unix))]
    terminate: std::sync::atomic::AtomicBool,
}

struct SpawnedOwner {
    state: std::sync::Arc<OwnerProcessState>,
    /// Read end of the owner's readiness pipe (`OWNER_READY_FD_ARG`).
    #[cfg(unix)]
    ready: Option<std::fs::File>,
    #[cfg(not(unix))]
    ready: Option<std::convert::Infallible>,
}

const DETACHED_OWNER_IDENTITY_ENV: [&str; 6] = [
    "CMUX_SURFACE_ID",
    "CMUX_WORKSPACE_ID",
    "CMUX_TAB_ID",
    "CMUX_PANEL_ID",
    "CMUX_PANE_ID",
    // The calling terminal's launch credential: the owner and every helper
    // it starts must never act as that terminal.
    "CMUX_LAUNCH_CREDENTIAL",
];

/// Remove terminal identity claims from the detached owner while preserving
/// configuration and socket variables inherited from the launching client.
fn configure_detached_owner_environment(command: &mut Command) {
    for key in DETACHED_OWNER_IDENTITY_ENV {
        command.env_remove(key);
    }
}

impl SpawnedOwner {
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

/// The readiness pipe: the read end stays here, the write end goes to the
/// owner only (both are close-on-exec; `pre_exec` clears the flag on the
/// owner's copy).
#[cfg(unix)]
fn ready_pipe(command: &mut Command) -> io::Result<(std::fs::File, io::PipeWriter)> {
    use std::os::fd::{AsRawFd, OwnedFd};
    use std::os::unix::process::CommandExt;
    let (reader, writer) = io::pipe()?;
    let write_fd = writer.as_raw_fd();
    command.arg(OWNER_READY_FD_ARG).arg(write_fd.to_string());
    // SAFETY: fcntl is async-signal-safe and touches only this descriptor.
    unsafe {
        command.pre_exec(move || {
            if libc::fcntl(write_fd, libc::F_SETFD, 0) != 0 {
                return Err(io::Error::last_os_error());
            }
            Ok(())
        });
    }
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
    #[cfg(unix)]
    let (ready, ready_writer) = ready_pipe(&mut command)?;
    #[cfg(not(unix))]
    let ready = None;
    // The owner reports through the bounded client log at its state root;
    // terminal teardown must never reach it, so it gets no stdio and (on
    // Unix) its own session, free of the controlling terminal.
    command.stdin(Stdio::null()).stdout(Stdio::null()).stderr(Stdio::null());
    #[cfg(unix)]
    {
        use std::os::unix::process::CommandExt;
        // SAFETY: setsid(2) is async-signal-safe and touches no Rust state
        // in the post-fork child. A freshly forked child is not a
        // process-group leader, so failure is a real launch error.
        unsafe {
            command.pre_exec(|| {
                if libc::setsid() < 0 { Err(io::Error::last_os_error()) } else { Ok(()) }
            });
        }
    }
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        const DETACHED_PROCESS: u32 = 0x0000_0008;
        const CREATE_NEW_PROCESS_GROUP: u32 = 0x0000_0200;
        command.creation_flags(DETACHED_PROCESS | CREATE_NEW_PROCESS_GROUP);
    }
    let child = command.spawn()?;
    // Only the owner holds the write end now, so end of file means it exited.
    #[cfg(unix)]
    drop(ready_writer);
    #[cfg(unix)]
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
        SpawnedOwner { state: std::sync::Arc::clone(&state), ready: None }.terminate();
        return Err(io::Error::other("local owner reaper unavailable"));
    }
    #[cfg(unix)]
    let ready = Some(ready);
    Ok(SpawnedOwner { state, ready })
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
    use std::process::Command;

    use super::configure_detached_owner_environment;

    #[cfg(unix)]
    mod event_driven {
        use std::os::fd::IntoRawFd;
        use std::sync::Arc;
        use std::time::{Duration, Instant};

        use super::super::*;

        fn spec(socket: PathBuf) -> OwnerSpec {
            OwnerSpec {
                session: "ready-pipe-test".into(),
                socket,
                socket_is_derived: false,
                state: None,
                term: None,
                initial_host_colors: None,
                terminal_reap_grace: None,
            }
        }

        #[test]
        fn ready_descriptor_is_claimed_close_on_exec_and_signaled_once() {
            let (mut reader, writer) = io::pipe().unwrap();
            let fd = writer.into_raw_fd();
            assert_eq!(claim_ready_fd(&fd.to_string()), Ok(fd));
            // SAFETY: querying flags of a descriptor this test owns.
            let flags = unsafe { libc::fcntl(fd, libc::F_GETFD) };
            assert_ne!(flags & libc::FD_CLOEXEC, 0);
            signal_ready(fd);
            let mut bytes = Vec::new();
            reader.read_to_end(&mut bytes).unwrap();
            assert_eq!(bytes, b"1");
            for invalid in ["0", "2", "-1", "x"] {
                assert!(claim_ready_fd(invalid).is_err(), "{invalid}");
            }
        }

        #[test]
        fn an_owner_that_never_signals_is_awaited_only_until_the_deadline() {
            let dir = std::env::temp_dir().join(format!(
                "cmux-owner-wait-{}-{}",
                std::process::id(),
                line!()
            ));
            let socket = dir.join("absent.sock");
            // Writer held open: no byte and no end of file.
            let (reader, _writer) = io::pipe().unwrap();
            let pipe = std::fs::File::from(std::os::fd::OwnedFd::from(reader));
            let started = Instant::now();
            let deadline = started + Duration::from_millis(200);
            assert!(matches!(
                wait_for_spawned_owner(&pipe, &spec(socket.clone()), deadline),
                Ok(None)
            ));
            assert!(started.elapsed() >= Duration::from_millis(150));
            // A byte with nothing serving the socket is not readiness either.
            let (reader, mut writer) = io::pipe().unwrap();
            writer.write_all(b"1").unwrap();
            drop(writer);
            let pipe = std::fs::File::from(std::os::fd::OwnedFd::from(reader));
            let deadline = Instant::now() + Duration::from_millis(200);
            assert!(matches!(wait_for_spawned_owner(&pipe, &spec(socket), deadline), Ok(None)));
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
            SpawnedOwner { state: Arc::clone(&state), ready: None }.terminate();
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
            .env("CMUX_LAUNCH_CREDENTIAL", "cmuxlc1.k.c.m")
            .env("CMUX_TUI_CONFIG", "/tmp/mux.json")
            .env("CMUX_MUX_CONFIG", "/tmp/legacy-mux.json");

        configure_detached_owner_environment(&mut command);

        let values = command
            .get_envs()
            .map(|(key, value)| (key.to_owned(), value.map(OsString::from)))
            .collect::<std::collections::HashMap<_, _>>();
        for key in [
            "CMUX_SURFACE_ID",
            "CMUX_WORKSPACE_ID",
            "CMUX_TAB_ID",
            "CMUX_PANEL_ID",
            "CMUX_PANE_ID",
            "CMUX_LAUNCH_CREDENTIAL",
        ] {
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
