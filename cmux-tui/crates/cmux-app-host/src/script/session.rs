//! One script session: the host process, its reader thread, and the cells
//! that run in it one at a time.

use std::collections::HashMap;
use std::fmt;
use std::io::{BufRead, BufReader, Read, Write};
use std::os::fd::AsRawFd;
use std::os::unix::net::UnixStream;
use std::os::unix::process::CommandExt;
use std::path::Path;
use std::process::{Command, Stdio};
use std::sync::atomic::{AtomicBool, AtomicU64, AtomicUsize, Ordering};
use std::sync::mpsc::{self, RecvTimeoutError, Sender};
use std::sync::{Arc, Mutex, PoisonError, Weak};
use std::time::Duration;

use serde_json::{Value, json};

use super::prelude;
use crate::protocol::{
    AppInfo, FatalReason, FromHost, MAX_LINE_BYTES, SCRIPT_MEMORY_BYTES, SCRIPT_PROFILE,
    SCRIPT_STEP_MS, ToHost,
};

/// Wall time of one cell when the caller gives none.
pub const DEFAULT_TIMEOUT: Duration = Duration::from_secs(60);
/// The longest wall time a caller may ask for.
pub const MAX_TIMEOUT: Duration = Duration::from_secs(600);
/// How long the host may take to load the prelude.
const START_TIMEOUT: Duration = Duration::from_secs(15);
/// Op calls one session may have in flight (the VM caps itself too, but the
/// VM is untrusted).
const MAX_INFLIGHT: usize = 64;
/// Live subscriptions one session may hold (the VM's own cap).
const MAX_SUBSCRIPTIONS: usize = 256;

/// Error codes of a cell (an op's own error keeps the op's code).
pub mod codes {
    /// The cell threw something that is not a `CmuxError`, or did not parse.
    pub const ERROR: &str = "script.error";
    /// The cell ran past its wall time; the session ended.
    pub const TIMEOUT: &str = "script.timeout";
    /// The VM used more memory than the script profile allows; the session ended.
    pub const MEMORY: &str = "script.memory";
    /// One step ran longer than the script profile allows without yielding; the session ended.
    pub const CPU: &str = "script.cpu";
    /// The caller cancelled; the session ended.
    pub const CANCELLED: &str = "script.cancelled";
    /// The host could not start, or exited.
    pub const HOST: &str = "script.host";
    /// Another cell of this session is running.
    pub const BUSY: &str = "script.busy";
}

/// Checks and runs the ops a script calls. The daemon implements it.
pub trait ScriptRouter: Send + Sync + 'static {
    /// Runs one op. Ok is the ABI ok body (`{value, ...}`), Err the ABI error
    /// body (`{code, message, details?, retryable}`).
    fn call(&self, op: &str, params: Value, options: Value) -> Result<Value, Value>;
    /// Starts calling `publish` with stream names (`resource.changed`, ...)
    /// until the returned guard drops. Called at most once per session, on
    /// its first subscription.
    fn watch(&self, publish: Arc<dyn Fn(&str) + Send + Sync>) -> Box<dyn Send>;
}

/// Receives the cell's console output: `(level, message)`.
pub type LogSink = Arc<dyn Fn(&str, &str) + Send + Sync>;

#[derive(Debug, Clone, PartialEq)]
pub struct ScriptError {
    pub code: String,
    pub message: String,
    pub details: Value,
}

impl ScriptError {
    pub fn new(code: &str, message: impl Into<String>) -> Self {
        Self { code: code.to_string(), message: message.into(), details: Value::Null }
    }

    fn from_body(body: &Value) -> Self {
        Self {
            code: body["code"].as_str().unwrap_or(codes::ERROR).to_string(),
            message: body["message"].as_str().unwrap_or("the script failed").to_string(),
            details: body.get("details").cloned().unwrap_or(Value::Null),
        }
    }

    /// `{code, message, details?}`.
    pub fn to_json(&self) -> Value {
        let mut value = json!({ "code": self.code, "message": self.message });
        if !self.details.is_null() {
            value["details"] = self.details.clone();
        }
        value
    }
}

impl fmt::Display for ScriptError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}: {}", self.code, self.message)
    }
}

struct Shared {
    writer: Mutex<UnixStream>,
    /// Shuts the socket down without the writer lock, which a write to a
    /// host that stopped reading can hold.
    killer: UnixStream,
    /// One sender per running cell, keyed by the `run` callback id.
    waiters: Mutex<HashMap<u64, Sender<(bool, Value)>>>,
    subs: Mutex<HashMap<u64, String>>,
    watch: Mutex<Option<Box<dyn Send>>>,
    inflight: AtomicUsize,
    fatal: Mutex<Option<FatalReason>>,
    cancelled: AtomicBool,
    timed_out: AtomicBool,
    /// Set (under the `waiters` lock) once the host is gone.
    dead: AtomicBool,
    router: Arc<dyn ScriptRouter>,
    log: LogSink,
}

fn lock<T>(mutex: &Mutex<T>) -> std::sync::MutexGuard<'_, T> {
    mutex.lock().unwrap_or_else(PoisonError::into_inner)
}

impl Shared {
    fn send(&self, message: &ToHost) {
        let Ok(mut line) = serde_json::to_vec(message) else { return };
        line.push(b'\n');
        let mut writer = lock(&self.writer);
        if writer.write_all(&line).and_then(|()| writer.flush()).is_err() {
            let _ = writer.shutdown(std::net::Shutdown::Both);
        }
    }

    /// Closes the channel both ways: the host reads end of input and exits,
    /// and the reader thread reaps it.
    fn kill(&self) {
        let _ = self.killer.shutdown(std::net::Shutdown::Both);
    }

    fn publish(&self, stream: &str) {
        let subs: Vec<u64> = lock(&self.subs)
            .iter()
            .filter(|(_, s)| s.as_str() == stream)
            .map(|(id, _)| *id)
            .collect();
        for sub in subs {
            self.send(&ToHost::Event { sub, body: json!({ "stream": stream }) });
        }
    }

    fn dead_error(&self) -> ScriptError {
        if self.cancelled.load(Ordering::Acquire) {
            return ScriptError::new(codes::CANCELLED, "the script was cancelled");
        }
        if self.timed_out.load(Ordering::Acquire) {
            return ScriptError::new(
                codes::TIMEOUT,
                "an earlier cell ran past its time and ended the session",
            );
        }
        match *lock(&self.fatal) {
            Some(FatalReason::Memory) => ScriptError::new(
                codes::MEMORY,
                format!("the script used more than {} MiB", SCRIPT_MEMORY_BYTES / (1024 * 1024)),
            ),
            Some(FatalReason::Interrupt) => ScriptError::new(
                codes::CPU,
                format!("one script step ran longer than {SCRIPT_STEP_MS} ms without yielding"),
            ),
            _ => ScriptError::new(codes::HOST, "the script runtime exited"),
        }
    }

    fn handle(self: &Arc<Self>, message: FromHost, ready: &mut Option<Sender<Result<(), String>>>) {
        match message {
            FromHost::Ready { .. } => {
                if let Some(ready) = ready.take() {
                    let _ = ready.send(Ok(()));
                }
            }
            FromHost::InitFailed { error } => {
                if let Some(ready) = ready.take() {
                    let _ = ready.send(Err(error));
                }
            }
            FromHost::Call { cb, name, params, options } => self.call(cb, name, params, options),
            FromHost::Subscribe { sub, stream, .. } => {
                {
                    let mut subs = lock(&self.subs);
                    if subs.len() >= MAX_SUBSCRIPTIONS {
                        // The VM caps itself too; a host past this is broken.
                        drop(subs);
                        self.kill();
                        return;
                    }
                    subs.insert(sub, stream);
                }
                let mut watch = lock(&self.watch);
                if watch.is_none() {
                    let me: Weak<Self> = Arc::downgrade(self);
                    let publish: Arc<dyn Fn(&str) + Send + Sync> = Arc::new(move |stream| {
                        if let Some(me) = me.upgrade() {
                            me.publish(stream);
                        }
                    });
                    *watch = Some(self.router.watch(publish));
                }
            }
            FromHost::Unsubscribe { sub } => {
                lock(&self.subs).remove(&sub);
            }
            FromHost::Log { level, message } => (self.log)(&level, &message),
            FromHost::Done { cb, ok, body } => {
                if let Some(waiter) = lock(&self.waiters).remove(&cb) {
                    let _ = waiter.send((ok, body));
                }
            }
            FromHost::Fatal { reason, .. } => *lock(&self.fatal) = Some(reason),
            FromHost::Mounted { .. } | FromHost::Scene { .. } => {}
        }
    }

    /// Runs one op on a worker thread and answers the host.
    fn call(self: &Arc<Self>, cb: u64, name: String, params: Value, options: Value) {
        if self.inflight.fetch_add(1, Ordering::AcqRel) >= MAX_INFLIGHT {
            self.inflight.fetch_sub(1, Ordering::AcqRel);
            let body = json!({ "code": "app.limit", "message": "too many calls in flight", "retryable": true });
            self.send(&ToHost::Resolve { cb, ok: false, body });
            return;
        }
        let me = self.clone();
        let spawned =
            std::thread::Builder::new().name("cmux-script-call".into()).spawn(move || {
                let (ok, body) = match me.router.call(&name, params, options) {
                    Ok(body) => (true, body),
                    Err(body) => (false, body),
                };
                me.inflight.fetch_sub(1, Ordering::AcqRel);
                me.send(&ToHost::Resolve { cb, ok, body });
            });
        if let Err(error) = spawned {
            self.inflight.fetch_sub(1, Ordering::AcqRel);
            let body = json!({ "code": "operation.failed", "message": format!("no worker thread: {error}"), "retryable": true });
            self.send(&ToHost::Resolve { cb, ok: false, body });
        }
    }

    /// The host is gone: every waiting cell sees a closed channel.
    fn mark_dead(&self) {
        let mut waiters = lock(&self.waiters);
        self.dead.store(true, Ordering::Release);
        waiters.clear();
        drop(waiters);
        lock(&self.subs).clear();
        let watch = lock(&self.watch).take();
        drop(watch);
    }
}

/// One script session. Dropping it ends the host process.
pub struct Session {
    shared: Arc<Shared>,
    next_cb: AtomicU64,
    turn: Mutex<()>,
}

impl Session {
    /// Spawns `binary` in the script profile and loads the prelude. `log`
    /// receives console output from every cell.
    pub fn start(
        binary: &Path,
        router: Arc<dyn ScriptRouter>,
        log: LogSink,
    ) -> Result<Self, ScriptError> {
        let host_error =
            |what: &str, e: std::io::Error| ScriptError::new(codes::HOST, format!("{what}: {e}"));
        let (ours, theirs) = UnixStream::pair().map_err(|e| host_error("socketpair", e))?;
        let fd = theirs.as_raw_fd();
        let mut command = Command::new(binary);
        command
            .args(["--profile", SCRIPT_PROFILE])
            .env_clear()
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null());
        // SAFETY: sysconf before the fork; only async-signal-safe calls in pre_exec.
        let max_fd = match unsafe { libc::sysconf(libc::_SC_OPEN_MAX) } {
            n if n > 0 => n.min(65_536) as libc::c_int,
            _ => 4096,
        };
        // SAFETY: only async-signal-safe calls between fork and exec.
        unsafe { command.pre_exec(move || child_fds(fd, max_fd)) };
        let mut child =
            command.spawn().map_err(|e| host_error("could not start the script runtime", e))?;
        drop(theirs);
        let (writer, killer) = match (ours.try_clone(), ours.try_clone()) {
            (Ok(writer), Ok(killer)) => (writer, killer),
            (Err(e), _) | (_, Err(e)) => {
                let _ = child.kill();
                let _ = child.wait();
                return Err(host_error("socket", e));
            }
        };
        let pid = child.id();
        let shared = Arc::new(Shared {
            writer: Mutex::new(writer),
            killer,
            waiters: Mutex::new(HashMap::new()),
            subs: Mutex::new(HashMap::new()),
            watch: Mutex::new(None),
            inflight: AtomicUsize::new(0),
            fatal: Mutex::new(None),
            cancelled: AtomicBool::new(false),
            timed_out: AtomicBool::new(false),
            dead: AtomicBool::new(false),
            router,
            log,
        });
        let (ready_tx, ready_rx) = mpsc::channel();
        let reader_shared = shared.clone();
        let spawned =
            std::thread::Builder::new().name("cmux-script-host".into()).spawn(move || {
                let mut ready = Some(ready_tx);
                let mut lines = BufReader::new(ours);
                let mut line = Vec::new();
                loop {
                    line.clear();
                    match lines
                        .by_ref()
                        .take(MAX_LINE_BYTES as u64 + 1)
                        .read_until(b'\n', &mut line)
                    {
                        Ok(0) | Err(_) => break,
                        Ok(_) if line.last() != Some(&b'\n') => break,
                        Ok(_) => match serde_json::from_slice::<FromHost>(&line) {
                            Ok(message) => reader_shared.handle(message, &mut ready),
                            Err(_) => break,
                        },
                    }
                }
                reader_shared.kill();
                let _ = child.kill();
                let _ = child.wait();
                reader_shared.mark_dead();
                if let Some(ready) = ready.take() {
                    let _ = ready.send(Err("the script runtime exited".into()));
                }
            });
        if let Err(e) = spawned {
            shared.kill();
            // The reader owned the child; end and reap it by pid.
            // SAFETY: our own unreaped child, so the pid is still ours.
            unsafe {
                libc::kill(pid as libc::pid_t, libc::SIGKILL);
                libc::waitpid(pid as libc::pid_t, std::ptr::null_mut(), 0);
            }
            return Err(host_error("reader thread", e));
        }
        shared.send(&ToHost::Init {
            app: AppInfo { id: prelude::APP_ID.into(), version: env!("CARGO_PKG_VERSION").into() },
            settings: json!({}),
            api_version: "1.0.0".into(),
            ops: None,
            known_ops: None,
            locale: None,
            strings: json!({}),
            main: prelude::main_source(),
        });
        match ready_rx.recv_timeout(START_TIMEOUT) {
            Ok(Ok(())) => Ok(Self { shared, next_cb: AtomicU64::new(1), turn: Mutex::new(()) }),
            Ok(Err(error)) => {
                shared.kill();
                Err(ScriptError::new(
                    codes::HOST,
                    format!("the script runtime did not start: {error}"),
                ))
            }
            Err(_) => {
                shared.kill();
                Err(ScriptError::new(codes::HOST, "the script runtime did not start in time"))
            }
        }
    }

    /// Runs one cell with `args` as `cmux.args`. The result is the value of
    /// the cell's last expression statement as JSON. A timeout, a limit or a
    /// cancel ends the session; later cells fail with the same error.
    pub fn eval(&self, code: &str, args: Value, timeout: Duration) -> Result<Value, ScriptError> {
        let Ok(_turn) = self.turn.try_lock() else {
            return Err(ScriptError::new(codes::BUSY, "another cell of this session is running"));
        };
        let cb = self.next_cb.fetch_add(1, Ordering::Relaxed);
        let (tx, rx) = mpsc::channel();
        {
            let mut waiters = lock(&self.shared.waiters);
            if self.shared.dead.load(Ordering::Acquire) {
                return Err(self.shared.dead_error());
            }
            waiters.insert(cb, tx);
        }
        self.shared.send(&ToHost::Run {
            cb,
            export: "eval".into(),
            args: json!({ "code": code, "args": args }),
            gesture: None,
        });
        let timeout = timeout.min(MAX_TIMEOUT);
        match rx.recv_timeout(timeout) {
            Ok((true, body)) => Ok(body.get("value").cloned().unwrap_or(Value::Null)),
            Ok((false, body)) => Err(ScriptError::from_body(&body)),
            Err(RecvTimeoutError::Timeout) => {
                lock(&self.shared.waiters).remove(&cb);
                self.shared.timed_out.store(true, Ordering::Release);
                self.shared.kill();
                Err(ScriptError::new(
                    codes::TIMEOUT,
                    format!("the script ran longer than {} ms", timeout.as_millis()),
                ))
            }
            Err(RecvTimeoutError::Disconnected) => Err(self.shared.dead_error()),
        }
    }

    /// Ends the session from any thread; a running cell fails with
    /// `script.cancelled`.
    pub fn cancel(&self) {
        self.shared.cancelled.store(true, Ordering::Release);
        self.shared.kill();
    }

    /// True once the host is gone.
    pub fn is_dead(&self) -> bool {
        self.shared.dead.load(Ordering::Acquire)
    }
}

impl Drop for Session {
    fn drop(&mut self) {
        self.shared.kill();
    }
}

/// In the child before exec: the channel on fd 3 without close-on-exec, and
/// every other inherited descriptor above 2 closed.
fn child_fds(fd: libc::c_int, max_fd: libc::c_int) -> std::io::Result<()> {
    // SAFETY: plain descriptor syscalls on this (forked, single-threaded) process.
    unsafe {
        if fd == 3 {
            if libc::fcntl(3, libc::F_SETFD, 0) != 0 {
                return Err(std::io::Error::last_os_error());
            }
        } else if libc::dup2(fd, 3) != 3 {
            return Err(std::io::Error::last_os_error());
        }
        // Linux closes every descriptor above 3 at once, whatever the limit.
        #[cfg(target_os = "linux")]
        if libc::syscall(libc::SYS_close_range, 4_u32, u32::MAX, 0_u32) == 0 {
            return Ok(());
        }
        for other in 4..max_fd {
            libc::close(other);
        }
    }
    Ok(())
}
