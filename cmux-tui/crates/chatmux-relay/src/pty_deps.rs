//! Production `PtyDeps`: real PTY allocation (cmux-pty), cmux-tui binary
//! resolution, headless daemon management, and the unix control socket.
//! Behavior port of the default* helpers in `packages/relay/bin/pty.mjs`.
//!
//! PTY reads and the child wait are blocking, so each runs on a dedicated
//! blocking thread that forwards into the attachment's event channel; writes
//! and resizes go through the (blocking) master behind a mutex.

#![cfg(unix)]

use std::collections::{HashMap, VecDeque};
use std::ffi::CString;
use std::io::{Read, Write};
use std::mem::{MaybeUninit, offset_of, size_of};
use std::os::fd::AsRawFd;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use async_trait::async_trait;
use bytes::Bytes;
use cmux_pty::{MasterPty, PtySize};
use sha2::{Digest, Sha256};

use crate::control::{CONTROL_TIMEOUT_MS, ControlHandle, connect_control};
use crate::pty::{
    CmuxTui, DataSink, EnsureDaemon, ExitSink, PtyControl, PtyDeps, PtyHandle, PtyOutput,
    SpawnSpec, session_name_ok,
};

const DAEMON_SOCKET_WAIT_MS: u64 = 5_000;
// `lifecycle_ready` was added to the cmux-tui control protocol at version 12.
// This is distinct from the relay's lower-level CONTROL_MIN_PROTOCOL floor.
const DAEMON_LIFECYCLE_PROTOCOL_MIN: u64 = 12;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
struct DaemonIdentity {
    pid: u32,
    lifecycle_ready: bool,
}

/// Read and validate the daemon identity without treating a starting daemon
/// as ready. Returning the PID gives startup cleanup a process identity fence,
/// so a relay never removes a socket that belongs to a racing daemon.
async fn control_identity(
    control: &Arc<dyn ControlHandle>,
    session: &str,
) -> Option<DaemonIdentity> {
    let response = control.request("identify", serde_json::Value::Null).await?;
    let data = response.get("data")?;
    if response.get("ok").and_then(serde_json::Value::as_bool) != Some(true)
        || data.get("app").and_then(serde_json::Value::as_str) != Some("cmux-tui")
        || data.get("session").and_then(serde_json::Value::as_str) != Some(session)
        || !data
            .get("protocol")
            .and_then(serde_json::Value::as_u64)
            .is_some_and(|protocol| protocol >= DAEMON_LIFECYCLE_PROTOCOL_MIN)
    {
        return None;
    }
    let pid = data
        .get("pid")
        .and_then(serde_json::Value::as_u64)
        .and_then(|pid| u32::try_from(pid).ok())
        .filter(|pid| *pid > 0)?;
    let lifecycle_ready = data.get("lifecycle_ready").and_then(serde_json::Value::as_bool)?;
    Some(DaemonIdentity { pid, lifecycle_ready })
}

async fn control_ready(control: &Arc<dyn ControlHandle>, session: &str) -> bool {
    control_identity(control, session).await.is_some_and(|identity| identity.lifecycle_ready)
}

/// Resolve the same bounded socket path that cmux-tui-core uses for a
/// session. `socket_dir` is the preferred `<runtime-base>/cmux-tui-<uid>`
/// directory supplied by this relay. The ordinary `/tmp` fallback is checked
/// before a digest leaf, then the digest is kept below the preferred runtime
/// base when that path still fits.
fn session_socket_path(socket_dir: &Path, uid: u32, session: &str) -> Result<PathBuf, String> {
    if !session_name_ok(session) {
        return Err("invalid session name".to_owned());
    }
    let leaf = format!("{session}.sock");
    let preferred = socket_dir.join(&leaf);
    if unix_socket_path_fits(&preferred) {
        return Ok(preferred);
    }

    let fallback_dir = Path::new("/tmp").join(format!("cmux-tui-{uid}"));
    let fallback = fallback_dir.join(&leaf);
    if unix_socket_path_fits(&fallback) {
        return Ok(fallback);
    }

    let digest = format!("{:x}", Sha256::digest(session.as_bytes()));
    let preferred_base = socket_dir
        .parent()
        .filter(|base| !base.as_os_str().is_empty())
        .unwrap_or_else(|| Path::new("/tmp"));
    let hashed =
        preferred_base.join(format!("cmux-tui-hashed-{uid}")).join(format!("{digest}.sock"));
    if unix_socket_path_fits(&hashed) {
        return Ok(hashed);
    }
    Ok(Path::new("/tmp").join(format!("cmux-tui-hashed-{uid}")).join(format!("{digest}.sock")))
}

fn unix_socket_path_fits(path: &Path) -> bool {
    use std::os::unix::ffi::OsStrExt;

    // Unix-domain socket paths include a trailing NUL in `sun_path`.
    const SUN_PATH_CAPACITY: usize =
        size_of::<libc::sockaddr_un>() - offset_of!(libc::sockaddr_un, sun_path);
    path.as_os_str().as_bytes().len() < SUN_PATH_CAPACITY
}

/// Buffers output until the manager subscribes, then drains one FIFO queue.
/// Only one caller drains at a time. This keeps bytes buffered before
/// `subscribe` ahead of bytes accepted while the backlog is being replayed.
#[derive(Default)]
struct SourceState {
    on_data: Option<DataSink>,
    on_exit: Option<ExitSink>,
    backlog: VecDeque<Bytes>,
    // Keep exit behind bytes that arrive before the subscriber drains.
    pending_exit: Option<i64>,
    delivering: bool,
    exited: bool,
}

struct ThreadOutput {
    state: Mutex<SourceState>,
}

impl ThreadOutput {
    fn new() -> Arc<ThreadOutput> {
        Arc::new(ThreadOutput { state: Mutex::new(SourceState::default()) })
    }

    /// Mark the queue as owned by a drainer, if a subscriber is ready.
    fn start_delivery(state: &mut SourceState) -> bool {
        if state.delivering
            || (state.backlog.is_empty() && state.pending_exit.is_none())
            || state.on_data.is_none()
            || state.on_exit.is_none()
        {
            return false;
        }
        state.delivering = true;
        true
    }

    /// Deliver queued events serially, without holding the source mutex while
    /// user code runs. Producers that arrive during a callback append to the
    /// same queue and are picked up by this drainer before it releases it.
    fn drain(&self) {
        loop {
            let next = {
                let mut state = self.state.lock().expect("source lock");
                if let Some(chunk) = state.backlog.pop_front() {
                    (Some(chunk), None, state.on_data.clone(), state.on_exit.clone())
                } else if let Some(code) = state.pending_exit.take() {
                    (None, Some(code), state.on_data.clone(), state.on_exit.clone())
                } else {
                    state.delivering = false;
                    return;
                }
            };
            let (chunk, exit, on_data, on_exit) = next;
            match (chunk, exit, on_data, on_exit) {
                (Some(chunk), _, Some(on_data), _) => on_data(chunk),
                (None, Some(code), _, Some(on_exit)) => on_exit(code),
                _ => {}
            }
        }
    }

    fn push_data(&self, chunk: Bytes) {
        let should_drain = {
            let mut state = self.state.lock().expect("source lock");
            state.backlog.push_back(chunk);
            Self::start_delivery(&mut state)
        };
        if should_drain {
            self.drain();
        }
    }

    fn push_exit(&self, code: i64) {
        let should_drain = {
            let mut state = self.state.lock().expect("source lock");
            if state.exited {
                return;
            }
            state.exited = true;
            state.pending_exit = Some(code);
            Self::start_delivery(&mut state)
        };
        if should_drain {
            self.drain();
        }
    }
}

impl PtyOutput for ThreadOutput {
    fn subscribe(&self, on_data: DataSink, on_exit: ExitSink) {
        let should_drain = {
            let mut state = self.state.lock().expect("source lock");
            state.on_data = Some(Arc::clone(&on_data));
            state.on_exit = Some(Arc::clone(&on_exit));
            Self::start_delivery(&mut state)
        };
        if should_drain {
            self.drain();
        }
    }
}

pub struct RealPtyDeps {
    env: HashMap<String, String>,
    uid: u32,
    shell: String,
}

struct CancelOnDrop {
    handoff: Arc<SpawnHandoff>,
    armed: bool,
}

/// Own the process control until the async `spawn_blocking` result is
/// consumed. Tokio cannot abort a blocking closure after it starts, so the
/// cancellation guard must have a control object it can signal while the
/// worker is finishing its thread handoff.
struct SpawnHandoff {
    cancelled: std::sync::atomic::AtomicBool,
    control: Mutex<Option<Arc<dyn PtyControl>>>,
}

impl SpawnHandoff {
    fn new() -> Arc<Self> {
        Arc::new(Self {
            cancelled: std::sync::atomic::AtomicBool::new(false),
            control: Mutex::new(None),
        })
    }

    fn is_cancelled(&self) -> bool {
        self.cancelled.load(std::sync::atomic::Ordering::Acquire)
    }

    /// Install the process control while holding the same lock used by
    /// cancellation. A cancellation that wins the race either takes and
    /// kills this control, or is observed before installation and kills it
    /// directly.
    fn install(&self, control: Arc<dyn PtyControl>) -> bool {
        let mut slot = self.control.lock().expect("spawn handoff lock");
        if self.cancelled.load(std::sync::atomic::Ordering::Acquire) {
            drop(slot);
            control.kill();
            return false;
        }
        *slot = Some(control);
        true
    }

    /// Cancel and take the temporary owner. Dropping the owner after `kill`
    /// is intentional: it closes the PTY/control resources as well as
    /// signalling the child.
    fn cancel(&self) {
        self.cancelled.store(true, std::sync::atomic::Ordering::Release);
        let control = self.control.lock().expect("spawn handoff lock").take();
        if let Some(control) = control {
            control.kill();
        }
    }

    /// Release the temporary owner after the caller has received the
    /// `PtyHandle`. The handle's own control Arc owns the process from this
    /// point onward.
    fn disarm(&self) {
        let _ = self.control.lock().expect("spawn handoff lock").take();
    }
}

/// Keep a control probe owned until its async handshake finishes. The
/// `ControlHandle` trait deliberately exposes an explicit `end()` operation
/// instead of relying on `Drop`, so cancellation must close the socket here.
struct ControlEndGuard {
    control: Option<Arc<dyn ControlHandle>>,
}

impl ControlEndGuard {
    fn new(control: Arc<dyn ControlHandle>) -> Self {
        Self { control: Some(control) }
    }

    fn disarm(&mut self) {
        self.control = None;
    }
}

impl Drop for ControlEndGuard {
    fn drop(&mut self) {
        if let Some(control) = self.control.take() {
            control.end();
        }
    }
}

impl CancelOnDrop {
    fn new(handoff: Arc<SpawnHandoff>) -> Self {
        Self { handoff, armed: true }
    }

    fn disarm(&mut self) {
        self.handoff.disarm();
        self.armed = false;
    }
}

impl Drop for CancelOnDrop {
    fn drop(&mut self) {
        if self.armed {
            self.handoff.cancel();
        }
    }
}

impl RealPtyDeps {
    pub fn new(env: HashMap<String, String>) -> RealPtyDeps {
        // SAFETY: getuid is always safe.
        let uid = unsafe { libc::getuid() };
        let shell = env.get("SHELL").cloned().unwrap_or_else(|| "/bin/sh".to_owned());
        RealPtyDeps { env, uid, shell }
    }
}

/// Process ownership state shared by a control handle and its wait guard.
///
/// A plain `AtomicBool` is not enough here. The wait thread can reap a child
/// while a close callback concurrently asks the control to kill it. The
/// mutex serializes those transitions, so a signal is sent only while the
/// child is still owned by its wait guard. Once `wait` returns, a recycled PID
/// can never be signalled by a late control drop.
struct ChildLifecycle {
    pid: Option<u32>,
    exited: bool,
    termination_started: bool,
}

type ChildLifecycleHandle = Arc<Mutex<ChildLifecycle>>;

impl ChildLifecycle {
    fn new(pid: Option<u32>) -> ChildLifecycleHandle {
        Arc::new(Mutex::new(Self { pid, exited: false, termination_started: false }))
    }

    /// Reserve the one process-group termination and run the signal operation
    /// while the lifecycle lock is held. Keeping the lock through the syscall
    /// closes the handoff window where the wait thread could reap the child,
    /// the PID could be reused, and a late close would signal that new group.
    fn terminate(lifecycle: &ChildLifecycleHandle, signal: impl FnOnce(Option<u32>)) -> bool {
        let mut state = lifecycle.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
        if state.exited || state.termination_started {
            return false;
        }
        state.termination_started = true;
        signal(state.pid);
        true
    }

    /// Reserve termination from the wait owner. The caller must perform the
    /// kill after this returns. Setting the flag first prevents a concurrent
    /// control drop from sending a second signal while the wait owner is
    /// converting an unexpected poll error into a bounded reap.
    fn begin_termination(lifecycle: &ChildLifecycleHandle) -> bool {
        let mut state = lifecycle.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
        if state.exited || state.termination_started {
            return false;
        }
        state.termination_started = true;
        true
    }

    /// Mark the child terminal immediately after `wait` has returned. A
    /// successful wait has reaped the PID; an error still leaves the guard in
    /// charge of the child, and its bounded Drop cleanup remains responsible
    /// for the final reap.
    fn mark_exited(lifecycle: &ChildLifecycleHandle) {
        lifecycle.lock().unwrap_or_else(|poisoned| poisoned.into_inner()).exited = true;
    }
}

/// A real PTY master behind a mutex; write/resize block briefly.
struct MasterControl {
    master: Mutex<Box<dyn MasterPty + Send>>,
    writer: Mutex<Box<dyn Write + Send>>,
    killer: Mutex<Box<dyn cmux_pty::ChildKiller + Send + Sync>>,
    lifecycle: ChildLifecycleHandle,
}

impl Drop for MasterControl {
    fn drop(&mut self) {
        // `portable_pty::Child` does not kill on drop. The wait thread owns
        // the child, so use the cloned signal handle here for the case where
        // the PTY handle is abandoned before it is installed in an
        // attachment.
        self.terminate();
    }
}

impl MasterControl {
    fn terminate(&self) {
        ChildLifecycle::terminate(&self.lifecycle, |pid| {
            let mut killer = match self.killer.lock() {
                Ok(killer) => killer,
                Err(poisoned) => poisoned.into_inner(),
            };
            let _ = killer.kill();
            // `portable-pty`'s Unix killer sends SIGHUP to only the direct
            // child. The PTY child is a session leader, so also force its
            // process group down to cover helpers it may have spawned.
            signal_process_group(pid);
        });
    }
}

impl PtyControl for MasterControl {
    fn write(&self, data: &[u8]) {
        if let Ok(mut writer) = self.writer.lock() {
            let _ = writer.write_all(data);
            let _ = writer.flush();
        }
    }
    fn resize(&self, cols: u16, rows: u16) {
        if let Ok(master) = self.master.lock() {
            let _ = master.resize(PtySize { rows, cols, pixel_width: 0, pixel_height: 0 });
        }
    }
    fn pause(&self) {}
    fn resume(&self) {}
    fn kill(&self) {
        self.terminate();
    }
}

/// A degraded pipe-mode shell (no TTY) used when PTY allocation fails. The
/// child is owned by its wait thread; kill signals it by pid.
struct PipeControl {
    stdin: Mutex<Option<std::process::ChildStdin>>,
    pid: u32,
    lifecycle: ChildLifecycleHandle,
}

impl PtyControl for PipeControl {
    fn write(&self, data: &[u8]) {
        if let Ok(mut guard) = self.stdin.lock()
            && let Some(stdin) = guard.as_mut()
        {
            let _ = stdin.write_all(data);
            let _ = stdin.flush();
        }
    }
    fn resize(&self, _cols: u16, _rows: u16) {}
    fn pause(&self) {}
    fn resume(&self) {}
    fn kill(&self) {
        // SAFETY: signalling a child pid this handle spawned; harmless if gone.
        ChildLifecycle::terminate(&self.lifecycle, |_| signal_process_group(Some(self.pid)));
    }
}

impl Drop for PipeControl {
    fn drop(&mut self) {
        self.kill();
    }
}

const CHILD_REAP_TIMEOUT: Duration = Duration::from_millis(500);
const CHILD_REAP_POLL: Duration = Duration::from_millis(10);

fn signal_process_group(pid: Option<u32>) {
    signal_process_group_with(pid, libc::SIGKILL);
}

/// Reap a portable-pty child without allowing cancellation cleanup to pin a
/// Tokio blocking worker. The process group receives SIGKILL first, then the
/// child is polled for a bounded interval. A tiny detached reaper handles the
/// kernel's rare delayed-exit case after the bound expires.
fn reap_portable_child(mut child: Box<dyn cmux_pty::Child + Send + Sync>, pid: Option<u32>) {
    signal_process_group(pid);
    let deadline = Instant::now() + CHILD_REAP_TIMEOUT;
    loop {
        match child.try_wait() {
            Ok(Some(_)) | Err(_) => return,
            Ok(None) if Instant::now() >= deadline => break,
            Ok(None) => std::thread::sleep(CHILD_REAP_POLL),
        }
    }
    let _ = std::thread::Builder::new().name("cmux-relay-pty-reaper".to_owned()).spawn(move || {
        let _ = child.wait();
    });
}

struct PtyChildGuard {
    child: Option<Box<dyn cmux_pty::Child + Send + Sync>>,
    pid: Option<u32>,
}

impl PtyChildGuard {
    fn new(child: Box<dyn cmux_pty::Child + Send + Sync>) -> Self {
        let pid = child.process_id();
        Self { child: Some(child), pid }
    }

    fn child(&self) -> &dyn cmux_pty::Child {
        self.child.as_deref().expect("PTY child guard is armed")
    }

    fn child_mut(&mut self) -> &mut dyn cmux_pty::Child {
        self.child.as_deref_mut().expect("PTY child guard is armed")
    }

    fn take(&mut self) -> Box<dyn cmux_pty::Child + Send + Sync> {
        self.child.take().expect("PTY child guard is armed")
    }

    fn disarm(&mut self) {
        let _ = self.child.take();
    }
}

impl Drop for PtyChildGuard {
    fn drop(&mut self) {
        let Some(child) = self.child.take() else { return };
        reap_portable_child(child, self.pid);
    }
}

struct PipeChildGuard {
    child: Option<std::process::Child>,
    pid: Option<u32>,
}

impl PipeChildGuard {
    fn new(child: std::process::Child) -> Self {
        let pid = Some(child.id());
        Self { child: Some(child), pid }
    }

    fn child_mut(&mut self) -> &mut std::process::Child {
        self.child.as_mut().expect("pipe child guard is armed")
    }

    fn take(&mut self) -> std::process::Child {
        self.child.take().expect("pipe child guard is armed")
    }

    fn disarm(&mut self) {
        let _ = self.child.take();
    }
}

impl Drop for PipeChildGuard {
    fn drop(&mut self) {
        let Some(mut child) = self.child.take() else { return };
        signal_process_group(self.pid);
        let deadline = Instant::now() + CHILD_REAP_TIMEOUT;
        loop {
            match child.try_wait() {
                Ok(Some(_)) | Err(_) => return,
                Ok(None) if Instant::now() >= deadline => break,
                Ok(None) => std::thread::sleep(CHILD_REAP_POLL),
            }
        }
        let _ = std::thread::Builder::new().name("cmux-relay-pipe-reaper".to_owned()).spawn(
            move || {
                let _ = child.wait();
            },
        );
    }
}

fn spawn_real_pty(spec: &SpawnSpec, handoff: &SpawnHandoff) -> anyhow::Result<PtyHandle> {
    if handoff.is_cancelled() {
        return Err(anyhow::anyhow!("PTY spawn cancelled"));
    }
    let pair = cmux_pty::open(PtySize {
        rows: spec.rows,
        cols: spec.cols,
        pixel_width: 0,
        pixel_height: 0,
    })?;
    let mut command = cmux_pty::PtyCommand::new(spec.file.clone());
    command.args(spec.args.clone());
    command.cwd(&spec.cwd);
    command.env_clear();
    for (key, value) in &spec.env {
        command.env(key, value);
    }
    let spawned = pair.spawn(command)?;
    let cmux_pty::SpawnedPty { master, child } = spawned;
    let mut child_guard = PtyChildGuard::new(child);
    // `spawn_blocking` cannot be aborted after it starts. If its async
    // handoff was cancelled while the child was being created, terminate the
    // child before handing any PTY resources to detached reader threads.
    if handoff.is_cancelled() {
        return Err(anyhow::anyhow!("PTY spawn cancelled"));
    }
    let reader = master.try_clone_reader()?;
    let writer = master.take_writer()?;
    if handoff.is_cancelled() {
        return Err(anyhow::anyhow!("PTY spawn cancelled"));
    }
    let killer = child_guard.child().clone_killer();
    let output = ThreadOutput::new();
    let lifecycle = ChildLifecycle::new(child_guard.child().process_id());
    let control = Arc::new(MasterControl {
        master: Mutex::new(master),
        writer: Mutex::new(writer),
        killer: Mutex::new(killer),
        lifecycle: Arc::clone(&lifecycle),
    });
    if !handoff.install(Arc::clone(&control) as Arc<dyn PtyControl>) {
        return Err(anyhow::anyhow!("PTY spawn cancelled"));
    }

    // Blocking reader thread -> output sink.
    let data_output = Arc::clone(&output);
    if let Err(error) =
        std::thread::Builder::new().name("cmux-relay-pty-reader".to_owned()).spawn(move || {
            let mut reader = reader;
            let mut buffer = [0_u8; 32_768];
            loop {
                match reader.read(&mut buffer) {
                    Ok(0) | Err(_) => break,
                    Ok(count) => data_output.push_data(Bytes::copy_from_slice(&buffer[..count])),
                }
            }
        })
    {
        handoff.disarm();
        return Err(anyhow::anyhow!("PTY reader thread spawn failed: {error}"));
    }

    // Keep a bounded cleanup guard in the thread closure too. If creating the
    // wait thread fails, `Builder::spawn` drops the closure and this guard
    // kills/reaps the child instead of leaving it detached.
    let wait_guard = PtyChildGuard::new(child_guard.take());
    let exit_output = Arc::clone(&output);
    let wait_lifecycle = Arc::clone(&lifecycle);
    if let Err(error) =
        std::thread::Builder::new().name("cmux-relay-pty-wait".to_owned()).spawn(move || {
            let mut wait_guard = wait_guard;
            loop {
                enum Poll {
                    Running,
                    Exited(i64),
                    Failed,
                }
                let poll = {
                    let mut lifecycle =
                        wait_lifecycle.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
                    match wait_guard.child_mut().try_wait() {
                        Ok(Some(status)) => {
                            // `try_wait` reaps the child on success. Mark it
                            // while the lifecycle lock is held, before a
                            // control drop can attempt a late PID signal.
                            lifecycle.exited = true;
                            Poll::Exited(status.exit_code() as i64)
                        }
                        Ok(None) => Poll::Running,
                        Err(_) => Poll::Failed,
                    }
                };
                match poll {
                    Poll::Exited(code) => {
                        wait_guard.disarm();
                        exit_output.push_exit(code);
                        return;
                    }
                    Poll::Running => std::thread::sleep(CHILD_REAP_POLL),
                    Poll::Failed => {
                        // An unexpected poll error must not leave the child
                        // owner ambiguous. Reserve termination before the
                        // fallback blocking wait, so a late control drop can
                        // never signal a recycled PID after this wait owner
                        // has finished reaping.
                        if ChildLifecycle::begin_termination(&wait_lifecycle) {
                            let _ = wait_guard.child_mut().kill();
                            signal_process_group(wait_guard.pid);
                        }
                        let status = wait_guard.child_mut().wait();
                        let code =
                            status.as_ref().map(|status| status.exit_code() as i64).unwrap_or(0);
                        if status.is_ok() {
                            ChildLifecycle::mark_exited(&wait_lifecycle);
                            wait_guard.disarm();
                        }
                        exit_output.push_exit(code);
                        return;
                    }
                }
            }
        })
    {
        handoff.disarm();
        return Err(anyhow::anyhow!("PTY wait thread spawn failed: {error}"));
    }

    // The cancellation owner remains installed until the async caller has
    // consumed the returned `PtyHandle`. This final check closes the narrow
    // interval after thread creation and before the handle is published.
    if handoff.is_cancelled() {
        handoff.disarm();
        return Err(anyhow::anyhow!("PTY spawn cancelled"));
    }

    Ok(PtyHandle { control, output, banner: None })
}

fn dead_handle(output: Arc<ThreadOutput>, banner: Option<Vec<u8>>) -> PtyHandle {
    output.push_exit(1);
    PtyHandle { control: Arc::new(DeadControl), output, banner }
}

fn spawn_pipe_mode(spec: &SpawnSpec, _reason: &str, handoff: &SpawnHandoff) -> PtyHandle {
    let output = ThreadOutput::new();
    let mut command = std::process::Command::new(&spec.file);
    command.args(&spec.args).current_dir(&spec.cwd).env_clear();
    for (key, value) in &spec.env {
        command.env(key, value);
    }
    command.env("TERM", "dumb");
    command.stdin(std::process::Stdio::piped());
    command.stdout(std::process::Stdio::piped());
    command.stderr(std::process::Stdio::piped());
    // Keep fallback shells and their descendants under one owner so dropping
    // a cancelled handoff cannot leave a helper process behind.
    use std::os::unix::process::CommandExt as _;
    command.process_group(0);
    // The allocation error can contain local paths, usernames, or provider
    // response text. This banner crosses the relay boundary, so keep it
    // stable and do not disclose the internal reason.
    // Do not put the remotely supplied executable path on the terminal. It
    // can contain control characters or local path details, and this banner
    // crosses the relay boundary.
    let banner = b"[cmux-relay] PTY allocation failed; running without a TTY.\r\n".to_vec();
    match command.spawn() {
        Ok(child) => {
            let mut child_guard = PipeChildGuard::new(child);
            if handoff.is_cancelled() {
                drop(child_guard);
                return dead_handle(output, None);
            }
            let (stdin, stdout, stderr, pid) = {
                let child = child_guard.child_mut();
                (child.stdin.take(), child.stdout.take(), child.stderr.take(), child.id())
            };
            let lifecycle = ChildLifecycle::new(Some(pid));
            let wait_lifecycle = Arc::clone(&lifecycle);
            let control = Arc::new(PipeControl { stdin: Mutex::new(stdin), pid, lifecycle });
            if !handoff.install(Arc::clone(&control) as Arc<dyn PtyControl>) {
                drop(child_guard);
                return dead_handle(output, None);
            }
            if let Some(stdout) = stdout {
                let out = Arc::clone(&output);
                if let Err(error) = std::thread::Builder::new()
                    .name("cmux-relay-pipe-stdout".to_owned())
                    .spawn(move || pump_pipe(stdout, out))
                {
                    let _ = error;
                    handoff.disarm();
                    return dead_handle(output, None);
                }
            }
            if let Some(stderr) = stderr {
                let out = Arc::clone(&output);
                if let Err(error) = std::thread::Builder::new()
                    .name("cmux-relay-pipe-stderr".to_owned())
                    .spawn(move || pump_pipe(stderr, out))
                {
                    let _ = error;
                    handoff.disarm();
                    return dead_handle(output, None);
                }
            }
            // The wait would need its own thread; the shell exits when its
            // pipes close, and the manager treats a data EOF plus process
            // teardown as the end. Report exit when both pipes close.
            let wait_guard = PipeChildGuard::new(child_guard.take());
            let wait_output = Arc::clone(&output);
            if let Err(error) = std::thread::Builder::new()
                .name("cmux-relay-pipe-wait".to_owned())
                .spawn(move || {
                    let mut wait_guard = wait_guard;
                    loop {
                        enum Poll {
                            Running,
                            Exited(i64),
                            Failed,
                        }
                        let poll = {
                            let mut lifecycle = wait_lifecycle
                                .lock()
                                .unwrap_or_else(|poisoned| poisoned.into_inner());
                            match wait_guard.child_mut().try_wait() {
                                Ok(Some(status)) => {
                                    lifecycle.exited = true;
                                    Poll::Exited(status.code().unwrap_or(0) as i64)
                                }
                                Ok(None) => Poll::Running,
                                Err(_) => Poll::Failed,
                            }
                        };
                        match poll {
                            Poll::Exited(code) => {
                                wait_guard.disarm();
                                wait_output.push_exit(code);
                                return;
                            }
                            Poll::Running => std::thread::sleep(CHILD_REAP_POLL),
                            Poll::Failed => {
                                if ChildLifecycle::begin_termination(&wait_lifecycle) {
                                    let _ = wait_guard.child_mut().kill();
                                    signal_process_group(wait_guard.pid);
                                }
                                let status = wait_guard.child_mut().wait();
                                let code = status
                                    .as_ref()
                                    .map(|status| status.code().unwrap_or(0) as i64)
                                    .unwrap_or(0);
                                if status.is_ok() {
                                    ChildLifecycle::mark_exited(&wait_lifecycle);
                                    wait_guard.disarm();
                                }
                                wait_output.push_exit(code);
                                return;
                            }
                        }
                    }
                })
            {
                let _ = error;
                handoff.disarm();
                return dead_handle(output, None);
            }
            if handoff.is_cancelled() {
                handoff.disarm();
                return dead_handle(output, None);
            }
            PtyHandle { control, output, banner: Some(banner) }
        }
        Err(error) => {
            let _ = error;
            dead_handle(output, Some(banner))
        }
    }
}

struct DeadControl;
impl PtyControl for DeadControl {
    fn write(&self, _data: &[u8]) {}
    fn resize(&self, _cols: u16, _rows: u16) {}
    fn pause(&self) {}
    fn resume(&self) {}
    fn kill(&self) {}
}

fn pump_pipe(mut stream: impl Read, output: Arc<ThreadOutput>) {
    let mut buffer = [0_u8; 32_768];
    loop {
        match stream.read(&mut buffer) {
            Ok(0) | Err(_) => break,
            Ok(count) => output.push_data(Bytes::copy_from_slice(&buffer[..count])),
        }
    }
}

async fn socket_exists(path: &Path) -> bool {
    let Ok(metadata) = tokio::fs::symlink_metadata(path).await else { return false };
    if metadata.file_type().is_symlink() {
        return false;
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::FileTypeExt as _;
        return metadata.file_type().is_socket();
    }
    #[allow(unreachable_code)]
    true
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
struct SocketFingerprint {
    device: u64,
    inode: u64,
}

fn socket_lock_path(path: &Path) -> PathBuf {
    let mut name = path.file_name().unwrap_or_default().to_os_string();
    name.push(".spawn-lock");
    path.with_file_name(name)
}

fn socket_fingerprint(path: &Path) -> Option<SocketFingerprint> {
    use std::os::unix::fs::MetadataExt;

    let metadata = std::fs::symlink_metadata(path).ok()?;
    Some(SocketFingerprint { device: metadata.dev(), inode: metadata.ino() })
}

fn socket_fingerprint_at(dir_fd: libc::c_int, name: &std::ffi::OsStr) -> Option<SocketFingerprint> {
    use std::os::unix::ffi::OsStrExt;

    let name = CString::new(name.as_bytes()).ok()?;
    let mut stat = MaybeUninit::<libc::stat>::uninit();
    // SAFETY: `name` is NUL terminated and `stat` points to writable storage.
    let result = unsafe {
        libc::fstatat(dir_fd, name.as_ptr(), stat.as_mut_ptr(), libc::AT_SYMLINK_NOFOLLOW)
    };
    if result != 0 {
        return None;
    }
    // SAFETY: fstatat initialized `stat` when it returned zero.
    let stat = unsafe { stat.assume_init() };
    if (stat.st_mode as libc::mode_t) & libc::S_IFMT != libc::S_IFSOCK {
        return None;
    }
    Some(SocketFingerprint { device: stat.st_dev as u64, inode: stat.st_ino as u64 })
}

/// Try to take the same private startup lock that cmux-tui-core uses. Cleanup
/// skips unlinking when another starter owns the lock. Leaving a stale socket
/// is safe; unlinking a replacement socket is not.
fn try_lock_socket_start_file(path: &Path) -> Option<std::fs::File> {
    use std::os::unix::fs::{MetadataExt, OpenOptionsExt, PermissionsExt};

    let mut options = std::fs::OpenOptions::new();
    options.create(true).append(true).read(true);
    options.custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC).mode(0o600);
    let file = options.open(path).ok()?;
    let metadata = file.metadata().ok()?;
    let uid = unsafe { libc::getuid() };
    if !metadata.is_file() || metadata.uid() != uid || metadata.permissions().mode() & 0o022 != 0 {
        return None;
    }
    // SAFETY: `file` remains open for the lock lifetime.
    if unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) } != 0 {
        return None;
    }
    Some(file)
}

/// Remove a socket only when its device/inode is the one observed from the
/// daemon we started. The shared startup lock is held while a directory fd
/// performs the identity check and unlink. All cmux-tui starters use this
/// lock, so a cooperating daemon cannot replace the pathname in that window.
fn remove_socket_if_owned(path: &Path, expected: Option<SocketFingerprint>) {
    let Some(expected) = expected else { return };
    let Some(_lock) = try_lock_socket_start_file(&socket_lock_path(path)) else { return };
    let Some(parent) = path.parent() else { return };
    let Some(name) = path.file_name() else { return };
    use std::os::unix::fs::OpenOptionsExt;
    let mut options = std::fs::OpenOptions::new();
    options.read(true).custom_flags(libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC);
    let Ok(directory) = options.open(parent) else { return };
    let current = socket_fingerprint_at(directory.as_raw_fd(), name);
    if current != Some(expected) {
        return;
    }
    let name = match CString::new({
        use std::os::unix::ffi::OsStrExt;
        name.as_bytes()
    }) {
        Ok(name) => name,
        Err(_) => return,
    };
    // SAFETY: `directory` is an open directory fd and `name` is NUL terminated.
    let _ = unsafe { libc::unlinkat(directory.as_raw_fd(), name.as_ptr(), 0) };
}

/// The cmux-tui core uses `<socket>.spawn-lock` for its probe/unlink/bind
/// sequence. Relay startup takes the same advisory lock while checking the
/// path and issuing the child spawn, which prevents two starters from both
/// classifying an absent socket as safe to claim. The lock is released before
/// readiness polling because the child must acquire it in `serve_paused`.
struct DaemonStartLock {
    _file: std::fs::File,
}

async fn acquire_daemon_start_lock(
    path: &Path,
    uid: u32,
    deadline: Instant,
) -> Result<DaemonStartLock, String> {
    use std::os::fd::AsRawFd;
    use std::os::unix::fs::{MetadataExt, OpenOptionsExt, PermissionsExt};

    let lock_path = socket_lock_path(path);
    if let Some(parent) = lock_path.parent() {
        tokio::fs::create_dir_all(parent)
            .await
            .map_err(|error| format!("daemon start lock directory create failed: {error}"))?;
        let metadata = tokio::fs::symlink_metadata(parent)
            .await
            .map_err(|error| format!("daemon start lock directory stat failed: {error}"))?;
        if metadata.file_type().is_symlink() || !metadata.is_dir() || metadata.uid() != uid {
            return Err(format!("daemon start lock directory is not owned by uid {uid}"));
        }
        let mut permissions = metadata.permissions();
        permissions.set_mode(0o700);
        tokio::fs::set_permissions(parent, permissions)
            .await
            .map_err(|error| format!("daemon start lock directory permissions failed: {error}"))?;
    }
    let mut options = std::fs::OpenOptions::new();
    options.create(true).append(true).read(true);
    options.custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC).mode(0o600);
    let file = options
        .open(&lock_path)
        .map_err(|error| format!("daemon start lock open failed: {error}"))?;
    let metadata =
        file.metadata().map_err(|error| format!("daemon start lock stat failed: {error}"))?;
    if !metadata.is_file() || metadata.uid() != uid || metadata.permissions().mode() & 0o022 != 0 {
        return Err("daemon start lock is not a private regular file".to_owned());
    }
    loop {
        // SAFETY: `file` remains open for the lifetime of the lock. `flock`
        // is the Unix primitive used by cmux-tui-core's fs4 lock.
        let result = unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) };
        if result == 0 {
            return Ok(DaemonStartLock { _file: file });
        }
        let error = std::io::Error::last_os_error();
        let raw_error = error.raw_os_error();
        if raw_error != Some(libc::EWOULDBLOCK) && raw_error != Some(libc::EAGAIN) {
            return Err(format!("daemon start lock failed: {error}"));
        }
        if Instant::now() >= deadline {
            return Err("timed out waiting for a concurrent daemon start".to_owned());
        }
        tokio::time::sleep(Duration::from_millis(25)).await;
    }
}

fn signal_process_group_with(pid: Option<u32>, signal: libc::c_int) {
    let Some(pid) = pid.and_then(|pid| i32::try_from(pid).ok()).filter(|pid| *pid > 0) else {
        return;
    };
    // SAFETY: the pid came from a child this relay spawned with
    // `process_group(0)`, so the negative pid addresses only that group.
    unsafe {
        let _ = libc::kill(-(pid as libc::pid_t), signal);
    }
}

/// Reap a deliberately long-lived daemon without reserving an OS thread per
/// session. Successful daemon handoff runs inside Tokio, so its waiter polls
/// the standard child from one lightweight async task and yields between
/// checks. The no-runtime branch is only a defensive shutdown fallback for a
/// guard dropped outside an executor; it is not used by normal startup.
fn spawn_daemon_reaper(mut child: std::process::Child) {
    if let Ok(handle) = tokio::runtime::Handle::try_current() {
        handle.spawn(async move {
            loop {
                match child.try_wait() {
                    Ok(Some(_)) | Err(_) => break,
                    Ok(None) => tokio::time::sleep(Duration::from_millis(100)).await,
                }
            }
        });
    } else {
        let _ = std::thread::Builder::new().name("cmux-relay-daemon-reaper".to_owned()).spawn(
            move || {
                let _ = child.wait();
            },
        );
    }
}

/// Poll a standard child without blocking the async reactor. `false` covers
/// both a still-running child and an OS wait error; the caller then keeps a
/// detached reaper as the final ownership fallback.
async fn wait_std_child_bounded(child: &mut std::process::Child, timeout: Duration) -> bool {
    let deadline = Instant::now() + timeout;
    loop {
        match child.try_wait() {
            Ok(Some(_)) => return true,
            Ok(None) if Instant::now() >= deadline => return false,
            Err(_) => return false,
            Ok(None) => tokio::time::sleep(CHILD_REAP_POLL).await,
        }
    }
}

/// Own a newly spawned daemon until readiness is proven. The guard always
/// retains the child handle, so cancellation cannot silently detach it. On
/// success it transfers the handle to a named reaper thread. On failure or
/// cancellation it kills the process group, removes only an identity-matched
/// socket, and transfers any delayed wait to that same reaper.
struct DaemonProcessGuard {
    child: Option<std::process::Child>,
    pid: Option<u32>,
    socket_path: PathBuf,
    socket: Option<SocketFingerprint>,
}

impl DaemonProcessGuard {
    fn new(child: std::process::Child, socket_path: PathBuf) -> Self {
        let pid = Some(child.id());
        Self { child: Some(child), pid, socket_path, socket: None }
    }

    fn pid(&self) -> Option<u32> {
        self.pid
    }

    fn child_running(&mut self) -> bool {
        let Some(child) = self.child.as_mut() else { return false };
        match child.try_wait() {
            Ok(None) => true,
            Ok(Some(_)) => {
                self.pid = None;
                false
            }
            Err(_) => false,
        }
    }

    fn claim_socket(&mut self) {
        if self.socket.is_none() {
            self.socket = socket_fingerprint(&self.socket_path);
        }
    }

    fn remove_socket(&mut self) {
        remove_socket_if_owned(&self.socket_path, self.socket.take());
    }

    /// Finish a successful handoff. The daemon intentionally survives the
    /// relay attachment, but its child handle still needs a waiter so exits
    /// are reaped instead of becoming zombies.
    fn detach(&mut self) {
        if let Some(child) = self.child.take() {
            self.pid = None;
            spawn_daemon_reaper(child);
        }
        self.socket = None;
    }

    async fn wait_bounded(&mut self, timeout: Duration) -> bool {
        let Some(child) = self.child.as_mut() else { return true };
        wait_std_child_bounded(child, timeout).await
    }

    /// Stop a daemon which never became ready. Every wait is bounded; if the
    /// kernel delays reaping, a detached thread owns the remaining wait.
    async fn cleanup(&mut self) {
        signal_process_group_with(self.pid, libc::SIGTERM);
        let exited = self.wait_bounded(Duration::from_millis(250)).await;
        if exited {
            self.pid = None;
            self.child.take();
        } else {
            signal_process_group(self.pid);
            if let Some(child) = self.child.as_mut() {
                let _ = child.kill();
            }
            let exited = self.wait_bounded(Duration::from_secs(1)).await;
            if exited {
                self.pid = None;
                self.child.take();
            }
        }
        if let Some(child) = self.child.take() {
            self.pid = None;
            spawn_daemon_reaper(child);
        }
        self.remove_socket();
    }
}

impl Drop for DaemonProcessGuard {
    fn drop(&mut self) {
        if self.child.is_some() {
            // Drop cannot await. A group SIGKILL plus a detached waiter gives
            // cancellation bounded synchronous work and preserves reaping.
            signal_process_group(self.pid);
            if let Some(child) = self.child.as_mut() {
                let _ = child.kill();
            }
            if let Some(child) = self.child.take() {
                spawn_daemon_reaper(child);
            }
        }
        self.pid = None;
        self.remove_socket();
    }
}

#[async_trait]
impl PtyDeps for RealPtyDeps {
    async fn spawn_pty(&self, spec: SpawnSpec) -> PtyHandle {
        // PTY allocation and thread setup are blocking; run off the reactor.
        // On PTY allocation failure (ptmx exhaustion et al) degrade to a
        // pipe-mode shell so the terminal still functions, with a banner.
        let output = ThreadOutput::new();
        let worker_output = Arc::clone(&output);
        let handoff = SpawnHandoff::new();
        let worker_handoff = Arc::clone(&handoff);
        let mut cancel_guard = CancelOnDrop::new(handoff);
        let result =
            tokio::task::spawn_blocking(move || match spawn_real_pty(&spec, &worker_handoff) {
                Ok(handle) => handle,
                Err(_error) if worker_handoff.is_cancelled() => {
                    worker_output.push_exit(1);
                    PtyHandle {
                        control: Arc::new(DeadControl),
                        output: worker_output,
                        banner: None,
                    }
                }
                Err(error) => spawn_pipe_mode(&spec, &error.to_string(), &worker_handoff),
            })
            .await;
        cancel_guard.disarm();
        result.unwrap_or_else(|_| {
            output.push_exit(1);
            PtyHandle { control: Arc::new(DeadControl), output, banner: None }
        })
    }

    async fn resolve_cmux_tui(&self) -> Option<CmuxTui> {
        if let Some(override_path) =
            self.env.get("CHATMUX_RELAY_CMUX_TUI").filter(|value| !value.trim().is_empty())
        {
            let path = override_path.trim();
            return if is_executable(Path::new(path)).await {
                Some(CmuxTui { file: path.to_owned(), prefix: Vec::new() })
            } else {
                None
            };
        }
        // Never a bare `cmux` on PATH — that name is ambiguous; only cmux-tui.
        for dir in self.env.get("PATH").map(String::as_str).unwrap_or("").split(':') {
            if dir.is_empty() {
                continue;
            }
            let candidate = Path::new(dir).join("cmux-tui");
            if is_executable(&candidate).await {
                return Some(CmuxTui {
                    file: candidate.to_string_lossy().into_owned(),
                    prefix: Vec::new(),
                });
            }
        }
        None
    }

    async fn ensure_daemon(
        &self,
        cmux_tui: &CmuxTui,
        session: &str,
        socket_dir: &Path,
        cwd: &Path,
        env: &HashMap<String, String>,
    ) -> Result<EnsureDaemon, String> {
        use std::os::unix::fs::{MetadataExt, PermissionsExt};
        tokio::fs::create_dir_all(socket_dir)
            .await
            .map_err(|error| format!("control socket directory create failed: {error}"))?;
        let metadata = tokio::fs::symlink_metadata(socket_dir)
            .await
            .map_err(|error| format!("control socket directory stat failed: {error}"))?;
        if metadata.file_type().is_symlink() || !metadata.is_dir() || metadata.uid() != self.uid {
            return Err(format!("control socket directory is not owned by uid {}", self.uid));
        }
        let permissions = std::fs::Permissions::from_mode(0o700);
        tokio::fs::set_permissions(socket_dir, permissions)
            .await
            .map_err(|error| format!("control socket directory permissions failed: {error}"))?;
        let socket_path = session_socket_path(socket_dir, self.uid, session)?;

        // Match cmux-tui-core's startup lock. Hold it through the initial
        // probe and child spawn, then release it before polling because the
        // child must acquire the same lock while binding its listener.
        let start_lock_deadline = Instant::now() + Duration::from_millis(DAEMON_SOCKET_WAIT_MS);
        let start_lock =
            acquire_daemon_start_lock(&socket_path, self.uid, start_lock_deadline).await?;
        if socket_exists(&socket_path).await {
            let ready = match connect_control(&socket_path, CONTROL_TIMEOUT_MS).await {
                Ok(control) => {
                    let mut control_guard = ControlEndGuard::new(Arc::clone(&control));
                    let ready = control_ready(&control, session).await;
                    control.end();
                    control_guard.disarm();
                    ready
                }
                Err(_) => false,
            };
            if ready {
                return Ok(EnsureDaemon { created: false, socket_path });
            }
            return Err(format!(
                "pre-existing cmux-tui socket {} failed identity/readiness validation",
                socket_path.display()
            ));
        }
        let mut args = cmux_tui.prefix.clone();
        args.extend([
            "--headless".to_owned(),
            "--session".to_owned(),
            session.to_owned(),
            "--socket".to_owned(),
            socket_path.to_string_lossy().into_owned(),
        ]);
        use std::os::unix::process::CommandExt as _;
        let mut command = std::process::Command::new(&cmux_tui.file);
        command.args(&args).current_dir(cwd).env_clear();
        for (key, value) in env {
            command.env(key, value);
        }
        command.stdin(std::process::Stdio::null());
        command.stdout(std::process::Stdio::null());
        command.stderr(std::process::Stdio::null());
        command.process_group(0);
        let child =
            command.spawn().map_err(|error| format!("cmux-tui daemon spawn failed: {error}"))?;
        // `serve_paused` takes the same lock before probing and binding. Do
        // not hold it during readiness polling, or the child would deadlock.
        drop(start_lock);
        let mut process_guard = DaemonProcessGuard::new(child, socket_path.clone());

        let deadline = Instant::now() + Duration::from_millis(DAEMON_SOCKET_WAIT_MS);
        while Instant::now() < deadline {
            if socket_exists(&socket_path).await {
                // Probe a control round-trip before declaring readiness.
                while Instant::now() < deadline {
                    match connect_control(&socket_path, CONTROL_TIMEOUT_MS).await {
                        Ok(control) => {
                            let mut control_guard = ControlEndGuard::new(Arc::clone(&control));
                            let identity = control_identity(&control, session).await;
                            control.end();
                            control_guard.disarm();
                            if let Some(identity) = identity {
                                if identity.pid == process_guard.pid().unwrap_or_default() {
                                    // The child handle still owns this PID, so
                                    // it cannot have been recycled between the
                                    // identity response and this check.
                                    if process_guard.child_running() {
                                        process_guard.claim_socket();
                                        if identity.lifecycle_ready {
                                            process_guard.detach();
                                            return Ok(EnsureDaemon { created: true, socket_path });
                                        }
                                    }
                                } else if identity.lifecycle_ready {
                                    // A concurrent starter won the bind race.
                                    // Reap our redundant child, then use the
                                    // already-ready daemon as an existing one.
                                    process_guard.cleanup().await;
                                    return Ok(EnsureDaemon { created: false, socket_path });
                                }
                            }
                        }
                        _ => tokio::time::sleep(Duration::from_millis(50)).await,
                    }
                }
                process_guard.cleanup().await;
                return Err(format!(
                    "cmux-tui daemon for \"{session}\" did not become control-ready"
                ));
            }
            tokio::time::sleep(Duration::from_millis(50)).await;
        }
        process_guard.cleanup().await;
        Err(format!("cmux-tui daemon for \"{session}\" never created {}", socket_path.display()))
    }

    async fn connect_control(&self, socket_path: &Path) -> Result<Arc<dyn ControlHandle>, String> {
        connect_control(socket_path, CONTROL_TIMEOUT_MS).await
    }

    async fn read_dir(&self, path: &Path) -> Result<Vec<String>, ()> {
        let mut entries = tokio::fs::read_dir(path).await.map_err(|_| ())?;
        let mut names = Vec::new();
        while let Ok(Some(entry)) = entries.next_entry().await {
            names.push(entry.file_name().to_string_lossy().into_owned());
        }
        Ok(names)
    }

    fn socket_dir(&self) -> PathBuf {
        let runtime = self
            .env
            .get("XDG_RUNTIME_DIR")
            .or_else(|| self.env.get("TMPDIR"))
            .map(String::as_str)
            .filter(|value| !value.is_empty())
            .unwrap_or("/tmp");
        Path::new(runtime).join(format!("cmux-tui-{}", self.uid))
    }

    fn shell(&self) -> String {
        self.shell.clone()
    }
}

async fn is_executable(path: &Path) -> bool {
    use std::os::unix::fs::PermissionsExt as _;
    match tokio::fs::metadata(path).await {
        Ok(meta) => meta.is_file() && meta.permissions().mode() & 0o111 != 0,
        Err(_) => false,
    }
}

/// Session-name validity is re-exported so the daemon path can reject early.
pub fn valid_session(name: &str) -> bool {
    session_name_ok(name)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicUsize, Ordering as AtomicOrdering};
    use std::sync::{Arc as TestArc, Barrier, Mutex as TestMutex};
    use std::thread;

    #[test]
    fn session_socket_path_matches_core_fallback_order() {
        let session = format!("legacy-{}", "x".repeat(200));
        let preferred_dir = PathBuf::from("/run/user/501/cmux-tui-501");
        let preferred = session_socket_path(&preferred_dir, 501, &session).unwrap();
        assert_eq!(
            preferred,
            PathBuf::from("/run/user/501/cmux-tui-hashed-501")
                .join("e538a84493067947f7376110a6f695dd3db062b67eee939c3660c07f3f47dce2.sock")
        );

        let long_dir = PathBuf::from("/tmp").join("x".repeat(200)).join("cmux-tui-501");
        let fallback = session_socket_path(&long_dir, 501, &session).unwrap();
        assert!(fallback.starts_with("/tmp/cmux-tui-hashed-501/"));
        assert!(unix_socket_path_fits(&fallback));
    }

    #[test]
    fn session_socket_path_rejects_invalid_names_before_path_use() {
        let error = session_socket_path(Path::new("/run/cmux-tui-501"), 501, "bad/name")
            .expect_err("path separator must be rejected");
        assert!(error.contains("invalid session"));
    }

    #[test]
    fn subscribe_replay_stays_ahead_of_concurrent_output_and_exit() {
        let output = ThreadOutput::new();
        output.push_data(Bytes::from_static(b"buffered"));

        let seen = TestArc::new(TestMutex::new(Vec::<String>::new()));
        let invocations = TestArc::new(AtomicUsize::new(0));
        let entered = TestArc::new(Barrier::new(2));
        let release = TestArc::new(Barrier::new(2));

        let callback_seen = TestArc::clone(&seen);
        let callback_invocations = TestArc::clone(&invocations);
        let callback_entered = TestArc::clone(&entered);
        let callback_release = TestArc::clone(&release);
        let on_data: DataSink = TestArc::new(move |chunk| {
            let value = String::from_utf8_lossy(&chunk).into_owned();
            let invocation = callback_invocations.fetch_add(1, AtomicOrdering::Relaxed) + 1;
            if invocation == 1 {
                callback_entered.wait();
                callback_release.wait();
            }
            callback_seen.lock().expect("seen lock").push(value);
        });
        let callback_seen = TestArc::clone(&seen);
        let on_exit: ExitSink = TestArc::new(move |code| {
            callback_seen.lock().expect("seen lock").push(format!("exit:{code}"));
        });

        let subscribe_output = TestArc::clone(&output);
        let join = thread::spawn(move || subscribe_output.subscribe(on_data, on_exit));

        entered.wait();
        output.push_data(Bytes::from_static(b"live"));
        output.push_exit(7);
        release.wait();
        join.join().expect("subscribe thread");

        assert_eq!(
            *seen.lock().expect("seen lock"),
            vec!["buffered".to_owned(), "live".to_owned(), "exit:7".to_owned()]
        );
    }

    struct CountingControl(TestArc<AtomicUsize>);

    impl PtyControl for CountingControl {
        fn write(&self, _data: &[u8]) {}
        fn resize(&self, _cols: u16, _rows: u16) {}
        fn pause(&self) {}
        fn resume(&self) {}
        fn kill(&self) {
            self.0.fetch_add(1, AtomicOrdering::SeqCst);
        }
    }

    #[test]
    fn cancellation_takes_and_kills_the_temporary_handoff_owner() {
        let handoff = SpawnHandoff::new();
        let kills = TestArc::new(AtomicUsize::new(0));
        assert!(handoff.install(Arc::new(CountingControl(TestArc::clone(&kills)))));

        handoff.cancel();
        handoff.disarm();

        assert_eq!(kills.load(AtomicOrdering::SeqCst), 1);
        assert!(handoff.is_cancelled());
    }

    #[test]
    fn disarming_after_async_handoff_does_not_kill_the_live_owner() {
        let handoff = SpawnHandoff::new();
        let kills = TestArc::new(AtomicUsize::new(0));
        let control: Arc<dyn PtyControl> = Arc::new(CountingControl(TestArc::clone(&kills)));
        assert!(handoff.install(Arc::clone(&control)));

        handoff.disarm();

        assert_eq!(kills.load(AtomicOrdering::SeqCst), 0);
        drop(control);
    }

    #[test]
    fn child_lifecycle_serializes_termination_and_reap() {
        let lifecycle = ChildLifecycle::new(Some(4242));
        let signals = TestArc::new(AtomicUsize::new(0));
        let first_signalled = ChildLifecycle::terminate(&lifecycle, |pid| {
            assert_eq!(pid, Some(4242));
            signals.fetch_add(1, AtomicOrdering::SeqCst);
        });
        let second_signalled = ChildLifecycle::terminate(&lifecycle, |_| {
            signals.fetch_add(1, AtomicOrdering::SeqCst);
        });
        assert!(first_signalled);
        assert!(!second_signalled);
        ChildLifecycle::mark_exited(&lifecycle);
        assert!(!ChildLifecycle::terminate(&lifecycle, |_| {
            signals.fetch_add(1, AtomicOrdering::SeqCst);
        }));
        assert_eq!(signals.load(AtomicOrdering::SeqCst), 1);
    }

    #[test]
    fn socket_cleanup_requires_the_observed_inode() {
        use std::os::unix::net::UnixListener;

        static NEXT_FIXTURE: AtomicUsize = AtomicUsize::new(0);
        let path = std::env::temp_dir().join(format!(
            "cmux-relay-socket-fingerprint-{}-{}",
            std::process::id(),
            NEXT_FIXTURE.fetch_add(1, AtomicOrdering::Relaxed)
        ));
        let _listener = UnixListener::bind(&path).expect("create fingerprint fixture");
        let observed = socket_fingerprint(&path).expect("fixture fingerprint");
        let wrong = SocketFingerprint { device: observed.device, inode: observed.inode + 1 };
        remove_socket_if_owned(&path, Some(wrong));
        assert!(path.exists(), "mismatched inode must remain untouched");
        remove_socket_if_owned(&path, Some(observed));
        assert!(!path.exists(), "matching inode must be cleaned");
    }
}
