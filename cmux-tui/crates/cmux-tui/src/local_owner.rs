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

fn socket_parent(path: &Path) -> &Path {
    path.parent().filter(|parent| !parent.as_os_str().is_empty()).unwrap_or_else(|| Path::new("."))
}

/// Total time an ensure may spend probing, spawning, and waiting for the
/// owner to accept clients. Matches the lifecycle CLI exchange deadline.
pub(crate) const ENSURE_DEADLINE: Duration = Duration::from_secs(10);

const POLL_INTERVAL: Duration = Duration::from_millis(25);
const RESPONSE_LIMIT: usize = 16 * 1024 * 1024;

/// How the owner process is launched.
pub(crate) struct OwnerSpec {
    pub session: String,
    pub socket: PathBuf,
    pub state: Option<PathBuf>,
    pub term: Option<String>,
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
    if let Some(ready) = wait_while_starting(&spec.socket, expected_session, deadline)? {
        return Ok(Ensured::Running(ready));
    }
    let _lock = SpawnLock::acquire(&spec.socket, deadline).map_err(EnsureError::Spawn)?;
    // Re-probe under the lock: a concurrent ensure may have spawned the
    // owner while this call waited for the lock.
    if let Some(ready) = wait_while_starting(&spec.socket, expected_session, deadline)? {
        return Ok(Ensured::Running(ready));
    }
    spawn_detached_owner(spec).map_err(EnsureError::Spawn)?;
    match wait_until_ready(&spec.socket, Some(&spec.session), deadline)? {
        Some(ready) => Ok(Ensured::Started(ready)),
        None => Err(EnsureError::NotReady),
    }
}

/// Poll while a live server reports it is still starting. `Ok(None)` means
/// nothing serves the socket; the caller decides whether to spawn.
fn wait_while_starting(
    socket: &Path,
    expected_session: Option<&str>,
    deadline: Instant,
) -> Result<Option<ReadyOwner>, EnsureError> {
    loop {
        match attempt(socket, expected_session, deadline)? {
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
    expected_session: Option<&str>,
    deadline: Instant,
) -> Result<Option<ReadyOwner>, EnsureError> {
    loop {
        if let Attempt::Ready(ready) = attempt(socket, expected_session, deadline)? {
            return Ok(Some(ready));
        }
        if Instant::now() >= deadline {
            return Ok(None);
        }
        std::thread::sleep(POLL_INTERVAL);
    }
}

fn attempt(
    socket: &Path,
    expected_session: Option<&str>,
    deadline: Instant,
) -> Result<Attempt, EnsureError> {
    let stream = match transport::connect(socket) {
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
    match identity.get("lifecycle_ready") {
        Some(Value::Bool(false)) => return Ok(Attempt::Starting),
        Some(Value::Bool(true)) | None => {}
        Some(_) => return Err(EnsureError::InvalidIdentity),
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
fn spawn_detached_owner(spec: &OwnerSpec) -> io::Result<()> {
    std::fs::create_dir_all(socket_parent(&spec.socket))?;
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
    let mut child = command.spawn()?;
    // The owner outlives this process. Reap it in the background so an
    // owner that exits early (for example after losing the bind race) never
    // lingers as a zombie of a long-lived interactive client.
    let reaper_child = std::sync::Arc::new(std::sync::Mutex::new(Some(child)));
    let reaper_handle = std::sync::Arc::clone(&reaper_child);
    if let Err(_error) =
        std::thread::Builder::new().name("local-owner-reaper".to_string()).spawn(move || {
            if let Some(mut child) = reaper_handle.lock().expect("reaper mutex poisoned").take() {
                let _ = child.wait();
            }
        })
    {
        // If the helper thread cannot be created, reap synchronously before
        // returning. This preserves the no-zombie guarantee even under
        // thread exhaustion; the owner has already been detached from the
        // caller's terminal and cannot report through its stdio.
        if let Some(mut child) = reaper_child.lock().expect("reaper mutex poisoned").take() {
            let _ = child.kill();
            let _ = child.wait();
        }
        return Err(io::Error::other("local owner reaper unavailable"));
    }
    Ok(())
}

/// Exclusive lock serializing owner spawns for one socket path. The lock
/// file lives next to the socket and is left in place: unlinking it would
/// reopen the very race it exists to close. The OS releases the lock when
/// the holder exits, so a crashed ensure never wedges the session.
struct SpawnLock {
    _file: std::fs::File,
}

impl SpawnLock {
    fn acquire(socket: &Path, deadline: Instant) -> io::Result<Self> {
        std::fs::create_dir_all(socket_parent(socket))?;
        let mut name = socket.file_name().unwrap_or_default().to_os_string();
        name.push(".spawn-lock");
        let path = socket.with_file_name(name);
        let file = std::fs::OpenOptions::new().create(true).append(true).open(&path)?;
        #[cfg(unix)]
        {
            use std::os::fd::AsRawFd;
            loop {
                if unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) } == 0 {
                    return Ok(Self { _file: file });
                }
                let error = io::Error::last_os_error();
                if error.kind() != io::ErrorKind::WouldBlock {
                    return Err(error);
                }
                if Instant::now() >= deadline {
                    return Err(io::Error::new(
                        io::ErrorKind::TimedOut,
                        "timed out waiting for a concurrent session-owner start",
                    ));
                }
                std::thread::sleep(POLL_INTERVAL);
            }
        }
        #[cfg(not(unix))]
        {
            // Windows has no flock with these semantics in std on this
            // toolchain's MSRV policy; concurrent ensures fall back to the
            // server's own live-socket refusal, which covers everything but
            // a sub-millisecond bind race.
            let _ = deadline;
            Ok(Self { _file: file })
        }
    }
}

#[cfg(test)]
mod tests {
    use super::socket_parent;
    use std::path::Path;

    #[test]
    fn bare_relative_socket_uses_current_directory_parent() {
        assert_eq!(socket_parent(Path::new("cmux.sock")), Path::new("."));
        assert_eq!(socket_parent(Path::new("nested/cmux.sock")), Path::new("nested"));
    }
}
