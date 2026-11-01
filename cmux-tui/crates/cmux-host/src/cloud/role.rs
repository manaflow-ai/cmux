//! The `cloud` role on Linux: one worker thread that blocks in `poll` over
//! the role's control socket, inotify on `/var/lib/cmux` (the driver's
//! `bind.json`), the agent socket and its clients, and the daemon's
//! activity stream, with the senders' earliest deadline as the timeout.
//! There is no tick; an idle bound machine wakes once per heartbeat.
//!
//! Resume comes from the supervisor (`HostEvent::Resumed`, its clock-set
//! wake after a metadata read confirmed the id), replacing the interim
//! agent's `OnClockChange` timer. A `{"resume": true}` socket line still
//! works.

use crate::json::JsonField;
use std::fs::{self, OpenOptions};
use std::io::{self, BufRead, BufReader, Read, Write};
use std::os::fd::AsRawFd;
use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::sync::mpsc::{Receiver, RecvTimeoutError};
use std::thread::JoinHandle;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use cmux_server::cloud_http::JsonPoster;
use cmux_server_core::install_key::{InstallKey, SystemRandom};
use cmux_server_core::role::{HostEvent, Role, RoleContext, RoleError, StopContext};
use serde_json::{Value, json};

use super::client::{
    BindResult, CloudClient, Http, Store, bind_machine, ensure_install_key, ensure_wg_key,
};
use super::github;
use super::github_minter::{Ask, Minter, Stop};
use super::handoff::{self, HandoffReport};
use super::harness_login_thread::{self, HarnessLogins, Method, Platform, Setup as LoginSetup};
use super::sender::{Answer, Backoff, OpRequest};
use super::session::Session;
use super::trajectory::Layout;
use super::trajectory_thread::{AcpmuxImporter, Trajectories};
use super::wire::{
    AGENT_SOCKET, AGENT_STATE_FILE, BIND_FILE, BOUND_FILE, Bound, DAEMON_ACTIVITY_CAPABILITY,
    DAEMON_INFO_FILE, DAEMON_SOCKET_FILE, DaemonInfo, STATE_DIR, daemon_info_from_identify,
    heartbeat_ms_for,
};
use crate::config::Paths;
use crate::daemon_spec::{ROOT_HOME, WORK_HOME, WORK_USER, binary_path};
use crate::linux::fds::Inotify;
use crate::linux::spawn::lookup_user;

/// The dev-only heartbeat test override (read once at role start).
pub const HEARTBEAT_ENV: &str = "CMUX_VM_AGENT_HEARTBEAT_MS";
/// Where a trajectory restore stages its bundles (the work user's, 0700).
pub const TRAJECTORY_STAGING: &str = "/var/lib/cmux-trajectory-restore";
const MAX_CLIENTS: usize = 16;
const MAX_LINE: usize = 64 * 1024;

fn log(line: &str) {
    eprintln!("cmux-host: cloud: {line}");
}

fn wall_ms() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map_or(0, |d| d.as_millis() as u64)
}

fn random_unit() -> f64 {
    let mut buf = [0u8; 4];
    // SAFETY: writes at most 4 bytes into `buf`.
    let n = unsafe { libc::getrandom(buf.as_mut_ptr().cast(), 4, 0) };
    if n != 4 {
        return 0.5;
    }
    f64::from(u32::from_le_bytes(buf)) / (f64::from(u32::MAX) + 1.0)
}

/// Files under the agent's root: atomic (temp file + rename), parents 0700.
pub struct FileStore {
    paths: Paths,
    /// Tests: the next step of a write that fails.
    #[cfg(test)]
    fail_next: std::cell::Cell<Option<WriteStep>>,
}

/// The steps of a write that can fail (tests inject one).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum WriteStep {
    Write,
    Permissions,
    Rename,
    Link,
}

/// A temp file removed when dropped, so no failure path leaves one behind.
struct TempGuard {
    path: PathBuf,
}

impl Drop for TempGuard {
    fn drop(&mut self) {
        match fs::remove_file(&self.path) {
            Ok(()) => {}
            Err(e) if e.kind() == io::ErrorKind::NotFound => {}
            Err(e) => log(&format!("{}: temp file cleanup: {e}", self.path.display())),
        }
    }
}

impl FileStore {
    pub fn new(paths: Paths) -> FileStore {
        FileStore {
            paths,
            #[cfg(test)]
            fail_next: std::cell::Cell::new(None),
        }
    }

    fn at(&self, file: &str) -> PathBuf {
        self.paths.at(file)
    }

    /// Tests: makes `step` of the next write fail.
    #[cfg(test)]
    pub fn fail_next(&self, step: WriteStep) {
        self.fail_next.set(Some(step));
    }

    fn step(&self, step: WriteStep) -> io::Result<()> {
        #[cfg(test)]
        if self.fail_next.get() == Some(step) {
            self.fail_next.set(None);
            return Err(io::Error::other(format!("injected {step:?} failure")));
        }
        let _ = step;
        Ok(())
    }

    /// A finished temp file next to `path`, holding `text` with `mode`. The
    /// guard removes it when dropped (a rename that moved it leaves nothing).
    fn temp_beside(&self, path: &Path, text: &str, mode: u32) -> Result<TempGuard, String> {
        let dir = path.parent().ok_or("no parent directory")?;
        fs::create_dir_all(dir).map_err(|e| format!("{}: {e}", dir.display()))?;
        let tmp = dir.join(format!(
            ".{}.tmp-{}",
            path.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default(),
            std::process::id()
        ));
        let mut out = OpenOptions::new()
            .write(true)
            .create(true)
            .truncate(true)
            .mode(mode)
            .custom_flags(libc::O_NOFOLLOW)
            .open(&tmp)
            .map_err(|e| format!("{}: {e}", tmp.display()))?;
        let guard = TempGuard { path: tmp };
        self.step(WriteStep::Write)
            .and_then(|()| out.write_all(text.as_bytes()))
            .map_err(|e| e.to_string())?;
        self.step(WriteStep::Permissions)
            .and_then(|()| out.set_permissions(fs::Permissions::from_mode(mode)))
            .map_err(|e| e.to_string())?;
        Ok(guard)
    }
}

impl Store for FileStore {
    fn read(&self, file: &str) -> Option<String> {
        fs::read_to_string(self.at(file)).ok()
    }

    fn present(&self, file: &str) -> Result<bool, String> {
        let path = self.at(file);
        match fs::symlink_metadata(&path) {
            Ok(_) => Ok(true),
            Err(e) if e.kind() == io::ErrorKind::NotFound => Ok(false),
            Err(e) => Err(format!("{}: {e}", path.display())),
        }
    }

    fn write(&mut self, file: &str, text: &str, mode: u32) -> Result<(), String> {
        let path = self.at(file);
        let tmp = self.temp_beside(&path, text, mode)?;
        self.step(WriteStep::Rename)
            .and_then(|()| fs::rename(&tmp.path, &path))
            .map_err(|e| format!("{}: {e}", path.display()))
    }

    fn create_new(&mut self, file: &str, text: &str, mode: u32) -> Result<bool, String> {
        let path = self.at(file);
        let tmp = self.temp_beside(&path, text, mode)?;
        // link() fails on any existing entry (a file, a dangling symlink, a
        // directory), so a record written after the caller's check is kept.
        // The temp name goes when `tmp` drops, linked or not.
        let linked = self.step(WriteStep::Link).and_then(|()| fs::hard_link(&tmp.path, &path));
        drop(tmp);
        match linked {
            Ok(()) => Ok(true),
            Err(e) if e.kind() == io::ErrorKind::AlreadyExists => Ok(false),
            Err(e) => Err(format!("{}: {e}", path.display())),
        }
    }

    fn remove(&mut self, file: &str) {
        let _ = fs::remove_file(self.at(file));
    }
}

/// [`Http`] over cmux-server's HTTPS poster.
pub struct PosterHttp(pub JsonPoster);

impl Http for PosterHttp {
    fn get(&self, url: &str, bearer: Option<&str>) -> Result<(u16, Value), String> {
        self.0.get(url, bearer)
    }

    fn post(&self, url: &str, body: &Value, bearer: Option<&str>) -> Result<(u16, Value), String> {
        self.0.post(url, body, bearer)
    }

    fn request_until(
        &self,
        url: &str,
        body: Option<&Value>,
        bearer: Option<&str>,
        deadline: Instant,
    ) -> Result<(u16, Vec<u8>), String> {
        self.0.request_until(url, body, bearer, deadline)
    }

    fn request_with_deadline(
        &self,
        url: &str,
        body: Option<&Value>,
        bearer: Option<&str>,
        deadline: &cmux_server::cloud_http::RequestDeadline,
    ) -> Result<(u16, Vec<u8>), String> {
        self.0.request_with_deadline(url, body, bearer, deadline)
    }
}

/// One `identify` on the daemon's control socket. `timeout` bounds the whole
/// exchange, not each read, and the reply line is at most `MAX_LINE`.
pub fn query_identify(socket: &Path, timeout: Duration) -> io::Result<Value> {
    let deadline = Instant::now() + timeout;
    let mut stream = UnixStream::connect(socket)?;
    let left = deadline.saturating_duration_since(Instant::now());
    stream.set_write_timeout(Some(left.max(Duration::from_millis(1))))?;
    stream.write_all(b"{\"id\":1,\"cmd\":\"identify\"}\n")?;
    let mut line = Vec::new();
    let mut chunk = [0u8; 4096];
    while !line.contains(&b'\n') {
        if line.len() > MAX_LINE {
            return Err(io::Error::other("daemon identify line over 64 KB"));
        }
        let left = deadline.saturating_duration_since(Instant::now());
        if left.is_zero() {
            return Err(io::Error::from(io::ErrorKind::TimedOut));
        }
        stream.set_read_timeout(Some(left))?;
        match stream.read(&mut chunk) {
            Ok(0) => break,
            Ok(n) => line.extend_from_slice(read_part(&chunk, n)?),
            Err(e) if e.kind() == io::ErrorKind::Interrupted => {}
            Err(e) => return Err(e),
        }
    }
    let end = line.iter().position(|b| *b == b'\n').unwrap_or(line.len());
    if end > MAX_LINE {
        return Err(io::Error::other("daemon identify line over 64 KB"));
    }
    let reply: Value =
        serde_json::from_slice(line.get(..end).unwrap_or_default()).map_err(io::Error::other)?;
    if *reply.field("ok") == true && reply.field("data").is_object() {
        Ok(reply.field("data").clone())
    } else {
        Err(io::Error::other("daemon identify refused"))
    }
}

/// The daemon socket path the bake recorded.
pub fn daemon_socket(paths: &Paths) -> Option<PathBuf> {
    let raw = fs::read_to_string(paths.at(DAEMON_SOCKET_FILE)).ok()?;
    let trimmed = raw.trim();
    (!trimmed.is_empty()).then(|| PathBuf::from(trimmed))
}

/// Live identify first; the bake-recorded `daemon.json` when the daemon
/// does not answer. Never an empty list.
pub fn resolve_daemon_info(paths: &Paths) -> Result<DaemonInfo, String> {
    if let Some(socket) = daemon_socket(paths)
        && let Ok(identify) = query_identify(&socket, Duration::from_secs(2))
    {
        return Ok(daemon_info_from_identify(&identify, false));
    }
    let recorded = fs::read_to_string(paths.at(DAEMON_INFO_FILE))
        .map_err(|_| "no daemon identify and no recorded daemon.json".to_owned())?;
    let info: DaemonInfo = serde_json::from_str(&recorded).map_err(|e| e.to_string())?;
    Ok(info.with_activity(false))
}

/// `wg genkey | wg pubkey` (wireguard-tools in the base image).
fn wg_keypair() -> Result<(String, String), String> {
    use std::process::{Command, Stdio};
    let private =
        Command::new("wg").arg("genkey").output().map_err(|e| format!("wg genkey: {e}"))?;
    if !private.status.success() {
        return Err("wg genkey failed".to_owned());
    }
    let mut child = Command::new("wg")
        .arg("pubkey")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .spawn()
        .map_err(|e| format!("wg pubkey: {e}"))?;
    child
        .stdin
        .take()
        .ok_or("wg pubkey: no stdin")?
        .write_all(&private.stdout)
        .map_err(|e| e.to_string())?;
    let public = child.wait_with_output().map_err(|e| e.to_string())?;
    if !public.status.success() {
        return Err("wg pubkey failed".to_owned());
    }
    let text = |b: &[u8]| String::from_utf8_lossy(b).trim().to_owned();
    Ok((text(&private.stdout), text(&public.stdout)))
}

/// The `cloud` role.
pub struct CloudRole {
    paths: Paths,
    worker: Option<WorkerHandle>,
    bootstrap: Option<super::bootstrap_role::RoleBridge>,
}

struct WorkerHandle {
    thread: JoinHandle<()>,
    control: UnixStream,
    /// Disconnects when the worker thread ends.
    done: Receiver<()>,
    /// Set before `stop`: from then on the minter hands out no token,
    /// even if the worker is stuck in a request past the deadline.
    github_stop: Arc<Stop>,
}

impl CloudRole {
    pub fn new(paths: Paths) -> CloudRole {
        CloudRole { paths, worker: None, bootstrap: None }
    }

    pub fn with_root_bootstrap(
        mut self,
        host: Option<Arc<cmux_link::root_bootstrap::Host>>,
    ) -> Self {
        self.bootstrap = host.map(super::bootstrap_role::RoleBridge::new);
        self
    }

    fn send(&mut self, word: &str) {
        if let Some(worker) = self.worker.as_mut() {
            let _ = worker.control.write_all(format!("{word}\n").as_bytes());
        }
    }

    fn halt(&mut self, deadline: Instant) -> Result<(), RoleError> {
        if let Some(worker) = self.worker.as_ref() {
            worker.github_stop.set();
        }
        let bootstrap = self.bootstrap.as_ref().map(|bridge| bridge.stop(deadline)).transpose();
        self.send("stop");
        let Some(worker) = self.worker.take() else {
            return bootstrap.map(|_| ()).map_err(|error| RoleError(error.to_string()));
        };
        // The worker ends after its current request (each is bounded by
        // 20 s); a later deadline is reported, not waited out.
        let wait = deadline.saturating_duration_since(Instant::now());
        match worker.done.recv_timeout(wait) {
            Err(RecvTimeoutError::Timeout) => {
                Err(RoleError("cloud worker did not stop by the deadline".to_owned()))
            }
            _ => {
                let _ = worker.thread.join();
                bootstrap.map(|_| ()).map_err(|error| RoleError(error.to_string()))
            }
        }
    }
}

impl Role for CloudRole {
    fn name(&self) -> &str {
        "cloud"
    }

    fn start(&mut self, ctx: &RoleContext) -> Result<(), RoleError> {
        let Some(instance_id) = ctx.instance_id.clone() else { return Ok(()) };
        if self.worker.is_some() {
            return Ok(());
        }
        let bootstrap = self.bootstrap.as_mut().and_then(|bridge| bridge.start().ok());
        let (ours, theirs) = UnixStream::pair().map_err(|e| RoleError(e.to_string()))?;
        let paths = self.paths.clone();
        let heartbeat_env = std::env::var(HEARTBEAT_ENV).ok();
        let (done_tx, done) = std::sync::mpsc::channel::<()>();
        let github_stop = Arc::new(Stop::default());
        let worker_stop = Arc::clone(&github_stop);
        let thread = std::thread::Builder::new()
            .name("cmux-host-cloud".to_owned())
            .spawn(move || {
                let _done = done_tx;
                let worker = Worker::new(paths, instance_id, heartbeat_env, theirs, worker_stop)
                    .map(|mut worker| {
                        worker.bootstrap = bootstrap;
                        worker
                    });
                if let Err(e) = worker.and_then(|mut w| w.run()) {
                    log(&format!("worker stopped: {e}"));
                }
            })
            .map_err(|e| RoleError(e.to_string()))?;
        self.worker = Some(WorkerHandle { thread, control: ours, done, github_stop });
        Ok(())
    }

    fn stop(&mut self, ctx: &StopContext) -> Result<(), RoleError> {
        self.halt(ctx.deadline)
    }

    fn on_event(&mut self, event: &HostEvent) -> Result<(), RoleError> {
        match event {
            HostEvent::Resumed => {
                if let Some(bridge) = &self.bootstrap {
                    let _ = bridge.resume();
                }
                self.send("resume");
                Ok(())
            }
            // No request is held open into a snapshot.
            HostEvent::Parked { deadline } | HostEvent::Shutdown { deadline } => {
                self.halt(*deadline)
            }
            _ => Ok(()),
        }
    }
}

struct Client {
    stream: UnixStream,
    buf: Vec<u8>,
    output: Vec<u8>,
    sent: usize,
    eof: bool,
    write_deadline: Option<u64>,
}

struct Activity {
    stream: Option<UnixStream>,
    buf: Vec<u8>,
    connected: bool,
    retry_at: Option<u64>,
    backoff: Backoff,
    /// The daemon does not serve `subscribe-activity`: no sender at all.
    unsupported: bool,
}

struct Live {
    client: CloudClient<PosterHttp>,
    session: Session,
}

struct Worker {
    bootstrap: Option<super::bootstrap_role::WorkerBridge>,
    bootstrap_retry_at: Option<u64>,
    bootstrap_backoff: Backoff,
    paths: Paths,
    store: FileStore,
    instance_id: String,
    heartbeat_env: Option<String>,
    control: UnixStream,
    control_buf: Vec<u8>,
    inotify: Inotify,
    listener: Option<UnixListener>,
    clients: Vec<Client>,
    activity: Activity,
    live: Option<Live>,
    /// GitHub token asks, off the poll loop (`github_minter.rs`).
    github: Minter<PosterHttp>,
    /// ACP chats kept in cmux Cloud and restored on a replacement (`trajectory_thread.rs`).
    trajectories: Option<Trajectories<PosterHttp>>,
    /// The person's harness logins, kept for their machines (`harness_login_thread.rs`).
    harness_logins: Option<HarnessLogins<PosterHttp, PlatformHttp>>,
    bind_retry_at: Option<u64>,
    bind_backoff: Backoff,
    rng: SystemRandom,
    epoch: Instant,
}

impl Worker {
    fn new(
        paths: Paths,
        instance_id: String,
        heartbeat_env: Option<String>,
        control: UnixStream,
        github_stop: Arc<Stop>,
    ) -> io::Result<Worker> {
        let state_dir = paths.at(STATE_DIR);
        fs::create_dir_all(&state_dir)?;
        fs::set_permissions(&state_dir, fs::Permissions::from_mode(0o700))?;
        let inotify = Inotify::new()?;
        inotify.watch_dir(&state_dir)?;
        control.set_nonblocking(true)?;
        let trajectories =
            spawn_trajectories(&paths).map_err(|e| log(&format!("trajectory mirror: {e}"))).ok();
        let harness_logins =
            spawn_harness_logins(&paths).map_err(|e| log(&format!("harness login: {e}"))).ok();
        Ok(Worker {
            bootstrap: None,
            bootstrap_retry_at: None,
            bootstrap_backoff: Backoff::new(1_000, 30_000),
            store: FileStore::new(paths.clone()),
            paths,
            instance_id,
            heartbeat_env,
            control,
            control_buf: Vec::new(),
            inotify,
            listener: None,
            clients: Vec::new(),
            activity: Activity {
                stream: None,
                buf: Vec::new(),
                connected: false,
                retry_at: None,
                backoff: Backoff::new(1_000, 60_000),
                unsupported: false,
            },
            live: None,
            github: Minter::spawn(wall_ms, log, github_stop)?,
            trajectories,
            harness_logins,
            bind_retry_at: None,
            bind_backoff: Backoff::new(2_000, 600_000),
            rng: SystemRandom::new(),
            epoch: Instant::now(),
        })
    }

    /// Monotonic milliseconds for the deadlines.
    fn now(&self) -> u64 {
        self.epoch.elapsed().as_millis() as u64
    }

    fn run(&mut self) -> io::Result<()> {
        self.listener = self.serve_socket().map_err(|e| log(&format!("agent socket: {e}"))).ok();
        if self.store.read(BIND_FILE).is_some() {
            self.bind_now();
        } else if let Some(saved) = self.store.read(BOUND_FILE) {
            self.resume_bound(&saved);
        } else {
            log("no bind.json and no bound.json; waiting for bind.json");
        }
        loop {
            self.drive_bootstrap();
            let deadline = [
                self.live.as_ref().and_then(|l| l.session.next_deadline()),
                self.bind_retry_at,
                self.activity.retry_at,
                self.bootstrap_retry_at,
            ]
            .into_iter()
            .flatten()
            .chain(self.clients.iter().filter_map(|c| c.write_deadline))
            .min();
            let timeout_ms =
                deadline.map_or(-1, |at| at.saturating_sub(self.now()).min(i32::MAX as u64) as i32);
            let mut fds = vec![
                libc::pollfd { fd: self.control.as_raw_fd(), events: libc::POLLIN, revents: 0 },
                libc::pollfd { fd: self.inotify.raw(), events: libc::POLLIN, revents: 0 },
            ];
            let listener_at = self.listener.as_ref().map(|l| {
                fds.push(libc::pollfd { fd: l.as_raw_fd(), events: libc::POLLIN, revents: 0 });
                fds.len() - 1
            });
            let activity_at = self.activity.stream.as_ref().map(|s| {
                fds.push(libc::pollfd { fd: s.as_raw_fd(), events: libc::POLLIN, revents: 0 });
                fds.len() - 1
            });
            let clients_from = fds.len();
            // Only these clients have a pollfd in this pass; `accept` below
            // adds new ones, which are read from the next pass on.
            let polled_clients = self.clients.len();
            for c in &self.clients {
                fds.push(libc::pollfd {
                    fd: c.stream.as_raw_fd(),
                    events: (if c.eof { 0 } else { libc::POLLIN })
                        | if c.output.is_empty() { 0 } else { libc::POLLOUT },
                    revents: 0,
                });
            }
            let bootstrap_wakes = self.bootstrap.as_ref().and_then(|bridge| bridge.wake_set());
            if let Some(wakes) = &bootstrap_wakes {
                fds.extend(wakes.fds());
            }
            // SAFETY: `fds` is a valid array of `fds.len()` pollfd entries.
            let n = unsafe { libc::poll(fds.as_mut_ptr(), fds.len() as libc::nfds_t, timeout_ms) };
            if n < 0 {
                let err = io::Error::last_os_error();
                if err.raw_os_error() == Some(libc::EINTR) {
                    continue;
                }
                return Err(err);
            }
            let ready = |i: usize| fds.get(i).is_some_and(|fd| fd.revents != 0);
            if ready(0) && self.control_words()? {
                return Ok(());
            }
            // The retained bootstrap descriptors wake the next loop's drive.
            // Process control and binding changes before preparing private data.
            if ready(1) {
                let bind = self.inotify.read_events()?.iter().any(|e| e.name == "bind.json");
                if bind {
                    self.bind_now();
                }
            }
            if listener_at.is_some_and(ready) {
                self.accept();
            }
            if activity_at.is_some_and(ready) {
                self.read_activity();
            }
            let readable: Vec<usize> =
                (0..polled_clients).filter(|i| ready(clients_from + i)).collect();
            if self.read_clients(&readable) {
                return Ok(());
            }
            let now = self.now();
            self.clients.retain(|c| c.write_deadline.is_none_or(|at| at > now));
            self.fire_deadlines();
        }
    }

    /// `resume` and `stop` from the role; `true` when the worker must end.
    fn control_words(&mut self) -> io::Result<bool> {
        let mut buf = [0u8; 256];
        loop {
            match self.control.read(&mut buf) {
                Ok(0) => return Ok(true),
                Ok(n) => self.control_buf.extend_from_slice(read_part(&buf, n)?),
                Err(e) if e.kind() == io::ErrorKind::WouldBlock => break,
                Err(e) if e.kind() == io::ErrorKind::Interrupted => continue,
                Err(e) => return Err(e),
            }
        }
        let words: Vec<String> = take_lines(&mut self.control_buf);
        for word in words {
            match word.as_str() {
                "stop" => return Ok(true),
                "resume" => {
                    self.bootstrap_retry_at = None;
                    self.bootstrap_backoff.reset();
                    if let Some(bridge) = &mut self.bootstrap {
                        bridge.resume();
                        if self.live.is_some() {
                            bridge.enrolled();
                        }
                    }
                    let now = self.now();
                    if let Some(live) = self.live.as_mut() {
                        let reqs = live.session.resume(now);
                        self.drive(reqs);
                    }
                }
                _ => {}
            }
        }
        Ok(false)
    }

    fn serve_socket(&self) -> io::Result<UnixListener> {
        let path = self.paths.at(AGENT_SOCKET);
        if let Some(dir) = path.parent() {
            fs::create_dir_all(dir)?;
            fs::set_permissions(dir, fs::Permissions::from_mode(0o755))?;
        }
        let _ = fs::remove_file(&path);
        let listener = UnixListener::bind(&path)?;
        listener.set_nonblocking(true)?;
        if self.paths.is_system_root()
            && let Some(gid) = group_id("cmux")
        {
            std::os::unix::fs::chown(&path, Some(0), Some(gid))?;
        }
        fs::set_permissions(&path, fs::Permissions::from_mode(0o660))?;
        Ok(listener)
    }

    fn accept(&mut self) {
        let Some(listener) = self.listener.as_ref() else { return };
        while let Ok((stream, _)) = listener.accept() {
            if self.clients.len() >= MAX_CLIENTS {
                // A GitHub token asker gets an answer rather than an EOF.
                let mut stream = stream;
                let busy = github::refusal("busy", "the Cloud agent's socket is full; retry");
                let _ = stream.set_write_timeout(Some(Duration::from_millis(200)));
                let _ = stream.write_all(format!("{busy}\n").as_bytes());
                continue;
            }
            if stream.set_nonblocking(true).is_err() {
                continue;
            }
            self.clients.push(Client {
                stream,
                buf: Vec::new(),
                output: Vec::new(),
                sent: 0,
                eof: false,
                write_deadline: None,
            });
        }
    }

    fn read_clients(&mut self, readable: &[usize]) -> bool {
        let mut closed = Vec::new();
        let mut lines = Vec::new();
        for &i in readable {
            let Some(client) = self.clients.get_mut(i) else { continue };
            match read_available(&mut client.stream, &mut client.buf) {
                Ok(open) => {
                    lines.extend(take_lines(&mut client.buf).into_iter().map(|line| (i, line)));
                    client.eof = !open;
                    if client.buf.len() > MAX_LINE {
                        closed.push(i);
                    }
                }
                Err(_) => closed.push(i),
            }
        }
        let mut asks: Vec<(usize, Ask)> = Vec::new();
        for (i, line) in lines {
            if asks.iter().any(|(asker, _)| *asker == i) {
                continue;
            }
            if closed.contains(&i) {
                continue;
            }
            if let Some(ask) = agent_ask(&line) {
                asks.push((i, ask));
                continue;
            }
            let now = self.now();
            if serde_json::from_str::<Value>(&line).is_ok_and(|v| {
                v.get("op").and_then(Value::as_str) == Some(super::receiver::POLICY_OP)
            }) {
                let Some(client) = self.clients.get(i) else { continue };
                if !client.output.is_empty() {
                    closed.push(i);
                    continue;
                }
                // A queued batch must not hold shutdown behind up to sixteen
                // separate network deadlines. Check the role's control fd
                // before every policy request, not only before the batch.
                if self.control_words().unwrap_or(true) {
                    return true;
                }
                // The request is deliberately parameterless. The role owns
                // every identity and credential used for this hidden read.
                #[derive(serde::Deserialize)]
                #[serde(deny_unknown_fields)]
                struct Request {
                    op: String,
                }
                let valid = serde_json::from_str::<Request>(&line)
                    .is_ok_and(|r| r.op == super::receiver::POLICY_OP);
                let value = if valid {
                    self.live.as_mut().and_then(|live| {
                        super::receiver_files::reply(
                            &self.paths,
                            &self.instance_id,
                            &mut live.client,
                            wall_ms(),
                        )
                        .ok()
                    })
                } else {
                    None
                };
                let value = value.unwrap_or_else(
                    || json!({ "ok": false, "error": "cloud.vm.network_policy.unavailable" }),
                );
                let Some(client) = self.clients.get_mut(i) else { continue };
                client.output = serde_json::to_vec(&value).unwrap_or_default();
                if client.output.len() > 1024 * 1024 {
                    closed.push(i);
                    continue;
                }
                client.output.push(b'\n');
                client.write_deadline = Some(self.epoch.elapsed().as_millis() as u64 + 1000);
                continue;
            }
            let Some(live) = self.live.as_mut() else { continue };
            let (reqs, note) = live.session.line(&line, now);
            if let Some(note) = note {
                log(&note);
            }
            self.drive(reqs);
        }
        let now = self.now();
        for &i in readable {
            if asks.iter().any(|(asker, _)| *asker == i) {
                continue;
            }
            let Some(client) = self.clients.get_mut(i) else { continue };
            if client.write_deadline.is_some_and(|deadline| deadline <= now) {
                closed.push(i);
                continue;
            }
            while client.sent < client.output.len() {
                let Some(pending) = client.output.get(client.sent..) else {
                    closed.push(i);
                    break;
                };
                match client.stream.write(pending) {
                    Ok(0) => {
                        closed.push(i);
                        break;
                    }
                    Ok(n) => client.sent += n,
                    Err(e) if e.kind() == io::ErrorKind::WouldBlock => break,
                    Err(e) if e.kind() == io::ErrorKind::Interrupted => continue,
                    Err(_) => {
                        closed.push(i);
                        break;
                    }
                }
            }
            if client.sent == client.output.len() {
                client.output.clear();
                client.sent = 0;
                client.write_deadline = None;
                if client.eof {
                    closed.push(i);
                }
            }
        }
        closed.extend(asks.iter().map(|(i, _)| *i));
        closed.sort_unstable();
        closed.dedup();
        for i in closed.into_iter().rev() {
            let client = self.clients.remove(i);
            if let Some(pos) = asks.iter().position(|(asker, _)| *asker == i) {
                self.github.ask(asks.swap_remove(pos).1, client.stream);
            }
        }
        false
    }

    fn bind_now(&mut self) {
        self.bind_retry_at = None;
        if self.store.read(BIND_FILE).is_none() {
            return;
        }
        let key = match ensure_install_key(&mut self.store, &self.instance_id, &self.rng) {
            Ok(loaded) => loaded.key,
            Err(e) => return log(&format!("install key: {e}")),
        };
        let wg = match ensure_wg_key(&mut self.store, &self.instance_id, wg_keypair) {
            Ok(public) => public,
            Err(e) => return log(&format!("wireguard key: {e}")),
        };
        let daemon = match resolve_daemon_info(&self.paths) {
            Ok(daemon) => daemon,
            Err(e) => return log(&format!("daemon info: {e}")),
        };
        let http = match JsonPoster::new() {
            Ok(poster) => PosterHttp(poster),
            Err(e) => return log(&e),
        };
        let result = bind_machine(&mut self.store, &http, &key, &wg, &daemon, wall_ms());
        log(&format!("bind: {}", result.describe()));
        match result {
            BindResult::Bound(bound) => {
                self.bind_backoff.reset();
                if let Err(e) = super::client::record_owner_kind(&mut self.store) {
                    log(&format!("vm-kind write: {e}"));
                }
                self.start_live(*bound, key, http, daemon);
            }
            BindResult::Retry(_) => {
                self.bind_retry_at = Some(self.now() + self.bind_backoff.next(0, random_unit()));
            }
            _ => {}
        }
    }

    /// The agent restarted on a bound machine: report again, unless the
    /// instance id changed since bind (the server does not know the new key).
    fn resume_bound(&mut self, saved: &str) {
        let bound: Bound = match serde_json::from_str(saved) {
            Ok(bound) => bound,
            Err(e) => return log(&format!("bound.json unreadable: {e}")),
        };
        // A machine bound by an older build may have no kind record yet; one
        // that has a record keeps it.
        if let Err(e) = super::client::record_owner_kind(&mut self.store) {
            log(&format!("vm-kind write: {e}"));
        }
        let loaded = match ensure_install_key(&mut self.store, &self.instance_id, &self.rng) {
            Ok(loaded) => loaded,
            Err(e) => return log(&format!("install key: {e}")),
        };
        if loaded.rotated {
            return log(
                "instance id changed since bind and no new bind.json; not reporting with a key the server does not know",
            );
        }
        let daemon = match resolve_daemon_info(&self.paths) {
            Ok(daemon) => daemon,
            Err(e) => return log(&format!("daemon info: {e}")),
        };
        match JsonPoster::new() {
            Ok(poster) => self.start_live(bound, loaded.key, PosterHttp(poster), daemon),
            Err(e) => log(&e),
        }
    }

    fn start_live(&mut self, bound: Bound, key: InstallKey, http: PosterHttp, daemon: DaemonInfo) {
        let heartbeat = heartbeat_ms_for(bound.env, self.heartbeat_env.as_deref());
        if heartbeat != super::wire::DEFAULT_HEARTBEAT_MS {
            log(&format!("heartbeat test override: {heartbeat} ms (dev only)"));
        }
        match github_client(&bound, &key) {
            Ok(client) => self.github.bound(client),
            Err(e) => log(&format!("github minter: {e}")),
        }
        if let Some(trajectories) = self.trajectories.as_ref() {
            match github_client(&bound, &key) {
                Ok(client) => trajectories.bound(client),
                Err(e) => log(&format!("trajectory mirror: {e}")),
            }
        }
        self.harness_logins_bound(&bound, &key);
        let mut session = Session::new(&bound.machine, daemon, heartbeat);
        let reqs = session.start(self.now());
        self.live = Some(Live { client: CloudClient::new(http, bound, key), session });
        if let Some(bridge) = &self.bootstrap {
            bridge.enrolled();
        }
        self.activity = self.activity_reset();
        self.connect_activity();
        self.drive(reqs);
    }

    /// Hands the harness-login thread its client when the environment keeps
    /// logins, and holds the first report until its boot pass (one list and
    /// the writes it allows) is over or [`harness_login_thread::BOOT_WAIT`]
    /// passed, so the first chat finds the person's login.
    fn harness_logins_bound(&self, bound: &Bound, key: &InstallKey) {
        let (Some(logins), Some(origin)) =
            (self.harness_logins.as_ref(), bound.env.harness_login_origin())
        else {
            return;
        };
        let client = match github_client(bound, key) {
            Ok(client) => client,
            Err(e) => return log(&format!("harness login: {e}")),
        };
        let platform = match JsonPoster::new() {
            Ok(poster) => PlatformHttp(poster),
            Err(e) => return log(&format!("harness login: {e}")),
        };
        let booted = logins.bound(client, platform, origin);
        if let Err(RecvTimeoutError::Timeout) = booted.recv_timeout(harness_login_thread::BOOT_WAIT)
        {
            log("harness login: boot pass still running; reporting anyway");
        }
    }

    fn activity_reset(&self) -> Activity {
        Activity {
            stream: None,
            buf: Vec::new(),
            connected: false,
            retry_at: None,
            backoff: Backoff::new(1_000, 60_000),
            unsupported: false,
        }
    }

    /// Opens one `subscribe-activity` stream when the daemon serves it.
    fn connect_activity(&mut self) {
        self.activity.retry_at = None;
        if self.activity.unsupported || self.live.is_none() {
            return;
        }
        let attempt = daemon_socket(&self.paths)
            .ok_or_else(|| io::Error::other("no daemon socket"))
            .and_then(|socket| {
                let identify = query_identify(&socket, Duration::from_secs(2))?;
                let caps = identify.field("capabilities").as_array().cloned().unwrap_or_default();
                if !caps.iter().any(|c| c == DAEMON_ACTIVITY_CAPABILITY) {
                    return Ok(None);
                }
                let mut stream = UnixStream::connect(&socket)?;
                stream.write_all(b"{\"id\":1,\"cmd\":\"subscribe-activity\"}\n")?;
                stream.set_nonblocking(true)?;
                Ok(Some(stream))
            });
        match attempt {
            Ok(Some(stream)) => self.activity.stream = Some(stream),
            Ok(None) => {
                self.activity.unsupported = true;
                log("activity: the daemon does not serve subscribe-activity; no activity sender");
            }
            Err(_) => self.activity_dropped(),
        }
    }

    fn read_activity(&mut self) {
        let Some(stream) = self.activity.stream.as_mut() else { return };
        // A line over `MAX_LINE` drops the stream like an EOF, so the buffer never grows past it.
        let (lines, open) = read_lines(stream, &mut self.activity.buf);
        for line in lines {
            let Ok(msg) = serde_json::from_str::<Value>(&line) else {
                log("activity: unreadable daemon line ignored");
                continue;
            };
            let now = self.now();
            let mut reqs = Vec::new();
            if *msg.field("ok") == true && !self.activity.connected {
                self.activity.connected = true;
                self.activity.backoff.reset();
                if let Some(live) = self.live.as_mut() {
                    reqs.extend(live.session.activity_stream(true, now));
                }
            }
            let activity = if *msg.field("event") == "activity-changed" {
                Some(msg.field("activity"))
            } else if *msg.field("ok") == true {
                Some(msg.field("data").field("activity"))
            } else {
                None
            };
            if let (Some(a), Some(live)) = (activity.filter(|a| a.is_object()), self.live.as_mut())
            {
                reqs.extend(live.session.daemon_activity(a, now));
            }
            self.drive(reqs);
        }
        if !open {
            self.activity_dropped();
        }
    }

    /// The stream dropped (the daemon restarted): `activity` off, reconnect
    /// with backoff.
    fn activity_dropped(&mut self) {
        self.activity.stream = None;
        self.activity.buf.clear();
        if self.activity.connected {
            self.activity.connected = false;
            let now = self.now();
            if let Some(live) = self.live.as_mut() {
                let reqs = live.session.activity_stream(false, now);
                self.drive(reqs);
            }
        }
        if self.live.is_some() && self.activity.retry_at.is_none() {
            self.activity.retry_at =
                Some(self.now() + self.activity.backoff.next(0, random_unit()));
        }
    }

    fn fire_deadlines(&mut self) {
        let now = self.now();
        if self.bind_retry_at.is_some_and(|at| at <= now) {
            self.bind_now();
        }
        if self.activity.retry_at.is_some_and(|at| at <= now) {
            self.connect_activity();
        }
        let now = self.now();
        if let Some(live) = self.live.as_mut() {
            let reqs = live.session.fire(now);
            self.drive(reqs);
        }
    }

    /// Sends each request and feeds its answer back until nothing is due.
    fn drive(&mut self, mut queue: Vec<OpRequest>) {
        while let Some(req) = queue.pop() {
            let Some(live) = self.live.as_mut() else { return };
            let answer = live.client.op(&req, wall_ms());
            let now = self.epoch.elapsed().as_millis() as u64;
            let (next, note) = live.session.answered(&req, &answer, now, random_unit());
            if let Some(note) = &note {
                log(note);
            }
            if req.op == super::wire::STATUS_REPORT_OP {
                self.write_state(&req, &answer);
            }
            queue.extend(next);
        }
    }

    fn write_state(&mut self, req: &OpRequest, answer: &Answer) {
        let Some(live) = self.live.as_ref() else { return };
        let (ok, applied, status) = match answer {
            Answer::Http { status, body } => {
                let ok = *status == 200 && *body.field("ok") == true;
                (ok, ok.then(|| *body.field("value").field("applied") == true), Some(*status))
            }
            Answer::Transport => (false, None, None),
        };
        let state = json!({
            "last_report": { "reason": req.reason, "ok": ok, "applied": applied, "at": wall_ms(), "status": status },
            "daemon": live.session.reporter.daemon().to_json(),
            "heartbeat_ms": live.session.reporter.heartbeat_ms(),
        });
        // Diagnostic only; a failed write is ignored.
        let _ = self.store.write(AGENT_STATE_FILE, &format!("{state}\n"), 0o644);
    }
}

/// Where the trajectory mirror finds acpmux: the work user's home when the
/// image has that user (the session host's layout, `linux/spawn.rs`
/// `select_layout`), else root's. Its staging folder for restores is that
/// user's (0700): the thread writes bundles as that user.
fn spawn_trajectories(paths: &Paths) -> io::Result<Trajectories<PosterHttp>> {
    let user = lookup_user(WORK_USER)
        .or_else(|| lookup_user("root"))
        .ok_or_else(|| io::Error::other("no work user and no root user"))?;
    let home = if user.uid == 0 { PathBuf::from(ROOT_HOME) } else { PathBuf::from(WORK_HOME) };
    let staging = paths.at(TRAJECTORY_STAGING);
    match fs::symlink_metadata(&staging) {
        Ok(meta) if !meta.is_dir() => {
            return Err(io::Error::other(format!("{} is not a folder", staging.display())));
        }
        Ok(_) => {}
        Err(_) => fs::create_dir_all(&staging)?,
    }
    std::os::unix::fs::lchown(&staging, Some(user.uid), Some(user.gid))?;
    fs::set_permissions(&staging, fs::Permissions::from_mode(0o700))?;
    let acpmux = home.join(".acpmux");
    let layout = Layout { sessions: acpmux.join("sessions"), home: home.clone(), staging };
    let importer = AcpmuxImporter {
        bin: binary_path(&home),
        user: user.name.clone(),
        uid: user.uid,
        gid: user.gid,
        home,
        socket: acpmux.join("acpmux.sock"),
    };
    let identity = Some((user.uid, user.gid));
    Trajectories::spawn(layout, Box::new(importer), identity, wall_ms, random_unit, log)
}

/// The harness-login thread: the login files under the work user's home
/// (read and written as that user), its state under the agent's root.
fn spawn_harness_logins(paths: &Paths) -> io::Result<HarnessLogins<PosterHttp, PlatformHttp>> {
    use crate::team_ssh::enroll::{TEAM_BOUND_FILE, TEAM_ENROLL_FILE};
    let user = lookup_user(WORK_USER)
        .or_else(|| lookup_user("root"))
        .ok_or_else(|| io::Error::other("no work user and no root user"))?;
    let home = if user.uid == 0 { PathBuf::from(ROOT_HOME) } else { PathBuf::from(WORK_HOME) };
    let setup = LoginSetup {
        home,
        state_file: paths.at(super::harness_login::STATE_FILE),
        vm_kind_file: paths.at(super::wire::VM_KIND_FILE),
        team_files: vec![paths.at(TEAM_ENROLL_FILE), paths.at(TEAM_BOUND_FILE)],
        fs_identity: Some((user.uid, user.gid)),
    };
    HarnessLogins::spawn(setup, wall_ms, random_unit, log)
}

/// [`Platform`] over cmux-server's HTTPS client.
pub struct PlatformHttp(pub JsonPoster);

impl Platform for PlatformHttp {
    fn send(
        &self,
        method: Method,
        url: &str,
        body: Option<&Value>,
        bearer: &str,
    ) -> Result<(u16, Value), String> {
        let verb = match method {
            Method::Get => "GET",
            Method::Put => "PUT",
        };
        self.0.send(verb, url, body, Some(bearer))
    }
}

/// The minter's own client for the bound machine: the same install key,
/// its own HTTPS poster and bearer cache.
fn github_client(bound: &Bound, key: &InstallKey) -> Result<CloudClient<PosterHttp>, String> {
    let key = InstallKey::from_pkcs8(key.pkcs8(), &SystemRandom::new())?;
    Ok(CloudClient::new(PosterHttp(JsonPoster::new()?), bound.clone(), key))
}

/// The ask of a `{"github_token": {...}}` or `{"handoff_report": {...}}`
/// line (checked), or `None` for every other line (the session's).
fn agent_ask(line: &str) -> Option<Ask> {
    let msg: Value = serde_json::from_str(line).ok()?;
    if let Some(ask) = msg.get(github::REQUEST_KEY) {
        return Some(github::TokenAsk::from_json(ask).into());
    }
    if let Some(ask) = msg.get(super::github_repos::REQUEST_KEY) {
        return Some(super::github_repos::ReposAsk::from_json(ask).into());
    }
    let report = msg.get(handoff::REQUEST_KEY)?;
    Some(HandoffReport::from_json(report).into())
}

/// Reads what is available; `Ok(false)` at end of stream.
fn read_available(stream: &mut UnixStream, buf: &mut Vec<u8>) -> io::Result<bool> {
    let mut chunk = [0u8; 4096];
    loop {
        match stream.read(&mut chunk) {
            Ok(0) => return Ok(false),
            Ok(n) => {
                buf.extend_from_slice(read_part(&chunk, n)?);
                if buf.len() > MAX_LINE {
                    return Ok(true);
                }
            }
            Err(e) if e.kind() == io::ErrorKind::WouldBlock => return Ok(true),
            Err(e) if e.kind() == io::ErrorKind::Interrupted => continue,
            Err(e) => return Err(e),
        }
    }
}

/// The complete lines available now, and whether the stream is still usable:
/// `false` at end of stream, on a read error, or when the unfinished line is
/// over `MAX_LINE`. So `buf` never holds more than `MAX_LINE` plus one read.
fn read_lines(stream: &mut UnixStream, buf: &mut Vec<u8>) -> (Vec<String>, bool) {
    let open = read_available(stream, buf).unwrap_or(false);
    let lines = take_lines(buf);
    (lines, open && buf.len() <= MAX_LINE)
}

/// The first `n` bytes of a read buffer; a reader that claims more than
/// the buffer holds is an error.
fn read_part(buf: &[u8], n: usize) -> io::Result<&[u8]> {
    buf.get(..n).ok_or_else(|| io::Error::other("read returned more than its buffer"))
}

/// Complete lines out of `buf` (the rest stays).
fn take_lines(buf: &mut Vec<u8>) -> Vec<String> {
    let mut out = Vec::new();
    while let Some(nl) = buf.iter().position(|b| *b == b'\n') {
        // `nl` is a position in `buf`, so the range is in bounds.
        let mut line: Vec<u8> = buf.drain(..=nl).collect();
        line.pop();
        out.push(String::from_utf8_lossy(&line).into_owned());
    }
    out
}

fn group_id(name: &str) -> Option<u32> {
    let cname = std::ffi::CString::new(name).ok()?;
    // SAFETY: getgrnam returns a pointer to static storage or null.
    let group = unsafe { libc::getgrnam(cname.as_ptr()) };
    if group.is_null() {
        return None;
    }
    // SAFETY: non-null result from getgrnam.
    Some(unsafe { (*group).gr_gid })
}

/// `cmux host cloud probe-activity`: the daemon advertises vm-activity-v1
/// and a `subscribe-activity` stream answers with a snapshot.
pub fn probe_activity(paths: &Paths, timeout: Duration) -> Result<Value, String> {
    let socket = daemon_socket(paths).ok_or_else(|| format!("{DAEMON_SOCKET_FILE} is missing"))?;
    let identify = query_identify(&socket, timeout).map_err(|e| format!("identify: {e}"))?;
    let caps = identify.field("capabilities").as_array().cloned().unwrap_or_default();
    if !caps.iter().any(|c| c == DAEMON_ACTIVITY_CAPABILITY) {
        return Err(format!("daemon does not advertise {DAEMON_ACTIVITY_CAPABILITY}"));
    }
    let mut stream = UnixStream::connect(&socket).map_err(|e| e.to_string())?;
    stream.set_read_timeout(Some(timeout)).map_err(|e| e.to_string())?;
    stream.write_all(b"{\"id\":1,\"cmd\":\"subscribe-activity\"}\n").map_err(|e| e.to_string())?;
    let mut line = String::new();
    BufReader::new(stream)
        .read_line(&mut line)
        .map_err(|_| "activity stream did not connect".to_owned())?;
    let msg: Value = serde_json::from_str(&line).map_err(|e| e.to_string())?;
    if *msg.field("ok") != true || !msg.field("data").field("activity").is_object() {
        return Err("activity stream did not connect".to_owned());
    }
    let change = super::wire::activity_from_daemon(msg.field("data").field("activity"));
    let mut activity = super::wire::Activity::default();
    change.apply(&mut activity);
    Ok(json!({ "capability": true, "connected": true, "activity": activity.to_json() }))
}

/// `cmux host cloud daemon-info`: the daemon block from a live identify.
pub fn print_daemon_info(paths: &Paths, timeout: Duration) -> Result<Value, String> {
    let socket = daemon_socket(paths).ok_or_else(|| format!("{DAEMON_SOCKET_FILE} is missing"))?;
    let identify = query_identify(&socket, timeout).map_err(|e| format!("identify: {e}"))?;
    Ok(daemon_info_from_identify(&identify, false).to_json())
}

#[cfg(test)]
#[path = "role_tests.rs"]
mod role_tests;

#[path = "role_bootstrap.rs"]
mod bootstrap;
