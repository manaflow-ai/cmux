//! The thread that keeps a person's harness logins in sync for their Cloud
//! machine (`harness_login.rs`), beside the Cloud worker so a slow request
//! never stalls its poll loop. The worker hands it a client at each bind and
//! waits up to [`BOOT_WAIT`] for its first pass (one list and the writes it
//! allows) before the machine's first status report, so the first chat
//! finds the login. From then on it looks at the login files every
//! [`SCAN_EVERY`] (metadata only; a file is read when it changed) and lists
//! the saved logins every [`PULL_EVERY`] with jitter, backing off on errors.
//! A deployment that keeps no logins (404) is asked again every
//! [`OFF_EVERY`].
//!
//! On Linux the login files are read and written as the work user
//! (`setfsuid`), so a link the work user planted cannot make root read or
//! write another file, and a written login is that user's. The state file
//! is root's (0600). No login, and no fingerprint, is ever logged.

use std::collections::BTreeMap;
use std::fs::{self, OpenOptions};
use std::io::{self, Read, Write};
use std::os::unix::fs::{DirBuilderExt, MetadataExt, OpenOptionsExt, PermissionsExt};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{self, Receiver, RecvTimeoutError, Sender};
use std::thread::JoinHandle;
use std::time::{Duration, Instant};

use serde_json::Value;

use super::client::{CloudClient, Http};
use super::harness_login::{
    CONTENT_MAX_BYTES, HARNESSES, Harness, Listed, Local, MACHINE_PATH, Put, Report, SyncState,
    parse_list, parse_put, personal_machine, put_path,
};
use super::sender::Backoff;

/// How long the worker holds its first status report for the boot pass.
pub const BOOT_WAIT: Duration = Duration::from_secs(10);
pub const SCAN_EVERY: Duration = Duration::from_secs(10);
pub const PULL_EVERY: Duration = Duration::from_secs(5 * 60);
pub const OFF_EVERY: Duration = Duration::from_secs(60 * 60);
/// A drop waits this long for the request in flight.
pub const STOP_WAIT: Duration = Duration::from_secs(25);

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Method {
    Get,
    Put,
}

/// One JSON request to the platform origin with the machine's bearer.
pub trait Platform {
    fn send(
        &self,
        method: Method,
        url: &str,
        body: Option<&Value>,
        bearer: &str,
    ) -> Result<(u16, Value), String>;
}

/// The saved-login routes, as the thread uses them (tests fake it).
pub trait Api {
    fn list(&mut self) -> Listed;
    fn put(&mut self, report: &Report) -> Put;
}

/// Where the thread looks.
#[derive(Clone, Debug)]
pub struct Setup {
    /// The work user's home; the harness files are under it.
    pub home: PathBuf,
    pub state_file: PathBuf,
    /// `/etc/cmux/vm-kind`.
    pub vm_kind_file: PathBuf,
    /// A team enroll or binding on disk (`team_ssh::enroll`).
    pub team_files: Vec<PathBuf>,
    /// The `(uid, gid)` the login files are read and written as (Linux).
    pub fs_identity: Option<(u32, u32)>,
}

impl Setup {
    /// A personal machine, decided again at every pass (fail closed).
    pub fn personal(&self) -> bool {
        let kind = fs::read(&self.vm_kind_file)
            .ok()
            .filter(|b| b.len() <= 64)
            .and_then(|b| String::from_utf8(b).ok());
        let team = self.team_files.iter().any(
            |f| !matches!(fs::symlink_metadata(f), Err(e) if e.kind() == io::ErrorKind::NotFound),
        );
        personal_machine(kind.as_deref(), team)
    }

    fn file(&self, harness: &Harness) -> PathBuf {
        self.home.join(harness.file)
    }
}

/// What one pass came to.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Pass {
    Done,
    Off,
    Retry(String),
}

/// The metadata a scan compares, so an unchanged file is not read.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct FileKey {
    len: u64,
    ino: u64,
    mtime: (i64, i64),
    ctime: (i64, i64),
}

/// The sync, over an [`Api`] and the files (sans thread).
pub struct Syncer {
    setup: Setup,
    state: SyncState,
    seen: BTreeMap<&'static str, Option<FileKey>>,
    /// A 409 said the saved login is gone: list soon to learn its revision,
    /// so a sign-out here moves the base past it.
    pub pull_soon: bool,
    log: fn(&str),
}

impl Syncer {
    pub fn new(setup: Setup, log: fn(&str)) -> Syncer {
        let text = fs::read_to_string(&setup.state_file).ok();
        Syncer {
            state: SyncState::parse(text.as_deref()),
            setup,
            seen: BTreeMap::new(),
            pull_soon: false,
            log,
        }
    }

    pub fn state(&self) -> &SyncState {
        &self.state
    }

    pub fn setup(&self) -> &Setup {
        &self.setup
    }

    fn as_user<T>(&self, f: impl FnOnce() -> T) -> T {
        set_fs_identity(self.setup.fs_identity, self.log);
        let out = f();
        if self.setup.fs_identity.is_some() {
            set_fs_identity(Some(own_identity()), self.log);
        }
        out
    }

    fn local(&self, harness: &Harness) -> (Local, Option<FileKey>) {
        let path = self.setup.file(harness);
        self.as_user(|| read_login(harness, &path))
    }

    fn save_state(&self) {
        let text = self.state.to_text();
        if let Err(e) = write_atomic(&self.setup.state_file, text.as_bytes(), 0o600) {
            (self.log)(&format!("harness login: state write failed: {e}"));
        }
    }

    /// Lists the saved logins and writes each one the rules allow (boot and
    /// every pull).
    pub fn pull(&mut self, api: &mut dyn Api) -> Pass {
        let saved = match api.list() {
            Listed::Saved(saved) => saved,
            Listed::Off => return Pass::Off,
            Listed::Retry(why) => return Pass::Retry(why),
            Listed::Refused(code) => return Pass::Retry(format!("list refused: {code}")),
        };
        let mut changed = false;
        for entry in &saved {
            let Some(harness) = super::harness_login::harness(&entry.harness) else { continue };
            let (local, _) = self.local(harness);
            let (write, moved) = self.state.saved(&local, entry);
            changed |= moved;
            let Some(content) = write else { continue };
            let path = self.setup.file(harness);
            match self.as_user(|| write_login(&path, &content)) {
                Ok(()) => {
                    self.state.written(entry);
                    self.seen.remove(harness.id);
                    changed = true;
                    (self.log)(&format!(
                        "harness login: {} revision {} written",
                        harness.id, entry.revision
                    ));
                }
                Err(e) => (self.log)(&format!("harness login: {} write failed: {e}", harness.id)),
            }
        }
        if changed {
            self.save_state();
        }
        Pass::Done
    }

    /// Looks at each login file; a changed one is read, and a login that
    /// differs from the last synced one is sent once.
    pub fn scan(&mut self, api: &mut dyn Api) -> Pass {
        let mut outcome = Pass::Done;
        for harness in HARNESSES {
            let path = self.setup.file(harness);
            let key = self.as_user(|| file_key(&path));
            if key.is_ok() && self.seen.get(harness.id) == key.as_ref().ok() {
                continue;
            }
            let (local, read_key) = self.local(harness);
            let (report, moved) = self.state.observe(harness.id, &local);
            if moved {
                (self.log)(&format!("harness login: {} signed out here", harness.id));
                self.save_state();
            }
            let Some(report) = report else {
                if local != Local::Unreadable {
                    self.seen.insert(harness.id, read_key);
                }
                continue;
            };
            let put = api.put(&report);
            self.state.answered(&report, &put);
            match &put {
                Put::Saved { revision, .. } => {
                    (self.log)(&format!("harness login: {} sent, revision {revision}", harness.id));
                }
                Put::Revoked => {
                    self.pull_soon = true;
                    (self.log)(&format!(
                        "harness login: {} was deleted by its owner; not sent until a fresh sign-in",
                        harness.id
                    ));
                }
                Put::Refused(code) => {
                    (self.log)(&format!("harness login: {} refused: {code}", harness.id));
                }
                Put::Off => outcome = Pass::Off,
                Put::Retry(why) => outcome = Pass::Retry(why.clone()),
            }
            if matches!(put, Put::Saved { .. } | Put::Revoked | Put::Refused(_)) {
                self.seen.insert(harness.id, read_key);
                self.save_state();
            }
            if outcome != Pass::Done {
                break;
            }
        }
        outcome
    }
}

/// The key of the file at `path` now (`Ok(None)`: not found).
fn file_key(path: &Path) -> io::Result<Option<FileKey>> {
    match fs::symlink_metadata(path) {
        Ok(m) => Ok(Some(FileKey {
            len: m.len(),
            ino: m.ino(),
            mtime: (m.mtime(), m.mtime_nsec()),
            ctime: (m.ctime(), m.ctime_nsec()),
        })),
        Err(e) if e.kind() == io::ErrorKind::NotFound => Ok(None),
        Err(e) => Err(e),
    }
}

/// The login file at `path`, never through a link, at most 64 KiB + 1 read.
pub fn read_login(harness: &Harness, path: &Path) -> (Local, Option<FileKey>) {
    let opened = OpenOptions::new().read(true).custom_flags(libc::O_NOFOLLOW).open(path);
    let mut file = match opened {
        Ok(file) => file,
        Err(e) if e.kind() == io::ErrorKind::NotFound => return (Local::Absent, None),
        Err(_) => return (Local::Unreadable, None),
    };
    let Ok(meta) = file.metadata() else { return (Local::Unreadable, None) };
    if !meta.is_file() {
        return (Local::Unreadable, None);
    }
    let key = FileKey {
        len: meta.len(),
        ino: meta.ino(),
        mtime: (meta.mtime(), meta.mtime_nsec()),
        ctime: (meta.ctime(), meta.ctime_nsec()),
    };
    let mut bytes = Vec::new();
    if (&mut file).take(CONTENT_MAX_BYTES as u64 + 1).read_to_end(&mut bytes).is_err() {
        return (Local::Unreadable, None);
    }
    (Local::from_bytes(harness, Some(bytes)), Some(key))
}

/// Writes a login: its folder is made 0700 when missing, the file is 0600.
pub fn write_login(path: &Path, content: &[u8]) -> io::Result<()> {
    write_atomic(path, content, 0o600)
}

/// A temp file in the same folder (exclusive, never through a link), fsync,
/// rename, fsync of the folder. A missing folder is made 0700.
pub fn write_atomic(path: &Path, content: &[u8], mode: u32) -> io::Result<()> {
    let dir = path.parent().ok_or_else(|| io::Error::other("no parent folder"))?;
    if !dir.exists() {
        fs::DirBuilder::new().recursive(true).mode(0o700).create(dir)?;
        fs::set_permissions(dir, fs::Permissions::from_mode(0o700))?;
    }
    let name = path.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
    let tmp = dir.join(format!(".{name}.cmux-sync-{}", std::process::id()));
    let _ = fs::remove_file(&tmp);
    let result = (|| {
        let mut out = OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(mode)
            .custom_flags(libc::O_NOFOLLOW)
            .open(&tmp)?;
        out.write_all(content)?;
        out.set_permissions(fs::Permissions::from_mode(mode))?;
        out.sync_all()?;
        drop(out);
        fs::rename(&tmp, path)?;
        fs::File::open(dir)?.sync_all()
    })();
    if result.is_err() {
        let _ = fs::remove_file(&tmp);
    }
    result
}

fn own_identity() -> (u32, u32) {
    // SAFETY: plain getters with no arguments.
    unsafe { (libc::geteuid(), libc::getegid()) }
}

/// File access of this thread as `uid`/`gid` (Linux `setfsuid`/`setfsgid`
/// are per thread; network calls are unaffected). Elsewhere a no-op.
fn set_fs_identity(identity: Option<(u32, u32)>, log: fn(&str)) {
    let Some((uid, gid)) = identity else { return };
    #[cfg(target_os = "linux")]
    {
        // SAFETY: plain syscalls on the calling thread; they take integers and touch no memory.
        unsafe {
            libc::setfsgid(gid);
            libc::setfsuid(uid);
        }
        // A second call answers the identity now in force.
        // SAFETY: as above.
        let (now_gid, now_uid) = unsafe { (libc::setfsgid(gid), libc::setfsuid(uid)) };
        if now_uid != uid as i32 || now_gid != gid as i32 {
            log(&format!("harness login: file identity is {now_uid}:{now_gid}, not {uid}:{gid}"));
        }
    }
    #[cfg(not(target_os = "linux"))]
    {
        let _ = (uid, gid, log);
    }
}

/// [`Api`] over the bound machine's client (its bearer) and the platform.
pub struct ClientApi<'a, H: Http, P: Platform> {
    pub client: &'a mut CloudClient<H>,
    pub platform: &'a P,
    pub origin: &'a str,
    pub stop: &'a AtomicBool,
    pub now: fn() -> u64,
}

impl<H: Http, P: Platform> ClientApi<'_, H, P> {
    /// One request; a 401 or 403 drops the cached bearer and retries once.
    fn call(
        &mut self,
        method: Method,
        path: &str,
        body: Option<&Value>,
    ) -> Result<(u16, Value), String> {
        let url = format!("{}{path}", self.origin);
        let mut retried = false;
        loop {
            if self.stop.load(Ordering::SeqCst) {
                return Err("stopping".to_owned());
            }
            let token = self.client.token((self.now)())?;
            let (status, answer) = self.platform.send(method, &url, body, &token)?;
            if (status == 401 || status == 403) && !retried {
                self.client.forget_token();
                retried = true;
                continue;
            }
            return Ok((status, answer));
        }
    }
}

impl<H: Http, P: Platform> Api for ClientApi<'_, H, P> {
    fn list(&mut self) -> Listed {
        match self.call(Method::Get, MACHINE_PATH, None) {
            Ok((status, body)) => parse_list(status, &body),
            Err(why) => Listed::Retry(why),
        }
    }

    fn put(&mut self, report: &Report) -> Put {
        match self.call(Method::Put, &put_path(&report.harness), Some(&report.body())) {
            Ok((status, body)) => parse_put(status, &body),
            Err(why) => Put::Retry(why),
        }
    }
}

enum Msg<H: Http, P: Platform> {
    Bound { client: Box<CloudClient<H>>, platform: P, origin: String, booted: Sender<()> },
}

/// The worker's handle on the thread.
pub struct HarnessLogins<H: Http, P: Platform> {
    tx: Option<Sender<Msg<H, P>>>,
    stop: Arc<AtomicBool>,
    done: Receiver<()>,
    thread: Option<JoinHandle<()>>,
}

impl<H: Http, P: Platform> Drop for HarnessLogins<H, P> {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::SeqCst);
        self.tx = None;
        if !matches!(self.done.recv_timeout(STOP_WAIT), Err(RecvTimeoutError::Timeout))
            && let Some(thread) = self.thread.take()
        {
            let _ = thread.join();
        }
    }
}

impl<H: Http + Send + 'static, P: Platform + Send + 'static> HarnessLogins<H, P> {
    /// Starts the thread. `now` is wall-clock milliseconds (the bearer's
    /// expiry), `random` in `[0, 1)` (jitter).
    pub fn spawn(
        setup: Setup,
        now: fn() -> u64,
        random: fn() -> f64,
        log: fn(&str),
    ) -> io::Result<HarnessLogins<H, P>> {
        let (tx, rx) = mpsc::channel();
        let (done_tx, done) = mpsc::channel::<()>();
        let stop = Arc::new(AtomicBool::new(false));
        let stopping = Arc::clone(&stop);
        let thread = std::thread::Builder::new().name("cmux-host-harness-login".to_owned()).spawn(
            move || {
                let _done = done_tx;
                run(&rx, &stopping, setup, now, random, log);
            },
        )?;
        Ok(HarnessLogins { tx: Some(tx), stop, done, thread: Some(thread) })
    }

    /// The machine is bound (again) and its environment keeps logins at
    /// `origin`. The answer disconnects when the boot pass is over.
    pub fn bound(&self, client: CloudClient<H>, platform: P, origin: &str) -> Receiver<()> {
        let (booted, done) = mpsc::channel();
        if let Some(tx) = self.tx.as_ref() {
            let msg = Msg::Bound {
                client: Box::new(client),
                platform,
                origin: origin.to_owned(),
                booted,
            };
            let _ = tx.send(msg);
        }
        done
    }
}

struct Live<H: Http, P: Platform> {
    client: Box<CloudClient<H>>,
    platform: P,
    origin: String,
}

fn jittered(every: Duration, random: f64) -> Duration {
    every.mul_f64(0.8 + 0.4 * random.clamp(0.0, 1.0))
}

fn run<H: Http, P: Platform>(
    rx: &Receiver<Msg<H, P>>,
    stop: &AtomicBool,
    setup: Setup,
    now: fn() -> u64,
    random: fn() -> f64,
    log: fn(&str),
) {
    let mut syncer = Syncer::new(setup, log);
    let mut live: Option<Live<H, P>> = None;
    let mut backoff = Backoff::new(5_000, 600_000);
    let mut next_pull = Instant::now();
    let mut next_scan = Instant::now();
    let mut off = false;
    loop {
        let msg = if live.is_none() {
            rx.recv().map_err(|_| RecvTimeoutError::Disconnected)
        } else {
            let at = if off { next_pull } else { next_pull.min(next_scan) };
            rx.recv_timeout(at.saturating_duration_since(Instant::now()))
        };
        let mut booted: Option<Sender<()>> = None;
        match msg {
            Ok(Msg::Bound { client, platform, origin, booted: tx }) => {
                live = Some(Live { client, platform, origin });
                backoff.reset();
                off = false;
                next_pull = Instant::now();
                next_scan = Instant::now();
                booted = Some(tx);
            }
            Err(RecvTimeoutError::Disconnected) => return,
            Err(RecvTimeoutError::Timeout) => {}
        }
        if stop.load(Ordering::SeqCst) {
            return;
        }
        let Some(l) = live.as_mut() else { continue };
        if !syncer.setup().personal() {
            // Checked again later: the kind is recorded after create.
            next_pull = Instant::now() + PULL_EVERY;
            next_scan = next_pull;
            continue;
        }
        let mut api = ClientApi {
            client: &mut *l.client,
            platform: &l.platform,
            origin: &l.origin,
            stop,
            now,
        };
        if Instant::now() >= next_pull {
            let pass = syncer.pull(&mut api);
            next_pull = Instant::now()
                + match pass {
                    Pass::Done => {
                        off = false;
                        backoff.reset();
                        jittered(PULL_EVERY, random())
                    }
                    Pass::Off => {
                        off = true;
                        OFF_EVERY
                    }
                    Pass::Retry(why) => {
                        log(&format!("harness login: list failed: {why}"));
                        Duration::from_millis(backoff.next(0, random()))
                    }
                };
        }
        // The boot pass is over: the first report may go.
        drop(booted);
        if !off && Instant::now() >= next_scan {
            next_scan = Instant::now()
                + match syncer.scan(&mut api) {
                    Pass::Done => SCAN_EVERY,
                    Pass::Off => {
                        off = true;
                        next_pull = Instant::now() + OFF_EVERY;
                        OFF_EVERY
                    }
                    Pass::Retry(why) => {
                        log(&format!("harness login: send failed: {why}"));
                        Duration::from_millis(backoff.next(0, random())).max(SCAN_EVERY)
                    }
                };
            if std::mem::take(&mut syncer.pull_soon) {
                next_pull = Instant::now();
            }
        }
    }
}
