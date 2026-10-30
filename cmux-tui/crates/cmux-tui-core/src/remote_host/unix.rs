#![cfg_attr(not(target_os = "macos"), allow(dead_code))]
use std::collections::HashMap;
use std::io::{BufRead, BufReader, Write};
use std::path::{Path, PathBuf};
use std::sync::mpsc::{Receiver, SyncSender};
use std::sync::{Arc, Mutex, PoisonError, Weak};
use std::time::{Duration, Instant};

use serde_json::{Value, json};

use crate::backoff::Backoff;

#[cfg(target_os = "macos")]
#[path = "macos.rs"]
mod platform;

/// Advertised by `identify` once `remote-host-status` and `remote-host-call` exist.
/// The supervisor protocol range this daemon speaks (the host picks one in it).
const PROTOCOL_MIN: u64 = 1;
const PROTOCOL_MAX: u64 = 1;
/// How long a starting host may take to report that it serves.
const READY_TIMEOUT: Duration = Duration::from_secs(15);
/// How long one request to the host may take (a permission prompt answers at once).
const CALL_TIMEOUT: Duration = Duration::from_secs(20);
/// A host that ran at least this long before it stopped restarts at the
/// first backoff delay again.
const HEALTHY_RUN: Duration = Duration::from_secs(30);

/// What the person turned on (`config.json`, kept for the next daemon start).
#[derive(Clone, Debug, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
pub(crate) struct RemoteConfig {
    #[serde(default)]
    pub(crate) computer_use: bool,
    #[serde(default)]
    pub(crate) screen_sharing: bool,
    #[serde(default = "yes")]
    pub(crate) headless: bool,
}

fn yes() -> bool {
    true
}

impl Default for RemoteConfig {
    fn default() -> Self {
        Self { computer_use: false, screen_sharing: false, headless: true }
    }
}

impl RemoteConfig {
    fn wanted(&self) -> bool {
        self.computer_use || self.screen_sharing
    }
}

/// The adoption record (`host.json`, 0600), written by the daemon that started the host.
#[derive(Clone, Debug, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
struct HostRecord {
    pid: u32,
    start_sec: u64,
    start_usec: u64,
    /// 64 lowercase hex digits.
    secret: String,
    /// The staged bundle's digest: another digest means another build.
    bundle_digest: String,
    socket: PathBuf,
}

/// Where one daemon's host lives.
#[derive(Clone, Debug)]
pub(crate) struct Paths {
    /// Sockets and the record: `rh-<digest>` beside the daemon socket (0700).
    pub(crate) runtime: PathBuf,
    /// Persistent: the staged bundle, `config.json`, the worker's device state.
    pub(crate) state: PathBuf,
    /// This app build's scope (the worker's Keychain items, one device per build).
    pub(crate) scope: String,
}

impl Paths {
    fn record(&self) -> PathBuf {
        self.runtime.join("host.json")
    }
    fn supervisor_socket(&self) -> PathBuf {
        self.runtime.join("s.sock")
    }
    fn config(&self) -> PathBuf {
        self.state.join("config.json")
    }
    fn log(&self) -> PathBuf {
        self.runtime.join("host.log")
    }
}

/// The paths for the daemon on `daemon_socket` with durable state under `state_root`.
pub(crate) fn paths_for(daemon_socket: &Path, state_root: &Path) -> Paths {
    use sha2::{Digest, Sha256};
    let digest = |bytes: &[u8]| format!("{:x}", Sha256::digest(bytes));
    let socket_digest = digest(daemon_socket.as_os_str().as_encoded_bytes());
    let leaf = format!("rh-{}", &socket_digest[..12]);
    let mut runtime = daemon_socket.parent().unwrap_or_else(|| Path::new("/tmp")).join(&leaf);
    #[cfg(unix)]
    if !crate::server::unix_socket_path_fits(&runtime.join("w-screen.sock")) {
        runtime = crate::platform::fallback_runtime_dir().join(leaf);
    }
    let scope_digest = digest(state_root.as_os_str().as_encoded_bytes());
    Paths { runtime, state: state_root.join("remote"), scope: format!("s{}", &scope_digest[..16]) }
}

/// The daemon's view of its host.
#[derive(Default)]
pub(crate) struct RemoteHostSupervisor {
    inner: Arc<Inner>,
}

#[derive(Default)]
struct Inner {
    paths: Mutex<Option<Paths>>,
    config: Mutex<RemoteConfig>,
    state: Mutex<State>,
    /// Held while a host starts or is adopted, so two callers never start two.
    starting: Mutex<()>,
    backoff: Mutex<Option<Backoff>>,
    /// Why there is no host, for status.
    unavailable: Mutex<Option<String>>,
    /// A newer embedded build waits for the running host to become idle.
    upgrade_pending: Mutex<bool>,
}

#[derive(Default)]
enum State {
    #[default]
    Idle,
    Running(Arc<Connection>),
}

/// One supervisor connection to a host.
struct Connection {
    pid: u32,
    record: HostRecord,
    adopted: bool,
    started: Instant,
    writer: Mutex<std::os::unix::net::UnixStream>,
    pending: Mutex<HashMap<u64, SyncSender<Value>>>,
    next_id: std::sync::atomic::AtomicU64,
    /// The latest `status` the host reported (its hello, then each event).
    status: Mutex<Value>,
}

impl RemoteHostSupervisor {
    /// Lets this daemon run cmux Remote: reads the person's last choices and
    /// adopts or starts the host when one is wanted.
    pub(crate) fn configure(&self, paths: Paths) {
        let config = read_config(&paths.config());
        *lock(&self.inner.paths) = Some(paths);
        *lock(&self.inner.config) = config.clone();
        if config.wanted() {
            let inner = Arc::clone(&self.inner);
            // Off the daemon's start path: staging and adoption touch the disk.
            let _ = std::thread::Builder::new().name("remote-host-start".into()).spawn(move || {
                if let Err(error) = Inner::ensure(&inner) {
                    eprintln!("cmux-tui: cmux Remote: {error}");
                }
            });
        }
    }

    /// The person's choices changed (the app's settings): saved, sent to the
    /// host, and the host started or stopped to match.
    pub(crate) fn set_config(&self, update: &Value) -> Result<Value, String> {
        let mut config = lock(&self.inner.config).clone();
        if let Some(value) = update.get("computer_use").and_then(Value::as_bool) {
            config.computer_use = value;
        }
        if let Some(value) = update.get("screen_sharing").and_then(Value::as_bool) {
            config.screen_sharing = value;
        }
        if let Some(value) = update.get("headless").and_then(Value::as_bool) {
            config.headless = value;
        }
        *lock(&self.inner.config) = config.clone();
        if let Some(paths) = lock(&self.inner.paths).clone() {
            write_config(&paths.config(), &config);
        }
        if !config.wanted() {
            Inner::stop(&self.inner);
            return Ok(self.status());
        }
        let connection = Inner::ensure(&self.inner)?;
        connection.call("config", json!({
            "computer_use": config.computer_use,
            "screen_sharing": config.screen_sharing,
            "headless": config.headless,
        }))?;
        Ok(self.status())
    }

    /// One request to the host, starting it first when it is wanted and none runs.
    pub(crate) fn call(&self, method: &str, params: Value) -> Result<Value, String> {
        let connection = Inner::ensure(&self.inner)?;
        connection.call(method, params)
    }

    /// The host's state for `remote-host-status` (never starts one).
    pub(crate) fn status(&self) -> Value {
        let config = lock(&self.inner.config).clone();
        let mut status = json!({
            "config": {
                "computer_use": config.computer_use,
                "screen_sharing": config.screen_sharing,
                "headless": config.headless,
            },
            "upgrade": if *lock(&self.inner.upgrade_pending) { "pending" } else { "none" },
        });
        match &*lock(&self.inner.state) {
            State::Running(connection) => {
                status["state"] = json!("running");
                status["adopted"] = json!(connection.adopted);
                status["host"] = lock(&connection.status).clone();
            }
            State::Idle => {
                let reason = lock(&self.inner.unavailable).clone();
                status["state"] = json!(match (&reason, config.wanted()) {
                    (Some(_), true) => "unavailable",
                    (_, true) => "starting",
                    _ => "off",
                });
                if let Some(reason) = reason {
                    status["reason"] = json!(reason);
                }
            }
        }
        status
    }
}

impl Inner {
    /// The running host's connection: adopted from the record, else started.
    fn ensure(this: &Arc<Self>) -> Result<Arc<Connection>, String> {
        if let State::Running(connection) = &*lock(&this.state) {
            return Ok(Arc::clone(connection));
        }
        let _starting = lock(&this.starting);
        if let State::Running(connection) = &*lock(&this.state) {
            return Ok(Arc::clone(connection));
        }
        let paths = lock(&this.paths).clone().ok_or("this daemon has no cmux Remote")?;
        let result = Self::adopt_or_start(this, &paths);
        match &result {
            Ok(connection) => {
                *lock(&this.unavailable) = None;
                *lock(&this.state) = State::Running(Arc::clone(connection));
            }
            Err(reason) => *lock(&this.unavailable) = Some(reason.clone()),
        }
        result
    }

    fn adopt_or_start(this: &Arc<Self>, paths: &Paths) -> Result<Arc<Connection>, String> {
        #[cfg(not(target_os = "macos"))]
        {
            let _ = (this, paths);
            Err("cmux Remote runs on macOS only".into())
        }
        #[cfg(target_os = "macos")]
        {
            let staged = platform::stage(&paths.state)?;
            if let Some(record) = read_record(&paths.record()) {
                match Self::adopt(this, &record) {
                    Ok(connection) => {
                        if record.bundle_digest != staged.digest {
                            Self::upgrade(this, &connection);
                        }
                        return Ok(connection);
                    }
                    Err(reason) => eprintln!("cmux-tui: cmux Remote: not adopting pid {}: {reason}", record.pid),
                }
            }
            let config = lock(&this.config).clone();
            let secret = mint_secret()?;
            let pid = platform::spawn_host(&staged, paths, &json!({
                "supervisor_secret": secret,
                "daemon_build": env!("CARGO_PKG_VERSION"),
                "computer_use": config.computer_use,
                "screen_sharing": config.screen_sharing,
                "headless": config.headless,
            }), READY_TIMEOUT)?;
            let (start_sec, start_usec) = platform::process_start(pid).ok_or("the new host exited at once")?;
            let record = HostRecord {
                pid,
                start_sec,
                start_usec,
                secret,
                bundle_digest: staged.digest.clone(),
                socket: paths.supervisor_socket(),
            };
            write_record(&paths.record(), &record);
            let connection = Self::connect(this, record, false)?;
            Ok(connection)
        }
    }

    /// Adopts a recorded host: the same process (pid and start time) and the record's secret.
    fn adopt(this: &Arc<Self>, record: &HostRecord) -> Result<Arc<Connection>, String> {
        #[cfg(target_os = "macos")]
        if platform::process_start(record.pid) != Some((record.start_sec, record.start_usec)) {
            return Err("the recorded host is not running".into());
        }
        Self::connect(this, record.clone(), true)
    }

    /// Connects, says hello, and starts reading the host's answers and events.
    fn connect(this: &Arc<Self>, record: HostRecord, adopted: bool) -> Result<Arc<Connection>, String> {
        let stream = std::os::unix::net::UnixStream::connect(&record.socket)
            .map_err(|error| format!("cannot connect to {}: {error}", record.socket.display()))?;
        #[cfg(target_os = "macos")]
        if platform::peer_pid(&stream) != Some(record.pid) {
            return Err("the supervisor socket's peer is not the recorded host".into());
        }
        let mut writer = stream.try_clone().map_err(|error| format!("{error}"))?;
        let hello = json!({"type": "hello", "secret": record.secret, "min": PROTOCOL_MIN, "max": PROTOCOL_MAX});
        writeln!(writer, "{hello}").map_err(|error| format!("hello: {error}"))?;
        let mut reader = BufReader::new(stream);
        let mut line = String::new();
        stream_timeout(reader.get_ref(), Some(READY_TIMEOUT));
        reader.read_line(&mut line).map_err(|error| format!("no hello from the host: {error}"))?;
        stream_timeout(reader.get_ref(), None);
        let answer: Value = serde_json::from_str(&line).map_err(|_| "the host's hello is not JSON".to_string())?;
        if answer.get("type").and_then(Value::as_str) != Some("hello") {
            let message = answer.pointer("/error/message").and_then(Value::as_str).unwrap_or("refused");
            return Err(format!("the host refused this daemon: {message}"));
        }
        let pid = record.pid;
        let connection = Arc::new(Connection {
            pid,
            record,
            adopted,
            started: Instant::now(),
            writer: Mutex::new(writer),
            pending: Mutex::new(HashMap::new()),
            next_id: std::sync::atomic::AtomicU64::new(1),
            status: Mutex::new(answer),
        });
        let weak = Arc::downgrade(this);
        let reading = Arc::clone(&connection);
        std::thread::Builder::new()
            .name("remote-host-read".into())
            .spawn(move || Self::read(&weak, &reading, reader))
            .map_err(|error| format!("cannot read the host: {error}"))?;
        eprintln!("cmux-tui: cmux Remote pid {pid} {}", if adopted { "adopted" } else { "started" });
        Ok(connection)
    }

    fn read(this: &Weak<Self>, connection: &Arc<Connection>, mut reader: BufReader<std::os::unix::net::UnixStream>) {
        let mut line = String::new();
        loop {
            line.clear();
            match reader.read_line(&mut line) {
                Ok(0) | Err(_) => break,
                Ok(_) => {}
            }
            let Ok(message) = serde_json::from_str::<Value>(&line) else { continue };
            if let Some(id) = message.get("id").and_then(Value::as_u64) {
                if let Some(waiting) = lock(&connection.pending).remove(&id) {
                    let _ = waiting.send(message);
                }
                continue;
            }
            if message.get("event").and_then(Value::as_str) == Some("status") {
                let status = message.get("status").cloned().unwrap_or(Value::Null);
                let idle = !status.get("busy").and_then(Value::as_bool).unwrap_or(false);
                *lock(&connection.status) = status;
                if idle && this.upgrade().is_some_and(|inner| *lock(&inner.upgrade_pending)) {
                    let _ = connection.call("drain", json!({}));
                }
            }
        }
        lock(&connection.pending).clear();
        let Some(inner) = this.upgrade() else { return };
        Self::host_gone(&inner, connection);
    }

    /// Another embedded build: drain now when idle, else when the host reports idle.
    fn upgrade(this: &Arc<Self>, connection: &Arc<Connection>) {
        *lock(&this.upgrade_pending) = true;
        let busy = lock(&connection.status).get("busy").and_then(Value::as_bool).unwrap_or(false);
        if !busy {
            let _ = connection.call("drain", json!({}));
        }
    }

    /// The host's connection ended (it exited, crashed or drained): forget it,
    /// and start a new one after the backoff delay while one is wanted.
    fn host_gone(this: &Arc<Self>, connection: &Arc<Connection>) {
        {
            let mut state = lock(&this.state);
            if matches!(&*state, State::Running(running) if Arc::ptr_eq(running, connection)) {
                *state = State::Idle;
            } else {
                return;
            }
        }
        let upgraded = std::mem::take(&mut *lock(&this.upgrade_pending));
        if let Some(paths) = lock(&this.paths).clone()
            && read_record(&paths.record()).is_some_and(|record| record == connection.record)
        {
            let _ = std::fs::remove_file(paths.record());
        }
        if !lock(&this.config).wanted() {
            return;
        }
        let ran = connection.started.elapsed();
        let delay = if upgraded {
            Duration::ZERO
        } else {
            let mut backoff = lock(&this.backoff);
            let backoff = backoff
                .get_or_insert_with(|| Backoff::new(Duration::from_millis(200), Duration::from_secs(30)));
            if ran >= HEALTHY_RUN {
                backoff.reset();
            }
            backoff.next_delay()
        };
        eprintln!(
            "cmux-tui: cmux Remote pid {} stopped after {} ms; starting again in {} ms",
            connection.pid,
            ran.as_millis(),
            delay.as_millis()
        );
        let inner = Arc::downgrade(this);
        let _ = std::thread::Builder::new().name("remote-host-restart".into()).spawn(move || {
            // A bounded restart delay on this thread, not a synchronization.
            std::thread::sleep(delay);
            let Some(inner) = inner.upgrade() else { return };
            if lock(&inner.config).wanted()
                && let Err(error) = Self::ensure(&inner)
            {
                eprintln!("cmux-tui: cmux Remote restart failed: {error}");
            }
        });
    }

    /// Nothing wants the host: end its supervisor connection; the host exits
    /// after its grace with no daemon (it ends a running session first).
    fn stop(this: &Arc<Self>) {
        let state = std::mem::take(&mut *lock(&this.state));
        if let State::Running(connection) = state {
            let _ = connection.call("drain", json!({}));
        }
    }
}

impl Connection {
    fn call(&self, method: &str, params: Value) -> Result<Value, String> {
        let id = self.next_id.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
        let (sender, receiver): (SyncSender<Value>, Receiver<Value>) = std::sync::mpsc::sync_channel(1);
        lock(&self.pending).insert(id, sender);
        let request = json!({"id": id, "method": method, "params": params});
        if writeln!(lock(&self.writer), "{request}").is_err() {
            lock(&self.pending).remove(&id);
            return Err("cmux Remote stopped".into());
        }
        let answer = receiver.recv_timeout(CALL_TIMEOUT).map_err(|_| {
            lock(&self.pending).remove(&id);
            format!("cmux Remote did not answer {method}")
        })?;
        if answer.get("ok").and_then(Value::as_bool) == Some(true) {
            return Ok(answer.get("result").cloned().unwrap_or(Value::Null));
        }
        let code = answer.pointer("/error/code").and_then(Value::as_str).unwrap_or("failed");
        let message = answer.pointer("/error/message").and_then(Value::as_str).unwrap_or("cmux Remote refused");
        Err(format!("{code}: {message}"))
    }
}

fn stream_timeout(stream: &std::os::unix::net::UnixStream, timeout: Option<Duration>) {
    let _ = stream.set_read_timeout(timeout);
}

fn lock<T>(mutex: &Mutex<T>) -> std::sync::MutexGuard<'_, T> {
    mutex.lock().unwrap_or_else(PoisonError::into_inner)
}

fn mint_secret() -> Result<String, String> {
    let mut bytes = [0_u8; 32];
    getrandom::fill(&mut bytes).map_err(|error| format!("cannot mint a secret: {error}"))?;
    Ok(bytes.iter().map(|byte| format!("{byte:02x}")).collect())
}

fn read_config(path: &Path) -> RemoteConfig {
    std::fs::read(path).ok().and_then(|bytes| serde_json::from_slice(&bytes).ok()).unwrap_or_default()
}

fn write_config(path: &Path, config: &RemoteConfig) {
    if let Ok(bytes) = serde_json::to_vec_pretty(config) {
        write_private(path, &bytes);
    }
}

fn read_record(path: &Path) -> Option<HostRecord> {
    std::fs::read(path).ok().and_then(|bytes| serde_json::from_slice(&bytes).ok())
}

fn write_record(path: &Path, record: &HostRecord) {
    if let Ok(bytes) = serde_json::to_vec(record) {
        write_private(path, &bytes);
    }
}

/// Writes `bytes` to `path` atomically, mode 0600, in a 0700 directory.
fn write_private(path: &Path, bytes: &[u8]) {
    use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
    let Some(dir) = path.parent() else { return };
    if std::fs::create_dir_all(dir).is_err() {
        return;
    }
    let _ = std::fs::set_permissions(dir, std::fs::Permissions::from_mode(0o700));
    let temporary = path.with_extension("tmp");
    let _ = std::fs::remove_file(&temporary);
    let written = std::fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(&temporary)
        .and_then(|mut file| file.write_all(bytes));
    if written.is_ok() {
        let _ = std::fs::rename(&temporary, path);
    }
}

/// A live process's start time (macOS), for the app grant.
#[cfg(target_os = "macos")]
pub(crate) fn process_stamp(pid: u32) -> Option<(u64, u64)> {
    platform::process_start(pid)
}

impl crate::mux::Mux {
    /// Lets this daemon run cmux Remote (macOS): the host for the daemon on
    /// `daemon_socket`, with durable state beside the daemon's own.
    pub fn configure_remote_host(self: &Arc<Self>, daemon_socket: &Path) {
        let Some(state_root) = crate::platform::workspace_state_dir()
            .and_then(|sessions| sessions.parent().map(Path::to_path_buf))
        else {
            return;
        };
        self.control_clients.remote_host.configure(paths_for(daemon_socket, &state_root));
    }
}
