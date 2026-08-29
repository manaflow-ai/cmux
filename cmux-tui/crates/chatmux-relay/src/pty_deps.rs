//! Production `PtyDeps`: real PTY allocation (cmux-pty), cmux-tui binary
//! resolution, headless daemon management, and the unix control socket.
//! Behavior port of the default* helpers in `packages/relay/bin/pty.mjs`.
//!
//! PTY reads and the child wait are blocking, so each runs on a dedicated
//! blocking thread that forwards into the attachment's event channel; writes
//! and resizes go through the (blocking) master behind a mutex.

#![cfg(unix)]

use std::collections::{HashMap, VecDeque};
use std::fs::File;
use std::io::{Read, Write};
use std::mem::{offset_of, size_of};
use std::os::fd::AsRawFd;
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Condvar, Mutex, mpsc};
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
const THREAD_OUTPUT_BACKLOG_CAP: usize = 1024 * 1024;
const THREAD_OUTPUT_OVERFLOW_EXIT: i64 = 75;
const PIPE_OUTPUT_DRAIN_GRACE: Duration = Duration::from_millis(250);
const PIPE_READ_POLL_MS: i32 = 100;
// `lifecycle_ready` was added to the cmux-tui control protocol at version 12.
// This is distinct from the relay's lower-level CONTROL_MIN_PROTOCOL floor.
const DAEMON_LIFECYCLE_PROTOCOL_MIN: u64 = 12;

async fn control_ready(control: &Arc<dyn ControlHandle>, session: &str) -> bool {
    control.request("identify", serde_json::Value::Null).await.is_some_and(|response| {
        response.get("ok").and_then(serde_json::Value::as_bool) == Some(true)
            && response
                .get("data")
                .and_then(|data| data.get("app"))
                .and_then(serde_json::Value::as_str)
                == Some("cmux-tui")
            && response
                .get("data")
                .and_then(|data| data.get("session"))
                .and_then(serde_json::Value::as_str)
                == Some(session)
            && response
                .get("data")
                .and_then(|data| data.get("protocol"))
                .and_then(serde_json::Value::as_u64)
                .is_some_and(|protocol| protocol >= DAEMON_LIFECYCLE_PROTOCOL_MIN)
            && response
                .get("data")
                .and_then(|data| data.get("lifecycle_ready"))
                .and_then(serde_json::Value::as_bool)
                == Some(true)
    })
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
    backlog_bytes: usize,
    // Keep exit behind bytes that arrive before the subscriber drains.
    pending_exit: Option<i64>,
    delivering: bool,
    exited: bool,
    overflowed: bool,
}

struct ThreadOutput {
    state: Mutex<SourceState>,
    overflow_handler: Mutex<Option<Arc<dyn Fn() + Send + Sync>>>,
}

impl ThreadOutput {
    fn new() -> Arc<ThreadOutput> {
        Arc::new(ThreadOutput {
            state: Mutex::new(SourceState::default()),
            overflow_handler: Mutex::new(None),
        })
    }

    /// Install the owner cleanup that must run when the bounded source queue
    /// overflows. The callback is invoked at most once and never while the
    /// source mutex is held.
    fn set_overflow_handler(&self, handler: Arc<dyn Fn() + Send + Sync>) {
        *self.overflow_handler.lock().expect("overflow handler lock") = Some(handler);
    }

    /// Bind overflow cleanup without extending the control owner's lifetime.
    /// The source can outlive its `PtyHandle` while its reader thread drains.
    fn set_overflow_control<T>(&self, control: &Arc<T>)
    where
        T: PtyControl + 'static,
    {
        let weak_control = Arc::downgrade(control);
        self.set_overflow_handler(Arc::new(move || {
            if let Some(control) = weak_control.upgrade() {
                control.kill();
            }
        }));
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
                    state.backlog_bytes = state.backlog_bytes.saturating_sub(chunk.len());
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
        // Empty reads carry no output and must not consume an unbounded queue
        // entry while a subscriber is late.
        if chunk.is_empty() {
            return;
        }
        let (should_drain, overflowed) = {
            let mut state = self.state.lock().expect("source lock");
            if state.exited || state.overflowed {
                return;
            }
            let mut overflowed = false;
            if chunk.len() > THREAD_OUTPUT_BACKLOG_CAP.saturating_sub(state.backlog_bytes) {
                state.overflowed = true;
                state.exited = true;
                state.pending_exit = Some(THREAD_OUTPUT_OVERFLOW_EXIT);
                overflowed = true;
            } else {
                state.backlog_bytes += chunk.len();
                state.backlog.push_back(chunk);
            }
            (Self::start_delivery(&mut state), overflowed)
        };
        if overflowed
            && let Some(handler) =
                self.overflow_handler.lock().expect("overflow handler lock").clone()
        {
            handler();
        }
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

/// Orders the process exit notification after every reader has reached EOF.
/// A child can exit while bytes remain buffered in a pipe or PTY master. The
/// wait thread records the exit code, and the final reader publishes it only
/// after its last `push_data` call. Both paths use a bounded grace period; the
/// PTY reader has an explicit poll cancellation wake for inherited slave
/// descriptors. The output callback runs outside this coordinator's mutex.
struct ProcessOutputCompletion {
    state: Mutex<ProcessOutputCompletionState>,
    wake: Condvar,
    output: Arc<ThreadOutput>,
    post_exit_grace: Option<Duration>,
    cancelled: AtomicBool,
    cancel_wake: Option<Arc<CancellationWake>>,
}

struct ProcessOutputCompletionState {
    readers_remaining: usize,
    child_exit: Option<i64>,
}

/// Wakes a PTY reader that is waiting in `poll` when completion reaches its
/// bounded grace deadline. A socket pair avoids closing a descriptor from a
/// different thread, which can race with descriptor reuse.
struct CancellationWake {
    writer: Mutex<UnixStream>,
}

impl CancellationWake {
    fn new() -> std::io::Result<(Arc<Self>, UnixStream)> {
        let (reader, writer) = UnixStream::pair()?;
        writer.set_nonblocking(true)?;
        Ok((Arc::new(Self { writer: Mutex::new(writer) }), reader))
    }

    fn signal(&self) {
        let Ok(mut writer) = self.writer.lock() else { return };
        loop {
            match writer.write(&[1]) {
                Ok(_) => break,
                Err(error) if error.kind() == std::io::ErrorKind::Interrupted => continue,
                Err(_) => break,
            }
        }
    }
}

impl ProcessOutputCompletion {
    fn new(readers_remaining: usize, output: Arc<ThreadOutput>) -> Arc<Self> {
        Self::with_post_exit_grace(readers_remaining, output, Some(PIPE_OUTPUT_DRAIN_GRACE))
    }

    fn with_post_exit_grace(
        readers_remaining: usize,
        output: Arc<ThreadOutput>,
        post_exit_grace: Option<Duration>,
    ) -> Arc<Self> {
        Self::with_post_exit_grace_and_cancel(
            readers_remaining,
            output,
            post_exit_grace,
            None,
        )
    }

    fn with_pty_cancellation(
        readers_remaining: usize,
        output: Arc<ThreadOutput>,
    ) -> std::io::Result<(Arc<Self>, UnixStream)> {
        let (cancel_wake, cancel_reader) = CancellationWake::new()?;
        let completion = Self::with_post_exit_grace_and_cancel(
            readers_remaining,
            output,
            Some(PIPE_OUTPUT_DRAIN_GRACE),
            Some(cancel_wake),
        );
        Ok((completion, cancel_reader))
    }

    fn with_post_exit_grace_and_cancel(
        readers_remaining: usize,
        output: Arc<ThreadOutput>,
        post_exit_grace: Option<Duration>,
        cancel_wake: Option<Arc<CancellationWake>>,
    ) -> Arc<Self> {
        Arc::new(Self {
            state: Mutex::new(ProcessOutputCompletionState { readers_remaining, child_exit: None }),
            wake: Condvar::new(),
            output,
            post_exit_grace,
            cancelled: AtomicBool::new(false),
            cancel_wake,
        })
    }

    fn child_exited(self: &Arc<Self>, code: i64) {
        let should_watch = {
            let mut state = self.state.lock().expect("process output completion lock");
            if state.child_exit.is_some() {
                return;
            }
            state.child_exit = Some(code);
            state.readers_remaining != 0 && self.post_exit_grace.is_some()
        };
        if should_watch {
            let completion = Arc::clone(self);
            std::thread::spawn(move || completion.wait_for_readers());
        } else {
            self.emit_if_ready();
        }
    }

    fn reader_finished(&self) {
        {
            let mut state = self.state.lock().expect("process output completion lock");
            if state.readers_remaining == 0 {
                return;
            }
            state.readers_remaining -= 1;
        }
        self.wake.notify_all();
        self.emit_if_ready();
    }

    fn wait_for_readers(self: Arc<Self>) {
        let grace = self.post_exit_grace.expect("bounded completion grace");
        let deadline = Instant::now() + grace;
        let mut state = self.state.lock().expect("process output completion lock");
        while state.readers_remaining != 0 && state.child_exit.is_some() {
            let Some(remaining) = deadline.checked_duration_since(Instant::now()) else { break };
            let (next, timeout) =
                self.wake.wait_timeout(state, remaining).expect("process output completion lock");
            state = next;
            if timeout.timed_out() {
                break;
            }
        }
        if state.readers_remaining == 0 || state.child_exit.is_none() {
            return;
        }
        let code = state.child_exit.take();
        self.cancelled.store(true, Ordering::Release);
        if let Some(cancel_wake) = &self.cancel_wake {
            cancel_wake.signal();
        }
        drop(state);
        if let Some(code) = code {
            // End the source after the bounded grace period. The PTY reader's
            // poll set includes the cancellation wake, so inherited
            // descriptors cannot retain a reader thread after this point.
            self.output.push_exit(code);
        }
    }

    fn cancelled(&self) -> bool {
        self.cancelled.load(Ordering::Acquire)
    }

    fn emit_if_ready(&self) {
        let code = {
            let mut state = self.state.lock().expect("process output completion lock");
            (state.readers_remaining == 0).then(|| state.child_exit.take()).flatten()
        };
        if let Some(code) = code {
            self.output.push_exit(code);
        }
    }
}

pub struct RealPtyDeps {
    env: HashMap<String, String>,
    uid: u32,
    shell: String,
}

impl RealPtyDeps {
    pub fn new(env: HashMap<String, String>) -> RealPtyDeps {
        // SAFETY: getuid is always safe.
        let uid = unsafe { libc::getuid() };
        let shell = env.get("SHELL").cloned().unwrap_or_else(|| "/bin/sh".to_owned());
        RealPtyDeps { env, uid, shell }
    }
}

/// A real PTY master behind a mutex; write/resize block briefly.
struct MasterControl {
    master: Mutex<Box<dyn MasterPty + Send>>,
    writer: Mutex<Box<dyn Write + Send>>,
    killer: Mutex<Box<dyn cmux_pty::ChildKiller + Send + Sync>>,
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
        if let Ok(mut killer) = self.killer.lock() {
            let _ = killer.kill();
        }
    }
}

/// A command sent to the thread that owns a degraded pipe-mode child.
///
/// Keeping the child in one thread gives overflow cleanup an owned process
/// handle. A numeric PID is never retained by the output callback, so a late
/// callback cannot signal a process that reused the old PID.
enum PipeChildCommand {
    Kill,
    ExitReady,
}

/// A degraded pipe-mode shell (no TTY) used when PTY allocation fails.
/// The child itself remains owned by the wait thread. The control only sends
/// commands to that owner and retains the child's stdin for input.
struct PipeControl {
    stdin: Mutex<Option<std::process::ChildStdin>>,
    command_tx: mpsc::Sender<PipeChildCommand>,
    kill_requested: AtomicBool,
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
        if self.kill_requested.swap(true, Ordering::AcqRel) {
            return;
        }
        let _ = self.command_tx.send(PipeChildCommand::Kill);
    }
}

/// Observe a child becoming waitable without reaping it. `WNOWAIT` keeps the
/// child's PID reserved until the owner thread handles the event and calls
/// `Child::wait`, which closes the PID-reuse window around overflow cleanup.
fn wait_for_child_exit_without_reaping(pid: libc::pid_t) -> std::io::Result<()> {
    loop {
        let mut status = std::mem::MaybeUninit::<libc::siginfo_t>::zeroed();
        // SAFETY: status points to writable siginfo storage. WNOWAIT observes
        // this child without releasing its PID for reuse.
        let result = unsafe {
            libc::waitid(
                libc::P_PID,
                pid as libc::id_t,
                status.as_mut_ptr(),
                libc::WEXITED | libc::WNOWAIT,
            )
        };
        if result == 0 {
            return Ok(());
        }
        let error = std::io::Error::last_os_error();
        if error.kind() != std::io::ErrorKind::Interrupted {
            return Err(error);
        }
    }
}

fn spawn_real_pty(spec: &SpawnSpec) -> anyhow::Result<PtyHandle> {
    let pair = cmux_pty::open(PtySize {
        rows: spec.rows,
        cols: spec.cols,
        pixel_width: 0,
        pixel_height: 0,
    })?;
    let reader = File::from(pair.try_clone_reader_descriptor()?);
    let mut command = cmux_pty::PtyCommand::new(spec.file.clone());
    command.args(spec.args.clone());
    command.cwd(&spec.cwd);
    command.env_clear();
    for (key, value) in &spec.env {
        command.env(key, value);
    }
    let spawned = pair.spawn(command)?;
    let writer = spawned.master.take_writer()?;
    let killer = spawned.child.clone_killer();
    let output = ThreadOutput::new();
    let control = Arc::new(MasterControl {
        master: Mutex::new(spawned.master),
        writer: Mutex::new(writer),
        killer: Mutex::new(killer),
    });
    output.set_overflow_control(&control);
    // Use the same bounded post-exit grace as pipe fallback. A background
    // descendant can inherit the PTY slave, so waiting for terminal EOF here
    // would otherwise delay the primary child exit without a bound.
    let (completion, cancel_reader) =
        ProcessOutputCompletion::with_pty_cancellation(1, Arc::clone(&output))?;

    // Blocking reader thread -> output sink.
    let data_output = Arc::clone(&output);
    let data_completion = Arc::clone(&completion);
    std::thread::spawn(move || {
        pump_pty(reader, cancel_reader, data_output, data_completion);
    });
    // Blocking wait thread -> exit.
    let mut child = spawned.child;
    let exit_completion = Arc::clone(&completion);
    std::thread::spawn(move || {
        let code = child.wait().map(|status| i64::from(status.exit_code() as i32)).unwrap_or(0);
        exit_completion.child_exited(code);
    });

    Ok(PtyHandle { control, output, banner: None })
}

/// Read a PTY with an owned descriptor and an explicit cancellation wake.
/// `Read::read` is called only after the descriptor reports readiness, so a
/// descendant-held PTY slave cannot leave this thread blocked past the grace
/// deadline.
fn pump_pty(
    mut reader: impl Read + AsRawFd,
    cancel_reader: UnixStream,
    output: Arc<ThreadOutput>,
    completion: Arc<ProcessOutputCompletion>,
) {
    let reader_fd = reader.as_raw_fd();
    let cancel_fd = cancel_reader.as_raw_fd();
    let mut buffer = [0_u8; 32_768];
    loop {
        let mut poll_fds = [
            libc::pollfd { fd: reader_fd, events: libc::POLLIN, revents: 0 },
            libc::pollfd { fd: cancel_fd, events: libc::POLLIN, revents: 0 },
        ];
        let poll_result = unsafe { libc::poll(poll_fds.as_mut_ptr(), poll_fds.len() as _, -1) };
        if poll_result < 0 {
            if std::io::Error::last_os_error().kind() == std::io::ErrorKind::Interrupted {
                continue;
            }
            break;
        }
        if completion.cancelled() || poll_fds[1].revents != 0 {
            break;
        }
        if poll_fds[0].revents == 0 {
            continue;
        }
        match reader.read(&mut buffer) {
            Ok(0) => break,
            Err(error) if error.raw_os_error() == Some(libc::EIO) => break,
            Err(_) => break,
            Ok(count) => output.push_data(Bytes::copy_from_slice(&buffer[..count])),
        }
    }
    completion.reader_finished();
}

fn spawn_pipe_mode(spec: &SpawnSpec, reason: &str) -> PtyHandle {
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
    let banner = format!(
        "[cmux-relay] PTY allocation failed ({reason}); running {} without a TTY.\r\n",
        Path::new(&spec.file)
            .file_name()
            .map(|n| n.to_string_lossy().into_owned())
            .unwrap_or_else(|| spec.file.clone()),
    );
    match command.spawn() {
        Ok(mut child) => {
            let stdin = child.stdin.take();
            let pid = child.id() as libc::pid_t;
            let (command_tx, command_rx) = mpsc::channel();
            let control = Arc::new(PipeControl {
                stdin: Mutex::new(stdin),
                command_tx: command_tx.clone(),
                kill_requested: AtomicBool::new(false),
            });
            output.set_overflow_control(&control);
            let reader_count = child.stdout.is_some() as usize + child.stderr.is_some() as usize;
            let completion = ProcessOutputCompletion::new(reader_count, Arc::clone(&output));
            if let Some(stdout) = child.stdout.take() {
                let out = Arc::clone(&output);
                let done = Arc::clone(&completion);
                std::thread::spawn(move || pump_pipe(stdout, out, done));
            }
            if let Some(stderr) = child.stderr.take() {
                let out = Arc::clone(&output);
                let done = Arc::clone(&completion);
                std::thread::spawn(move || pump_pipe(stderr, out, done));
            }
            // Observe exit without reaping. The owner thread handles both
            // overflow kill requests and the final wait, so all process
            // signals use the still-owned Child handle.
            let observer_tx = command_tx;
            std::thread::spawn(move || {
                let _ = wait_for_child_exit_without_reaping(pid);
                let _ = observer_tx.send(PipeChildCommand::ExitReady);
            });
            let wait_completion = Arc::clone(&completion);
            std::thread::spawn(move || {
                let mut exit_ready = false;
                while !exit_ready {
                    match command_rx.recv() {
                        Ok(PipeChildCommand::ExitReady) => exit_ready = true,
                        Ok(PipeChildCommand::Kill) => {
                            let _ = child.kill();
                        }
                        Err(_) => exit_ready = true,
                    }
                }
                let code =
                    child.wait().map(|status| status.code().unwrap_or(0) as i64).unwrap_or(0);
                wait_completion.child_exited(code);
            });
            PtyHandle { control, output, banner: Some(banner.into_bytes()) }
        }
        Err(error) => {
            let _ = error;
            output.push_exit(1);
            PtyHandle { control: Arc::new(DeadControl), output, banner: Some(banner.into_bytes()) }
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

fn pump_pipe(
    mut stream: impl Read + AsRawFd,
    output: Arc<ThreadOutput>,
    completion: Arc<ProcessOutputCompletion>,
) {
    let fd = stream.as_raw_fd();
    let mut buffer = [0_u8; 32_768];
    loop {
        if completion.cancelled() {
            break;
        }
        let mut poll_fd = libc::pollfd { fd, events: libc::POLLIN, revents: 0 };
        let poll_result = unsafe { libc::poll(&mut poll_fd, 1, PIPE_READ_POLL_MS) };
        if poll_result < 0 {
            if std::io::Error::last_os_error().raw_os_error() == Some(libc::EINTR) {
                continue;
            }
            break;
        }
        if poll_result == 0 {
            continue;
        }
        if poll_fd.revents & libc::POLLNVAL != 0 {
            break;
        }
        match stream.read(&mut buffer) {
            Ok(0) => break,
            Err(_) => break,
            Ok(count) => output.push_data(Bytes::copy_from_slice(&buffer[..count])),
        }
    }
    completion.reader_finished();
}

async fn socket_exists(path: &Path) -> bool {
    tokio::fs::metadata(path).await.is_ok()
}

/// Stop a daemon that was started by `ensure_daemon` but never became ready.
/// The daemon is placed in its own process group, so cleanup also covers
/// children it may have spawned before readiness failed.
async fn cleanup_daemon(mut child: tokio::process::Child) {
    if let Some(pid) = child.id() {
        unsafe {
            let _ = libc::kill(-(pid as libc::pid_t), libc::SIGTERM);
        }
    }
    if tokio::time::timeout(Duration::from_millis(250), child.wait()).await.is_ok() {
        return;
    }
    if let Some(pid) = child.id() {
        unsafe {
            let _ = libc::kill(-(pid as libc::pid_t), libc::SIGKILL);
        }
    }
    let _ = child.kill().await;
    let _ = tokio::time::timeout(Duration::from_secs(1), child.wait()).await;
}

#[async_trait]
impl PtyDeps for RealPtyDeps {
    async fn spawn_pty(&self, spec: SpawnSpec) -> PtyHandle {
        // PTY allocation and thread setup are blocking; run off the reactor.
        // On PTY allocation failure (ptmx exhaustion et al) degrade to a
        // pipe-mode shell so the terminal still functions, with a banner.
        let output = ThreadOutput::new();
        tokio::task::spawn_blocking(move || match spawn_real_pty(&spec) {
            Ok(handle) => handle,
            Err(error) => spawn_pipe_mode(&spec, &error.to_string()),
        })
        .await
        .unwrap_or_else(|_| {
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
        let metadata = tokio::fs::metadata(socket_dir)
            .await
            .map_err(|error| format!("control socket directory stat failed: {error}"))?;
        if !metadata.is_dir() || metadata.uid() != self.uid {
            return Err(format!("control socket directory is not owned by uid {}", self.uid));
        }
        let mut permissions = metadata.permissions();
        permissions.set_mode(0o700);
        tokio::fs::set_permissions(socket_dir, permissions)
            .await
            .map_err(|error| format!("control socket directory permissions failed: {error}"))?;
        let socket_path = session_socket_path(socket_dir, self.uid, session)?;
        if socket_exists(&socket_path).await {
            let ready = match connect_control(&socket_path, CONTROL_TIMEOUT_MS).await {
                Ok(control) => control_ready(&control, session).await,
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
        let mut command = tokio::process::Command::new(&cmux_tui.file);
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

        let deadline = Instant::now() + Duration::from_millis(DAEMON_SOCKET_WAIT_MS);
        while Instant::now() < deadline {
            if socket_exists(&socket_path).await {
                // Probe a control round-trip before declaring readiness.
                while Instant::now() < deadline {
                    match connect_control(&socket_path, CONTROL_TIMEOUT_MS).await {
                        Ok(control) if control_ready(&control, session).await => {
                            return Ok(EnsureDaemon { created: true, socket_path });
                        }
                        _ => tokio::time::sleep(Duration::from_millis(50)).await,
                    }
                }
                // Do not unlink the path here. Another daemon may have won
                // the socket race after our initial absence check; ownership
                // of a pathname cannot be proven after the fact.
                cleanup_daemon(child).await;
                return Err(format!(
                    "cmux-tui daemon for \"{session}\" did not become control-ready"
                ));
            }
            tokio::time::sleep(Duration::from_millis(50)).await;
        }
        cleanup_daemon(child).await;
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
    use std::os::unix::net::UnixStream;
    use std::sync::atomic::{AtomicUsize, Ordering as AtomicOrdering};
    use std::sync::{Arc as TestArc, Barrier, Mutex as TestMutex, mpsc};
    use std::thread;

    struct TestControl {
        kills: TestArc<AtomicUsize>,
        drops: TestArc<AtomicUsize>,
    }

    impl Drop for TestControl {
        fn drop(&mut self) {
            self.drops.fetch_add(1, AtomicOrdering::Relaxed);
        }
    }

    impl PtyControl for TestControl {
        fn write(&self, _data: &[u8]) {}
        fn resize(&self, _cols: u16, _rows: u16) {}
        fn pause(&self) {}
        fn resume(&self) {}
        fn kill(&self) {
            self.kills.fetch_add(1, AtomicOrdering::Relaxed);
        }
    }

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

    #[test]
    fn backlog_overflow_preserves_prefix_and_emits_terminal_exit_once() {
        let output = ThreadOutput::new();
        let kills = TestArc::new(AtomicUsize::new(0));
        let kill_counter = TestArc::clone(&kills);
        output.set_overflow_handler(TestArc::new(move || {
            kill_counter.fetch_add(1, AtomicOrdering::Relaxed);
        }));
        output.push_data(Bytes::from(vec![b'x'; THREAD_OUTPUT_BACKLOG_CAP]));
        output.push_data(Bytes::from_static(b"overflow"));
        output.push_exit(0);
        let seen = TestArc::new(TestMutex::new(Vec::new()));
        let data_seen = TestArc::clone(&seen);
        let exit_seen = TestArc::clone(&seen);
        output.subscribe(
            TestArc::new(move |chunk| {
                data_seen.lock().expect("seen lock").push(format!("data:{}", chunk.len()))
            }),
            TestArc::new(move |code| {
                exit_seen.lock().expect("seen lock").push(format!("exit:{code}"))
            }),
        );
        assert_eq!(
            *seen.lock().expect("seen lock"),
            vec![format!("data:{THREAD_OUTPUT_BACKLOG_CAP}"), "exit:75".to_owned()]
        );
        output.push_data(Bytes::from_static(b"another overflow"));
        assert_eq!(kills.load(AtomicOrdering::Relaxed), 1);
    }

    #[test]
    fn overflow_control_kills_live_owner_without_retaining_it() {
        let output = ThreadOutput::new();
        let kills = TestArc::new(AtomicUsize::new(0));
        let drops = TestArc::new(AtomicUsize::new(0));
        let control = TestArc::new(TestControl {
            kills: TestArc::clone(&kills),
            drops: TestArc::clone(&drops),
        });
        let weak_control = TestArc::downgrade(&control);
        output.set_overflow_control(&control);

        output.push_data(Bytes::from(vec![b'x'; THREAD_OUTPUT_BACKLOG_CAP]));
        output.push_data(Bytes::from_static(b"overflow"));
        assert_eq!(kills.load(AtomicOrdering::Relaxed), 1);

        drop(control);
        assert!(weak_control.upgrade().is_none());
        assert_eq!(drops.load(AtomicOrdering::Relaxed), 1);
    }

    #[test]
    fn pipe_control_sends_one_kill_request_to_owned_child() {
        let (command_tx, command_rx) = mpsc::channel();
        let control = PipeControl {
            stdin: Mutex::new(None),
            command_tx,
            kill_requested: AtomicBool::new(false),
        };

        control.kill();
        control.kill();

        assert!(matches!(command_rx.recv(), Ok(PipeChildCommand::Kill)));
        assert!(command_rx.try_recv().is_err());
    }

    #[test]
    fn child_exit_observer_leaves_child_owned_for_wait() {
        let mut child = std::process::Command::new("/bin/sh")
            .args(["-c", "exit 23"])
            .spawn()
            .expect("spawn child");
        wait_for_child_exit_without_reaping(child.id() as libc::pid_t).expect("observe child");
        assert_eq!(child.wait().expect("reap child").code(), Some(23));
    }

    #[test]
    fn empty_chunks_do_not_bypass_backlog_cap() {
        let output = ThreadOutput::new();
        for _ in 0..10_000 {
            output.push_data(Bytes::new());
        }

        let state = output.state.lock().expect("source lock");
        assert!(state.backlog.is_empty());
        assert_eq!(state.backlog_bytes, 0);
    }

    #[test]
    fn pipe_exit_waits_for_reader_eof_before_delivering_late_bytes() {
        let output = ThreadOutput::new();
        let completion = ProcessOutputCompletion::new(1, TestArc::clone(&output));
        completion.child_exited(23);
        output.push_data(Bytes::from_static(b"tail"));
        completion.reader_finished();

        let seen = TestArc::new(TestMutex::new(Vec::<String>::new()));
        let data_seen = TestArc::clone(&seen);
        let exit_seen = TestArc::clone(&seen);
        output.subscribe(
            TestArc::new(move |chunk| {
                data_seen
                    .lock()
                    .expect("seen lock")
                    .push(String::from_utf8_lossy(&chunk).into_owned())
            }),
            TestArc::new(move |code| {
                exit_seen.lock().expect("seen lock").push(format!("exit:{code}"))
            }),
        );

        assert_eq!(*seen.lock().expect("seen lock"), vec!["tail".to_owned(), "exit:23".to_owned()]);
    }

    #[test]
    fn inherited_pty_descriptor_cannot_hold_exit_forever() {
        // The PTY completion path uses the same bounded grace coordinator as
        // pipe fallback. An open stream models a background descendant that
        // inherited the PTY slave and keeps the reader from reaching EOF.
        let output = ThreadOutput::new();
        let completion = ProcessOutputCompletion::new(1, TestArc::clone(&output));
        let (reader, _writer) = UnixStream::pair().expect("pipe pair");
        let (exit_tx, exit_rx) = mpsc::channel();
        let (reader_done_tx, reader_done_rx) = mpsc::channel();
        let pump_output = TestArc::clone(&output);
        let pump_completion = TestArc::clone(&completion);
        thread::spawn(move || {
            pump_pipe(reader, pump_output, pump_completion);
            reader_done_tx.send(()).expect("reader completion");
        });
        output.subscribe(
            TestArc::new(|_| {}),
            TestArc::new(move |code| exit_tx.send(code).expect("exit delivery")),
        );

        completion.child_exited(41);

        assert_eq!(
            exit_rx
                .recv_timeout(Duration::from_secs(1))
                .expect("inherited descriptors must not suppress exit"),
            41
        );
        reader_done_rx
            .recv_timeout(Duration::from_secs(1))
            .expect("reader must stop after bounded post-exit recovery");
    }

    #[test]
    fn pty_reader_cancellation_wakes_a_blocked_poll() {
        let output = ThreadOutput::new();
        let (completion, cancel_reader) =
            ProcessOutputCompletion::with_pty_cancellation(1, TestArc::clone(&output))
                .expect("cancellation wake");
        let (reader_stream, _writer_stream) = UnixStream::pair().expect("PTY-like stream pair");
        let reader = reader_stream;
        let (reader_done_tx, reader_done_rx) = mpsc::channel();
        let pump_output = TestArc::clone(&output);
        let pump_completion = TestArc::clone(&completion);
        thread::spawn(move || {
            pump_pty(reader, cancel_reader, pump_output, pump_completion);
            reader_done_tx.send(()).expect("reader completion");
        });

        completion.child_exited(41);

        reader_done_rx
            .recv_timeout(Duration::from_secs(1))
            .expect("cancellation must wake a blocked PTY poll");
    }
}
