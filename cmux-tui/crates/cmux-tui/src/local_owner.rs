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
use serde_json::{Value, json};

/// Total time an ensure may spend probing, spawning, and waiting for the
/// owner to accept clients. Matches the lifecycle CLI exchange deadline.
pub(crate) const ENSURE_DEADLINE: Duration = cmux_tui_core::budgets::OWNER_ENSURE;

const POLL_INTERVAL: Duration = cmux_tui_core::budgets::OWNER_POLL;

/// The reaper's only job is clearing a zombie when the owner exits early
/// (a lost bind race or a crash), and `terminate` reaps synchronously
/// without it, so it can tick slowly instead of waking a long-lived
/// interactive client 40 times a second for nothing.
const REAP_INTERVAL: Duration = Duration::from_secs(1);
const RESPONSE_LIMIT: usize = 16 * 1024 * 1024;

/// How the owner process is launched.
pub(crate) struct OwnerSpec {
    pub session: String,
    pub socket: PathBuf,
    pub socket_is_derived: bool,
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

#[derive(Debug)]
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

/// A throwaway bench-owned session: a spawned owner and the temporary state
/// root to clean up when the bench stops.
pub(crate) struct EnsuredOwnerHandle {
    pid: u64,
    generation: String,
    state_root: Option<PathBuf>,
    owned: bool,
}

impl EnsuredOwnerHandle {
    /// Process id of the owner; terminal hosts it spawned are its children
    /// while it runs, which is how the bench audits for leaked hosts.
    pub(crate) fn pid(&self) -> u64 {
        self.pid
    }

    pub(crate) fn should_stop(&self) -> bool {
        self.owned
    }

    /// Ask the owner to shut down (best effort) and remove the temp state root.
    pub(crate) fn stop(self, socket: &Path) {
        if !self.owned {
            return;
        }
        let deadline = Instant::now() + Duration::from_secs(5);
        let mut exited = false;
        if let Ok(stream) = transport::connect(socket) {
            let _ = stream.set_read_timeout(Some(Duration::from_secs(2)));
            let _ = stream.set_write_timeout(Some(Duration::from_secs(2)));
            let mut connection = BufReader::new(stream);
            let request = json!({
                "id": 1,
                "cmd": "shutdown-daemon",
                "pid": self.pid,
                "generation": self.generation,
            });
            if writeln!(connection.get_mut(), "{request}")
                .and_then(|()| connection.get_mut().flush())
                .is_ok()
            {
                // Drain until the socket closes or the deadline passes.
                loop {
                    if Instant::now() >= deadline {
                        break;
                    }
                    let mut bytes = Vec::new();
                    match connection.read_until(b'\n', &mut bytes) {
                        Ok(0) => {
                            exited = true;
                            break;
                        }
                        Ok(_) if bytes.len() > 4096 => {
                            exited = true;
                            break;
                        }
                        Err(error) if error.kind() != io::ErrorKind::TimedOut => {
                            exited = true;
                            break;
                        }
                        Err(_) => break,
                        Ok(_) => {}
                    }
                }
            }
        }
        if !exited && owner_process_is_alive(self.pid) {
            let pid = self.pid.to_string();
            let _ = Command::new("kill").args(["-TERM", &pid]).status();
            let kill_deadline = Instant::now() + Duration::from_millis(250);
            while Instant::now() < kill_deadline && owner_process_is_alive(self.pid) {
                std::thread::sleep(Duration::from_millis(10));
            }
            if owner_process_is_alive(self.pid) {
                let _ = Command::new("kill").args(["-KILL", &pid]).status();
            }
            exited = !owner_process_is_alive(self.pid);
        }
        if (exited || !owner_process_is_alive(self.pid))
            && let Some(root) = self.state_root
        {
            let _ = std::fs::remove_dir_all(root);
            // `SocketStartLock` deliberately leaves `<socket>.spawn-lock` in
            // place for durable sessions, because unlinking it reopens the
            // stale-socket start race for that session name. A bench session
            // name is random and never started again, so removing its lock
            // after the owner we spawned has been asked to exit leaves nothing
            // behind under the runtime directory.
            let mut name = socket.file_name().unwrap_or_default().to_os_string();
            name.push(".spawn-lock");
            let _ = std::fs::remove_file(socket.with_file_name(name));
        }
    }
}

fn owner_process_is_alive(pid: u64) -> bool {
    Command::new("ps")
        .args(["-p", &pid.to_string()])
        .output()
        .map(|output| output.status.success())
        .unwrap_or(true)
}

/// Spawn (or adopt) a headless owner for a bench session and return a handle
/// that can stop it. Uses a private temporary state root so a throwaway
/// session never touches the default durable state.
pub(crate) fn ensure_owner_for_bench(
    session: &str,
    socket: &Path,
) -> Result<EnsuredOwnerHandle, String> {
    let nonce = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_err(|error| format!("state dir: {error}"))?
        .as_nanos();
    let state_root =
        std::env::temp_dir().join(format!("cmux-bench-state-{}-{nonce}", std::process::id()));
    std::fs::create_dir(&state_root).map_err(|error| format!("state dir: {error}"))?;
    let spec = OwnerSpec {
        session: session.to_string(),
        socket: socket.to_path_buf(),
        socket_is_derived: true,
        state: Some(state_root.clone()),
        term: None,
    };
    let deadline = Instant::now() + ENSURE_DEADLINE;
    match ensure_owner(&spec, Some(session), deadline) {
        Ok(Ensured::Running(ready)) => {
            // This call created the temporary root before probing, but an
            // adopted owner already has its own state. Remove our unused
            // directory so repeated benches do not leave empty roots behind.
            let _ = std::fs::remove_dir(&state_root);
            Ok(EnsuredOwnerHandle {
                pid: ready.pid,
                generation: ready.generation,
                state_root: None,
                owned: false,
            })
        }
        Ok(Ensured::Started(ready)) => Ok(EnsuredOwnerHandle {
            pid: ready.pid,
            generation: ready.generation,
            state_root: Some(state_root),
            owned: true,
        }),
        Err(error) => {
            let _ = std::fs::remove_dir_all(&state_root);
            Err(format!("ensure bench owner: {error:?}"))
        }
    }
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
    if let Some(ready) = wait_while_starting(&spec.socket, expected_session, deadline)? {
        return Ok(Ensured::Running(ready));
    }
    let owner = {
        let _lock = cmux_tui_core::server::SocketStartLock::acquire(&spec.socket, deadline)
            .map_err(EnsureError::Spawn)?;
        // Re-probe under the lock: a concurrent ensure may have spawned the
        // owner while this call waited for the lock.
        if let Some(ready) = wait_while_starting(&spec.socket, expected_session, deadline)? {
            return Ok(Ensured::Running(ready));
        }
        // The lock is released once the spawn is issued: the owner's serve
        // path takes the same lock to bind, so holding it across the
        // readiness wait would deadlock parent against child. A redundant
        // owner spawned by a racing ensure loses the serialized bind, exits,
        // and every caller converges on the winner through the probe below.
        spawn_detached_owner(spec).map_err(EnsureError::Spawn)?
    };
    match wait_until_ready(&spec.socket, Some(&spec.session), deadline) {
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
    wake: std::sync::Condvar,
    terminate: std::sync::atomic::AtomicBool,
}

struct SpawnedOwner {
    state: std::sync::Arc<OwnerProcessState>,
}

impl SpawnedOwner {
    fn terminate(self) {
        self.state.terminate.store(true, std::sync::atomic::Ordering::Release);
        // Reap synchronously instead of waiting for the reaper thread: this
        // must terminate the owner even when that thread could not be
        // created. The reaper wakes to an empty slot and exits.
        let mut child = self.state.child.lock().expect("owner mutex poisoned");
        if let Some(mut process) = child.take() {
            let _ = process.kill();
            let _ = process.wait();
        }
        self.state.wake.notify_all();
    }
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
    // The owner outlives this process. Reap it in the background so an
    // owner that exits early (for example after losing the bind race) never
    // lingers as a zombie of a long-lived interactive client.
    let state = std::sync::Arc::new(OwnerProcessState {
        child: std::sync::Mutex::new(Some(child)),
        wake: std::sync::Condvar::new(),
        terminate: std::sync::atomic::AtomicBool::new(false),
    });
    let reaper_state = std::sync::Arc::clone(&state);
    if let Err(_error) =
        std::thread::Builder::new().name("local-owner-reaper".to_string()).spawn(move || {
            let mut child = reaper_state.child.lock().expect("owner mutex poisoned");
            while let Some(process) = child.as_mut() {
                if reaper_state.terminate.load(std::sync::atomic::Ordering::Acquire) {
                    let _ = process.kill();
                }
                let exited = match process.try_wait() {
                    Ok(Some(_)) | Err(_) => true,
                    Ok(None) => false,
                };
                if exited {
                    child.take();
                    reaper_state.wake.notify_all();
                    break;
                }
                child = reaper_state
                    .wake
                    .wait_timeout(child, REAP_INTERVAL)
                    .expect("owner condvar poisoned")
                    .0;
            }
        })
    {
        // If the helper thread cannot be created, reap synchronously before
        // returning. This preserves the no-zombie guarantee even under
        // thread exhaustion; the owner has already been detached from the
        // caller's terminal and cannot report through its stdio.
        SpawnedOwner { state: std::sync::Arc::clone(&state) }.terminate();
        return Err(io::Error::other("local owner reaper unavailable"));
    }
    Ok(SpawnedOwner { state })
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::{BufRead, BufReader, Write};
    use std::thread;

    #[test]
    fn adopting_running_bench_owner_removes_unused_state_root() {
        let session = format!("bench-adopt-state-cleanup-{}", std::process::id());
        let socket = cmux_tui_core::server::try_default_socket_path(&session).unwrap();
        let state_root = std::env::temp_dir().join(format!("cmux-bench-{session}"));
        let _ = std::fs::remove_file(&socket);
        let _ = std::fs::remove_dir_all(&state_root);
        cmux_tui_core::server::prepare_socket_parent(&socket, true).unwrap();
        let listener = transport::listen(&socket).unwrap();
        let server_session = session.clone();
        let server = thread::spawn(move || {
            let mut stream = listener.accept().unwrap();
            let mut request = Vec::new();
            BufReader::new(&mut stream).read_until(b'\n', &mut request).unwrap();
            let request: Value = serde_json::from_slice(&request).unwrap();
            let response = json!({
                "id": request["id"],
                "ok": true,
                "data": {
                    "app": "cmux-tui",
                    "protocol": cmux_tui_core::server::PROTOCOL_VERSION,
                    "lifecycle_ready": true,
                    "session": server_session,
                    "pid": 4242,
                    "generation": "test-generation"
                }
            });
            writeln!(stream, "{response}").unwrap();
            stream.flush().unwrap();
        });

        let owner = ensure_owner_for_bench(&session, &socket).unwrap();
        assert_eq!(owner.pid(), 4242);
        assert!(!owner.should_stop(), "adopted owners must remain running after the bench");
        assert!(
            !state_root.exists(),
            "adopting an owner must remove its unused temporary state root"
        );

        server.join().unwrap();
        let _ = std::fs::remove_file(&socket);
        let _ = std::fs::remove_file(socket.with_file_name(format!("{session}.sock.spawn-lock")));
    }
}
